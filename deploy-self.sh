#!/usr/bin/env bash
set -e
# Config
if [ -z "$1" ]
then
    echo "No argument supplied"
    exit 1
fi
TYPE=$2
export Deployment_environment="$1"
echo "Deploying $1 api on localhost"
export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. "$SCRIPT_DIR/env/.env.$1"
export PROJECT_DIR="$SCRIPT_DIR/.."
export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
export DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"
export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"
. "$SCRIPT_DIR/incl-self.sh"
echo "$SCRIPT_DIR/deploy-$TYPE-self.sh"
$SCRIPT_DIR/deploy-$TYPE-self.sh
echo "self deployment done for api on localhost"