#!/usr/bin/env bash
# Runs in the new release directory: rsync ./dist to /var/www/<project>-<env>-<service>,
# without sudo: the server setup creates that directory owned by the deploy user (the
# server template's nginx role does, from nginx_sites), so a missing or unwritable one is
# a configuration error, reported as such.
# shellcheck source-path=SCRIPTDIR/../common
set -Eeo pipefail

set -a
# shellcheck disable=SC1091  # written by the deploy script
source .env.deploy set
set +a

lib=${NAPSES_DEPLOY_LIB:-$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE}
# shellcheck source=events.sh
. "$lib/events.sh"

DESTINATION=${STATIC_ROOT:-/var/www}/$PROJECT_NAME-$APP_ENV-$DEPLOY_SERVICE
deploy_started
trap 'deploy_finished failure stage=sync' ERR
echo "Source: ./dist"
echo "Destination: $DESTINATION"

if [[ ! -d $DESTINATION || ! -w $DESTINATION ]]; then
  trap - ERR
  echo "static: $DESTINATION is missing or not writable by $(id -un). Create it owned by" \
    "$(id -un) in the server setup (server template: add the site to nginx_sites)." >&2
  deploy_finished failure stage=preflight
  exit 1
fi

echo "Syncing files..."
rsync -aq --delete --chmod=D755,F644 "./dist/" "$DESTINATION/"
deploy_finished success
echo "Deployment completed successfully"
