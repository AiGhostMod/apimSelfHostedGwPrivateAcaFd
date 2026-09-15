#!/usr/bin/env bash
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID}"
: "${ACR_NAME:?Set ACR_NAME}"
: "${IMAGE_TAG:?Set IMAGE_TAG}"

[[ "$AZURE_SUBSCRIPTION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
  printf '%s\n' "Invalid Azure subscription ID" >&2; exit 2;
}
[[ "$ACR_NAME" =~ ^[a-zA-Z0-9]{5,50}$ ]] || {
  printf '%s\n' "Invalid ACR name" >&2; exit 2;
}
[[ "$IMAGE_TAG" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' "IMAGE_TAG must be the SHA-256 build-context hash" >&2; exit 2;
}
command -v az >/dev/null || { printf '%s\n' "Azure CLI is required" >&2; exit 127; }

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Every call selects the subscription explicitly; never change global CLI context
# or enable registry admin credentials. ACR Tasks builds without a local daemon.
# Azure CLI resolves --file locally, not relative to the build context.
az account show --subscription "$AZURE_SUBSCRIPTION_ID" --output none
az acr build \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --registry "$ACR_NAME" \
  --image "mock-api:$IMAGE_TAG" \
  --platform linux/amd64 \
  --file "$project_dir/mock-api/Dockerfile" \
  --no-logs \
  "$project_dir/mock-api"
