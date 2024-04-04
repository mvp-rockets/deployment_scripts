#!/usr/bin/env bash
set -e

DEPLOYMENT_DIR=$(pwd)
ROOT_DEPLOYMENT_DIR=$(builtin cd "../../"; pwd)

cd $ROOT_DEPLOYMENT_DIR

echo "creating symbolic link"
ln -sf $DEPLOYMENT_DIR $ROOT_DEPLOYMENT_DIR/current

echo "starting api"
cd $ROOT_DEPLOYMENT_DIR/current
pm2 startOrRestart deploy.config.json

running=$(pm2 jlist | jq .[].name | wc -l)
saved=$(jq .[].name ~/.pm2/dump.pm2 | wc -l)
if [ $running -ne $saved ];
then
    echo "pm2 tasks mismatch. running: $running Saved: $saved."
    echo "Saving pm2 tasks"
    pm2 save
fi