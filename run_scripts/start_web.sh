#!/usr/bin/env bash
set -e
ROOT_DEPLOYMENT_DIR=$1
DEPLOYMENT_DIR=$2
NODE_ENV=$3
echo "creating symbolic link with cache .next"
# ln -sfT $ROOT_DEPLOYMENT_DIR/cache/.next $DEPLOYMENT_DIR/.next
cd $ROOT_DEPLOYMENT_DIR
echo "deleting current directory"
rm -rf ./current
echo "creating symbolic link"
ln -s  $DEPLOYMENT_DIR $ROOT_DEPLOYMENT_DIR/current
echo "starting web"
cd $ROOT_DEPLOYMENT_DIR/current
pm2 startOrRestart deploy.config.json