# PetStore on Azure (CloudX Modules 3-4)

Updated PetStore solution used for the EPAM CloudX "Associate MS Azure Developer (Java)" tasks:
- **Module 3** - Azure App Services
- **Module 4** - Azure Container Apps (see section below)

---

## Module 3 - App Services

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

---

## Module 4 - Azure Container Apps

All four services run as separate Container Apps in one environment (`module4-env`, East US, resource group `module4-rg`), pulling images from `ajitjhacloudxacr.azurecr.io`.

| Container App | Image | Ingress | Scale (HTTP, 10 concurrent requests) |
|---|---|---|---|
| `petstorepetservice` | `petstorepetservice:v1` | external, port 8080 | min 1 / max 4 |
| `petstoreproductservice` | `petstoreproductservice:v1` | external, port 8080 | min 1 / max 4 |
| `petstoreorderservice` | `petstoreorderservice:v1` | external, port 8080 | min 1 / max 4 |
| `petstoreapp` (Web) | `petstoreapp:v1` -> `v2` | external, port 8080 | min 1 / max 2, **Multiple revision mode** |

Environment variables (https FQDNs of the APIs):
- `petstoreapp`: `PETSTOREPETSERVICE_URL`, `PETSTOREPRODUCTSERVICE_URL`, `PETSTOREORDERSERVICE_URL`
- `petstoreorderservice`: `PETSTOREPRODUCTSERVICE_URL`

### Files added for Module 4
- `k6/load-test-module4.js` - ramps to 100 virtual users and calls the three APIs in parallel (`http.batch`) to trigger HTTP autoscaling. Result: each API scaled 1 -> 4 replicas in ~45 s, 202k requests, 0% errors, p95 251 ms.
- `scripts/deploy-module4.sh` - Azure CLI automation:
  ```bash
  export MSYS_NO_PATHCONV=1            # Git Bash on Windows
  ./scripts/deploy-module4.sh deploy                    # env + 3 APIs + web (v1), env vars, autoscaling
  ./scripts/deploy-module4.sh new-revision v2           # new web revision, 0% traffic
  ./scripts/deploy-module4.sh canary <blueRev> <greenRev> 20
  ./scripts/deploy-module4.sh bluegreen <greenRev> <blueRev>
  ./scripts/deploy-module4.sh rollback <blueRev> <greenRev>
  ./scripts/deploy-module4.sh status
  ./scripts/deploy-module4.sh cleanup
  ```

### Revisions / traffic
- `petstoreapp--0000001` (image v1, label `blue`) and `petstoreapp--v2` (image v2, label `green`).
- Canary: 80% blue / 20% green. Blue/Green: 100% green, blue deactivated (kept for rollback).
- Verify which revision serves the main URL (revision name is printed in the page footer):
  ```bash
  for i in $(seq 1 50); do curl -s https://petstoreapp.<env-domain>/ | grep -o 'petstoreapp--[a-z0-9]*' | head -1; done | sort | uniq -c
  ```
