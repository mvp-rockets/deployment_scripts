#!/usr/bin/env bash
set -e

export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
export PROJECT_DIR="$SCRIPT_DIR/.."
export IDENTITY_FILE="$SCRIPT_DIR/$IDENTITY_FILE"
export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"
if [[ "$IDENTITY_FILE" != "" ]]; then
        export KEYARG="-i $IDENTITY_FILE"
else
        export KEYARG=
fi


. "$SCRIPT_DIR/incl.sh"
ssh $KEYARG $REMOTE_USER@$SERVER_NAME "mkdir -p $ROOT_DEPLOYMENT_DIR/automation_scripts"

log "database file"
sync /scripts/"$DATABASE.sql" /automation_scripts

log "syncing automation_restore_db.sh file"
sync /scripts/misc/automation_restore_db.sh /automation_scripts

log "Running automation_restore_db"
run_remote /automation_scripts "automation_restore_db.sh $DB_HOSTNAME $DB_USERNAME $DATABASE $DB_PASSWORD"