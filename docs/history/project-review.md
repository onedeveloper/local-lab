# Project Review: `local-lab`

> **Scope:** Code review of the three platform lifecycle scripts (`scripts/bootstrap-lab.sh`, `scripts/onboard-repo.sh`, `scripts/nuke-lab.sh`), the Go test suite (`tests/platform_test.go`), and the documentation set under `docs/`.
>
> **Date:** 2026-11-05

---

## Overall Assessment

This is a **well-engineered, well-documented platform lab**. The core design decisions are sound and the implementation is consistent with them.

- **App-agnostic separation** (platform infra vs. workloads) is clean and *enforced* — `tests/platform_test.go` actively asserts that `k8s/`, `argocd/`, `.gitea/` are absent and that `bootstrap-lab.sh` contains no `orders`/`inventory`/`payments` references. The design principle is guarded by a test, not just prose.
- **Tiered architecture** is textbook-correct: foundational appliances in `docker compose` (survive cluster wipes, no chicken-and-egg), `kind-admin` as the Argo CD / observability hub, `kind-dev` / `kind-prod` as disposable spokes. The reasoning for *why* (Argo CD needs etcd as its DB, containerd pulls at the node level, blast-radius isolation) is explained well in the docs.
- **Two-key HITL promotion** (`dev` auto-sync, `prod` gated by branch protection + manual Argo CD sync) faithfully mirrors real enterprise release governance.
- The **Go tests pass**, all three scripts are executable and pass `bash -n`, and the generated multi-cluster `kind` config validates as well-formed YAML (the `ADMIN_EXTRA` indentation was reproduced and checked — both port mappings align at the same level).

No correctness defects in the primary target path (OrbStack + macOS). The issues below are mostly **portability / robustness** gaps that contradict the script's "cross-platform" claims.

---

## Findings (Prioritized)

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 1 | **High** | `bootstrap-lab.sh:139`, `27–40` | `docker login harbor.orb.local:8085` is **unguarded** under `set -e`, but insecure-registry auto-config only covers **OrbStack** (`~/.orbstack/config/docker.json`). On Docker Desktop or native Linux the host daemon rejects plain-HTTP Harbor, so login fails and the **entire bootstrap halts**. The Linux branch (lines 35–40) only touches `/etc/hosts`, not `insecure-registries` — that step is left manual in the README despite the "3 adjustments are automated" claim. |
| 2 | **Medium** | `onboard-repo.sh:36,44` | Origin is only renamed to `seed` when it matches `*github.com*`. Any other existing remote (GitLab, self-hosted) is **silently deleted** by `git remote remove origin` — a data-loss footgun that contradicts the "safely preserves" header. |
| 3 | **Medium** | `onboard-repo.sh:52` | `git push` requires `user.email` / `user.name`; the script never sets them, so push fails under `set -e` for users without a global git identity. |
| 4 | **Low / Med** | `bootstrap-lab.sh:113–124` | Harbor `sed` edits are brittle and **version-coupled** to `v2.11.1` (`s/port: 80$/…` unanchored; the `/^https:/,/^[^ ]/ s/^/#/` range; the `listen 8080;→listen 8085;` double-inject). They'll break on a Harbor bump. |
| 5 | **Low** | `bootstrap-lab.sh:22` vs `94,108,129` | `curl` is used heavily but **absent from the pre-flight check**, so a minimal machine fails confusingly mid-script instead of at start. |
| 6 | **Low** | `bootstrap-lab.sh:94,129` | `until curl …; do sleep; done` readiness loops have **no max-attempts / timeout** — a failed Gitea / Harbor start hangs forever instead of failing clearly. |
| 7 | **Low** | repo-wide | The repo has a Go test suite but **no CI** to run `go test` / `bash -n` on push, so the app-agnostic invariant it guards isn't continuously protected. |
| 8 | **Info** | `nuke-lab.sh` | Deletes clusters / network / runtimes but leaves **stale kubeconfig contexts** and the insecure-registry entry it added to `~/.orbstack/config/docker.json` — minor, but "nothing survives" is the stated goal. |

### Verified Non-Issues

Things that were checked and are *fine*:

- `base64 -d` works on this macOS (both `-d` and the BSD `-D` form succeed), so there is no portability bug at `bootstrap-lab.sh:189`.
- The generated `kind` config indentation is valid YAML.
- The jq `insecure-registries` dedupe expression at `bootstrap-lab.sh:29` is correct — the `| unique` scopes to the array as intended.
- Runtime state is correctly git-ignored (`.lab-runtime/`).
- The Harbor double-listen / alias scheme is internally consistent even if intricate.

---

## Recommendation

The top fix is **#1** — it's the one that makes the "OrbStack *or* Docker Desktop" and "Linux" claims false in practice. Make the host daemon's insecure-registry config platform-aware (or at minimum guard the login with `|| true` plus a clear "you must configure insecure-registries manually" warning), since the in-cluster containerd mirror already uses `insecure_skip_verify=true` and the host login is only needed for host-side push/pull.

Suggested starting set, highest-impact / lowest-risk first:

- **#1** — platform-aware insecure-registry handling (or guard + warn).
- **#2 / #3** — harden `onboard-repo.sh`: preserve any non-GitHub origin as `seed`; ensure a git identity before `git push`.
- **#5 / #6** — add `curl` to the pre-flight check and add bounded retries / timeouts to the readiness loops.

A small GitHub Actions workflow for **#7** that runs `go test ./tests/...` and `bash -n` on every script would also protect the app-agnostic invariant continuously.
