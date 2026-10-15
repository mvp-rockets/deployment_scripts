#!/usr/bin/env bash
set -e
# 1. Prepare for build
# 2. Build vite
# 3. Make sure the remote directory structure is present
# 4. Sync dist
# 5. Flip current symlink
# 6. Update remote history log
# 7. Clean up older deployments

# Init
source "$SCRIPT_DIR/incl.sh"
deployment_path="/$DEPLOY_SERVICE/releases/$GIT_COMMIT"

log "$(basename $PROJECT_DIR) $APP_ENV $GIT_COMMIT $DEPLOY_SERVICE"


cp "$SCRIPT_DIR/env/.env.$APP_ENV" "/$SCRIPT_DIR/remote/current/.env.deploy" 
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set GIT_COMMIT="$GIT_COMMIT"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOY_SERVICE_TYPE="$DEPLOY_SERVICE_TYPE"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set ROOT_DEPLOYMENT_DIR="$ROOT_DEPLOYMENT_DIR"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOYMENT_DIR="$DEPLOYMENT_DIR"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOY_SERVICE="$DEPLOY_SERVICE"
set_deploy_metadata "/$SCRIPT_DIR/remote/current/.env.deploy"

# 1. Prepare for build
cd "$PROJECT_DIR/$DEPLOY_SERVICE"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command -v nvm &> /dev/null
then
  nvm use
fi

rm -rf dist
rm -rf node_modules/ --force
npm ci --include=dev

# 2. Build vite
log "Building $DEPLOY_SERVICE"
npm run build --env=$APP_ENV
npm prune --production

## Start of loop
if [[ -n $AWS_EC2_TARGET_GROUP_ARN ]]; then
    arg='instance'
    if [ $REMOTE_TYPE != "ec2_instance_connect" ]; then
        arg="ip"
    fi
    servers=( $("$SCRIPT_DIR/get-instance-4-target-group.sh" $arg ) )
else
    servers=( $SERVER_NAME )
fi

for host in "${servers[@]}"
do
    if [ $REMOTE_TYPE == "ec2_instance_connect" ]; then
        export INSTANCE_ID=$host
        host_type="private"
    else
        export SERVER_NAME=$host
        host_type="public"
    fi

    log "Deploying $DEPLOY_SERVICE_TYPE:$DEPLOY_SERVICE on $host ($host_type)"

    # 3. Make sure the remote directory structure is present
    log "Making sure following dir is present: $DEPLOYMENT_DIR "
    sync_remote_folder_structure "$DEPLOYMENT_DIR"

    # 4. Sync dist
    log "Syncing $DEPLOY_SERVICE"
    sync "/$DEPLOY_SERVICE/dist" "$deployment_path"
    sync "/scripts/remote/current/static_service.sh" "$deployment_path/"
    sync "/scripts/remote/current/.env.deploy" "$deployment_path/"
    
    # sync files to the root_deployment_dir
    sync "/scripts/remote/common/*" "/$DEPLOY_SERVICE/"

    # 5. Flip current symlink
    exec_remote "ln -sfn $ROOT_DEPLOYMENT_DIR$deployment_path $ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE/current"
   
    # SPA — deploy as static files
    run_remote "$deployment_path" "static_service.sh"

    # 6. Update remote history log
    log "Logging current build to deployment history"
    run_remote "/$DEPLOY_SERVICE" "log_to_deployment_history.sh $GIT_COMMIT"

    # 7. Clean up older deployments
    log "Cleaning up old deployments"
    run_remote "/$DEPLOY_SERVICE" "clean_up_old_deployment.sh"

done
## End of loop

rm "$SCRIPT_DIR/remote/current/.env.deploy"
log "##### Deployment Completed for $APP_ENV - $DEPLOY_SERVICE #####"

