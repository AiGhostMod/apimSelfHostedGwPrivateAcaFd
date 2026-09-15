#!/usr/bin/env bash
# Read-only smoke tests; retry while APIM configuration and Front Door propagate.
set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: bash scripts/test-endpoints.sh [terraform-outputs.json]" >&2
  exit 2
fi
for command in python3 curl; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 2; }
done

attempts="${SMOKE_MAX_ATTEMPTS:-30}"
delay="${SMOKE_RETRY_DELAY:-20}"
timeout="${SMOKE_REQUEST_TIMEOUT:-30}"
for value in "$attempts" "$delay" "$timeout"; do
  if [[ ! "$value" =~ ^[0-9]{1,5}$ ]]; then
    echo "Retry settings must be bounded nonnegative integers" >&2
    exit 2
  fi
done
attempts=$((10#$attempts))
delay=$((10#$delay))
timeout=$((10#$timeout))
if (( attempts < 1 || attempts > 120 || delay > 300 || timeout < 1 || timeout > 120 )); then
  echo "Allowed settings: attempts 1..120, delay 0..300, timeout 1..120 seconds" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scratch=".smoke-test-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
mkdir -m 700 -- "$scratch"
cleanup() {
  rm -f -- "$scratch/body" "$scratch/urls" "$scratch/terraform-outputs.json"
  rmdir -- "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

outputs="${1:-$scratch/terraform-outputs.json}"
if (( $# == 0 )); then
  command -v terraform >/dev/null || { echo "Missing prerequisite: terraform" >&2; exit 2; }
  terraform output -json > "$outputs"
fi
python3 "$script_dir/validate-response.py" outputs "$outputs" > "$scratch/urls"
{
  IFS= read -r self_hosted
  IFS= read -r managed
} < "$scratch/urls"

payload='{"message":"smoke-test","count":7,"enabled":true,"nested":{"items":[1,"two",null],"flag":false}}'

request() {
  local label="$1" root="$2" method="$3" path="$4"
  local attempt status curl_result
  local -a args validation
  args=(--disable --silent --show-error --proto '=https' --connect-timeout 10 --max-time "$timeout"
    --request "$method" --output "$scratch/body" --write-out '%{http_code}')
  validation=(response "$scratch/body" "$method" "$path")
  if [[ "$method" == POST ]]; then
    args+=(--header 'Content-Type: application/json' --data-raw "$payload")
    validation+=("$payload")
  fi
  for ((attempt=1; attempt<=attempts; attempt++)); do
    : > "$scratch/body"
    curl_result=0
    status="$(curl "${args[@]}" --url "${root}${path}")" || curl_result=$?
    printf '\n%s attempt %s/%s: curl=%s HTTP=%s\n' "$label" "$attempt" "$attempts" "$curl_result" "$status"
    cat "$scratch/body"
    printf '\n'
    if (( curl_result == 0 )) && [[ "$status" == 200 ]] &&
      python3 "$script_dir/validate-response.py" "${validation[@]}"; then
      printf 'PASS: %s\n' "$label"
      return 0
    fi
    if (( attempt < attempts )); then sleep "$delay"; fi
  done
  printf 'FAIL: %s exhausted %s attempts\n' "$label" "$attempts" >&2
  return 1
}

failures=0
request "self-hosted GET" "$self_hosted" GET /get || failures=$((failures + 1))
request "self-hosted POST" "$self_hosted" POST /post || failures=$((failures + 1))
request "managed GET" "$managed" GET /get || failures=$((failures + 1))
if (( failures > 0 )); then
  printf '\n%s smoke test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nAll three endpoint smoke tests passed.\n'
