# GCP Platform Installation Guide
# Run these commands IN ORDER after `terraform apply` completes.
# Each step depends on the one above it.

## Prerequisites

```bash
# Get kubectl access to the new cluster
gcloud container clusters get-credentials core-platform-prod \
  --region=me-central2 --project=core-platform-workload-prod

# Verify you're on the right cluster
kubectl config current-context
kubectl get nodes
```
 
---

## Step 1 — cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager --version v1.11.0 \
  -n cert-manager --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/cert-manager/values-cert-manager-gcp.yaml

# Wait for all 3 pods ready
kubectl rollout status deployment cert-manager -n cert-manager
kubectl rollout status deployment cert-manager-webhook -n cert-manager

# Apply ClusterIssuers
kubectl apply -f ~/Infrastructure/GCP/helm-releases/cert-manager/clusterissuers-gcp.yaml
```

---

## Step 2 — External Secrets Operator + GCP Secret Manager

```bash
# Grant ESO Workload Identity access to Secret Manager
# (core-platform-workload-prod is fully independent - no OCI dependency)
gcloud projects add-iam-policy-binding core-platform-workload-prod \
  --member="serviceAccount:core-platform-workload-prod.svc.id.goog[external-secrets/external-secrets]" \
  --role="roles/secretmanager.secretAccessor"

# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets --version 0.8.1 \
  -n external-secrets --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/external-secrets/values-external-secrets-gcp.yaml

kubectl rollout status deployment external-secrets -n external-secrets

# Apply ClusterSecretStore (reads from GCP Secret Manager - fully OCI-independent)
kubectl apply -f ~/Infrastructure/GCP/helm-releases/external-secrets/clustersecretstore-gcp.yaml

kubectl get clustersecretstore oci-vault-cluster-secret-store
```

### Load secrets into GCP Secret Manager before proceeding

Most copy straight from your backup. Three need NEW values - read carefully:

```bash
PROJECT=core-platform-workload-prod

# --- Copy straight from backup (replace <value> with real value) ---
for SECRET in DB_PASSWORD API_SECRET SESSION_SECRET JWT_SECRET \
  SENDGRID_API_KEY TWILIO_AUTH_TOKEN ALPACA_API_KEY ALPACA_API_SECRET \
  ANB_CLIENT_ID ANB_CLIENT_SECRET CUSTODIAN_PASSWORD \
  DOWJONES_RISK_AND_COMPLIANCE_PASSWORD DOWJONES_SCREENING_AND_MONITORING_PASSWORD \
  YAHOO_FINANCE_API_KEY EML_APP_KEY EML_APP_ID X_API_KEY_WEBHOOK \
  GITHUB_TOKEN argocd-notifications-secret argocd-github-infrastructure-repo \
  backup-upload-secret apple-pay-certificate bucket-oci-creds \
  OCI_REGISTRY_SECRET OCI_USERNAME OCI_AUTH_TOKEN; do
  echo "Create $SECRET in GCP console → Secret Manager → Create Secret"
done

# --- MONGO_DB_URI: use Atlas URL (complete Phase 1 first) ---
echo "mongodb+srv://core-platform-service:<pass>@<atlas-url>/core-platform_dev?retryWrites=true&w=majority" \
  | gcloud secrets create MONGO_DB_URI --project=$PROJECT --data-file=-

# --- REDIS_URI: use GCP Redis (fill in after Step 5.5 - Redis deployed) ---
# format: redis://:<password>@core-platform-redis-master.redis.svc.cluster.local:6379

# --- AMQP_URI: use GCP RabbitMQ (fill in after Step 5.4 - RabbitMQ deployed) ---
# Get credentials after RabbitmqCluster creates:
#   kubectl get secret core-platform-default-user -n rabbitmq-system \
#     -o jsonpath='{.data.username}' | base64 -d
#   kubectl get secret core-platform-default-user -n rabbitmq-system \
#     -o jsonpath='{.data.password}' | base64 -d
# format: amqp://<user>:<pass>@core-platform.rabbitmq-system.svc.cluster.local:5672/
```

---

## Step 3 — ArgoCD

```bash
# argocd-notifications-secret MUST exist before ArgoCD starts
# ESO will sync it automatically from OCI Vault since ClusterSecretStore is now running
# Wait for it:
kubectl get externalsecret argocd-notifications-secret -n argocd 2>/dev/null || \
  echo "namespace not created yet - ArgoCD install will create it"

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd --version 5.34.1 \
  -n argocd --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/argocd/values-argocd-gcp.yaml

kubectl rollout status deployment argocd-server -n argocd

# Get initial admin password (if the bcrypt hash in values doesn't work)
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Step 4 — RabbitMQ

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install rabbitmq-operator bitnami/rabbitmq-cluster-operator \
  -n rabbitmq-system --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/rabbitmq/values-rabbitmq-operator-gcp.yaml

kubectl rollout status deployment rabbitmq-operator-rabbitmq-cluster-operator -n rabbitmq-system

# Apply cluster + permission (waits for CRDs to be ready)
kubectl apply -f ~/Infrastructure/GCP/helm-releases/rabbitmq/rabbitmq-cluster-gcp.yaml

# Watch pods come up (takes 2-3 minutes, known bootstrap history - be patient)
kubectl get pods -n rabbitmq-system -w
```

---

## Step 5 — Redis

```bash
# Get Redis password from OCI first
kubectl config use-context context-ctphymu27ra
REDIS_PASS=$(kubectl get secret core-platform-redis -n redis \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# Switch to GCP
kubectl config use-context <gcp-context-name>

kubectl create namespace redis
kubectl create secret generic core-platform-redis -n redis \
  --from-literal=redis-password="$REDIS_PASS"

kubectl apply -f ~/Infrastructure/GCP/helm-releases/redis/redis-gcp.yaml
kubectl rollout status statefulset core-platform-redis-master -n redis
```

---

## Step 6 — Observability Stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Prometheus + Grafana + Alertmanager
helm install monitoring prometheus-community/kube-prometheus-stack --version 43.2.1 \
  -n monitoring --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/kube-prometheus-stack/values-kube-prometheus-stack-gcp.yaml

# Loki
helm install loki grafana/loki-distributed \
  -n monitoring \
  -f ~/Infrastructure/GCP/helm-releases/loki/values-loki-gcp.yaml

# Promtail
helm install promtail grafana/promtail \
  -n monitoring \
  -f ~/Infrastructure/GCP/helm-releases/promtail/values-promtail-gcp.yaml
```

---

## Step 7 — OpenTelemetry

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install opentelemetry-operator open-telemetry/opentelemetry-operator --version 0.32.0 \
  -n opentelemetry-operator --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/opentelemetry-operator/values-opentelemetry-operator-gcp.yaml

kubectl rollout status deployment opentelemetry-operator -n opentelemetry-operator

# Bind Workload Identity for Cloud Trace access
gcloud projects add-iam-policy-binding core-platform-workload-prod \
  --member="serviceAccount:core-platform-workload-prod.svc.id.goog[opentelemetry-operator/opentelemetry-collector]" \
  --role="roles/cloudtrace.agent"

# Apply collector config (now exports to Cloud Trace instead of dead Tempo)
kubectl apply -f ~/Infrastructure/GCP/helm-releases/opentelemetry-operator/opentelemetry-collector-gcp.yaml
```

---

## Step 8 — Twingate Connector

```bash
# Prerequisites (from Twingate console for core-platformprodgcp account):
# 1. Create connector under core-platformprodgcp Remote Network
# 2. Copy the kubectl create secret command Twingate shows you
# 3. Run that secret command first, then:

helm repo add twingate https://twingate.github.io/helm-charts
helm repo update

helm install twingate-gcp-connector twingate/connector \
  -n default \
  -f ~/Infrastructure/GCP/helm-releases/twingate-gcp/values-core-platformprodgcp.yaml
```

---

## Step 9 — Application Layer (ArgoCD takes over from here)

```bash
# Fill in DB_HOST in BOTH files that reference it
DBHOST=$(cd ~/Infrastructure/GCP/terraform/envs/prod && terraform output -raw cloudsql_private_ip)

# 1. Install values file
sed -i "s|TODO-fill-in-after-terraform-apply|$DBHOST|g" \
  ~/Infrastructure/GCP/helm-releases/core-platform-gcp-install/values-core-platform-gcp-prod.yaml

# 2. defaults-prod.values.yaml (the file all 27 services inherit DB_HOST from)
sed -i "s|TODO-fill-in-after-terraform-apply|$DBHOST|g" \
  ~/Infrastructure/GCP/helm-releases/core-platform-gcp/defaults-prod.values.yaml

# Verify both updated correctly
grep "DB_HOST" ~/Infrastructure/GCP/helm-releases/core-platform-gcp-install/values-core-platform-gcp-prod.yaml
grep "DB_HOST" ~/Infrastructure/GCP/helm-releases/core-platform-gcp/defaults-prod.values.yaml

# Install the core-platform-gcp ApplicationSet
helm install core-platform-gcp ~/Infrastructure/GCP/helm-charts/core-platform-gcp \
  -n argocd \
  -f ~/Infrastructure/GCP/helm-releases/core-platform-gcp-install/values-core-platform-gcp-prod.yaml

# ArgoCD now watches helm-releases/core-platform-gcp/* and deploys all 27 services
# Watch them appear:
kubectl get applications -n argocd -w
kubectl get pods -n core-platform -w
```

---

## Step 10 — Traefik (replaces Gateway API — same as OCI)

```bash
# Add static IP to Traefik values first
TRAEFIK_IP=$(cd ~/Infrastructure/GCP/terraform/envs/prod && terraform output -raw traefik_lb_ip)
# Edit values-traefik-gcp.yaml and add under service.annotations:
#   cloud.google.com/load-balancer-ip: "<TRAEFIK_IP>"

helm repo add traefik https://traefik.github.io/charts
helm repo update

helm install traefik traefik/traefik --version 38.0.1 \
  -n traefik --create-namespace \
  -f ~/Infrastructure/GCP/helm-releases/traefik/values-traefik-gcp.yaml

# Wait for Traefik to get its external IP (1-2 min)
kubectl get svc traefik -n traefik -w

# Apply the redirect-to-https middleware
kubectl apply -f ~/Infrastructure/GCP/helm-releases/traefik/traefik-middleware-gcp.yaml

# Apply TLS certificates (cert-manager issues these)
kubectl apply -f ~/Infrastructure/GCP/helm-releases/traefik-routes/prod/traefik-certificates-gcp.yaml

# Install the main app routes (api, app, admin, website, ratbiplus)
helm install traefik-routes ~/Infrastructure/GCP/helm-charts/traefik-routes \
  -n core-platform \
  -f ~/Infrastructure/GCP/helm-releases/traefik-routes/prod/values-core-platform-gcp-prod.yaml

# Apply extra routes (argocd, monitoring, rabbitmq - different namespaces)
kubectl apply -f ~/Infrastructure/GCP/helm-releases/traefik-routes/prod/traefik-routes-extra-gcp.yaml

# Verify Traefik has its IP
kubectl get svc traefik -n traefik
```

---

## Verification Checklist

```bash
# All platform pods healthy
kubectl get pods -A | grep -v Running | grep -v Completed

# Traefik has external IP
kubectl get svc traefik -n traefik

# All 27 services synced in ArgoCD
kubectl get applications -n argocd

# ESO secrets syncing
kubectl get externalsecrets -n core-platform

# RabbitMQ cluster healthy
kubectl get rabbitmqcluster -n rabbitmq-system

# Redis healthy
kubectl get pods -n redis

# Certificates issued (after DNS points at GCP)
kubectl get certificates -A
```
