#!/usr/bin/env bash
# Ephemeral Local Platform Engineering Lab Bootstrap — Native Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/bootstrap-common.sh
source "${SCRIPT_DIR}/bootstrap-common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: bootstrap-linux.sh is intended for Linux. On macOS with OrbStack, run ./scripts/bootstrap-orbstack.sh" >&2
  exit 1
fi

preflight_check

if ! grep -q "gitea.orb.local" /etc/hosts || ! grep -q "harbor.orb.local" /etc/hosts; then
  echo "==> Linux: adding gitea.orb.local & harbor.orb.local to /etc/hosts (requires sudo)..."
  echo "127.0.0.1 gitea.orb.local harbor.orb.local" | sudo tee -a /etc/hosts >/dev/null
fi

DAEMON_JSON="/etc/docker/daemon.json"
if [ ! -f "${DAEMON_JSON}" ] || ! grep -q "harbor.orb.local:8085" "${DAEMON_JSON}"; then
  echo "==> Linux: configuring Docker insecure-registries for harbor.orb.local:8085 in ${DAEMON_JSON} (requires sudo)..."
  sudo mkdir -p /etc/docker
  CURRENT_DAEMON="{}"
  if [ -f "${DAEMON_JSON}" ] && [ -s "${DAEMON_JSON}" ]; then
    CURRENT_DAEMON="$(cat "${DAEMON_JSON}")"
  fi
  echo "${CURRENT_DAEMON}" | jq '. + {"insecure-registries": ((.["insecure-registries"] // []) + ["harbor.orb.local:8085"] | unique)}' \
    | sudo tee "${DAEMON_JSON}" >/dev/null
  sudo systemctl restart docker
  wait_for_docker 30
fi

bootstrap_platform
