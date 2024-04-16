#!/usr/bin/env bash
set -e
VERSION=1.0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

NODE_CURRENT=20.12.2
NODE_UPGRADE=20.12.2
CURRENT=$(cat $PROJECT_DIR/.nvmrc)

if [[ "$CURRENT" == "v$NODE_UPGRADE" ]];then
  echo "Current version is already $NODE_UPGRADE"
  exit 1 
fi

#grep -r "$NODE_CURRENT" --exclude-dir={node_modules,.git,log} --exclude="*.svg" --exclude="$(basename $0)" $PROJECT_DIR
count=$(grep -r "$NODE_CURRENT" --exclude-dir={node_modules,.git,log} --exclude="*.svg" --exclude="$(basename $0)" $PROJECT_DIR | wc -l)
echo "Found $NODE_CURRENT references in $count places"

echo "v$NODE_UPGRADE" > "$PROJECT_DIR/.nvmrc"
sed -i "s/node:$NODE_CURRENT/node:$NODE_UPGRADE/g" "$PROJECT_DIR/bitbucket-pipelines.yml" 
sed -i "s/v$NODE_CURRENT/v$NODE_UPGRADE/g" "$PROJECT_DIR/scripts/test/install.sh"

DEPLOY_SERVICES=($(jq -c -r '.services[].name' $PROJECT_DIR/services.json))    
for service in "${DEPLOY_SERVICES[@]}"
do
  echo "v$NODE_UPGRADE" > "$PROJECT_DIR/$service/.nvmrc"
  service_type=$(jq -c -r --arg n "$service" '.services[] | select(.name == $n) | .type' $PROJECT_DIR/services.json)
  if [[ "$service_type" == "api" ]];then
    sed -i "s/node:$NODE_CURRENT/node:$NODE_UPGRADE/g" "$PROJECT_DIR/$service/api.Dockerfile" 
    sed -i "s/node:$NODE_CURRENT/node:$NODE_UPGRADE/g" "$PROJECT_DIR/$service/Dockerfile" 
    sed -i "s/node:$NODE_CURRENT/node:$NODE_UPGRADE/g" "$PROJECT_DIR/$service/docker-compose.yml" 
  fi
done

count=$(grep -r "$NODE_UPGRADE" --exclude-dir={node_modules,.git,log} --exclude="*.svg" --exclude="$(basename $0)" $PROJECT_DIR | wc -l)
echo "Found $NODE_UPGRADE references in $count places"
#grep -r "$NODE_UPGRADE" --exclude-dir={node_modules,.git,log} --exclude="*.svg" --exclude="$(basename $0)" $PROJECT_DIR

nvm install --reinstall-packages-from="v$NODE_CURRENT" --latest-npm "v$NODE_UPGRADE" 
nvm alias default "v$NODE_UPGRADE" 

#  .nvmrc:v20.11.1
#  generators/api/templates/api.Dockerfile:FROM node:20.11.1
#  generators/api/templates/Dockerfile:FROM node:20.11.1
#  generators/api/templates/.nvmrc:v20.11.1
#  generators/api/templates/docker-compose.yml:    #image: node:20.11.1
#  generators/web/templates/.nvmrc:v20.11.1
#  generators/app/templates/init/.nvmrc:v20.11.1
#  generators/app/templates/init/bitbucket-pipelines.yml:image: node:20.11.0
#  generators/scripts/templates/test/install.sh:  nvm install v20.11.1

