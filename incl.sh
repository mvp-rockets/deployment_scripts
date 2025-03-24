
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

# runs a command (second argument) in a directory (first argument) in a remote machine.
# uses ssh to execute the command remotely
function run_remote()
{
    exec_remote "cd $ROOT_DEPLOYMENT_DIR$1; ./$2"
}

function exec_remote()
{
    if [ $REMOTE_TYPE == "ssh" ];
    then
      ssh_args="$KEYARG -t -o ControlMaster=auto -o ControlPath=~/.ssh/ssh-master-%C -o ControlPersist=60"
      ssh $ssh_args $REMOTE_USER@$SERVER_NAME "$@" 

    elif [ $REMOTE_TYPE == "ec2_instance_connect" ];
    then
      ssh $KEYARG -t $REMOTE_USER@$INSTANCE_ID \
        -o ProxyCommand='aws ec2-instance-connect open-tunnel \
        --instance-id '$INSTANCE_ID' --profile '$AWS_PROFILE' \
        --region '$AWS_REGION'' "$@"
    # aws ec2-instance-connect --region '$AWS_REGION' --instance-id '' --instance-os-user ubuntu --ssh-public-key file://<path>
    elif [ $REMOTE_TYPE == "aws_session_manager" ]; # Needs testing
    then
      aws ssm --region $AWS_REGION start-session --target $INSTANCE_ID  "$@"

    elif [ $REMOTE_TYPE == "teleport" ];
    then
      tsh ssh -t $REMOTE_USER@$SERVER_NAME "$@"

    elif [ $REMOTE_TYPE == "local" ];
    then
      eval " $@"

    else
        error "Unsupported REMOTE_TYPE = $REMOTE_TYPE"
        exit 1
    fi
    #  -o ServerAliveInterval=60 
}

function check_remote_connection()
{
  ssh $KEYARG -O check -o ControlPath=~/.ssh/ssh-master-%C $REMOTE_USER@$SERVER_NAME 
}

function end_remote_connection()
{
  ssh $KEYARG -O stop -o ControlPath=~/.ssh/ssh-master-%C $REMOTE_USER@$SERVER_NAME
}

function sync_remote_folder_structure()
{
  exec_remote "mkdir -p $1"   
}

# loads a file passed as parameter and ensures that we export all
# variables defined within the file
function load_vars()
{
  if [ ! -f $1 ];
  then
    error "$1 config file not found"
    return 1
  fi

  set -a
  source $1 set
  set +a
}

# Exports pre-defined variables like
# SCRIPT_DIR: Absolute Path where the deployment scripts reside
# PROJECT_DIR: Root directory for the project git repo
# APP_ENV: Application Environment, e.g. qa, uat, production, ...
# NODE_ENV: Depreceated. Same as APP_ENV
# IDENTITY_FILE: Pem file used for SSH
# GIT_COMMIT: Commit ID that is being deployed
# DEPLOYMENT_DIR: Remote path under which the app will be deployed.
# ROOT_DEPLOYMENT_DIR: The root directory under which all apps reside 
function export_vars()
{
    export SCRIPT_DIR=$SCRIPT_DIR
    export PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)
    export APP_ENV=$APP_ENV
    export NODE_ENV=$APP_ENV
    #parent_dir="$(dirname -- "$(realpath -- "$file_or_dir_name")")"
    export IDENTITY_FILE="$SCRIPT_DIR/$IDENTITY_FILE"
    export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
    export DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$APP_ENV"
    export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$APP_ENV"

    if [[ "$IDENTITY_FILE" != "" ]]; then
        export KEYARG="-i $IDENTITY_FILE"
    else
        export KEYARG=
    fi
}

## Sync directories where source directory is local and target directory is remote
# sync source target additional args
# It uses rsync, so all additional args are passed through to rsync
function sync()
{
    all_args=($@)
    rest_args=(${all_args[@]:2})

    # rsync args used:
    #
    # -a = --archive, which is -rlptgoD
    #      i.e. --recursive --links --perms --times --group --owner
    # -q = --quiet
    # -z = --compress
    # -h = --human-readable
    # -P = --partial --progress
    # -e = -rsh=COMMAND

    set +x
    if [ $REMOTE_TYPE == "ssh" ]; 
    then
      ssh_args="$KEYARG" #-tt -o ControlMaster=auto -o ControlPath=~/.ssh/ssh-master-%C -o ControlPersist=60"

      #--delete-after
      rsync -Pazq --delete --filter=":- $PROJECT_DIR/.gitignore" -e "ssh $ssh_args" $PROJECT_DIR$1 $REMOTE_USER@$SERVER_NAME:$ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}

    elif [ $REMOTE_TYPE == "ec2_instance_connect" ];
    then
      rsync -Pazq --delete --filter=":- $PROJECT_DIR/.gitignore" -e "ssh $KEYARG -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id $INSTANCE_ID --profile $AWS_PROFILE --region $AWS_REGION'" $PROJECT_DIR$1 $REMOTE_USER@$INSTANCE_ID:$ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}

    elif [ $REMOTE_TYPE == "teleport" ];
    then
      rsync -Pazq --delete --filter=":- $PROJECT_DIR/.gitignore" -e "tsh ssh" $PROJECT_DIR$1 $REMOTE_USER@$SERVER_NAME:$ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}

    elif [ $REMOTE_TYPE == "local" ];
    then
      rsync -Pazq --delete --filter=":- $PROJECT_DIR/.gitignore" $PROJECT_DIR$1 $ROOT_DEPLOYMENT_DIR$2 ${rest_args[@]}
    else
      error "Unsupported REMOTE_TYPE = $REMOTE_TYPE"
      exit 1
    fi
}

# $1: Project directory that needs to be checked for project type
# Returns 1 if it fails else returns 0
# Set's a global variable $PROJECT_TYPE and also echo's the following values
# "typescript", "javascript", "go", "flutter" or "dart" depending upon the project type 
# Usage: project_type=$(check_project_type "$project_dir") 
# Use the PROJECT_TYPE variable in your script
#    if [[ "$PROJECT_TYPE" != "unknown" && "$PROJECT_TYPE" != "invalid_directory" ]]; then
#      echo "Project type detected: $PROJECT_TYPE"
#    else
#      echo "No valid project detected in the given directory."
#    fi
check_project_type() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        echo "Usage: check_project_type <directory>"
        return 1
    fi

    # Check if the argument is a directory
    if [[ ! -d "$dir" ]]; then
        echo "Error: Directory '$dir' does not exist."
        return 1
    fi

    # Check for TypeScript project
    if [[ -f "$dir/tsconfig.json" ]]; then
        PROJECT_TYPE="typescript"
        echo "typescript"
        return 0
    fi

    # Check for JavaScript project (Node.js)
    if [[ -f "$dir/package.json" ]]; then
        PROJECT_TYPE="javascript"
        echo "javascript"
        return 0
    fi

    # Check for Go project
    if [[ -f "$dir/go.mod" ]]; then
        PROJECT_TYPE="go"
        echo "go"
        return 0
    fi

    # Check for Flutter or Dart project
    if [[ -f "$dir/pubspec.yaml" ]]; then
        if grep -q "flutter:" "$dir/pubspec.yaml"; then
            PROJECT_TYPE="flutter"
            echo "flutter"
            return 0
        else
            PROJECT_TYPE="dart"
            echo "dart"
            return 0
        fi
    fi

    PROJECT_TYPE="unknown" 
    echo "unknown"
    return 1
}

# $1: App name, e.g. api, admin, ui, ...
# $2: Target file name (optional), defaults to deploy.config.json
# $3: services.json file(optional), defaults to $PROJECT_DIR/services.json. Used for testing purpose
# Env Variables: PROJECT_NAME, APP_ENV, PROJECT_DIR, SCRIPT_DIR
# Expects services.json file to be present in PROJECT_DIR. Format of the file
##  {
##    "services": [
##      {"type": "api", "name": "core", "sub_services": ["cron", "socket", "sqs"]},
##      {"type": "api", "name": "auth", "sub_services": []},
##      {"type": "web", "name": "admin", "sub_services": []},
##      {"type": "backend", "name": "backend", "sub_services": ["cron", "socket", "sqs"]}
##    ]
##  }
## For more details see: test/test-pm2-json.sh && test/pm2-config/services.json
function generate_pm2_start_json()
{
  local service=$1
  TEMP_FILE=$(mktemp tmp.XXXXXXXXXX)
  target_file="${2:-deploy.config.json}"
  services_file="${3:-services.json}"
  info=$(jq -c --arg n "$service" '.services[] | select(.name == $n)' $PROJECT_DIR/$services_file)

  # Create the base 
  apps='{ "apps": [] }'
  service_type=$(echo "$info" | jq -r '.type')
  app=
  
  excluded=$(echo $info | jq -c -r --arg env "$APP_ENV" '.excludeEnvs | if . != null then any(. == $env) else false end')
  included=$(echo $info | jq -c -r --arg env "$APP_ENV" '.includeEnvs | if . != null then any(. == $env) else true end')
  if ! $excluded && $included ;
   then

    if [ "$service_type" != "backend" ]
    then
      app=$(build_pm2_json $service_type "$PROJECT_NAME-$APP_ENV-$service" $service)
      apps=$(echo "$apps" | jq --argjson app "$app" '.apps += [$app ]')
    fi

    if ! $(echo $info | jq -c -r --arg env "$APP_ENV" '.sub_services.excludeEnvs | if . != null then any(. == $env) else false end') &&
      $(echo $info | jq -c -r --arg env "$APP_ENV" '.sub_services.includeEnvs | if . != null then any(. == $env) else true end') ;
     then
      readarray -t deploy_services < <(echo $info | jq -c -r '.sub_services.services[]')

      for sub in "${deploy_services[@]}"
      do
        app=$(build_pm2_json $sub "$PROJECT_NAME-$APP_ENV-$sub" $service)
        apps=$(echo "$apps" | jq --argjson app "$app" '.apps += [$app ]')
      done
    fi
  fi
  echo "$apps" > $TEMP_FILE
  mv $TEMP_FILE $SCRIPT_DIR/remote/current/$target_file
}

## Takes 3 arguments
# $1: type: web, api, cron, sqs, socket
# $2: Name of the app. e.g. project-qa-api
# $3: working directory, e.g. api, web, admin,...
# Env Variables that need to be defined
# NODE_ENV, APP_ENV, ROOT_DEPLOYMENT_DIR
function build_pm2_json()
{
  json=$(cat << EOT_JS 
{
  "name": "$2",
  "cwd": "$ROOT_DEPLOYMENT_DIR/$3/current/",
  "env": {
     "NODE_ENV": "$NODE_ENV",
     "APP_ENV": "$APP_ENV"
  },
  "time": true,
  "exp_backoff_restart_delay": 100,
  "max_restarts": 16
}
EOT_JS

)
# "exp_backoff_restart_delay": 100,
# "max_restarts": 16,
# "min_uptime": 5000, 
# "max_memory_restart": "1G",

#TODO: Fix the script path depending upon if it's typescript or not
#e.g. index.js becomes build/src/main.js
case "$1" in
  web|admin)
  service_port="PORT_"$(echo "$3" | tr '[:lower:]' '[:upper:]')
  json=$(echo "$json" | jq '.env.NODE_ENV = "production"')
  json=$(echo "$json" | jq --arg p "${!service_port}" '.env.PORT = $p')
  read -r -d '' js << EOM
{
  "script" : "npm",
  "args" : "run start"
}
EOM
  ;;
  api)
  read -r -d '' js << EOM
{
  "script": "./index.js",
  "exec_mode" : "cluster",
  "instances" : 2,
  "combine_logs": true,
  "node_args": [
     "--max_old_space_size=1048"
   ]}
EOM
  ;;
  cron|backend|sqs|socket)
  read -r -d '' js << EOM
{
  "exp_backoff_restart_delay": "500",
  "max_memory_restart": "2G",
  "script": "./$1-index.js",
  "node_args": [
     "--max_old_space_size=2048"
   ]}
EOM
  ;;
esac

  json=$(echo "$json" | jq --argjson json "$js" '. += $json')
  echo "$json"
}

function is_healthy() {
    
    service="$1"
    container_id="$(docker compose ps -q "$service")"
    health_status="$(docker inspect -f "{{.State.Health.Status}}" "$container_id")"

    if [ "$health_status" = "healthy" ]; then
        return 0
    else
        return 1
    fi
}

function check_for_commands() {

  # Check if AWS CLI and jq are installed
  if ! command -v aws &> /dev/null; then
      echo "AWS CLI not found. Please install AWS CLI."
      exit 1
  fi

  if ! command -v jq &> /dev/null; then
      echo "jq not found. Please install jq."
      exit 1
  fi
}
function smoke_tests() {

  # Check if AWS CLI and jq are installed
    log "Running smoke tests to verify deployment"
    "$SCRIPT_DIR/run-smoke-tests.sh" "$APP_ENV"
    SMOKE_TEST_RESULT=$?

    if [ $SMOKE_TEST_RESULT -ne 0 ]; then
        error "❌ Smoke tests failed! Please check the logs and fix any issues."
        # Uncomment the line below if you want deployment to fail when smoke tests fail
        # exit 1
    fi
}
