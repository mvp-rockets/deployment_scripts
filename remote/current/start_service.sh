#!/usr/bin/env bash
# Runs in the new release directory (deploy-api.sh's step 6): switch `current`, start or
# restart under pm2, then the health gate: if HEALTH_URL doesn't answer 2xx within
# HEALTH_TIMEOUT seconds (default 60), `current` goes back to the previous release, pm2
# reloads it, and the deploy fails. Every outcome is a deploy event.
# shellcheck source-path=SCRIPTDIR/../common
set -Eeo pipefail

set -a
# shellcheck disable=SC1091  # written by the deploy script
source .env.deploy set
set +a

lib=${NAPSES_DEPLOY_LIB:-$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE}
# shellcheck source=events.sh
. "$lib/events.sh"
# shellcheck source=health.sh
. "$lib/health.sh"

SERVICE_DIR="$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE"
cd "$SERVICE_DIR"
previous=$(readlink current 2>/dev/null || true)
trap 'deploy_finished failure stage=start' ERR

echo "creating symbolic link for $GIT_COMMIT"
ln -sfn "$DEPLOYMENT_DIR" "$SERVICE_DIR/current"

echo "starting service $DEPLOY_SERVICE"
cd "$SERVICE_DIR/current"
pm2 startOrRestart deploy.config.json

health=skipped
if [[ -n ${HEALTH_URL:-} ]]; then
  if health_wait "$HEALTH_URL"; then
    health=pass
  else
    trap - ERR
    deploy_event health_check result=failure url="$HEALTH_URL"
    if [[ -n $previous && -d $previous && $previous != "$DEPLOYMENT_DIR" ]]; then
      echo "health check failed: rolling back to $(basename "$previous")" >&2
      ln -sfn "$previous" "$SERVICE_DIR/current"
      (cd "$SERVICE_DIR/current" && pm2 startOrReload deploy.config.json)
      deploy_event rollback to_sha="$(basename "$previous")"
      deploy_finished failure stage=health rolled_back=true
    else
      echo "health check failed; no previous release to roll back to" >&2
      deploy_finished failure stage=health rolled_back=false
    fi
    exit 1
  fi
fi

# pm2 modules (pm2-logrotate, pm2-event-shipper) are never in dump.pm2: count apps only.
running=$(pm2 jlist | jq '[.[] | select(.pm2_env.pmx_module != true)] | length')
saved=$(jq length ~/.pm2/dump.pm2 2>/dev/null || echo 0)
if [ "$running" -ne "$saved" ]; then
  echo "pm2 tasks mismatch. running: $running Saved: $saved."
  echo "Saving pm2 tasks"
  pm2 save
fi
deploy_finished success health="$health"
