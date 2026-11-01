#!/usr/bin/env bash
# =============================================================================
# CloudX Module 4 - Azure Container Apps automation (Azure CLI + bash)
#
# Usage:
#   ./deploy-containerapps.sh deploy                 # env + 3 APIs + PetStoreApp (v1), env vars, HTTP autoscaling
#   ./deploy-containerapps.sh new-revision [tag]     # deploy PetStoreApp image tag (default v2) as new revision, 0% traffic
#   ./deploy-containerapps.sh canary <blueRev> <greenRev> [greenPercent]   # e.g. canary petstoreapp--v1 petstoreapp--v2 20
#   ./deploy-containerapps.sh bluegreen <greenRev> [blueRev]               # 100% to green, optionally deactivate blue
#   ./deploy-containerapps.sh rollback <blueRev> <greenRev>                # activate blue, 100% back to blue
#   ./deploy-containerapps.sh status                 # FQDNs, scale settings, revisions + traffic
#   ./deploy-containerapps.sh cleanup                # delete the resource group
#
# Git Bash on Windows: run `export MSYS_NO_PATHCONV=1` first.
# =============================================================================
set -euo pipefail

# ---------- configuration (override with env vars) ----------
RG="${RG:-module4-rg}"
LOCATION="${LOCATION:-eastus}"
ENV_NAME="${ENV_NAME:-module4-env}"
ACR_NAME="${ACR_NAME:-ajitjhacloudxacr}"
ACR_SERVER="${ACR_NAME}.azurecr.io"
TAG="${TAG:-v1}"
CPU="0.5"; MEMORY="1.0Gi"
API_MIN=1; API_MAX=4
WEB_MIN=1; WEB_MAX=2
CONCURRENCY=10
APIS=(petstorepetservice petstoreproductservice petstoreorderservice)
WEB=petstoreapp

log() { echo -e "\n==> $*"; }

exists() { az containerapp show -n "$1" -g "$RG" -o none 2>/dev/null; }

fqdn() { az containerapp show -n "$1" -g "$RG" --query properties.configuration.ingress.fqdn -o tsv; }

acr_creds() {
  ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv)
  ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv)
}

# create one container app (external ingress 8080, HTTP scale rule); extra args passed through
create_app() {
  local name=$1 min=$2 max=$3; shift 3
  if exists "$name"; then log "$name already exists - skipping create"; return; fi
  log "Creating container app $name ($ACR_SERVER/$name:$TAG)"
  az containerapp create -n "$name" -g "$RG" --environment "$ENV_NAME" \
    --image "$ACR_SERVER/$name:$TAG" \
    --registry-server "$ACR_SERVER" --registry-username "$ACR_USER" --registry-password "$ACR_PASS" \
    --ingress external --target-port 8080 \
    --cpu "$CPU" --memory "$MEMORY" \
    --min-replicas "$min" --max-replicas "$max" \
    --scale-rule-name http-rule --scale-rule-type http --scale-rule-http-concurrency "$CONCURRENCY" \
    --tags Project=cloudx-module4 \
    "$@" -o none
}

deploy() {
  log "Resource group $RG ($LOCATION)"
  az group create -n "$RG" -l "$LOCATION" -o none

  if ! az containerapp env show -n "$ENV_NAME" -g "$RG" -o none 2>/dev/null; then
    log "Creating Container Apps environment $ENV_NAME"
    az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$LOCATION" -o none
  fi

  acr_creds

  # 1) independent APIs first
  create_app petstorepetservice     "$API_MIN" "$API_MAX"
  create_app petstoreproductservice "$API_MIN" "$API_MAX"
  local PRODUCT_URL="https://$(fqdn petstoreproductservice)"

  # 2) OrderService depends on ProductService
  create_app petstoreorderservice "$API_MIN" "$API_MAX" \
    --env-vars "PETSTOREPRODUCTSERVICE_URL=$PRODUCT_URL"

  local PET_URL="https://$(fqdn petstorepetservice)"
  local ORDER_URL="https://$(fqdn petstoreorderservice)"

  # 3) Web app depends on all three; multiple revision mode for canary / blue-green
  create_app "$WEB" "$WEB_MIN" "$WEB_MAX" \
    --revisions-mode multiple --revision-suffix "$TAG" \
    --env-vars "PETSTOREPETSERVICE_URL=$PET_URL" \
               "PETSTOREPRODUCTSERVICE_URL=$PRODUCT_URL" \
               "PETSTOREORDERSERVICE_URL=$ORDER_URL"

  status
}

new_revision() {
  local tag=${1:-v2}
  log "Deploying $WEB:$tag as new revision $WEB--$tag (multiple mode -> 0% traffic until assigned)"
  az containerapp update -n "$WEB" -g "$RG" --image "$ACR_SERVER/$WEB:$tag" --revision-suffix "$tag" -o none
  revisions
}

canary() {
  local blue=$1 green=$2 pct=${3:-20}
  log "Canary: $blue=$((100 - pct))%  $green=$pct%"
  az containerapp revision label add -n "$WEB" -g "$RG" --label blue  --revision "$blue"  --no-prompt -o none || true
  az containerapp revision label add -n "$WEB" -g "$RG" --label green --revision "$green" --no-prompt -o none || true
  az containerapp ingress traffic set -n "$WEB" -g "$RG" \
    --revision-weight "$blue=$((100 - pct))" "$green=$pct" -o none
  revisions
}

bluegreen() {
  local green=$1 blue=${2:-}
  log "Blue/Green: 100% -> $green"
  az containerapp ingress traffic set -n "$WEB" -g "$RG" --revision-weight "$green=100" -o none
  if [[ -n "$blue" ]]; then
    log "Deactivating old revision $blue (kept for rollback)"
    az containerapp revision deactivate -n "$WEB" -g "$RG" --revision "$blue" -o none
  fi
  revisions
}

rollback() {
  local blue=$1 green=$2
  log "Rollback: activating $blue and sending 100% traffic back to it"
  az containerapp revision activate -n "$WEB" -g "$RG" --revision "$blue" -o none
  az containerapp ingress traffic set -n "$WEB" -g "$RG" --revision-weight "$blue=100" "$green=0" -o none
  revisions
}

revisions() {
  az containerapp revision list -n "$WEB" -g "$RG" --all \
    --query "[].{revision:name, active:properties.active, traffic:properties.trafficWeight, replicas:properties.replicas}" -o table
}

status() {
  log "Application URLs"
  for a in "${APIS[@]}" "$WEB"; do echo "$a: https://$(fqdn "$a")"; done
  log "Scale settings"
  for a in "${APIS[@]}" "$WEB"; do
    az containerapp show -n "$a" -g "$RG" --query "{app:name, min:properties.template.scale.minReplicas, max:properties.template.scale.maxReplicas, rules:join(', ', properties.template.scale.rules[].name)}" -o tsv
  done
  log "PetStoreApp revisions"
  revisions
}

cleanup() {
  log "Deleting resource group $RG (ACR in a separate RG is NOT touched)"
  az group delete -n "$RG" --yes --no-wait
}

case "${1:-}" in
  deploy)       deploy ;;
  new-revision) new_revision "${2:-v2}" ;;
  canary)       canary "${2:?blue revision}" "${3:?green revision}" "${4:-20}" ;;
  bluegreen)    bluegreen "${2:?green revision}" "${3:-}" ;;
  rollback)     rollback "${2:?blue revision}" "${3:?green revision}" ;;
  status)       status ;;
  cleanup)      cleanup ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
