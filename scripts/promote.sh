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
