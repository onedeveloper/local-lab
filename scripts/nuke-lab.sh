#!/usr/bin/env bash
# Total Lab Nuke ("Nothing Survives")
# Destroys all 3 Kind clusters, Gitea, Gitea Runner, Harbor, the 'kind' network, and the OS-scoped runtime directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${LAB_RUNTIME_DIR:-}" ]]; then
  RUNTIME_ROOT="${LAB_RUNTIME_DIR}"
elif [[ "$(uname -s)" == "Linux" ]]; then
  RUNTIME_ROOT="${XDG_DATA_HOME:-${HOME}/.local/share}/local-lab"
else
  RUNTIME_ROOT="${ROOT}/.lab-runtime"
fi
RUNTIME="${RUNTIME_ROOT}/appliances"

echo "==> 1. Destroying Kind clusters (admin, dev, prod)..."
kind delete clusters admin dev prod 2>/dev/null || true

echo "==> 2. Destroying Gitea & Actions Runner..."
if [ -d "${RUNTIME}" ] && [ -f "${RUNTIME}/docker-compose.yml" ]; then
  (cd "${RUNTIME}" && docker compose down -v --remove-orphans) || true
else
  docker compose -p appliances down -v --remove-orphans 2>/dev/null || true
fi

echo "==> 3. Destroying Harbor containers & volumes..."
if [ -d "${RUNTIME}/harbor" ]; then
  (cd "${RUNTIME}/harbor" && docker compose down -v --remove-orphans) || true
else
  docker compose -p harbor down -v --remove-orphans 2>/dev/null || true
fi

echo "==> 4. Removing Docker 'kind' network & wiping ${RUNTIME_ROOT}..."
docker network rm kind 2>/dev/null || true
rm -rf "${RUNTIME_ROOT}"

echo "==> Lab completely nuked. Run ./scripts/bootstrap-orbstack.sh (macOS) or ./scripts/bootstrap-linux.sh (Linux) whenever you want a fresh platform!"
