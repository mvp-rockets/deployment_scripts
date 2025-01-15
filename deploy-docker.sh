#!/usr/bin/env bash
set -e

if [[ $DEPLOY_MODE == "docker" ]];
then
  project_name=$(jq -c -r '.projectName' $PROJECT_DIR/services.json)
  image_name="$project_name-$DEPLOY_SERVICE"
  tag="latest"

  cd "$PROJECT_DIR/$DEPLOY_SERVICE/"

  docker run --rm -i hadolint/hadolint < "$PROJECT_DIR/$DEPLOY_SERVICE/Dockerfile"
  #docker run --rm -i ghcr.io/hadolint/hadolint < Dockerfile

  DOCKER_BUILDKIT=1 docker buildx build "$PROJECT_DIR/$DEPLOY_SERVICE/" -t "$image_name:v1.0"

  snyk container test node:20.12.2-bookworm-slim --file=Dockerfile --exclude-base-image-vulns
  echo "To execute the container locally"
  echo "docker run --rm --env-file ""../$DEPLOY_SERVICE/env/.env.$APP_ENV" "--network=\"host\"" "$image_name"
  # TODO: Build Tags. Additionally handle ACR, Docker Hub, GCP Artifact Registry, Azure Container Registry, E2E

  #docker image prune -a --force
  docker image prune --force
fi

#webapp
#docker run -d -p3002:3002 --name "$project_name-$DEPLOY_SERVICE" "$image_name:tag"
#api
#docker run -d -p3000:3000 --name "$project_name-$DEPLOY_SERVICE" "$image_name:tag"
