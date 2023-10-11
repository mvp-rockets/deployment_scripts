#!/usr/bin/env bash
set -e
DEPLOYMENT_DIR=$1
export NODE_ENV=$2
<exportingCredentials>
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




