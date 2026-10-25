# PetStore on Azure App Services (CloudX Module 3)

Updated PetStore solution used for the EPAM CloudX "Associate MS Azure Developer (Java)" Module 3 task.

## Services
| Service | Folder | Azure web app |
|---|---|---|
| Web (UI) | `petstoreapp` | `ajitjha-petstoreapp-r1` (Central US, + `staging` slot), `ajitjha-petstoreapp-r2` (West US 3) |
| Pet API | `petstorepetservice` | `ajitjha-petservice` (Central US) |
| Product API | `petstoreproductservice` | `ajitjha-productservice` (Central US) |
| Order API | `petstoreorderservice` | `ajitjha-orderservice` (Central US) |

Images: `ajitjhacloudxacr.azurecr.io/<service>:v1` (and `petstoreapp:v2` for the slot demo).

## Changes for Module 3
- `petstoreapp/src/main/resources/templates/home.html` - v2 text used to demonstrate the staging slot, continuous deployment and swap.
- `k6/load-test.js` - load test used to trigger CPU-based autoscale of the APIs.
- `scripts/deploy-module3.sh` - optional Azure CLI automation (plans, web apps, app settings, autoscale, slot, Traffic Manager; `cleanup` argument deletes the resource group).

## Configuration notes
- Every web app: `WEBSITES_PORT=8080` (Spring Boot listens on 8080).
- Web: `PETSTOREPETSERVICE_URL`, `PETSTOREPRODUCTSERVICE_URL`, `PETSTOREORDERSERVICE_URL` (https URLs).
- OrderService also needs `PETSTOREPRODUCTSERVICE_URL` (it calls ProductService).

## Run locally
```bash
cp .env.sample .env
docker compose up -d --build   # http://localhost:8080
```
