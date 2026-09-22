#!/usr/bin/env bash
set -e
VERSION=1.0
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

usage()
{
    local envs=($(find $SCRIPT_DIR/env/ -type f | sed 's|.*\.||' | sort -u))
    echo "usage: $(basename $0) environment [local_port]"
    echo ""
    echo -e "available environments are:\e[1;32m ${envs[@]}\e[0m"
    echo ""
    echo "Sets up a local proxy (via the environment's REMOTE_TYPE) to the RDS/Aurora"
    echo "postgres instance (DB_HOST:DB_PORT) defined in the environment's env file,"
    echo "since it sits in a private subnet and isn't reachable directly."
    echo ""
    echo "local_port: port to bind the proxy on. If it's already taken, the next"
    echo "free port is used instead and printed. Defaults to \$LOCAL_DB_PORT or DB_PORT."
    exit 1
}

if [[ -z "$1" ]]
then
    usage
fi

APP_ENV=$1
NODE_ENV=$APP_ENV

source "$SCRIPT_DIR/incl.sh"
load_vars "$SCRIPT_DIR/env/.env.$APP_ENV"
export_vars

awsp

if [[ -z "$DB_HOST" ]]; then
    error "DB_HOST not defined in env/.env.$APP_ENV. Set it to the RDS/Aurora endpoint."
    exit 1
fi

DB_PORT="${DB_PORT:-5432}"

# Resolve which instance/server to tunnel through
if [[ -z $SERVER_NAME ]] && [[ -z $TARGET_GROUP ]] && [[ -z $INSTANCE_ID ]]; then
    error "SERVER_NAME, TARGET_GROUP or INSTANCE_ID must be defined to locate a host with network access to the DB"
    usage
fi

if [[ -n $TARGET_GROUP ]]; then
    TARGET_GROUP_ARN=$TARGET_GROUP
fi

if [[ -n $TARGET_GROUP_ARN ]]; then
    INSTANCE_IDS=($(aws elbv2 describe-target-health --target-group-arn $TARGET_GROUP_ARN | jq -r '.TargetHealthDescriptions[].Target.Id'))

    if [ -z "$INSTANCE_IDS" ]; then
        error "No instances found for the target group ARN: $TARGET_GROUP_ARN"
        exit 1
    fi

    if [ ${#INSTANCE_IDS[@]} -gt 1 ]; then
        echo -e "Instances found in the target group: \e[1;32m ${INSTANCE_IDS[@]}\e[0m"
        PS3="Select the instance you want to tunnel through: "
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
fi

if [[ $REMOTE_TYPE != "ec2_instance_connect" && $REMOTE_TYPE != "aws_session_manager" && -z $SERVER_NAME ]]; then
    SERVER_NAME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID | jq -r '.Reservations[].Instances[].PublicIpAddress')

    if [ -z "$SERVER_NAME" ]; then
        error "Public IP not found for instance ID: $INSTANCE_ID"
        exit 1
    fi
fi

# Finds the first free local TCP port starting at $1
find_free_port()
{
    local port=$1
    while (echo > /dev/tcp/127.0.0.1/$port) &> /dev/null; do
        port=$((port + 1))
    done
    echo $port
}

REQUESTED_PORT="${2:-${LOCAL_DB_PORT:-$DB_PORT}}"
LOCAL_PORT=$(find_free_port "$REQUESTED_PORT")

if [[ "$LOCAL_PORT" != "$REQUESTED_PORT" ]]; then
    log "Port $REQUESTED_PORT is already in use, using $LOCAL_PORT instead"
fi

log "Local port: $LOCAL_PORT"
echo -e "Connect using: \e[1;32mpsql -h localhost -p $LOCAL_PORT -U <user> -d <database>\e[0m"
log "Setting up proxy to $DB_HOST:$DB_PORT (Ctrl+C to stop)..."

if [ $REMOTE_TYPE == "ssh" ];
then

    ssh $KEYARG -N -L $LOCAL_PORT:$DB_HOST:$DB_PORT $REMOTE_USER@$SERVER_NAME

elif [ $REMOTE_TYPE == "ec2_instance_connect" ];
then

    ssh $KEYARG -N -L $LOCAL_PORT:$DB_HOST:$DB_PORT $REMOTE_USER@$INSTANCE_ID \
      -o ProxyCommand='aws ec2-instance-connect open-tunnel \
      --instance-id '$INSTANCE_ID' --profile '$AWS_PROFILE' \
      --region '$AWS_REGION''

elif [ $REMOTE_TYPE == "aws_session_manager" ];
then

    ssh $KEYARG -N -L $LOCAL_PORT:$DB_HOST:$DB_PORT $REMOTE_USER@$INSTANCE_ID \
      -o ProxyCommand='aws ssm start-session \
      --target '$INSTANCE_ID' --document-name AWS-StartSSHSession \
      --parameters portNumber=%p --profile '$AWS_PROFILE' \
      --region '$AWS_REGION''

    aws ssm start-session --profile $AWS_PROFILE --target $INSTANCE_ID \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "host=$DB_HOST,portNumber=$DB_PORT,localPortNumber=$LOCAL_PORT" 

else

    error "Unsupported REMOTE_TYPE = $REMOTE_TYPE for db-connect"
    exit 1
fi
