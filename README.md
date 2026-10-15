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

```
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
```

### What a deploy does on the server

- **node_modules from a store** (`remote/common/nm_store.sh`): `init_api.sh` and `init_web.sh` no longer run `npm ci` in every release. The install runs once per lockfile (key: `package-lock.json`/`pnpm-lock.yaml`, `package.json`, node version, install flags, `NODE_ENV` and npm's omit/include settings) into `~/apps/.nm-store/<project>/<key>/`, and each release gets a hard-link copy (seconds, almost no disk). Store files are read-only, so a tool that rewrites a file inside `node_modules` in place fails loudly instead of changing other releases. An app whose postinstall generates files from repo sources (e.g. Prisma) must not use the store. `deploy-web.sh` no longer rsyncs `node_modules`.
- **Health gate** (`remote/current/start_service.sh`, `remote/common/health.sh`): after pm2 starts the release, `HEALTH_URL` must answer 2xx within `HEALTH_TIMEOUT` seconds (default 60). If it doesn't, `current` goes back to the previous release, pm2 reloads it, and the deploy fails. Set `HEALTH_URL_<SERVICE>` (e.g. `HEALTH_URL_API=http://127.0.0.1:4000/api/healthz`) or `HEALTH_URL` in `env/.env.<env>`; empty means no gate.
- **Deploy events** (`remote/common/events.sh`): one JSON line per event in `/var/log/napses/deploy-events.jsonl` (`NAPSES_DEPLOY_EVENTS`): `deploy_start`, `deploy_end` (`result` success/failure, `duration_s`, `stage` on failure, `health`), `health_check`, `rollback`. Each carries app, env, service, host, sha, branch and trigger (`BITBUCKET_BUILD_NUMBER` in a pipeline, else the deployer's `git config user.email`; or set `DEPLOY_TRIGGER`). With `DORA_WEBHOOK_URL` set, each event is also POSTed there. A missing or unwritable log file only warns.
- **Secrets manifest** (`remote/common/secrets_manifest.sh`): with `scripts/secrets-manifest.json` in the project (`{"services": {"api": {"required": [...], "optional": [...]}}}`), `init_api.sh` checks the app's secret before `load-secrets`: a missing required key fails the deploy; a key no service lists fails it too, except on the first checked deploy, which only warns. The secret is read with `aws secretsmanager get-secret-value` (`AWS_SM_SECRET_ID`, with the host's AWS profile and region), or with `SECRETS_FETCH_CMD`. No manifest: a warning, not checked.
- **Cleanup** (`remote/common/clean_up_old_deployment.sh`, `release_prune.sh`): keeps the last two releases and never removes one that `deployment_history` still lists or `current` points at (a redeployed sha); removes hanging releases (failed deploys, never logged to `deployment_history`) older than `RELEASE_PRUNE_MIN_AGE_MIN` minutes (120); drops this project's store entries no kept release uses, and nothing of other projects: cleanup across projects belongs to a scheduled job on the host (`release_prune.sh --all`, then `nm_store_gc` without a project). `release_prune.sh [--dry-run] --all [apps root]` also works on its own, e.g. from a timer.
- **No deploy over the live release** (`incl.sh` `refuse_live_release`): a release directory is named by the commit, so deploying the commit `current` already points at stops with "commit the changes and deploy the new commit" instead of rsyncing over the running release.
- **Generated files** (`remote/current/.env.deploy`, a copy of the env file with its secrets, and `deploy.config.json`) are removed however the deploy ends, and git-ignored.
- **The web build** runs `npm ci` from the committed lockfile and no `npm prune`, which rewrites `package-lock.json`: the host installs from the lockfile it is sent.
- **pm2 save**: `start_service.sh` compares the apps pm2 runs (pm2 modules such as pm2-logrotate excluded) with `~/.pm2/dump.pm2` and saves only when they differ.
- **Static sites** (`static_service.sh`): no sudo. `/var/www/<project>-<env>-<service>` must exist and be writable by the deploy user (create it in the server setup), else the deploy fails with that message.

## 7. Testing

See [Readme](test/readme.md)
