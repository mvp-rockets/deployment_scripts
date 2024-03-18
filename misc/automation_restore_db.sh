#!/usr/bin/env bash
set -e

DB_HOSTNAME=$1
DB_USERNAME=$2
DATABASE=$3
DB_PASSWORD=$4

export PGPASSWORD="$DB_PASSWORD"
echo "Terminating active connections"
psql -h $DB_HOSTNAME -U $DB_USERNAME   -c "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '$DATABASE'"
echo "Terminatiated active connections"
echo "Dropping db $DATABASE"
psql -h $DB_HOSTNAME -U $DB_USERNAME   -c "drop database  $DATABASE"
echo  "$DATABASE dropped "
echo  "Creating db $DATABASE "
psql -h $DB_HOSTNAME -U $DB_USERNAME    -c "create database  $DATABASE"
echo "$DATABASE created"


echo  "Restoring db $DATABASE "
psql -h $DB_HOSTNAME -U $DB_USERNAME  -d $DATABASE  -f  "$DATABASE".sql
echo "$DATABASE restored"


psql -h $DB_HOSTNAME -U $DB_USERNAME -c "ALTER DATABASE $DATABASE  OWNER to trumo_automation_user"
#granting access
echo "Granting access $DATABASE"
psql -h $DB_HOSTNAME -U $DB_USERNAME -c "GRANT ALL PRIVILEGES ON DATABASE $DATABASE to trumo_automation_user"
echo "Access Granted"
unset PGPASSWORD

