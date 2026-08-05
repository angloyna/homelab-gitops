# homelab-gitops

ArgoCD app-of-apps for a two-node k3s cluster (`tina` control-plane, `louise`
worker). Everything lives under `apps/`; `apps/root/application.yaml` discovers
each app by globbing `*/application.yaml`, so adding a directory with an
`application.yaml` is all it takes to register one.

Helm only — no Kustomize. Two shapes are in use:

- **upstream chart + local values** (`cert-manager`, `external-secrets`,
  `longhorn`, `zot`): a multi-source Application, values referenced through a
  `$values` ref source.
- **in-repo chart** (`flow`, `flow-migrations`, `flow-secrets`): `path:` points
  at `apps/<name>/chart`, with `valueFiles: [../values.yaml]`.

## Secrets

Secrets come from **Bitwarden Secrets Manager**, synced into the cluster by
External Secrets Operator. Nothing except the bootstrap token below is created
by hand, and no secret material is committed.

### How it fits together

```
Bitwarden SM project 006747b1-…
        │  (machine account token)
        ▼
bitwarden-sdk-server  ──HTTPS──▶  External Secrets Operator
  (REST shim for the                      │
   Rust SDK, :9998)                       │  ClusterSecretStore "flow-secrets"
                                          ▼
                              Secret/flow-dev-secrets  (namespace flow-dev)
                                          │
                      ┌───────────────────┴───────────────────┐
                      ▼                                       ▼
        flow: api, api-public (envFrom),          flow-migrations: Flyway Job
        realtime + db (SECRET_KEY_BASE,           (DB_PASSWORD)
        DB_PASSWORD)
```

Sync waves order the bootstrap, and ArgoCD waits for each wave to report
Healthy before starting the next:

| wave | app | why it must come first |
|-----:|-----|------------------------|
| `-3` | `cert-manager` | issues the TLS cert the SDK server needs |
| `-2` | `external-secrets` | provides the CRDs and the SDK server |
| `-1` | `flow-secrets` | creates `flow-dev-secrets` |
| `0`  | `flow-migrations` | Flyway needs `DB_PASSWORD` |
| `1`  | `flow` | needs the whole Secret |

### The one manual step

The machine account token is the single chicken-and-egg secret: it is what
authenticates to Bitwarden, so it cannot come *from* Bitwarden. Create it once,
per cluster:

```bash
kubectl create secret generic bitwarden-access-token \
  --namespace external-secrets \
  --from-literal=token='0.xxxxxxxx…'
```

Requirements for that machine account:

- **Explicitly granted access to project `006747b1-…`.** Bitwarden scopes
  machine accounts per project. A token without the grant fails with a bare
  `404 Resource not found`, which looks identical to a wrong project ID.
- **"Can read" is enough.** ESO's provider page says to grant Read-Write, but
  states it as a blanket note covering the whole provider — including
  `PushSecret`, which writes secrets back to Bitwarden. This repo only ever
  reads: `apps/flow-secrets/` defines a ClusterSecretStore and an
  ExternalSecret and no PushSecret. Since this token bootstraps every other
  credential in the cluster, grant the narrower permission. If a sync ever
  fails with a permission error, widen it then.

Verify a token before wiring it in — this prints secret **names** only:

```bash
BWS_ACCESS_TOKEN='0.xxx…' bws secret list 006747b1-5f82-45f5-8ad5-b49a0130b72c \
  | python3 -c "import json,sys; print('\n'.join(sorted(s['key'] for s in json.load(sys.stdin))))"
```

### Which keys go where

`apps/flow-secrets/chart/values.yaml` enumerates the keys pulled from
Bitwarden. It mirrors `scripts/required-secrets.txt` in the flow repo — **keep
the two in sync**: that file gates compose deploys, this list gates the cluster.

Keys are listed explicitly rather than using `dataFrom.find`, because the
Bitwarden provider ignores find selectors and returns secrets keyed by UUID —
which would produce a Secret full of unusable environment variable names.
Enumerating also means a key missing from Bitwarden fails loudly at sync
instead of silently leaving a variable unset.

**Anything that is not a credential belongs in the ConfigMap, not Bitwarden.**
`DB_USER`, `BC_WEBHOOK_URL`, `LINEAR_WEBHOOK_URL`, and `BC_DEEP_LINK_BASE` are
config and live in `apps/flow/chart/templates/configmap.yaml`. `DB_PASSWORD` is
a credential and comes from Bitwarden. Adding a non-secret to the Bitwarden
project works but muddies the boundary.

### Rotating a secret

Change it in Bitwarden. ESO re-reads on `refreshInterval` (1h) and updates the
Secret in place.

**But running pods will not see it.** There is no Reloader in this cluster, and
`envFrom` is evaluated only at container start — a rotated credential reaches a
running pod on its next restart. Force it:

```bash
kubectl -n flow-dev rollout restart deploy/flow-api deploy/flow-api-public deploy/flow-realtime
kubectl -n flow-dev rollout restart statefulset/flow-db   # only if DB_PASSWORD changed
```

## Gotchas

**The migrations Job is named by image tag.** `flow-migrations-{{ .Values.image.tag }}`
with a permanently-`dev` tag means the name never changes, and Job specs are
immutable — so *any* change to the Job template leaves the app permanently
OutOfSync. Delete the Job and let ArgoCD recreate it (Flyway is idempotent):

```bash
kubectl -n flow-dev delete job flow-migrations-dev
```

**Nothing is pinned to a node any more.** Earlier values files pinned flow and
zot to `tina` citing "louise network flakiness". That was a misdiagnosis — the
real cause was a pending kernel upgrade leaving the running kernel's modules
mismatched, which crash-looped `k3s-agent` until a reboot. Pinning zot was
actively harmful: flow pulls images from zot's ClusterIP with
`imagePullPolicy: Always`, so a registry pinned to the same node as everything
else means a node reboot leaves every flow pod in `ImagePullBackOff`.

**ArgoCD is not managed by this repo** and is pinned to `tina` in its own Helm
release, so it is unavailable while `tina` reboots. Drain first so workloads
migrate while the API server is still up:

```bash
kubectl drain tina --ignore-daemonsets --delete-emptydir-data --timeout=300s
# reboot, then:
kubectl uncordon tina
```

**`zot` is addressed by ClusterIP, not DNS** (`10.43.114.154:5000`). Image
pulls happen in the node's network namespace and never reach CoreDNS, so
`*.svc.cluster.local` cannot resolve for them. If zot's Service is ever
recreated it gets a new ClusterIP, and `apps/flow/values.yaml` plus
`apps/flow-migrations/values.yaml` must be updated.
