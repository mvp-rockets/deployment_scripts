#!/bin/bash

###################################################################
# Script Name: backup-with-jumpbox.sh
# Description: This script creates an SSH tunnel to a remote database server via a jumpbox,
#              executes a database backup using pg_dump, and then closes the tunnel.
# Author: Hitesh
# Email: hitesh.bhati@napses.com
# Date: April 17 2024
# Version: 1.0
###################################################################

# Database connection details
DB_HOST="216.48.183.200"
DB_NAME="nidanaqa"
DB_USER="nidanaqa_usr"
DB_PASSWORD='nidanaqa234'

# Append current date in DDMMYYYY format to the backup file name
TODAY=$(date +"%d%m%Y")
BACKUP_FILE="dump_$TODAY.sql"

# Jumpbox connection details
#JUMPBOX_HOST="216.48.186.43"
#PEM_FILE="/home/rentsher/Napses/nidana/scripts/keys/qa_node_2.pem"


# Tables to exclude from backup (add your excluded tables here)
EXCLUDED_TABLES=("service_requests")

# Start the SSH tunnel in the background
#ssh -L 5433:$DB_HOST:5432 -i $PEM_FILE ubuntu@$JUMPBOX_HOST -N &
#SSH_TUNNEL_PID=$!
#echo "SSH tunnel attempting to establish, PID: $SSH_TUNNEL_PID"
#export PGSSLMODE=require
# Function to clean up SSH tunnel
#cleanup() {
#    echo "Closing SSH tunnel..."
#    kill $SSH_TUNNEL_PID
#    wait $SSH_TUNNEL_PID 2>/dev/null
#    echo "SSH tunnel closed"
#}

# Trap to ensure SSH tunnel is killed on script exit
#trap cleanup EXIT

# Check if SSH tunnel was established
#if ! ps -p $SSH_TUNNEL_PID > /dev/null; then
#    echo "Failed to establish SSH tunnel"
 #   exit 1
#fi

# Wait for SSH tunnel to establish
echo "Waiting for SSH tunnel to establish..."
sleep 5

# Build exclude table options
EXCLUDE_OPTIONS=""
for table in "${EXCLUDED_TABLES[@]}"; do
    EXCLUDE_OPTIONS+=" --exclude-table-data=$table"
done

# Execute the pg_dump command
echo "Starting database backup..."
PGPASSWORD=$DB_PASSWORD pg_dump --no-owner --no-privileges --file=$BACKUP_FILE --username=$DB_USER --host=$DB_HOST --port=5432 $DB_NAME --verbose $EXCLUDE_OPTIONS
if [ $? -ne 0 ]; then
    echo "Database backup failed"
    exit 1
fi

echo "Database backup completed successfully"
