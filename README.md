# GCP Migration — core-platform

Everything for the OCI → GCP move lives here. Detailed decisions, CIDR plan,
and the full remaining-inputs list are in `terraform/README.md` — this file
is just the map and the current snapshot.

## Layout
 
```
GCP/
├── terraform/      Infrastructure-as-code. See terraform/README.md for
│                   the full decision log, CIDR plan, and module map.
├── ci-cd/           Adapted GitHub Actions workflow — dual-push variant.
│                   Builds once, pushes to BOTH OCIR and Artifact Registry,
│                   so OKE and GKE can run side-by-side during validation.
│                   Final home is the separate `github-workflows` repo — MUST
│                   keep the exact filename `build-push-update-tag-reusable.yml`,
│                   since every service repo's caller references it by name.
│                   Set `GCP_WORKLOAD_IDENTITY_PROVIDER`/`GCP_SERVICE_ACCOUNT`
│                   once at the GitHub **Organization** level — every caller
│                   uses `secrets: inherit`, so no per-repo secret needed.
│                   Values come from `terraform output` after `apply` — see
│                   below. Drop the OCI login/push lines only once OKE is
│                   fully decommissioned — until then, both are required.
│                   Which registry a *cluster* pulls from is separate from
│                   this file entirely — that's each service's own
│                   `image.repository` in its Helm values, not a CI decision.
└── scripts/         Discovery, preflight, and one-time image migration
                    tooling. All read-only except copy-images-to-ar.sh,
                    which only pushes to Artifact Registry..
```

## Status, as of this write-up

**Decided:** GKE Standard (not Autopilot). Gateway API (not Traefik) for
ingress — confirmed safe, Traefik Hub's premium features confirmed unused.
Staying on GoDaddy for DNS. Fresh project `core-platform-prod-dr` for the
database — the old Doha-based `core-platform-dr-db` is **not** adopted, kept
running during transition, its data possibly reused for the initial sync.
3 workload-relevant GCP projects (network host + workload + db), non-prod
deferred, for blast-radius isolation.

**Written and ready to `apply` the moment billing works:** everything —
`bootstrap/`, `modules/project`, `modules/network`, `modules/iam-github-wif`,
`modules/cloudsql` (real creation, not a reference), `modules/gke`,
`modules/lb`, all wired together in `envs/prod/`. Billing is confirmed
active on the CNTXT account.

**Helm — done:** the `service` chart (forked, one-line registry change),
all 27 services' real values copied byte-for-byte, the `gateway-routes`
chart with all 9 confirmed hostnames across 4 correctly-grouped certs, the
`core-platform-gcp` ApplicationSet fork (Slack channel decoupled from
`environment`, ingress/regcred removed since Gateway API and Workload
Identity supersede them).

**Not yet written:** ArgoCD's own GKE install, RabbitMQ (Cluster Operator +
default-vhost Permission — fully understood now, just not built), Redis,
observability (Loki/Prometheus/Grafana/Promtail), cert-manager for GKE,
PVC data migration mechanism, DNS cutover plan.

**Still open, needs a direct answer:**
- Egress proxy or not — still the single biggest lever on cutover timeline,
  given partner IP whitelisting's 4–12 week lead time per partner.
- Security remediation on the plaintext-secret finding — confirmed staying
  as-is per explicit instruction, not being changed.
- Whether the suspended `mysqldump-backup` CronJob gets revived, or DMS
  replication is accepted as the only continuity mechanism going forward.

## Once GCP billing is active (already true)

```bash
cd terraform/bootstrap && terraform init && terraform apply
# uncomment the gcs backend, then:
terraform init -migrate-state

cd ../envs/prod
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init && terraform plan && terraform apply
```
