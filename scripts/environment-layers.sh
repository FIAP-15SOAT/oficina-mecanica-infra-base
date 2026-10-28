#!/usr/bin/env bash
# Shared layer definitions and GitHub Actions workflow helpers for
# provisioning (environment-up.sh) and tearing down (environment-down.sh)
# the prod-simulated environment in the AWS Academy Learner Lab.

set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:-FIAP-15SOAT}"
AWS_REGION="${AWS_REGION:-us-east-1}"
INFRA_BASE_REPO="oficina-mecanica-infra-base"
CUSTOM_MONITORING_REPO="oficina-mecanica-custom-monitoring"

# shellcheck disable=SC2034
# Each entry follows the format: "<repo>:<workflow_file>:<accepts_action_input>"
# Layer 1: Base network (VPC, subnets, NAT Gateway, route tables)
LAYER_1_INFRA_BASE=(
  "oficina-mecanica-infra-base:cd.yml:true"
)

# Layer 2: Compute, messaging, and per-service data stores (RDS PostgreSQL 18 + ElastiCache for Valkey 9.1)
LAYER_2_DATA_AND_PLATFORM=(
  "oficina-mecanica-infra-k8s:cd.yml:true"
  "oficina-mecanica-infra-messaging:cd.yml:true"
  "oficina-mecanica-infra-database-work-order:cd.yml:true"
  "oficina-mecanica-infra-database-identity:cd.yml:true"
  "oficina-mecanica-infra-database-billing:cd.yml:true"
  "oficina-mecanica-infra-database-inventory:cd.yml:true"
)

# Layer 3: Microservices CD pipelines (database migrations, seed, and Kubernetes deployment)
# New service repositories are uncommented as their bootstrap changes (C-14, C-17, C-21) land.
LAYER_3_SERVICES=(
  "oficina-mecanica-work-order-service:cd.yml:false"
  # "oficina-mecanica-identity-service:cd.yml:false"
  "oficina-mecanica-billing-service:cd.yml:false"
  # "oficina-mecanica-inventory-service:cd.yml:false"
)

# Layer 4: Edge HTTP API Gateway and VPC Link
LAYER_4_GATEWAY=(
  "oficina-mecanica-api-gateway:cd.yml:true"
)

# Layer 5: Serverless functions (Lambda customer-auth and Lambda notification)
# oficina-mecanica-lambda-notification is uncommented when C-10 lands.
LAYER_5_LAMBDAS=(
  "oficina-mecanica-lambda-customer-auth:cd.yml:true"
  # "oficina-mecanica-lambda-notification:cd.yml:true"
)

# Layer 6: External observability and synthetic monitoring (Datadog)
LAYER_6_MONITORING=(
  "oficina-mecanica-custom-monitoring:cd.yml:false"
)

# Service contexts checked at the public API Gateway edge (/health/<context>)
# after Layer 4 completes and before Layer 5 starts.
EDGE_HEALTH_CONTEXTS=(
  "work-order"
  "identity"
  "billing"
  "inventory"
)

require_prerequisites() {
  local cmd
  for cmd in bash gh jq curl aws; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "[ERROR] Required command '${cmd}' is not installed or not in PATH." >&2
      return 1
    fi
  done

  echo "==> Checking GitHub CLI authentication..."
  if ! gh auth status >/dev/null 2>&1; then
    echo "[ERROR] GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
    return 1
  fi

  echo "==> Checking AWS CLI session credentials..."
  local caller_arn
  if ! caller_arn="$(aws sts get-caller-identity --region "${AWS_REGION}" --query 'Arn' --output text 2>/dev/null)"; then
    echo "[ERROR] AWS CLI credentials are missing or expired. Export valid AWS Academy session credentials first." >&2
    return 1
  fi
  echo "    Authenticated AWS identity: ${caller_arn}"
}

resolve_tf_state_bucket() {
  local bucket
  bucket="$(
    gh api "repos/${GITHUB_ORG}/${INFRA_BASE_REPO}/actions/organization-variables" \
      --jq '.variables[] | select(.name=="TF_STATE_BUCKET") | .value'
  )"

  if [[ -z "${bucket}" ]]; then
    echo "[ERROR] Organization variable TF_STATE_BUCKET was not found via ${GITHUB_ORG}/${INFRA_BASE_REPO}." >&2
    return 1
  fi

  printf '%s\n' "${bucket}"
}

is_service_context_active() {
  local context="$1"
  local target_repo="oficina-mecanica-${context}-service"
  local entry repo
  for entry in "${LAYER_3_SERVICES[@]}"; do
    repo="${entry%%:*}"
    if [[ "${repo}" == "${target_repo}" ]]; then
      return 0
    fi
  done
  return 1
}

trigger_workflow_and_resolve_run_id() {
  local repo="$1"
  local workflow="$2"
  local accepts_action="$3"
  local action="$4"

  local prev_run_id
  prev_run_id="$(
    gh run list \
      -R "${GITHUB_ORG}/${repo}" \
      --workflow "${workflow}" \
      --event workflow_dispatch \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // 0'
  )"

  local triggered_at
  triggered_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ "${accepts_action}" == "true" ]]; then
    gh workflow run "${workflow}" \
      -R "${GITHUB_ORG}/${repo}" \
      --ref main \
      -f "action=${action}" >/dev/null
  else
    gh workflow run "${workflow}" \
      -R "${GITHUB_ORG}/${repo}" \
      --ref main >/dev/null
  fi

  local attempt=1
  local max_attempts=30
  local run_id=""

  while (( attempt <= max_attempts )); do
    run_id="$(
      gh run list \
        -R "${GITHUB_ORG}/${repo}" \
        --workflow "${workflow}" \
        --event workflow_dispatch \
        --limit 5 \
        --json databaseId,createdAt \
        --jq "
          [.[] | select((.databaseId > ${prev_run_id}) or (.createdAt >= \"${triggered_at}\"))]
          | sort_by(.databaseId)
          | last
          | .databaseId // empty
        "
    )"

    if [[ -n "${run_id}" ]]; then
      printf '%s\n' "${run_id}"
      return 0
    fi

    sleep 2
    (( attempt++ ))
  done

  echo "[ERROR] Timed out waiting for workflow_dispatch run of ${workflow} in ${GITHUB_ORG}/${repo} (triggered at ${triggered_at})." >&2
  return 1
}

run_layer() {
  local layer_label="$1"
  local action="$2"
  shift 2
  local entries=("$@")

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "==> [${layer_label}] No repositories configured in this layer; skipping."
    return 0
  fi

  echo "==> [${layer_label}] Dispatching ${#entries[@]} workflow(s) (action=${action})..."

  local repos=()
  local workflows=()
  local run_ids=()
  local entry rest repo workflow accepts_action run_id

  for entry in "${entries[@]}"; do
    repo="${entry%%:*}"
    rest="${entry#*:}"
    workflow="${rest%%:*}"
    accepts_action="${rest#*:}"

    echo "    -> Triggering ${GITHUB_ORG}/${repo} (${workflow}, accepts_action=${accepts_action})..."
    if ! run_id="$(trigger_workflow_and_resolve_run_id "${repo}" "${workflow}" "${accepts_action}" "${action}")"; then
      return 1
    fi

    echo "       Dispatched run #${run_id} in ${GITHUB_ORG}/${repo}"
    repos+=("${repo}")
    workflows+=("${workflow}")
    run_ids+=("${run_id}")
  done

  local i run_url
  for i in "${!repos[@]}"; do
    repo="${repos[$i]}"
    workflow="${workflows[$i]}"
    run_id="${run_ids[$i]}"

    echo "    -> Waiting for ${GITHUB_ORG}/${repo} run #${run_id}..."
    if ! gh run watch "${run_id}" -R "${GITHUB_ORG}/${repo}" --exit-status >/dev/null; then
      run_url="$(
        gh run view "${run_id}" \
          -R "${GITHUB_ORG}/${repo}" \
          --json url \
          --jq '.url // empty' 2>/dev/null || true
      )"
      if [[ -z "${run_url}" ]]; then
        run_url="https://github.com/${GITHUB_ORG}/${repo}/actions/runs/${run_id}"
      fi
      echo "[ERROR] Workflow ${workflow} failed in ${GITHUB_ORG}/${repo}: ${run_url}" >&2
      return 1
    fi
    echo "       Completed ${GITHUB_ORG}/${repo} run #${run_id} successfully."
  done

  echo "==> [${layer_label}] Layer completed successfully."
}
