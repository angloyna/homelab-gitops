# homelab-gitops

ArgoCD app-of-apps for a two-node k3s cluster (`tina` control-plane, `louise`
worker). Everything lives under `apps/`; `apps/root/application.yaml` discovers
each app by globbing `*/application.yaml`, so adding a directory with an
`application.yaml` is all it takes to register one.

Helm only — no Kustomize. Two shapes are in use: **upstream chart + local
values** (`cert-manager`, `external-secrets`, `longhorn`), a
multi-source Application with values referenced through a `$values` ref
source; and **raw manifests** (`cloudflared`, `plex`), a directory of YAML.

Spike's Flow also runs on this cluster, under its own ArgoCD and its own
repo, spike-electric/flow-infrastructure. This repo supplies the platform
Flow stands on (cert-manager, External Secrets, Longhorn, the Cloudflare
tunnel) and nothing of Flow's (see [Flow](#flow)).

## ArgoCD instances

Two ArgoCDs share the cluster, split by repo. **Flow's** is the original
`argocd` release in namespace `argocd`: it manages
spike-electric/flow-infrastructure's `helm/argocd/` and nothing else, and
everything about it beyond the chart (the repo PAT, the tailnet front door,
the GitHub webhook, the Tailscale operator) is documented in that repo's
README under "ArgoCD". **This repo's** is `argocd-homelab` in namespace
`argocd-homelab`. Both are installed by hand with Helm; the values are
committed under `bootstrap/` and are the only record of them.

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
# Flow's (exists; this is how its values change)
helm upgrade argocd argo/argo-cd --version 10.10.0 -n argocd -f bootstrap/argocd/values.yaml
# this repo's
helm install argocd-homelab argo/argo-cd --version 10.10.0 -n argocd-homelab --create-namespace -f bootstrap/argocd-homelab/values.yaml
```

What keeps them apart:

- **`installationID`**, different in each `argocd-cm`: ArgoCD writes it
  into every resource's tracking annotation and ignores resources carrying
  another instance's ID.
- **One owner for the CRDs**: Flow's release installs them,
  `argocd-homelab` sets `crds.install: false`. Keep both on the same chart
  version and upgrade Flow's first.
- **Separate namespaces for the Application objects**: an instance only
  watches its own, so every `application.yaml` under `apps/` names
  `argocd-homelab`.

The personal instance has no front door. Reach it with a port-forward:

```bash
kubectl -n argocd-homelab port-forward svc/argocd-homelab-server 8443:443
kubectl -n argocd-homelab get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
argocd login localhost:8443 --grpc-web   # or https://localhost:8443 in a browser
```

It polls this repo every two minutes (`timeout.reconciliation`); there is
no webhook. The `homelab-gitops-repo` credential (the deploy key for this
repo) has to exist in `argocd-homelab` as it does in `argocd`:

```bash
kubectl -n argocd get secret homelab-gitops-repo -o yaml | sed 's/namespace: argocd$/namespace: argocd-homelab/' | kubectl apply -f -
```

### The handover (2026-11)

The split was done in this order, each step leaving the cluster running;
it is also the recipe if an instance ever has to be rebuilt.

1. `helm upgrade` Flow's instance with `bootstrap/argocd/values.yaml`
   (sets its `installationID`; every resource gets re-annotated on the
   next sync, which is noise, not change).
2. Merge the homelab-gitops PR that removes `apps/flow`,
   `apps/argocd-tailnet`, `apps/tailscale-oauth`, `apps/tailscale-operator`
   and `apps/traefik-tailnet`. `root` prunes those Application objects;
   none carries the cascade finalizer, so the operator, the `ingress`
   device and Flow's tiers keep running, unowned for a few minutes.
3. Merge the flow-infrastructure PR that defines them there, then
   `kubectl apply -f helm/argocd/flow.yaml` in that repo. Flow's root
   adopts them by name.
4. Install `argocd-homelab` and copy the repo credential in.
5. Hand this repo's apps over: in the `argocd` namespace delete `root`,
   then each remaining Application object. **Longhorn first needs its
   finalizers stripped**, or deleting the Application runs the chart's
   uninstall hook:
   `kubectl -n argocd patch application longhorn --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`.
   Everything else deletes plainly: `kubectl -n argocd delete application
   root cert-manager external-secrets longhorn cloudflared plex prefect
   clickhouse kafka kafbat`.
6. Merge the PR that moves every `application.yaml` to
   `namespace: argocd-homelab`, then `kubectl apply -f
   bootstrap/argocd-homelab/root.yaml`. The new root creates the
   Applications in its namespace and they adopt the running resources.

## Secrets

Application secrets come from **Bitwarden Secrets Manager**, synced into the
cluster by External Secrets Operator. No secret material is committed. The
store and the ExternalSecrets that use it are defined in flow-infrastructure
(see [Flow](#flow)); this repo supplies the operator, the SDK server and the
bootstrap token.

Four credentials are created by hand and belong to neither git nor
Bitwarden: the ESO bootstrap token below, Prefect's database password and
ClickHouse's admin password, which are not Flow's and so stay out of
Flow's Bitwarden (see [Prefect](#prefect) and [ClickHouse](#clickhouse)),
and the Cloudflare tunnel token (see [Cloudflare tunnel](#cloudflare-tunnel)).
Flow's own by-hand credentials (the PAT its ArgoCD reads
flow-infrastructure with, the CI runners' PAT) are listed in that repo's
README.

### How it fits together

```
Bitwarden SM org 006747b1-…: projects flow-staging, flow-dev
        │  (one machine account token, Can read on each project)
        ▼
bitwarden-sdk-server  ──HTTPS──▶  External Secrets Operator
  (REST shim for the                      │
   Rust SDK, :9998)                       │  ClusterSecretStores, one per project
                                          │  (flow-infrastructure, helm/flow-secrets,
                                          │   applied by Flow's ArgoCD)
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

The platform apps above are this instance's whole bootstrap; everything
else here (`longhorn`, `cloudflared`, `plex`, `prefect`,
`clickhouse`, `kafka`, `kafbat`) has no wave and no ordering need. Flow's
waves live in flow-infrastructure, under its own ArgoCD.

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

Spike's Flow runs in this cluster -- three dev tiers, its Bitwarden secret
stores, the Prometheus/Loki/Grafana stack that watches the Flow hosts, its
CI runners, and the Tailscale operator that puts those on Spike's tailnet
-- but it is Spike's, so all of it is defined in
spike-electric/flow-infrastructure and applied by that repo's own ArgoCD
(the `argocd` namespace; see [ArgoCD instances](#argocd-instances)).
Nothing of Flow's is in this repo. What Flow depends on from here is the
platform: cert-manager, External Secrets and its bootstrap token, Longhorn,
and the tunnel hostnames below. The one thing that runs the other way is
the tailnet, next.

## Private network: WARP over the tunnel

Prefect, ClickHouse, Kafka, Kafbat and the Longhorn UI have no front door.
They are plain ClusterIP Services, and a laptop reaches them by their
cluster DNS names through a **Cloudflare WARP private network**: the same
tunnel that carries the public hostnames also routes the cluster's Service
range to enrolled devices. Until 2026-11 they were Tailscale LoadBalancers
on Spike's tailnet; that tailnet is Spike's, so nothing personal is on it
any more. The Zero Trust side is set by hand; this is what it is.

| what | where |
|---|---|
| Prefect UI and API | `http://prefect-server.prefect.svc.cluster.local:4200` |
| ClickHouse HTTP / play UI, native | `clickhouse-clickhouse.clickhouse.svc.cluster.local` ports 8123, 9000 |
| Kafka bootstrap | `main-kafka-bootstrap.kafka.svc.cluster.local:9092` |
| Kafbat UI | `http://kafbat-kafka-ui.kafbat.svc.cluster.local` |
| Longhorn UI | `http://longhorn-frontend.longhorn-system.svc.cluster.local` |

The Zero Trust side of that (the tunnel's CIDR route, the WARP profile's
split tunnel and DNS fallback, who may enroll, which machine, and the
Gateway policy that admits only that login on that machine) is OpenTofu:
`tofu/cloudflare/`, see [Cloudflare](#cloudflare). The laptop's part is
`brew install --cask cloudflare-warp`, log in to the Zero Trust team,
enroll, and the table above works. One thing to know if the laptop is
also on a tailnet: WARP has to own system DNS, so Tailscale's DNS handling
is turned off (`tailscale set --accept-dns=false`), and the module forwards
the tailnet's MagicDNS suffix to Tailscale's resolver (`var.tailnet_dns`)
so those names keep resolving. With both on, WARP sits in "connecting"
forever and `svc.cluster.local` never resolves.

## CI runners

The GitHub Actions self-hosted runners for spike-electric/flow are Flow's
CI and live in flow-infrastructure, as does `zot`, the pull-through mirror
their dind pulls Docker Hub images through (moved there 2026-11-20; it had
no other consumer). Nothing of theirs is here.

## Cloudflare

Two halves. **In the cluster**, `apps/cloudflared`: the two-replica
cloudflared Deployment that connects the Cloudflare Tunnel. It was
hand-installed in July 2026 on the `latest` tag and adopted here on
2026-10-07 pinned to the version then running; upgrading is a tag bump in
`manifests/deployment.yaml`. Its token is the hand-created `tunnel-token`
Secret in the `cloudflared` namespace, key `token`, from the tunnel's page
in Zero Trust; it predates the Application and carries no ArgoCD labels,
so prune leaves it alone. Recreating it on a new cluster:

```bash
kubectl create namespace cloudflared
kubectl -n cloudflared create secret generic tunnel-token --from-literal=token='<tunnel token>'
```

**In Cloudflare**, `tofu/cloudflare/`, an OpenTofu root module for
everything the tunnel and the private network need on the account side.
Until 2026-11 all of it was set by hand in the Zero Trust dashboard.

| what | resource | note |
|---|---|---|
| the tunnel | `cloudflare_zero_trust_tunnel_cloudflared.cluster` | imported, `prevent_destroy`: a new tunnel would mean a new token in the cluster |
| its public hostnames | `..._tunnel_cloudflared_config.cluster` | `hooks.` and `ingest.turdblossom.dev` to Traefik, both Flow's (flow-infrastructure); `var.public_hostnames` |
| the private network | `..._tunnel_cloudflared_route.cluster_services` and `.cluster_pods` | `10.43.0.0/16`, k3s's Service CIDR, and `10.42.0.0/16`, the pod CIDR: Kafka's advertised broker address is a headless-Service name that resolves to the broker pod |
| the WARP profile | `..._device_default_profile.default` and `..._local_domain_fallback.default` | include-mode split tunnel of those two ranges only; `svc.cluster.local` resolved by CoreDNS `10.43.0.10`; the tailnet suffix forwarded to Tailscale's resolver (`var.tailnet_dns`) |
| who may enroll | `..._access_application.warp_enrollment` + `..._access_policy.enroll` | one email, `var.login_email` |
| which machine | `..._list.device_serials` + `..._device_posture_rule.known_device` | serial numbers, `var.device_serial_numbers` |
| who gets in | `..._gateway_policy.cluster_allow` / `cluster_block` | the login on a listed machine may reach both ranges; everyone else enrolled is blocked from them |

State is one object in the S3 bucket `angloyna-homelab-tofu-state` in
the personal AWS account (profile `default`, region `us-east-1`), versioned,
locked with S3's own lock file, and encrypted client-side with a
passphrase before upload, the way the Spike repos keep theirs. Two
credentials beyond the AWS profile, both by hand and in the personal
password manager, neither in git or Bitwarden:

- **An API token** (Cloudflare dashboard > profile > API Tokens), with
  Account permissions `Cloudflare Tunnel: Edit`, `Zero Trust: Edit`,
  `Access: Apps and Policies: Edit`, `Access: Device Posture: Edit`, and
  `Account Settings: Read`, scoped to this account. Exported as
  `CLOUDFLARE_API_TOKEN`.
- **The state passphrase**, `openssl rand -base64 48`, exported as
  `TF_VAR_homelab_state_passphrase` (its own name: the Spike repos' `TF_VAR_state_passphrase`
  is a different secret and may be set in the same shell).

Setup, once. The bucket first, versioned so an overwritten state can be
recovered and closed to the public:

```bash
export AWS_PROFILE=default
aws s3api create-bucket --bucket angloyna-homelab-tofu-state --region us-east-1
aws s3api put-bucket-versioning --bucket angloyna-homelab-tofu-state --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket angloyna-homelab-tofu-state --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Then the module:

```bash
export AWS_PROFILE=default
export CLOUDFLARE_API_TOKEN='…'
export TF_VAR_homelab_state_passphrase='…'
export TF_VAR_account_id='<Zero Trust > Settings > Account: Account ID>'
export TF_VAR_tunnel_id='<Networks > Tunnels > the tunnel: Tunnel ID>'
export TF_VAR_tunnel_name='<its name there>'
export TF_VAR_login_email='you@example.com'
export TF_VAR_device_serial_numbers='["<serial from: system_profiler SPHardwareDataType>"]'
cd tofu/cloudflare && tofu init
# the CIDR route was created in the dashboard before the module; adopt it
tofu import cloudflare_zero_trust_tunnel_cloudflared_route.cluster_services "$TF_VAR_account_id/<Networks > Routes > the route's ID>"
tofu plan
```

The plan's imports (the tunnel, its config, the default WARP profile and
its fallback list) should show no changes beyond what this module adds:
the route's comment, the profile's include list, the fallback entry for
the cluster, and the enrollment, posture and Gateway objects as creates.
If the plan wants to create `warp_enrollment` but apply answers that an
application of type `warp` already exists, Zero Trust made one when
enrollment permissions were first touched in the dashboard: import it
with `tofu import cloudflare_zero_trust_access_application.warp_enrollment
"$TF_VAR_account_id/<its id, from Access > Applications>"` and plan again.
Then `tofu apply`, and the private network is live for the listed machine
once WARP on it is enrolled with that login.

A second laptop is one more serial in `TF_VAR_device_serial_numbers`. A
third public hostname is one more entry in `var.public_hostnames`.

## Prefect

`http://prefect-server.prefect.svc.cluster.local:4200` over the private
route, from `apps/prefect`: Prefect 3 for workflow experiments, unrelated
to Flow (Flow's jobs stay on the API's APScheduler; flow-infrastructure
knows nothing about this). One Application with three sources: the
upstream `prefect-server` and `prefect-worker` charts with local values,
and `manifests/` for a Postgres 17 StatefulSet on Longhorn that the server
uses as its external database (the chart's bundled option is Bitnami's
Postgres 14 from the frozen `bitnamilegacy` registry). The worker polls a
Kubernetes work pool named `kubernetes`, creating it on first start, and
runs flows as Jobs in the `prefect` namespace. No login on the UI and no
public DNS or certificate: the private route is the wall (see [Private
network](#private-network-warp-over-the-tunnel)).

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

From the laptop, `prefect config set PREFECT_API_URL=http://prefect-server.prefect.svc.cluster.local:4200/api`
points the CLI at it; `prefect deploy` against the `kubernetes` pool is
the quickest way to see a flow run on the cluster.

## ClickHouse

`clickhouse-clickhouse.clickhouse.svc.cluster.local` over the private route,
ports 8123 (HTTP, and the `/play` UI) and 9000 (native), from `apps/clickhouse`: Altinity's clickhouse-operator with
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

Then, from the laptop:

```bash
PW=$(kubectl -n clickhouse get secret clickhouse-admin -o jsonpath='{.data.password}' | base64 -d)
curl -s "http://clickhouse-clickhouse.clickhouse.svc.cluster.local:8123/?user=admin&password=$PW" --data-binary 'SELECT version()'
```

## Kafka

`main-kafka-bootstrap.kafka.svc.cluster.local:9092` over the private route
(the broker advertises itself by its own `*.svc.cluster.local` name, which
the route's DNS fallback resolves), from `apps/kafka`: Strimzi's operator
with local values, and `manifests/kafka.yaml`, the cluster `main` it runs.
KRaft, one node that is both controller and broker, Kafka 4.3.1, pinned to
louise next to ClickHouse, the log on a 20Gi Longhorn volume. Topics are git:
the `events` topic is a `KafkaTopic` in the same file, and the topic
operator keeps Kafka matching it. No auth; the private route is the wall. Three
brokers and controllers wait for the third node (homelab-ansible,
`docs/ha-plan.md`), and when that happens the replication-factor settings
in the `Kafka` resource are the lines to raise.

The same bootstrap address is what the ClickHouse side uses inside the
cluster. `http://kafbat-kafka-ui.kafbat.svc.cluster.local` is Kafbat UI, its
own Application in `apps/kafbat`: topics, messages, consumer groups and
their lag, which is the easiest way to watch the ClickHouse consumer keep
up. It is separate so it syncs and upgrades on its own; it only knows the
bootstrap address. [docs/kafka-to-clickhouse.md](docs/kafka-to-clickhouse.md)
walks through producing to the topic and consuming it into a ClickHouse
table with the Kafka engine and a materialized view.

## Plex

`http://192.168.1.241:32400/web`, from `apps/plex`: Plex Media Server,
moved off the Synology on 2026-10-21. It runs on gene, pinned by nodeSelector, because
gene's i7-1185G7 has an Iris Xe and Plex's Linux hardware transcoding is
built around Intel Quick Sync (tina's UHD 630 would also do; louise's
Radeon only half works with Plex). `/dev/dri` is a hostPath and the
container is privileged, the only way a container may open a device node
without a device plugin. The library stays on the Synology, mounted
read-only over NFS at the same path it had there, so the restored
database's folder paths still resolve. Plex's own state (`/config`) is a
Longhorn volume. One Service, a MetalLB address on 32400 at a fixed IP,
which `ADVERTISE_IP` names so clients connect to it rather than the pod
IP. Not on the tailnet, on purpose: away from home, Plex's own Remote
Access is the way in.

Before the first sync, three things by hand, in this order. Argo will
adopt the PVCs it finds already there.

1. **NFS on the Synology.** Control Panel, File Services, NFS on; then
   the media shared folder, Edit, NFS Permissions: one rule per node
   (192.168.1.187, .62, .179), read-only, squash "map all users to
   admin" or no mapping with a UID that can read the files. Note the
   export path (`/volume1/<share>`) and put it, the NAS address and the
   UID/GID into the `TODO`s in `apps/plex/manifests/`. Then stop Plex
   in Package Center so the database is quiet while it is copied.

2. **Restore the config volume.** The Plex package keeps its state at
   `/volume1/PlexMediaServer/AppData/Plex Media Server`, readable only
   by root. `sudo` over SSH needs a terminal, and a terminal mangles a
   streamed tar, so the copy goes in two hops: the NAS tars it into the
   media share (`Cache` and `Logs` skipped, they are large and rebuilt),
   and a helper pod on gene, mounting both volumes, unpacks it straight
   off NFS. Nothing passes through the Mac.

   ```bash
   ssh -t angloyna@192.168.1.158 'sudo tar -C "/volume1/PlexMediaServer/AppData/Plex Media Server" \
     --exclude=./Cache --exclude=./Logs -cf /volume1/plex_media/plex-config.tar . && ls -lh /volume1/plex_media/plex-config.tar'
   ```

   Then the claims and the helper:

   ```bash
   kubectl create namespace plex
   kubectl apply -n plex -f apps/plex/manifests/storage.yaml
   cat <<'YAML' | kubectl apply -n plex -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: plex-restore
   spec:
     nodeSelector:
       kubernetes.io/hostname: gene
     restartPolicy: Never
     containers:
       - name: shell
         image: alpine:3.22
         command: ["sleep", "infinity"]
         volumeMounts:
           - name: config
             mountPath: /config
           - name: media
             mountPath: /media
             readOnly: true
     volumes:
       - name: config
         persistentVolumeClaim:
           claimName: plex-config
       - name: media
         persistentVolumeClaim:
           claimName: plex-media
           readOnly: true
   YAML
   kubectl wait -n plex --for=condition=Ready pod/plex-restore --timeout=5m
   kubectl exec -n plex plex-restore -- sh -c '
     DST="/config/Library/Application Support/Plex Media Server"
     mkdir -p "$DST" && tar -xf /media/plex-config.tar -C "$DST" \
       && chown -R 1000:1000 /config && du -sh /config'
   kubectl delete pod -n plex plex-restore
   ssh -t angloyna@192.168.1.158 'sudo rm /volume1/plex_media/plex-config.tar'
   ```

   The chown matches `PUID`/`PGID` in the Deployment. The last line
   removes the tar from the share so Plex does not see it as media.

3. **Push.** Argo creates the Deployment and Services; the pod starts on
   the restored volume as the same server, already claimed, with its
   libraries, watch history and users. In Plex's settings afterwards:
   Transcoder, tick hardware transcoding and HDR tone mapping (the
   Iris Xe is listed); Network, LAN Networks `192.168.1.0/24`, and
   check Remote Access reports reachable. Force a transcode from each
   kind of client the household uses before uninstalling Plex from the
   Synology; keep its data directory until then.

Moving to tina is the nodeSelector and nothing else: the Longhorn volume
attaches wherever the pod lands, and tina has Quick Sync too.

## Gotchas

**Nothing is pinned to a node any more.** Earlier values files pinned flow and
zot to `tina` citing "louise network flakiness". That was a misdiagnosis — the
real cause was a pending kernel upgrade leaving the running kernel's modules
mismatched, which crash-looped `k3s-agent` until a reboot. Pinning zot was
actively harmful while flow pulled its images from it: a registry pinned to
the same node as everything else means a node reboot leaves every pod in
`ImagePullBackOff`.

**Both ArgoCD instances are pinned to `tina`** (`bootstrap/*/values.yaml`),
so neither is available while `tina` reboots. Drain first so workloads
migrate while the API server is still up:

```bash
kubectl drain tina --ignore-daemonsets --delete-emptydir-data --timeout=300s
# reboot, then:
kubectl uncordon tina
```

**Image pulls by the node cannot resolve cluster names.** The old zot chart
addressed the registry by ClusterIP because image pulls happen in the
node's network namespace and never reach CoreDNS, so `*.svc.cluster.local`
cannot resolve for them. Still true for anything that pulls from an
in-cluster registry directly; a process inside a pod (the CI runners'
dockerd, say) resolves it fine. zot itself lives in flow-infrastructure now.
