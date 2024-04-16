- [1. Introduction](#1-introduction)
- [2. Pre-requirement](#2-pre-requirement)
- [3. Updating variables](#3-updating-variables)
- [4. How to run](#4-how-to-run)

## 1. Introduction

Bash scripts for deployment of node.js api and next.js web.

## 2. Pre-requirement
- Ubuntu 22.04 LTS
- The server already has nvm, node & pm2 installed. See [install.sh](test/install.sh) for reference

## 3. Updating variables

1. Run `./env.sh --env <name> --create` to create a new environment. 
  For e.g. `./env.sh --env qa --create` 
2. Update the `./env/.env.qa`, `../api/env/.env.qa` and ../web/env/.env.qa` with your application specific configurations

## 4. How to run

```
./deploy.sh :env

examples
./deploy.sh qa --> will deploy both api and web to qa
./deploy.sh uat --> will deploy both api and web to uat
./deploy.sh production --> will deploy both api and web to production

deploy either api or web
./deploy.sh qa api --> will deploy only api to qa
./deploy.sh qa web --> will deploy only web to qa
```

