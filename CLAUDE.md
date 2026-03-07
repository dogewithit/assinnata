# dogewithit/assinnata — GitOps Pipeline Context

## Repository Purpose

This is a GitOps-managed application repository. The CI/CD pipeline builds Docker images,
updates Helm charts, and ArgoCD automatically syncs the Kubernetes cluster on every merge
to `master`.

---

## Branching & CI/CD Flow

```
feat/xxxx  ──▶  PR (open against master)
                 │
                 │  GitHub Actions: Build & Release
                 │   1. detect-changes  — did app/** change?
                 │   2. build           — docker build (NO push, validates only)
                 │   3. update-helm     — SKIPPED on PRs
                 │   4. notify-deploy   — SKIPPED on PRs
                 ▼
              Merge to master
                 │
                 │  GitHub Actions: Build & Release
                 │   1. detect-changes  — app/** changed? (must be true to proceed)
                 │   2. build           — docker build + push to GHCR (full SHA tag)
                 │   3. update-helm     — yq patches helm/app/values.yaml image.tag
                 │                        commits "chore(helm): ... [skip ci]" to master
                 │   4. notify-deploy   — GitHub Deployment event (state: success)
                 ▼
              ArgoCD (polls git every ~3 min)
                 │
                 │  detects helm/app/values.yaml change
                 │  helm template diff → kubectl apply
                 │  automated: prune=true, selfHeal=true
                 ▼
              Kubernetes namespace: app
                 │
                 │  RollingUpdate — 2 pods across 2 nodes
                 │  readinessProbe /readyz gates traffic
                 ▼
              Running: ghcr.io/dogewithit/assinnata/app:<full-sha>
```

### Key rules

| Condition | build | update-helm | notify-deployment |
|-----------|-------|-------------|-------------------|
| PR — `app/**` changed | ✓ build-only (no push) | ✗ | ✗ |
| push master — `app/**` changed | ✓ build + push | ✓ | ✓ |
| push master — workflow file only | ✗ skipped | ✗ | ✗ |
| push master — `helm/**` only | ✗ (path filter) | ✗ | ✗ |

### Loop-prevention (two independent guards)

1. **Path filter** — `on.push.paths: [app/**, .github/workflows/...]`. A helm write-back commit never matches, so it never re-triggers the workflow.
2. **`[skip ci]`** — the helm write-back commit message carries this tag. Fallback if paths filter is ever misconfigured.

---

## Repository Layout

```
.github/
  workflows/
    build-release.yml   CI pipeline (detect → build → helm → deploy event)
  dependabot.yml        Weekly updates: Actions, Docker, Python packages
app/
  Dockerfile            Multi-stage Python build (builder + slim runtime)
  src/
    main.py             FastAPI app — /healthz  /readyz  /
    requirements.txt    Python dependencies (fastapi, uvicorn)
argocd/
  application-app.yaml          Production ArgoCD Application (namespace: app)
  application-app-staging.yaml  Staging ArgoCD Application (namespace: app-staging)
  project.yaml                  AppProject 'platform' — scoped to this repo
  notifications-cm.yaml         Slack alerts: sync-failed, sync-succeeded, health-degraded
helm/
  app/
    Chart.yaml              Chart metadata (version 0.1.0)
    values.yaml             Default values — image.tag auto-patched by CI
    values-staging.yaml     Overrides: replicas=1, tag=latest
    values-production.yaml  Overrides: replicas=3, HPA enabled
    templates/              Deployment, Service, ServiceAccount, HPA
scripts/
  create-pull-secret.sh   Idempotent GHCR pull secret creator
docs/
  gitops-argocd-plan.md   Full architecture and design decisions
  claude-agent-prompt.md  Original agent work order
```

---

## ArgoCD

**Installed on:** `do-fra1-assinnata` Kubernetes cluster, namespace `argocd`
**Version:** v3.3.2
**Application:** `app` (production, namespace `app`)

```bash
# Login (port-forward required — ArgoCD is not exposed externally)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure

# App status
argocd app get app --insecure

# Force refresh (don't wait for 3-min poll)
argocd app get app --insecure --refresh

# Wait for sync + healthy
argocd app wait app --health --sync --insecure --timeout 120

# Manual sync (normally automated)
argocd app sync app --insecure
```

---

## Kubernetes

**Cluster:** `do-fra1-assinnata` (DigitalOcean Frankfurt)
**Namespace:** `app`
**Nodes:** 2 (`default-k942a`, `default-kzpeu`)
**Image registry:** `ghcr.io/dogewithit/assinnata/app:<full-sha>`

```bash
# Get kubeconfig
source .env && doctl kubernetes cluster kubeconfig save 6abd6401-8da7-48f6-800f-b34bd1346c38 -t "$DO_TOKEN"

# Check rollout
kubectl rollout status deployment/app -n app --timeout=120s

# Live pods
kubectl get pods -n app -o wide

# Current image SHA
kubectl get deployment app -n app -o jsonpath='{.spec.template.spec.containers[0].image}'

# Logs
kubectl logs -n app deployment/app --tail=50

# Quick health check
kubectl port-forward svc/app -n app 9090:80 &
curl http://localhost:9090/healthz
curl http://localhost:9090/readyz
curl http://localhost:9090/
```

---

## Image Pull Secret

The GHCR pull secret must exist in the `app` namespace **before** ArgoCD can pull images.
It is not managed by Helm (secrets shouldn't live in git).

```bash
# Create / recreate (idempotent)
./scripts/create-pull-secret.sh \
  --namespace app \
  --username  dogewithit \
  --token     <github-pat-with-packages-read> \
  --registry  ghcr.io

# Verify
kubectl get secret ghcr-pull-secret -n app
```

---

## Rollback

```bash
# Option A — revert the Helm tag commit in git (ArgoCD auto-syncs old image)
git revert <helm-update-commit-sha>
git push origin master

# Option B — ArgoCD CLI rollback to a previous revision number
argocd app rollback app <revision-number> --insecure

# Option C — emergency kubectl (ArgoCD selfHeal will revert after next sync)
kubectl set image deployment/app app=ghcr.io/dogewithit/assinnata/app:<old-sha> -n app
```

---

## Required Secrets & Variables

| Name | Where | Purpose |
|------|-------|---------|
| `GITHUB_TOKEN` | Auto (Actions) | GHCR push, Deployments API |
| `GIT_AUTOMATION_TOKEN` | Repo secret (optional) | Fine-grained PAT for helm write-back |
| `SERVICE_URL` | Repo variable (optional) | Shown in GitHub Deployments UI |
| `$slack-token` | K8s secret in argocd ns | ArgoCD Slack notifications |

---

## Adding a New Service

1. Add source under `services/<name>/` with a `Dockerfile`.
2. Create `helm/<name>/` (copy `helm/app/` structure).
3. In `build-release.yml`, add to the path filter and extend the matrix services list.
4. Create `argocd/application-<name>.yaml` pointing to `helm/<name>/`.
5. Apply: `kubectl apply -f argocd/application-<name>.yaml`
6. Create pull secret in the new namespace via `scripts/create-pull-secret.sh`.
