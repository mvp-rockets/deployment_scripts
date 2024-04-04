#!/usr/bin/env bash
set -e
version=2.0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

usage()
{
    local envs=($(find ./env/ -type f | sed 's|.*\.||' | sort -u))
    local services=($(jq -c '.services[].name' $PROJECT_DIR/services.json))
    echo "Usage: $(basename $0) environment service"
    echo ""
    echo -e "Available environments are:\e[1;32m ${envs[@]}\e[0m"
    echo -e "And available services are:\e[1;32m ${services[@]}\e[0m. Default is \e[1;32m'all'\e[0m when no second arg is passed"
    exit 1
}

if [[ -z "$1" && -z "$APP_ENV" ]]
then
    usage
fi

# Config
if [ -n "$1" ]
then
    APP_ENV=$1
    NODE_ENV=$APP_ENV
fi
source "$SCRIPT_DIR/incl.sh"
load_vars "$SCRIPT_DIR/env/.env.$APP_ENV"
export_vars
DEPLOY_SERVICES=("${2:-all}")
if [ ${DEPLOY_SERVICES[0]} != "all" ]
then
    DEPLOY_SERVICE_TYPE=$(jq -c -r --arg n "${DEPLOY_SERVICES[0]}" '.services[] | select(.name == $n) | .type' $PROJECT_DIR/services.json)
    if [ -z $DEPLOY_SERVICE_TYPE ]; then
        error "No deployable service ${DEPLOY_SERVICE[0]} found."
        usage
    fi
else
    # In case of all, deploy all services
    DEPLOY_SERVICES=($(jq -c -r '.services[].name' $PROJECT_DIR/services.json))    
fi

log "project: $(basename $PROJECT_DIR) env: $APP_ENV commit: $GIT_COMMIT services: ${DEPLOY_SERVICES[@]}"

# Ensure that node_modules are present as we need it for get-instances-by-target-group script
primary_prj=$(jq -c -r '.services[] | select(.primary == true).name' $PROJECT_DIR/services.json)
if [[ ! -d "$PROJECT_DIR/$primary_prj/node_modules" ]]; then
    pushd .
    cd "$PROJECT_DIR/$primary_prj"
    nvm use
    npm install --force
    popd
fi

for service in "${DEPLOY_SERVICES[@]}"
do
    export DEPLOY_SERVICE_TYPE=$(jq -c -r --arg n "$service" '.services[] | select(.name == $n) | .type' $PROJECT_DIR/services.json)
    export DEPLOY_SERVICE="$service"
    export DEPLOYMENT_DIR="$ROOT_DEPLOYMENT_DIR/$service/releases/$GIT_COMMIT"

    target_group="TARGET_GROUP_"$(echo "$DEPLOY_SERVICE" | tr '[:lower:]' '[:upper:]')
    if [[ -n ${!target_group} ]]; then
        # TODO: If local / self deployment then ensure we are disabling certain conditions
        export AWS_EC2_TARGET_GROUP_ARN=${!target_group}
        #export REMOTE_TYPE=self
    fi
    log "Deploying $service of type $DEPLOY_SERVICE_TYPE"
    $SCRIPT_DIR/deploy-$DEPLOY_SERVICE_TYPE.sh
done
