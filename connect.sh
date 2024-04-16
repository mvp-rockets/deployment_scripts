#!/usr/bin/env bash
set -e
VERSION=2.0

if [ -z "$1" ]
then
    echo "No argument supplied"
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

if [ -n "$1" ]
then
    APP_ENV=$1
    NODE_ENV=$APP_ENV
fi

source "$SCRIPT_DIR/incl.sh"
load_vars "$SCRIPT_DIR/env/.env.$APP_ENV"
export_vars

# TODO: Handle multiple servers

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
