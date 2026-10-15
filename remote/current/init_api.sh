#!/usr/bin/env bash
# Runs in the new release directory (deploy-api.sh's step 5): node_modules from the
# lockfile-keyed store instead of npm ci (common/nm_store.sh), deploy events
# (common/events.sh), the secret checked against secrets-manifest.json before load-secrets
# (common/secrets_manifest.sh).
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

deploy_started
trap 'deploy_finished failure stage=init' ERR

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command -v nvm &>/dev/null; then
  nvm use
fi

nm_store_install "$DEPLOYMENT_DIR" "$PROJECT_NAME"

check_secrets() {
  local manifest=${SECRETS_MANIFEST:-$DEPLOYMENT_DIR/secrets-manifest.json} secret
  if [[ ! -f $manifest ]]; then
    echo "secrets manifest: none at $manifest (WARNING: not checked)" >&2
    return 0
  fi
  secret=$(mktemp)
  # shellcheck disable=SC2064  # expand now: the path is local
  trap "rm -f '$secret'" RETURN
  secrets_fetch "$secret"
  secrets_manifest_check "$manifest" "$secret" "${DEPLOY_SERVICE##*/}" "$ROOT_DEPLOYMENT_DIR/.secrets-manifest-enforced"
}

echo "build env"
if [[ -f "$DEPLOYMENT_DIR/tsconfig.json" ]]; then
  check_secrets
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
