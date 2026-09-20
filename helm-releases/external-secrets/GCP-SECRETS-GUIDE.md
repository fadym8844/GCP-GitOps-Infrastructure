# GCP Secret Manager — Definitive Guide
# What to create, what to skip, and why

## Direct answer: you only NEED 7 secrets in GCP Secret Manager

The ExternalSecret template in the service chart fetches ONLY what's in the
`envSecret` block of defaults.values.yaml. Confirmed by reading the actual
template (helm-charts/service/templates/env-secrets.yaml).

Those 7 keys are:
  - DB_PASSWORD
  - SESSION_SECRET
  - API_SECRET
  - MONGO_DB_URI 
  - REDIS_URI
  - AMQP_URI
  - SEGMENT_WRITE_KEY  (only in some services)

Plus 2 ArgoCD-specific secrets (separate ExternalSecrets in argocd namespace):
  - argocd-notifications-secret
  - argocd-github-infrastructure-repo

That's 9 total. Everything else in the OCI vault (ANB, Dow Jones, Alpaca,
Twilio, SendGrid, etc.) does NOT go through ESO at all — those are either
in service-specific prod.yaml files (inline values) or not used by services.

---

## The 7 service secrets — what to put in each

### 1. DB_PASSWORD
Source: copy from OCI backup — SAME value as OCI
Reason: Cloud SQL is a replica of OCI MySQL, same users and passwords
```bash
echo -n "<value-from-backup>" | gcloud secrets create DB_PASSWORD \
  --project=core-platform-workload-prod --data-file=-
```

### 2. SESSION_SECRET
Source: copy from OCI backup — SAME value
Reason: session tokens issued by OCI services must remain valid on GCP
```bash
echo -n "<value-from-backup>" | gcloud secrets create SESSION_SECRET \
  --project=core-platform-workload-prod --data-file=-
```

### 3. API_SECRET
Source: copy from OCI backup — SAME value
Reason: same as SESSION_SECRET — must match for token compatibility
```bash
echo -n "<value-from-backup>" | gcloud secrets create API_SECRET \
  --project=core-platform-workload-prod --data-file=-
```

### 4. MONGO_DB_URI — NEW VALUE (not OCI)
Source: Atlas connection string (complete Phase 1 first)
Reason: OCI's internal Percona address is unreachable from GCP
Format: mongodb+srv://core-platform-service:<pass>@<atlas-cluster>.mongodb.net/core-platform_dev?retryWrites=true&w=majority
```bash
echo -n "mongodb+srv://..." | gcloud secrets create MONGO_DB_URI \
  --project=core-platform-workload-prod --data-file=-
```

### 5. REDIS_URI — NEW VALUE (not OCI)
Source: GCP Redis internal address (fill in after Redis deployed in Step 5.5)
Reason: OCI's internal Redis address is unreachable from GCP
Format: redis://:<redis-password>@core-platform-redis-master.redis.svc.cluster.local:6379
```bash
# Get Redis password first:
# kubectl get secret core-platform-redis -n redis -o jsonpath='{.data.redis-password}' | base64 -d
echo -n "redis://..." | gcloud secrets create REDIS_URI \
  --project=core-platform-workload-prod --data-file=-
```

### 6. AMQP_URI — NEW VALUE (not OCI)
Source: GCP RabbitMQ credentials (fill in after RabbitMQ deployed in Step 5.4)
Reason: OCI's internal RabbitMQ address is unreachable from GCP
Get credentials after RabbitmqCluster creates:
  kubectl get secret core-platform-default-user -n rabbitmq-system \
    -o jsonpath='{.data.username}' | base64 -d
  kubectl get secret core-platform-default-user -n rabbitmq-system \
    -o jsonpath='{.data.password}' | base64 -d
Format: amqp://<user>:<pass>@core-platform.rabbitmq-system.svc.cluster.local:5672/
```bash
echo -n "amqp://..." | gcloud secrets create AMQP_URI \
  --project=core-platform-workload-prod --data-file=-
```

### 7. SEGMENT_WRITE_KEY
Source: copy from OCI backup if it exists, otherwise check service-specific values
```bash
echo -n "<value>" | gcloud secrets create SEGMENT_WRITE_KEY \
  --project=core-platform-workload-prod --data-file=-
```

---

## The 2 ArgoCD secrets

### argocd-notifications-secret
Contains the Slack bot token. Copy from OCI backup.
```bash
echo -n "<value>" | gcloud secrets create argocd-notifications-secret \
  --project=core-platform-workload-prod --data-file=-
```

### argocd-github-infrastructure-repo
Contains the SSH key for ArgoCD to pull from the Infrastructure repo.
Copy from OCI backup.
```bash
echo -n "<value>" | gcloud secrets create argocd-github-infrastructure-repo \
  --project=core-platform-workload-prod --data-file=-
```

---

## The remaining 20 OCI vault secrets — do NOT need to go in GCP Secret Manager

These are NOT fetched by ESO. They go into service-specific prod.yaml files
(already copied into helm-releases/core-platform-gcp/<service>/prod.yaml) as inline
values. They're already there — no action needed.

ANB_CLIENT_ID, ANB_CLIENT_SECRET, ALPACA_API_KEY, ALPACA_API_SECRET,
TWILIO_AUTH_TOKEN, SENDGRID_API_KEY, YAHOO_FINANCE_API_KEY, EML_APP_KEY,
EML_APP_ID, DOWJONES_RISK_AND_COMPLIANCE_PASSWORD,
DOWJONES_SCREENING_AND_MONITORING_PASSWORD, CUSTODIAN_PASSWORD,
X_API_KEY_WEBHOOK, GITHUB_TOKEN, OCI_USERNAME, OCI_AUTH_TOKEN,
OCI_REGISTRY_SECRET, bucket-oci-creds, backup-upload-secret,
apple-pay-certificate

---

## Additional secrets: service-specific `secrets:` block (2 more)

Beyond the 7 shared envSecret keys, two services fetch their own secrets via
the `secrets:` block — these also go through ESO and need GCP Secret Manager.

### bucket-oci-creds (media-service)
Source: copy from OCI backup — SAME value
Reason: media-service on GCP still points at OCI Object Storage buckets in
the dev/stg compartment (out of scope for this migration). The buckets are
accessible over the internet. This credential stays unchanged until dev/stg
migrates separately.
```bash
echo -n "<value-from-backup>" | gcloud secrets create bucket-oci-creds \
  --project=core-platform-workload-prod --data-file=-
```

### apple-pay-certificate (payment-service + webhook-service)
Source: copy from OCI backup — SAME value
```bash
echo -n "<value-from-backup>" | gcloud secrets create apple-pay-certificate \
  --project=core-platform-workload-prod --data-file=-
```

## TOTAL: 11 secrets needed (not 9)

| # | Secret | Source |
|---|---|---|
| 1 | DB_PASSWORD | Copy from OCI backup |
| 2 | SESSION_SECRET | Copy from OCI backup |
| 3 | API_SECRET | Copy from OCI backup |
| 4 | SEGMENT_WRITE_KEY | Copy from OCI backup |
| 5 | argocd-notifications-secret | Copy from OCI backup |
| 6 | argocd-github-infrastructure-repo | Copy from OCI backup |
| 7 | bucket-oci-creds | Copy from OCI backup |
| 8 | apple-pay-certificate | Copy from OCI backup |
| 9 | MONGO_DB_URI | Atlas URL — Phase 1 first |
| 10 | REDIS_URI | GCP Redis address — after Step 5.5 |
| 11 | AMQP_URI | GCP RabbitMQ credentials — after Step 5.4 |

---

## Verify after loading

After loading all 11 secrets and installing ESO + ClusterSecretStore:
```bash
# Check ESO can reach Secret Manager
kubectl get clustersecretstore oci-vault-cluster-secret-store

# After ArgoCD deploys the services, check ExternalSecrets are syncing:
kubectl get externalsecrets -n core-platform

# Each should show STATUS: SecretSynced
# If any show error, describe it:
kubectl describe externalsecret auth-service-env-secret -n core-platform
```
