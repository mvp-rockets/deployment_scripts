#!/usr/bin/env bash
set -e
# Config
if [ -z "$1" ]
then
    echo "No argument supplied"
    exit 1
fi
TYPE=$2
export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. "$SCRIPT_DIR/env/.env.$1"

export PROJECT_DIR="$SCRIPT_DIR/.."
export IDENTITY_FILE="$SCRIPT_DIR/$IDENTITY_FILE"
export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"

if [[ "$IDENTITY_FILE" != "" ]]; then
    export KEYARG="-i $IDENTITY_FILE"
else
    export KEYARG=
fi

. "$SCRIPT_DIR/incl.sh"

echo $TYPE
if [[ -n "$TYPE" ]]
then
    log "Deploying $TYPE"
    $SCRIPT_DIR/deploy-$TYPE.sh
else
    log "Deploying all aps"
    $SCRIPT_DIR/deploy-api.sh
    $SCRIPT_DIR/deploy-web.sh
fi

