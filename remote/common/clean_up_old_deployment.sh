#!/usr/bin/env bash
# Runs in the service directory after each deploy: keep the last two releases, remove
# hanging releases (failed deploys that never reached deployment_history), then drop
# this project's node_modules store entries no kept release uses (nm_store_gc). Only this
# service's releases and this project's store: other projects are left to node_runtime's
# scheduled release-prune job.
# shellcheck source-path=SCRIPTDIR
set -e
# <apps root>/<project>/<env>/<service>
svc=$(pwd -P)
project=$(basename "$(dirname "$(dirname "$svc")")")
apps=$(dirname "$(dirname "$(dirname "$svc")")")
nos=$(wc -l < deployment_history)
if [ "$nos" -gt 2 ]
then
  deployment_to_delete=$(head -n 1 deployment_history)
  sed -i "1d" deployment_history
  # A redeployed sha is listed twice (A B A): keep its release while the history still
  # names it or current points at it.
  if ! grep -qxF "$deployment_to_delete" deployment_history \
     && [ "$(readlink -f current)" != "$svc/releases/$deployment_to_delete" ]
  then
    rm -rf "releases/$deployment_to_delete"
  fi
fi
./release_prune.sh .
# shellcheck source=nm_store.sh
. ./nm_store.sh
nm_store_gc "$apps" "$project"
