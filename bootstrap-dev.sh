#!/usr/bin/env bash
set -e
VERSION=1.0

if ! command -v jq &> /dev/null
then
  #sudo apt-get -y update && sudo apt-get -y upgrade
  sudo apt-get -y update 
  sudo apt-get -y install build-essential python3 jq git tree redis-tools postgresql-client moreutils
fi

if [[ $(type -t nvm) == function ]] ;
then
  echo "nvm is already installed, skipping..."
elif [[ ! -d "$HOME/.nvm" ]]
then 
  cd ~
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  TEMP_FILE=$(mktemp tmp.XXXXXXXXXX)
  echo  'export NVM_DIR="$HOME/.nvm"' > $TEMP_FILE
  echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> $TEMP_FILE
  cat ~/.bashrc >> $TEMP_FILE && mv $TEMP_FILE ~/.bashrc 
  source ~/.bashrc
else
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
fi

if [ -z "$NVM_DIR" ]
then 
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
fi

if ! command -v node &> /dev/null
then
  nvm install
  npm install -g node-gyp
fi

if ! command -v docker &> /dev/null
then
  # Add Docker's official GPG key:
  sudo apt-get -y update
  sudo apt-get -y install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update

  # Install docker
  sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker $USER
  newgrp docker

  # Verify if it works
  docker run hello-world
fi

if ! command -v snyk &> /dev/null
then
  curl https://static.snyk.io/cli/latest/snyk-linux -o snyk
  chmod +x ./snyk
  sudo mv ./snyk /usr/local/bin/
fi

# Init
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../"; pwd)

source "$SCRIPT_DIR/incl.sh"
source "$SCRIPT_DIR/lib/dotenv"

# Project Init
pushd .
primary_prj=$(jq -c -r '.services[] | select(.primary == true).name' $PROJECT_DIR/services.json)
cd "$PROJECT_DIR/$primary_prj"
if [[ $(node -v) != $(cat .nvmrc) ]]; then
    nvm install
fi
nvm use
npm install 

set +e
npm audit fix
set -e

mkdir -p seeders

if [ $(docker compose -f docker-compose.yml ps | wc -l) -eq 1 ];
then
  echo "Starting docker ..."
  docker compose up -d
fi

echo "waiting for postgres db..."

while ! is_healthy db; do sleep 1; done

echo "starting db migration"

# Setup DB

load_vars "./env/.env.test"

has_db=$(PGPASSWORD=root psql -U root -h localhost -XtAc "SELECT 1 FROM pg_database WHERE datname = 'test-api'")
if [[ $has_db -ne 1 ]]
then 
    APP_ENV=test npm run db:create
    APP_ENV=test npm run db:migrate
    APP_ENV=test npm run db:seed:all
fi

load_vars "./env/.env.ci"

has_db=$(PGPASSWORD=root psql -U root -h localhost -XtAc "SELECT 1 FROM pg_database WHERE datname = 'ci-api'")
if [[ $has_db -ne 1 ]]
then 
    APP_ENV=ci npm run db:create
    APP_ENV=ci npm run db:migrate
    APP_ENV=ci npm run db:seed:all
fi

#change db.host = localhost so that we can run it outside docker compose
$SCRIPT_DIR/lib/dotenv --file "./env/.env.dev" set DB_HOST="localhost"
load_vars "./env/.env.dev"

has_db=$(PGPASSWORD=root psql -U root -h localhost -XtAc "SELECT 1 FROM pg_database WHERE datname = 'dev-api'")
if [[ $has_db -ne 1 ]]
then 
    APP_ENV=dev npm run db:create
    APP_ENV=dev npm run db:migrate
    APP_ENV=dev npm run db:seed:all
fi
#change db.host = db so that we can run it inside docker compose
$SCRIPT_DIR/lib/dotenv --file "./env/.env.dev" set DB_HOST="db"

docker compose restart 

NODE_ENV=ci npm run test:ci
NODE_ENV=test npm run test

#curl http://localhost:3000/healthz/
#curl http://localhost:3000/healthz/db
#curl http://localhost:3000/healthz/redis

popd
