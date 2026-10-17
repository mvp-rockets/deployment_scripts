#!/usr/bin/env bash
# Runs in the new release directory (deploy-api.sh's step 5): node_modules from the
# lockfile-keyed store instead of npm ci (common/nm_store.sh), deploy events
# (common/events.sh), the secret checked against secrets-manifest.json before load-secrets
# (common/secrets_manifest.sh), a cluster-mode app's .nvmrc checked against pm2's Node
# (common/pm2_node.sh).
# shellcheck source-path=SCRIPTDIR/../common
set -Eeo pipefail

set -a
# shellcheck disable=SC1091  # written by the deploy script
source .env.deploy set
set +a

lib=${NAPSES_DEPLOY_LIB:-$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE}
# shellcheck source=events.sh
. "$lib/events.sh"
# shellcheck source=nm_store.sh
. "$lib/nm_store.sh"
# shellcheck source=secrets_manifest.sh
. "$lib/secrets_manifest.sh"
# shellcheck source=pm2_node.sh
. "$lib/pm2_node.sh"

deploy_started
# before nvm use (pm2's Node) and before the install and migrations
if ! pm2_cluster_node_check "$DEPLOYMENT_DIR/deploy.config.json" "$DEPLOYMENT_DIR/.nvmrc"; then
  deploy_finished failure stage=preflight
  exit 1
fi
trap 'deploy_finished failure stage=init' ERR

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command -v nvm &>/dev/null; then
  nvm use
fi

nm_store_install "$DEPLOYMENT_DIR" "$PROJECT_NAME"

echo "build env"
if [[ -f "$DEPLOYMENT_DIR/tsconfig.json" ]]; then
  secrets_check "${SECRETS_MANIFEST:-$DEPLOYMENT_DIR/secrets-manifest.json}" "${DEPLOY_SERVICE##*/}"
  npm run load-secrets
  echo "Running migration scripts"
  npm run migration:run --env="$APP_ENV"
  npm run migration:seed --env="$APP_ENV"
else  # Our older template
  npm run build:env
  echo "Running migration scripts"
  npm run db:migrate --env="$APP_ENV"
  npm run db:seed:all --env="$APP_ENV"
fi
