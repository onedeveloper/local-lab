# Local Kubernetes Platform Engineering Lab: From Code to GitOps via Gateway API

This guide provides a comprehensive walkthrough to build an enterprise-grade Kubernetes platform locally on macOS (Apple Silicon M-series or Intel) using **OrbStack / Docker**, **Kind**, **ArgoCD**, **Gateway API (Envoy Gateway)**, and a **Local Container Registry**.

---

## Architecture Overview

```
 [ Local Developer Machine (Mac) ]
  ├── 1. Code Edit (FastAPI Calculator)
  ├── 2. Build & Push Image ───────────► [ Local Registry: localhost:5001 ]
  ├── 3. Commit GitOps Manifests ──────► [ Local Git Server / Repo ]
                                                │
                                                ▼
  [ ArgoCD Control Plane (kind-dev) ] ◄── Watches Git
        │
        ├── Deploys to Dev Namespace (In-Cluster)
        └── (Optionally) Deploys to Remote Clusters via ServiceAccount
                 │
                 ▼
  [ Gateway API (Envoy Gateway) ] ◄── Listens on host port 80 / 443
        │
        └── HTTPRoute: calc.local/calculate ──► [ calculator-service ] ──► [ Pods ]
```

---

## 1. Prerequisites Installation

Run the following commands in your Mac terminal (using [Homebrew](https://brew.sh)):

```bash
# 1. Install CLI utilities
brew install kind kubectl kustomize helm argocd jq

# 2. Verify container runtime is active
docker ps
```

---

## 2. All-in-One Automated Setup Script

Save this script as `setup-lab.sh` and execute it (`chmod +x setup-lab.sh && ./setup-lab.sh`). It provisions:
1. A local Docker registry (`localhost:5001`).
2. A multi-node Kind cluster (`kind-lab`) configured to talk directly to the local registry with host port bindings on `80` and `443`.
3. Standard Gateway API CRDs and Envoy Gateway.
4. ArgoCD in the `argocd` namespace.
5. The FastAPI Calculator source code, Dockerfile, and Kustomize overlays.

```bash
#!/usr/bin/env bash
set -euo pipefail

REG_NAME='kind-registry'
REG_PORT='5001'
CLUSTER_NAME='lab'

echo "==> 1. Setting up Local Docker Registry..."
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name "${REG_NAME}" registry:2
fi

echo "==> 2. Creating Kind Cluster with Host Port Mappings & Registry Config..."
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REG_PORT}"]
        endpoint = ["http://${REG_NAME}:5000"]
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
EOF

# Connect the local registry container to the Kind Docker network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REG_NAME}"
fi

# Inform Kubernetes about the local registry (KEP-1755 standard)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "==> 3. Installing Kubernetes Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "==> 4. Installing Envoy Gateway Controller..."
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 \
  --namespace envoy-gateway-system \
  --create-namespace

echo "==> 5. Installing ArgoCD..."
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server to be ready..."
kubectl wait --namespace argocd --for=condition=available deployment/argocd-server --timeout=180s

echo "================================================================="
echo " Lab Infrastructure is Ready!"
echo " Cluster: kind-${CLUSTER_NAME}"
echo " Registry: localhost:${REG_PORT}"
echo "================================================================="
```

---

## 3. Step-by-Step Project Setup

### Step 3.1: Prepare the GitOps Directory Structure
Run this in your terminal to create the directory layout for both application code and GitOps manifests:

```bash
mkdir -p platform-lab/{app,gitops/{base,envs/dev,envs/staging,envs/prod}}
cd platform-lab
```

### Step 3.2: Create the FastAPI Application
Create `app/main.py`:

```python
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Literal

app = FastAPI(title="Calculator Service")

class CalcRequest(BaseModel):
    a: float
    b: float
    operation: Literal["add", "subtract", "multiply", "divide"]

@app.post("/calculate")
def calculate(req: CalcRequest):
    if req.operation == "add":
        return {"result": req.a + req.b}
    elif req.operation == "subtract":
        return {"result": req.a - req.b}
    elif req.operation == "multiply":
        return {"result": req.a * req.b}
    elif req.operation == "divide":
        if req.b == 0:
            raise HTTPException(status_code=400, detail="Division by zero")
        return {"result": req.a / req.b}

@app.get("/healthz")
def healthz():
    return {"status": "ok"}
```

Create `app/Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY main.py .
RUN pip install --no-cache-dir fastapi uvicorn
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Build and push the image into your local registry:
```bash
docker build -t localhost:5001/calculator-api:v1 app/
docker push localhost:5001/calculator-api:v1
```

---

### Step 3.3: Build the Gateway API Infrastructure

Before deploying the app, establish the network gateway that listens on port 80.

Create `gitops/base/gateway.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
```

Apply the Gateway to your cluster:
```bash
kubectl apply -f gitops/base/gateway.yaml
```

---

### Step 3.4: Define Kustomize Base Manifests

Create `gitops/base/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: calculator-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: calculator-api
  template:
    metadata:
      labels:
        app: calculator-api
    spec:
      containers:
      - name: api
        image: localhost:5001/calculator-api:v1
        ports:
        - containerPort: 8000
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8000
          initialDelaySeconds: 3
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8000
          initialDelaySeconds: 3
          periodSeconds: 5
```

Create `gitops/base/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: calculator-service
spec:
  type: ClusterIP
  selector:
    app: calculator-api
  ports:
  - port: 80
    targetPort: 8000
```

Create `gitops/base/httproute.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: calculator-route
spec:
  parentRefs:
  - name: platform-gateway
    namespace: default
  hostnames:
  - "calc.local"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /calculate
    - path:
        type: PathPrefix
        value: /healthz
    backendRefs:
    - name: calculator-service
      port: 80
```

Create `gitops/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
```

---

### Step 3.5: Create Environment Overlays

#### Dev Environment (`gitops/envs/dev/kustomization.yaml`):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: dev
namePrefix: dev-
resources:
  - ../../base
```

#### Prod Environment (`gitops/envs/prod/kustomization.yaml`):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
namePrefix: prod-
resources:
  - ../../base
patches:
  - target:
      kind: Deployment
      name: calculator-api
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
  - target:
      kind: HTTPRoute
      name: calculator-route
    patch: |-
      - op: replace
        path: /spec/hostnames/0
        value: "calc.prod.local"
```

---

## 4. Initialize Local Git Repository

ArgoCD requires a Git repository to pull manifests from. We will initialize a local Git repository right inside `gitops/`:

```bash
cd gitops
git init
git config user.name "Platform Engineer"
git config user.email "engineer@local.lab"
git add .
git commit -m "Initial commit: Base platform manifests and env overlays"
```

> **Testing with Remote Git:** If you push this repository to GitHub/GitLab, you can point ArgoCD directly to your public or private URL. If working strictly offline, you can push this to an in-cluster Gitea instance or run a simple local Git server.

---

## 5. Connect ArgoCD to the GitOps Manifests

Apply the ArgoCD `Application` to deploy the **Dev** environment:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: calculator-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    # If using GitHub, replace with your repo URL
    repoURL: 'https://github.com/your-org/platform-lab.git'
    targetRevision: HEAD
    path: gitops/envs/dev
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

---

## 6. Accessing and Testing the Application

### Step 6.1: Map Test Domains
Add the hostnames to your Mac's `/etc/hosts`:
```bash
sudo sh -c 'echo "127.0.0.1 calc.local calc.prod.local" >> /etc/hosts'
```

### Step 6.2: Test the Calculation API
Once Envoy Gateway and the Pods are running, execute a calculation request:

```bash
curl -i -X POST http://calc.local/calculate \
  -H "Content-Type: application/json" \
  -d '{"a": 15, "b": 3, "operation": "multiply"}'
```

**Expected Response:**
```json
HTTP/1.1 200 OK
content-type: application/json
content-length: 15

{"result":45.0}
```

---

## 7. The Day-2 Platform Engineering Workflow

When a developer changes code:
1. **Build & Push:**
   ```bash
   docker build -t localhost:5001/calculator-api:v2 app/
   docker push localhost:5001/calculator-api:v2
   ```
2. **Update GitOps Manifest:**
   Change the image tag in `gitops/base/deployment.yaml` to `localhost:5001/calculator-api:v2`.
3. **Commit & Push to Git:**
   ```bash
   git commit -am "chore: bump calculator-api to v2"
   ```
4. **Automated Reconciliation:**
   ArgoCD detects the change, executes a rolling deployment across the cluster, and routes live traffic through the Envoy Gateway without downtime.

---

## 8. Teardown Instructions

To completely wipe the lab and reclaim disk space:

```bash
kind delete cluster --name lab
docker stop kind-registry && docker rm kind-registry
```