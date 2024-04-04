#!/usr/bin/env bash
set -e
# 1. generate scripts & update scripts for remote
# 2. Make sure the remote directory structure is present
# 3. sync main code
# 4. sync the generated files
# 5. run remote init
# 6. run remote start
# 7. update remote history log
# 8. clean up older deployments

# Config
source "$SCRIPT_DIR/incl.sh"
deployment_path="/$DEPLOY_SERVICE/releases/$GIT_COMMIT"

log "$(basename $PROJECT_DIR) $APP_ENV $GIT_COMMIT $DEPLOY_SERVICE $DEPLOY_SERVICE_TYPE"

# 1. generate scripts & update scripts for remote
log "Generating $DEPLOY_SERVICE deploy config"
generate_pm2_start_json $DEPLOY_SERVICE
cp "$SCRIPT_DIR/env/.env.$APP_ENV" "/$SCRIPT_DIR/remote/current/.env.deploy" 
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set GIT_COMMIT="$GIT_COMMIT"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOY_SERVICE_TYPE="$DEPLOY_SERVICE_TYPE"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set ROOT_DEPLOYMENT_DIR="$ROOT_DEPLOYMENT_DIR"
$SCRIPT_DIR/lib/dotenv --file "/$SCRIPT_DIR/remote/current/.env.deploy" set DEPLOYMENT_DIR="$DEPLOYMENT_DIR"

## Start of loop
if [[ -n $AWS_EC2_TARGET_GROUP_ARN ]]; then
    arg='instance'
    if [ $REMOTE_TYPE != "ec2_instance_connect" ]; then
        arg="ip"
    fi
    primary_prj=$(jq -c -r '.services[] | select(.primary == true).name' $PROJECT_DIR/services.json)

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

    # 2. Make sure the remote directory structure is present
    log "Making sure following dir is present: $DEPLOYMENT_DIR "
    sync_remote_folder_structure "$DEPLOYMENT_DIR"

    # 3. sync main code
    log "##### Starting $DEPLOY_SERVICE deployment #####"
    log "Syncing $DEPLOY_SERVICE"
    sync "/$DEPLOY_SERVICE/" "$deployment_path" \
    --exclude node_modules --exclude test --exclude logs \
    --exclude deployment-scripts --exclude postman --exclude .vscode \
    --exclude codeAnalysis --exclude .nyc_output \
    --exclude elasticmq --exclude volume
    # --exclude-from=ignore-list

    # 4. sync the generated files
    sync "/scripts/remote/current/*" "$deployment_path/"
    sync "/scripts/remote/current/.env.deploy" "$deployment_path/"

    # sync files to the root_deployment_dir
    sync "/scripts/remote/common/*" "/$DEPLOY_SERVICE/"

    # 5. run remote init
    log "init $DEPLOY_SERVICE"
    run_remote "$deployment_path" "init_api.sh"
    # 6. run remote start
    log "start $DEPLOY_SERVICE"
    run_remote "$deployment_path" "start_service.sh"

    # 7. update remote history log
    log "Logging current build to deployment history"
    run_remote "/$DEPLOY_SERVICE" "log_to_deployment_history.sh $GIT_COMMIT"
    # 8. clean up older deployments
    log "Cleaning up old deployments"
    run_remote "/$DEPLOY_SERVICE" "clean_up_old_deployment.sh"

done
## End of loop

log "##### Deployment Completed for $APP_ENV - $DEPLOY_SERVICE #####"
# 9. Update deployment logs
# TODO: Push Deployment Success event

# 10. Cleanup
rm $SCRIPT_DIR/remote/current/deploy.config.json
rm "$SCRIPT_DIR/remote/current/.env.deploy"
# git checkout $SCRIPT_DIR/remote/current
check_remote_connection
