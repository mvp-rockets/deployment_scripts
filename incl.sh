
function log()
{
    GREEN="32"
    BOLDGREEN="\e[1;${GREEN}m"
    ENDCOLOR="\e[0m"
    
    echo -e "${BOLDGREEN} $@ ${ENDCOLOR}"
}
function error()
{
    RED="31"
    ITALICRED="\e[3;${RED}m"
    ENDCOLOR="\e[0m"
    
    echo -e "${ITALICRED} $@ ${ENDCOLOR}"
}

function run()
{
    echo "Running: $@"
    "$@"
}

function run_remote()
{
    if [ $NODE_ENV == "qa" ];
    then
        ssh $KEYARG -t $REMOTE_USER@$SERVER_NAME "cd $ROOT_DEPLOYMENT_DIR$1; ./$2"
    elif [ $NODE_ENV == "uat" ] || [ $NODE_ENV == "production" ] || [ $NODE_ENV == "automation" ] && [ "$TYPE" == "web" ] || [ "$TYPE" == "api" ];
    then
        ssh $KEYARG -t $REMOTE_USER@$INSTANCE_ID -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id '$INSTANCE_ID' --profile '$AWS_PROFILE' --region '$AWS_REGION'' "cd $ROOT_DEPLOYMENT_DIR$1; ./$2"
    else
        echo "please check run_remote"
        exit 1
    fi
#    ssh $KEYARG -t $REMOTE_USER@$SERVER_NAME "cd $ROOT_DEPLOYMENT_DIR$1; ./$2"
}
 
function sync()
{
    all_args=($@)
    rest_args=(${all_args[@]:2})
    set +x
    if [ $NODE_ENV == "qa" ]; 
    then
        rsync -Paz --delete -e "ssh $KEYARG" $PROJECT_DIR$1 $REMOTE_USER@$SERVER_NAME:$ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}
    elif [ $NODE_ENV == "uat" ] || [ $NODE_ENV == "production" ] || [ $NODE_ENV == "automation" ] && [ "$TYPE" == "web" ] || [ "$TYPE" == "api" ];
    then
        rsync -Paz --delete -e "ssh $KEYARG -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id $INSTANCE_ID --profile $AWS_PROFILE --region $AWS_REGION'" $PROJECT_DIR$1 $REMOTE_USER@$INSTANCE_ID:$ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}
    else
        echo "please check rsync"
        exit 1
    fi
#   rsync -Paz --delete -e "ssh $KEYARG" $PROJECT_DIR$1 $REMOTE_USER@$SERVER_NAME:$ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}
}


function generate_start_scripts()
{
    TEMP_FILE=$(mktemp tmp.XXXXXXXXXX)
    target_file=deploy.config.json
    cat << EOT_JS >> $TEMP_FILE
{
  "apps" : [{
    "name"   : "$NODE_ENV-$1-$PROJECT_NAME",
    "script": "./$3.js",
    "cwd": "$ROOT_DEPLOYMENT_DIR/$2",
    "exec_mode" : "cluster",
    "instances" : 2,
    "env": {
       "NODE_ENV": "$NODE_ENV",
    },
    "time": true,
    "node_args": [
       "--max_old_space_size=2048"
     ]
  },
  {
    "name"   : "$NODE_ENV-socket-$PROJECT_NAME",
    "script": "./cron-index.js",
    "cwd": "$ROOT_DEPLOYMENT_DIR/$2",
    "env": {
       "NODE_ENV": "$NODE_ENV",
    },
    "time": true,
    "node_args": [
       "--max_old_space_size=3526"
     ]
  }],
}
EOT_JS
    mv $TEMP_FILE $PROJECT_DIR/$target_file
}

function generate_web_start_scripts()
{
    TEMP_FILE=$(mktemp tmp.XXXXXXXXXX)
    target_file=deploy.config.json
    cat << EOT_JS >> $TEMP_FILE
{
  "apps" : [{
    "name"   : "$NODE_ENV-$1-$PROJECT_NAME",
    "script" : "npm",
    "args" : "run start:$NODE_ENV",
    "cwd": "$ROOT_DEPLOYMENT_DIR/$2",
    "env": {
       "NODE_ENV": "$NODE_ENV"
    },
    "time": true
  }]
}
EOT_JS
    mv $TEMP_FILE $PROJECT_DIR/$target_file
}
