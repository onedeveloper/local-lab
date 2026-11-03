#!/usr/bin/env bash
# Total Lab Nuke ("Nothing Survives")
# Destroys all 3 Kind clusters, Gitea, Gitea Runner, Harbor, the 'kind' network, and .lab-runtime/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${ROOT}/.lab-runtime/appliances"

echo "==> 1. Destroying Kind clusters (admin, dev, prod)..."
kind delete clusters admin dev prod 2>/dev/null || true

echo "==> 2. Destroying Gitea & Actions Runner..."
if [ -d "${RUNTIME}" ] && [ -f "${RUNTIME}/docker-compose.yml" ]; then
  (cd "${RUNTIME}" && docker compose down -v --remove-orphans) || true
fi

echo "==> 3. Destroying Harbor containers & volumes..."
if [ -d "${RUNTIME}/harbor" ]; then
  (cd "${RUNTIME}/harbor" && sudo docker compose down -v --remove-orphans) || true
fi

echo "==> 4. Removing Docker 'kind' network & wiping .lab-runtime/..."
docker network rm kind 2>/dev/null || true
sudo rm -rf "${ROOT}/.lab-runtime"

echo "==> 5. Resetting Git working tree to clean 'seed' baseline..."
if git -C "${ROOT}" remote get-url seed >/dev/null 2>&1; then
  git -C "${ROOT}" checkout master
  git -C "${ROOT}" reset --hard seed/master
  git -C "${ROOT}" branch -f dev seed/dev
  git -C "${ROOT}" branch -f prod seed/prod
fi

echo "==> Lab completely nuked. Run ./scripts/bootstrap-lab.sh whenever you want a fresh lab!"
