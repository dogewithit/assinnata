#!/usr/bin/env bash
# create-pull-secret.sh — Create (or recreate) the GHCR image pull secret.
#
# Usage:
#   ./scripts/create-pull-secret.sh \
#     --namespace  app \
#     --username   <github-actor> \
#     --token      <ghcr-pat> \
#     [--registry  ghcr.io]
#
# The script is idempotent: if the secret already exists it is deleted first.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REGISTRY="ghcr.io"
NAMESPACE=""
USERNAME=""
TOKEN=""
SECRET_NAME="ghcr-pull-secret"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)  NAMESPACE="$2";  shift 2 ;;
    --username)   USERNAME="$2";   shift 2 ;;
    --token)      TOKEN="$2";      shift 2 ;;
    --registry)   REGISTRY="$2";   shift 2 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: $0 --namespace <ns> --username <user> --token <pat> [--registry <reg>]" >&2
      exit 1
      ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "$NAMESPACE" ]]; then
  echo "ERROR: --namespace is required" >&2
  exit 1
fi

if [[ -z "$USERNAME" ]]; then
  echo "ERROR: --username is required" >&2
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: --token is required" >&2
  exit 1
fi

# ── Check kubectl is available ────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

# ── Idempotent delete + recreate ──────────────────────────────────────────────
echo "Targeting namespace '${NAMESPACE}' on registry '${REGISTRY}'..."

if kubectl get secret "${SECRET_NAME}" --namespace "${NAMESPACE}" &>/dev/null; then
  echo "Secret '${SECRET_NAME}' already exists — deleting for clean recreation..."
  kubectl delete secret "${SECRET_NAME}" --namespace "${NAMESPACE}"
fi

kubectl create secret docker-registry "${SECRET_NAME}" \
  --namespace      "${NAMESPACE}" \
  --docker-server  "${REGISTRY}" \
  --docker-username "${USERNAME}" \
  --docker-password "${TOKEN}"

# ── Verify ────────────────────────────────────────────────────────────────────
if kubectl get secret "${SECRET_NAME}" --namespace "${NAMESPACE}" &>/dev/null; then
  echo "SUCCESS: Secret '${SECRET_NAME}' created in namespace '${NAMESPACE}'."
else
  echo "FAILURE: Secret '${SECRET_NAME}' was not found after creation." >&2
  exit 1
fi
