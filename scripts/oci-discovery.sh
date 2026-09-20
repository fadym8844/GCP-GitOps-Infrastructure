#!/usr/bin/env bash
# ============================================================================
# OCI -> GCP Migration :: Read-Only Discovery Bundle
#
# SAFE: performs only get/list/describe operations. Nothing is created,
# modified, or deleted. Secret VALUES are never captured - only names and
# the key names inside them.
#
# Usage:
#   export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..xxxx"
#   export OCI_TENANCY_OCID="ocid1.tenancy.oc1..xxxx"     # optional 
#   export INFRA_REPO_PATH="$HOME/Infrastructure"          # optional
#   ./oci-discovery.sh
#
# Requires: kubectl (pointed at OKE), oci CLI, jq. helm/argocd/gh optional.
# ============================================================================

set -uo pipefail   # deliberately NOT -e: a missing resource type must not abort

OUT="${OUT:-./discovery-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"/{k8s,oci,secrets,cicd,network,logs}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[skip] %s\033[0m\n' "$*"; }
run()  { # run <outfile> <cmd...>
  local f="$1"; shift
  if "$@" > "$f" 2>>"$OUT/logs/errors.log"; then :; else warn "$* -> see logs/errors.log"; fi
}

# ---------------------------------------------------------------------------
log "0. Prerequisites"
# ---------------------------------------------------------------------------
for t in kubectl jq; do
  command -v "$t" >/dev/null || { echo "FATAL: $t not found"; exit 1; }
done
command -v oci     >/dev/null || warn "oci CLI missing - OCI sections will be empty"
command -v helm    >/dev/null || warn "helm missing"
command -v argocd  >/dev/null || warn "argocd CLI missing"
command -v gh      >/dev/null || warn "gh CLI missing"

kubectl config current-context > "$OUT/k8s/current-context.txt" 2>&1
kubectl version -o json        > "$OUT/k8s/version.json"        2>&1

# ===========================================================================
log "1. Kubernetes - cluster level"
# ===========================================================================
run "$OUT/k8s/nodes-wide.txt"        kubectl get nodes -o wide
run "$OUT/k8s/nodes-full.json"       kubectl get nodes -o json
run "$OUT/k8s/namespaces.txt"        kubectl get ns
run "$OUT/k8s/storageclasses.yaml"   kubectl get storageclass -o yaml
run "$OUT/k8s/pv.yaml"               kubectl get pv -o yaml
run "$OUT/k8s/crds.txt"              kubectl get crd
run "$OUT/k8s/apiservices.txt"       kubectl get apiservices
run "$OUT/k8s/nodes-capacity.txt"    kubectl describe nodes

# Everything that will need re-scheduling on GKE
run "$OUT/k8s/all-namespaced.txt"    kubectl get all --all-namespaces -o wide
run "$OUT/k8s/pvc-all.yaml"          kubectl get pvc --all-namespaces -o yaml
run "$OUT/k8s/ingress-all.yaml"      kubectl get ingress --all-namespaces -o yaml
run "$OUT/k8s/ingressclass.yaml"     kubectl get ingressclass -o yaml
run "$OUT/k8s/svc-loadbalancers.txt" kubectl get svc --all-namespaces \
      -o=custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTIP:.status.loadBalancer.ingress[*].ip,PORTS:.spec.ports[*].port'
run "$OUT/k8s/hpa.yaml"              kubectl get hpa --all-namespaces -o yaml
run "$OUT/k8s/pdb.yaml"              kubectl get pdb --all-namespaces -o yaml
run "$OUT/k8s/networkpolicies.yaml"  kubectl get networkpolicy --all-namespaces -o yaml
run "$OUT/k8s/daemonsets.yaml"       kubectl get daemonset --all-namespaces -o yaml
run "$OUT/k8s/statefulsets.yaml"     kubectl get statefulset --all-namespaces -o yaml
run "$OUT/k8s/cronjobs.yaml"         kubectl get cronjob --all-namespaces -o yaml
run "$OUT/k8s/serviceaccounts.txt"   kubectl get sa --all-namespaces
run "$OUT/k8s/clusterroles.txt"      kubectl get clusterrole,clusterrolebinding
run "$OUT/k8s/resourcequotas.yaml"   kubectl get resourcequota,limitrange --all-namespaces -o yaml
run "$OUT/k8s/mutatingwebhooks.yaml" kubectl get mutatingwebhookconfiguration -o yaml
run "$OUT/k8s/validatingwebhooks.yaml" kubectl get validatingwebhookconfiguration -o yaml

# Container images in use -> drives the Artifact Registry re-push list
kubectl get pods --all-namespaces \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
  2>/dev/null | sort -u > "$OUT/k8s/images-in-use.txt"

# Per-namespace full manifests (the actual migration payload)
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  mkdir -p "$OUT/k8s/ns/$ns"
  kubectl get deploy,sts,ds,svc,cm,ingress,job,cronjob,hpa,pvc,sa,role,rolebinding \
    -n "$ns" -o yaml > "$OUT/k8s/ns/$ns/workloads.yaml" 2>/dev/null
  kubectl get events -n "$ns" --sort-by=.lastTimestamp \
    > "$OUT/k8s/ns/$ns/events.txt" 2>/dev/null
done

# Resource requests/limits table -> sizes the GKE node pools
kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
  ["NS","POD","CONTAINER","CPU_REQ","CPU_LIM","MEM_REQ","MEM_LIM"],
  (.items[] | .metadata.namespace as $ns | .metadata.name as $p |
    .spec.containers[] | [$ns,$p,.name,
      (.resources.requests.cpu // "-"), (.resources.limits.cpu // "-"),
      (.resources.requests.memory // "-"), (.resources.limits.memory // "-")])
  | @tsv' > "$OUT/k8s/resource-requests.tsv"

# ===========================================================================
log "2. Ingress / TLS / cert-manager"
# ===========================================================================
run "$OUT/k8s/certmanager-certs.yaml"    kubectl get certificate --all-namespaces -o yaml
run "$OUT/k8s/certmanager-issuers.yaml"  kubectl get issuer,clusterissuer --all-namespaces -o yaml
run "$OUT/k8s/certmanager-orders.txt"    kubectl get certificaterequest,order,challenge --all-namespaces
run "$OUT/k8s/traefik-crds.yaml"         kubectl get ingressroute,middleware,tlsstore,tlsoption,serverstransport --all-namespaces -o yaml

# Every hostname currently served -> the DNS cutover checklist
{
  kubectl get ingress --all-namespaces -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}'
  kubectl get certificate --all-namespaces -o jsonpath='{range .items[*]}{range .spec.dnsNames[*]}{.}{"\n"}{end}{end}'
} 2>/dev/null | sed '/^$/d' | sort -u > "$OUT/k8s/hostnames.txt"

# ===========================================================================
log "3. Secrets - NAMES AND KEYS ONLY, no values"
# ===========================================================================
kubectl get secrets --all-namespaces -o json 2>/dev/null | jq -r '
  ["NAMESPACE","NAME","TYPE","KEYS"],
  (.items[] | [.metadata.namespace, .metadata.name, .type,
               ((.data // {}) | keys | join(","))])
  | @tsv' > "$OUT/secrets/k8s-secret-inventory.tsv"

kubectl get configmaps --all-namespaces -o json 2>/dev/null | jq -r '
  ["NAMESPACE","NAME","KEYS"],
  (.items[] | [.metadata.namespace, .metadata.name,
               ((.data // {}) | keys | join(","))])
  | @tsv' > "$OUT/secrets/k8s-configmap-inventory.tsv"

# Are secrets synced from an external store already?
run "$OUT/secrets/external-secrets.yaml" kubectl get externalsecret,secretstore,clustersecretstore --all-namespaces -o yaml
run "$OUT/secrets/sealed-secrets.txt"    kubectl get sealedsecret --all-namespaces

if command -v oci >/dev/null && [ -n "${OCI_COMPARTMENT_OCID:-}" ]; then
  run "$OUT/secrets/oci-vaults.json"   oci kms management vault list -c "$OCI_COMPARTMENT_OCID" --all
  run "$OUT/secrets/oci-secrets.json"  oci vault secret list -c "$OCI_COMPARTMENT_OCID" --all
fi

# ===========================================================================
log "4. OCI - compute, OKE, registry, database"
# ===========================================================================
if command -v oci >/dev/null && [ -n "${OCI_COMPARTMENT_OCID:-}" ]; then
  C="$OCI_COMPARTMENT_OCID"
  run "$OUT/oci/oke-clusters.json"     oci ce cluster list -c "$C" --all
  run "$OUT/oci/oke-nodepools.json"    oci ce node-pool list -c "$C" --all
  run "$OUT/oci/instances.json"        oci compute instance list -c "$C" --all
  run "$OUT/oci/volumes.json"          oci bv volume list -c "$C" --all
  run "$OUT/oci/boot-volumes.json"     oci bv boot-volume list -c "$C" --all
  run "$OUT/oci/vol-backups.json"      oci bv backup list -c "$C" --all
  run "$OUT/oci/ocir-repos.json"       oci artifacts container repository list -c "$C" --all
  run "$OUT/oci/ocir-images.json"      oci artifacts container image list -c "$C" --all
  run "$OUT/oci/mysql-dbsystems.json"  oci mysql db-system list -c "$C" --all
  run "$OUT/oci/mysql-configs.json"    oci mysql configuration list -c "$C" --all
  run "$OUT/oci/mysql-backups.json"    oci mysql backup list -c "$C" --all
  run "$OUT/oci/buckets.json"          oci os bucket list -c "$C" --all
  run "$OUT/oci/file-systems.json"     oci fs file-system list -c "$C" --all --availability-domain ALL
  run "$OUT/oci/streams.json"          oci streaming admin stream list -c "$C" --all
  run "$OUT/oci/functions.json"        oci fn application list -c "$C" --all
  run "$OUT/oci/dynamic-groups.json"   oci iam dynamic-group list --all
  run "$OUT/oci/policies.json"         oci iam policy list -c "$C" --all
  run "$OUT/oci/tags.json"             oci iam tag-namespace list -c "$C" --all

  # -------------------------------------------------------------------
  log "5. OCI - networking (drives the VPC design + DNS cutover)"
  # -------------------------------------------------------------------
  run "$OUT/network/vcns.json"            oci network vcn list -c "$C" --all
  run "$OUT/network/subnets.json"         oci network subnet list -c "$C" --all
  run "$OUT/network/route-tables.json"    oci network route-table list -c "$C" --all
  run "$OUT/network/security-lists.json"  oci network security-list list -c "$C" --all
  run "$OUT/network/nsgs.json"            oci network nsg list -c "$C" --all
  run "$OUT/network/nat-gateways.json"    oci network nat-gateway list -c "$C" --all
  run "$OUT/network/service-gateways.json" oci network service-gateway list -c "$C" --all
  run "$OUT/network/internet-gateways.json" oci network internet-gateway list -c "$C" --all
  run "$OUT/network/drgs.json"            oci network drg list -c "$C" --all
  run "$OUT/network/public-ips.json"      oci network public-ip list -c "$C" --scope REGION --all
  run "$OUT/network/lb.json"              oci lb load-balancer list -c "$C" --all
  run "$OUT/network/nlb.json"             oci nlb network-load-balancer list -c "$C" --all
  run "$OUT/network/lb-certs.json"        oci lb certificate list -c "$C" 2>/dev/null
  run "$OUT/network/dns-zones.json"       oci dns zone list -c "$C" --all
else
  warn "OCI_COMPARTMENT_OCID unset or oci CLI missing - OCI + network sections skipped"
fi

# ===========================================================================
log "6. CI/CD - ArgoCD, Helm, GitHub Actions"
# ===========================================================================
run "$OUT/cicd/argocd-apps.yaml"      kubectl get applications.argoproj.io -A -o yaml
run "$OUT/cicd/argocd-appsets.yaml"   kubectl get applicationsets.argoproj.io -A -o yaml
run "$OUT/cicd/argocd-projects.yaml"  kubectl get appprojects.argoproj.io -A -o yaml
run "$OUT/cicd/argocd-cm.yaml"        kubectl get cm -n argocd -o yaml
run "$OUT/cicd/argocd-version.txt"    kubectl get deploy -n argocd -o wide

if command -v helm >/dev/null; then
  run "$OUT/cicd/helm-releases.txt" helm list -A
  helm list -A -o json 2>/dev/null | jq -r '.[].name' | while read -r r; do
    ns=$(helm list -A -o json | jq -r --arg r "$r" '.[]|select(.name==$r)|.namespace')
    helm get values "$r" -n "$ns" -a > "$OUT/cicd/helm-values-$ns-$r.yaml" 2>/dev/null
  done
fi

if [ -n "${INFRA_REPO_PATH:-}" ] && [ -d "$INFRA_REPO_PATH" ]; then
  ( cd "$INFRA_REPO_PATH" && git remote -v && git branch -a ) > "$OUT/cicd/infra-repo-git.txt" 2>&1
  find "$INFRA_REPO_PATH" -name '*.yaml' -path '*helm-releases*' | sort > "$OUT/cicd/infra-repo-tree.txt"
  find "$INFRA_REPO_PATH" -path '*.github/workflows/*' -name '*.y*ml' \
    -exec sh -c 'echo "===== $1"; cat "$1"' _ {} \; > "$OUT/cicd/github-workflows.txt" 2>/dev/null
fi

if command -v gh >/dev/null; then
  run "$OUT/cicd/gh-repos.txt"    gh repo list madkol --limit 200
  run "$OUT/cicd/gh-secrets.txt"  gh secret list --repo madkol/Infrastructure
  run "$OUT/cicd/gh-runners.txt"  gh api /orgs/madkol/actions/runners
fi

# ===========================================================================
log "7. Observability + package"
# ===========================================================================
run "$OUT/k8s/newrelic.txt"  kubectl get all -n newrelic
run "$OUT/k8s/metrics-top.txt" kubectl top nodes
kubectl top pods --all-namespaces >> "$OUT/k8s/metrics-top.txt" 2>/dev/null

TAR="${OUT}.tar.gz"
tar czf "$TAR" "$OUT" 2>/dev/null

cat <<EOF

============================================================
Discovery complete.

  Directory : $OUT
  Archive   : $TAR
  Errors    : $OUT/logs/errors.log

Key files to look at first:
  k8s/hostnames.txt            every DNS name needing cutover
  k8s/images-in-use.txt        every image to re-push to Artifact Registry
  k8s/resource-requests.tsv    sizing input for GKE node pools
  secrets/k8s-secret-inventory.tsv   secrets to recreate (names only)
  network/lb.json              current public IPs behind GoDaddy
  network/subnets.json         CIDRs to avoid overlapping in the new VPC

Before sharing: grep the bundle for anything sensitive.
Values were excluded, but Helm values files and ArgoCD manifests
can contain inline credentials.
============================================================
EOF
