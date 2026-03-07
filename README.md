# Matteo Assinnata

**Trading Engineering Manager @ 21Shares / Amun**

## About
With nine years of working experience in IT Financial Services, IT Strategy, Software Architecture, Software Development,  Digital Transformation, and Innovation. I am most skilled in these competence centers:
- Infrastructure as Code, Infrastructure as a Service, Software as a Service
- Continuous Integration / Continuous Delivery and SDLC
- Infrastructure and Application Monitoring
- Application Security
- Release Management

Major providers, tools, and skills:
- AWS, Cloudflare, Digitalocean, Hetzner, Datadog, NewRelic
- K8s, Terraform, CloudFormation, Docker, Python, Nodejs
- Blockchain and cryptocurrencies

## Companies
I have worked for companies like Aziona Ventures, Kami Swiss SA, Mediobanca SPA

## Social
- <a href="https://linkedin.com/in/assinnata" target="_blank">linkedin</a>

---

## CI/CD & GitOps

Full design document: [`docs/gitops-argocd-plan.md`](docs/gitops-argocd-plan.md)

### Overall Flow

```
Developer push (app/**)
        │
        ▼
GitHub Actions — Build & Release
  1. detect-changes   identify which services changed
  2. build            docker build + push to GHCR, tagged with full git SHA
  3. update-helm      bump image.tag in helm/<service>/values.yaml
                      commit back with [skip ci]
  4. notify-deployment post GitHub Deployment event (state: success)
        │
        ▼
ArgoCD (watching helm/ in git)
  • detects values.yaml change
  • runs helm diff
  • syncs cluster automatically (prune + selfHeal)
        │
        ▼
Kubernetes cluster (namespace: app / app-staging)
```

Two loop-prevention guards stop infinite build cycles:
1. **Path filter** — workflow only triggers on `app/**` changes; `helm/` pushes are ignored.
2. **`[skip ci]`** — the Helm write-back commit carries this tag as a second safety net.

### How to Add a New Service

1. Add source code under `services/<name>/` with a `Dockerfile`.
2. Create `helm/<name>/` chart (copy `helm/app/` as a template).
3. In `build-release.yml`, extend the `paths` filter and the `services` matrix.
4. Add `argocd/application-<name>.yaml` pointing to `helm/<name>/`.
5. Apply the ArgoCD manifest: `kubectl apply -f argocd/application-<name>.yaml`.

### How to Roll Back

```bash
# Option A — revert the Helm tag commit in git (ArgoCD auto-syncs old image)
git revert <helm-update-commit-sha>
git push origin master

# Option B — ArgoCD CLI rollback to a previous revision
argocd app rollback app <revision-number>

# Option C — emergency kubectl (ArgoCD selfHeal will revert this after next sync)
kubectl set image deployment/app app=ghcr.io/dogewithit/assinnata/app:<old-sha> -n app
```

### Required Repository Secrets and Variables

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `GIT_AUTOMATION_TOKEN` | Secret | Recommended | Fine-grained PAT (Contents: Write) for Helm write-back. Falls back to `GITHUB_TOKEN`. |
| `GITHUB_TOKEN` | Secret | Auto | Provided by GitHub Actions. Used for GHCR push and Deployment API. |
| `SERVICE_URL` | Variable | Optional | Public URL of the deployed service (shown in GitHub Deployments UI). |

ArgoCD cluster secrets (applied via `kubectl` or `argocd` CLI):

| Name | Where | Description |
|------|-------|-------------|
| `ghcr-pull-secret` | Namespace `app` / `app-staging` | GHCR image pull secret. Create with `scripts/create-pull-secret.sh`. |
| `$slack-token` | ArgoCD namespace secret | Slack bot token for ArgoCD notifications. Referenced in `argocd/notifications-cm.yaml`. |
