#!/bin/bash
set -e

# Check if AWS_EC2_TARGET_GROUP_ARN is set
if [ -z "$AWS_EC2_TARGET_GROUP_ARN" ]; then
  echo "Missing AWS_EC2_TARGET_GROUP_ARN"
  exit 1
fi

# Determine the mode
mode="instance"
if [ "$1" == "ip" ]; then
  mode="ip"
fi

# Special case for vagrant environment
if [ "$APP_ENV" == "vagrant" ]; then
  echo "192.168.56.20"
  echo "192.168.56.30"
  exit 0
fi

# Fetch target health descriptions
target_health=$(aws elbv2 describe-target-health --target-group-arn "$AWS_EC2_TARGET_GROUP_ARN" --output json)

# Extract instance IDs
instance_ids=($(echo "$target_health" | jq -r '.TargetHealthDescriptions[].Target.Id'))

if [ ${#instance_ids[@]} -eq 0 ]; then
  echo "No TargetGroups found"
  exit 1
fi

# Describe instances
instance_details=$(aws ec2 describe-instances --instance-ids "${instance_ids[@]}" --output json)

# Extract and print either instance IDs or public IP addresses
count=0
for reservation in $(echo "$instance_details" | jq -c '.Reservations[]'); do
  for instance in $(echo "$reservation" | jq -c '.Instances[]'); do
    if [ "$mode" == "instance" ]; then
      val=$(echo "$instance" | jq -r '.InstanceId')
    else
      val=$(echo "$instance" | jq -r '.PublicIpAddress')
    fi

    if [ "$val" != "null" ]; then
      echo "$val"
      count=$((count+1))
    fi
  done
done

if [ "$count" -eq 0 ]; then
  echo "No instances found mapped to TargetGroups"
  exit 1
fi

