#!/usr/bin/env bash
set -e
ROOT_DEPLOYMENT_DIR=$1
GIT_COMMIT=$2
cd $ROOT_DEPLOYMENT_DIR
if [ -f $ROOT_DEPLOYMENT_DIR/deployment_history ]
then
    previous=$(tail -n 1 deployment_history)
    if [[ "$previous" != "$GIT_COMMIT" ]]; then
        echo "$GIT_COMMIT">>$ROOT_DEPLOYMENT_DIR/deployment_history
    fi
else
    echo "$GIT_COMMIT">>$ROOT_DEPLOYMENT_DIR/deployment_history
fi

