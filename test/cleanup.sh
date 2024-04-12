#!/usr/bin/env bash
set -e

if vagrant status | grep "running"; 
then
  vagrant destroy
fi

if [ $(docker compose -f ../../api/docker-compose.yml ps | wc -l) -gt 1 ];
then
  cd ../../api
  docker compose down -v
  cd -
fi

rm ../config/golden-key
