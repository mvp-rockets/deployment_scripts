#!/usr/bin/env bash
set -e
version=2.0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)
source "$SCRIPT_DIR/incl.sh"

usage()
{
    local services=($(jq -c '.services[].name' $PROJECT_DIR/services.json))
    echo "Usage: $(basename $0) service"
    echo "Where available services are: ${services[@]}. Default 'all' when no second arg is passed"
    exit 1
}

# Config
DEPLOY_SERVICES=("${2:-all}")
if [ ${DEPLOY_SERVICES[0]} != "all" ]
then
    DEPLOY_SERVICE_TYPE=($(jq -c -r --arg n "${DEPLOY_SERVICES[0]}" '.services[] | select(.name == $n) | .type' $PROJECT_DIR/services.json))
    if [ -z $DEPLOY_SERVICE_TYPE ]; then
        error "No deployable service ${DEPLOY_SERVICE[0]} found."
        usage
    fi
else
    # In case of all, deploy all services
    DEPLOY_SERVICES=($(jq -c -r '.services[].name' $PROJECT_DIR/services.json))    
fi

cd "$PROJECT_DIR"

for service in "${DEPLOY_SERVICES[@]}"
do
    export DEPLOY_SERVICE_TYPE=($(jq -c -r --arg n "$service" '.services[] | select(.name == $n) | .type' $PROJECT_DIR/services.json))
    export DEPLOY_SERVICE="$service"
    log "Cleaning up service $DEPLOY_SERVICE_TYPE of type $service"
    cd "$service"
   
    rm -rf node_modules/ --force
    git checkout package-lock.json    
   
    if [ $DEPLOY_SERVICE_TYPE == "web" ];
    then
        rm -rf .next
        rm -rf storybook-static/ --force
        rm -rf ./public/storybook/ --force
    fi

    cd ..
done
