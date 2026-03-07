# Claude Code Agent Work Order — ArgoCD GitOps Implementation

> **For agent use:** Copy the prompt below verbatim into a Claude Code session
> pointed at this repository. The agent should read `docs/gitops-argocd-plan.md`
> first, then execute the tasks listed here.

---

## Prompt

```
You are a senior platform/DevOps engineer implementing a GitOps continuous
delivery system.  Your target repository is the one you are currently in.

## Context

Read these files before starting:
- docs/gitops-argocd-plan.md          → full architecture and design decisions
- .github/workflows/build-release.yml → existing CI pipeline
- helm/app/Chart.yaml                  → Helm chart metadata
- helm/app/values.yaml                 → values file (image.tag is CI-managed)

## Your Tasks

### Task 1 — ArgoCD Application manifests

Create `argocd/` directory with the following files:

1. `argocd/application-app.yaml`
   - ArgoCD Application pointing to `helm/app/` in this repo on branch `master`
   - Automated sync with prune=true and selfHeal=true
   - CreateNamespace=true syncOption
   - Retry policy: 5 retries, exponential backoff
   - Use the exact YAML structure from docs/gitops-argocd-plan.md §3

2. `argocd/project.yaml`
   - ArgoCD AppProject named `platform`
   - Source repos: this repo URL only
   - Destination: any namespace on the in-cluster server
   - Cluster and namespace resource whitelist (no CRDs, no ClusterRoles by default)

3. `argocd/notifications-cm.yaml` (ConfigMap patch)
   - Configure ArgoCD notifications for Slack
   - Triggers: on-sync-failed, on-sync-succeeded, on-health-degraded
   - Use template variables: app name, sync revision, sync status
   - Placeholder for `$slack-token` secret reference

### Task 2 — Image pull secret automation

Create `scripts/create-pull-secret.sh`:
- Bash script that creates the GHCR image pull secret in the target namespace
- Accepts: --namespace, --username, --token, --registry (default ghcr.io)
- Idempotent: delete + recreate if exists
- Outputs a clear success/failure message
- Make the file executable (chmod +x)

### Task 3 — Helm values environments overlay

Extend the Helm chart with per-environment overrides:

Create these files:
- `helm/app/values-staging.yaml`    → replicas=1, resources smaller, tag=latest
- `helm/app/values-production.yaml` → replicas=3, HPA enabled, stricter resources

Update `argocd/application-app.yaml` to add a staging Application variant
`argocd/application-app-staging.yaml` pointing to `helm/app/` with
`valueFiles: [values.yaml, values-staging.yaml]`.

### Task 4 — GitHub Actions: deployment event reporting

Amend `.github/workflows/build-release.yml` to add a new job `notify-deployment`
that runs after `update-helm` succeeds.  The job must:

1. Post a GitHub Deployment event via the REST API:
   ```
   POST /repos/{owner}/{repo}/deployments
   ```
   with payload:
   ```json
   {
     "ref": "<github.sha>",
     "environment": "production",
     "description": "Deploy <service> @ <sha>",
     "auto_merge": false,
     "required_contexts": []
   }
   ```

2. Immediately update the deployment status to `success`:
   ```
   POST /repos/{owner}/{repo}/deployments/{id}/statuses
   ```
   with `state: success` and `environment_url` pointing to the service URL
   (read from a new `SERVICE_URL` repo variable).

Use `GITHUB_TOKEN` for auth.  Handle the case where `SERVICE_URL` is not set
(skip environment_url in that case).

### Task 5 — Dependabot configuration

Create `.github/dependabot.yml` to auto-update:
- GitHub Actions (weekly, grouped by ecosystem)
- Docker base images in `app/Dockerfile` (weekly)
- Python packages in `app/src/requirements.txt` (weekly)

### Task 6 — Documentation

Update `README.md` to add a "CI/CD & GitOps" section that explains:
- The overall flow (diagram in ASCII or mermaid)
- How to add a new service
- How to roll back
- Required repository secrets and variables
- Links to docs/gitops-argocd-plan.md

## Constraints

- Do NOT break the loop-prevention mechanisms documented in §6 of the plan.
  Any change to the workflow `paths:` filter must be reviewed carefully.
- All new shell scripts must pass `shellcheck`.
- YAML files must be valid (run `yamllint` if available).
- Do not commit secrets or tokens in plain text — use placeholder references.
- Commit all changes with clear conventional-commit messages.
- Push to the current branch when done.

## Success Criteria

- [ ] `argocd/` directory contains at least 3 valid YAML files
- [ ] `scripts/create-pull-secret.sh` is executable and passes shellcheck
- [ ] `helm/app/values-staging.yaml` and `values-production.yaml` exist
- [ ] `argocd/application-app-staging.yaml` references both values files
- [ ] `build-release.yml` has the `notify-deployment` job
- [ ] `.github/dependabot.yml` exists and covers Actions + Docker + Python
- [ ] `README.md` has a "CI/CD & GitOps" section
```

---

## Notes for the agent

- The Gitea remote is at `http://local_proxy@127.0.0.1:60074/git/dogewithit/assinnata`
- The active branch is `claude/github-actions-gitops-pipeline-ALM3C`
- Push to that branch when done; the MR is already open
- Do not push directly to `master`
