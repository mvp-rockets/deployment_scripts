
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
    cd $DEPLOYMENT_DIR$1; ./$2
}

function sync()
{
    all_args=($@)
    rest_args=(${all_args[@]:2})
    set +x
    rsync -av --progress  $PROJECT_DIR$1 $DEPLOYMENT_DIR$2 ${rest_args[@]}
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
