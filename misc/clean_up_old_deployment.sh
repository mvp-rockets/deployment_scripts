#!/usr/bin/env bash
set -e
nos=$(wc -l < deployment_history)
if [ $nos -gt 2 ]
then
  deployment_to_delete=$(head -n 1 deployment_history)
  rm -rf releases/$deployment_to_delete
  sed -i "1d" deployment_history
fi
