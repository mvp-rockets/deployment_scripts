#!/usr/bin/env bash
set -e
version=2.0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

usage()
{
    local envs=($(find ./env/ -type f | sed 's|.*\.||' | sort -u))
    local services=($(jq -c '.services[].name' $PROJECT_DIR/services.json))
    echo "Usage: $(basename $0) environment service --self(optional)"
    echo ""
    echo -e "Available environments are:\e[1;32m ${envs[@]}\e[0m"
    echo -e "And available services are:\e[1;32m ${services[@]}\e[0m. Default is \e[1;32m'all'\e[0m when no second arg is passed"
    echo -e "If --self flag is passed, then it will install locally. In that case arg 1 & 2 become mandatory"
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

if [[ $* == *--self* ]]; then
    self_deployment=true
else
    self_deployment=false
fi

log "project: $(basename $PROJECT_DIR) env: $APP_ENV commit: $GIT_COMMIT services: ${DEPLOY_SERVICES[@]}"

for service in "${DEPLOY_SERVICES[@]}"
do
    export DEPLOY_SERVICE_TYPE=$(jq -c -r --arg n "$service" '.services[] | select(.name == $n) | .type' $PROJECT_DIR/services.json)
    export DEPLOY_SERVICE="$service"

    if [[ $DEPLOY_MODE == "docker" ]];
    then
      $SCRIPT_DIR/deploy-docker.sh
    else
      export DEPLOYMENT_DIR="$ROOT_DEPLOYMENT_DIR/$service/releases/$GIT_COMMIT"

      # Following variables can be used: $SERVER_NAME, $TARGET_GROUP, $TARGET_GROUP_<DEPLOY_SERVICE> (e.g. TARGET_GROUP_API, TARGET_GROUP_BACKEND, ...)
      if [[ -n $TARGET_GROUP ]]; then
        export AWS_EC2_TARGET_GROUP_ARN=$TARGET_GROUP
      elif [[ -z $SERVER_NAME ]]; then
        target_group="TARGET_GROUP_"$(echo "$DEPLOY_SERVICE" | tr '[:lower:]' '[:upper:]')
        if [[ -n ${!target_group} ]]; then
            export AWS_EC2_TARGET_GROUP_ARN=${!target_group}
        fi
      fi

      if [[ $self_deployment == true ]];then
          export REMOTE_TYPE='local'
          unset AWS_EC2_TARGET_GROUP_ARN
          export SERVER_NAME='localhost'
      fi
      log "Deploying $service of type $DEPLOY_SERVICE_TYPE using mode $REMOTE_TYPE"
      $SCRIPT_DIR/deploy-$DEPLOY_SERVICE_TYPE.sh
    fi
done

# end_remote_connection
