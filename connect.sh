#!/usr/bin/env bash
set -e
if [ -z "$1" ]
then
    echo "No argument supplied"
    exit 1
fi
export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. "$SCRIPT_DIR/env/.env.$1"
ssh -i $SCRIPT_DIR/$IDENTITY_FILE $REMOTE_USER@$SERVER_NAME