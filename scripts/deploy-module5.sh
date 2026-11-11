#!/usr/bin/env bash
# =============================================================================
# CloudX Module 5 - Monitoring and Logging (Application Insights + Container Apps)
#
# Every subcommand is idempotent (safe to run again): existing resources are kept.
#
# Usage:
#   ./scripts/deploy-module5.sh infra                  # RG + Log Analytics (30 d, 1 GB/day cap) + workspace-based App Insights
#   ./scripts/deploy-module5.sh build [tag]            # build + push the 4 images (default tag m5) with WSL Docker
#   ./scripts/deploy-module5.sh deploy [tag]           # ACA env (logs -> workspace) + 4 apps (back-ends internal, web external),
#                                                      #   connection string as secret, cloud role name per service
#   ./scripts/deploy-module5.sh web <tag>              # new petstoreapp revision with image tag (e.g. m5-err)
#   ./scripts/deploy-module5.sh error on|off           # switch the intentional "Cannot move further" error (env var, no rebuild)
#   ./scripts/deploy-module5.sh verify                 # agent start line from each container's console log
#   ./scripts/deploy-module5.sh kql-session <id>       # all telemetry of one session, per item type and service
#   ./scripts/deploy-module5.sh kql-errors             # count "Cannot move further" exceptions in the last hour
#   ./scripts/deploy-module5.sh metric                 # ProductsReturnedCount custom metric (last hour, 5-min avg)
#   ./scripts/deploy-module5.sh scale <min>            # min replicas for all apps (0 = scale to zero overnight)
#   ./scripts/deploy-module5.sh status                 # URLs, revisions, images
#   ./scripts/deploy-module5.sh cleanup                # delete the resource group
#
# Git Bash on Windows: run `export MSYS_NO_PATHCONV=1` first.
# =============================================================================
set -euo pipefail

# ---------- configuration (override with env vars) ----------
RG="${RG:-module5-rg}"
LOCATION="${LOCATION:-eastus}"
LAW="${LAW:-petstore-law}"              # Log Analytics workspace
AI="${AI:-petstore-ai}"                 # Application Insights
ENV_NAME="${ENV_NAME:-petstore-env}"    # Container Apps environment
ACR_NAME="${ACR_NAME:-ajitjhacloudxacr}"
ACR_SERVER="${ACR_NAME}.azurecr.io"
DOCKER="${DOCKER:-wsl docker}"          # Docker runs in WSL on this laptop
CPU="0.5"; MEMORY="1.0Gi"
APIS=(petstorepetservice petstoreproductservice petstoreorderservice)
WEB=petstoreapp
ALL=("${APIS[@]}" "$WEB")
TAGS="course=cloudx module=5 owner=ajit"

log()    { echo -e "\n==> $*"; }
exists() { az containerapp show -n "$1" -g "$RG" -o none 2>/dev/null; }
fqdn()   { az containerapp show -n "$1" -g "$RG" --query properties.configuration.ingress.fqdn -o tsv; }
ai_conn(){ az monitor app-insights component show --app "$AI" -g "$RG" --query connectionString -o tsv; }
ai_query(){ az monitor app-insights query --app "$AI" -g "$RG" --analytics-query "$1" --offset "${2:-1h}" \
             --query "tables[0].rows" -o tsv; }

acr_creds() {
  ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv)
  ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv)
}

infra() {
  log "Resource group $RG ($LOCATION)"
  az group create -n "$RG" -l "$LOCATION" --tags $TAGS -o none

  if ! az monitor log-analytics workspace show -g "$RG" -n "$LAW" -o none 2>/dev/null; then
    log "Log Analytics workspace $LAW (retention 30 days, daily cap 1 GB)"
    az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOCATION" \
      --retention-time 30 --quota 1 -o none
  fi
  local WS_RID
  WS_RID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)

  if ! az monitor app-insights component show --app "$AI" -g "$RG" -o none 2>/dev/null; then
    log "Application Insights $AI (workspace-based -> $LAW)"
    az monitor app-insights component create --app "$AI" -g "$RG" -l "$LOCATION" \
      --workspace "$WS_RID" --application-type web --kind web -o none
  fi
  az monitor app-insights component show --app "$AI" -g "$RG" \
    --query "{name:name, ingestionMode:ingestionMode, workspace:workspaceResourceId}" -o table
}

build() {
  local tag="${1:-m5}"
  for s in "${ALL[@]}"; do
    log "Build + push $ACR_SERVER/$s:$tag"
    $DOCKER build -t "$ACR_SERVER/$s:$tag" "$s"
    $DOCKER push "$ACR_SERVER/$s:$tag"
  done
}

# create one container app; extra args (env vars) passed through
create_app() {
  local name=$1 ingress=$2 tag=$3; shift 3
  if exists "$name"; then log "$name already exists - skipping create"; return; fi
  log "Creating $name ($ACR_SERVER/$name:$tag, ingress $ingress)"
  az containerapp create -n "$name" -g "$RG" --environment "$ENV_NAME" \
    --image "$ACR_SERVER/$name:$tag" \
    --registry-server "$ACR_SERVER" --registry-username "$ACR_USER" --registry-password "$ACR_PASS" \
    --target-port 8080 --ingress "$ingress" \
    --cpu "$CPU" --memory "$MEMORY" --min-replicas 1 --max-replicas 1 \
    --secrets ai-conn="$AI_CONN" \
    --env-vars APPLICATIONINSIGHTS_CONNECTION_STRING=secretref:ai-conn "APPLICATIONINSIGHTS_ROLE_NAME=$name" "$@" \
    -o none
}

deploy() {
  local tag="${1:-m5}"
  AI_CONN=$(ai_conn)
  if ! az containerapp env show -n "$ENV_NAME" -g "$RG" -o none 2>/dev/null; then
    log "Container Apps environment $ENV_NAME (console logs -> $LAW)"
    local WS_ID WS_KEY
    WS_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
    WS_KEY=$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LAW" --query primarySharedKey -o tsv)
    az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$LOCATION" \
      --logs-workspace-id "$WS_ID" --logs-workspace-key "$WS_KEY" -o none
  fi
  acr_creds

  # back-ends first (internal ingress); order service needs the product service URL
  create_app petstoreproductservice internal "$tag"
  create_app petstorepetservice     internal "$tag"
  create_app petstoreorderservice   internal "$tag" "PETSTOREPRODUCTSERVICE_URL=https://$(fqdn petstoreproductservice)"

  # web front-end last (external ingress)
  create_app "$WEB" external "$tag" \
    "PETSTOREPETSERVICE_URL=https://$(fqdn petstorepetservice)" \
    "PETSTOREPRODUCTSERVICE_URL=https://$(fqdn petstoreproductservice)" \
    "PETSTOREORDERSERVICE_URL=https://$(fqdn petstoreorderservice)"
  status
}

web() {
  local tag="${1:?usage: web <tag>}"
  log "New $WEB revision with image tag $tag"
  az containerapp update -n "$WEB" -g "$RG" --image "$ACR_SERVER/$WEB:$tag" \
    --query "{revision:properties.latestRevisionName, image:properties.template.containers[0].image}" -o table
}

error_switch() {
  case "${1:-}" in
    on)  az containerapp update -n "$WEB" -g "$RG" --set-env-vars PETSTORE_SIMULATE_ERROR=true  -o none ;;
    off) az containerapp update -n "$WEB" -g "$RG" --set-env-vars PETSTORE_SIMULATE_ERROR=false -o none ;;
    *)   echo "usage: error on|off"; exit 1 ;;
  esac
  log "PETSTORE_SIMULATE_ERROR set ($1) - new revision created"
}

verify() {
  for a in "${ALL[@]}"; do
    echo "== $a"
    az containerapp logs show -n "$a" -g "$RG" --tail 300 --format text 2>/dev/null \
      | grep -i -e "Java Agent" -e "Fail to runtime attach" | head -3 || echo "   (no agent line yet - container still starting?)"
  done
}

kql_session() {
  local sid="${1:?usage: kql-session <sessionId from the page footer>}"
  ai_query "union traces, customEvents, requests, dependencies, exceptions, pageViews
| where timestamp > ago(1d)
| where tostring(customDimensions.session_Id) == '$sid' or tostring(customDimensions.sessionId) == '$sid' or message has '$sid'
| summarize items = count() by itemType, cloud_RoleName
| order by items desc" 1d
}

kql_errors() {
  ai_query "exceptions
| where timestamp > ago(1h)
| where outerMessage contains 'Cannot move further' or innermostMessage contains 'Cannot move further'
| summarize exceptionCount = count(), estimatedWithSampling = sum(itemCount)" 1h
}

metric() {
  az monitor app-insights metrics show --app "$AI" -g "$RG" \
    --metric customMetrics/ProductsReturnedCount --aggregation avg count --interval PT5M --offset 1h -o json
}

scale() {
  local min="${1:?usage: scale <min replicas>}"
  for a in "${ALL[@]}"; do
    az containerapp update -n "$a" -g "$RG" --min-replicas "$min" -o none && echo "$a -> min $min"
  done
}

status() {
  log "Container apps in $RG"
  az containerapp list -g "$RG" \
    --query "[].{name:name, fqdn:properties.configuration.ingress.fqdn, external:properties.configuration.ingress.external, revision:properties.latestRevisionName, image:properties.template.containers[0].image}" -o table
}

cleanup() {
  log "Deleting resource group $RG (App Insights, workspace, environment, apps)"
  az group delete -n "$RG" --yes --no-wait
}

case "${1:-}" in
  infra)       infra ;;
  build)       build "${2:-m5}" ;;
  deploy)      deploy "${2:-m5}" ;;
  web)         web "${2:-}" ;;
  error)       error_switch "${2:-}" ;;
  verify)      verify ;;
  kql-session) kql_session "${2:-}" ;;
  kql-errors)  kql_errors ;;
  metric)      metric ;;
  scale)       scale "${2:-}" ;;
  status)      status ;;
  cleanup)     cleanup ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
