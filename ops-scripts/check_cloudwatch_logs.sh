#!/bin/bash
#
#################################################################################
# Script Name: check_cloudwatch_logs.sh
# Description: This script checks if logs are being received in specified
#              AWS CloudWatch Logs streams across multiple log groups. It retrieves 
#              the latest log event for each stream and checks if the last log 
#              was received within the specified window period in minutes.
# Author: Hitesh Bhati
# Email: hitesh.bhati@napses.com
# Version: 1.5
# Date: 2025-01-16
################################################################################

# Check if LOG_WINDOW_PERIOD argument is passed
if [ -z "$1" ]; then
    echo "Error: LOG_WINDOW_PERIOD (in minutes) argument is required."
    exit 1
fi

# Convert the LOG_WINDOW_PERIOD from minutes to seconds
LOG_WINDOW_PERIOD_MINUTES=$1
LOG_WINDOW_PERIOD_SECONDS=$((LOG_WINDOW_PERIOD_MINUTES * 60))

# Define AWS region (optional, can also be passed via environment variable)
AWS_REGION=${AWS_REGION:-"ap-south-1"}  # Default to ap-south-1 if not set

# Check if AWS credentials are provided through environment variables
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables must be set."
    exit 1
fi

# Define an array of log groups and their corresponding log streams
log_groups_and_streams=(
    '{"nidana": ["nidana"]}' 
    '{"deon": ["deon-qa"]}'
    '{"magically": ["magically-qa"]}'
    '{"circle": ["circle-qa", "circle-prod"]}'
    # Add more log groups and streams as needed
)

# Fetch the caller identity to get user details associated with the provided credentials
CALLER_ID=$(aws sts get-caller-identity --region "$AWS_REGION" --output text --query 'Arn' 2>&1)

# Check if the `aws sts get-caller-identity` command was successful
if [ $? -eq 0 ]; then
    # If successful, we print the identity (IAM user or role) associated with the credentials
    echo "Using AWS identity: $CALLER_ID"
else
    # If it fails (no role or user), use the provided access key and secret key directly
    echo "No role found, using provided access key and secret key."
fi

# Get the current time in seconds since Unix epoch (for comparison later)
CURRENT_TIME=$(date +%s)

# Red color code
RED='\033[0;31m'
# Reset color code
NC='\033[0m'  # No Color

# Loop through each log group and its associated log streams
for entry in "${log_groups_and_streams[@]}"; do
    # Extract the log group name and the log streams using `jq`
    LOG_GROUP=$(echo $entry | jq -r 'keys[0]')
    LOG_STREAMS=$(echo $entry | jq -r '.[keys[0]][]')  # Use [] to extract elements from the array

    echo "Checking logs in log group: $LOG_GROUP"
    
    # Loop through each log stream for the current log group
    for LOG_STREAM in $LOG_STREAMS; do
        echo "  Checking log stream: $LOG_STREAM"
        
        # Get the latest log event from the stream
        LATEST_LOG_EVENT=$(aws logs get-log-events \
            --log-group-name "$LOG_GROUP" \
            --log-stream-name "$LOG_STREAM" \
            --limit 1 \
            --region "$AWS_REGION" \
            --query 'events[0].timestamp' \
            --output text 2>&1)

        # Check if the AWS command was successful
        if [ $? -ne 0 ]; then
            echo "    Error: Failed to retrieve log events. Details: $LATEST_LOG_EVENT"
            continue
        fi

        # Check if the log stream has any events
        if [ "$LATEST_LOG_EVENT" == "None" ]; then
            echo "    No logs found in the stream '$LOG_STREAM' under the log group '$LOG_GROUP'."
            continue
        fi

        # Convert the latest log event timestamp into seconds
        LATEST_LOG_TIME=$(($LATEST_LOG_EVENT / 1000))

        # Calculate the time difference between the current time and the last log received
        TIME_DIFF=$((CURRENT_TIME - LATEST_LOG_TIME))

        # Print the time when the last log was received
        echo "    Last log received at $(date -d @$LATEST_LOG_TIME)"

        # Check if the last log was received within the specified window period
        if [ "$TIME_DIFF" -le "$LOG_WINDOW_PERIOD_SECONDS" ]; then
            echo "    Logs are being received within the last $LOG_WINDOW_PERIOD_MINUTES minutes."
        else
            # Print the "No logs received" message in red
            echo -e "    ${RED}No logs received in the last $LOG_WINDOW_PERIOD_MINUTES minutes.${NC}"
        fi
    done
done
