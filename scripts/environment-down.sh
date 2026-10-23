#!/usr/bin/env bash
# Tears down the prod-simulated environment in reverse dependency order (§22):
#   1. Layer 6: Set ENVIRONMENT_ONLINE=false and run custom-monitoring CD (pauses synthetics)
#   2. Layer 5: Destroy Serverless Lambdas in parallel (action=destroy)
#   3. Layer 4: Destroy API Gateway (action=destroy)
#   4. Layer 2: Destroy Kubernetes, Messaging, and 4 Databases in parallel (action=destroy)
#   5. Layer 1: Destroy infra-base with retry every 5 min for up to 30 min while ENIs detach
#   6. Final AWS audit: verify no billable or project resources remain (except TF_STATE_BUCKET)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/environment-layers.sh
source "${SCRIPT_DIR}/environment-layers.sh"

destroy_infra_base_with_retries() {
  local max_attempts=7
  local retry_delay_seconds=300
  local attempt=1

  while true; do
    echo "==> [Layer 1 - Base Network] Destroying infra-base (attempt ${attempt}/${max_attempts})..."
    if run_layer "Layer 1 - Base Network" "destroy" "${LAYER_1_INFRA_BASE[@]}"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      echo "[ERROR] Layer 1 (infra-base) destroy failed after ${max_attempts} attempts (30 minutes)." >&2
      return 1
    fi

    echo "[WARN] Layer 1 destroy failed (ENIs from VPC Link or VPC Lambdas may still be detaching). Waiting 5 minutes before retry..." >&2
    sleep "${retry_delay_seconds}"
    (( attempt++ ))
  done
}

verify_no_leftover_resources() {
  echo "==> [Final Verification] Checking AWS account for leftover project resources in ${AWS_REGION}..."
  local leftovers_found=0

  local eks_clusters
  eks_clusters="$(
    aws eks list-clusters --region "${AWS_REGION}" --output json \
      | jq -r '.clusters[]? | select(test("oficina-mecanica"))'
  )"
  if [[ -n "${eks_clusters}" ]]; then
    echo "[LEFTOVER] EKS clusters still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${eks_clusters}"
    leftovers_found=1
  fi

  local nat_gateways
  nat_gateways="$(
    aws ec2 describe-nat-gateways \
      --region "${AWS_REGION}" \
      --filter "Name=state,Values=available,pending,deleting" \
      --output json \
      | jq -r '
          .NatGateways[]?
          | select(
              .State == "available"
              and (
                any(.Tags[]?; (.Key == "Project" and .Value == "oficina-mecanica") or (.Key == "Name" and (.Value | test("oficina-mecanica"))))
              )
            )
          | "\(.NatGatewayId) (\(.State))"
        '
  )"
  if [[ -n "${nat_gateways}" ]]; then
    echo "[LEFTOVER] Available NAT Gateways still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${nat_gateways}"
    leftovers_found=1
  fi

  local rds_instances
  rds_instances="$(
    aws rds describe-db-instances --region "${AWS_REGION}" --output json \
      | jq -r '.DBInstances[]? | select(.DBInstanceIdentifier | test("oficina-mecanica")) | "\(.DBInstanceIdentifier) (\(.DBInstanceStatus))"'
  )"
  if [[ -n "${rds_instances}" ]]; then
    echo "[LEFTOVER] RDS DB instances still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${rds_instances}"
    leftovers_found=1
  fi

  local elasticache_groups
  elasticache_groups="$(
    aws elasticache describe-replication-groups --region "${AWS_REGION}" --output json \
      | jq -r '.ReplicationGroups[]? | select(.ReplicationGroupId | test("oficina-mecanica")) | "\(.ReplicationGroupId) (\(.Status))"'
  )"
  if [[ -n "${elasticache_groups}" ]]; then
    echo "[LEFTOVER] ElastiCache replication groups still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${elasticache_groups}"
    leftovers_found=1
  fi

  local vpc_links
  vpc_links="$(
    aws apigatewayv2 get-vpc-links --region "${AWS_REGION}" --output json \
      | jq -r '.Items[]? | select(.Name | test("oficina-mecanica")) | "\(.Name) (\(.VpcLinkId) - \(.VpcLinkStatus))"'
  )"
  if [[ -n "${vpc_links}" ]]; then
    echo "[LEFTOVER] API Gateway VPC Links still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${vpc_links}"
    leftovers_found=1
  fi

  local lambda_functions
  lambda_functions="$(
    aws lambda list-functions --region "${AWS_REGION}" --output json \
      | jq -r '.Functions[]? | select(.FunctionName | test("oficina-mecanica")) | .FunctionName'
  )"
  if [[ -n "${lambda_functions}" ]]; then
    echo "[LEFTOVER] Lambda functions still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${lambda_functions}"
    leftovers_found=1
  fi

  local sqs_queues
  sqs_queues="$(
    aws sqs list-queues --region "${AWS_REGION}" --output json \
      | jq -r '.QueueUrls[]? | select(test("oficina-mecanica"))'
  )"
  if [[ -n "${sqs_queues}" ]]; then
    echo "[LEFTOVER] SQS queues still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${sqs_queues}"
    leftovers_found=1
  fi

  local sns_topics
  sns_topics="$(
    aws sns list-topics --region "${AWS_REGION}" --output json \
      | jq -r '.Topics[]?.TopicArn | select(test("oficina-mecanica"))'
  )"
  if [[ -n "${sns_topics}" ]]; then
    echo "[LEFTOVER] SNS topics still present:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "  - ${line}" >&2
    done <<< "${sns_topics}"
    leftovers_found=1
  fi

  if (( leftovers_found != 0 )); then
    echo "[ERROR] Teardown verification failed: one or more project resources remain in AWS." >&2
    return 1
  fi

  echo "==> [Final Verification] Confirmed: zero project resources remain in AWS (S3 state bucket preserved)."
}

main() {
  require_prerequisites

  echo "==> Setting ENVIRONMENT_ONLINE=false in ${GITHUB_ORG}/${CUSTOM_MONITORING_REPO}..."
  gh variable set ENVIRONMENT_ONLINE \
    --body "false" \
    -R "${GITHUB_ORG}/${CUSTOM_MONITORING_REPO}"

  run_layer "Layer 6 - Custom Monitoring (Offline Mode)" "apply" "${LAYER_6_MONITORING[@]}"
  run_layer "Layer 5 - Serverless Lambdas" "destroy" "${LAYER_5_LAMBDAS[@]}"
  run_layer "Layer 4 - API Gateway" "destroy" "${LAYER_4_GATEWAY[@]}"
  run_layer "Layer 2 - Kubernetes, Messaging & Databases" "destroy" "${LAYER_2_DATA_AND_PLATFORM[@]}"

  destroy_infra_base_with_retries
  verify_no_leftover_resources

  echo "==> Environment teardown completed successfully."
}

main "$@"
