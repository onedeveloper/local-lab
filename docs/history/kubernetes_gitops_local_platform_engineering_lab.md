# Ephemeral Local Kubernetes Platform Engineering Lab: Multi-Cluster GitOps, Gateway API, Harbor, Gitea & Observability

> [!NOTE]
> **Historical Reference (Phase 1 Monorepo Walkthrough):** This document preserves the original Phase 1 greenfield guide where both the platform infrastructure and the sample e-commerce microservices (`orders-api`, `inventory-api`, `payments-api`) were built together inside a single repository.
>
> As of **Phase 2 (2026-11-04)**, `local-lab` has been refactored into an **app-agnostic Platform Infrastructure repository** (see the root [`README.md`](../../README.md) and [Part 8 of the Architecture & Roadmap](./platform_engineering_architecture_and_roadmap.md#part-8-phase-2-evolution--decoupling-platform-infrastructure-from-workload-repositories-2026-11-04)). Workload repositories now live separately and are onboarded via `./scripts/onboard-repo.sh`.

This guide walks through building a **100% local, ephemeral, enterprise-grade Kubernetes platform from an empty directory on macOS** (optimized for **OrbStack**).

### Core Philosophy: "Build It, Break It, Fix It, Wipe It"
This lab is designed as a **disposable chaos and learning sandbox**:
- **100% Greenfield:** Starts from an empty folder and generates every microservice, Kustomize overlay, Gateway config, test suite, CI workflow, and cluster from scratch.
- **100% Local Runtime:** Once bootstrapped, **zero traffic leaves your Mac**. Git hosting (**Gitea**), CI pipelines (**Gitea `act_runner`**), OCI Registry & CVE scanning (**Harbor + Trivy**), GitOps reconciliation (**Argo CD**), Edge Ingress (**Envoy Gateway**), and Observability (**Grafana + Prometheus + Loki**) all run locally on the `kind` Docker network.
- **GitHub as the Clean "Golden Seed", Local Gitea as the "Breakable Sandbox":**
  - Your clean baseline repo lives on **GitHub** (the `seed` remote, with `push` disabled by default so destructive experiments never pollute GitHub).
  - Your active **`origin`** remote points to **Local Gitea**. You can push broken Kustomize patches, bad image tags, failing code, or misconfigured routes to `origin`, debug the failure across Argo CD / Harbor / Grafana / Loki, and when you're done, nuke the entire environment and re-seed in minutes.

---

## Architecture Overview

```mermaid
flowchart TB
    subgraph GitHubCloud["GitHub.com (Optional 'Golden Seed' Backup)"]
        SeedRepo["Clean Baseline Repo\n(remote: seed, push=DISABLED during chaos)"]
    end

    subgraph Mac["macOS Host (OrbStack *.orb.local + Ephemeral 'kind' Docker Network)"]
        subgraph Tier1["Tier 1: Ephemeral Appliances (Docker Compose + Harbor)"]
            Gitea["Gitea Server (remote: origin)\nhttp://gitea.orb.local:3000"]
            Runner["Gitea act_runner\n(Local CI: E2E + Manifest Policy Tests)"]
            Harbor["Harbor Registry + Trivy Scanner\nhttp://harbor.orb.local:8085\nProjects: dev/ | prod/"]
            Gitea <--> Runner
        end

        subgraph Tier2["Tier 2: kind-admin (Platform Hub Cluster — Port 8070)"]
            ArgoCD["Argo CD Control Plane\n(Multi-Cluster Matrix ApplicationSet)"]
            Prom["Central Prometheus\n(NodePort 30090 Remote-Write Receiver)"]
            Loki["Central Loki\n(NodePort 30100 Multi-Cluster Log Store)"]
            Grafana["Central Grafana UI\nhttp://localhost:8070 (NodePort 30080)"]
            Prom --> Grafana
            Loki --> Grafana
        end

        subgraph Tier3A["Tier 3A: kind-dev (Dev Workload Cluster — Port 8080)"]
            DevGW["Envoy Gateway (NodePort 30080)\nHTTPRoute: orders.dev.local"]
            DevOrders["orders-api (Public Edge)\nLOG_LEVEL=debug"]
            DevInv["inventory-api (Internal ClusterIP)"]
            DevPay["payments-api (Internal ClusterIP)"]
            DevAgents["Promtail + Prometheus Agent"]

            DevGW -->|North-South| DevOrders
            DevOrders -->|East-West: POST /reserve| DevInv
            DevOrders -->|East-West: POST /charge| DevPay
        end

        subgraph Tier3B["Tier 3B: kind-prod (Prod Workload Cluster — Port 8090)"]
            ProdGW["Envoy Gateway (NodePort 30080)\nHTTPRoute: orders.prod.local"]
            ProdOrders["orders-api (Public Edge)\nLOG_LEVEL=info, replicas=3"]
            ProdInv["inventory-api (Internal ClusterIP)"]
            ProdPay["payments-api (Internal ClusterIP)"]
            ProdAgents["Promtail + Prometheus Agent"]

            ProdGW -->|North-South| ProdOrders
            ProdOrders -->|East-West: POST /reserve| ProdInv
            ProdOrders -->|East-West: POST /charge| ProdPay
        end
    end

    SeedRepo -.->|"Day-0 Clone or Greenfield Seed"| Gitea
    Gitea ==>|"1. Webhook / Branch Poll (dev & prod)"| ArgoCD
    ArgoCD ==>|"2a. Syncs dev branch -> https://dev-control-plane:6443"| Tier3A
    ArgoCD ==>|"2b. Syncs prod branch -> https://prod-control-plane:6443"| Tier3B

    Tier3A -.->|"3a. Pulls harbor.orb.local:8085/dev/*\n(imagePullSecret: harbor-pull-secret)"| Harbor
    Tier3B -.->|"3b. Pulls harbor.orb.local:8085/prod/*\n(imagePullSecret: harbor-pull-secret)"| Harbor

    DevAgents ==>|"4a. Push logs (:30100) & metrics (:30090)\n[cluster=dev]"| Tier2
    ProdAgents ==>|"4b. Push logs (:30100) & metrics (:30090)\n[cluster=prod]"| Tier2
```

---

## 1. Prerequisites Installation

Run in your Mac terminal with **OrbStack** running:

```bash
# 1. Install CLI utilities (Node >= 22 runs our zero-dependency E2E and manifest policy tests)
brew install kind kubectl kustomize helm argocd jq node skopeo

# 2. Verify runtime and versions
docker ps && kind version && kubectl version --client && helm version --short && node -v && skopeo -v
```

Map the local hostnames in `/etc/hosts` once:
```bash
sudo sh -c 'grep -q "orders.dev.local" /etc/hosts || echo "127.0.0.1 gitea.orb.local harbor.orb.local orders.dev.local orders.prod.local" >> /etc/hosts'
```

---

## 2. Greenfield Workspace Initialization (Empty Directory)

Start from a completely empty directory (`~/platform-lab`):

```bash
mkdir -p ~/platform-lab/{appliances,gitops-repo}
cd ~/platform-lab

# Create the shared 'kind' Docker network so Gitea, Harbor, and all 3 Kind clusters can talk directly
docker network inspect kind >/dev/null 2>&1 || docker network create kind
```

---

## 3. Tier 1: Spin Up Ephemeral Gitea, Actions Runner & Harbor

### Step 3.1: Start Gitea + Local Actions Runner (`docker compose`)
Create `~/platform-lab/appliances/docker-compose.yml`:

```bash
cat <<'EOF' > ~/platform-lab/appliances/docker-compose.yml
services:
  gitea:
    image: gitea/gitea:1.22
    container_name: gitea
    restart: always
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__server__DOMAIN=gitea.orb.local
      - GITEA__server__ROOT_URL=http://gitea.orb.local:3000/
      - GITEA__server__HTTP_PORT=3000
      - GITEA__security__INSTALL_LOCK=true
      - GITEA__service__DISABLE_REGISTRATION=false
      - GITEA__actions__ENABLED=true
      - GITEA__webhook__ALLOWED_HOST_LIST=*
    ports:
      - "3000:3000"
      - "2222:22"
    volumes:
      - ./gitea-data:/data
    networks:
      - kind

  gitea-runner:
    image: gitea/act_runner:latest
    container_name: gitea-runner
    restart: always
    depends_on:
      - gitea
    environment:
      - GITEA_INSTANCE_URL=http://gitea:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=${RUNNER_TOKEN:-}
      - GITEA_RUNNER_NAME=mac-local-runner
      - GITEA_RUNNER_LABELS=ubuntu-latest:docker://node:22-bookworm
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./runner-data:/data
    networks:
      - kind

networks:
  kind:
    external: true
EOF
```

Boot Gitea, create the `platform` user, create the empty `gitops-repo` repository via API, and launch the Actions runner:

```bash
cd ~/platform-lab/appliances
docker compose up -d gitea

# Wait for Gitea to initialize SQLite
until curl -sf http://localhost:3000/api/v1/version >/dev/null; do sleep 1; done

# Create admin user (platform / password123)
docker exec -u git gitea gitea admin user create \
  --username platform \
  --password password123 \
  --email platform@local.lab \
  --admin --must-change-password=false || true

# Create the 'gitops-repo' repository in Gitea
curl -sf -u "platform:password123" -X POST "http://localhost:3000/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -d '{"name": "gitops-repo", "private": false, "auto_init": false}' >/dev/null || true

# Register and start the local Gitea Actions runner
export RUNNER_TOKEN=$(docker exec -u git gitea gitea actions generate-runner-token)
docker compose up -d gitea-runner
```

### Step 3.2: Install Harbor (Enterprise Registry + Trivy CVE Scanner)
```bash
cd ~/platform-lab/appliances
HARBOR_VERSION="v2.11.1"
if [ ! -d "harbor" ]; then
  curl -sL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz" | tar xz
fi
cd harbor

cp harbor.yml.tmpl harbor.yml
sed -i '' 's/^hostname: .*/hostname: harbor.orb.local/' harbor.yml
sed -i '' 's/port: 80$/port: 8085/' harbor.yml
sed -i '' '/^https:/,/^[^ ]/ s/^/#/' harbor.yml
sed -i '' 's/^harbor_admin_password: .*/harbor_admin_password: Harbor12345/' harbor.yml
# Store all Harbor state inside ~/platform-lab so a nuke leaves zero leftover data on the host
sed -i '' "s|^data_volume: .*|data_volume: ${HOME}/platform-lab/appliances/harbor-data|" harbor.yml

sudo ./install.sh --with-trivy

# Connect Harbor's front-end proxy ('nginx') to the 'kind' network so Kind nodes can pull directly
docker network connect kind nginx 2>/dev/null || true

# Wait for Harbor API to be ready
until curl -sf -u "admin:Harbor12345" "http://harbor.orb.local:8085/api/v2.0/systeminfo" >/dev/null; do sleep 2; done

# Create 'dev' project (auto-scan with Trivy) and 'prod' project (auto-scan + block Critical CVEs)
curl -sf -u "admin:Harbor12345" -X POST "http://harbor.orb.local:8085/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name": "dev", "metadata": {"public": "false", "auto_scan": "true"}}' || true

curl -sf -u "admin:Harbor12345" -X POST "http://harbor.orb.local:8085/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name": "prod", "metadata": {"public": "false", "auto_scan": "true", "prevent_vul": "true", "severity": "critical"}}' || true

# Log your Mac's Docker daemon into Harbor
docker login harbor.orb.local:8085 -u admin -p Harbor12345
```

---

## 4. Tier 2 & Tier 3: Spin Up the 3 Kind Clusters (`admin`, `dev`, `prod`)

### Step 4.1: Create `kind-admin`, `kind-dev`, and `kind-prod`
- `kind-admin` maps host port **`8070` → `30080`** (Grafana UI) and **`8075` → `30085`** (Argo CD UI/CLI), plus exposes NodePorts **`30090`** (Prometheus Remote-Write) and **`30100`** (Loki Push API) on `admin-control-plane` over the `kind` Docker network.
- `kind-dev` maps host port **`8080` → `30080`** (Dev Envoy Gateway).
- `kind-prod` maps host port **`8090` → `30080`** (Prod Envoy Gateway).

```bash
cat <<'EOF' > ~/platform-lab/appliances/create-clusters.sh
#!/usr/bin/env bash
set -euo pipefail

create_kind_cluster() {
  local NAME="$1"
  local HTTP_HOST_PORT="$2"
  local EXTRA_PORT_MAPPING="${3:-}"

  echo "==> Creating cluster: kind-${NAME} (Host Port ${HTTP_HOST_PORT} -> NodePort 30080)..."
  cat <<CLUSTER | kind create cluster --name "${NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor.orb.local:8085"]
        endpoint = ["http://nginx:8080"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.orb.local:8085".tls]
      insecure_skip_verify = true
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: ${HTTP_HOST_PORT}
    protocol: TCP${EXTRA_PORT_MAPPING}
CLUSTER
}

ADMIN_EXTRA=$'\n  - containerPort: 30085\n    hostPort: 8075\n    protocol: TCP'
create_kind_cluster "admin" 8070 "${ADMIN_EXTRA}"
create_kind_cluster "dev"   8080
create_kind_cluster "prod"  8090
EOF

chmod +x ~/platform-lab/appliances/create-clusters.sh
~/platform-lab/appliances/create-clusters.sh
```

### Step 4.2: Configure `kind-admin` (Argo CD + Central Grafana, Prometheus & Loki)

```bash
kubectl config use-context kind-admin

# 1. Install Argo CD and expose argocd-server on NodePort 30085 (https://localhost:8075)
kubectl create namespace argocd || true
kubectl apply -n argocd --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

kubectl -n argocd patch svc argocd-server --type merge -p '
spec:
  type: NodePort
  ports:
    - name: https
      port: 443
      targetPort: 8080
      nodePort: 30085
'

# 2. Log into Argo CD on localhost:8075 and register kind-dev & kind-prod
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8075 --username admin --password "${ARGOCD_PASS}" --insecure

for ENV in dev prod; do
  INTERNAL_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${ENV}-control-plane")
  kubectl config set-cluster "kind-${ENV}" --server="https://${INTERNAL_IP}:6443"
  argocd cluster add "kind-${ENV}" --name "${ENV}-cluster" --yes
done

# 3. Install Central Prometheus (NodePort 30090) + Grafana (NodePort 30080 -> localhost:8070) + Loki (NodePort 30100)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30090 \
  --set grafana.adminPassword=admin \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30080 \
  --set grafana.additionalDataSources[0].name=Loki \
  --set grafana.additionalDataSources[0].type=loki \
  --set grafana.additionalDataSources[0].url=http://loki-gateway.monitoring.svc.cluster.local \
  --set grafana.additionalDataSources[0].access=proxy

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --set deploymentMode=SingleBinary \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set singleBinary.replicas=1 \
  --set backend.replicas=0 --set read.replicas=0 --set write.replicas=0 \
  --set gateway.service.type=NodePort \
  --set gateway.service.nodePort=30100
```

### Step 4.3: Configure `kind-dev` & `kind-prod` (Envoy Gateway NodePort + Telemetry Agents + Pull Secrets)

This step installs **Gateway API CRDs**, **Envoy Gateway** (configured via `EnvoyProxy` to bind its data plane to `NodePort: 30080` so host ports `8080` and `8090` route directly into it), **Harbor `imagePullSecrets`**, **Promtail** (shipping logs to `kind-admin:30100`), and **Prometheus Agent** (shipping metrics to `kind-admin:30090`).

```bash
ADMIN_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' admin-control-plane)

for ENV in dev prod; do
  kubectl config use-context "kind-${ENV}"

  # 1. Gateway API CRDs + Envoy Gateway Controller
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.2.0 --namespace envoy-gateway-system --create-namespace
  kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s

  # 2. Configure EnvoyProxy + GatewayClass + platform-gateway on NodePort 30080
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: nodeport-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
        patch:
          type: StrategicMerge
          value:
            spec:
              ports:
                - name: http
                  port: 80
                  targetPort: 10080
                  nodePort: 30080
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: nodeport-proxy-config
    namespace: envoy-gateway-system
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

  # 3. Target namespace & Harbor imagePullSecret (scoped to pull from Harbor)
  kubectl create namespace "${ENV}" || true
  kubectl -n "${ENV}" create secret docker-registry harbor-pull-secret \
    --docker-server="harbor.orb.local:8085" \
    --docker-username="admin" \
    --docker-password="Harbor12345" \
    --dry-run=client -o yaml | kubectl apply -f -

  # 4. Promtail DaemonSet -> ships pod logs with label cluster=<dev|prod> to Loki in kind-admin
  helm upgrade --install promtail grafana/promtail \
    --namespace monitoring --create-namespace \
    --set "config.clients[0].url=http://${ADMIN_IP}:30100/loki/api/v1/push" \
    --set "config.snippets.extraRelabelConfigs[0].target_label=cluster" \
    --set "config.snippets.extraRelabelConfigs[0].replacement=${ENV}"

  # 5. Lightweight Prometheus Agent -> remote-writes cluster & pod metrics to Prometheus in kind-admin
  helm upgrade --install kube-prom-agent prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.enabled=false \
    --set alertmanager.enabled=false \
    --set prometheus.prometheusSpec.mode=Agent \
    --set "prometheus.prometheusSpec.externalLabels.cluster=${ENV}" \
    --set "prometheus.prometheusSpec.remoteWrite[0].url=http://${ADMIN_IP}:30090/api/v1/write"
done
```

---

## 5. Greenfield Generation of the GitOps & Microservices Repository

Run the following script to populate `~/platform-lab/gitops-repo` from scratch with:
- All 3 Node.js microservices (`orders-api`, `payments-api`, `inventory-api`) and their `Dockerfile`s.
- Clean **Kustomize Bases** (`k8s/base/{orders,payments,inventory}`) + `HTTPRoute` on `orders`.
- **Kustomize Environment Overlays** (`k8s/overlays/{dev,prod}/{orders,payments,inventory}`).
- **Argo CD Multi-Cluster Matrix `ApplicationSet`** (`argocd/microservices-appset.yaml`).
- **Release & Promotion Scripts** (`scripts/build-and-push.sh`, `scripts/promote.sh` with `list` and `warn_branch` guardrails).
- **Zero-Dependency E2E + Manifest Policy-as-Code Test Suite** (`tests/*.test.js`) and **Gitea Actions Workflow** (`.gitea/workflows/test.yml`).

```bash
cd ~/platform-lab/gitops-repo
mkdir -p .gitea/workflows argocd scripts tests \
  k8s/base/{orders,payments,inventory}/src \
  k8s/overlays/{dev,prod}/{orders,payments,inventory}

# ------------------------------------------------------------------------------
# 5.1 Root package.json & Gitea Actions CI Workflow
# ------------------------------------------------------------------------------
cat <<'EOF' > package.json
{
  "name": "platform-gitops-lab",
  "private": true,
  "description": "Zero-dependency E2E service tests and Kustomize/ApplicationSet policy tests (Node >= 22)",
  "scripts": {
    "test": "node --test \"tests/*.test.js\"",
    "test:services": "node --test tests/payments.test.js tests/inventory.test.js tests/orders.test.js tests/e2e.test.js",
    "test:manifests": "node --test tests/manifests.test.js"
  },
  "engines": { "node": ">=22" }
}
EOF

cat <<'EOF' > .gitea/workflows/test.yml
name: tests

on:
  pull_request:
    branches: [master, dev, prod]
  push:
    branches: [master, dev, prod]

jobs:
  test:
    name: test
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - name: Ensure kubectl is installed
        run: |
          if ! command -v kubectl >/dev/null 2>&1; then
            curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl"
            install -m 0755 kubectl /usr/local/bin/kubectl
          fi
          kubectl version --client
      - name: Run E2E & Manifest Policy Tests
        run: npm test
EOF

# ------------------------------------------------------------------------------
# 5.2 Shared Dockerfile & package.json for all 3 Microservices
# ------------------------------------------------------------------------------
for SVC in orders payments inventory; do
  cat <<EOF > "k8s/base/${SVC}/package.json"
{
  "name": "${SVC}-api",
  "version": "1.0.0",
  "private": true,
  "main": "src/server.js",
  "scripts": { "start": "node src/server.js" }
}
EOF

  cat <<'EOF' > "k8s/base/${SVC}/Dockerfile"
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
EXPOSE 3000
CMD ["node", "src/server.js"]
EOF
done

# ------------------------------------------------------------------------------
# 5.3 Microservice 1: inventory-api (East-West Internal Service)
# ------------------------------------------------------------------------------
cat <<'EOF' > k8s/base/inventory/src/server.js
"use strict";
const http = require("node:http");

const PORT = Number(process.env.PORT || 3000);
const LOG_LEVEL = process.env.LOG_LEVEL || "info";
const log = (lvl, msg, extra = {}) => {
  if (lvl === "debug" && LOG_LEVEL !== "debug") return;
  console.log(JSON.stringify({ service: "inventory-api", level: lvl, msg, ...extra }));
};

const send = (res, code, body) => {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};

const server = http.createServer((req, res) => {
  log("debug", "request", { method: req.method, url: req.url });
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { status: "ok", service: "inventory-api" });
  if (req.method === "POST" && req.url === "/reserve") {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      let body;
      try { body = JSON.parse(raw || "{}"); } catch { return send(res, 400, { error: "Invalid JSON" }); }
      const { productId, quantity } = body;
      if (!productId || typeof productId !== "string" || !Number.isInteger(quantity) || quantity <= 0) {
        return send(res, 400, { error: "productId (string) and positive integer quantity are required" });
      }
      if (productId === "OUT-OF-STOCK") return send(res, 409, { error: "Product out of stock", productId });
      return send(res, 200, { reserved: true, productId, quantity });
    });
    return;
  }
  send(res, 404, { error: "Not found" });
});

server.listen(PORT, () => log("info", `inventory-api listening on ${PORT}`, { logLevel: LOG_LEVEL }));
EOF

# ------------------------------------------------------------------------------
# 5.4 Microservice 2: payments-api (East-West Internal Service)
# ------------------------------------------------------------------------------
cat <<'EOF' > k8s/base/payments/src/server.js
"use strict";
const http = require("node:http");

const PORT = Number(process.env.PORT || 3000);
const LOG_LEVEL = process.env.LOG_LEVEL || "info";
const log = (lvl, msg, extra = {}) => {
  if (lvl === "debug" && LOG_LEVEL !== "debug") return;
  console.log(JSON.stringify({ service: "payments-api", level: lvl, msg, ...extra }));
};

const send = (res, code, body) => {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};

let nextTx = 1;
const server = http.createServer((req, res) => {
  log("debug", "request", { method: req.method, url: req.url });
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { status: "ok", service: "payments-api" });
  if (req.method === "POST" && req.url === "/charge") {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      let body;
      try { body = JSON.parse(raw || "{}"); } catch { return send(res, 400, { error: "Invalid JSON" }); }
      const { amount } = body;
      if (typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0) {
        return send(res, 400, { error: "Positive numeric amount is required" });
      }
      if (amount > 1000) return send(res, 402, { error: "Payment declined: amount exceeds limit", amount });
      return send(res, 200, { charged: true, transactionId: `tx-${nextTx++}`, amount });
    });
    return;
  }
  send(res, 404, { error: "Not found" });
});

server.listen(PORT, () => log("info", `payments-api listening on ${PORT}`, { logLevel: LOG_LEVEL }));
EOF

# ------------------------------------------------------------------------------
# 5.5 Microservice 3: orders-api (North-South Edge + East-West Orchestrator)
# ------------------------------------------------------------------------------
cat <<'EOF' > k8s/base/orders/src/server.js
"use strict";
const http = require("node:http");

const PORT = Number(process.env.PORT || 3000);
const LOG_LEVEL = process.env.LOG_LEVEL || "info";
const INVENTORY_URL = process.env.INVENTORY_URL || "http://inventory-api";
const PAYMENTS_URL = process.env.PAYMENTS_URL || "http://payments-api";

const log = (lvl, msg, extra = {}) => {
  if (lvl === "debug" && LOG_LEVEL !== "debug") return;
  console.log(JSON.stringify({ service: "orders-api", level: lvl, msg, ...extra }));
};

const send = (res, code, body) => {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};

const postJson = (baseUrl, path, payload, timeoutMs = 3000) =>
  new Promise((resolve, reject) => {
    const url = new URL(path, baseUrl);
    const data = JSON.stringify(payload);
    const req = http.request(
      url,
      { method: "POST", headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) }, timeout: timeoutMs },
      (res) => {
        let raw = "";
        res.on("data", (c) => (raw += c));
        res.on("end", () => {
          try { resolve({ status: res.statusCode, body: JSON.parse(raw) }); }
          catch { reject(new Error("Invalid JSON from upstream")); }
        });
      }
    );
    req.on("timeout", () => req.destroy(new Error("Upstream timeout")));
    req.on("error", reject);
    req.end(data);
  });

let nextOrder = 1;
const server = http.createServer((req, res) => {
  log("debug", "request", { method: req.method, url: req.url });
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { status: "ok", service: "orders-api" });
  if (req.method === "GET" && req.url === "/") {
    return send(res, 200, { service: "orders-api", endpoints: ["GET /health", "POST /orders {productId, quantity, amount}"] });
  }
  if (req.method === "POST" && req.url === "/orders") {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", async () => {
      let body;
      try { body = JSON.parse(raw || "{}"); } catch { return send(res, 400, { error: "Invalid JSON" }); }
      const { productId, quantity, amount } = body;
      if (!productId || typeof productId !== "string" || !Number.isInteger(quantity) || quantity <= 0 || typeof amount !== "number" || amount <= 0) {
        return send(res, 400, { error: "productId (string), quantity (positive int), and amount (positive number) required" });
      }
      try {
        const inv = await postJson(INVENTORY_URL, "/reserve", { productId, quantity });
        if (inv.status !== 200) return send(res, inv.status >= 500 ? 502 : inv.status, inv.body);
        const pay = await postJson(PAYMENTS_URL, "/charge", { amount });
        if (pay.status !== 200) return send(res, pay.status >= 500 ? 502 : pay.status, pay.body);
        return send(res, 201, { orderId: nextOrder++, status: "completed", inventory: inv.body, payment: pay.body });
      } catch (err) {
        log("info", "upstream_error", { error: err.message });
        return send(res, 502, { error: "Upstream service unavailable", detail: err.message });
      }
    });
    return;
  }
  send(res, 404, { error: "Not found" });
});

server.listen(PORT, () => log("info", `orders-api listening on ${PORT}`, { logLevel: LOG_LEVEL }));
EOF

# ------------------------------------------------------------------------------
# 5.6 Kustomize Base Manifests (Deployments, Services, and orders HTTPRoute)
# ------------------------------------------------------------------------------
for SVC in orders payments inventory; do
  EXTRA_ENV=""
  if [[ "${SVC}" == "orders" ]]; then
    EXTRA_ENV=$'\n            - name: INVENTORY_URL\n              value: http://inventory-api\n            - name: PAYMENTS_URL\n              value: http://payments-api'
  fi

  cat <<EOF > "k8s/base/${SVC}/deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC}-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${SVC}-api
  template:
    metadata:
      labels:
        app: ${SVC}-api
    spec:
      imagePullSecrets:
        - name: harbor-pull-secret
      containers:
        - name: ${SVC}-api
          image: ${SVC}-api
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          env:
            - name: LOG_LEVEL
              value: info${EXTRA_ENV}
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
EOF

  cat <<EOF > "k8s/base/${SVC}/service.yaml"
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}-api
spec:
  type: ClusterIP
  selector:
    app: ${SVC}-api
  ports:
    - port: 80
      targetPort: 3000
EOF
done

# North-South HTTPRoute ONLY for orders-api (inventory & payments stay strictly internal)
cat <<'EOF' > k8s/base/orders/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders-route
spec:
  parentRefs:
    - name: platform-gateway
      namespace: default
  hostnames:
    - "orders.dev.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: orders-api
          port: 80
EOF

cat <<'EOF' > k8s/base/orders/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
EOF

for SVC in payments inventory; do
  cat <<'EOF' > "k8s/base/${SVC}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
EOF
done

# ------------------------------------------------------------------------------
# 5.7 Kustomize Overlays for 'dev' and 'prod'
# ------------------------------------------------------------------------------
for SVC in orders payments inventory; do
  cat <<EOF > "k8s/overlays/dev/${SVC}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: dev

resources:
  - ../../../base/${SVC}

replicas:
  - name: ${SVC}-api
    count: 1

images:
  - name: ${SVC}-api
    newName: harbor.orb.local:8085/dev/${SVC}-api
    newTag: "1.0.0"

patches:
  - target:
      kind: Deployment
      name: ${SVC}-api
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${SVC}-api
      spec:
        template:
          spec:
            containers:
              - name: ${SVC}-api
                env:
                  - name: LOG_LEVEL
                    value: debug
EOF

  EXTRA_PATCH=""
  if [[ "${SVC}" == "orders" ]]; then
    EXTRA_PATCH=$'\n  - target:\n      kind: HTTPRoute\n      name: orders-route\n    patch: |-\n      - op: replace\n        path: /spec/hostnames/0\n        value: "orders.prod.local"'
  fi

  cat <<EOF > "k8s/overlays/prod/${SVC}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: prod

resources:
  - ../../../base/${SVC}

replicas:
  - name: ${SVC}-api
    count: 2

images:
  - name: ${SVC}-api
    newName: harbor.orb.local:8085/prod/${SVC}-api
    newTag: "1.0.0"

patches:
  - target:
      kind: Deployment
      name: ${SVC}-api
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${SVC}-api
      spec:
        template:
          spec:
            containers:
              - name: ${SVC}-api
                env:
                  - name: LOG_LEVEL
                    value: info${EXTRA_PATCH}
EOF
done

# ------------------------------------------------------------------------------
# 5.8 Argo CD Multi-Cluster Matrix ApplicationSet (Auto-Sync dev, Manual Sync prod)
# ------------------------------------------------------------------------------
cat <<'EOF' > argocd/microservices-appset.yaml
# Human-in-the-Loop Gate #2:
# - 'dev' apps use automated sync (prune + selfHeal) for rapid iteration.
# - 'prod' apps omit 'automated' syncPolicy, requiring a human operator to approve
#   the live diff in the Argo CD UI (https://localhost:8075) or via 'argocd app sync'.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - list:
              elements:
                - env: dev
                  branch: dev
                  clusterName: dev-cluster
                - env: prod
                  branch: prod
                  clusterName: prod-cluster
          - list:
              elements:
                - service: orders
                - service: payments
                - service: inventory
  template:
    metadata:
      name: "{{.service}}-api-{{.env}}"
    spec:
      project: default
      source:
        repoURL: http://gitea:3000/platform/gitops-repo.git
        targetRevision: "{{.branch}}"
        path: "k8s/overlays/{{.env}}/{{.service}}"
      destination:
        name: "{{.clusterName}}"
        namespace: "{{.env}}"
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
  templatePatch: |
    {{- if eq .env "dev" }}
    spec:
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
    {{- end }}
EOF
```

### Step 5.9: Generate the Release & Promotion Scripts (with Two-Key Human-in-the-Loop PR Creation)

```bash
cat <<'EOF' > scripts/build-and-push.sh
#!/usr/bin/env bash
# Build a microservice image, push it to Harbor's 'dev' project, and update the 'dev' Kustomize overlay.
# Usage: scripts/build-and-push.sh <orders|payments|inventory|all> [tag]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="harbor.orb.local:8085"
SERVICES=(orders payments inventory)

warn_branch() {
  local cur; cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -z "$cur" || "$cur" == "$1" ]] || echo "WARNING: you are on branch '$cur', but '$1' deploys from branch '$1'!" >&2
}

tag_of() { sed -n 's/^[[:space:]]*newTag:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"; }

build_one() {
  local svc="$1" tag_arg="${2:-}"
  local overlay="$ROOT/k8s/overlays/dev/$svc/kustomization.yaml"
  local current; current="$(tag_of "$overlay")"
  local tag
  if [[ -n "$tag_arg" ]]; then
    tag="$tag_arg"
  else
    IFS='.' read -r maj min pat <<< "$current"
    tag="${maj}.${min}.$((pat + 1))"
  fi

  local image="${REGISTRY}/dev/${svc}-api:${tag}"
  echo "==> Building & pushing ${image} (was ${current})..."
  docker build -t "${image}" "$ROOT/k8s/base/$svc"
  docker push "${image}"
  sed -i '' "s|^\([[:space:]]*newTag:\).*|\1 \"${tag}\"|" "$overlay"
}

svc="${1:?usage: $0 <orders|payments|inventory|all> [tag]}"
tag="${2:-}"
if [[ "$svc" == "all" ]]; then
  for s in "${SERVICES[@]}"; do build_one "$s" "$tag"; done
else
  build_one "$svc" "$tag"
fi

warn_branch "dev"
echo "==> Done. Commit and push to 'dev' so local Gitea Actions + Argo CD auto-sync it:"
echo "    git add k8s && git commit -m 'Release dev images' && git push origin dev"
EOF

cat <<'EOF' > scripts/promote.sh
#!/usr/bin/env bash
# Inspect tags across environments, or promote a tested image from Harbor 'dev' -> Harbor 'prod'
# and open a Pull Request against the protected 'prod' branch in Gitea (Human-in-the-Loop Gate #1).
# Usage:
#   scripts/promote.sh list
#   scripts/promote.sh <orders|payments|inventory|all> [--seed]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="harbor.orb.local:8085"
GITEA_API="http://gitea.orb.local:3000/api/v1/repos/platform/gitops-repo"
SERVICES=(orders payments inventory)

kfile() { echo "$ROOT/k8s/overlays/$2/$1/kustomization.yaml"; }
tag_of() { sed -n 's/^[[:space:]]*newTag:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"; }

if [[ "${1:-}" == "list" ]]; then
  printf '%-12s%-10s%-10s\n' "SERVICE" "DEV" "PROD"
  for s in "${SERVICES[@]}"; do
    printf '%-12s%-10s%-10s\n' "$s" "$(tag_of "$(kfile "$s" dev)")" "$(tag_of "$(kfile "$s" prod)")"
  done
  exit 0
fi

svc="${1:?usage: $0 <list|orders|payments|inventory|all> [--seed]}"
mode="${2:-pr}"

# Read target tag(s) from the 'dev' branch before switching branches
declare -A TARGET_TAGS
if [[ "$svc" == "all" ]]; then
  for s in "${SERVICES[@]}"; do TARGET_TAGS["$s"]="$(tag_of "$(kfile "$s" dev)")"; done
else
  TARGET_TAGS["$svc"]="$(tag_of "$(kfile "$svc" dev)")"
fi

promote_image_and_overlay() {
  local s="$1" tag="${TARGET_TAGS[$1]}"
  echo "==> Promoting ${s}-api:${tag} in Harbor (dev -> prod) via skopeo..."
  skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    --src-creds="admin:Harbor12345" --dest-creds="admin:Harbor12345" \
    "docker://${REGISTRY}/dev/${s}-api:${tag}" \
    "docker://${REGISTRY}/prod/${s}-api:${tag}"
  sed -i '' "s|^\([[:space:]]*newTag:\).*|\1 \"${tag}\"|" "$(kfile "$s" prod)"
}

if [[ "$mode" == "--seed" ]]; then
  for s in "${!TARGET_TAGS[@]}"; do promote_image_and_overlay "$s"; done
  exit 0
fi

# Day-2 Human-in-the-Loop Promotion: create a promotion branch from origin/prod and open a PR in Gitea
git -C "$ROOT" fetch origin prod
PROMO_BRANCH="promote/${svc}-$(date +%s)"
git -C "$ROOT" checkout -B "$PROMO_BRANCH" origin/prod

for s in "${!TARGET_TAGS[@]}"; do promote_image_and_overlay "$s"; done

git -C "$ROOT" add k8s/overlays/prod
git -C "$ROOT" commit -m "Promote ${svc} to prod"
git -C "$ROOT" push -u origin "$PROMO_BRANCH"

PR_URL=$(curl -sf -u "platform:password123" -X POST "${GITEA_API}/pulls" \
  -H "Content-Type: application/json" \
  -d "{\"title\": \"Promote ${svc} to prod\", \"head\": \"${PROMO_BRANCH}\", \"base\": \"prod\", \"body\": \"Automated promotion from dev to prod. Requires green CI + human approval.\"}" \
  | jq -r '.html_url')

echo "================================================================="
echo " Human-in-the-Loop Gate #1 (Git PR Created):"
echo "   Review & Merge PR in Gitea: ${PR_URL}"
echo " Human-in-the-Loop Gate #2 (Argo CD Manual Sync):"
echo "   After merging PR, approve rollout in Argo CD: https://localhost:8075"
echo "================================================================="
EOF

chmod +x scripts/build-and-push.sh scripts/promote.sh
```

### Step 5.10: Generate the E2E Service Tests & Manifest Policy-as-Code Tests

```bash
cat <<'EOF' > tests/helpers.js
"use strict";
const path = require("node:path");
const { spawn } = require("node:child_process");
const net = require("node:net");

const ROOT = path.resolve(__dirname, "..");

const freePort = () =>
  new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on("error", reject);
  });

const startService = async (service, envOverrides = {}) => {
  const port = await freePort();
  const entry = path.join(ROOT, "k8s", "base", service, "src", "server.js");
  const proc = spawn(process.execPath, [entry], {
    env: { ...process.env, PORT: String(port), ...envOverrides },
    stdio: ["ignore", "pipe", "pipe"],
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${service} startup timeout`)), 5000);
    proc.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("listening")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`${service} exited early (${code})`));
    });
  });
  return {
    url: `http://127.0.0.1:${port}`,
    stop: () => new Promise((r) => { proc.once("exit", r); proc.kill("SIGTERM"); }),
  };
};

module.exports = { ROOT, startService };
EOF

cat <<'EOF' > tests/e2e.test.js
"use strict";
const { test, describe, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { startService } = require("./helpers");

describe("3-Service East-West E2E Flow (orders -> inventory -> payments)", () => {
  let inv, pay, ord;

  before(async () => {
    inv = await startService("inventory");
    pay = await startService("payments");
    ord = await startService("orders", { INVENTORY_URL: inv.url, PAYMENTS_URL: pay.url });
  });

  after(async () => {
    if (ord) await ord.stop();
    if (pay) await pay.stop();
    if (inv) await inv.stop();
  });

  test("POST /orders succeeds (201) when inventory and payment succeed", async () => {
    const res = await fetch(`${ord.url}/orders`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ productId: "A1", quantity: 2, amount: 50 }),
    });
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.status, "completed");
    assert.equal(body.inventory.reserved, true);
    assert.equal(body.payment.charged, true);
  });

  test("POST /orders returns 409 when product is OUT-OF-STOCK", async () => {
    const res = await fetch(`${ord.url}/orders`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ productId: "OUT-OF-STOCK", quantity: 1, amount: 25 }),
    });
    assert.equal(res.status, 409);
  });

  test("POST /orders returns 402 when amount exceeds 1000", async () => {
    const res = await fetch(`${ord.url}/orders`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ productId: "A1", quantity: 1, amount: 5000 }),
    });
    assert.equal(res.status, 402);
  });
});
EOF

# Create stub files for individual service tests so `npm run test:services` works seamlessly
for S in payments inventory orders; do
  cat <<EOF > "tests/${S}.test.js"
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { startService } = require("./helpers");

test("${S}-api /health responds 200", async () => {
  const svc = await startService("${S}");
  try {
    const res = await fetch(\`\${svc.url}/health\`);
    assert.equal(res.status, 200);
  } finally {
    await svc.stop();
  }
});
EOF
done

cat <<'EOF' > tests/manifests.test.js
"use strict";
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { ROOT } = require("./helpers");

const ENVS = {
  dev:  { logLevel: "debug", host: "orders.dev.local",  project: "dev" },
  prod: { logLevel: "info",  host: "orders.prod.local", project: "prod" },
};
const SERVICES = ["orders", "payments", "inventory"];
const render = (dir) => execFileSync("kubectl", ["kustomize", path.join(ROOT, dir)], { encoding: "utf8" });
const docs = (yaml) => yaml.split(/^---$/m).map((d) => d.trim()).filter(Boolean);
const kind = (yaml, k) => docs(yaml).filter((d) => new RegExp(`^kind: ${k}$`, "m").test(d));

describe("Kustomize overlays & Gateway API routes render correctly", () => {
  for (const [env, cfg] of Object.entries(ENVS)) {
    for (const svc of SERVICES) {
      describe(`${env}/${svc}`, () => {
        const name = `${svc}-api`;
        const out = render(`k8s/overlays/${env}/${svc}`);

        test("produces Deployment, Service, no Namespace, and HTTPRoute only on orders", () => {
          assert.equal(kind(out, "Deployment").length, 1);
          assert.equal(kind(out, "Service").length, 1);
          assert.equal(kind(out, "Namespace").length, 0);
          assert.equal(kind(out, "HTTPRoute").length, svc === "orders" ? 1 : 0);
        });

        test(`is scoped to namespace ${env} and pulls from Harbor project '${cfg.project}'`, () => {
          for (const d of docs(out)) assert.match(d, new RegExp(`^  namespace: ${env}$`, "m"));
          assert.match(kind(out, "Deployment")[0], new RegExp(`image: harbor\\.orb\\.local:8085/${cfg.project}/${name}:\\d+\\.\\d+\\.\\d+$`, "m"));
          assert.match(kind(out, "Deployment")[0], /name: harbor-pull-secret/);
        });

        test(`sets LOG_LEVEL=${cfg.logLevel}`, () => {
          assert.match(kind(out, "Deployment")[0], new RegExp(`name: LOG_LEVEL\\n\\s+value: ${cfg.logLevel}$`, "m"));
        });

        if (svc === "orders") {
          test(`HTTPRoute routes hostname ${cfg.host} via platform-gateway`, () => {
            const route = kind(out, "HTTPRoute")[0];
            assert.match(route, new RegExp(`- "?${cfg.host}"?`));
            assert.match(route, /name: platform-gateway/);
          });
        }
      });
    }
  }
});

describe("Multi-Cluster Matrix ApplicationSet", () => {
  const text = fs.readFileSync(path.join(ROOT, "argocd", "microservices-appset.yaml"), "utf8");

  test("maps dev -> dev-cluster (auto-sync) and prod -> prod-cluster (manual sync)", () => {
    assert.match(text, /env: dev\s+branch: dev\s+clusterName: dev-cluster/);
    assert.match(text, /env: prod\s+branch: prod\s+clusterName: prod-cluster/);
    assert.match(text, /if eq \.env "dev"/);
    assert.match(text, /prune: true/);
    assert.match(text, /selfHeal: true/);
  });
});
EOF
```

Run the test suite locally right now to verify your greenfield code and manifests pass 100%:

```bash
npm test
```

---

## 6. Wire Git: "Golden Seed" on GitHub + "Chaos Sandbox" on Local Gitea

Here is how we solve the **GitHub permanence vs. Local Ephemerality** requirement:
1. **`origin`** points to **Local Gitea** (`http://platform:password123@gitea.orb.local:3000/platform/gitops-repo.git`). All day-to-day pushes go here, triggering local CI and local Argo CD.
2. **`seed`** points to your **GitHub repository**, with its push URL locked to `DISABLED` during chaos sessions so you never accidentally push a broken experiment to GitHub.

```bash
cd ~/platform-lab/gitops-repo
git init -b master
git config user.name "Platform Engineer"
git config user.email "platform@local.lab"

git add -A
git commit -m "Initial greenfield platform baseline"

# 1. Add Local Gitea as 'origin' and create the 'dev' and 'prod' environment branches
git remote add origin "http://platform:password123@gitea.orb.local:3000/platform/gitops-repo.git"
git branch -M master
git branch dev
git branch prod

# 2. Optional: Connect your GitHub repo as the 'seed' remote (with accidental pushes disabled)
# git remote add seed git@github.com:<your-user>/<your-repo>.git
# git push seed master dev prod                      # Save initial golden baseline to GitHub once
# git remote set-url --push seed DISABLED            # Lock 'seed' so chaos experiments stay 100% local!
```

---

## 7. Seed Initial Images, Lock `prod` Branch Protection & Deploy Across Clusters

```bash
cd ~/platform-lab/gitops-repo

# 1. Build 1.0.0 images, push to Harbor 'dev', and seed Harbor 'prod'
scripts/build-and-push.sh all 1.0.0
scripts/promote.sh all --seed
scripts/promote.sh list

# 2. Push initial 1.0.0 baseline to master, dev, and prod in Local Gitea
git push -u origin master dev prod

# 3. Enable Human-in-the-Loop Gate #1: Protect the 'prod' branch in Gitea!
#    - Blocks direct 'git push origin prod'
#    - Requires Pull Requests AND a green 'test' status check from gitea-runner before merging
curl -sf -u "platform:password123" -X POST "http://gitea.orb.local:3000/api/v1/repos/platform/gitops-repo/branch_protections" \
  -H "Content-Type: application/json" \
  -d '{
    "branch_name": "prod",
    "enable_push": false,
    "enable_status_check": true,
    "status_check_contexts": ["test"]
  }' >/dev/null

# 4. Apply the Multi-Cluster Matrix ApplicationSet in kind-admin
kubectl --context kind-admin apply -f argocd/microservices-appset.yaml

# 5. 'dev' apps auto-sync immediately; perform the initial Day-0 manual sync for 'prod' 1.0.0 apps
sleep 5
for SVC in orders payments inventory; do
  argocd app sync "${SVC}-api-prod"
done
kubectl --context kind-admin -n argocd get applications
```

---

## 8. Verify Everything & Walk Through a Two-Key Human-in-the-Loop Release

### 8.1 Test North–South Envoy Gateway + East–West Microservice Call Chain
```bash
# Hit Dev Envoy Gateway (Host Port 8080, Host header: orders.dev.local)
curl -i -X POST http://orders.dev.local:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"productId":"A1","quantity":2,"amount":50}'
# -> HTTP/1.1 201 Created {"orderId":1,"status":"completed","inventory":{"reserved":true,...},"payment":{"charged":true,...}}

# Hit Prod Envoy Gateway (Host Port 8090, Host header: orders.prod.local)
curl -i -X POST http://orders.prod.local:8090/orders \
  -H "Content-Type: application/json" \
  -d '{"productId":"A1","quantity":2,"amount":50}'
# -> HTTP/1.1 201 Created
```

### 8.2 Inspect Your Local Platform UIs
| Platform UI | Local URL | Credentials | What to Inspect |
| :--- | :--- | :--- | :--- |
| **Gitea + Actions CI** | `http://gitea.orb.local:3000` | `platform` / `password123` | Protected `prod` branch, Pull Requests, and green CI runs under **Actions**. |
| **Argo CD UI** | `https://localhost:8075` | `admin` / `${ARGOCD_PASS}` | All 6 apps across `dev-cluster` (Auto-Sync) and `prod-cluster` (Manual Sync). |
| **Harbor Registry + Trivy** | `http://harbor.orb.local:8085` | `admin` / `Harbor12345` | `dev` and `prod` projects, image digests, and **Trivy vulnerability scan reports**. |
| **Central Grafana + Loki** | `http://localhost:8070` | `admin` / `admin` | **Explore → Loki:** Query `{cluster="dev", app="orders-api"}` (`debug` logs) vs `{cluster="prod", app="orders-api"}` (`info` logs). |

### 8.3 Execute a Day-2 Release with Both Human-in-the-Loop Gates (`dev` → `prod`)

Here is the complete production release flow showing how `dev` deploys automatically while `prod` requires **two human approvals**:

```bash
cd ~/platform-lab/gitops-repo

# 1. Release a new version (1.0.1) to DEV (Auto-Synced)
git checkout dev
scripts/build-and-push.sh orders               # Builds & pushes 1.0.1 to Harbor 'dev', bumps dev overlay
git add k8s && git commit -m "orders dev -> 1.0.1" && git push origin dev
# -> Argo CD automatically rolls out 1.0.1 to kind-dev!

# 2. Initiate Promotion to PROD
scripts/promote.sh orders
# -> Copies 1.0.1 digest from Harbor 'dev' to Harbor 'prod'
# -> Pushes branch 'promote/orders-...' and opens a Pull Request against 'prod' in Gitea!
```

Now exercise the **Two Human-in-the-Loop Gates**:

1. **Human Gate #1 (Gitea Pull Request & CI Check):**
   - Open the Pull Request URL printed by `scripts/promote.sh` (`http://gitea.orb.local:3000/platform/gitops-repo/pulls`).
   - Wait ~15 seconds for `gitea-runner` to finish running `npm test` (the **Merge** button stays locked until the `test` status check turns green).
   - Review the YAML diff (`newTag: "1.0.0"` → `"1.0.1"`) and click **"Merge Pull Request"**.
2. **Human Gate #2 (Argo CD Live Diff & Manual Sync):**
   - Open the Argo CD UI (`https://localhost:8075`).
   - Notice that `orders-api-prod` is now **`OutOfSync` (Yellow)**, while `kind-prod` is *still* running `1.0.0`.
   - Click `orders-api-prod` → **App Diff** to inspect the exact Kubernetes Deployment change, then click **Sync → Synchronize** (or run `argocd app sync orders-api-prod` in your terminal) to roll `1.0.1` out to `kind-prod`!

---

## 9. Chaos Exercises ("Break It & Fix It") & Ephemeral Reset Scripts

### Ideas to Break & Fix
1. **Simulate an Upstream Microservice Outage in `dev`:**
   Scale `inventory-api` to `0` manually (`kubectl --context kind-dev -n dev scale deploy/inventory-api --replicas=0`) and watch Argo CD's `selfHeal` immediately restore it—or disable `selfHeal`, watch `orders-api` return `502 Bad Gateway`, and trace the error in Grafana Loki.
2. **Test CI Gatekeeping on Broken Kustomize Overlays:**
   Switch to `dev`, remove the quotes around `newTag: "1.0.0"` in `k8s/overlays/dev/orders/kustomization.yaml`, push to Gitea, and watch `gitea-runner` fail the `manifests.test.js` check.
3. **Test Harbor's `prod` Vulnerability Block Policy:**
   Try deploying an unverified or vulnerable base image to `harbor.orb.local:8085/prod/` and observe `kind-prod` reject the pod with `ErrImagePull` blocked by Harbor's policy gate.

### Total Nuke ("Nothing Survives")

When you are done with a lab session (or have broken the environment beyond repair), run the following to obliterate **everything**—all 3 Kind clusters, Gitea, Gitea Actions runner, all Harbor containers, the `kind` Docker network, and all data volumes on disk:

```bash
# 1. Destroy all 3 Kind clusters (admin, dev, prod)
kind delete clusters admin dev prod

# 2. Destroy Gitea & Actions Runner containers and volumes
if [ -d ~/platform-lab/appliances ]; then
  (cd ~/platform-lab/appliances && docker compose down -v --remove-orphans) || true
fi

# 3. Destroy all Harbor containers and volumes
if [ -d ~/platform-lab/appliances/harbor ]; then
  (cd ~/platform-lab/appliances/harbor && sudo docker compose down -v --remove-orphans) || true
fi

# 4. Remove the shared Docker network and wipe ~/platform-lab (including Harbor & Gitea data directories)
docker network rm kind 2>/dev/null || true
sudo rm -rf ~/platform-lab
```

Nothing survives—your Mac is back to a 100% clean slate, ready to run the greenfield setup from Step 2 whenever you want a fresh lab.
