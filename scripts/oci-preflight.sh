#!/usr/bin/env bash
# ============================================================================
# OCI-only pre-flight — safe to run RIGHT NOW, even while prod compute and
# the Kubernetes API server are down.
#
# Everything here is an OCI control-plane read (list/get). That plane has
# stayed reachable throughout the current outage — compartment list, mysql
# db-system list, and every network command already succeeded live earlier
# in this session. This script touches NO kubectl, so it will not hang
# waiting on the unreachable API server the way the full oci-discovery.sh
# would right now.
# 
# Usage:
#   export PROD_COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaa...cqi3q"
#   export DEVSTG_COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaa...2engq"
#   export MYSQL_DBSYSTEM_OCID="<optional, grab from the printed table below>"
#   ./oci-preflight.sh
# ============================================================================

set -uo pipefail

OUT="${OUT:-./preflight-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

PROD="${PROD_COMPARTMENT_OCID:?export PROD_COMPARTMENT_OCID first}"
DEVSTG="${DEVSTG_COMPARTMENT_OCID:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[skip] %s\033[0m\n' "$*" | tee -a "$OUT/errors.log"; }
run()  { local f="$1"; shift; "$@" > "$f" 2>>"$OUT/errors.log" || warn "$*"; }

# ---------------------------------------------------------------------------
log "1. GKE sizing: node pool shape/count + cluster Kubernetes version"
# ---------------------------------------------------------------------------
run "$OUT/node-pools.json" oci ce node-pool list -c "$PROD" --all
oci ce node-pool list -c "$PROD" --all \
  --query 'data[*].{name:name,shape:"node-shape",size:"node-config-details".size}' \
  --output table 2>>"$OUT/errors.log"

run "$OUT/cluster-version.json" oci ce cluster list -c "$PROD" --all
oci ce cluster list -c "$PROD" --all \
  --query 'data[*].{name:name,version:"kubernetes-version",state:"lifecycle-state"}' \
  --output table 2>>"$OUT/errors.log"

# ---------------------------------------------------------------------------
log "2. Cloud SQL sizing: full DB system spec + config flags"
# ---------------------------------------------------------------------------
echo "-- All db-systems in prod (grab the OCID for core-platform-mysql-stg-no-ha) --"
oci mysql db-system list -c "$PROD" --all \
  --query 'data[*].{name:"display-name",id:id,state:"lifecycle-state"}' \
  --output table | tee "$OUT/mysql-dbsystems-table.txt"

if [ -n "${MYSQL_DBSYSTEM_OCID:-}" ]; then
  run "$OUT/mysql-dbsystem.json" oci mysql db-system get --db-system-id "$MYSQL_DBSYSTEM_OCID"
  CFG=$(jq -r '.data."configuration-id" // empty' "$OUT/mysql-dbsystem.json" 2>/dev/null)
  if [ -n "$CFG" ]; then
    run "$OUT/mysql-configuration.json" oci mysql configuration get --configuration-id "$CFG"
  fi
else
  warn "MYSQL_DBSYSTEM_OCID not set — re-run with it exported to get full spec + config flags"
fi

# ---------------------------------------------------------------------------
log "3. WAF — does one exist in front of the LB, and what does it allow?"
# ---------------------------------------------------------------------------
run "$OUT/waf.json" oci waf web-app-firewall list -c "$PROD" --all
run "$OUT/waf-address-lists.json" oci waf network-address-list list -c "$PROD" --all

# ---------------------------------------------------------------------------
log "4. Vault / secret metadata — names only, never values"
# ---------------------------------------------------------------------------
run "$OUT/vaults.json" oci kms management vault list -c "$PROD" --all
run "$OUT/vault-secrets.json" oci vault secret list -c "$PROD" --all

# ---------------------------------------------------------------------------
log "5. Which of the two 10.0.0.0/16 VCNs does the dev/stg cluster use?"
# ---------------------------------------------------------------------------
if [ -n "$DEVSTG" ]; then
  run "$OUT/devstg-clusters.json" oci ce cluster list -c "$DEVSTG" --all
  oci ce cluster list -c "$DEVSTG" --all \
    --query 'data[*].{name:name,vcn:"vcn-id",state:"lifecycle-state"}' \
    --output table 2>>"$OUT/errors.log"
else
  warn "DEVSTG_COMPARTMENT_OCID not set — skipped"
fi

# ---------------------------------------------------------------------------
log "6. Local-only checks — no network call at all"
# ---------------------------------------------------------------------------
if [ -d "$HOME/Infrastructure" ]; then
  {
    echo "-- credential file ever committed? --"
    ( cd "$HOME/Infrastructure" && git log --all --oneline -- terraform/credential/ )
    ( cd "$HOME/Infrastructure" && git ls-files | grep -i credential )
  } > "$OUT/credential-check.txt" 2>&1
fi

if [ -d "$HOME/github-repo/Daily-start-stop-dev-stg" ]; then
  grep -rniE 'mysql|db-system|stop|display-name|-stg|compartment' \
    "$HOME/github-repo/Daily-start-stop-dev-stg" \
    > "$OUT/scheduler-scope.txt" 2>&1 || true
fi

cat <<EOF

============================================================
Pre-flight complete: $OUT
Errors (expect near-zero — this touches no kubectl): $OUT/errors.log
============================================================
EOF
