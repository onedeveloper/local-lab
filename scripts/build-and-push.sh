#!/usr/bin/env bash
# Build a microservice image, push it to Harbor's 'dev' project, and update the 'dev' Kustomize overlay.
# Usage: scripts/build-and-push.sh <orders|payments|inventory|all> [tag]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="harbor.orb.local:8085"
SERVICES=(orders payments inventory)

warn_branch() {
  local cur; cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -z "$cur" || "$cur" == "$1" ]] || echo "WARNING: you are on branch '$cur', but '$1' deploys from branch '$1'!" >&2
}

tag_of() { sed -n 's/^[[:space:]]*newTag:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"; }

build_one() {
  local svc="$1" tag_arg="${2:-}"
  local overlay="$ROOT/k8s/overlays/dev/$svc/kustomization.yaml"
  local current; current="$(tag_of "$overlay")"
  local tag
  if [[ -n "$tag_arg" ]]; then
    tag="$tag_arg"
  else
    IFS='.' read -r maj min pat <<< "$current"
    tag="${maj}.${min}.$((pat + 1))"
  fi

  local image="${REGISTRY}/dev/${svc}-api:${tag}"
  echo "==> Building & pushing ${image} (was ${current})..."
  docker build -t "${image}" "$ROOT/k8s/base/$svc"
  docker push "${image}"
  sed -i '' "s|^\([[:space:]]*newTag:\).*|\1 \"${tag}\"|" "$overlay"
}

svc="${1:?usage: $0 <orders|payments|inventory|all> [tag]}"
tag="${2:-}"
if [[ "$svc" == "all" ]]; then
  for s in "${SERVICES[@]}"; do build_one "$s" "$tag"; done
else
  build_one "$svc" "$tag"
fi

warn_branch "dev"
echo "==> Done. Commit and push to 'dev' so local Gitea Actions + Argo CD auto-sync it:"
echo "    git add k8s && git commit -m 'Release dev images' && git push origin dev"
