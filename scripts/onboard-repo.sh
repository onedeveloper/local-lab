#!/usr/bin/env bash
# Onboard an external local Git repository onto the Local Platform Lab (Gitea + Branch Protection + Argo CD).
#
# Usage:
#   ./scripts/onboard-repo.sh <path-to-local-repo> [gitea-repo-name]
#
# What it does:
#   1. Creates the repository in local Gitea (http://gitea.orb.local:3000/platform/<repo-name>.git).
#   2. Safely preserves any existing GitHub 'origin' as 'seed' (with push DISABLED) and wires 'origin' to Gitea.
#   3. Ensures 'dev' and 'prod' branches exist and pushes all branches to Gitea.
#   4. Configures branch protection on 'prod' in Gitea (requires PR + green CI status check).
#   5. Applies any Argo CD manifests found in <repo>/argocd/ to kind-admin.
set -euo pipefail

REPO_PATH="${1:?Usage: $0 <path-to-local-repo> [gitea-repo-name]}"
if [ ! -d "${REPO_PATH}/.git" ]; then
  echo "ERROR: '${REPO_PATH}' is not a Git repository (missing .git directory)." >&2
  exit 1
fi

REPO_ABS="$(cd "${REPO_PATH}" && pwd)"
REPO_NAME="${2:-$(basename "${REPO_ABS}")}"
GITEA_URL="http://gitea.orb.local:3000"
GITEA_API="${GITEA_URL}/api/v1"
GITEA_USER="platform"
GITEA_PASS="password123"

echo "==> 1. Creating repository '${REPO_NAME}' in Local Gitea..."
curl -sf -u "${GITEA_USER}:${GITEA_PASS}" -X POST "${GITEA_API}/user/repos" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"private\": false, \"auto_init\": false}" >/dev/null 2>&1 || true

echo "==> 2. Wiring Git remotes in ${REPO_ABS}..."
cd "${REPO_ABS}"
CURRENT_ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
if [[ "${CURRENT_ORIGIN}" == *"github.com"* ]]; then
  echo "    Renaming existing GitHub 'origin' -> 'seed' (push DISABLED)..."
  git remote rename origin seed
fi
if git remote get-url seed >/dev/null 2>&1; then
  git remote set-url --push seed DISABLED
fi

git remote remove origin 2>/dev/null || true
git remote add origin "http://${GITEA_USER}:${GITEA_PASS}@gitea.orb.local:3000/${GITEA_USER}/${REPO_NAME}.git"

DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")"
git branch -f dev "${DEFAULT_BRANCH}" 2>/dev/null || true
git branch -f prod "${DEFAULT_BRANCH}" 2>/dev/null || true

echo "==> 3. Pushing branches (${DEFAULT_BRANCH}, dev, prod) to Local Gitea..."
git push -u origin "${DEFAULT_BRANCH}" dev prod --force

echo "==> 4. Enabling branch protection on 'prod' in Gitea..."
curl -sf -u "${GITEA_USER}:${GITEA_PASS}" -X POST "${GITEA_API}/repos/${GITEA_USER}/${REPO_NAME}/branch_protections" \
  -H "Content-Type: application/json" \
  -d '{
    "branch_name": "prod",
    "enable_push": false,
    "enable_status_check": true,
    "status_check_contexts": ["test"]
  }' >/dev/null 2>&1 || true

if [ -d "${REPO_ABS}/argocd" ]; then
  echo "==> 5. Applying Argo CD manifests from ${REPO_ABS}/argocd/ to kind-admin..."
  kubectl --context kind-admin apply -f "${REPO_ABS}/argocd/"
else
  echo "==> 5. No argocd/ directory found in ${REPO_ABS} (skipping Argo CD apply)."
fi

echo "================================================================="
echo " Onboarded '${REPO_NAME}' to Local Platform Lab!"
echo " - Gitea Repo:  ${GITEA_URL}/${GITEA_USER}/${REPO_NAME}"
echo " - Internal Git URL (for Argo CD): http://gitea:3000/${GITEA_USER}/${REPO_NAME}.git"
echo "================================================================="
