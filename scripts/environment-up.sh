#!/usr/bin/env bash
# Provisions the complete prod-simulated environment in dependency order (§22):
#   1. Ensure S3 Terraform state bucket exists with versioning enabled
#   2. Layer 1: infra-base (VPC, subnets, NAT Gateway)
#   3. Layer 2: infra-k8s, infra-messaging, and 4 infra-database-* repositories (parallel)
#   4. Layer 3: Microservice CD pipelines (parallel)
#   5. Layer 4: api-gateway
#   6. Edge health check: GET /health/<context> via API Gateway (retry every 15s for up to 10 min)
#   7. Layer 5: Serverless Lambdas (parallel)
#   8. Layer 6: Set ENVIRONMENT_ONLINE=true and run custom-monitoring CD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/environment-layers.sh
source "${SCRIPT_DIR}/environment-layers.sh"

ensure_state_bucket() {
  local bucket="$1"
  echo "==> Checking S3 Terraform state bucket '${bucket}'..."

  if aws s3api head-bucket --bucket "${bucket}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "    Bucket '${bucket}' already exists."
  else
    echo "    Bucket '${bucket}' not found. Creating in ${AWS_REGION}..."
    aws s3api create-bucket \
      --bucket "${bucket}" \
      --region "${AWS_REGION}" >/dev/null
    echo "    Bucket '${bucket}' created."
  fi

  echo "    Ensuring bucket versioning is Enabled on '${bucket}'..."
  aws s3api put-bucket-versioning \
    --bucket "${bucket}" \
    --region "${AWS_REGION}" \
    --versioning-configuration Status=Enabled
}

resolve_gateway_endpoint() {
  local bucket="$1"
  local endpoint=""

  endpoint="$(
    aws s3 cp "s3://${bucket}/infra/prod-simulated/api-gateway/terraform.tfstate" - \
      --region "${AWS_REGION}" 2>/dev/null \
      | jq -r '.outputs.api_endpoint.value // empty' || true
  )"

  if [[ -z "${endpoint}" ]]; then
    endpoint="$(
      aws apigatewayv2 get-apis \
        --region "${AWS_REGION}" \
        --output json \
        | jq -r '.Items[] | select(.Name | test("oficina-mecanica")) | .ApiEndpoint' \
        | head -n 1
    )"
  fi

  if [[ -z "${endpoint}" ]]; then
    echo "[ERROR] Could not resolve api_endpoint from API Gateway state or AWS API." >&2
    return 1
  fi

  printf '%s\n' "${endpoint%/}"
}

wait_for_service_health_at_edge() {
  local api_endpoint="$1"
  local context="$2"
  local max_attempts=40
  local interval_seconds=15
  local attempt=1
  local url="${api_endpoint}/health/${context}"
  local fallback_url="${api_endpoint}/api/health/ready"
  local status_code=""

  echo "    -> Probing GET ${url} (timeout: 10 minutes, interval: ${interval_seconds}s)..."

  while (( attempt <= max_attempts )); do
    status_code="$(
      curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${url}" 2>/dev/null || printf '000'
    )"

    # Before C-11 splits gateway routes per context, work-order readiness is exposed at /api/health/ready
    if [[ "${status_code}" == "404" && "${context}" == "work-order" ]]; then
      status_code="$(
        curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${fallback_url}" 2>/dev/null || printf '000'
      )"
    fi

    if [[ "${status_code}" == "200" ]]; then
      echo "       Service '${context}' responded HTTP 200 on attempt ${attempt}/${max_attempts}."
      return 0
    fi

    echo "       Attempt ${attempt}/${max_attempts} for '${context}' returned HTTP ${status_code}; retrying in ${interval_seconds}s..."
    sleep "${interval_seconds}"
    (( attempt++ ))
  done

  echo "[ERROR] Service '${context}' did not respond HTTP 200 at ${url} within 10 minutes." >&2
  return 1
}

verify_edge_health() {
  local api_endpoint="$1"
  echo "==> [Edge Verification] Checking service readiness through API Gateway (${api_endpoint})..."

  local context
  for context in "${EDGE_HEALTH_CONTEXTS[@]}"; do
    if ! is_service_context_active "${context}"; then
      echo "    -> Skipping '/health/${context}' (repository oficina-mecanica-${context}-service is not yet registered in LAYER_3_SERVICES)."
      continue
    fi

    if ! wait_for_service_health_at_edge "${api_endpoint}" "${context}"; then
      return 1
    fi
  done

  echo "==> [Edge Verification] All active service contexts responded HTTP 200."
}

main() {
  require_prerequisites

  local tf_state_bucket
  tf_state_bucket="$(resolve_tf_state_bucket)"
  ensure_state_bucket "${tf_state_bucket}"

  run_layer "Layer 1 - Base Network" "apply" "${LAYER_1_INFRA_BASE[@]}"
  run_layer "Layer 2 - Kubernetes, Messaging & Databases" "apply" "${LAYER_2_DATA_AND_PLATFORM[@]}"
  run_layer "Layer 3 - Microservices" "apply" "${LAYER_3_SERVICES[@]}"
  run_layer "Layer 4 - API Gateway" "apply" "${LAYER_4_GATEWAY[@]}"

  local api_endpoint
  api_endpoint="$(resolve_gateway_endpoint "${tf_state_bucket}")"
  verify_edge_health "${api_endpoint}"

  run_layer "Layer 5 - Serverless Lambdas" "apply" "${LAYER_5_LAMBDAS[@]}"

  echo "==> Setting ENVIRONMENT_ONLINE=true in ${GITHUB_ORG}/${CUSTOM_MONITORING_REPO}..."
  gh variable set ENVIRONMENT_ONLINE \
    --body "true" \
    -R "${GITHUB_ORG}/${CUSTOM_MONITORING_REPO}"

  run_layer "Layer 6 - Custom Monitoring" "apply" "${LAYER_6_MONITORING[@]}"

  echo "==> Environment bootstrap completed successfully. Public API Gateway endpoint: ${api_endpoint}"
}

main "$@"
