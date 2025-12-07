#!/usr/bin/env bash
set -e

set -a
source .env.deploy set
set +a

SERVICE_DIR="$ROOT_DEPLOYMENT_DIR/$DEPLOY_SERVICE"

cd $SERVICE_DIR

rm -f $SERVICE_DIR/current

echo "creating symbolic link for $GIT_COMMIT"
ln -sf $DEPLOYMENT_DIR $SERVICE_DIR/current

echo "starting service $DEPLOY_SERVICE"
cd $SERVICE_DIR/current
pm2 startOrRestart deploy.config.json

running=$(pm2 jlist | jq .[].name | wc -l)
saved=$(jq .[].name ~/.pm2/dump.pm2 | wc -l)
((saved++)) # Ensure that we take pm2-logrotate into account
if [ $running -ne $saved ];
then
    echo "pm2 tasks mismatch. running: $running Saved: $saved."
    echo "Saving pm2 tasks"
    pm2 save
fi
