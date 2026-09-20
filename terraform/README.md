# core-platform — GCP Landing Zone (Terraform)

Target region: **me-central2** (Dammam, KSA) — required for NCA data residency.

**Scope: PRODUCTION ONLY.** Dev/stg (OKE cluster `c4k7ywsxhwa`) stays on OCI —
explicitly decided, not a sequencing choice. `core-platform-nonprod` below is
listed for completeness of the CIDR reservation only; it is not being built.

Greenfield. The existing `Infrastructure/terraform` OCI code is not portable
(every resource is `oci_*`), but the per-env-stack-calling-shared-modules shape
is kept deliberately so the layout stays familiar.

## Project layout 

| Project | Purpose |
|---|---|
| `core-platform-tfstate` | GCS state bucket only. Never holds workloads, so a workload problem can't lock you out of your own state. |
| `core-platform-network-prod` | Shared VPC **host** for production. Owns the VPC, subnets, Cloud NAT, static egress IPs. Created fresh by this stack. |
| `core-platform-workload-prod` | Shared VPC **service** project. GKE, Artifact Registry, GitHub Actions WIF for prod. Created fresh by this stack. |
| `core-platform-database-dr-prod` | Fresh project, created by this stack. Holds the production Cloud SQL instance — regional HA from day one, unlike the OCI source. Attached to the Shared VPC so `workload-prod`'s GKE reaches it privately. The old Doha-based `core-platform-dr-db` stays running separately during transition; not adopted or referenced here. |
| `core-platform-nonprod` | **Out of scope** — dev + stg stay on OCI. CIDR reserved below anyway, in case this changes; costs nothing to leave unused. |

**Why GKE lives in `workload-prod`, not inside `core-platform-database-dr-prod` itself:**
Same reasoning as always — project boundaries are IAM/billing/quota; reaching
the database privately is a Shared VPC + Private Service Access question,
and `modules/network` already handles that. `core-platform-database-dr-prod` is attached to
the Shared VPC purely so GKE can reach its private IP, without needing to
live in the same project.

**Resolved** — decommission timing for the old `core-platform-dr-db` (Doha): leave
it running during transition, and reuse its already-replicated data for the
initial sync into the new instance if practical, rather than pulling fresh
from OCI a second time. Needs the exact binlog position at dump time so the
new DMS job's ongoing replication picks up cleanly — handle this when
actually standing up the new pipeline.

## CIDR plan

Chosen to avoid every range currently live on OCI, so a VPN between clouds
works without NAT translation.

### In use on OCI — do not reuse

| Range | Purpose |
|---|---|
| `10.10.0.0/16` | prod VCN (`core-platform-vcn-stg`, compartment `core-platform-prod`) |
| `10.0.0.0/16`  | `oke-vcn-quick-core-platform-dev-cluster-bd0a28972` (dev/stg) |
| `10.0.0.0/16`  | `oke-vcn-quick-core-platform-dev-cluster-625e6ef19` (dev/stg) — **overlaps the above**, one is dead |
| `10.20.0.0/16` | `core-platform-vcn` (dev/stg) |
| `10.244.0.0/16` | OKE prod pod CIDR |
| `10.96.0.0/16` | OKE prod service CIDR |

One of the two `10.0.0.0/16` VCNs is the `LPG-PROD` peer; they cannot both be,
since identical ranges can't peer into the same VCN. Both are OCI "quick
create" wizard artifacts. Identify which the dev cluster actually uses before
decommissioning either.

Dev/stg pod and service CIDRs are not yet captured — if those clusters were
built by the quick-create wizard they will be on OKE defaults, likely the same
`10.244.0.0/16` and `10.96.0.0/16` as prod.

### GCP allocation

Deliberately placed in the `10.60.0.0` – `10.91.255.255` band, which is clear
of every OCI range above with wide margin on both sides. Only the `prod`
column is being built right now — stg/dev columns are reserved so nothing
collides whenever those environments do move, not because they're out of
scope permanently.

| Purpose | prod (built now) | stg (reserved) | dev (reserved) |
|---|---|---|---|
| Node subnet (primary) | `10.60.0.0/20` | `10.61.0.0/20` | `10.62.0.0/20` |
| Pods (secondary)      | `10.64.0.0/14` | `10.72.0.0/14` | `10.80.0.0/14` |
| Services (secondary)  | `10.68.0.0/20` | `10.76.0.0/20` | `10.84.0.0/20` |
| GKE control plane (`/28`) | `172.16.10.0/28` | `172.16.11.0/28` | `172.16.12.0/28` |

Shared, prod VPC:

| Purpose | Range |
|---|---|
| Proxy-only subnet (regional Gateway) | `10.63.0.0/24` |
| Private Service Access (Cloud SQL) | `10.88.0.0/16` |
| Reserved / future growth | `10.92.0.0/16` |

> **Revision note.** An earlier draft used `10.20.0.0/20` for prod nodes. That
> collides with `core-platform-vcn` (`10.20.0.0/16`) in `core-platform-dev-stg`. Anything
> in `10.0.x`, `10.10.x`, `10.20.x`, `10.96.x`, or `10.244.x` is unusable.

Notes:
- Pod ranges are `/14` because GKE pre-allocates a `/24` per node by default —
  a `/20` would cap you at ~16 nodes.
- Control-plane ranges sit in `172.16.x` on purpose: they must be `/28`, must
  not overlap anything, and keeping them out of `10.x` removes a whole class
  of future collision.
- Proxy-only subnet is mandatory for a *regional* external Gateway. Confirmed
  as the right choice — see Decisions below.

## Bootstrap order

```bash
# 0. Prerequisites: CNTXT billing account active, org/folder IDs known.
#    Verify every service you need exists in me-central2 before starting:
#    https://cloud.google.com/about/locations

# 1. State bucket (local state, one time only, then migrate)
cd bootstrap
terraform init && terraform apply
terraform init -migrate-state    # after uncommenting the gcs backend

# 2. Production landing zone
cd ../envs/prod
cp terraform.tfvars.example terraform.tfvars   # fill in real IDs
terraform init && terraform plan
```

## Module map — OCI to GCP

| Existing OCI module | GCP module | Note |
|---|---|---|
| `network` + `new_network` | `network` | Collapse the duplicate; `new_network` was an abandoned rewrite |
| `oke` | `gke` *(TODO)* | Standard, not Autopilot — confirmed. Also enables the Gateway API feature flag on the cluster resource. |
| `mysql` | `cloudsql` | **Real creation module.** Fresh instance in `core-platform-database-dr-prod`, regional HA enabled, private IP via PSA. Confirmed decision: not adopting the existing Doha-based `core-platform-dr-db` — see Decisions below. |
| `vaults` + `kms_keys` + `secrets` | `secrets` *(TODO)* | Secret Manager covers all three |
| `loadbalancer` + `firewall` (WAF) | `lb` *(TODO)* | Gateway API confirmed. Regional Gateway static IP, Cloud Armor policy, Certificate Manager resources — see Certificate strategy below. The `Gateway`/`HTTPRoute` k8s objects themselves are GitOps, not Terraform. |
| `static_ip` | `network` | Cloud NAT static IPs — 4 reserved, see below |
| `compartments` | `project` | Compartments to projects: different model, not a rename |
| `identity/*` + `policy` | `iam-github-wif` | Plus WIF, replacing OCIR auth tokens |
| `devops/*` (9 modules) | — | Dropped: you use GitHub Actions + ArgoCD, not OCI DevOps |
| `domains` | — | **Stay on GoDaddy — confirmed.** No Cloud DNS module needed. |
| `buckets` | `gcs` *(TODO)* | Trivial |

`gke`, `secrets`, and `lb` are still not written — their sizing and config
depend on cluster discovery data the OCI outage is currently blocking.

## Why four NAT egress IPs

OCI gives you exactly one: `144.24.209.5` (RESERVED, confirmed as the only
address prod workloads egress from — all four OKE nodes have no public IP).
Partners whitelist it.

That address does **not** come with you. On GCP you get new addresses, which
means a change request with every IP-gated counterparty — and in Saudi fintech
those routinely take 4–12 weeks each.

So reserve **four** static IPs up front and get all four whitelisted in the
*same* change request. Reasons:
1. Cloud NAT allocates source ports per IP; a single address can exhaust ports
   under connection-heavy load, failing in ways that look like partner-side
   rejections.
2. Adding an IP later means repeating every counterparty's approval cycle.

Ask each partner whether they can whitelist **additively** (keep the OCI IP
while adding the GCP ones) rather than swapping. Additive means zero-downtime
cutover. Swap means a hard simultaneous switch across all partners at once.

## Decisions

**Resolved:**
- **GKE Standard**, not Autopilot.
- **GKE Gateway API**, not Traefik. Consequence: every current `IngressRoute`
  and `Middleware` needs translating to `HTTPRoute` once the discovery data
  (`k8s/traefik-crds.yaml`, `k8s/ingress-all.yaml`) is in hand — not a values
  tweak, a real rewrite, though a mechanical one.
- **Stay on GoDaddy.** Earlier guidance in this doc said wildcard certs would
  force a move off GoDaddy — true for cert-manager's ACME DNS-01 flow, which
  has no GoDaddy solver. No longer the binding constraint: see Certificate
  strategy below.
- **Fresh project for the database, confirmed.** Not adopting the existing
  Doha-based `core-platform-dr-db` (no regional HA, network not controlled by this
  stack). `core-platform-database-dr-prod` gets created by this Terraform, with a new DMS
  pipeline into it, in Dammam. The old Doha instance stays running during
  transition — its already-replicated data may get reused for the initial
  sync into the new instance rather than pulling fresh from OCI again, if
  the binlog-position handoff can be done cleanly.

**Certificate strategy — a consequence of Gateway API, not an independent
choice:** A **regional** Gateway is the natural fit (matches single-region
me-central2, keeps TLS termination inside the NCA-residency boundary the way
a global anycast Gateway wouldn't necessarily). Google's classic managed
certificates (the `ManagedCertificate` annotation people usually mean by
"Google-managed cert") are incompatible with regional Gateways outright — not
a preference, a hard constraint. The fit here is **Certificate Manager**
instead — a distinct GCP product from both that and from cert-manager. Its
DNS-authorization mode supports wildcards via a single one-time DNS record at
the parent domain, which GoDaddy handles fine, no ACME DNS-01 solver
integration needed. Load-balancer-authorization mode is simpler again but
doesn't support wildcards. Which mode depends on whether any current hostname
is wildcard-based — answered by `k8s/hostnames.txt` once discovery runs.

**Recommended, still reversible — 3 projects (workload-prod + network-prod +
nonprod), not 1:** see the concrete breakdown in chat. Nothing is applied yet,
so this is cheap to change; say so if you'd rather collapse it.

**Still open:**
- **Egress proxy?** Keeping one small OCI VM to retain `144.24.209.5`, with
  GKE routing partner-bound traffic through it over VPN, decouples the whole
  migration from partner approval timelines. Costs one instance plus a
  Dammam→Jeddah hop on partner calls only. Still unanswered — decide before
  `network` is finalised.
- Building the actual DMS pipeline into `core-platform-database-dr-prod` (connection
  profiles + migration job) — decided, not yet started.
- MySQL data size confirmed (~37GB across all schemas before the planned
  `alpaca_api_log` trim) — informs how long the new initial sync takes.

## Newly discovered scope — from the Infrastructure repo directory tree

Not previously known, found by walking `helm-releases/`:

- **MongoDB** (`psmdb/` — Percona's operator), **RabbitMQ** (`rabbitmq/`), **Redis**
  (`redis/`) — each has `dev/` and `stg/` folders only, **no visible `prod/`**.
  **RabbitMQ confirmed production**: `rabbitmq.core-platform.com` resolves to
  `79.72.5.115`, the confirmed production LB IP — despite living in the `stg`
  folder. This means the earlier two-node bootstrap deadlock
  (`RABBITMQ_FORCE_BOOT=yes`) was a production incident, not staging. Treat
  RabbitMQ as high-risk for the migration given its documented failure mode.
  MongoDB and Redis remain unconfirmed — no ingress/hostname to check against,
  needs a direct answer rather than file archaeology.
- **External Secrets Operator is already the live secrets mechanism**
  (`external-secrets/` folder exists and is in use). Confirmed: production's
  `ClusterSecretStore` uses provider `oracle`, vault
  `ocid1.vault.oc1.me-jeddah-1.djrm3vzeaadiy.abvgkljrql2r2l5tqu7aag775oik2ncvnqv5nydmqqcmqyqfvtervmb2qsza`,
  authenticated via a static API-key credential
  (`external-secrets-oci-credentials` secret: user OCID, tenancy OCID,
  private key, fingerprint). For GCP: swap the `ClusterSecretStore` provider
  to GCP Secret Manager. Worth doing better than a straight swap — GCP's ESO
  provider supports Workload Identity natively, so GKE wouldn't need any
  stored credential at all, unlike the OCI API-key pattern today.
- **ArgoCD naming confusion, resolved differently than first guessed.**
  `helm-releases/argocd/*.values.yaml` are plain `argo-cd` Helm chart values
  (installing ArgoCD itself), not per-service Application lists — confirmed
  by the `server.ingress.hosts` field. `core-platform-stg.values.yaml` sets
  `cd.core-platform.com`, confirmed as the real production ArgoCD. Where the actual
  per-service Applications are declared is still unknown — possibly an
  ApplicationSet with a git-generator glob (which would explain how the 29
  zero-byte scaffold files earlier could silently register as broken
  Applications). Real answer needs `kubectl get applications.argoproj.io -A
  -o yaml`, still blocked on cluster reachability.
- **Two observability stacks, not one.** New Relic (SaaS) *and* a self-hosted
  `kube-promethues-stack` (Prometheus) + `loki` + `tempo` + `promtail` +
  `opentelemetry-operator`. The self-hosted stack has its own PVC-backed data
  needing a migration decision, independent of New Relic re-instrumentation.
- **ArgoCD naming likely repeats the OCI "-stg means prod" pattern.**
  `helm-releases/argocd/core-platform-stg.values.yaml` configures ingress host
  `cd.core-platform.com` — confirmed as the real production ArgoCD. No `-prod` file
  exists at all. Working theory: `core-platform-stg.values.yaml` is the ArgoCD
  instance on `ctphymu27ra` (prod cluster), `core-platform-dev.values.yaml` is the
  one on `c4k7ywsxhwa` (dev+stg cluster) — unconfirmed, matters for how ArgoCD
  gets replicated on GKE.
- **ArgoCD mechanism, fully resolved** (from the actual repo, not inference).
  `helm-charts/core-platform/templates/applicationset.yaml` is a single
  `ApplicationSet` per ArgoCD instance, using a git **directory** generator on
  `helm-releases/core-platform/*` — every subdirectory there auto-becomes a live,
  auto-synced Application (`selfHeal: true, prune: true`). Value-file merge
  order, confirmed: `defaults.values.yaml` → `defaults-<env>.values.yaml` →
  `<service>/values.yaml` → `<service>/<env>.yaml`, later wins.
  `destination.server: https://kubernetes.default.svc` means each ArgoCD
  instance only ever deploys to its own cluster — confirms the two-instance
  model (one per cluster) cleanly. Still unknown: where `environment`/
  `organization` get set for the live install (chart defaults are blank) —
  likely a manual `helm install --set` outside git.
- **MongoDB/Redis clarified, probably not what was first suspected.**
  `helm-charts/core-platform/Chart.yaml` conditionally bundles Bitnami
  `redis`/`mongodb`/`mysql` **only for ephemeral feature-branch preview
  environments** (`featureBranchEnv.enabled`). The separate
  `helm-releases/psmdb/` (Percona operator) and `helm-releases/redis/` folders
  may be a second, more persistent deployment — unconfirmed whether these are
  the same thing or two different setups.
- **stg/prod configs may be near-identical.** Diffing `admin-frontend`'s
  `stg.yaml-old-prod` backup against current `stg.yaml` and `prod.yaml` shows
  differences only in image tag (and one autoscaling block vs prod). Either
  deliberate stg-mirrors-prod design, or stg was cloned from prod once and
  never meaningfully diverged since — unconfirmed which.
- **Security finding, independent of migration**: `old-infra/dev/secrets/`
  contains a file named `! PRIVATE KEY INFO !.txt` (cert: `STAR_madkol_co`)
  and `oci/oci-config.txt` (real OCI CLI config structure — tenancy/user/
  fingerprint/key_file fields). Contents deliberately not read. Needs
  personal verification: if either is still live, rotate and purge from git
  history properly (`git-filter-repo`/BFG, not a plain `rm`).
- **362 MB of accidentally-committed Terraform provider binaries** found in
  `terraform/dev/.terraform/providers/` — should be gitignored, never
  committed. Two different OCI providers cached (`hashicorp/oci` v7.29.0,
  `oracle/oci` v4.69.0) — worth confirming which one each stack actually uses.
- **RakizaPropTech and Azure confirmed fully out of scope** — not partially,
  entirely dead.
- **Full production secret inventory confirmed, 29 secrets, `core-platform-stg-vault`
  (in `core-platform-prod` — same "-stg means prod" pattern, now confirmed at the
  vault level too).** Includes `DB_PASSWORD`, `MONGO_DB_URI`, `REDIS_URI`,
  `AMQP_URI` (confirms all three datastores are genuinely used, consistent
  with RabbitMQ/MongoDB findings above), `ANB_CLIENT_ID`/`ANB_CLIENT_SECRET`
  (Arab National Bank — almost certainly what `core-platform-ANB-NGW-stg` was built
  for; **ANB should be prioritized in the partner IP-whitelist list**),
  `DOWJONES_RISK_AND_COMPLIANCE_PASSWORD`/`DOWJONES_SCREENING_AND_MONITORING_PASSWORD`
  (AML/compliance screening), `CUSTODIAN_PASSWORD`, `ALPACA_API_KEY`/`SECRET`,
  `TWILIO_AUTH_TOKEN`, `SENDGRID_API_KEY`, `YAHOO_FINANCE_API_KEY`, and CI/infra
  secrets (`OCI_REGISTRY_SECRET`, `argocd-github-infrastructure-repo`,
  `argocd-notifications-secret`, `GITHUB_TOKEN`). A second, separate
  `apple-pay-certificate` vault exists (created Aug 2025) alongside an older
  same-named secret in `core-platform-stg-vault` (Aug 2023) — the newer dedicated
  vault is likely the live one; unconfirmed which is authoritative.
- **MongoDB and Redis topology, fully confirmed via live kubectl — not
  inference.** `psmdb` and `redis` live under `helm-releases/{psmdb,redis}/`
  at the repo root (not `helm-releases/core-platform/`), so they fall outside the
  ApplicationSet's directory-generator glob entirely — confirmed separate,
  individually-installed Helm releases, not part of the auto-discovery
  mechanism. **MongoDB: production-only.** `core-platform-psmdb-db-rs0-0/1/2`, a
  genuine 3-node replica set on `ctphymu27ra`, 50Gi each, 3y197d old. Zero
  psmdb pods/PVCs exist on the dev/stg cluster despite `psmdb/dev` and
  `psmdb/stg` folders existing in the repo — nothing's actually deployed from
  them. **Redis: seven separate instances, not one** — `core-platform-redis-master-0/1`
  (prod, 2 nodes), `stg-redis-master`+`stg-redis-replicas` (dev/stg, 4 nodes,
  correctly named), a dev-tier instance, and three dedicated single-node
  instances per feature (`core-platform-icon-tooltip`, `core-platform-thirft-plan-flow`,
  `core-platform-thrift-plan`). `argocd-redis` on both clusters is ArgoCD's own
  bundled cache, not application data — excluded, comes back automatically
  when ArgoCD is reinstalled on GKE.
- **ExternalSecrets confirmed mapped across essentially every service** — one
  `<service>-service-env-secret` per service, all from
  `oci-vault-cluster-secret-store`. Notable extras: `media-service-bucket-oci-creds`,
  `payment-service-apple-pay-certificate` AND `webhook-service-apple-pay-certificate`
  (both need it), `oci-regcred` (image pull secret — may not be needed at all
  on GKE if Workload Identity grants `roles/artifactregistry.reader`
  directly), and a `backup` namespace with its own `backup-upload-secret`.
- **Full `helm list -A` on prod (`ctphymu27ra`), several things resolved at
  once.** Two releases of the identical `core-platform-0.1.0` chart exist — one in
  the `argocd` namespace, one in the `core-platform` namespace, 13 minutes apart —
  almost certainly how `environment=prod`/`organization=core-platform` actually get
  set (the chart's own defaults are blank). Needs `helm get values core-platform -n
  argocd` and `-n core-platform` to confirm exactly. **`traefik` (controller) and
  `traefik-routes` (per-service routes, namespace `core-platform`) are two separate
  Helm releases** — `traefik-routes` lives at `helm-releases/traefik-routes/`,
  outside `helm-releases/core-platform/*`, so like `redis`/`psmdb` it's NOT covered
  by the ApplicationSet directory generator. This is the actual target for
  the Gateway API rewrite. **Observability gap**: only `opentelemetry-operator`
  and `tempo` appear — no `kube-promethues-stack`, `loki`, or `promtail` on
  this cluster despite all five existing in the repo. Unconfirmed whether
  they're on the dev/stg cluster instead, raw-kubectl-managed (same pattern as
  redis/psmdb), or never actually deployed to prod at all. **New discovery:
  Twingate** (`twingate-sincere-chihuahua`, namespace `default`) — a Zero
  Trust remote-access connector, never mentioned before this. May be the real
  mechanism for reaching the private cluster, alongside or instead of the VPN
  instance (`144.24.216.181`) found earlier. If actively used, GCP's network
  design should include a Twingate connector rather than assuming a
  traditional VPN gateway.
- **Correction to the item above**: Loki, Prometheus, and Promtail ARE alive
  and running on production — `helm list` didn't show them because, like
  Redis/PSMDB, they're not Helm-managed on this cluster (raw manifests or
  ArgoCD-directory-sourced), not because they're dead. Confirmed via
  `kubectl get statefulsets -A`: `loki-read`/`loki-write` (3/3 each),
  `prometheus-monitoring-kube-prometheus`, `alertmanager-monitoring-kube-prometheus`,
  all 2-3+ years old and actively running. **Tempo is the one that's actually
  inactive** — `tempo-ingester`/`tempo-memcached` StatefulSets exist but show
  `0/0` replicas. OTel auto-instrumentation is genuinely active (5% trace
  sampling, real OTLP export config in `instrumentation.yaml`), so traces are
  being generated with nowhere to land. Unconfirmed whether this is a known,
  accepted gap or an oversight.
- **The `core-platform` chart (both releases, `argocd` and `core-platform` namespaces,
  byte-identical values) does far more than the ApplicationSet.** Full
  template list: `applicationset.yaml`, `ingress.yaml`, `instrumentation.yaml`,
  `regcred.yaml`, `vhost.yml`, plus a feature-branch-only MySQL restore job.
  **`vhost.yml` resolves the RabbitMQ mechanism completely** — creates a
  `Vhost`+`Permission` via the RabbitMQ Cluster Operator
  (`rabbitmqClusterReference: name: core-platform`), one vhost per environment
  (`environment: prod` → vhost `prod`) inside a shared operator-managed
  cluster — matches the `core-platform-server` StatefulSet in `rabbitmq-system`
  exactly. Needs the operator + this Vhost/Permission pattern reproduced on
  GKE, not a chart port. **`ingress.yaml` renders `ingressClassName: nginx`**
  for `admin.core-platform.com`/`api.core-platform.com`/`app.core-platform.com`/`core-platform.com` —
  not Traefik. Unconfirmed whether `ingress-nginx` is a live second ingress
  controller alongside Traefik, which would mean two mechanisms to migrate,
  not one. **`regcred.yaml`** confirms `oci-regcred` pulls from vault key
  `OCI_REGISTRY_SECRET`. The feature-branch MySQL restore job reveals a
  working backup pipeline already dumps production MySQL to
  `s3://backup-downloader-app/core-platform-dump.sql` via OCI's S3-compatible
  endpoint — schedule unconfirmed, but a ready-made artifact if so.
  **Traefik Hub CRDs found** (`hub.traefik.io` — API catalogs, rate limiting,
  portal auth, subscriptions), dated to the same day as the recent Traefik
  version upgrade. This is a commercial add-on, not standard Traefik — if
  actually configured and used, the Gateway API decision needs revisiting,
  since Gateway API has no equivalent. Unconfirmed whether it's genuinely in
  use or enabled incidentally.
- **Concrete facts confirmed from the values dump**: `DB_HOST: 10.10.30.111`
  (production MySQL's private IP). Confirmed hostnames:
  `admin.core-platform.com`, `api.core-platform.com`, `app.core-platform.com`, `core-platform.com`.
- **Full production deployment/PVC inventory, from `kubectl get deployments,pods,pvc,pv -A`.**
  `newwebsite-service` is scaled to `0/0` — exists but not currently live,
  despite being in the confirmed service list. **Grafana confirmed running**
  (`monitoring-grafana`, 3/3, 3y171d) — the dashboard layer for
  Prometheus+Loki. **Tempo is completely dead, not just partially** —
  `tempo-compactor`/`distributor`/`querier`/`query-frontend` all `0/0`,
  confirming the ingester/memcached finding extends to every Tempo
  component. Do not reproduce Tempo on GKE. **Velero found, also `0/0`** — a
  cluster backup/DR tool that exists but isn't running; unconfirmed whether
  ever actually configured. **Twingate confirmed genuinely active** — 2
  running replicas, 2y317d old. **Full PVC inventory**: 9 volumes (450Gi) for
  monitoring (alertmanager, loki-read×3, loki-write×3, prometheus×2), 3×50Gi
  for psmdb, 3×50Gi for rabbitmq, 2×50Gi for redis — 17 volumes, 850Gi
  allocated total (actual used space likely far less, as with MongoDB's
  50Gi-allocated-but-5.85GB-used pattern). All on `oci-bv`/`oci-bv-xfs`
  (OCI Block Volume) — GKE equivalent is Persistent Disk, but the bytes
  themselves still need actual copying, not just PVC recreation.
- **Security remediation still open**: rotation and git-history purge for
  the plaintext secrets found in `payment`/`auth`/`ledger`/`webhook`
  `prod.yaml` — status pending. A fuller pattern-scan across `dev.yaml`/
  `stg.yaml` too (not just `prod.yaml`) is worth completing regardless of
  migration scope, since the exposure exists in git history either way.
- **MongoDB decision: Atlas, confirmed.** 5.85GB real data — small enough for
  a one-time dump+restore in a single short window rather than a prolonged
  live-sync tool, minimizing how long OCI reachability matters during the
  actual cutover. Atlas region choice should be decided alongside the
  Doha/Dammam MySQL question with Saad, not separately.

- `traefik-routes/{dev,stg,prod}` is exactly where the Gateway API HTTPRoute
  translation work happens once Gateway API discovery data is in hand.



### Blocked on the OCI outage clearing + `oci-discovery.sh` running

| Module | Needs | Source |
|---|---|---|
| `gke` | ~~Node shape, OCPU/memory, current node count per pool~~ **confirmed**: `VM.Standard.E3.Flex`, 4 OCPU / 16GB, 4 nodes, single AD | `oci ce node-pool list` — done, via console |
| `gke` | ~~Current Kubernetes version~~ **confirmed**: `v1.32.10` — flagged "not supported" by OKE, worth escalating independent of migration | `oci ce cluster list` — done, via console |
| `gke` | Per-service CPU/memory requests + limits, for node pool sizing | `k8s/resource-requests.tsv` |
| `gke` | Any DaemonSets needing privileged/hostPath access | `k8s/daemonsets.yaml` — New Relic infra agent already known |
| `gke` | Whether RabbitMQ's StatefulSet wants a dedicated, tainted node pool | Given its prior two-node bootstrap deadlock, worth considering |
| `cloudsql` | Building the actual DMS pipeline into the new `core-platform-database-dr-prod` instance | Console/gcloud DMS work, separate from Terraform |
| `secrets` | Full secret name/key inventory (never values) | `secrets/k8s-secret-inventory.tsv` |
| `secrets` | Any secrets sourced from OCI Vault | `oci vault secret list` |
| `secrets` | Sync mechanism: External Secrets Operator vs Secret Manager CSI driver vs manual | Architecture choice, not blocked by data |
| `lb` | Every current hostname, and which (if any) are wildcard-based | `k8s/hostnames.txt` — decides Certificate Manager DNS-auth vs LB-auth mode |
| `lb` | Current WAF rules, if replicating to Cloud Armor | `oci waf web-app-firewall-policy get` |

## Consolidated status checklist (refreshed, latest)

**Resolved, no longer open**: node shape/count/K8s version, full
deployment/pod/PVC inventory, ArgoCD mechanism, RabbitMQ mechanism, MongoDB
size+decision (Atlas), secrets backend+inventory, CI/CD registry swap,
ingress (Traefik only, confirmed live), observability (Loki/Prometheus/Grafana
live; Tempo fully dead), DR network path (DRG + 2 IPSec tunnels, already
built), MySQL DMS status (CDC running).

**Blocked on you / external parties, not on data**:
- Doha vs. Dammam residency (Saad) — decide MySQL *and* Atlas region together.
- CNTXT billing IAM grant (Saad/CNTXT).
- Secret rotation + git-history purge — pending.
- Traefik Hub actual usage — blocks finalizing Gateway API vs. keep Traefik.
- `core-platform_dev` database naming — genuinely prod, or a naming mix-up?
- Redis actual data size/usage — never measured, unlike MongoDB.
- `derayah/prod.yaml` client secret discrepancy — present dev/stg, absent prod.

**Pure decisions, answerable today**: Gateway API vs. keep Traefik (pending
Traefik Hub answer — resolved, Gateway API confirmed), egress proxy or not.

**Mechanical work, ready once inputs land**: `GCP/helm-releases/core-platform-gcp/`
with real per-service values (secrets externalized to ESO+Secret Manager,
not copied inline), `gke`/`secrets`/`lb` Terraform modules.

## What Terraform manages, vs what happens after `apply` (GitOps layer)

Terraform's boundary stops at "the cluster and its supporting infrastructure
exist." Everything running *inside* Kubernetes — CRDs, Helm releases,
ArgoCD's own Application objects — is applied by ArgoCD/Helm/kubectl, not
Terraform. This mirrors the current OCI setup exactly: the OCI Terraform only
ever created `oci_containerengine_cluster` + `oci_containerengine_node_pool`;
everything else — all 27 services, Traefik, cert-manager, ArgoCD itself —
comes from `helm-releases/` in the `Infrastructure` repo. The GCP side follows
the same split.

### A. Terraform-managed

| Layer | Resource | Status |
|---|---|---|
| State | GCS bucket, versioned | done — `bootstrap/` |
| Projects | `network-prod` + `workload-prod` + `core-platform-database-dr-prod`, all created fresh | done — `modules/project` |
| Network | VPC, node subnet + secondary ranges, proxy-only subnet | done — `modules/network` |
| Network | Cloud Router + Cloud NAT, 4 reserved static egress IPs | done |
| Network | PSA range for Cloud SQL private IP | done — `modules/network`, no peering needed since the database project attaches directly to the Shared VPC |
| Network | Firewall rules (health checks, proxy-only, internal, control-plane webhooks) | done |
| Registry | Artifact Registry repo + cleanup policy | done — in `workload-prod` |
| IAM | GitHub Actions WIF pool + provider + CI service account | done — in `workload-prod` |
| IAM | Cloud SQL access via Workload Identity, against `core-platform-database-dr-prod` | pending — wire up once GKE's service accounts exist |
| Compute | GKE cluster + node pool(s), Workload Identity, Gateway API flag | **pending** — needs node/version data above |
| Database | Cloud SQL instance, regional HA | done — `modules/cloudsql`, real creation |
| Secrets | Secret Manager containers + IAM bindings | **pending** — needs the secret inventory |
| Ingress | Regional Gateway static IP, Cloud Armor policy, Certificate Manager resources | **pending** — needs the hostname list |
| DNS | — | **not needed** — staying on GoDaddy |

### B. NOT Terraform — applied to the cluster after it exists

| Step | Tool | Notes |
|---|---|---|
| Install ArgoCD | Helm | Same as current OKE setup |
| Point ArgoCD at `Infrastructure` repo | ArgoCD | Same repo, same structure |
| Create `Gateway` + `HTTPRoute` objects | ArgoCD, via Helm | Translated from current `IngressRoute`/`Middleware` — a real rewrite, mechanical once the CRD export is in hand |
| Attach the Certificate Manager cert map to the Gateway | `networking.gke.io/certmap` annotation | Replaces cert-manager's role for ingress TLS |
| Install External Secrets Operator (if chosen) | Helm, via ArgoCD | Syncs Secret Manager into Kubernetes Secrets |
| Sync all 27 services | ArgoCD | Existing Helm charts — values files get a registry-path + Gateway-ingress + GKE-overrides pass, not a rewrite |
| PVC data migration | `rsync`/`rclone`/Job, per volume | Needs the PVC inventory from discovery |
| MySQL cutover | GCP DMS, new pipeline into `core-platform-database-dr-prod` | Not yet started — old Doha replica's data may be reused for the initial sync |
| DNS cutover | GoDaddy | Manual, per-hostname, last in the runbook |
| Partner IP re-whitelisting | Email/portal, per counterparty | Outside all tooling — the current critical path |
| New Relic re-instrumentation | Helm/Dockerfile injection, per service | Same patterns already established on OKE |
