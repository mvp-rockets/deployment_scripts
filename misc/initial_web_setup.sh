#!/usr/bin/env bash
set -e
DEPLOYMENT_DIR=$1
cd $DEPLOYMENT_DIR
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
nvm use