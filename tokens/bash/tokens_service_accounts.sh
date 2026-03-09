#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../vault/config.cfg"

EXPIRING_ARGS=()
PAGE=1
PER_PAGE=100

while true; do
    RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 \
        "${API_URL}/api/serviceaccounts/search?perpage=${PER_PAGE}&page=${PAGE}" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    SA_LIST=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" != "200" ]; then
        echo "ERROR: Failed to fetch service accounts (page $PAGE). HTTP: $HTTP_CODE"
        exit 1
    fi

    SA_COUNT=$(echo "$SA_LIST" | jq '.serviceAccounts | length')
    if [ "$SA_COUNT" -eq 0 ]; then
        break
    fi

    while read -r sa; do
        SA_ID=$(echo "$sa" | jq -r '.id')
        SA_NAME=$(echo "$sa" | jq -r '.name')
        SA_DISABLED=$(echo "$sa" | jq -r '.isDisabled')

        if [[ "$SA_NAME" == extsvc-* ]]; then
            continue
        fi

        if [ "$SA_DISABLED" = "true" ]; then
            SA_STATUS="disabled"
        else
            SA_STATUS="enabled"
        fi

        RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 \
            "$API_URL/api/serviceaccounts/$SA_ID/tokens" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json")
        HTTP_CODE=$(echo "$RESPONSE" | tail -1)
        TOKENS=$(echo "$RESPONSE" | sed '$d')

        if [ "$HTTP_CODE" != "200" ]; then
            echo "WARNING: Failed to fetch tokens for SA '$SA_NAME' (ID: $SA_ID). HTTP: $HTTP_CODE"
            continue
        fi

        while read -r token; do
            TOKEN_NAME=$(echo "$token" | jq -r '.name')
            TOKEN_EXPIRATION=$(echo "$token" | jq -r 'if .expiration == null or .expiration == "" then "Never" else .expiration end')

            EXPIRING_ARGS+=("$SA_NAME|$SA_STATUS|$TOKEN_NAME|$TOKEN_EXPIRATION")
        done < <(echo "$TOKENS" | jq -c '.[]?')
    done < <(echo "$SA_LIST" | jq -c '.serviceAccounts[]?')

    if [ "$SA_COUNT" -lt "$PER_PAGE" ]; then
        break
    fi
    PAGE=$((PAGE + 1))
done

if [ ${#EXPIRING_ARGS[@]} -gt 0 ]; then
    bash "$SCRIPT_DIR/tokens_metrics.sh" "service_account" "${EXPIRING_ARGS[@]}"
    bash "$SCRIPT_DIR/tokens_slack.sh" "service_account" "${EXPIRING_ARGS[@]}"
else
    echo "No tokens to report."
fi
