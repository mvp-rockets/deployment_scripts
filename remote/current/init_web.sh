#!/usr/bin/env bash
# Runs in the new release directory. node_modules from the lockfile-keyed store with dev
# dependencies (next.js builds need them) instead of npm ci (common/nm_store.sh); deploy
# events (common/events.sh).
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

deploy_started
trap 'deploy_finished failure stage=init' ERR

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command -v nvm &>/dev/null; then
  nvm use
fi

NM_INSTALL_FLAGS="--include=dev" nm_store_install "$DEPLOYMENT_DIR" "$PROJECT_NAME"
