#!/usr/bin/env bash
set -e
# Config
. "$SCRIPT_DIR/incl.sh"
ssh $KEYARG $REMOTE_USER@$SERVER_NAME "mkdir -p $ROOT_DEPLOYMENT_DIR/api/releases/$GIT_COMMIT"
# Start API deployment
API_PROJECT_FOLDER_NAME=
log "##### Starting api deployment #####"
log "Syncing api"
sync /$API_PROJECT_FOLDER_NAME/ /api/releases/$GIT_COMMIT \
--exclude node_modules --exclude test --exclude logs --exclude deployment-scripts \
--exclude postman \
--exclude codeAnalysis \
--exclude .nyc_output \
--exclude elasticmq

log "syncing .nvmrc file"
sync /.nvmrc /api/releases/$GIT_COMMIT

log "Syncing intial api setup script"
sync "/scripts/misc/initial_api_setup.sh" "/api/releases/$GIT_COMMIT"

log "Generating api deploy config"
generate_start_scripts API api/current index

log "Syncing deploy config"
sync /deploy.config.json "/api/releases/$GIT_COMMIT"

log "Syncing start api"
sync "/scripts/run_scripts/start_api.sh" "/api/releases/$GIT_COMMIT"

log "Syncing log_to_deployment_history"
sync "/scripts/misc/log_to_deployment_history.sh" "/api"

log "Syncing clean up old deployment script"
sync "/scripts/misc/clean_up_old_deployment.sh" "/api"

log "Syncing rollback script"
sync "/scripts/misc/rollback.sh" "/api"

log "Running initial api setup script"
run_remote /api/releases/$GIT_COMMIT "initial_api_setup.sh $ROOT_DEPLOYMENT_DIR/api/releases/$GIT_COMMIT $NODE_ENV $AWS_SM_ACCESS_KEY_ID $AWS_SM_SECRET_ACCESS_KEY_ID $AWS_SM_REGION $AWS_SM_SECRET_ID"

log "Running start api"
run_remote /api/releases/$GIT_COMMIT "start_api.sh $ROOT_DEPLOYMENT_DIR/api $ROOT_DEPLOYMENT_DIR/api/releases/$GIT_COMMIT $GIT_COMMIT"

log "Logging current build no deployment history"
run_remote /api "log_to_deployment_history.sh $ROOT_DEPLOYMENT_DIR/api $GIT_COMMIT"

log "Running clean up old deployments"
run_remote /api "clean_up_old_deployment.sh"

log "##### Deployment Completed for $NODE_ENV #####"

