#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../vault/config.cfg"

EXPIRING_ARGS=()

RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 \
    "$CLOUD_API_POLICIES" \
    -H "Authorization: Bearer $CLOUD_API_TOKEN")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
POLICIES=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: Failed to fetch cloud policies. HTTP: $HTTP_CODE"
    exit 1
fi

RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 \
    "$CLOUD_API_TOKENS" \
    -H "Authorization: Bearer $CLOUD_API_TOKEN")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
TOKENS=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: Failed to fetch cloud tokens. HTTP: $HTTP_CODE"
    exit 1
fi

while read -r policy; do
    POLICY_ID=$(echo "$policy" | jq -r '.id')
    POLICY_DISPLAY=$(echo "$policy" | jq -r '.displayName // .name')
    POLICY_STATUS=$(echo "$policy" | jq -r 'if .status == "active" then "enabled" else "disabled" end')

    MATCHING_TOKENS=$(echo "$TOKENS" | jq -c --arg pid "$POLICY_ID" '[.items[]? | select(.accessPolicyId == $pid)]')

    while read -r token; do
        TOKEN_NAME=$(echo "$token" | jq -r '.name')
        TOKEN_EXPIRATION=$(echo "$token" | jq -r 'if .expiresAt == null or .expiresAt == "" then "Never" else .expiresAt end')
        TOKEN_CREATED=$(echo "$token" | jq -r 'if .createdAt == null or .createdAt == "" then "" else .createdAt end')
        TOKEN_LASTUSED=$(echo "$token" | jq -r 'if .lastUsedAt == null or .lastUsedAt == "" then "Never" else .lastUsedAt end')

        EXPIRING_ARGS+=("$POLICY_DISPLAY|$POLICY_STATUS|$TOKEN_NAME|$TOKEN_EXPIRATION|$TOKEN_CREATED|$TOKEN_LASTUSED")
    done < <(echo "$MATCHING_TOKENS" | jq -c '.[]?')
done < <(echo "$POLICIES" | jq -c '.items[]?')

if [ ${#EXPIRING_ARGS[@]} -gt 0 ]; then
    bash "$SCRIPT_DIR/tokens_metrics.sh" "cloud_policy" "${EXPIRING_ARGS[@]}"
    bash "$SCRIPT_DIR/tokens_slack.sh" "cloud_policy" "${EXPIRING_ARGS[@]}"
else
    echo "No tokens with expiration dates found."
fi
