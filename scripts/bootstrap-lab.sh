#!/usr/bin/env bash
# Ephemeral Local Platform Engineering Lab Bootstrap
# Spins up Tier 1 (Gitea + act_runner + Harbor), Tier 2 (kind-admin), Tier 3 (kind-dev + kind-prod),
# locks 'seed' remote (GitHub), wires 'origin' to Local Gitea, seeds 1.0.0 images, and deploys via Argo CD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${ROOT}/.lab-runtime/appliances"

echo "==> 0. Pre-flight check..."
for cmd in docker kind kubectl kustomize helm argocd jq node skopeo git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' is not installed. Run: brew install $cmd" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker / OrbStack is not running. Start OrbStack first!" >&2; exit 1; }

if ! grep -q "orders.dev.local" /etc/hosts; then
  echo "==> Adding lab hostnames to /etc/hosts (requires sudo)..."
  sudo sh -c 'echo "127.0.0.1 gitea.orb.local harbor.orb.local orders.dev.local orders.prod.local" >> /etc/hosts'
fi

mkdir -p "${RUNTIME}"
docker network inspect kind >/dev/null 2>&1 || docker network create kind

echo "==> 1. Starting Tier 1A: Gitea + Local Actions Runner..."
cat <<'COMPOSE' > "${RUNTIME}/docker-compose.yml"
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
COMPOSE

(cd "${RUNTIME}" && docker compose up -d gitea)
until curl -sf http://localhost:3000/api/v1/version >/dev/null; do sleep 1; done

docker exec -u git gitea gitea admin user create \
  --username platform \
  --password password123 \
  --email platform@local.lab \
  --admin --must-change-password=false 2>/dev/null || true

curl -sf -u "platform:password123" -X POST "http://localhost:3000/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -d '{"name": "gitops-repo", "private": false, "auto_init": false}' >/dev/null 2>&1 || true

export RUNNER_TOKEN=$(docker exec -u git gitea gitea actions generate-runner-token)
(cd "${RUNTIME}" && docker compose up -d gitea-runner)

echo "==> 2. Starting Tier 1B: Harbor Registry + Trivy Scanner..."
HARBOR_VERSION="v2.11.1"
if [ ! -d "${RUNTIME}/harbor" ]; then
  curl -sL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz" | tar xz -C "${RUNTIME}"
fi
(
  cd "${RUNTIME}/harbor"
  cp harbor.yml.tmpl harbor.yml
  sed -i '' 's/^hostname: .*/hostname: harbor.orb.local/' harbor.yml
  sed -i '' 's/port: 80$/port: 8085/' harbor.yml
  sed -i '' '/^https:/,/^[^ ]/ s/^/#/' harbor.yml
  sed -i '' 's/^harbor_admin_password: .*/harbor_admin_password: Harbor12345/' harbor.yml
  sed -i '' "s|^data_volume: .*|data_volume: ${RUNTIME}/harbor-data|" harbor.yml
  sudo ./install.sh --with-trivy
)
docker network connect kind nginx 2>/dev/null || true
until curl -sf -u "admin:Harbor12345" "http://harbor.orb.local:8085/api/v2.0/systeminfo" >/dev/null; do sleep 2; done

curl -sf -u "admin:Harbor12345" -X POST "http://harbor.orb.local:8085/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name": "dev", "metadata": {"public": "false", "auto_scan": "true"}}' >/dev/null 2>&1 || true

curl -sf -u "admin:Harbor12345" -X POST "http://harbor.orb.local:8085/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name": "prod", "metadata": {"public": "false", "auto_scan": "true", "prevent_vul": "true", "severity": "critical"}}' >/dev/null 2>&1 || true

docker login harbor.orb.local:8085 -u admin -p Harbor12345

echo "==> 3. Creating Kind Clusters (admin, dev, prod)..."
create_kind_cluster() {
  local NAME="$1" HTTP_HOST_PORT="$2" EXTRA_PORT_MAPPING="${3:-}"
  if kind get clusters 2>/dev/null | grep -qx "${NAME}"; then
    echo "    kind-${NAME} already exists, skipping creation."
    return
  fi
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

echo "==> 4. Configuring kind-admin (Argo CD + Central Grafana, Prometheus, Loki)..."
kubectl config use-context kind-admin
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
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

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8075 --username admin --password "${ARGOCD_PASS}" --insecure

for ENV in dev prod; do
  INTERNAL_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${ENV}-control-plane")
  kubectl config set-cluster "kind-${ENV}" --server="https://${INTERNAL_IP}:6443"
  argocd cluster add "kind-${ENV}" --name "${ENV}-cluster" --yes
done

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

echo "==> 5. Configuring kind-dev & kind-prod (Envoy Gateway, Harbor Pull Secrets, Telemetry Agents)..."
ADMIN_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' admin-control-plane)

for ENV in dev prod; do
  kubectl config use-context "kind-${ENV}"
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.2.0 --namespace envoy-gateway-system --create-namespace
  kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s

  cat <<GW | kubectl apply -f -
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
GW

  kubectl create namespace "${ENV}" 2>/dev/null || true
  kubectl -n "${ENV}" create secret docker-registry harbor-pull-secret \
    --docker-server="harbor.orb.local:8085" \
    --docker-username="admin" \
    --docker-password="Harbor12345" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install promtail grafana/promtail \
    --namespace monitoring --create-namespace \
    --set "config.clients[0].url=http://${ADMIN_IP}:30100/loki/api/v1/push" \
    --set "config.snippets.extraRelabelConfigs[0].target_label=cluster" \
    --set "config.snippets.extraRelabelConfigs[0].replacement=${ENV}"

  helm upgrade --install kube-prom-agent prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.enabled=false \
    --set alertmanager.enabled=false \
    --set prometheus.prometheusSpec.mode=Agent \
    --set "prometheus.prometheusSpec.externalLabels.cluster=${ENV}" \
    --set "prometheus.prometheusSpec.remoteWrite[0].url=http://${ADMIN_IP}:30090/api/v1/write"
done

echo "==> 6. Wiring Git Remotes (seed=GitHub [push DISABLED], origin=Local Gitea) & Seeding 1.0.0..."
cd "${ROOT}"
CURRENT_ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
if [[ "${CURRENT_ORIGIN}" == *"github.com"* ]]; then
  git remote rename origin seed
fi
if git remote get-url seed >/dev/null 2>&1; then
  git remote set-url --push seed DISABLED
fi
git remote remove origin 2>/dev/null || true
git remote add origin "http://platform:password123@gitea.orb.local:3000/platform/gitops-repo.git"

git branch -f dev master 2>/dev/null || true
git branch -f prod master 2>/dev/null || true

"${ROOT}/scripts/build-and-push.sh" all 1.0.0
"${ROOT}/scripts/promote.sh" all --seed
git push -u origin master dev prod --force

curl -sf -u "platform:password123" -X POST "http://gitea.orb.local:3000/api/v1/repos/platform/gitops-repo/branch_protections" \
  -H "Content-Type: application/json" \
  -d '{
    "branch_name": "prod",
    "enable_push": false,
    "enable_status_check": true,
    "status_check_contexts": ["test"]
  }' >/dev/null 2>&1 || true

kubectl --context kind-admin apply -f "${ROOT}/argocd/microservices-appset.yaml"
sleep 5
for SVC in orders payments inventory; do
  argocd app sync "${SVC}-api-prod" || true
done

echo "================================================================="
echo " Local Platform Engineering Lab is LIVE!"
echo " - Gitea UI:   http://gitea.orb.local:3000   (platform / password123)"
echo " - Harbor UI:  http://harbor.orb.local:8085  (admin / Harbor12345)"
echo " - Argo CD UI: https://localhost:8075        (admin / ${ARGOCD_PASS})"
echo " - Grafana UI: http://localhost:8070         (admin / admin)"
echo " - Dev Edge:   http://orders.dev.local:8080/orders"
echo " - Prod Edge:  http://orders.prod.local:8090/orders"
echo "================================================================="
