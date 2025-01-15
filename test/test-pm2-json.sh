#!/usr/bin/env bash
set -e

source ../incl.sh

NODE_ENV=prod
APP_ENV=qa
PROJECT_NAME=vagrant
ROOT_DEPLOYMENT_DIR=~/apps/testing/vagrant
PROJECT_DIR='./pm2-config'
SCRIPT_DIR="."

#echo "$APP_ENV api should have services cron, sqs"
#generate_pm2_start_json api "$APP_ENV-api.deploy.json"
#
#echo "$APP_ENV backend should not be included"
#generate_pm2_start_json backend "$APP_ENV-backend.deploy.json"
#
#echo "$APP_ENV ui should be included"
#generate_pm2_start_json ui "$APP_ENV-ui.deploy.json"
#
#echo "$APP_ENV admin should be included"
#generate_pm2_start_json admin "$APP_ENV-admin.deploy.json"
#
#echo "$APP_ENV auth should not be included"
#generate_pm2_start_json auth "$APP_ENV-auth.deploy.json"
#
#echo "$APP_ENV background should not be included"
#generate_pm2_start_json background "$APP_ENV-background.deploy.json"

#generate_pm2_start_json web "web.deploy.json"
#generate_pm2_start_json admin "admin.deploy.json"
#generate_pm2_start_json sqs "sqs.deploy.json"

environments=("qa" "prod" "test")
for sub in "${environments[@]}"
do
  APP_ENV=$sub
  echo "$APP_ENV loaded ..."
  jq -c '.services[]' ./pm2-config/services.json | while read service; do
      # do stuff with $i
      sname=$(echo $service | jq -r '.name')
      stype=$(echo $service | jq -r '.type')
      readarray -t deploy_services < <(echo $service | jq -c -r '.sub_services[]')
      echo "Services generated: $sname - $stype { ${deploy_services[*]} }"
    generate_pm2_start_json $sname "$APP_ENV-$sname.config.json" 'services.json' 
  done
done

# TODO: Test the output against expected json
#mkdir 1
#mkdir 2
#for i in `ls X/`; do cat X/$i | jq -S -f walk.filter > 1/$i; done 
#for i in `ls Y/`; do cat Y/$i | jq -S -f walk.filter > 2/$i; done 
#meld 1/ 2/

#diff <(jq -S . A.json) <(jq -S . B.json)
#diff <(jq -S -f walk.filter . A.json) <(jq -S -f walk.filter . B.json)
