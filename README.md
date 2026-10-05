# homelab-gitops

ArgoCD app-of-apps for a two-node k3s cluster (`tina` control-plane, `louise`
worker). Everything lives under `apps/`; `apps/root/application.yaml` discovers
each app by globbing `*/application.yaml`, so adding a directory with an
`application.yaml` is all it takes to register one.

Helm only — no Kustomize. Three shapes are in use:

- **upstream chart + local values** (`cert-manager`, `external-secrets`,
  `longhorn`, `zot`): a multi-source Application, values referenced through a
  `$values` ref source.
- **OCI chart + local values** (`arc-controller`, `arc-runners`): as the first
  shape, but the chart comes from a container registry. GitHub publishes ARC
  nowhere else. `repoURL` takes **no** `oci://` prefix, and the registry must
  be registered as a repository first — `arc-charts` does that.
- **nested app-of-apps in another repo** (`flow`): the Application points at
  a directory of Applications in `spike-electric/flow-infrastructure`, whose
  charts live there too. See [Flow](#flow).

## Secrets

Application secrets come from **Bitwarden Secrets Manager**, synced into the
cluster by External Secrets Operator. No secret material is committed. The
store and the ExternalSecrets that use it are defined in flow-infrastructure
(see [Flow](#flow)); this repo supplies the operator, the SDK server and the
bootstrap token.

Two credentials are created by hand and belong to neither git nor Bitwarden:
the ESO bootstrap token below, and the GitHub PAT the CI runners use (see
[CI runners](#ci-runners)).

### How it fits together

```
Bitwarden SM org 006747b1-…: projects flow-staging, flow-dev
        │  (one machine account token, Can read on each project)
        ▼
bitwarden-sdk-server  ──HTTPS──▶  External Secrets Operator
  (REST shim for the                      │
   Rust SDK, :9998)                       │  ClusterSecretStores, one per project
                                          │  (flow-infrastructure, helm/flow-secrets)
                      ┌───────────────────┴───────────────────┐
                      ▼ "flow-dev"                            ▼ "flow-secrets" (flow-staging)
   Secret/flow-dev-secrets +                      Secret/grafana-secrets
   Secret/flow-dev-ghcr-pull                      (namespace monitoring)
   (namespace flow-dev: realtime's envFrom, the
    api services' mounted /app/.env, the Flyway
    hook, image pulls)
```

Sync waves order the bootstrap, and ArgoCD waits for each wave to report
Healthy before starting the next:

| wave | app | why it must come first |
|-----:|-----|------------------------|
| `-6` | `arc-charts` | registers the OCI registry the two below pull from |
| `-5` | `arc-controller` | installs the CRDs `arc-runners` is made of |
| `-4` | `arc-runners` | needs those CRDs |
| `-3` | `cert-manager` | issues the TLS cert the SDK server needs |
| `-2` | `external-secrets` | provides the CRDs and the SDK server |
| `0`  | `flow` | the nested app-of-apps; its children carry their own waves in flow-infrastructure (`flow-secrets` -1, then `flow-dev` and the monitoring apps at 0), and inside the flow chart the ExternalSecrets, database, Flyway hook and apps are waved again |

**The three ARC apps run first on purpose, and CI does not depend on any of
the apps below them.** Waves are one global ordering, so they have to sit
somewhere in it. They used to sit at `1`/`2`/`3`, which put the CI runners
behind Bitwarden, ESO, the Flyway Job and every flow pod -- and because the
old migrations Job went permanently OutOfSync on any template change, a
wedged migration meant `root` never applied waves 1-3 and the arc
Applications were never created at all. There is no error to find
when that happens: the namespace that would carry the logs does not exist.

Putting them first inverts the coupling rather than removing it -- the flow
chain now waits on them -- but none of the three can hang on anything outside
the cluster. `arc-charts` is a Secret, `arc-controller` is a local Deployment,
and ArgoCD ships no health check for `AutoscalingRunnerSet`, so `arc-runners`
reports Healthy as soon as the CR applies. An unreachable GitHub or an expired
PAT cannot stall flow. Removing the coupling entirely would take a second
app-of-apps root.

**The `flow-dev` namespace is being reused.** The first attempt at Flow on
this cluster (`apps/flow`, `apps/flow-migrations`, `apps/flow-secrets` as
in-repo charts, images pushed by hand to zot) was disabled on 2026-10-03 and
replaced by the dev environment defined in flow-infrastructure, which lands
in the same namespace under new names (`flow-dev-api`, `flow-dev-db-0`,
...). The `flow-secrets` ClusterSecretStore the old app created is the one
the new apps adopt (same Application name). The old objects are not: before
the new Application's first sync, delete what the retired charts left --
the scaled-down workloads, the `flow-dev-secrets` ExternalSecret, and the
Longhorn volumes `data-flow-db-0` and `flow-attachments` -- so the restore
starts from an empty volume and nothing old answers on the old Service
names. `kubectl delete namespace flow-dev` is the simplest way; ArgoCD
recreates the namespace.

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

- **Explicitly granted access to every project a store reads**: today
  `flow-staging` (`747cfdb0-…`) and `flow-dev` (`5b6aa3f7-…`). Bitwarden
  scopes machine accounts per project. A token without the grant fails with
  a bare `404 Resource not found`, which looks identical to a wrong project
  ID.
- **"Can read" is enough.** ESO's provider page says to grant Read-Write, but
  states it as a blanket note covering the whole provider — including
  `PushSecret`, which writes secrets back to Bitwarden. Nothing here or in
  flow-infrastructure defines a PushSecret; the store and every
  ExternalSecret only read. Since this token bootstraps every other
  credential in the cluster, grant the narrower permission. If a sync ever
  fails with a permission error, widen it then.

Verify a token before wiring it in — this prints secret **names** only:

```bash
BWS_ACCESS_TOKEN='0.xxx…' bws secret list 006747b1-5f82-45f5-8ad5-b49a0130b72c \
  | python3 -c "import json,sys; print('\n'.join(sorted(s['key'] for s in json.load(sys.stdin))))"
```

### Which keys go where

`helm/flow/values.yaml` in flow-infrastructure (`secrets.keys`) enumerates
the keys pulled from Bitwarden. It mirrors `scripts/required-secrets.txt` in
the flow repo — **keep the two in sync**: that file gates compose deploys,
this list gates the cluster.

Keys are listed explicitly rather than using `dataFrom.find`, because the
Bitwarden provider ignores find selectors and returns secrets keyed by UUID —
which would produce a Secret full of unusable environment variable names.
Enumerating also means a key missing from Bitwarden fails loudly at sync
instead of silently leaving a variable unset.

The CI runners' GitHub PAT is deliberately **not** in that list, and not in
Bitwarden at all. It is not a flow environment variable — nothing in the
application reads it — and `flow-dev-secrets` reaches every flow pod, so
adding it there would hand every one of them a credential that can
administer the GitHub repo. See [CI runners](#ci-runners). The GHCR pull
token (`GHCR__PULL_TOKEN`) *is* in Bitwarden, but lands in a separate
dockerconfigjson Secret that only the kubelet reads, never in a pod's
environment.

**Anything that is not a credential belongs in the ConfigMap, not Bitwarden.**
`DB__USER`, the webhook URLs and `BC__DEEP_LINK_BASE` are config and live in
flow-infrastructure's `helm/flow` values. `DB__PASSWORD` is a credential and
comes from Bitwarden. Adding a non-secret to the Bitwarden
project works but muddies the boundary.

### Rotating a secret

Change it in Bitwarden. ESO re-reads on `refreshInterval` (1h) and updates the
Secret in place.

**But running pods will not see it.** There is no Reloader in this cluster, and
`envFrom` is evaluated only at container start — a rotated credential reaches a
running pod on its next restart. Force it:

```bash
kubectl -n flow-dev rollout restart deploy/flow-dev-api deploy/flow-dev-api-public deploy/flow-dev-realtime
kubectl -n flow-dev rollout restart statefulset/flow-dev-db   # only if DB__PASSWORD changed
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
  | kubectl -n flow-dev exec -i flow-dev-db-0 -c db -- psql -U flow_user -d flow_data -q

kubectl -n flow-dev rollout restart deploy/flow-dev-api deploy/flow-dev-api-public deploy/flow-dev-realtime
```

(The Flyway hook re-runs on the next sync by itself; nothing to delete.)

This bit us during the initial migration: the cluster's Postgres had been
initialized with a different password than the one in the Bitwarden project,
so the first ESO sync broke every database client until the `ALTER USER` above.

## Flow

Spike's Flow runs in this cluster -- a dev environment, its Bitwarden
secret store, and the Prometheus/Loki/Grafana stack that watches the Flow
hosts -- but it is Spike's, so everything about it lives in
`spike-electric/flow-infrastructure` under `helm/` (that repo's README has
the design, the manual prerequisites and the verification commands).
`apps/flow/` is the only trace here: an Application that syncs the
Applications defined in that repo's `helm/argocd/`. Images come from GHCR,
built by the flow repo's own workflow, which also commits each new tag into
flow-infrastructure; nothing here changes per deploy.

ArgoCD needs read access to that repo. The org disallows deploy keys, so it
is a fine-grained PAT (Contents: read-only on that one repository, nothing
else) held as a repository Secret in the `argocd` namespace,
`flow-infrastructure-repo`, over HTTPS. Like the runners' PAT it is created
by hand and is not in Bitwarden; it expires, so set a reminder, and renew by
recreating the Secret:

```bash
kubectl -n argocd create secret generic flow-infrastructure-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/spike-electric/flow-infrastructure.git \
  --from-literal=username=x-access-token \
  --from-literal=password='github_pat_…' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret flow-infrastructure-repo argocd.argoproj.io/secret-type=repository --overwrite
```

Everything there reads Bitwarden through the `flow-secrets`
ClusterSecretStore, so it depends on the bootstrap token above being valid.

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

### When pods sit in `PodInitializing`

Seen 2026-09-23 to 2026-10-03: both runner pods stuck `0/2 PodInitializing`
for ten days, the `flow-k8s` pool showing no online runners on GitHub, and
nothing logged anywhere. The dind sidecar had failed its startup probe for
hours, then the pod sandbox vanished (pod IP went to `<none>`) and kubelet
never rebuilt it. The controller still counted the two zombies as its two
pending runners, so the listener held the count at 2 and never created
replacements.

**1. Confirm it is this.** A dind sidecar with a high restart count, no pod IP,
and `PodReadyToStartContainers=False`:

```bash
kubectl -n arc-runners get pods -o wide
kubectl -n arc-runners describe pod <pod> | sed -n '/^Init Containers:/,/^Conditions:/p'
kubectl -n arc-runners get pod <pod> -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

If the pod *has* an IP and dind is still actively restarting, it is a live
probe failure, not a zombie. Read the sidecar log before deleting anything:

```bash
kubectl -n arc-runners logs <pod> -c dind --tail=50
```

**2. Delete the stuck pods.** Runners are ephemeral and these are idle, so
nothing is lost; the controller recreates them within seconds.

```bash
kubectl -n arc-runners delete pod -l actions.github.com/scale-set-name=flow-k8s --timeout=60s
```

**3. If that hangs in `Terminating`, force it.** Only when every container
already shows `terminated` and the pod has no IP, meaning nothing is left
running on the node:

```bash
kubectl -n arc-runners delete pod -l actions.github.com/scale-set-name=flow-k8s --grace-period=0 --force
```

**4. Verify.** Within a minute: `2/2 Running`, ephemeral runners `Running`,
and `Listening for Jobs` in the runner log.

```bash
kubectl -n arc-runners get pods -o wide
kubectl -n arc-runners get ephemeralrunners
kubectl -n arc-runners logs <new-pod> -c runner --tail=5
```

**If the new pods also fail the dind probe,** the node is the problem, not
the pods. The probe is `docker info` with a 1s timeout; healthy is well under
100ms. If it is near or over 1s, the node is overloaded or containerd is
unhealthy, and restarting `k3s-agent` on that node is the next step.

```bash
kubectl -n arc-runners exec <pod> -c dind -- sh -c 'time docker info >/dev/null'
kubectl describe node <node> | sed -n '/^Conditions:/,/^Addresses:/p'
```

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

**Migrations are an ArgoCD hook, not a tracked Job.** The old
`flow-migrations-dev` Job was immutable and permanently OutOfSync after any
template change. The flow chart in flow-infrastructure runs Flyway as a Sync
hook with `BeforeHookCreation`, so it is recreated every sync and never part
of the diff; a failed migration fails the sync instead of wedging it.

**Nothing is pinned to a node any more.** Earlier values files pinned flow and
zot to `tina` citing "louise network flakiness". That was a misdiagnosis — the
real cause was a pending kernel upgrade leaving the running kernel's modules
mismatched, which crash-looped `k3s-agent` until a reboot. Pinning zot was
actively harmful while flow pulled its images from it: a registry pinned to
the same node as everything else means a node reboot leaves every pod in
`ImagePullBackOff`.

**ArgoCD is not managed by this repo** and is pinned to `tina` in its own Helm
release, so it is unavailable while `tina` reboots. Drain first so workloads
migrate while the API server is still up:

```bash
kubectl drain tina --ignore-daemonsets --delete-emptydir-data --timeout=300s
# reboot, then:
kubectl uncordon tina
```

**`zot` is only the CI runners' pull-through mirror now.** Flow's images
come from GHCR over DNS with a pull secret. The old chart addressed zot by
ClusterIP because image pulls happen in the node's network namespace and
never reach CoreDNS, so `*.svc.cluster.local` cannot resolve for them --
still true for anything that pulls from zot directly; the runners' dind
resolves it fine because dockerd runs inside the pod.
