#!/usr/bin/env bash
set -e
if [ -z "$1" ]
then
    echo "No argument supplied"
    exit 1
fi
export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/env/.env.$1"

if [ $1 == "qa" ];
then
    ssh -i $SCRIPT_DIR/$IDENTITY_FILE $REMOTE_USER@$SERVER_NAME
else
   ssh -i $SCRIPT_DIR/$IDENTITY_FILE $REMOTE_USER@$INSTANCE_ID -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id '$INSTANCE_ID' --profile '$AWS_PROFILE' --region '$AWS_REGION''
fi
