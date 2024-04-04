#!/usr/bin/env bash
set -e

if [ ! -f ./golden-key ]
then
  ssh-keygen -t ed25519 -C "devops@napses.com" -f ./golden-key -q -N "" 
fi

if vagrant status | grep "running"; 
then
  echo "Vagrant is up"
else
  vagrant up
fi

if [ $(docker compose -f ../../api/docker-compose.yml ps | wc -l) -eq 1 ];
then
  pushd .
  echo "Starting docker ..."
  cd ../../api
  #docker compose --project-name "vagrant-backend" up -d
  docker compose up -d
  popd
fi

secrets_file="../env/.env.vagrant"
secrets_api_file="../../api/env/.env.vagrant"

current_secrets=$(aws secretsmanager list-secrets | jq '.SecretList | select(length > 0)')

if [ -z "${current_secrets}" ];
then
  echo "Creating secrets"
  ../lib/shdotenv --env "$secrets_api_file" --format json -i > env.json
  secrets=$(aws secretsmanager create-secret --name 'api-vagrant-keys' --secret-string file://env.json)
  rm env.json
fi

source ../lib/dotenv

region=$( ../lib/dotenv --file "$secrets_file" get AWS_SM_REGION )
if [ -z "${region}" ];
then
  region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
  echo "Setting region $region"
fi

if [ ! -z "${secrets}" ];
then
  secret_arn=$(echo "$secrets" | jq .ARN -r)
  echo "Setting secret ARN: $secret_arn"
  ../lib/dotenv --file "$secrets_file" set AWS_SM_SECRET_ID="$secret_arn"
fi

secret_arn=$( ../lib/dotenv --file "$secrets_file" get AWS_SM_SECRET_ID )
if [ -z "${secret_arn}" ];
then
  secret_arn=$(aws secretsmanager list-secrets | jq '.SecretList[0].ARN' -r)
  echo "Setting secret ARN: $secret_arn"
  ../lib/dotenv --file "$secrets_file" set AWS_SM_SECRET_ID="$secret_arn"
fi
