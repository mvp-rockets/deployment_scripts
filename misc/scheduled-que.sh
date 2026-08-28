#!/usr/bin/env bash
# Idempotent EventBridge Scheduler -> SQS reminder pipeline setup.
# Creates the reminder queue (+ DLQ), schedule group, scheduler execution
# role, grants the environment's IAM user the permissions it needs to
# manage schedules/consume the queue, and syncs the resulting values into
# AWS Secrets Manager.
#
# See ../../reminder-scheduler-aws-setup.md for the resources this produces.
#
# Usage: ./scheduled-que.sh --env <environment>
# Prerequisites: AWS_PROFILE must be set with sufficient IAM permissions.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../../" &> /dev/null && pwd )"

# ──────────────────────────────────────────────────────────
# Arguments
# ──────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 --env <environment>"
    echo "  --env, -e   Target environment (e.g., qa, uat, production)"
    exit 1
}

ENV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env|-e) ENV="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -z "$ENV" ]] && usage

# ──────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────
PROJECT_NAME=$(jq -r '.projectName' "$PROJECT_DIR/services.json")
ENV_FILE="$PROJECT_DIR/scripts/env/.env.$ENV"
# NOTE: scripts/env.sh's update_secrets() writes its own scratch file to a
# relative "new-secrets.json" in the caller's cwd, which collides with (and
# truncates) that exact filename if it's also used as the --file input from
# the project root. Use a name that can't collide.
SECRETS_FILE="$PROJECT_DIR/scheduled-que-secrets.json"

[[ ! -f "$ENV_FILE" ]] && { echo "Error: env file not found: $ENV_FILE"; exit 1; }

_env_var() {
    grep -E "^${1}=" "$ENV_FILE" | head -1 | cut -d'=' -f2- | sed "s/['\"]//g" || true
}

SM_REGION=$(_env_var "AWS_SM_REGION")
REGION="${SM_REGION:-ap-south-1}"
SM_ACCESS_KEY_ID=$(_env_var "AWS_SM_ACCESS_KEY_ID")
SM_SECRET_ACCESS_KEY=$(_env_var "AWS_SM_SECRET_ACCESS_KEY_ID")

# Resolve the secret ID from env file
SECRET_ID="$PROJECT_NAME-$ENV-api-keys"
_sm_id=$(_env_var "AWS_SM_SECRET_ID")
[[ -n "$_sm_id" ]] && SECRET_ID="$_sm_id"

# Prefer dedicated reminder-scheduler credentials from Secrets Manager if they already exist
EXISTING_SECRETS=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString --output text 2>/dev/null || echo "{}")

REMINDER_ACCESS_KEY_ID=$(echo "$EXISTING_SECRETS" | jq -r '.REMINDER_SCHEDULER_ACCESS_KEY_ID // empty' 2>/dev/null || true)
REMINDER_SECRET_KEY=$(echo "$EXISTING_SECRETS"     | jq -r '.REMINDER_SCHEDULER_SECRET_KEY      // empty' 2>/dev/null || true)

# Fall back to the shared SM user credentials
if [[ -z "$REMINDER_ACCESS_KEY_ID" ]]; then
    REMINDER_ACCESS_KEY_ID="$SM_ACCESS_KEY_ID"
    REMINDER_SECRET_KEY="$SM_SECRET_ACCESS_KEY"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Project : $PROJECT_NAME"
echo "Env     : $ENV"
echo "Region  : $REGION"
echo "Account : $ACCOUNT_ID"

DLQ_NAME="$PROJECT_NAME-reminder-fire-dlq"
QUEUE_NAME="$PROJECT_NAME-reminder-fire"
SCHEDULE_GROUP_NAME="$PROJECT_NAME-reminders"
SCHEDULER_ROLE_NAME="$PROJECT_NAME-reminder-scheduler-role"
SCHEDULER_ROLE_POLICY_NAME="send-to-reminder-queue"
USER_POLICY_NAME="$PROJECT_NAME-reminder-scheduler-access"

# ──────────────────────────────────────────────────────────
# Helper: get queue URL (returns empty string if not found)
# ──────────────────────────────────────────────────────────
_queue_url() {
    aws sqs get-queue-url \
        --queue-name "$1" \
        --region "$REGION" \
        --query QueueUrl --output text 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────
# Step 1 – Dead Letter Queue
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Dead Letter Queue ==="

DLQ_URL=$(_queue_url "$DLQ_NAME")

if [[ -z "$DLQ_URL" ]]; then
    echo "Creating DLQ: $DLQ_NAME"
    DLQ_URL=$(aws sqs create-queue \
        --queue-name "$DLQ_NAME" \
        --region "$REGION" \
        --query QueueUrl --output text)
    echo "Created: $DLQ_URL"
else
    echo "DLQ already exists: $DLQ_URL"
fi

DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --query Attributes.QueueArn --output text)
echo "DLQ ARN: $DLQ_ARN"

REDRIVE_POLICY_STR=$(jq -cn --arg arn "$DLQ_ARN" '{"deadLetterTargetArn":$arn,"maxReceiveCount":3}')

# ──────────────────────────────────────────────────────────
# Step 2 – Reminder queue (create if missing, attach DLQ if needed)
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Reminder Queue ==="

QUEUE_URL=$(_queue_url "$QUEUE_NAME")

if [[ -z "$QUEUE_URL" ]]; then
    echo "Creating with DLQ attached: $QUEUE_NAME"
    CREATE_ATTRS=$(jq -cn --arg rp "$REDRIVE_POLICY_STR" '{"VisibilityTimeout":"60","RedrivePolicy":$rp}')
    QUEUE_URL=$(aws sqs create-queue \
        --queue-name "$QUEUE_NAME" \
        --region "$REGION" \
        --attributes "$CREATE_ATTRS" \
        --query QueueUrl --output text)
    echo "Created: $QUEUE_URL"
else
    echo "Already exists: $QUEUE_URL"

    CURRENT_REDRIVE=$(aws sqs get-queue-attributes \
        --queue-url "$QUEUE_URL" \
        --attribute-names RedrivePolicy \
        --region "$REGION" \
        --query 'Attributes.RedrivePolicy' \
        --output text 2>/dev/null || true)

    CURRENT_DLQ_ARN=""
    if [[ -n "$CURRENT_REDRIVE" && "$CURRENT_REDRIVE" != "None" ]]; then
        CURRENT_DLQ_ARN=$(echo "$CURRENT_REDRIVE" | jq -r '.deadLetterTargetArn // empty' 2>/dev/null || true)
    fi

    if [[ "$CURRENT_DLQ_ARN" == "$DLQ_ARN" ]]; then
        echo "DLQ already correctly attached"
    else
        echo "-> Attaching / updating DLQ"
        UPDATE_ATTRS=$(jq -cn --arg rp "$REDRIVE_POLICY_STR" '{"RedrivePolicy":$rp}')
        aws sqs set-queue-attributes \
            --queue-url "$QUEUE_URL" \
            --attributes "$UPDATE_ATTRS" \
            --region "$REGION"
        echo "DLQ attached"
    fi
fi

QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --query Attributes.QueueArn --output text)
echo "Queue ARN: $QUEUE_ARN"

# ──────────────────────────────────────────────────────────
# Step 3 – Schedule group
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Schedule Group ==="

if aws scheduler get-schedule-group --name "$SCHEDULE_GROUP_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "Already exists: $SCHEDULE_GROUP_NAME"
else
    echo "Creating: $SCHEDULE_GROUP_NAME"
    aws scheduler create-schedule-group --name "$SCHEDULE_GROUP_NAME" --region "$REGION" >/dev/null
    echo "Created"
fi

# ──────────────────────────────────────────────────────────
# Step 4 – Scheduler execution role (assumed by EventBridge Scheduler)
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Scheduler Execution Role ==="

ASSUME_ROLE_POLICY=$(jq -cn '{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "scheduler.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}')

if aws iam get-role --role-name "$SCHEDULER_ROLE_NAME" >/dev/null 2>&1; then
    ROLE_ARN=$(aws iam get-role --role-name "$SCHEDULER_ROLE_NAME" --query Role.Arn --output text)
    echo "Already exists: $ROLE_ARN"
else
    ROLE_ARN=$(aws iam create-role \
        --role-name "$SCHEDULER_ROLE_NAME" \
        --assume-role-policy-document "$ASSUME_ROLE_POLICY" \
        --query Role.Arn --output text)
    echo "Created: $ROLE_ARN"
fi

# Trust policy and inline permissions are single-purpose (this role isn't
# shared with anything else), so it's safe to unconditionally overwrite
# them each run rather than diff-and-skip.
aws iam update-assume-role-policy --role-name "$SCHEDULER_ROLE_NAME" --policy-document "$ASSUME_ROLE_POLICY"

ROLE_POLICY_DOC=$(jq -cn --arg arn "$QUEUE_ARN" '{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "sqs:SendMessage",
        "Resource": $arn
    }]
}')
aws iam put-role-policy \
    --role-name "$SCHEDULER_ROLE_NAME" \
    --policy-name "$SCHEDULER_ROLE_POLICY_NAME" \
    --policy-document "$ROLE_POLICY_DOC"
echo "Role policy '$SCHEDULER_ROLE_POLICY_NAME' up to date"

# ──────────────────────────────────────────────────────────
# Step 5 – Grant the API's IAM user permission to manage schedules /
# consume the queue
# ──────────────────────────────────────────────────────────
echo ""
echo "=== IAM Permissions ==="

IAM_USERNAME=$(aws iam get-access-key-last-used \
    --access-key-id "$REMINDER_ACCESS_KEY_ID" \
    --query 'UserName' --output text 2>/dev/null || true)

if [[ -z "$IAM_USERNAME" || "$IAM_USERNAME" == "None" ]]; then
    echo "Warning: could not resolve IAM user for access key $REMINDER_ACCESS_KEY_ID — skipping policy attachment"
else
    echo "IAM user: $IAM_USERNAME"

    SCHEDULE_ARN="arn:aws:scheduler:$REGION:$ACCOUNT_ID:schedule/$SCHEDULE_GROUP_NAME/*"

    USER_POLICY_DOC=$(jq -cn \
        --arg schedule_arn "$SCHEDULE_ARN" \
        --arg role_arn "$ROLE_ARN" \
        --arg queue_arn "$QUEUE_ARN" \
        '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": ["scheduler:CreateSchedule", "scheduler:DeleteSchedule", "scheduler:UpdateSchedule", "scheduler:GetSchedule"],
                    "Resource": $schedule_arn
                },
                {
                    "Effect": "Allow",
                    "Action": "iam:PassRole",
                    "Resource": $role_arn,
                    "Condition": {"StringEquals": {"iam:PassedToService": "scheduler.amazonaws.com"}}
                },
                {
                    "Effect": "Allow",
                    "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
                    "Resource": $queue_arn
                }
            ]
        }')

    # Use a customer-managed policy rather than an inline (put-user-policy)
    # policy. IAM users are frequently shared across services/projects in
    # this account, and the aggregate size of all inline policies on a
    # single user is capped at 2048 bytes (a hard limit, not adjustable via
    # Service Quotas). Managed policies (6144 bytes each, up to 10
    # attachable per user by default) avoid that shared cap.
    POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$USER_POLICY_NAME"

    # Sort statement Resource arrays (and all object keys) so equivalent
    # policies compare equal regardless of ordering.
    _normalize_policy_doc() {
        jq -cS '.Statement |= map(.Resource |= (if type == "array" then sort else . end))'
    }

    if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
        DEFAULT_VERSION_ID=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
        CURRENT_DOC_JSON=$(aws iam get-policy-version \
            --policy-arn "$POLICY_ARN" \
            --version-id "$DEFAULT_VERSION_ID" \
            --query 'PolicyVersion.Document' --output json)

        if [[ "$(echo "$CURRENT_DOC_JSON" | _normalize_policy_doc)" == "$(echo "$USER_POLICY_DOC" | _normalize_policy_doc)" ]]; then
            echo "Managed policy already up to date ($DEFAULT_VERSION_ID) — skipping"
        else
            echo "Managed policy exists but is out of date — publishing new version"

            # A managed policy keeps at most 5 versions; prune the oldest
            # non-default version before adding a new one if we're at the cap.
            VERSIONS_JSON=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions' --output json)
            VERSION_COUNT=$(echo "$VERSIONS_JSON" | jq 'length')
            if [[ "$VERSION_COUNT" -ge 5 ]]; then
                OLDEST_VERSION_ID=$(echo "$VERSIONS_JSON" | jq -r '[.[] | select(.IsDefaultVersion == false)] | sort_by(.CreateDate) | .[0].VersionId')
                echo "Pruning oldest policy version: $OLDEST_VERSION_ID"
                aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST_VERSION_ID"
            fi

            aws iam create-policy-version \
                --policy-arn "$POLICY_ARN" \
                --policy-document "$USER_POLICY_DOC" \
                --set-as-default >/dev/null
        fi
    else
        echo "Creating managed policy: $USER_POLICY_NAME"
        POLICY_ARN=$(aws iam create-policy \
            --policy-name "$USER_POLICY_NAME" \
            --policy-document "$USER_POLICY_DOC" \
            --query 'Policy.Arn' --output text)
    fi

    aws iam attach-user-policy --user-name "$IAM_USERNAME" --policy-arn "$POLICY_ARN"
    echo "Policy '$USER_POLICY_NAME' attached to $IAM_USERNAME"
fi

# ──────────────────────────────────────────────────────────
# Step 6 – Generate secrets file
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Generating $SECRETS_FILE ==="

SECRETS_JSON=$(jq -cn \
    --arg mode    "eventbridge" \
    --arg region  "$REGION" \
    --arg akid    "$REMINDER_ACCESS_KEY_ID" \
    --arg ak      "$REMINDER_SECRET_KEY" \
    --arg group   "$SCHEDULE_GROUP_NAME" \
    --arg role    "$ROLE_ARN" \
    --arg qurl    "$QUEUE_URL" \
    --arg qarn    "$QUEUE_ARN" \
    '{
        "REMINDER_SCHEDULER_MODE":       $mode,
        "REMINDER_SCHEDULER_REGION":     $region,
        "REMINDER_SCHEDULER_ACCESS_KEY_ID": $akid,
        "REMINDER_SCHEDULER_SECRET_KEY": $ak,
        "REMINDER_SCHEDULER_GROUP_NAME": $group,
        "REMINDER_SCHEDULER_ROLE_ARN":   $role,
        "REMINDER_QUEUE_URL":            $qurl,
        "REMINDER_QUEUE_ARN":            $qarn
    }')

echo "$SECRETS_JSON" | jq '.' > "$SECRETS_FILE"
echo "Written: $SECRETS_FILE"

# ──────────────────────────────────────────────────────────
# Step 7 – Import secrets into AWS Secrets Manager
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Importing secrets into Secrets Manager ($ENV) ==="
"$PROJECT_DIR/scripts/env.sh" --env "$ENV" --secrets --update --file "$SECRETS_FILE"
echo "Done."

# ──────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "Region          : $REGION"
echo "DLQ             : $DLQ_NAME"
echo "Queue           : $QUEUE_NAME"
echo "Schedule group  : $SCHEDULE_GROUP_NAME"
echo "Scheduler role  : $ROLE_ARN"
echo ""
echo "Secrets file written to: $SECRETS_FILE"
echo "Secrets Manager updated for env: $ENV"
