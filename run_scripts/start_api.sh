#!/usr/bin/env bash
set -e
ROOT_DEPLOYMENT_DIR=$1
DEPLOYMENT_DIR=$2
GIT_COMMIT=$3
cd $ROOT_DEPLOYMENT_DIR
echo "deleting current directory"
rm -rf ./current
echo "creating symbolic link"
ln -s $DEPLOYMENT_DIR $ROOT_DEPLOYMENT_DIR/current
echo "starting api"
cd $ROOT_DEPLOYMENT_DIR/current
pm2 startOrRestart deploy.config.json
