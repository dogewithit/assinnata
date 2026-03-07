#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# open-pr.sh — Create the pull request via terminal (GitHub API or gh CLI)
#
# Usage:
#   export GITHUB_TOKEN=<your-fine-grained-or-classic-PAT>
#   bash docs/open-pr.sh
#
# Alternatively, if you have the GitHub CLI installed:
#   gh auth login
#   bash docs/open-pr.sh --gh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

OWNER="dogewithit"
REPO="assinnata"
HEAD_BRANCH="claude/github-actions-gitops-pipeline-ALM3C"
BASE_BRANCH="master"

PR_TITLE="feat(ci): GitHub Actions build pipeline + Helm chart + GitOps ArgoCD plan"

PR_BODY=$(cat <<'BODY'
## Summary

### What's in this PR

| Path | Description |
|------|-------------|
| `.github/workflows/build-release.yml` | CI pipeline: triggers only on `app/**`, builds Docker image tagged with full git SHA, pushes to GHCR, patches `helm/app/values.yaml`, commits back with `[skip ci]` |
| `helm/app/` | Full Helm chart (Deployment, Service, ServiceAccount, HPA); image tag CI-managed, pinned to commit SHA |
| `app/` | Python FastAPI placeholder, non-root multi-stage Dockerfile |
| `docs/gitops-argocd-plan.md` | ArgoCD Application YAML, trigger matrix, loop-prevention rationale, rollback procedure |
| `docs/claude-agent-prompt.md` | Work order for a follow-up Claude Code agent (ArgoCD manifests, env overlays, Dependabot) |

### Loop-prevention design

Two independent guards prevent the Helm write-back from re-triggering a build:
1. **Path filter** — workflow `on.push.paths` only matches `app/**`; commits to `helm/**` never activate it
2. **`[skip ci]`** — commit message convention honoured by GitHub Actions as defence-in-depth

---

## Manual steps to activate

### 1. Repository secrets

| Secret name | Value |
|-------------|-------|
| `GIT_AUTOMATION_TOKEN` | Fine-grained PAT: **contents: write** on this repo (for Helm write-back) |
| _(optional)_ `SLACK_WEBHOOK_URL` | For ArgoCD notifications (see plan doc) |

```bash
# Set via GitHub CLI
gh secret set GIT_AUTOMATION_TOKEN --body "<your-PAT>"
```

### 2. GHCR image pull secret on the cluster

```bash
# Run once per namespace
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_ACTOR> \
  --docker-password=<PAT_WITH_PACKAGES_READ> \
  --namespace app
```

### 3. Apply ArgoCD Application (after follow-up agent completes)

```bash
kubectl apply -f argocd/application-app.yaml
argocd app sync app
```

### 4. Verify the pipeline

After merging this PR:
```bash
# Trigger a build by modifying app source
echo "# trigger" >> app/src/main.py
git add app/src/main.py
git commit -m "chore: trigger build test"
git push origin master

# Watch the workflow
gh run watch

# Verify Helm was updated
git log --oneline helm/app/values.yaml | head -5
grep "image.tag" helm/app/values.yaml
```

---

## Test plan

- [ ] Push to `app/src/main.py` → build workflow fires, Docker image pushed, `helm/app/values.yaml` updated
- [ ] Push directly to `helm/app/values.yaml` → build workflow does **NOT** fire
- [ ] Verify the Helm commit message contains `[skip ci]`
- [ ] Confirm `image.tag` in values.yaml matches the exact 40-char commit SHA
- [ ] ArgoCD detects the values.yaml change and syncs the cluster
BODY
)

# ─── Mode: GitHub CLI ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "--gh" ]]; then
  if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install from https://cli.github.com/" >&2
    exit 1
  fi
  gh pr create \
    --repo "${OWNER}/${REPO}" \
    --head "${HEAD_BRANCH}" \
    --base "${BASE_BRANCH}" \
    --title "${PR_TITLE}" \
    --body "${PR_BODY}"
  exit 0
fi

# ─── Mode: curl (GitHub REST API) ────────────────────────────────────────────
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN is not set."
  echo ""
  echo "Set it and retry:"
  echo "  export GITHUB_TOKEN=<your-PAT>"
  echo "  bash docs/open-pr.sh"
  echo ""
  echo "Or use the GitHub CLI:"
  echo "  gh auth login"
  echo "  bash docs/open-pr.sh --gh"
  echo ""
  echo "Or open the PR manually at:"
  echo "  https://github.com/${OWNER}/${REPO}/pull/new/${HEAD_BRANCH}"
  exit 1
fi

echo "Creating PR via GitHub REST API..."

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${OWNER}/${REPO}/pulls" \
  --data "$(jq -n \
    --arg title  "${PR_TITLE}" \
    --arg head   "${HEAD_BRANCH}" \
    --arg base   "${BASE_BRANCH}" \
    --arg body   "${PR_BODY}" \
    '{title: $title, head: $head, base: $base, body: $body}'
  )")

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY_RESP=$(echo "${RESPONSE}" | head -n -1)

if [[ "${HTTP_CODE}" == "201" ]]; then
  PR_URL=$(echo "${BODY_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['html_url'])")
  echo ""
  echo "✓ Pull request created successfully:"
  echo "  ${PR_URL}"
else
  echo "ERROR: GitHub API returned HTTP ${HTTP_CODE}"
  echo "${BODY_RESP}" | python3 -m json.tool 2>/dev/null || echo "${BODY_RESP}"
  exit 1
fi
