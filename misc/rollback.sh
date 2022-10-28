#!/bin/bash
set -e

nos=$(wc -l < deployment_history)
if [ $nos -gt 1 ]
then
  rolled=$(tail -n 1 deployment_history)
  sed -i '$ d' deployment_history
  current=$(tail -n 1 deployment_history)
  rm -rf releases/$rolled
  ln -sfr releases/$current current
  cd ./current
  pm2 startOrReload deploy.config.json
fi
