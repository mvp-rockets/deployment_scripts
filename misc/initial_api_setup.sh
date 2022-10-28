#!/usr/bin/env bash
set -e
DEPLOYMENT_DIR=$1
export NODE_ENV=$2
export AWS_SM_ACCESS_KEY_ID=$3
export AWS_SM_SECRET_ACCESS_KEY_ID=$4
export AWS_SM_REGION=$5
export AWS_SM_SECRET_ID=$6
export AWS_SM_API_VERSION=2017-10-17
cd $DEPLOYMENT_DIR
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
nvm use
npm ci --include=dev

echo "build env"
npm run build:env
EXIT_STATUS=$?
if [  "$EXIT_STATUS" -eq "0"  ]
then
    echo "Running migration scripts"
    npm run db:migrate --env=$NODE_ENV
else
    echo "ERROR: Failed to create .env file"
    exit 1
fi




