#!/bin/bash
set -euo pipefail


# Read secrets from environment variables, warn if not set
if [ -z "${ASG:-}" ]; then echo "ERROR: ASG env var not set" >&2; exit 1; fi
if [ -z "${REGION:-}" ]; then echo "ERROR: REGION env var not set" >&2; exit 1; fi
if [ -z "${PROFILE:-}" ]; then echo "ERROR: PROFILE env var not set" >&2; exit 1; fi

# How long to wait between checks (seconds)
SLEEP=10

# Wait for an active EC2 instance in the ASG
while true; do
  INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
    --output text --region "$REGION" --profile "$PROFILE")
  if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
    echo "Found active instance: $INSTANCE_ID"
    break
  fi
  echo "Waiting for active instance in ASG $ASG..."
  sleep $SLEEP
done

# Start SSM session and log in (default: bash shell)
echo "Starting SSM session to $INSTANCE_ID..."
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION" --profile "$PROFILE"
