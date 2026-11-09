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
  (cd "${RUNTIME}/harbor" && docker compose down -v --remove-orphans) || true
fi

echo "==> 4. Removing Docker 'kind' network & wiping .lab-runtime/..."
docker network rm kind 2>/dev/null || true
rm -rf "${ROOT}/.lab-runtime"

echo "==> Lab completely nuked. Run ./scripts/bootstrap-orbstack.sh (macOS) or ./scripts/bootstrap-linux.sh (Linux) whenever you want a fresh platform!"
