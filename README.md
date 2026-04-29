[PROVISION_RUNBOOK.md](https://github.com/user-attachments/files/27112535/PROVISION_RUNBOOK.md)
# Krisplus ChatGPT MCP — Infra Provisioning Runbook

This runbook is self-contained. You do not need to read any other doc to provision
a new environment or migrate an existing one to VNet.

> **Last reviewed:** 2026-04-08

---

## 1. Prerequisites

### Tools
```bash
# Azure Developer CLI (azd) — v1.x or later
winget install Microsoft.Azd          # Windows
brew install azure/azd/azd            # macOS

# Azure CLI
winget install Microsoft.AzureCLI     # Windows
brew install azure-cli                # macOS

# jq (used by the App Gateway update script inside Bicep)
winget install jqlang.jq              # Windows
brew install jq                       # macOS
```

### Azure Roles Required (on the target subscription)

| Role | Scope | Why |
|------|-------|-----|
| Contributor | Target resource group | Create/update all environment resources |
| Contributor | Shared resource group (`SHARED-KRISPLUS-CHATGPT-RG`) | AcrPull role assignment on registry |
| Contributor | App Gateway resource group (`DEVUAT-ASE-RG`) | App Gateway RBAC module + subnet creation |
| Network Contributor | App Gateway resource (`DEVUAT-ASE-APPGWV2-03`) | Backend pool update (GET+PUT on full App Gateway config) |
| Managed Identity Operator | Existing UAMI on App Gateway (e.g. `KP_NonProd_AppGw_KV_MI`) | Linked authorization — the PUT body references the UAMI, requiring `assign/action` |
| User Access Administrator | Search service resource group | Grant Search Index Data Reader to Container App MSI |
| User Access Administrator | Shared registry resource group | Grant AcrPull to Container App MSI |

> **Why Managed Identity Operator?** `az network application-gateway address-pool update` does a full GET+PUT. The PUT body includes every UAMI attached to the App Gateway. ARM's linked authorization check requires `assign/action` on each referenced UAMI — even though we are not modifying the identity assignment.

### Login
```bash
az login
azd auth login
az account set --subscription <SUBSCRIPTION_ID>
# Non-prod: 9048e167-320c-4204-8671-f4bf4557b1d5
```

---

## 2. Repository Setup

```bash
unzip krisplus-mcp-infra-handover-*.zip -d krisplus-mcp-infra
cd krisplus-mcp-infra

# Key files:
#   infra/                     — Bicep templates (do not modify)
#   azd-staging.env.sample     — variable template for staging
#   infra/main.parameters.json — maps env vars to Bicep params (reference only)
```

---

## 3. Pre-Provision Discovery

Run these commands to find values you need for the env file.

### Available subnet space in DEVUAT-APP-VNET
```bash
# List existing subnets to find a free /27 within the VNet's address space
az network vnet subnet list \
  --vnet-name DEVUAT-APP-VNET \
  --resource-group DEVUAT-ASE-RG \
  --query "[].{name:name, prefix:addressPrefix, delegation:delegations[0].serviceName}" \
  -o table
```
Choose a free `/27` block within the VNet's existing address spaces (`10.162.137.0/24` and `10.163.144.0/24`). See the CIDR table in IAC_REVIEW.md Section 1 for current allocations.

> **Important:** Subnet size is permanent after the managed environment is attached. A `/27` supports ~90 total replicas across all apps in the environment (~45 during zero-downtime rollouts).

### Log Analytics workspace
```bash
az monitor log-analytics workspace list \
  --query "[].{name:name, rg:resourceGroup}" -o table
```

### App Gateway details
```bash
# List backend pools
az network application-gateway address-pool list \
  --gateway-name <APP_GATEWAY_NAME> \
  --resource-group <APP_GATEWAY_RG> \
  --query "[].name" -o table

# List UAMIs attached to the App Gateway (needed for linked-auth)
az network application-gateway show \
  --name <APP_GATEWAY_NAME> \
  --resource-group <APP_GATEWAY_RG> \
  --query "identity.userAssignedIdentities" -o json \
  | jq -r 'keys[] | split("/") | last'

# Get the App Gateway subnet name
az network application-gateway show \
  --name <APP_GATEWAY_NAME> \
  --resource-group <APP_GATEWAY_RG> \
  --query "gatewayIPConfigurations[0].properties.subnet.id" -o tsv \
  | awk -F/ '{print $NF}'
```

### Azure Search service
```bash
az resource list \
  --resource-type "Microsoft.Search/searchServices" \
  --query "[].{name:name, rg:resourceGroup}" -o table
```

---

## 4. Environment File Setup

```bash
# Create the azd environment
azd env new <env-name>        # e.g. dev, uat, stg

# Copy the sample directly — it has no comments so it is usable as-is
cp azd-<env-name>.env.sample .azure/<env-name>/.env

# Open the file and fill in all placeholder values (e.g. CONTAINER_APP_SUBNET_ADDRESS_PREFIX)
# then save it.

# Notes:
# - For UAT: set CONTAINER_APP_ENVIRONMENT_EXISTS=true and use the exact same
#   CONTAINER_APP_ENVIRONMENT_NAME as dev (shared managed environment — see note below)
# - For STG: set CONTAINER_APP_ENVIRONMENT_EXISTS=false — staging has its own standalone
#   managed environment and subnet
# - azd parses the file as plain KEY=value pairs — do NOT add comments or blank lines

azd env select <env-name>
```

### Application runtime variables (Section B of env files)

These variables are injected into the Container App and are owned by the app team:

| Variable | Purpose |
|---|---|
| `AZURE_SEARCH_ENDPOINT` | Azure Search service URL (e.g. `https://dev-kp-search.search.windows.net`) |
| `AZURE_SEARCH_MERCHANT_INDEX` | Partner/merchant index name |
| `AZURE_SEARCH_DEALS_INDEX` | Deals/vouchers index name |
| `AZURE_SEARCH_PRIVILEGE_INDEX` | Privileges index name |
| `STATIC_API_URL` | Category/tag data API endpoint (required for filtering) |
| `WIDGET_DOMAIN` | Full HTTPS URL of this server for MCP Apps sandbox (e.g. `https://dev-chatgpt.nonprod-krispay.com`) |
| `VITE_KRISPLUS_UNIVERSAL_LINK` | Deep link to Kris+ app (e.g. `https://ca-dev.nonprod-krispay.com`) |
| `WIDGET_CSP_RESOURCE_DOMAINS` | Comma-separated CSP `img-src`/`style-src` domains |
| `WIDGET_CSP_CONNECT_DOMAINS` | Comma-separated CSP `fetch`/`xhr` domains |
| `NODE_ENV` | `development` for dev/uat, `production` for staging/prod |

**CI/CD-only variables** — managed in Azure DevOps variable groups, NOT in env files:
- `MIN_SCORE_THRESHOLD` — Azure Search score filter (default: `0.01`)
- `CORS_ALLOWED_ORIGINS` — allowed origins (e.g. `https://chatgpt.com`)
- `WORKERS` — worker process count (empty = auto CPU count)
- `KRISPLUS_API_BASE_URL` — Kris+ API endpoint (logging/debug only)
- `KRISPLUS_COUNTRY` — country code (logging/debug only)

### Infrastructure variables

| Variable | How to find the value |
|---|---|
| `RESOURCE_GROUP_NAME` | Name of the RG for this environment (e.g. `DEV-KRISPLUS-CHATGPT-RG`) |
| `SHARED_RESOURCE_GROUP_NAME` | Shared RG containing the ACR (e.g. `SHARED-KRISPLUS-CHATGPT-RG`) |
| `SHARED_LOCATION` | Azure region for shared resources (e.g. `southeastasia`) |
| `SHARED_CONTAINER_REGISTRY_NAME` | Shared ACR name (e.g. `krisplusregistry`) |
| `SHARED_CONTAINER_REGISTRY_EXISTS` | `true` (always — prevents ACR recreation) |
| `CONTAINER_APP_ENVIRONMENT_NAME` | Managed environment name. **Dev/UAT:** use the same name (shared env). **STG:** use a unique name (standalone env). |
| `CONTAINER_APP_ENVIRONMENT_EXISTS` | `false` for dev (creates env) and stg (standalone). `true` for UAT (reuses dev's environment). |
| `CONTAINER_APP_ENVIRONMENT_RESOURCE_GROUP_NAME` | RG where the managed environment lives. Required when `CONTAINER_APP_ENVIRONMENT_EXISTS=true`. |
| `CONTAINER_APP_NAME` | Container App name (unique per environment, e.g. `dev-krisplus-chatgpt-app`) |
| `LOG_WORKSPACE_RG` | Log Analytics workspace resource group (e.g. `DEVUAT-ASE-RG`) |
| `LOG_WORKSPACE_NAME` | Log Analytics workspace name (e.g. `dev-workspace`) |
| `CONTAINER_APP_SUBNET_NAME` | Subnet name to create in DEVUAT-APP-VNET (e.g. `KRISPLUS-CHATGPT-DEV-SUBNET`) |
| `CONTAINER_APP_SUBNET_ADDRESS_PREFIX` | Free `/27` CIDR from discovery step (e.g. `10.163.144.128/27`) |
| `APP_GATEWAY_VNET_NAME` | VNet containing the App Gateway (e.g. `DEVUAT-APP-VNET`) |
| `APP_GATEWAY_VNET_RESOURCE_GROUP` | App Gateway VNet's resource group (e.g. `DEVUAT-ASE-RG`) |
| `APP_GATEWAY_NAME` | App Gateway name (e.g. `DEVUAT-ASE-APPGWV2-03`) |
| `APP_GATEWAY_BACKEND_POOL_NAME` | Backend pool for this environment (from discovery step, e.g. `DEV-KRISPLUS-CHATGPT-POOL`) |
| `APP_GATEWAY_EXISTING_UAMI_NAME` | UAMI attached to App Gateway (from discovery step, e.g. `KP_NonProd_AppGw_KV_MI`). Leave empty if none. |
| `APP_GATEWAY_SUBNET_NAME` | App Gateway's own subnet name (from discovery step, e.g. `DEVUAT-APPGWV2-SUBNET`) |
| `APP_GATEWAY_HTTP_SETTINGS_NAME` | HTTP settings name to create/update (e.g. `DEV-KRISPLUS-CHATGPT-HTTPSetting`) |
| `APP_GATEWAY_LISTENER_NAME` | HTTPS listener name to create/update (e.g. `DEV-KRISPLUS-CHATGPT-LISTENER`) |
| `APP_GATEWAY_RULE_NAME` | Routing rule name to create/update (e.g. `DEV-KRISPLUS-CHATGPT-RULE`) |
| `APP_GATEWAY_SSL_CERT_NAME` | Existing SSL certificate name on the App Gateway (e.g. `nonprodkrispaydotcom-sectigo-Expiry-2026`) |
| `APP_GATEWAY_HOSTNAME` | Public hostname for the HTTPS listener (e.g. `dev-chatgpt.nonprod-krispay.com`) |
| `CONTAINER_MIN_REPLICAS` | `0` for non-prod, `≥1` for prod |
| `CONTAINER_MAX_REPLICAS` | Scaling limit — keep in mind the `/27` capacity ceiling (~90 replicas total) |
| `CONTAINER_CPU` / `CONTAINER_MEMORY` | `0.5` / `1.0Gi` for non-prod; `1.0`+ for prod |
| `CONTAINER_PORT` | Container ingress port. Default: `3000` (do not change unless necessary) |
| `AZURE_SEARCH_SERVICE_NAME` | From discovery step (e.g. `dev-kp-search`). Leave empty to skip RBAC role assignment. |
| `AZURE_SEARCH_RESOURCE_GROUP` | From discovery step (e.g. `KP_SEARCH`). Required when `AZURE_SEARCH_SERVICE_NAME` is set. |
| `BOOTSTRAP_IMAGE` | Container image for initial provision (default: hello-world). CI/CD pipeline replaces with real image. |
| `INFRASTRUCTURE_SUBNET_ID` | Advanced: pre-existing subnet ID. Ignored when `CONTAINER_APP_SUBNET_NAME` is set. |

> **Managed environment topology:**
> - **Dev + UAT** share a single managed environment and subnet. Dev's `azd provision` creates it. UAT must:
>   1. Set `CONTAINER_APP_ENVIRONMENT_EXISTS=true`
>   2. Use the **exact same `CONTAINER_APP_ENVIRONMENT_NAME`** as dev
>   3. Set `CONTAINER_APP_ENVIRONMENT_RESOURCE_GROUP_NAME` to the RG where dev created the environment
>
>   The Bicep references the environment as an `existing` resource and does NOT recreate it. Using a different name or omitting the RG will create a second environment and consume a second subnet.
>
> - **Staging** has its own standalone managed environment (`CONTAINER_APP_ENVIRONMENT_EXISTS=false`, unique `CONTAINER_APP_ENVIRONMENT_NAME`). Its subnet is independent of dev/uat.
>

> **Application runtime variables (Section B)** — coordinate with the app team. These are
> injected into the Container App as environment variables (search endpoints, widget URLs, etc.).
> The app team owns these values; do not guess them. See the table above for what each variable does.

---

## 5. Provision — Net-New Environment

```bash
azd env select <env-name>
azd provision
```

Bicep will create (on first provision for the shared environment):
- Resource group (if it doesn't exist)
- Container Apps subnet in `DEVUAT-APP-VNET` (delegated to `Microsoft.App/environments`)
- Container Apps managed environment (Workload Profiles v2, `internal: true`)
- Container App (running bootstrap hello-world image)
- Application Insights (per-app instance)
- Private DNS zone + wildcard A record + link to `DEVUAT-APP-VNET`
- App Gateway backend pool update (points pool to Container App private FQDN)
- AcrPull role — Container App system MSI → shared ACR
- Search Index Data Reader role — Container App system MSI → Azure Search service

On subsequent provisions into the same shared environment (uat, stg):
- Managed environment and subnet already exist — referenced as `existing`, not recreated
- A new Container App, App Insights, DNS record, backend pool, and role assignments are created

**After provision:** trigger the CI/CD pipeline to deploy the real application image.
The Container App will serve a hello-world placeholder until the pipeline completes.

---

## 6. Provision — Migrating an Existing Public Environment to VNet

> ⚠️ Azure does not allow adding VNet to an existing public managed environment in-place.
> The environment must be deleted and recreated. Expect **10–20 minutes of downtime**.
> All Container Apps in the shared environment will be destroyed and recreated.

```bash
azd env select <env-name>

# Ensure VNet vars are filled in .azure/<env>/.env before proceeding

# Step 1 — destroy Container App + managed environment (NOT the shared registry)
azd down

# Step 2 — provision fresh with VNet
azd provision

# Step 3 — trigger CI/CD pipeline to restore the real application image
```

`azd down` only destroys resources in the environment resource group. It does **not** touch:
- `SHARED-KRISPLUS-CHATGPT-RG` (container registry)
- The App Gateway or its VNet
- The Azure Search service
- The Log Analytics workspace

**After recreation:** The system-assigned MSI on each Container App is new (different principal ID, zero role assignments). Both `acr-pull-rbac.bicep` and `azure-search-rbac.bicep` re-run automatically during `azd provision` to re-grant roles. The ACR registry config (`registries`) is **not** set by Bicep (to avoid a chicken-and-egg with the AcrPull role) — the CI/CD pipeline adds it via `az containerapp registry set --identity system` before each deploy. If provisioning fails before those modules execute, grant roles manually:
```bash
# AcrPull
az role assignment create \
  --assignee "<new-principalId>" \
  --role "AcrPull" \
  --scope "<acrResourceId>"

# Search Index Data Reader
az role assignment create \
  --assignee "<new-principalId>" \
  --role "Search Index Data Reader" \
  --scope "<searchServiceResourceId>"

# Then trigger CI/CD pipeline — it will add the ACR registry and deploy the image
```

---

## 7. Post-Provision Checklist

```bash
# 1. Verify the App Gateway backend pool was updated
az network application-gateway address-pool show \
  --gateway-name <APP_GATEWAY_NAME> \
  --resource-group <APP_GATEWAY_RG> \
  --name <APP_GATEWAY_BACKEND_POOL_NAME> \
  --query "properties.backendAddresses" -o json
# Expected: [{"fqdn": "<container-app-name>.<managed-env-default-domain>"}]

# 2. Verify AcrPull role assignment
az role assignment list \
  --scope "<acrResourceId>" \
  --query "[?roleDefinitionName=='AcrPull'].{principal:principalId, type:principalType}" \
  -o table

# 3. Verify Search Index Data Reader role assignment
az role assignment list \
  --scope "<searchServiceResourceId>" \
  --query "[?roleDefinitionName=='Search Index Data Reader'].{principal:principalId, type:principalType}" \
  -o table

# 4. Verify Container App is running (after CI/CD pipeline completes)
az containerapp show \
  --name <CONTAINER_APP_NAME> \
  --resource-group <RESOURCE_GROUP_NAME> \
  --query "{image: properties.template.containers[0].image, replicas: properties.template.scale}" \
  -o json

# 5. Health check via App Gateway
#    NOTE: Requires App Gateway listener + external DNS to be configured by the
#    network team first. If not yet set up, verify the Container App directly
#    from within the VNet or check step 4 output instead.
curl -s https://<WIDGET_DOMAIN>/health
# Expected: {"status":"ok"}
```

---

## 8. Failure Reference

| Error | Cause | Fix |
|---|---|---|
| `LinkedAuthorizationFailed` on App Gateway PUT | RBAC not yet propagated (can take up to 10 min) | Re-run `azd provision` — the backend update script retries automatically |
| `Search returns 403` | Container App MSI has no Search Index Data Reader | Re-run `azd provision` — `azure-search-rbac.bicep` grants it idempotently |
| `unable to pull image using Managed identity` | Container App MSI has no AcrPull | Re-run `azd provision` — `acr-pull-rbac.bicep` grants it idempotently |
| `ApplicationGatewayCustomErrorStatusCodeIsInvalid` | Pre-existing invalid custom error on App Gateway | The update script strips invalid custom errors automatically — no action needed |
| Container App shows hello-world after provision | Expected — real image not deployed yet | Trigger the CI/CD pipeline |
| `azd provision` fails with subnet conflict | CIDR overlaps with an existing subnet in `DEVUAT-APP-VNET` | Pick a different `/27` (re-run discovery step 3) |
| Second `azd provision` creates new managed environment | `CONTAINER_APP_ENVIRONMENT_NAME` differs from existing shared env | Use the same name as the first provision. See ADR-004. |

---

## 9. Contacts

| Question | Contact |
|---|---|
| Section B app runtime variables | App team |
| App Gateway listener / hostname for WIDGET_DOMAIN | Network team |
| Azure Search index names for staging/prod | App team |
| CIDR allocation approval | Network team |

Architectural Overview:
Overall Flow
User → DNS → Application Gateway → Container App → Azure Search / OpenAI → Response

1. Entry Layer (DNS + Application Gateway)


User accesses:
https://stg-chatgpt.nonprod-krispay.com


DNS resolves this domain to the public IP of Application Gateway


Application Gateway:


Terminates SSL (using certificate)


Uses listener + rule + backend pool


Routes traffic to backend (Container App)





2. Network Layer (VNet + Private Access)


All resources are inside:
VNet: DEVUAT-APP-VNET


Container Apps run in a dedicated subnet (/27)


Container App is internal (no public access)


Private DNS zone is used to resolve:
Container App private FQDN → private IP


Application Gateway (inside same VNet) connects to Container App using private network



3. Compute Layer (Container Apps)


Container App name:
stg-krisplus-chatgpt-app


Runs application (likely Node.js API)


Scaling:


Minimum replicas: 1


Maximum replicas: 3




Automatically scales based on load



4. Data + AI Layer


Azure AI Search:
stg-kp-search


Indexes used:


chatgpt-deal-index


chatgpt-merchant-index


chatgpt-privielge-index




Flow:


App receives user request


Queries Azure Search for relevant data


Sends context to OpenAI (RAG pattern)


Gets AI-generated response


Returns response to user





5. Identity & Security


Managed Identity (MSI) is used instead of passwords


Used for:


Container App → pull image from ACR (AcrPull role)


Container App → access Azure Search (reader role)


Application Gateway → access SSL cert from Key Vault



6. Container Registry (ACR)


Shared registry:
krisplusregistry.azurecr.io


Flow:


Image built via CI/CD


Pushed to ACR


Container App pulls image using managed identity





7. Monitoring


Log Analytics Workspace


Application Insights


Used for:


Logs


Metrics


Performance monitoring



🔁 End-to-End Request Flow


User opens:
https://stg-chatgpt.nonprod-krispay.com


DNS resolves to Application Gateway


Application Gateway:


Validates SSL


Applies routing rule




Request sent to Container App (private endpoint)


Container App:


Processes request


Queries Azure Search


Calls OpenAI




Response generated


Response flows back:
Container App → App Gateway → User



⚠️ Important Characteristics


No public access to backend (secure design)


Uses private networking (VNet + DNS)


Shared infrastructure (App Gateway reused across environments)


Uses RBAC instead of secrets


Auto-scaling compute (Container Apps)



🧾 Final Summary
This architecture is a secure, private, scalable ChatGPT-based application on Azure where:


Application Gateway handles traffic entry


Container Apps run the backend


Azure Search + OpenAI provide intelligence


Everything runs inside a private network using RBAC



If you want next, I can give:


A one-paragraph explanation for management


OR a deep infra breakdown (what azd actually creates vs links)


