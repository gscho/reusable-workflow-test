#!/bin/bash

set -e

export AWS_PAGER=""

CLUSTER_NAME="${GITHUB_REF_NAME}-cluster"
SERVICE_NAME="${GITHUB_REF_NAME}-web-service"
ECS_SUBNET_ID="subnet-0964d46f30718aa4d"
ECS_SG_NAME="${GITHUB_REF_NAME}-ecs-sg"

function create-security-group() {
    ECS_SG_JSON=$(aws ec2 describe-security-groups \
                    --group-name "${ECS_SG_NAME}")

    if [ -z "${ECS_SG_JSON}" ]; then
      ECS_SG_ID=$(aws ec2 create-security-group \
                      --group-name "${ECS_SG_NAME}" \
                      --description "Allow all inbound HTTPS traffic" | jq -r '.GroupId')
      set-security-group-rules
    else
      ECS_SG_ID=$(echo "${ECS_SG_JSON}" | jq -r '.SecurityGroups[0].GroupId')
    fi
}

function set-security-group-rules() {
  aws ec2 authorize-security-group-ingress \
      --group-id "${ECS_SG_ID}" \
      --protocol tcp \
      --port 80 \
      --cidr "0.0.0.0/0"

  aws ec2 authorize-security-group-egress \
      --group-id "${ECS_SG_ID}" \
      --ip-permissions IpProtocol=tcp,FromPort=0,ToPort=65535,IpRanges='[{CidrIp=0.0.0.0/0}]'
}

function create-cluster() {
    DESC_CLUSTERS=$(aws ecs describe-clusters \
                        --clusters "${CLUSTER_NAME}" | jq -r '.clusters[0].clusterArn')
    if [ ${DESC_CLUSTERS} == "null" ]; then
      aws ecs create-cluster \
        --cluster-name "${CLUSTER_NAME}"
    fi
}

function render-task-def() {
  jq '.containerDefinitions[0].image = "public.ecr.aws/docker/library/httpd:latest"' tasks/web-server.json.tmpl > tasks/web-server.json
}

function register-task-def() {
  render-task-def
  aws ecs register-task-definition \
      --cli-input-json file://tasks/web-server.json
  LATEST_TASK_DEF=$(aws ecs list-task-definitions | jq -r '.taskDefinitionArns[-1]' | xargs basename)
}

function create-or-update-service() {
  DESC_SERVICES=$(aws ecs describe-services \
                      --cluster-name "${CLUSTER_NAME}" \
                      --services ${SERVICE_NAME} | jq -r '.services[0].serviceArn')
  if [ ${DESC_CLUSTERS} == "null" ]; then
    aws ecs create-service \
        --cluster "${CLUSTER_NAME}" \
        --service-name "${SERVICE_NAME}" \
        --task-definition "${LATEST_TASK_DEF}" \
        --desired-count 1 \
        --launch-type "FARGATE" \
        --network-configuration "awsvpcConfiguration={subnets=[${ECS_SUBNET_ID}],securityGroups=[${ECS_SG_ID}],assignPublicIp=ENABLED}"
  else
    aws ecs update-service \
        --cluster "${CLUSTER_NAME}" \
        --service "${SERVICE_NAME}" \
        --task-definition "${LATEST_TASK_DEF}" \
        --desired-count 1
  fi
  SERVICE_TASK_ARN=$(aws ecs list-tasks \
                         --cluster "${CLUSTER_NAME}" \
                         --service ${SERVICE_NAME} | jq -r '.taskArns[-1]')
}

function write-public-ip-to-file() {
  ENI_ID=$(aws ecs describe-tasks \
               --cluster "${CLUSTER_NAME}" \
               --tasks "${SERVICE_TASK_ARN}" | jq -r '.tasks[0].attachments[0].details[1] | select(.name=="networkInterfaceId").value')

  PUBLIC_IP=$(aws ec2 describe-network-interfaces \
                  --network-interface-id "${ENI_ID}" | jq -r '.NetworkInterfaces[0].Association.PublicIp')
  echo "http://${PUBLIC_IP}" > url.txt
}

function main() {
    create-security-group
    create-cluster
    register-task-def
    create-or-update-service
    write-public-ip-to-file
}

main "$@"