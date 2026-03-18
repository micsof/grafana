#!/bin/bash
set -euo pipefail

# Usage: tokens_slack.sh "service_account|cloud_policy" "account_name|status|token_name|expiration|created|lastused" ...

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../vault/config.cfg"
source "$SCRIPT_DIR/functions.sh"

NOW_EPOCH=$(date +%s)
TOKEN_ENTRIES=()
COUNT=0

if [ $# -lt 2 ]; then
    echo "Usage: tokens_slack.sh <type> <entry1> [entry2] ..."
    exit 0
fi

TYPE="$1"
shift

if [ "$TYPE" = "service_account" ]; then
    LABEL="Service Account"
else
    LABEL="Cloud Policy"
fi

for ENTRY in "$@"; do
    IFS='|' read -r ACCOUNT_NAME STATUS TOKEN_NAME EXPIRATION _ _ <<< "$ENTRY"

    if [ "$EXPIRATION" = "Never" ]; then
        continue
    fi

    EXPIRE_EPOCH=$(to_epoch "$EXPIRATION") || true
    if [ -z "$EXPIRE_EPOCH" ]; then
        continue
    fi

    DIFF_SECONDS=$(( EXPIRE_EPOCH - NOW_EPOCH ))
    DAYS_LEFT=$(floor_days "$DIFF_SECONDS")

    COUNT=$((COUNT + 1))

    if [ "$DAYS_LEFT" -lt 0 ]; then
        STATUS_ICON=":red_circle: *EXPIRED* ($(( DAYS_LEFT * -1 )) days ago)"
    elif [ "$DAYS_LEFT" -le 3 ]; then
        STATUS_ICON=":red_circle: *${DAYS_LEFT} days left*"
    elif [ "$DAYS_LEFT" -le 7 ]; then
        STATUS_ICON=":warning: ${DAYS_LEFT} days left"
    else
        STATUS_ICON=":large_yellow_circle: ${DAYS_LEFT} days left"
    fi

    TOKEN_ENTRIES+=("${STATUS_ICON}
\`\`\`${LABEL}:  ${ACCOUNT_NAME}
Token Name:      ${TOKEN_NAME}
Expires:         ${EXPIRATION}\`\`\`")
done

# --- Send Slack notification ---
if [ "$COUNT" -eq 0 ]; then
    echo "No expiring tokens to notify."
    exit 0
fi

echo "Found $COUNT expiring token(s). Sending Slack notification..."

MAX_SECTION_LEN=2900
HEADER_TEXT=":rotating_light: ${COUNT} Grafana Token(s) Expiration Status"
CONTEXT_TEXT=":grafana: <${CLOUD_INSTANCE_URL}|Open Grafana> | Stack: ${CLOUD_STACK_ID}"
PREFIX="The following tokens on stack *${CLOUD_STACK_ID}* are expiring:"

SECTIONS_JSON="[]"
CURRENT_TEXT="$PREFIX"

for ENTRY_TEXT in "${TOKEN_ENTRIES[@]}"; do
    CANDIDATE="${CURRENT_TEXT}

${ENTRY_TEXT}"
    if [ ${#CANDIDATE} -gt $MAX_SECTION_LEN ] && [ "$CURRENT_TEXT" != "$PREFIX" ]; then
        SECTIONS_JSON=$(echo "$SECTIONS_JSON" | jq --arg t "$CURRENT_TEXT" '. + [{ type: "section", text: { type: "mrkdwn", text: $t } }]')
        CURRENT_TEXT="${ENTRY_TEXT}"
    else
        CURRENT_TEXT="$CANDIDATE"
    fi
done

if [ -n "$CURRENT_TEXT" ]; then
    SECTIONS_JSON=$(echo "$SECTIONS_JSON" | jq --arg t "$CURRENT_TEXT" '. + [{ type: "section", text: { type: "mrkdwn", text: $t } }]')
fi

PAYLOAD=$(jq -n \
    --arg channel "$SLACK_CHANNEL_ID" \
    --arg header "$HEADER_TEXT" \
    --arg context "$CONTEXT_TEXT" \
    --argjson sections "$SECTIONS_JSON" \
    '{
        channel: $channel,
        username: "Grafana Token Monitor",
        icon_emoji: ":key:",
        blocks: (
            [{ type: "header", text: { type: "plain_text", text: $header, emoji: true } }]
            + $sections
            + [{ type: "divider" }, { type: "context", elements: [{ type: "mrkdwn", text: $context }] }]
        )
    }')

RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
SLACK_OK=$(echo "$BODY" | jq -r '.ok // false')

if [ "$HTTP_CODE" = "200" ] && [ "$SLACK_OK" = "true" ]; then
    echo "Slack notification sent successfully."
else
    ERROR=$(echo "$BODY" | jq -r '.error // "unknown"')
    echo "Failed to send Slack notification. HTTP: $HTTP_CODE, Error: $ERROR"
    exit 1
fi
