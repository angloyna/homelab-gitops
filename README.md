# homelab-gitops

ArgoCD app-of-apps for a two-node k3s cluster (`tina` control-plane, `louise`
worker). Everything lives under `apps/`; `apps/root/application.yaml` discovers
each app by globbing `*/application.yaml`, so adding a directory with an
`application.yaml` is all it takes to register one.

Helm only — no Kustomize. Three shapes are in use:

- **upstream chart + local values** (`cert-manager`, `external-secrets`,
  `longhorn`, `zot`): a multi-source Application, values referenced through a
  `$values` ref source.
- **in-repo chart** (`flow`, `flow-migrations`, `flow-secrets`): `path:` points
  at `apps/<name>/chart`, with `valueFiles: [../values.yaml]`.
- **OCI chart + local values** (`arc-controller`, `arc-runners`): as the first
  shape, but the chart comes from a container registry. GitHub publishes ARC
  nowhere else. `repoURL` takes **no** `oci://` prefix, and the registry must
  be registered as a repository first — `arc-charts` does that.

## Secrets

Application secrets come from **Bitwarden Secrets Manager**, synced into the
cluster by External Secrets Operator. No secret material is committed.

Two credentials are created by hand and belong to neither git nor Bitwarden:
the ESO bootstrap token below, and the GitHub PAT the CI runners use (see
[CI runners](#ci-runners)).

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
        realtime + db (SECRET_KEY_BASE,           (DB__PASSWORD)
        DB__PASSWORD)
```

Sync waves order the bootstrap, and ArgoCD waits for each wave to report
Healthy before starting the next:

| wave | app | why it must come first |
|-----:|-----|------------------------|
| `-3` | `cert-manager` | issues the TLS cert the SDK server needs |
| `-2` | `external-secrets` | provides the CRDs and the SDK server |
| `-1` | `flow-secrets` | creates `flow-dev-secrets` |
| `0`  | `flow-migrations` | Flyway needs `DB__PASSWORD` |
| `1`  | `flow` | needs the whole Secret |
| `1`  | `arc-charts` | registers the OCI registry the two below pull from |
| `2`  | `arc-controller` | installs the CRDs `arc-runners` is made of |
| `3`  | `arc-runners` | needs those CRDs |

### The bootstrap secret

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

The CI runners' GitHub PAT is deliberately **not** in that list, and not in
Bitwarden at all. It is not a flow environment variable — nothing in the
application reads it — and `flow-dev-secrets` is `envFrom`'d into every api
pod, so adding it there would hand every one of them a credential that can
administer the GitHub repo. See [CI runners](#ci-runners).

**Anything that is not a credential belongs in the ConfigMap, not Bitwarden.**
`DB__USER`, `BC_WEBHOOK_URL`, `LINEAR__WEBHOOK_URL`, and `BC___DEEP_LINK_BASE` are
config and live in `apps/flow/chart/templates/configmap.yaml`. `DB__PASSWORD` is
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
kubectl -n flow-dev rollout restart statefulset/flow-db   # only if DB__PASSWORD changed
```

### DB__PASSWORD is special — rotating it takes two steps

`POSTGRES_PASSWORD` is only read when Postgres initializes an **empty** data
directory. For an existing database it is ignored completely: the password
lives inside the database, not in the env var.

So changing `DB__PASSWORD` in Bitwarden does **not** change the database's
password. ESO updates the Secret, pods restart with the new value, and every
one of them is rejected with:

```
asyncpg.exceptions.InvalidPasswordError: password authentication failed for user "flow_user"
```

The failure is delayed and confusing, because pods that have not restarted yet
keep working on the old credential. Change the database too:

```bash
# local socket auth is trusted inside the pod, so no old password needed.
# note flow_user IS the superuser here -- there is no `postgres` role,
# because the volume was initialized with POSTGRES_USER=flow_user.
NEW=$(kubectl -n flow-dev get secret flow-dev-secrets -o jsonpath='{.data.DB__PASSWORD}' | base64 -d)
printf "ALTER USER flow_user WITH PASSWORD '%s';\n" "$NEW" \
  | kubectl -n flow-dev exec -i flow-db-0 -- psql -U flow_user -d flow_data -q

kubectl -n flow-dev rollout restart deploy/flow-api deploy/flow-api-public deploy/flow-realtime
kubectl -n flow-dev delete job flow-migrations-dev   # let it re-run
```

This bit us during the initial migration: the cluster's Postgres had been
initialized with a different password than the one in the Bitwarden project,
so the first ESO sync broke every database client until the `ALTER USER` above.

## CI runners

`arc-controller` + `arc-runners` run GitHub Actions self-hosted runners for
**spike-electric/flow**, replacing GitHub-hosted `ubuntu-latest` for the seven
jobs in that repo's `.github/workflows/ci-checks.yml`. One ephemeral Pod per
queued job, destroyed when the job ends.

Workflows select the pool with **`runs-on: flow-k8s`** — the
`runnerScaleSetName` in `apps/arc-runners/values.yaml`. Runner scale sets match
on that name *only*; they do not register the legacy `self-hosted` label, so a
job asking for `self-hosted` sits in "Waiting for a runner" forever with no
error anywhere. That is the first thing to check when a job never starts.

Runners are **repo-scoped**, not org-scoped: only this one repo can schedule
work onto the cluster. Since runner pods contain a privileged dind sidecar,
widening that to the org would let any repo in it run privileged containers
here.

### The one manual step

**Create the `github-pat` Secret.** A classic PAT with the `repo` scope,
created by an account with **admin** on `spike-electric/flow` — registering
self-hosted runners is an admin-level operation.

This one stays out of Bitwarden on purpose. It is a CI credential, not an
application credential: nothing flow runs ever reads it, and keeping it out of
the ESO path means the operator that bootstraps every app secret has no route
to a token that can administer the repo.

The namespace must exist first. ArgoCD creates it on first sync, or:

```bash
kubectl create namespace arc-runners

kubectl create secret generic github-pat --namespace arc-runners \
  --from-literal=github_token='ghp_…'
```

The key must be exactly `github_token` — the chart hardcodes it. Nothing in
this repo manages this Secret, so `prune` will not remove it, and ArgoCD will
not recreate it if it is deleted: the listener just crash-loops until it is
back. To rotate, `kubectl delete secret` and recreate, then restart the
listener so it re-reads:

```bash
kubectl -n arc-runners delete pod -l actions.github.com/scale-set-name=flow-k8s
```

Set a real expiry and a calendar reminder. The failure mode is silent: when the
token expires, runners simply stop registering and jobs queue with nothing
logged in the cluster.

### Verifying

```bash
kubectl -n arc-systems rollout status deploy/arc-controller-gha-rs-controller
kubectl -n arc-runners get secret github-pat           # must exist first
kubectl -n arc-runners get pods                        # one idle runner (2/2)
```

`flow-k8s` should appear under the repo's Settings → Actions → Runners. During
a run, watch pods come and go, and read either container:

```bash
kubectl -n arc-runners get pods -w
kubectl -n arc-runners logs <pod> -c dind      # dockerd startup
kubectl -n arc-runners logs <pod> -c runner    # job output
```

A few minutes after a run, pod count should be back to 1 with no `Completed` or
`Error` leftovers.

### Known rough edges

- **Toolchains download on every job.** The runner image carries no tool cache,
  so `setup-python`, `setup-node`, and `setup-beam` fetch and install each run.
  This is the main reason a job can be slower here than on `ubuntu-latest`. The
  fix, if it becomes painful, is a custom runner image with the toolchains
  baked in — pushed to `zot`, which is already in the cluster.
- **`erlef/setup-beam` is the likeliest first failure.** It wants prebuilt
  OTP/Elixir matched to the host Ubuntu plus libs a minimal image may not
  carry. If `lint-realtime` alone fails while the others pass, that is why.
- **Docker images re-pull every job.** `/var/lib/docker` is an emptyDir, so
  postgis and flyway are pulled fresh each time. Tolerable on a LAN; `zot` as a
  pull-through cache is the fix if it is not.
- **The runner image is minimal and non-root.** No `psql`, no `sudo` to install
  one. Workflow steps needing a client tool must `docker run` it — which is why
  ci-checks.yml creates its test database through the postgis image rather than
  calling `psql` directly.

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
