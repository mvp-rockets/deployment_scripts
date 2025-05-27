- [1. Introduction](#1-introduction)
- [2. Pre-requirement](#2-pre-requirement)
- [3. Updating variables](#3-updating-variables)
- [4. How to run](#4-how-to-run)
- [5. Other commands](#5-other-scripts)
- [6. Understanding the design](#6-understanding-the-design)
- [7. Testing](#7-testing)

## 1. Introduction

This is a standard boilerplate deployment script, that is used for deploying node applications on an EC2 instance.
The script works on a standardized Ubuntu instance. It uses bash for all it's operation. 

## 2. Pre-requirement

- Target server should be Ubuntu LTS version. Currently we are running it on Ubuntu 24.04 LTS
- The server should have the pre-requisite software already installed. See [install.sh](./install.sh) as reference cloud-init script
  - nvm (used for managing node version)
  - node (obvious)
  - jq (to handle json in bash)
  - pm2 (process management for node applications)
  - aws cli (deployment in AWS environment)
- The client should be a Ubuntu or Linux machine with Bash. MacOS also should work.
- The client machine should have the following installed. You can use [bootstrap-dev.sh](./bootstrap-dev.sh) to ensure everything is setup correctly
  - nvm (used for managing node version)
  - node (obvious)
  - jq (to handle json in bash)
  - pm2 (process management for node applications)
  - aws cli (deployment in AWS environment)
  - rsync (sync files from client to server over ssh)

- For local testing of scripts
  - Vagrant
  - Docker

## 3. Managing Environments


## 4. How to run

```
./deploy.sh <env> <service-name>

examples
./deploy.sh qa --> will deploy both api and web to qa
./deploy.sh uat --> will deploy both api and web to uat
./deploy.sh production --> will deploy both api and web to production

deploy either api or web
./deploy.sh qa api --> will deploy only api to qa
./deploy.sh qa web --> will deploy only web to qa

```

## 5. Other scripts

deploy.sh
:
bootstrap-dev.sh
:
cleanup.sh
:
connect.sh
:
env.sh
:
install.sh
:
manual-smoke-test.sh
:
update_node.sh
:

## 6. Understanding the implementation

Folder structure and their contents:

├── env                              - Contains all environment definitions and their respective variable values in standard .env files
├── lib                              - Helper scripts. Currently for manipulating and reading env files
├── misc                             - Util scripts. For installing dependencies, syncing to s3, setup ques, ...
├── prod-testing
├── remote                           - This folder contains scripts that are used on the remote server during deployments
│   ├── common                       - Common scripts for managing multiple versions of deployments
│   └── current                      - Scripts for deploying a specific service type, for e.g. web or api
└── test                             - Test scripts to validate and or test the bash scripts.
    ├── aws-config                   - Credential files for localstack used by `aws config`.
    ├── pm2-config                   - Example services.json files used to test the generation of pm2 config files
    └── remote
        └── current                  - Used by the test scripts

## 7. Testing

See [Readme](test/readme.md)
