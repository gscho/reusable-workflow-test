#!/bin/bash

set -e

export AWS_PAGER=""

REPO_NAME=$(basename "${GITHUB_REPOSITORY}")
DEPLOY_ID="${GITHUB_REF_NAME}-${REPO_NAME}"
CLUSTER_NAME="${DEPLOY_ID}-cluster"
SERVICE_NAME="${DEPLOY_ID}-web-service"
ECS_SUBNET_ID="subnet-0964d46f30718aa4d"
ECS_SG_NAME="${DEPLOY_ID}-ecs-sg"
DEFAULT_TAGS="key=DEPLOY_ID,value=${DEPLOY_ID}"

function emit() {
  local __MESSAGE="${1}"
  # shellcheck disable=SC2155
  local __TIMESTAMP="$( date '+%Y-%m-%d %H:%M:%S.%s%z' )"
  printf "%s - %s - %s\n" "${__TIMESTAMP}" "INFO" "${__MESSAGE}"
}

function create-security-group() {
    set +e
    ECS_SG_JSON=$(aws ec2 describe-security-groups \
                    --group-name "${ECS_SG_NAME}" 2>/dev/null)
    set -e
    if [ -z "${ECS_SG_JSON}" ]; then
      emit "create security group: ${ECS_SG_NAME}"
      ECS_SG_ID=$(aws ec2 create-security-group \
                      --group-name "${ECS_SG_NAME}" \
                      --description "Allow all inbound HTTPS traffic" | jq -r '.GroupId')
      set-security-group-rules
    else
      emit "security group exists: ${ECS_SG_NAME}"
      emit "skipping create security group"
      ECS_SG_ID=$(echo "${ECS_SG_JSON}" | jq -r '.SecurityGroups[0].GroupId')
    fi
}

function set-security-group-rules() {
  emit "adding ingress rules to security group: ${ECS_SG_NAME}"
  aws ec2 authorize-security-group-ingress \
      --group-id "${ECS_SG_ID}" \
      --protocol tcp \
      --port 80 \
      --cidr "0.0.0.0/0"

  emit "adding egress rules to security group: ${ECS_SG_NAME}"
  aws ec2 authorize-security-group-egress \
      --group-id "${ECS_SG_ID}" \
      --ip-permissions IpProtocol=tcp,FromPort=0,ToPort=65535,IpRanges='[{CidrIp=0.0.0.0/0}]'
}

function create-cluster() {
    DESC_CLUSTERS=$(aws ecs describe-clusters \
                        --clusters "${CLUSTER_NAME}" | jq -r '.clusters[] | select(.status=="ACTIVE")')
    if [ -z "${DESC_CLUSTERS}" ]; then
      emit "create cluster: ${CLUSTER_NAME}"
      aws ecs create-cluster \
        --cluster-name "${CLUSTER_NAME}" \
        --tags ${DEFAULT_TAGS}
    else
      emit "cluster exists: ${ECS_SG_NAME}"
      emit "skipping create cluster"
    fi
}

function render-task-def() {
  emit "rendering task definition for docker image: ${DOCKER_IMAGE}"
  jq ".containerDefinitions[0].image = \"${DOCKER_IMAGE}\"" tasks/web-server.json.tmpl > tasks/web-server.json
}

function register-task-def() {
  render-task-def
  aws ecs register-task-definition \
      --cli-input-json file://tasks/web-server.json
  LATEST_TASK_DEF=$(aws ecs list-task-definitions | jq -r '.taskDefinitionArns[-1]' | xargs basename)
  emit "registered task definition revision: ${LATEST_TASK_DEF}"
}

function create-or-update-service() {
  DESC_SERVICES=$(aws ecs describe-services \
                      --cluster "${CLUSTER_NAME}" \
                      --services "${SERVICE_NAME}" | jq -r '.services[] | select(.status=="ACTIVE")')
  if [ -z "${DESC_SERVICES}" ]; then
    emit "creating service: ${SERVICE_NAME}"
    aws ecs create-service \
        --cluster "${CLUSTER_NAME}" \
        --service-name "${SERVICE_NAME}" \
        --task-definition "${LATEST_TASK_DEF}" \
        --desired-count 1 \
        --launch-type "FARGATE" \
        --network-configuration "awsvpcConfiguration={subnets=[${ECS_SUBNET_ID}],securityGroups=[${ECS_SG_ID}],assignPublicIp=ENABLED}"
  else
    emit "service exists: ${SERVICE_NAME}"
    emit "updating service"
    aws ecs update-service \
        --cluster "${CLUSTER_NAME}" \
        --service "${SERVICE_NAME}" \
        --task-definition "${LATEST_TASK_DEF}" \
        --desired-count 1
  fi

  sleep 30

  SERVICE_TASK_ARN=$(aws ecs list-tasks \
                         --cluster "${CLUSTER_NAME}" \
                         --service "${SERVICE_NAME}" | jq -r '.taskArns[-1]')
}

function write-public-ip-to-file() {
  emit "fetching network interface for service task: ${SERVICE_TASK_ARN}"
  ENI_ID=$(aws ecs describe-tasks \
               --cluster "${CLUSTER_NAME}" \
               --tasks "${SERVICE_TASK_ARN}" | jq -r '.tasks[0].attachments[0].details[1] | select(.name=="networkInterfaceId").value')

  PUBLIC_IP=$(aws ec2 describe-network-interfaces \
                  --network-interface-id "${ENI_ID}" | jq -r '.NetworkInterfaces[0].Association.PublicIp')
  echo "http://${PUBLIC_IP}" > url.txt
  emit "application url: http://${PUBLIC_IP}"
}

function main() {
  create-security-group
  create-cluster
  register-task-def
  create-or-update-service
  write-public-ip-to-file
}

main "$@"