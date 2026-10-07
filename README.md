# homelab-gitops

ArgoCD app-of-apps for a two-node k3s cluster (`tina` control-plane, `louise`
worker). Everything lives under `apps/`; `apps/root/application.yaml` discovers
each app by globbing `*/application.yaml`, so adding a directory with an
`application.yaml` is all it takes to register one.

Helm only — no Kustomize. Two shapes are in use:

- **upstream chart + local values** (`cert-manager`, `external-secrets`,
  `longhorn`, `zot`, `tailscale-operator`): a multi-source Application,
  values referenced through a `$values` ref source. `traefik-tailnet` is
  the one raw-manifest app, a single Service (see [Tailscale](#tailscale)).
- **nested app-of-apps in another repo** (`flow`): the Application points at
  a directory of Applications in `spike-electric/flow-infrastructure`, whose
  charts and values live there too. Flow itself, its monitoring stack and
  its CI runners (`arc-charts`, `arc-controller`, `arc-runners`) all arrive
  this way. See [Flow](#flow).

## Secrets

Application secrets come from **Bitwarden Secrets Manager**, synced into the
cluster by External Secrets Operator. No secret material is committed. The
store and the ExternalSecrets that use it are defined in flow-infrastructure
(see [Flow](#flow)); this repo supplies the operator, the SDK server and the
bootstrap token.

Six credentials are created by hand and belong to neither git nor
Bitwarden: the ESO bootstrap token below, the PAT ArgoCD reads
flow-infrastructure with (see [Flow](#flow)), the GitHub PAT the CI
runners use (see [CI runners](#ci-runners)), Prefect's database
password and ClickHouse's admin password, which are not Flow's and so stay
out of Flow's Bitwarden (see [Prefect](#prefect) and
[ClickHouse](#clickhouse)), and the Cloudflare tunnel token (see
[Cloudflare tunnel](#cloudflare-tunnel)). The Tailscale operator's OAuth client used
to be one of these; it now comes from Bitwarden (see
[Tailscale](#tailscale)).

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
| `-3` | `cert-manager` | issues the TLS cert the SDK server needs |
| `-2` | `external-secrets` | provides the CRDs and the SDK server |
| `0`  | `flow` | the nested app-of-apps; its children carry their own waves in flow-infrastructure (the three ARC apps at -4/-3/-2, `flow-secrets` -1, then `flow-dev` and the monitoring apps at 0), and inside the flow chart the ExternalSecrets, database, Flyway hook and apps are waved again |
| `1`  | `tailscale-oauth` | the operator's credential, an ExternalSecret through the `flow-dev` store that `flow` defines |
| `2`  | `tailscale-operator` | cannot start without that Secret |
| `3`  | `traefik-tailnet` | a Service the operator has to be there to claim |

**The CI runners are children of `flow`, not of `root`.** They used to be
three apps here at waves ahead of everything, so that a wedged Flow sync
could never stop them being applied; that ordering now lives inside
flow-infrastructure's `helm/argocd/`, where the ARC apps sit ahead of
`flow-secrets`. What this costs is that the runners now wait on
`cert-manager` and `external-secrets`, both local and both stable, and that
a wedged `root` (a chart that cannot render, say) would hold them up along
with everything else. Nothing CI needs is behind them.

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

## Tailscale

`tailscale-operator` is the [Tailscale Kubernetes
operator](https://tailscale.com/kb/1236/kubernetes-operator); `traefik-tailnet`
is a second LoadBalancer Service over k3s's Traefik pods with
`loadBalancerClass: tailscale`, which the operator turns into a tailnet
device named `ingress`. Traefik still routes by hostname, so putting a site
on the tailnet is a DNS record for its name pointing at that device's
100.x address, plus a certificate Traefik can serve for it; the record can
be public (a tailnet address resolves to nothing for anyone outside) and the
certificate comes from cert-manager through a DNS-01 ClusterIssuer that
flow-infrastructure defines (`helm/letsencrypt`). Grafana and Flow's dev
tier (`grafana.` and `dev.spikeelectric.dev`) are on it, and so is ArgoCD
(`argocd-tailnet`, below); the Cloudflare tunnel's public hostnames carry
the rest for now.

### ArgoCD on the tailnet

`https://argocd.spikeelectric.dev`, from `apps/argocd-tailnet`: a DNS-only
A record at the ingress device, an Ingress on `websecure` with a
cert-manager certificate, and a second Service over the argocd-server pods
that carries the Traefik annotations for re-encrypting to argocd-server's
own self-signed TLS (plain HTTP to it is a redirect loop). The hand-installed
`argocd` Helm release is untouched: `server.insecure` stays off and its
Service is not edited. The `url` in `argocd-cm` is still the chart's
placeholder; it only matters once SSO is configured. The CLI goes through
the same door with `argocd login argocd.spikeelectric.dev --grpc-web`.

The same app also carries the GitHub push webhook, so a commit is picked
up in seconds instead of on the two-minute poll: `/api/webhook`, and only
that path, on the Cloudflare Tunnel as `hooks.turdblossom.dev`, plus an
ExternalSecret that merges the signing secret into `argocd-secret`. The
secret is generated by flow-infrastructure (`environments/dev`,
`ARGOCD__WEBHOOK_SECRET`); the tunnel hostname and the webhooks on each
repository are set by hand, as that repo's README ("ArgoCD webhook") lays
out.

### Where the credential comes from

The operator logs in with an OAuth client. flow-infrastructure creates it
with OpenTofu (`modules/tailscale`, applied from `shared/`) along with the
tailnet policy that defines `tag:k8s-operator` and lets it own `tag:k8s`,
and `environments/dev` there writes the client's id and secret into the
flow-dev Bitwarden project. `apps/tailscale-oauth` is an ExternalSecret
that turns those into the `operator-oauth` Secret the chart mounts. No
step here; rotating the client is a `tofu apply` in that repo, and the
operator picks the new mount up on its next restart:

```bash
kubectl -n tailscale rollout restart deploy/operator
```

### Verifying

```bash
kubectl -n tailscale get pods                       # operator-0 plus one ts-traefik-tailnet-* proxy
kubectl -n kube-system get svc traefik-tailnet      # EXTERNAL-IP: ingress.<tailnet>.ts.net
tailscale status | grep -E 'ingress|tailscale-operator'
```

The device's address is what DNS records for tailnet-only sites point at:
`tailscale ip -4 ingress`. The operator renames or replaces the proxy on
some upgrades, but the address is stable for the device's lifetime; if it
ever changes, the records do too.

## CI runners

The GitHub Actions self-hosted runners for **spike-electric/flow**
(`arc-charts`, `arc-controller`, `arc-runners`: the `flow-k8s` pool) are
Flow's CI, so they are defined in flow-infrastructure, under `helm/`, and
arrive here through the `flow` Application like everything else of Flow's.
That repo's README has the design, the one manual step (the `github-pat`
Secret in the `arc-runners` namespace, created by hand and in neither git
nor Bitwarden), the verification commands and the runbook for pods stuck in
`PodInitializing`.

What is still this repo's: the runners' dind pulls Docker Hub images through
`zot` (`--registry-mirror`, pointed at `zot.zot.svc.cluster.local:5000`), so
`apps/zot` has to exist and answer on that Service name; and the runner pods
need `/dev/net/tun` on the node, which k3s provides.

## Cloudflare tunnel

`apps/cloudflared`: the one-replica cloudflared Deployment that connects the
cluster to the Cloudflare Tunnel carrying the public hostnames
(`ingest.turdblossom.dev`, `hooks.turdblossom.dev`) to Traefik. The
hostnames and their origins live in Zero Trust, set by hand; this repo only
runs the connector. It was hand-installed in July 2026 on the `latest` tag
and adopted here on 2026-10-07 pinned to the version then running; upgrading
is a tag bump in `manifests/deployment.yaml`.

The tunnel token is the hand-created `tunnel-token` Secret in the
`cloudflared` namespace, key `token`, from the tunnel's page in Zero Trust.
It predates the Application and carries no ArgoCD labels, so prune leaves it
alone. Recreating it on a new cluster:

```bash
kubectl create namespace cloudflared
kubectl -n cloudflared create secret generic tunnel-token --from-literal=token='<tunnel token>'
```

## Prefect

`http://prefect.tail60f7ac.ts.net`, from `apps/prefect`: Prefect 3 for
workflow experiments, unrelated to Flow (Flow's jobs stay on the API's
APScheduler; flow-infrastructure knows nothing about this). One
Application with three sources: the upstream `prefect-server` and
`prefect-worker` charts with local values, and `manifests/` for a
Postgres 17 StatefulSet on Longhorn that the server uses as its external
database (the chart's bundled option is Bitnami's Postgres 14 from the
frozen `bitnamilegacy` registry) and the tailnet Service. The worker
polls a Kubernetes work pool named `kubernetes`, creating it on first
start, and runs flows as Jobs in the `prefect` namespace. No login on the
UI, and no public DNS or certificate either: it is on the tailnet the way
the dev databases are, a LoadBalancer Service with `loadBalancerClass:
tailscale` that the operator turns into the device `prefect`, plain HTTP
over WireGuard.

The one hand-created piece is the `prefect-db` Secret, two keys that must
agree: `password`, which initialises the Postgres role, and
`connection-string`, the URL the server reads. Create it before the first
sync; the volume is initialised from it once, so changing it later is an
`ALTER ROLE` in psql and then both keys.

```bash
kubectl create namespace prefect
PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
kubectl -n prefect create secret generic prefect-db \
  --from-literal=password="$PW" \
  --from-literal=connection-string="postgresql+asyncpg://prefect:${PW}@prefect-db.prefect.svc.cluster.local:5432/prefect"
unset PW
```

From a laptop, `prefect config set PREFECT_API_URL=http://prefect.tail60f7ac.ts.net/api`
points the CLI at it; `prefect deploy` against the `kubernetes` pool is
the quickest way to see a flow run on the cluster.

## ClickHouse

`clickhouse.tail60f7ac.ts.net`, ports 8123 (HTTP, and the `/play` UI) and
9000 (native), from `apps/clickhouse`: Altinity's clickhouse-operator with
local values, and `manifests/clickhouse.yaml`, the one
`ClickHouseInstallation` it runs. Single shard, single replica, ClickHouse
26.8 (the LTS line; a tag bump upgrades it), pinned to louise with a 6Gi
memory limit that ClickHouse treats as its RAM, data on a 50Gi `local-path`
volume rather than Longhorn. That last choice means the data lives on
louise's disk only and goes with the node; it is a target for experiments,
reloadable, not a system of record. Replication and Keeper wait for the
third node (homelab-ansible, `docs/ha-plan.md`): Keeper needs quorum the
same way etcd does.

Log in as `admin` with the hand-created `clickhouse-admin` Secret
(key `password`) in the `clickhouse` namespace; the operator's `default`
user stays restricted to the pods. Create the Secret before the first sync:

```bash
kubectl create namespace clickhouse
kubectl -n clickhouse create secret generic clickhouse-admin \
  --from-literal=password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
```

Then, from a laptop on the tailnet:

```bash
PW=$(kubectl -n clickhouse get secret clickhouse-admin -o jsonpath='{.data.password}' | base64 -d)
curl -s "http://clickhouse.tail60f7ac.ts.net:8123/?user=admin&password=$PW" --data-binary 'SELECT version()'
```

## Kafka

`kafka.tail60f7ac.ts.net:9094` (bootstrap; the broker is advertised as
`kafka-0.tail60f7ac.ts.net:9094`), from `apps/kafka`: Strimzi's operator
with local values, and `manifests/kafka.yaml`, the cluster `main` it runs.
KRaft, one node that is both controller and broker, Kafka 4.3.1, pinned to
louise next to ClickHouse, the log on a 20Gi Longhorn volume. Topics are git:
the `events` topic is a `KafkaTopic` in the same file, and the topic
operator keeps Kafka matching it. No auth; the tailnet is the wall. Three
brokers and controllers wait for the third node (homelab-ansible,
`docs/ha-plan.md`), and when that happens the replication-factor settings
in the `Kafka` resource are the lines to raise.

Inside the cluster the bootstrap is
`main-kafka-bootstrap.kafka.svc.cluster.local:9092`, which is what the
ClickHouse side uses. `http://kafbat.tail60f7ac.ts.net` is Kafbat UI, its
own Application in `apps/kafbat`: topics, messages, consumer groups and
their lag, which is the easiest way to watch the ClickHouse consumer keep
up. It is separate so it syncs and upgrades on its own; it only knows the
bootstrap address. [docs/kafka-to-clickhouse.md](docs/kafka-to-clickhouse.md)
walks through producing to the topic and consuming it into a ClickHouse
table with the Kafka engine and a materialized view.

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

**`zot` is only the CI runners' pull-through mirror now** (flow-infrastructure,
`helm/arc-runners/values.yaml`). Flow's images
come from GHCR over DNS with a pull secret. The old chart addressed zot by
ClusterIP because image pulls happen in the node's network namespace and
never reach CoreDNS, so `*.svc.cluster.local` cannot resolve for them --
still true for anything that pulls from zot directly; the runners' dind
resolves it fine because dockerd runs inside the pod.
