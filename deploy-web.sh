#!/usr/bin/env bash
set -e
# 1. generate scripts & update scripts for remote
# 2. Prepare for build
# 3. Build storybook
# 4. Build next
# 5. Make sure the remote directory structure is present
# 6. sync .next and related stuff
# 7. sync the generated files
# 8. run remote start
# 9. update remote history log
# 10. clean up older deployments
 
# Init
source "$SCRIPT_DIR/incl.sh"
deployment_path="/$DEPLOY_SERVICE/releases/$GIT_COMMIT"

log "$(basename $PROJECT_DIR) $APP_ENV $GIT_COMMIT $DEPLOY_SERVICE"

# TODO: Check if the service is to be deployed locally or remotely
# echo "$DEPLOY_SERVICE" | tr '[:lower:]' '[:upper:]'

export NODE_ENV=production

# 1. generate scripts & update scripts for remote
log "Generating $DEPLOY_SERVICE deploy config"
generate_pm2_start_json $DEPLOY_SERVICE "deploy.config.json"
cp "$SCRIPT_DIR/env/.env.$APP_ENV" "/$SCRIPT_DIR/remote/current/.env.deploy" 
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set GIT_COMMIT="$GIT_COMMIT"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOY_SERVICE_TYPE="$DEPLOY_SERVICE_TYPE"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set ROOT_DEPLOYMENT_DIR="$ROOT_DEPLOYMENT_DIR"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOYMENT_DIR="$DEPLOYMENT_DIR"

# 2. Prepare for build
cd "$PROJECT_DIR/$DEPLOY_SERVICE"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
if command -v nvm &> /dev/null
then
  nvm use
fi

# Cleanup local files
rm -rf .next
rm -rf node_modules/ --force
rm -rf storybook-static/ --force
rm -rf ./public/storybook/ --force
git checkout package-lock.json
npm ci --include=dev

# 3. Build storybook
if [ $BUILD_STORYBOOK == true ];
then
    log "Building storybook"
    npm run build:storybook
    npm run deploy-storybook
    cp -r ./storybook-static ./public/storybook
fi

# 4. Build next
log "Building $DEPLOY_SERVICE"
npm run build:$APP_ENV
npm prune --production

## Start of loop
if [[ -n $AWS_EC2_TARGET_GROUP_ARN ]]; then
    arg='instance'
    if [ $REMOTE_TYPE != "ec2_instance_connect" ]; then
        arg="ip"
    fi
    primary_prj=$(jq -c -r '.services[] | select(.primary == true) | if .location != null then .location else .name end' $PROJECT_DIR/services.json)

    servers=( $(node "$PROJECT_DIR/$primary_prj/get-instances-by-target-group.js" $arg ) )
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

    # 5. Make sure the remote directory structure is present
    log "Making sure following dir is present: $DEPLOYMENT_DIR "
    sync_remote_folder_structure "$DEPLOYMENT_DIR"

    # 6. sync .next and related stuff
    log "Syncing $DEPLOY_SERVICE"
    sync "/$DEPLOY_SERVICE/.next" "$deployment_path"
    sync "/$DEPLOY_SERVICE/.nvmrc" "$deployment_path"
    sync "/$DEPLOY_SERVICE/node_modules" "$deployment_path"
    sync "/$DEPLOY_SERVICE/env/.env.$APP_ENV" "$deployment_path/.env"
    sync "/$DEPLOY_SERVICE/next.config.js" "$deployment_path"
    sync "/$DEPLOY_SERVICE/public" "$deployment_path"
    sync "/$DEPLOY_SERVICE/package*.json" "$deployment_path"

    # 7. sync the generated files
    sync "/scripts/remote/current/*" "$deployment_path/"
    sync "/scripts/remote/current/.env.deploy" "$deployment_path/"
    # sync files to the root_deployment_dir
    sync "/scripts/remote/common/*" "/$DEPLOY_SERVICE/"

    # 8. run remote start
    log "start $DEPLOY_SERVICE"
    run_remote "$deployment_path" "start_service.sh"

    # 9. update remote history log
    log "Logging current build to deployment history"
    run_remote "/$DEPLOY_SERVICE" "log_to_deployment_history.sh $GIT_COMMIT"

    # 10. clean up older deployments
    log "Cleaning up old deployments"
    run_remote "/$DEPLOY_SERVICE" "clean_up_old_deployment.sh"

done
## End of loop

log "##### Deployment Completed for $APP_ENV - $DEPLOY_SERVICE #####"
# 11. Update deployment logs
# TODO: Push Deployment Success event

# 12. Cleanup
rm $SCRIPT_DIR/remote/current/deploy.config.json
rm "$SCRIPT_DIR/remote/current/.env.deploy"
#git checkout $SCRIPT_DIR/remote/current
