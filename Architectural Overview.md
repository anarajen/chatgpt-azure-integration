# 🏗️ Architecture Overview – Krisplus ChatGPT (STG)

## 🔹 High-Level Flow

User → DNS → Application Gateway → Container App → Azure Search / OpenAI → Response

---

## 🔹 Components

### 1. Entry Layer

* **DNS**
  Routes `stg-chatgpt.nonprod-krispay.com` to Application Gateway

* **Application Gateway (Shared)**

  * SSL termination
  * Request routing (listener, rule, backend pool)
  * Forwards traffic to Container App (private endpoint)

---

### 2. Network Layer

* **Virtual Network:** `DEVUAT-APP-VNET`

* **Subnet:** Dedicated `/27` subnet for Container Apps

* **Private DNS Zone:**

  * Resolves Container App private FQDN
  * Enables internal communication from App Gateway

* **Access Model:**

  * Container App is **not publicly exposed**
  * Only reachable via Application Gateway

---

### 3. Compute Layer

* **Azure Container App**

  * Name: `stg-krisplus-chatgpt-app`
  * Runtime: API backend (Node.js)
  * Scaling:

    * Min replicas: 1
    * Max replicas: 3

---

### 4. AI & Data Layer

* **Azure AI Search:** `stg-kp-search`

  * Indexes:

    * `chatgpt-deal-index`
    * `chatgpt-merchant-index`
    * `chatgpt-privielge-index`

* **Azure OpenAI (via App)**

  * Used for response generation
  * Pattern: Retrieval-Augmented Generation (RAG)

---

### 5. Identity & Security

* **Managed Identity (MSI)**

  * Container App → ACR (AcrPull)
  * Container App → Azure Search (read access)
  * App Gateway → Key Vault (SSL certificate)

* **No secrets stored in code**

---

### 6. Container Registry

* **Azure Container Registry (Shared)**

  * `krisplusregistry.azurecr.io`

* Flow:

  1. Image built via CI/CD
  2. Pushed to ACR
  3. Pulled by Container App using MSI

---

### 7. Monitoring

* **Log Analytics Workspace**
* **Application Insights**

Used for:

* Logs
* Metrics
* Performance monitoring

---

## 🔹 End-to-End Request Flow

1. User accesses application URL
2. DNS resolves to Application Gateway
3. Application Gateway validates SSL and routes request
4. Request forwarded to Container App (private)
5. Application:

   * Queries Azure Search
   * Sends context to OpenAI
6. Response generated and returned to user

---

## 🔹 Key Design Principles

* Private backend (no public exposure)
* Centralized ingress via Application Gateway
* RBAC-based access (Managed Identity)
* Scalable compute using Container Apps
* Shared infrastructure across environments (DEV/UAT/STG)

---

## ⚠️ Notes

* Application Gateway is shared — changes must be validated carefully
* Subnet must not overlap with existing address space
* Proper RBAC roles required for cross-resource access
