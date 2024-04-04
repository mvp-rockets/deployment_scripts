#!/usr/bin/env bash
set -e
GIT_COMMIT=$1
if [ -f deployment_history ]
then
    previous=$(tail -n 1 deployment_history)
    if [[ "$previous" != "$GIT_COMMIT" ]]; then
        echo "$GIT_COMMIT">>deployment_history
    fi
else
    echo "$GIT_COMMIT">>deployment_history
fi

