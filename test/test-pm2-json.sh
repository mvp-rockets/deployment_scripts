#!/usr/bin/env bash
set -e

source incl.sh

NODE_ENV=qa
APP_ENV=qa
PROJECT_NAME=vagrant
ROOT_DEPLOYMENT_DIR=~/workspace/napses/testing/scripts/temp
PROJECT_DIR=~/workspace/napses/testing/scripts/temp

generate_start_scripts core 'current/api/' index
generate_web_start_scripts admin 'current/api/' index

jq -c '.services[]' ./temp/services.json | while read service; do
    # do stuff with $i
    sname=$(echo $service | jq -r '.name')
    stype=$(echo $service | jq -r '.type')
    readarray -t deploy_services < <(echo $service | jq -c -r '.sub_services[]')
    echo "sname - stype { ${deploy_services[*]} }"
  generate_pm2_start_json $sname "$sname.config.json" 
done
