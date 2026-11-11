#!/usr/bin/env bash
# Onboard an external local Git repository onto the Local Platform Lab (Gitea + Branch Protection + Argo CD).
#
# Usage:
#   ./scripts/onboard-repo.sh <path-to-local-repo> [gitea-repo-name]
#
# What it does:
#   1. Creates the repository in local Gitea (http://gitea.orb.local:3000/platform/<repo-name>.git).
#   2. Safely preserves any existing external 'origin' remote as 'seed' (with push DISABLED) and wires 'origin' to Gitea.
#   3. Creates 'dev' and 'prod' branches if missing (without clobbering existing branches) and pushes to Gitea.
#   4. Configures/updates branch protection on 'prod' in Gitea (requires PR + green CI status check).
#   5. Applies any Argo CD manifests found in <repo>/argocd/ to kind-admin.
set -euo pipefail

REPO_PATH="${1:?Usage: $0 <path-to-local-repo> [gitea-repo-name]}"
if ! git -C "${REPO_PATH}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: '${REPO_PATH}' is not a Git repository." >&2
  exit 1
fi
if ! git -C "${REPO_PATH}" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "ERROR: '${REPO_PATH}' has no commits yet. Create an initial commit before onboarding." >&2
  exit 1
fi

REPO_ABS="$(cd "${REPO_PATH}" && pwd)"
REPO_NAME="${2:-$(basename "${REPO_ABS}")}"
GITEA_URL="${GITEA_URL:-http://gitea.orb.local:3000}"
GITEA_API="${GITEA_URL}/api/v1"
GITEA_USER="${GITEA_USER:-platform}"
GITEA_PASS="${GITEA_PASS:-password123}"

if ! curl -sf "${GITEA_API}/version" >/dev/null; then
  echo "ERROR: Cannot reach Gitea at ${GITEA_URL}. Ensure the platform lab is running first." >&2
  exit 1
fi

echo "==> 1. Ensuring repository '${REPO_NAME}' exists in Local Gitea..."
if ! curl -sf -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_API}/repos/${GITEA_USER}/${REPO_NAME}" >/dev/null 2>&1; then
  curl -sf -u "${GITEA_USER}:${GITEA_PASS}" -X POST "${GITEA_API}/user/repos" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${REPO_NAME}\", \"private\": false, \"auto_init\": false}" >/dev/null
fi

echo "==> 2. Wiring Git remotes in ${REPO_ABS}..."
cd "${REPO_ABS}"
GITEA_HOST="${GITEA_URL#*://}"
CURRENT_ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
if [[ -n "${CURRENT_ORIGIN}" && "${CURRENT_ORIGIN}" != *"gitea.orb.local"* && "${CURRENT_ORIGIN}" != *"${GITEA_HOST}"* ]]; then
  if git remote get-url seed >/dev/null 2>&1; then
    echo "    Existing 'seed' remote already present; removing previous 'origin' (${CURRENT_ORIGIN})..."
    git remote remove origin
  else
    echo "    Renaming existing 'origin' (${CURRENT_ORIGIN}) -> 'seed' (push DISABLED)..."
    git remote rename origin seed
  fi
fi
if git remote get-url seed >/dev/null 2>&1; then
  git remote set-url --push seed DISABLED
fi

GITEA_SCHEME="${GITEA_URL%%://*}"
GITEA_REMOTE_URL="${GITEA_SCHEME}://${GITEA_USER}:${GITEA_PASS}@${GITEA_HOST}/${GITEA_USER}/${REPO_NAME}.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "${GITEA_REMOTE_URL}"
else
  git remote add origin "${GITEA_REMOTE_URL}"
fi

DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")"
if ! git show-ref --verify --quiet refs/heads/dev; then
  git branch dev "${DEFAULT_BRANCH}"
fi
if ! git show-ref --verify --quiet refs/heads/prod; then
  git branch prod "${DEFAULT_BRANCH}"
fi

echo "==> 3. Pushing branches to Local Gitea..."
if git ls-remote --exit-code --heads origin prod >/dev/null 2>&1; then
  echo "    Remote 'prod' branch already exists in Gitea (preserving protected prod state); pushing ${DEFAULT_BRANCH} and dev..."
  git push -u origin "${DEFAULT_BRANCH}" dev
else
  git push -u origin "${DEFAULT_BRANCH}" dev prod
fi

echo "==> 4. Ensuring branch protection on 'prod' in Gitea..."
PROTECTION_PAYLOAD='{
  "branch_name": "prod",
  "enable_push": false,
  "enable_status_check": true,
  "status_check_contexts": ["test"]
}'
if curl -sf -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_API}/repos/${GITEA_USER}/${REPO_NAME}/branch_protections/prod" >/dev/null 2>&1; then
  curl -sf -u "${GITEA_USER}:${GITEA_PASS}" -X PATCH "${GITEA_API}/repos/${GITEA_USER}/${REPO_NAME}/branch_protections/prod" \
    -H "Content-Type: application/json" \
    -d "${PROTECTION_PAYLOAD}" >/dev/null
else
  curl -sf -u "${GITEA_USER}:${GITEA_PASS}" -X POST "${GITEA_API}/repos/${GITEA_USER}/${REPO_NAME}/branch_protections" \
    -H "Content-Type: application/json" \
    -d "${PROTECTION_PAYLOAD}" >/dev/null
fi

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
