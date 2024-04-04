#!/usr/bin/env bash
set -e

set -a
source .env.deploy set
set +a

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

nvm use
npm ci --production --silent

echo "build env"
npm run build:env

echo "Running migration scripts"
npm run db:migrate --env=$APP_ENV
npm run db:seed:all --env=$APP_ENV

#npm run sqs:create:dlq --env=$APP_ENV
#npm run sqs:create --env=$APP_ENV
#npm run sqs:associate:dlq --env=$APP_ENV
