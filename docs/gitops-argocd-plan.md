# GitOps Image Update Plan — ArgoCD

> **Status:** Design document. Implementation is delegated to a Claude Code agent
> (see `docs/claude-agent-prompt.md`).

---

## 1. Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        GitOps Flow                                      │
│                                                                         │
│  Developer push ──▶ GitHub Actions ──▶ Docker build                    │
│       │                  │                   │                          │
│       │                  │           tag = full git SHA                 │
│       │                  │           push to GHCR                      │
│       │                  │                   │                          │
│       │                  └─── git commit ────┘                         │
│       │                  helm/<svc>/values.yaml                         │
│       │                  image.tag = <sha>  [skip ci]                  │
│       │                                    │                            │
│       │                  ┌─────────────────▼──────────────────┐        │
│       │                  │   ArgoCD (watching helm/ in git)   │        │
│       │                  │   • detects values.yaml change     │        │
│       │                  │   • runs helm diff                  │        │
│       │                  │   • syncs cluster (auto/manual)     │        │
│       │                  └────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Repository Layout

```
assinnata/
├── .github/
│   └── workflows/
│       └── build-release.yml   ← CI pipeline (build + helm update)
├── app/                        ← Application source code
│   ├── Dockerfile
│   └── src/
├── helm/                       ← ArgoCD source of truth (GitOps store)
│   └── app/
│       ├── Chart.yaml
│       ├── values.yaml         ← image.tag auto-updated by CI
│       └── templates/
└── docs/
    ├── gitops-argocd-plan.md   ← this file
    └── claude-agent-prompt.md  ← agent work order
```

---

## 3. ArgoCD Application Manifest

Deploy this manifest into the ArgoCD namespace on your cluster:

```yaml
# argocd/application-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app
  namespace: argocd
  # Finalizer ensures ArgoCD cleans up resources on deletion
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: https://github.com/dogewithit/assinnata.git
    targetRevision: master
    # ArgoCD only watches this path — changes elsewhere are ignored
    path: helm/app

  destination:
    server: https://kubernetes.default.svc
    namespace: app          # pre-create or let ArgoCD create it

  syncPolicy:
    automated:
      prune: true           # remove resources deleted from helm
      selfHeal: true        # revert manual kubectl edits
      allowEmpty: false     # never sync to an empty state
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  # Ignore the image tag in live state diff (ArgoCD manages it via git)
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration

  # Health checks
  revisionHistoryLimit: 10
```

---

## 4. Required Secrets & Config

### 4.1 ArgoCD repo access

ArgoCD needs read access to the repository to pull Helm charts.

```bash
# If repo is private — add credentials via CLI
argocd repo add https://github.com/dogewithit/assinnata.git \
  --username git \
  --password <GITHUB_PAT_WITH_REPO_READ>
```

### 4.2 Kubernetes image pull secret (GHCR)

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_ACTOR> \
  --docker-password=<GITHUB_PAT_WITH_PACKAGES_READ> \
  --namespace app
```

Reference it in `helm/app/values.yaml`:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

### 4.3 GitHub Actions secret for Helm write-back

The workflow needs to push the Helm commit back to master.
Create a fine-grained GitHub PAT with:
- **Contents: Write** for this repository only

Store it as repo secret `GIT_AUTOMATION_TOKEN`.
If not set, the workflow falls back to `GITHUB_TOKEN` (works only when
branch protection does not require PRs).

---

## 5. Trigger Matrix

| Event                              | Build runs? | Helm updated? | ArgoCD syncs? |
|------------------------------------|-------------|---------------|---------------|
| Push to `app/**` → master          | ✅ Yes       | ✅ Yes         | ✅ Yes         |
| Push to `helm/**` only → master    | ❌ No        | N/A           | ✅ Yes (manual helm edit) |
| Pull request (app changes)         | ✅ Yes       | ❌ No (PR only) | ❌ No          |
| CI Helm write-back commit [skip ci]| ❌ No        | N/A           | ✅ Yes         |
| Push to `docs/**` only             | ❌ No        | ❌ No          | ❌ No          |

---

## 6. Loop-Prevention Mechanisms

The system uses **two independent guards** to prevent the Helm write-back from
triggering an infinite build loop:

1. **Path filter** (`.github/workflows/build-release.yml` → `paths:`):
   - The workflow is only triggered by changes in `app/**`.
   - A commit touching only `helm/` never activates the `on.push` trigger.

2. **`[skip ci]` in commit message**:
   - Both GitHub Actions and Gitea/GitLab honour this convention.
   - If the path filter were ever misconfigured, this acts as a hard stop.

Neither mechanism alone is sufficient; both together make the system robust.

---

## 7. Multi-Service Extension

To add a second service (e.g. `services/worker`):

1. Create `services/worker/Dockerfile` and source code.
2. Add `helm/worker/` chart (copy structure from `helm/app/`).
3. In `build-release.yml`, extend the matrix and path filter:

```yaml
# In detect-changes job:
filters: |
  app:
    - "app/**"
  worker:
    - "services/worker/**"

# In build-matrix step:
services='["app","worker"]'
```

4. Add an ArgoCD Application manifest for `helm/worker`.

---

## 8. Rollback Procedure

```bash
# Option A — revert the Helm values commit in git (ArgoCD auto-syncs old tag)
git revert <helm-update-commit-sha>
git push origin master

# Option B — ArgoCD UI / CLI rollback to previous sync revision
argocd app rollback app <revision-number>

# Option C — emergency kubectl (bypasses ArgoCD, selfHeal will revert it)
kubectl set image deployment/app app=ghcr.io/dogewithit/assinnata/app:<old-sha> -n app
```

---

## 9. Observability Integration Points

- **Datadog / NewRelic**: annotate deployments with `DD_VERSION` / `NEW_RELIC_METADATA_KUBERNETES_CLUSTER_NAME` env vars set from `image.tag`.
- **ArgoCD notifications**: configure Slack/PagerDuty webhooks for sync failures.
- **GitHub Deployments API**: the CI workflow can post deployment events keyed on `github.sha` for end-to-end traceability.

---

## 10. Security Considerations

| Concern | Mitigation |
|---------|-----------|
| Secrets in Helm values | Use `envFromSecrets` + K8s Secrets (or Vault/ESO) |
| Image provenance | Build provenance attestation + SBOM enabled in workflow |
| Least-privilege pod | `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL capabilities |
| Write-back PAT scope | Fine-grained PAT, contents write, single repo only |
| Supply chain | Pin all Action versions to SHA, use Dependabot for updates |
