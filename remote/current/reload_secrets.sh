#!/usr/bin/env bash
# Runs in the live release (`secrets.sh <env> reload`, ADR 0053): the app re-reads its secret
# without a deploy. The secret is checked against the release's secrets-manifest.json
# (common/secrets_manifest.sh), load-secrets rewrites .env and .env.$APP_ENV, pm2 reloads the
# app, then the health gate (common/health.sh). A failure after the check puts the previous
# files back and reloads pm2 on them. Each outcome is a secrets_reload event (common/events.sh;
# `outcome`, not `result`: a reload is not a deploy).
# shellcheck source-path=SCRIPTDIR/../common
set -Eeo pipefail

cd "$(pwd -P)"
set -a
# shellcheck disable=SC1091  # written by the deploy script
source .env.deploy set
set +a

lib=${NAPSES_DEPLOY_LIB:-$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE}
# shellcheck source=events.sh
. "$lib/events.sh"
# shellcheck source=health.sh
. "$lib/health.sh"
# shellcheck source=secrets_manifest.sh
. "$lib/secrets_manifest.sh"

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command -v nvm &>/dev/null; then
  nvm use
fi

if ! secrets_check "${SECRETS_MANIFEST:-$PWD/secrets-manifest.json}" "${DEPLOY_SERVICE##*/}"; then
  deploy_event secrets_reload outcome=failure stage=check
  echo "reload: nothing changed" >&2
  exit 1
fi

files=(.env ".env.$APP_ENV")
backup=$(mktemp -d)
chmod 700 "$backup"
trap 'rm -rf "$backup"' EXIT
for f in "${files[@]}"; do
  if [[ -f $f ]]; then cp -p "$f" "$backup/"; fi
done

failed() {  # failed <stage>: the previous files back, pm2 reloaded on them
  trap - ERR
  set +e
  echo "reload: $1 failed: restoring the previous values" >&2
  for f in "${files[@]}"; do
    if [[ -f $backup/$f ]]; then cp -p "$backup/$f" "$f"; else rm -f "$f"; fi
  done
  pm2 startOrReload deploy.config.json
  deploy_event secrets_reload outcome=failure stage="$1" restored=true
  exit 1
}

trap 'failed load' ERR
if [[ -f tsconfig.json ]]; then
  npm run load-secrets
else  # Our older template
  npm run build:env
fi
trap 'failed reload' ERR
pm2 startOrReload deploy.config.json
trap - ERR

health=skipped
if [[ -n ${HEALTH_URL:-} ]]; then
  if health_wait "$HEALTH_URL"; then
    health=pass
  else
    failed health
  fi
fi
deploy_event secrets_reload outcome=success health="$health"
echo "reload: $DEPLOY_SERVICE reads the secret's current values (health: $health)"
