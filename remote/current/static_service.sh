#!/usr/bin/env bash
# Runs in the new release directory (deploy-static.sh, after `current` moves to it):
# 1. writes ./dist/version.txt, the build's metadata from .env.deploy (incl.sh's
#    set_version_metadata), so every static site serves it at <path>version.txt;
# 2. rsyncs ./dist to /var/www/<project>-<env>-<service>, without sudo: the server setup
#    creates that directory owned by the deploy user (the server template's nginx role does,
#    from nginx_sites), so a missing or unwritable one is a configuration error, reported as
#    such;
# 3. the health gate, with HEALTH_URL set: a URL ending in /version.txt must show this
#    release's commit, any other must answer 2xx, within HEALTH_TIMEOUT seconds (default 60);
#    on failure the previous release (deployment_history's last other commit) is synced back,
#    `current` with it, and the deploy fails. Every outcome is a deploy event.
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

DESTINATION=${STATIC_ROOT:-/var/www}/$PROJECT_NAME-$APP_ENV-$DEPLOY_SERVICE
SERVICE_DIR=$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE
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

# One key=value per line. Public: no deployer identity (DEPLOY_TRIGGER can be an email).
{
  echo "version=${APP_VERSION:-unknown}"
  echo "tag=${GIT_TAG:-none}"
  echo "commit=${GIT_COMMIT_FULL:-$GIT_COMMIT}"
  echo "commitShort=$GIT_COMMIT"
  echo "branch=${GIT_BRANCH:-unknown}"
  echo "buildId=${BUILD_ID:-unknown}"
  echo "buildTime=${BUILD_TIME:-unknown}"
  echo "deployTime=$(date -u +%FT%TZ)"
  echo "env=$APP_ENV"
  echo "nodeVersion=${BUILD_NODE_VERSION:-unknown}"
} >./dist/version.txt
echo "version.txt: commit=${GIT_COMMIT_FULL:-$GIT_COMMIT} env=$APP_ENV"

echo "Syncing files..."
rsync -aq --delete --chmod=D755,F644 "./dist/" "$DESTINATION/"

health=skipped
if [[ -n ${HEALTH_URL:-} ]]; then
  if health_check_for "$HEALTH_URL" "$GIT_COMMIT"; then
    health=pass
  else
    trap - ERR
    deploy_event health_check result=failure url="$HEALTH_URL"
    previous=$( (grep -vxF "$GIT_COMMIT" "$SERVICE_DIR/deployment_history" 2>/dev/null || true) | tail -n 1)
    if [[ -n $previous && -d $SERVICE_DIR/releases/$previous/dist ]]; then
      echo "health check failed ($HEALTH_URL): rolling back to $previous" >&2
      rsync -aq --delete --chmod=D755,F644 "$SERVICE_DIR/releases/$previous/dist/" "$DESTINATION/"
      ln -sfn "$SERVICE_DIR/releases/$previous" "$SERVICE_DIR/current"
      deploy_event rollback to_sha="$previous"
      deploy_finished failure stage=health rolled_back=true
    else
      echo "health check failed ($HEALTH_URL); no previous release to roll back to" >&2
      deploy_finished failure stage=health rolled_back=false
    fi
    exit 1
  fi
fi
deploy_finished success health="$health"
echo "Deployment completed successfully"
