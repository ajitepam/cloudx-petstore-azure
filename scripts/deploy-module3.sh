#!/bin/bash
# Module 3 (App Services) - automated deployment of the PetStore with Azure CLI.
# Prerequisites: az login (correct subscription selected), images already pushed to ACR
#   (<acr>.azurecr.io/petstoreapp|petstorepetservice|petstoreproductservice|petstoreorderservice:v1),
#   ACR admin user enabled.
# Usage: ./deploy-module3.sh            (create everything)
#        ./deploy-module3.sh cleanup    (delete the resource group)
set -euo pipefail

# ---------- Variables ----------
PREFIX="ajitjha"
RG_NAME="petstore-rg"
LOCATION1="centralus"                     # APIs + Web region 1
LOCATION2_CANDIDATES="westus3 westus2 canadacentral northcentralus southcentralus"
ACR_NAME="ajitjhacloudxacr"
TAG="v1"
SKU="S1"                                  # S1 = slots + autoscale
TM_NAME="${PREFIX}-petstore-tm"

ACR_SERVER="${ACR_NAME}.azurecr.io"
PET_URL="https://${PREFIX}-petservice.azurewebsites.net"
PRODUCT_URL="https://${PREFIX}-productservice.azurewebsites.net"
ORDER_URL="https://${PREFIX}-orderservice.azurewebsites.net"

log() { echo -e "\n==> $*"; }

# ---------- Functions ----------
register_providers() {
  for ns in Microsoft.Web Microsoft.ContainerRegistry Microsoft.Insights Microsoft.Network; do
    az provider register --namespace "$ns" --output none
  done
}

create_app_service_plan() {        # $1 name  $2 location  -> returns 0/1 (quota may be 0)
  log "Creating App Service plan $1 in $2"
  az appservice plan create --name "$1" --resource-group "$RG_NAME" --location "$2" \
    --is-linux --sku "$SKU" --tags "Project=PetStore" --output none
}

create_web_app() {                 # $1 app name  $2 plan  $3 image repo
  log "Creating web app $1 on $2 ($3:$TAG)"
  az webapp create --resource-group "$RG_NAME" --plan "$2" --name "$1" \
    --container-image-name "${ACR_SERVER}/$3:${TAG}" --output none
  az webapp config appsettings set --resource-group "$RG_NAME" --name "$1" \
    --settings WEBSITES_PORT=8080 --output none
}

configure_web_settings() {         # $1 web app name
  az webapp config appsettings set --resource-group "$RG_NAME" --name "$1" --output none --settings \
    PETSTOREPETSERVICE_URL="$PET_URL" PETSTOREPRODUCTSERVICE_URL="$PRODUCT_URL" \
    PETSTOREORDERSERVICE_URL="$ORDER_URL" PETSTORE_SECURITY_ENABLED=false APPLICATIONINSIGHTS_ENABLED=false
}

configure_autoscale() {            # rules-based autoscale on the API plan
  log "Configuring autoscale on plan-api-r1"
  az monitor autoscale create --resource-group "$RG_NAME" --name "plan-api-r1-autoscale" \
    --resource "plan-api-r1" --resource-type "Microsoft.Web/serverfarms" \
    --min-count 1 --max-count 3 --count 1 --output none
  az monitor autoscale rule create --resource-group "$RG_NAME" --autoscale-name "plan-api-r1-autoscale" \
    --condition "CpuPercentage > 50 avg 5m" --scale out 1 --cooldown 5 --output none
  az monitor autoscale rule create --resource-group "$RG_NAME" --autoscale-name "plan-api-r1-autoscale" \
    --condition "CpuPercentage < 30 avg 5m" --scale in 1 --cooldown 5 --output none
}

create_staging_slot() {            # staging slot + continuous deployment from ACR
  log "Creating staging slot for ${PREFIX}-petstoreapp-r1"
  az webapp deployment slot create --resource-group "$RG_NAME" --name "${PREFIX}-petstoreapp-r1" \
    --slot staging --configuration-source "${PREFIX}-petstoreapp-r1" --output none
  az webapp config container set --resource-group "$RG_NAME" --name "${PREFIX}-petstoreapp-r1" --slot staging \
    --container-image-name "${ACR_SERVER}/petstoreapp:v2" --output none
  az webapp deployment container config --resource-group "$RG_NAME" --name "${PREFIX}-petstoreapp-r1" \
    --slot staging --enable-cd true --output none
  # Swap later with:
  # az webapp deployment slot swap -g $RG_NAME -n ${PREFIX}-petstoreapp-r1 --slot staging --target-slot production
}

create_traffic_manager() {         # $1 region-2 web app name
  log "Creating Traffic Manager profile $TM_NAME (Priority)"
  az network traffic-manager profile create --resource-group "$RG_NAME" --name "$TM_NAME" \
    --routing-method Priority --unique-dns-name "$TM_NAME" \
    --protocol HTTPS --port 443 --path "/" --ttl 60 --output none
  local i=1
  for app in "${PREFIX}-petstoreapp-r1" "$1"; do
    local id
    id=$(az webapp show --resource-group "$RG_NAME" --name "$app" --query id --output tsv)
    az network traffic-manager endpoint create --resource-group "$RG_NAME" --profile-name "$TM_NAME" \
      --type azureEndpoints --name "endpoint-$app" --target-resource-id "$id" --priority $i --output none
    i=$((i + 1))
  done
}

# ---------- Main ----------
if [[ "${1:-}" == "cleanup" ]]; then
  log "Deleting resource group $RG_NAME"
  az group delete --name "$RG_NAME" --yes --no-wait
  exit 0
fi

register_providers
log "Creating resource group $RG_NAME"
az group create --name "$RG_NAME" --location "$LOCATION1" --output none

create_app_service_plan "plan-web-r1" "$LOCATION1"
create_app_service_plan "plan-api-r1" "$LOCATION1"

# Region 2: free/trial subscriptions often have 0 S1 quota in some regions -> try a list
PLAN_R2=""
for loc in $LOCATION2_CANDIDATES; do
  if create_app_service_plan "plan-web-r2-$loc" "$loc"; then PLAN_R2="plan-web-r2-$loc"; break; fi
done
[[ -z "$PLAN_R2" ]] && { echo "No region with S1 quota found"; exit 1; }

create_web_app "${PREFIX}-petservice"     "plan-api-r1" "petstorepetservice"
create_web_app "${PREFIX}-productservice" "plan-api-r1" "petstoreproductservice"
create_web_app "${PREFIX}-orderservice"   "plan-api-r1" "petstoreorderservice"
# OrderService calls ProductService itself
az webapp config appsettings set --resource-group "$RG_NAME" --name "${PREFIX}-orderservice" \
  --settings PETSTOREPRODUCTSERVICE_URL="$PRODUCT_URL" --output none

create_web_app "${PREFIX}-petstoreapp-r1" "plan-web-r1" "petstoreapp"
create_web_app "${PREFIX}-petstoreapp-r2" "$PLAN_R2"    "petstoreapp"
configure_web_settings "${PREFIX}-petstoreapp-r1"
configure_web_settings "${PREFIX}-petstoreapp-r2"

configure_autoscale
create_staging_slot
create_traffic_manager "${PREFIX}-petstoreapp-r2"

log "Done. Open: http://${TM_NAME}.trafficmanager.net"
az resource list --resource-group "$RG_NAME" --query "[].{Name:name, Type:type, Location:location}" --output table
