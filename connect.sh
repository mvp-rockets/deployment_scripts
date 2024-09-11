#!/usr/bin/env bash
set -e
VERSION=2.0
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

usage()
{
    local envs=($(find ./env/ -type f | sed 's|.*\.||' | sort -u))
    local services=($(jq -c '.services[].name' $PROJECT_DIR/services.json))
    echo "usage: $(basename $0) environment service (optional)"
    echo ""
    echo -e "available environments are:\e[1;32m ${envs[@]}\e[0m"
    echo -e "and available services are:\e[1;32m ${services[@]}\e[0m. By default \e[1;32m'SERVER_NAME'\e[0m is used when no second arg is passed"
    exit 1
}

if [[ -z "$1" ]]
then
    usage
fi

if [ -n "$1" ]
then
    APP_ENV=$1
    NODE_ENV=$APP_ENV
fi

source "$SCRIPT_DIR/incl.sh"
load_vars "$SCRIPT_DIR/env/.env.$APP_ENV"
export_vars

# Following variables can be used: $SERVER_NAME, $TARGET_GROUP, $TARGET_GROUP_<DEPLOY_SERVICE> (e.g. TARGET_GROUP_API, TARGET_GROUP_BACKEND, ...)

if [[ -z $SERVER_NAME ]] && [[ -z $TARGET_GROUP && -z "$2" ]]; then
    echo "Server Name or Target Group not defined. Pass the service name that we need to connect to"
    usage
fi

if [[ -n $TARGET_GROUP ]]; then
    TARGET_GROUP_ARN=$TARGET_GROUP
elif [[ -z $SERVER_NAME ]]; then
    target_group="TARGET_GROUP_"$(echo "$2" | tr '[:lower:]' '[:upper:]')
    if [[ -n ${!target_group} ]]; then
        TARGET_GROUP_ARN=${!target_group}
    fi
fi

if [[ -z $SERVER_NAME && -z $TARGET_GROUP_ARN ]]; then
    echo "SERVER_NAME or TARGET_GROUP not defined."
    exit
elif [[ -z $SERVER_NAME && -n $TARGET_GROUP_ARN ]]; then

  # Get the instance IDs from the target group
  INSTANCE_IDS=($(aws elbv2 describe-target-health --target-group-arn $TARGET_GROUP_ARN | jq -r '.TargetHealthDescriptions[].Target.Id'))

  if [ -z "$INSTANCE_IDS" ]; then
      echo "No instances found for the target group ARN: $TARGET_GROUP_ARN"
      exit 1
  fi

  if [ ${#INSTANCE_IDS[@]} -gt 1 ]; then 
    # Display the instances and prompt the user to select one
    echo -e "Instances found in the target group: \e[1;32m ${INSTANCE_IDS[@]}\e[0m"
    PS3="Select the instance you want to SSH into: "
    select INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
        if [ -n "$INSTANCE_ID" ]; then
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
  else 
    INSTANCE_ID=${INSTANCE_IDS[0]}
  fi

  if [ $REMOTE_TYPE != "ec2_instance_connect" ]; then
    # Get the public DNS of the selected instance
    #PUBLIC_DNS=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID | jq -r '.Reservations[].Instances[].PublicDnsName')
    SERVER_NAME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID | jq -r '.Reservations[].Instances[].PublicIpAddress')

    if [ -z "$SERVER_NAME" ]; then
        echo "Public IP not found for instance ID: $INSTANCE_ID"
        exit 1
    fi
  fi

fi

if [ $REMOTE_TYPE == "ssh" ];
then

  ssh_args="$KEYARG -t -o ControlMaster=auto -o ControlPath=~/.ssh/ssh-master-%C -o ControlPersist=60"
  ssh $ssh_args $REMOTE_USER@$SERVER_NAME

elif [ $REMOTE_TYPE == "ec2_instance_connect" ];
then

  ssh $KEYARG -t $REMOTE_USER@$INSTANCE_ID \
    -o ProxyCommand='aws ec2-instance-connect open-tunnel \
    --instance-id '$INSTANCE_ID' --profile '$AWS_PROFILE' \
    --region '$AWS_REGION''

elif [ $REMOTE_TYPE == "teleport" ];
then

  tsh ssh -t $REMOTE_USER@$SERVER_NAME

elif [ $REMOTE_TYPE == "local" ];
then

  eval " $1"

else

    error "Unsupported REMOTE_TYPE = $REMOTE_TYPE"
    exit 1
fi
