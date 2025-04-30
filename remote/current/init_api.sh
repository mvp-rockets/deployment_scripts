#!/usr/bin/env bash
set -e

set -a
source .env.deploy set
set +a

if [ -d "$ROOT_DEPLOYMENT_DIR/current/node_modules" ] && [ ! -d "$DEPLOYMENT_DIR/node_modules" ]; then
  echo "Copying node_modules dir"
  cp -r "$ROOT_DEPLOYMENT_DIR/current/node_modules" "$DEPLOYMENT_DIR/node_modules" 
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
if command -v nvm &> /dev/null
then
  nvm use
fi

npm ci --production --silent
# npm ci --include=dev  # next.js uses this

echo "build env"
if [[ -f "$DEPLOYMENT_DIR/tsconfig.json" ]]; then
  npm run load-secrets
  npm run build
  echo "Running migration scripts"
  npm run migration:run --env=$APP_ENV
else  # Our older template
  npm run build:env
  echo "Running migration scripts"
  npm run db:migrate --env=$APP_ENV
  npm run db:seed:all --env=$APP_ENV
fi

#next specific
#npm run build:$APP_ENV
#npm prune --production

#npm run sqs:create:dlq --env=$APP_ENV
#npm run sqs:create --env=$APP_ENV
#npm run sqs:associate:dlq --env=$APP_ENV
