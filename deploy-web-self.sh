#!/usr/bin/env bash
set -e
# Init
. "$SCRIPT_DIR/incl-self.sh"
mkdir -p $ROOT_DEPLOYMENT_DIR/{/web/releases/$GIT_COMMIT,/web/cache/.next}
UI_PROJECT_FOLDER_NAME=ui
log "##### Starting Deployment web #####"
cd $PROJECT_DIR/$UI_PROJECT_FOLDER_NAME
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
nvm use
rm -rf .next
rm -rf node_modules/ --force
rm -rf storybook-static/ --force
rm -rf ./public/storybook/ --force
git checkout package-lock.json
npm ci --include=dev

if [[ "$NODE_ENV" == "qa" ]]; then
    log "Building storybook"
    npm run build:storybook
    cp -r ./storybook-static ./public/storybook
fi

log "Building $UI_PROJECT_FOLDER_NAME"
npm run build:$NODE_ENV

log "Syncing web"
sync /$UI_PROJECT_FOLDER_NAME/.next/ /web/releases/$GIT_COMMIT/.next

log "syncing .nvmrc file"
sync /.nvmrc /web/releases/$GIT_COMMIT

log "syncing node_modules"
sync /$UI_PROJECT_FOLDER_NAME/node_modules /web/releases/$GIT_COMMIT

log "syncing public folder"
sync /$UI_PROJECT_FOLDER_NAME/public /web/releases/$GIT_COMMIT

log "syncing package json file"
sync /$UI_PROJECT_FOLDER_NAME/package.json /web/releases/$GIT_COMMIT

log "Generating web deploy config"
generate_web_start_scripts WEB web/current

log "Syncing deploy config"
sync /deploy.config.json "/web/releases/$GIT_COMMIT"

log "Syncing intial web setup script"
sync "/scripts/misc/initial_web_setup.sh" "/web/releases/$GIT_COMMIT"

log "Syncing start web"
sync "/scripts/run_scripts/start_web.sh" "/web/releases/$GIT_COMMIT"

log "Syncing log_to_deployment_history"
sync "/scripts/misc/log_to_deployment_history.sh" "/web"

log "Syncing clean up old deployment script"
sync "/scripts/misc/clean_up_old_deployment.sh" "/web"

log "Syncing rollback script"
sync "/scripts/misc/rollback.sh" "/web"

log "Running initial web setup script"
run_remote /web/releases/$GIT_COMMIT "initial_web_setup.sh $ROOT_DEPLOYMENT_DIR/web/releases/$GIT_COMMIT"

log "Running start web"
run_remote /web/releases/$GIT_COMMIT "start_web.sh $ROOT_DEPLOYMENT_DIR/web $ROOT_DEPLOYMENT_DIR/web/releases/$GIT_COMMIT $NODE_ENV"

log "Logging current build no deployment history"
run_remote /web "log_to_deployment_history.sh $ROOT_DEPLOYMENT_DIR/web $GIT_COMMIT"

log "Running clean up old deployments"
run_remote /web "clean_up_old_deployment.sh"

log "##### Deployment Completed for $NODE_ENV #####"
