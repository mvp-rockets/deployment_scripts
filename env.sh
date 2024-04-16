#!/usr/bin/env bash
set -e
VERSION=1.0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

VERSION="1.0.0"
# Usage:
#--env qa --create
#--env qa --delete
#--env qa --validate
#--env qa --secrets --create --file /path/to/env/file
#--env qa --secrets --update --file /path/to/env/file
#--env qa --secrets --delete 
#--env qa --secrets --validate 
#--env qa --secrets --compare dev 

# @getoptions
parser_definition() {
  setup REST help:usage abbr:true -- "MVP Rocket environment management script" ''

  msg   -- 'USAGE:' "  ${2##*/} [command] [action] [arguments...]" ''

  msg   -- 'OPTIONS:'
  disp  VERSION -V --version                      -- "Print version info and exit"
  disp  :usage  -h --help                         -- "Print help information"

  msg   -- 'Command Manage Environment: --env <name> --<action>'
  msg   -- 'e.g.: --env qa --create'
  param APP_ENV   -e  --env      -- "--env qa / --env=qa"
  flag  CREATE    -c  --create   -- "create the environment files"
  flag  DELETE    -d  --delete   -- "delete the environment files"
  flag  VALIDATE  -v  --validate -- "validate the environment files"

  msg   -- 'Command Manage Secrets: --env <name> --secret --<action> --file <path/to/file>'
  msg   -- 'e.g.: --env qa --secret --create --file <path/to/env/file>'
  flag  SECRETS   -s  --secrets  -- "Manage secrets for given environment"
  flag  CREATE    -c  --create   -- "create the secrets from the env file"
  flag  UPDATE    -u  --update   -- "update the secrets from the env file"
  flag  DELETE    -d  --delete   -- "delete the secrets for a given environment"
  flag  VALIDATE  -v  --validate -- "validate the secrets for a given environment"
  flag  EXPORT    -p  --export   -- "export the secrets for a given environment"
  param COMPARE   -k  --compare  -- "compare the secret's keys for an environment"
  param FILE      -f  --file     -- "path to env or json file that contains the env key:value"
}
# @end

# @gengetoptions parser -i parser_definition parse
#
#     INSERTED HERE
#
# @end

main() {
  if [ $# -eq 0 ]; then
    eval "set -- --help"
  fi
  eval "$(getoptions parser_definition getoptions_parse "$0") exit 1"
  getoptions_parse "$@"
  eval "set -- $REST"

  export PROJECT_NAME=$(jq -c -r '.projectName' $PROJECT_DIR/services.json)
  primary_prj=$(jq -c -r '.services[] | select(.primary == true).name' $PROJECT_DIR/services.json)

  if [[ -n "$APP_ENV" && -n "$COMPARE" && "$APP_ENV" == "$COMPARE" ]]; then 
    echo "For comparison, source and destination enviroments cannot be the same."
    exit 1
  elif [[ -n "$APP_ENV" && -z "$SECRETS" && -n "$CREATE" ]]; then
    create_environment $APP_ENV
  elif [[ -n "$APP_ENV" && -z "$SECRETS" && -n "$DELETE" ]]; then
    delete_environment $APP_ENV
  elif [[ -n "$APP_ENV" && -z "$SECRETS" && -n "$VALIDATE" ]]; then
    validate_environment $APP_ENV
  elif [[ -n "$APP_ENV" && -n "$SECRETS" && -n "$CREATE" ]]; then
    file="${FILE:="$PROJECT_DIR/$primary_prj/env/.env.$APP_ENV"}"
    create_secrets $APP_ENV $file
  elif [[ -n "$APP_ENV" && -n "$SECRETS" && -n "$UPDATE" ]]; then
    file="${FILE:="$PROJECT_DIR/$primary_prj/env/.env.$APP_ENV"}"
    update_secrets $APP_ENV $file
  elif [[ -n "$APP_ENV" && -n "$SECRETS" && -n "$DELETE" ]]; then
    delete_secrets $APP_ENV
  elif [[ -n "$APP_ENV" && -n "$SECRETS" && -n "$EXPORT" ]]; then
    export_secrets $APP_ENV
  elif [[ -n "$APP_ENV" && -n "$SECRETS" && -n "$VALIDATE" ]]; then
    validate_secrets $APP_ENV
  elif [[ -n "$APP_ENV" && -n "$SECRETS" && -n "$COMPARE" ]]; then
    compare_secrets $APP_ENV $COMPARE
  else
    echo "Invalid arguments or options passed. Please run env.sh -h to see the options"
    eval "set -- --help"
  fi
}

create_environment() {
  echo "create $APP_ENV environment files"
  file_list=()
  # Update all web apps:
  local services=($(jq -r -c '.services[] | select(.type | . and contains("web")).name' $PROJECT_DIR/services.json))
  for web in "${services[@]}"
  do
    jq --arg APP_ENV "$APP_ENV" --indent 4 '.scripts += {"build:$APP_ENV": "env-cmd -f .env.$APP_ENV next build"}' "$PROJECT_DIR/$web/package.json" > package2.json
    sed -i "s/\$APP_ENV/$APP_ENV/g" package2.json
    mv package2.json "$PROJECT_DIR/$web/package.json"
    cp "$PROJECT_DIR/generators/env/env.next" "$PROJECT_DIR/$web/env/.env.$APP_ENV"
    file_list+=("$web/env/.env.$APP_ENV")
  done

  # Copy from template to scripts/env/.env.<name>
  cp "$PROJECT_DIR/generators/env/env.scripts" "$PROJECT_DIR/scripts/env/.env.$APP_ENV"
  "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/scripts/env/.env.$APP_ENV" set APP_ENV="$APP_ENV"
  "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/scripts/env/.env.$APP_ENV" set NODE_ENV="$APP_ENV"
  "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/scripts/env/.env.$APP_ENV" set PROJECT_NAME="$PROJECT_NAME"
  local services=($(jq -r -c '.services[].name' $PROJECT_DIR/services.json))
  for service in "${services[@]}"
  do
    target_group="TARGET_GROUP_"$(echo "$service" | tr '[:lower:]' '[:upper:]')
    "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/scripts/env/.env.$APP_ENV" set "$target_group"=""
  done
  file_list+=("scripts/env/.env.$APP_ENV")

  # Copy from template to api/env/.env.<name>
  local services=($(jq -r -c '.services[] | select(.type | . and contains("api")).name' $PROJECT_DIR/services.json))
  for api in "${services[@]}"
  do
    cp "$PROJECT_DIR/generators/env/env.api" "$PROJECT_DIR/$api/env/.env.$APP_ENV"
    "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/$api/env/.env.$APP_ENV" set APP_ENV="$APP_ENV"
    "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/$api/env/.env.$APP_ENV" set ENVIRONMENT="$APP_ENV"
    file_list+=("$api/env/.env.$APP_ENV")
  done

  # Update bitbucket-pipelines.yml
  # TODO: update bitbucket-pipelines.yml

  # Update app-spec.yml
  # Copy from template <service>-spec.yml
  # TODO: update app-spec.yml

  # Update values from terraform
  if [[ -d "$PROJECT_DIR/infra/$APP_ENV/ecs/modules/ecs-secrets/" ]]; then
    cd "$PROJECT_DIR/infra/$APP_ENV/ecs/modules/ecs-secrets/" 
    #terraform output -json | jq '.secret_arn'
    secret_arn=$(terraform output -raw secret_arn)
    "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/scripts/env/.env.$APP_ENV" set AWS_SM_SECRET_ID="$secret_arn"
  else
    echo "Directory $PROJECT_DIR/infra/$APP_ENV/ not found. Cannot update output variables to env files"
  fi

  echo "Following files have been generated. Please review and update these files before committing them."
  echo ""
  printf ' - %s\n' "${file_list[@]}"
}

delete_environment() {
  echo "delete $APP_ENV files"
  # Update all web apps:
  local services=($(jq -r -c '.services[] | select(.type | . and contains("web")).name' $PROJECT_DIR/services.json))
  for web in "${services[@]}"
  do
    #sed -i '/pattern to match/d' "$PROJECT_DIR/$web/package.json"
    jq --indent 4 "del(.scripts.\"build:$APP_ENV\")" "$PROJECT_DIR/$web/package.json" > package2.json
    mv package2.json "$PROJECT_DIR/$web/package.json"
    rm "$PROJECT_DIR/$web/env/.env.$APP_ENV"
  done

  rm "$PROJECT_DIR/scripts/env/.env.$APP_ENV"

  local services=($(jq -r -c '.services[] | select(.type | . and contains("api")).name' $PROJECT_DIR/services.json))
  for api in "${services[@]}"
  do
    rm "$PROJECT_DIR/$api/env/.env.$APP_ENV"
  done
}

validate_environment() {
  echo "validate $APP_ENV"
}

create_secrets() {
  echo "create secrets for $APP_ENV from $file"

  current_secrets=$(aws secretsmanager list-secrets | jq ".SecretList[] | select(.Name == \"$PROJECT_NAME-$APP_ENV-api-keys\") | select(length > 0)")

  if [ -z "${current_secrets}" ];
  then
    echo "Creating secrets"
    if [[ $file == *.json ]]; then
      jq '. | with_entries(if .value == null or .value == "" then empty else . end)' $file > env2.json
    else
      "$SCRIPT_DIR/lib/shdotenv" --env "$file" --format json -i | jq '. | with_entries(if .value == null or .value == "" then empty else . end)' > env2.json
    fi
    secrets=$(aws secretsmanager create-secret --name "$PROJECT_NAME-$APP_ENV-api-keys" --secret-string file://env2.json)
    secret_arn=$(echo "$secrets" | jq .ARN -r)
    "$SCRIPT_DIR/lib/dotenv" --file "$PROJECT_DIR/scripts/env/.env.$APP_ENV" set AWS_SM_SECRET_ID="$secret_arn"
    rm env2.json
  fi
}

delete_secrets() {
  echo "delete secrets for $APP_ENV"
  aws secretsmanager delete-secret --secret-id "$PROJECT_NAME-$APP_ENV-api-keys" --force-delete-without-recovery 
}

update_secrets() {
  echo "update secrets for $APP_ENV from $file"
  current_secrets=$(aws secretsmanager list-secrets | jq ".SecretList[] | select(.Name == \"$PROJECT_NAME-$APP_ENV-api-keys\") | select(length > 0)")

  if [ -n "${current_secrets}" ];
  then
    echo "Updating secrets"
    if [[ $file == *.json ]]; then
      jq '. | with_entries(if .value == null or .value == "" then empty else . end)' $file > env2.json
    else
      "$SCRIPT_DIR/lib/shdotenv" --env "$file" --format json -i | jq '. | with_entries(if .value == null or .value == "" then empty else . end)' > env2.json
    fi
    secrets=$(aws secretsmanager update-secret --secret-id "$PROJECT_NAME-$APP_ENV-api-keys" --secret-string file://env2.json)
    rm env2.json
  fi
}

export_secrets() {
  aws secretsmanager get-secret-value --secret-id "$PROJECT_NAME-$APP_ENV-api-keys" | jq -r '.SecretString' | jq -r '.'
}

validate_secrets() {
  echo "$APP_ENV and $SECRETS validate"
}

compare_secrets() {
  echo "compare secrets of $COMPARE against $APP_ENV "
  aws secretsmanager get-secret-value --secret-id "$PROJECT_NAME-$APP_ENV-api-keys" | jq -r '.SecretString' | jq -r 'keys[]'
  #instead of keys you can use keys_unsorted 
}

source "$SCRIPT_DIR/lib/getoptions.sh"

main "$@"
