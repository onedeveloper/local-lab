#!/usr/bin/env bash
# Ephemeral Local Platform Engineering Lab Bootstrap — macOS + OrbStack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/bootstrap-common.sh
source "${SCRIPT_DIR}/bootstrap-common.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: bootstrap-orbstack.sh is intended for macOS (Darwin). On Linux, run ./scripts/bootstrap-linux.sh" >&2
  exit 1
fi

preflight_check

ORB_CONFIG="${HOME}/.orbstack/config/docker.json"
if [ ! -f "${ORB_CONFIG}" ]; then
  echo "ERROR: OrbStack configuration not found at ${ORB_CONFIG}. Ensure OrbStack is installed and initialized." >&2
  exit 1
fi

if ! grep -q "harbor.orb.local:8085" "${ORB_CONFIG}"; then
  echo "==> Configuring OrbStack insecure-registries for harbor.orb.local:8085..."
  jq '. + {"insecure-registries": ((.["insecure-registries"] // []) + ["harbor.orb.local:8085"] | unique)}' \
    "${ORB_CONFIG}" > "${ORB_CONFIG}.tmp"
  mv "${ORB_CONFIG}.tmp" "${ORB_CONFIG}"
  if command -v orb >/dev/null 2>&1; then
    orb restart docker
    wait_for_docker 30
  fi
fi

bootstrap_platform
