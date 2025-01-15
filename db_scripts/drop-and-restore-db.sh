#!/bin/bash

###################################################################
# Script Name: drop-and-restore_db.sh
# Description: This script drops an existing database, creates a new
#              one, and restores a backup file to the new database.
# Author: Hitesh
# Email: hitesh.bhati@napses.com
# Date: April 17 2024
# Version: 1.0
###################################################################

#!/bin/bash

# Database variables
DB_HOST="127.0.0.1"
DB_NAME="nidana-test"
DB_USER="root"
DB_PASSWORD="root"
BACKUP_FILE="/home/rentsher/Downloads/nidana-qa-dump.sql"

# Terminate all connections to the database
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME';"
if [ $? -ne 0 ]; then
    echo "Failed to terminate connections to the database."
    exit 1
fi

# Drop the database if it exists
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
if [ $? -ne 0 ]; then
    echo "Failed to drop the database."
    exit 1
fi

# Execute the psql command to create the database
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d postgres -c "create database \"$DB_NAME\" with owner $DB_USER;"
if [ $? -ne 0 ]; then
    echo "Failed to create the database."
    exit 1
fi

# Restore the backup file to the newly created database
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" < "$BACKUP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to restore the backup file."
    exit 1
fi

echo "Backup restoration completed successfully."
