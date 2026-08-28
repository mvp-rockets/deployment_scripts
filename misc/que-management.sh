#!/usr/bin/env bash
# Idempotent SQS queue management script.
# Creates queues defined in the awsSQS config, attaches a shared DLQ,
# grants the environment's IAM user SQS permissions, and syncs the
# resulting URLs into AWS Secrets Manager.
#
# Usage: ./que-management.sh --env <environment>
# Prerequisites: AWS_PROFILE must be set with sufficient IAM permissions.
set -euo pipefail

# The api/src/config/aws.config.ts should have the following awsSQS config object
#
#     awsSQS: {
#		accessKeyId: process.env.AWS_SQS_ACCESS_KEY_ID,
#		secretKeyId: process.env.AWS_SQS_SECRET_ACCESS_KEY_ID,
#		region: process.env.AWS_SQS_REGION,
#		url: process.env.AWS_SQS_BASE_URL,
#		arn: process.env.AWS_SQS_BASE_ARN,
#		deadLetterQueue: process.env.AWS_SQS_DEAD_LETTER_QUEUE,
#		queues: {
#			"<que-1>": process.env.AWS_SQS_<que-1> ,
#			"<que-2>": process.env.AWS_SQS_<que-2> ,
#			"<que-3>": process.env.AWS_SQS_<que-3> ,
#		}
#     }
#

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
SECRETS_FILE="$PROJECT_DIR/new-secrets.json"

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

# Prefer dedicated SQS credentials from Secrets Manager if they already exist
EXISTING_SECRETS=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString --output text 2>/dev/null || echo "{}")

SQS_ACCESS_KEY_ID=$(echo "$EXISTING_SECRETS" | jq -r '.AWS_SQS_ACCESS_KEY_ID // empty' 2>/dev/null || true)
SQS_SECRET_KEY=$(echo "$EXISTING_SECRETS"     | jq -r '.AWS_SQS_SECRET_ACCESS_KEY_ID      // empty' 2>/dev/null || true)

# Fall back to the shared SM user credentials
if [[ -z "$SQS_ACCESS_KEY_ID" ]]; then
    SQS_ACCESS_KEY_ID="$SM_ACCESS_KEY_ID"
    SQS_SECRET_KEY="$SM_SECRET_ACCESS_KEY"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Project : $PROJECT_NAME"
echo "Env     : $ENV"
echo "Region  : $REGION"
echo "Account : $ACCOUNT_ID"

# ──────────────────────────────────────────────────────────
# Queue definitions – read dynamically from api/src/config/
# ──────────────────────────────────────────────────────────
# Uses Node.js to brace-match the queues:{} block inside awsSQS and
# emit "queue-key<TAB>ENV_SUFFIX" lines.  Developers update the
# TypeScript config; this script picks up changes automatically.

CONFIG_DIR="$PROJECT_DIR/api/src/config"

# Activate the Node version declared in api/.nvmrc
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck source=/dev/null
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
(cd "$PROJECT_DIR/api" && nvm use --silent)

_extract_queues() {
    node - "$CONFIG_DIR" <<'NODEJS'
const fs   = require('fs');
const path = require('path');
const dir  = process.argv[2];

const files = fs.readdirSync(dir).filter(f => f.endsWith('.ts'));

for (const file of files) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');

    // Locate the awsSQS block
    const sqsIdx = src.indexOf('awsSQS');
    if (sqsIdx === -1) continue;

    // Locate the queues: key inside awsSQS
    const queuesIdx = src.indexOf('queues', sqsIdx);
    if (queuesIdx === -1) continue;

    // Find the opening brace of the queues object
    const openBrace = src.indexOf('{', queuesIdx);
    if (openBrace === -1) continue;

    // Walk forward to find the matching closing brace
    let depth = 1, pos = openBrace + 1;
    while (pos < src.length && depth > 0) {
        if (src[pos] === '{') depth++;
        else if (src[pos] === '}') depth--;
        pos++;
    }
    const queuesBlock = src.slice(openBrace + 1, pos - 1);

    // Extract: "queue-key": process.env.AWS_SQS_SUFFIX
    const re = /["'`]([^"'`]+)["'`]\s*:\s*process\.env\.AWS_SQS_(\w+)/g;
    let m, found = false;
    while ((m = re.exec(queuesBlock)) !== null) {
        process.stdout.write(m[1] + '\t' + m[2] + '\n');
        found = true;
    }
    if (found) process.exit(0);
}

process.stderr.write(
    'Error: awsSQS.queues not found in ' + dir + '\n' +
    'Add an awsSQS block to api/src/config/aws.config.ts first.\n'
);
process.exit(1);
NODEJS
}

QUEUE_DEFS=$(_extract_queues)
if [[ -z "$QUEUE_DEFS" ]]; then
    echo "Error: No queues extracted from $CONFIG_DIR — aborting."
    exit 1
fi

QUEUE_KEYS=()
QUEUE_ENV_SUFFIXES=()
while IFS=$'\t' read -r key suffix; do
    [[ -n "$key" && -n "$suffix" ]] || continue
    QUEUE_KEYS+=("$key")
    QUEUE_ENV_SUFFIXES+=("$suffix")
done <<< "$QUEUE_DEFS"

echo "Queues loaded from config (${#QUEUE_KEYS[@]}):"
for i in "${!QUEUE_KEYS[@]}"; do
    echo "  ${QUEUE_KEYS[$i]}  →  AWS_SQS_${QUEUE_ENV_SUFFIXES[$i]}"
done

DLQ_NAME="$PROJECT_NAME-$ENV-dlq"

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

# Build the RedrivePolicy JSON string that SQS expects as an escaped string value
REDRIVE_POLICY_STR=$(jq -cn --arg arn "$DLQ_ARN" '{"deadLetterTargetArn":$arn,"maxReceiveCount":3}')

# ──────────────────────────────────────────────────────────
# Step 2 – Work queues (create if missing, attach DLQ if needed)
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Work Queues ==="

declare -a QUEUE_URLS=()

for i in "${!QUEUE_KEYS[@]}"; do
    QUEUE_KEY="${QUEUE_KEYS[$i]}"
    QUEUE_NAME="$PROJECT_NAME-$ENV-$QUEUE_KEY"

    echo ""
    echo "Queue: $QUEUE_NAME"

    QUEUE_URL=$(_queue_url "$QUEUE_NAME")

    if [[ -z "$QUEUE_URL" ]]; then
        echo "  → Creating with DLQ attached"
        CREATE_ATTRS=$(jq -cn \
            --arg rp "$REDRIVE_POLICY_STR" \
            '{"VisibilityTimeout":"60","RedrivePolicy":$rp}')
        QUEUE_URL=$(aws sqs create-queue \
            --queue-name "$QUEUE_NAME" \
            --region "$REGION" \
            --attributes "$CREATE_ATTRS" \
            --query QueueUrl --output text)
        echo "  Created: $QUEUE_URL"
    else
        echo "  Already exists: $QUEUE_URL"

        # Check whether DLQ is already attached and pointing to our DLQ
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
            echo "  DLQ already correctly attached"
        else
            echo "  → Attaching / updating DLQ"
            UPDATE_ATTRS=$(jq -cn --arg rp "$REDRIVE_POLICY_STR" '{"RedrivePolicy":$rp}')
            aws sqs set-queue-attributes \
                --queue-url "$QUEUE_URL" \
                --attributes "$UPDATE_ATTRS" \
                --region "$REGION"
            echo "  DLQ attached"
        fi
    fi

    QUEUE_URLS+=("$QUEUE_URL")
done

# ──────────────────────────────────────────────────────────
# Step 3 – Grant SQS permissions to the IAM user
# ──────────────────────────────────────────────────────────
echo ""
echo "=== IAM Permissions ==="

IAM_USERNAME=$(aws iam get-access-key-last-used \
    --access-key-id "$SQS_ACCESS_KEY_ID" \
    --query 'UserName' --output text 2>/dev/null || true)

if [[ -z "$IAM_USERNAME" || "$IAM_USERNAME" == "None" ]]; then
    echo "Warning: could not resolve IAM user for access key $SQS_ACCESS_KEY_ID — skipping policy attachment"
else
    echo "IAM user: $IAM_USERNAME"

    # Build the resource ARN list
    ARNS_JSON="$(jq -cn --arg dlq "$DLQ_ARN" '[$dlq]')"
    for QUEUE_KEY in "${QUEUE_KEYS[@]}"; do
        QUEUE_ARN="arn:aws:sqs:$REGION:$ACCOUNT_ID:$PROJECT_NAME-$ENV-$QUEUE_KEY"
        ARNS_JSON=$(echo "$ARNS_JSON" | jq --arg arn "$QUEUE_ARN" '. + [$arn]')
    done

    POLICY_DOC=$(jq -cn --argjson resources "$ARNS_JSON" '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": [
                "sqs:SendMessage",
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes"
            ],
            "Resource": $resources
        }]
    }')

    # Use a customer-managed policy rather than an inline (put-user-policy)
    # policy. IAM users are frequently shared across services/projects in
    # this account, and the aggregate size of all inline policies on a
    # single user is capped at 2048 bytes (a hard limit, not adjustable via
    # Service Quotas) — a couple of projects' worth of queue ARNs is enough
    # to exceed it. Managed policies (6144 bytes each, up to 10 attachable
    # per user by default) avoid that shared cap.
    POLICY_NAME="$PROJECT_NAME-$ENV-sqs-access"
    POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

    # Sort statement Resource arrays (and all object keys) so equivalent
    # policies compare equal regardless of ARN ordering or key ordering.
    _normalize_policy_doc() {
        jq -cS '.Statement |= map(.Resource |= (if type == "array" then sort else . end))'
    }

    if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
        DEFAULT_VERSION_ID=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
        CURRENT_DOC_JSON=$(aws iam get-policy-version \
            --policy-arn "$POLICY_ARN" \
            --version-id "$DEFAULT_VERSION_ID" \
            --query 'PolicyVersion.Document' --output json)

        if [[ "$(echo "$CURRENT_DOC_JSON" | _normalize_policy_doc)" == "$(echo "$POLICY_DOC" | _normalize_policy_doc)" ]]; then
            echo "  Managed policy already up to date ($DEFAULT_VERSION_ID) — skipping"
        else
            echo "  Managed policy exists but is out of date — publishing new version"

            # A managed policy keeps at most 5 versions; prune the oldest
            # non-default version before adding a new one if we're at the cap.
            VERSIONS_JSON=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions' --output json)
            VERSION_COUNT=$(echo "$VERSIONS_JSON" | jq 'length')
            if [[ "$VERSION_COUNT" -ge 5 ]]; then
                OLDEST_VERSION_ID=$(echo "$VERSIONS_JSON" | jq -r '[.[] | select(.IsDefaultVersion == false)] | sort_by(.CreateDate) | .[0].VersionId')
                echo "  Pruning oldest policy version: $OLDEST_VERSION_ID"
                aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST_VERSION_ID"
            fi

            aws iam create-policy-version \
                --policy-arn "$POLICY_ARN" \
                --policy-document "$POLICY_DOC" \
                --set-as-default >/dev/null
        fi
    else
        echo "  Creating managed policy: $POLICY_NAME"
        POLICY_ARN=$(aws iam create-policy \
            --policy-name "$POLICY_NAME" \
            --policy-document "$POLICY_DOC" \
            --query 'Policy.Arn' --output text)
    fi

    aws iam attach-user-policy --user-name "$IAM_USERNAME" --policy-arn "$POLICY_ARN"
    echo "Policy '$POLICY_NAME' attached to $IAM_USERNAME"
fi

# ──────────────────────────────────────────────────────────
# Step 4 – Generate new-secrets.json
# ──────────────────────────────────────────────────────────
echo ""
echo "=== Generating $SECRETS_FILE ==="

# Base URL/ARN prefixes – the API combines these with the queue name at runtime
SQS_BASE_URL="https://sqs.${REGION}.amazonaws.com/${ACCOUNT_ID}"
SQS_BASE_ARN="arn:aws:sqs:${REGION}:${ACCOUNT_ID}"

SECRETS_JSON=$(jq -cn \
    --arg akid    "$SQS_ACCESS_KEY_ID" \
    --arg ak      "$SQS_SECRET_KEY" \
    --arg region  "$REGION" \
    --arg url     "$SQS_BASE_URL" \
    --arg arn     "$SQS_BASE_ARN" \
    --arg dlq     "$DLQ_NAME" \
    '{
        "AWS_SQS_ACCESS_KEY_ID":     $akid,
        "AWS_SQS_SECRET_ACCESS_KEY": $ak,
        "AWS_SQS_REGION":            $region,
        "AWS_SQS_BASE_URL":          $url,
        "AWS_SQS_BASE_ARN":          $arn,
        "AWS_SQS_DEAD_LETTER_QUEUE": $dlq
    }')

for i in "${!QUEUE_KEYS[@]}"; do
    QUEUE_NAME="$PROJECT_NAME-$ENV-${QUEUE_KEYS[$i]}"
    SECRETS_JSON=$(echo "$SECRETS_JSON" | jq \
        --arg key "AWS_SQS_${QUEUE_ENV_SUFFIXES[$i]}" \
        --arg val "$QUEUE_NAME" \
        '. + {($key): $val}')
done

echo "$SECRETS_JSON" | jq '.' > "$SECRETS_FILE"
echo "Written: $SECRETS_FILE"

# ──────────────────────────────────────────────────────────
# Step 5 – Import secrets into AWS Secrets Manager
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
echo "Base URL : $SQS_BASE_URL"
echo "Base ARN : $SQS_BASE_ARN"
echo "DLQ      : $DLQ_NAME"
echo "Queues:"
for i in "${!QUEUE_KEYS[@]}"; do
    printf "  AWS_SQS_%-40s %s\n" "${QUEUE_ENV_SUFFIXES[$i]}=" "$PROJECT_NAME-$ENV-${QUEUE_KEYS[$i]}"
done
echo ""
echo "new-secrets.json written to: $SECRETS_FILE"
echo "Secrets Manager updated for env: $ENV"
