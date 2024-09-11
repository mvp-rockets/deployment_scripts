- [1. Introduction](#1-introduction)
- [2. Pre-requirement](#2-pre-requirement)
- [3. Updating variables](#3-updating-variables)
- [4. How to run](#4-how-to-run)
- [5. Authors/maintainers/contributors](#5-authorsmaintainerscontributors)

## 1. Introduction

Boilerplate codes for deployment api and web.

## 2. Pre-requirement
- Ubuntu 20.04.4 LTS

## 3. Updating variables


1. Update ./env/.env.qa,./env/.env.uat,./env/.env.prod
with your configurations.
2. Update API_PROJECT_FOLDER_NAME variable inside ./deploy-api.sh with your api project name.
3. Update UI_PROJECT_FOLDER_NAME variable inside ./deploy-web.sh with your ui project name.

## 4. How to run

```
./deploy.sh :env

examples
./deploy.sh qa --> will deploy both api and web to qa
./deploy.sh uat --> will deploy both api and web to uat
./deploy.sh prod --> will deploy both api and web to prod

deploy either api or web
./deploy.sh qa api --> will deploy only api to qa
./deploy.sh qa web --> will deploy only web to qa



```

## 5. Authors/maintainers/contributors

- Yashjeet Luthra (yash@napses.com)
