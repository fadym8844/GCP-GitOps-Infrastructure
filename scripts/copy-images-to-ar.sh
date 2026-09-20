#!/usr/bin/env bash
# ============================================================================
# One-time copy: existing OCIR images -> Artifact Registry.
#
# Run this ONCE, after k8s/images-in-use.txt exists (from oci-discovery.sh)
# and BEFORE the first GKE deployment. After this, GKE only ever pulls from
# Artifact Registry — it never talks to OCIR, not even once.
#
# Uses skopeo (registry-to-registry copy, no local disk churn) if available,
# falls back to docker pull/tag/push otherwise.
#
# Usage:
#   export IMAGES_FILE="./discovery-XXXXXXXX/k8s/images-in-use.txt" 
#   export AR_REGION="me-central2"
#   export AR_PROJECT="core-platform-workload-prod"   # confirm real project ID first
#   export AR_REPO="core-platform"
#   ./copy-images-to-ar.sh
# ============================================================================

set -uo pipefail

IMAGES_FILE="${IMAGES_FILE:?export IMAGES_FILE - path to images-in-use.txt}"
AR_REGION="${AR_REGION:-me-central2}"
AR_PROJECT="${AR_PROJECT:?export AR_PROJECT - the Artifact Registry project id}"
AR_REPO="${AR_REPO:-core-platform}"
AR_HOST="${AR_REGION}-docker.pkg.dev"

LOG="./copy-log-$(date +%Y%m%d-%H%M%S).txt"
touch "$LOG"

echo "Authenticating to Artifact Registry..."
gcloud auth configure-docker "$AR_HOST" --quiet

if command -v skopeo >/dev/null; then
  echo "Using skopeo (registry-to-registry, no local pull)"
  USE_SKOPEO=1
else
  echo "skopeo not found — falling back to docker pull/tag/push (slower, uses local disk)"
  USE_SKOPEO=0
fi

total=0
ok=0
failed=0

while IFS= read -r src_image; do
  [ -z "$src_image" ] && continue
  total=$((total+1))

  # jed.ocir.io/axvp4vawnqyw/portfolio-service:abc12345
  #   -> me-central2-docker.pkg.dev/core-platform-workload-prod/core-platform/portfolio-service:abc12345
  name_tag="${src_image##*/}"                 # portfolio-service:abc12345
  dest_image="${AR_HOST}/${AR_PROJECT}/${AR_REPO}/${name_tag}"

  echo "[$total] $src_image -> $dest_image" | tee -a "$LOG"

  if [ "$USE_SKOPEO" = "1" ]; then
    if skopeo copy "docker://${src_image}" "docker://${dest_image}" >>"$LOG" 2>&1; then
      ok=$((ok+1))
    else
      echo "  [FAILED]" | tee -a "$LOG"
      failed=$((failed+1))
    fi
  else
    if docker pull "$src_image" >>"$LOG" 2>&1 \
      && docker tag "$src_image" "$dest_image" \
      && docker push "$dest_image" >>"$LOG" 2>&1; then
      ok=$((ok+1))
    else
      echo "  [FAILED]" | tee -a "$LOG"
      failed=$((failed+1))
    fi
  fi
done < "$IMAGES_FILE"

cat <<EOF

============================================================
Done. $ok/$total copied successfully, $failed failed.
Full log: $LOG
============================================================
EOF
