#!/bin/bash
set -euo pipefail

# Usage: tokens_metrics.sh "service_account|cloud_policy" "account_name|status|token_name|expiration" ...

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../vault/config.cfg"
source "$SCRIPT_DIR/functions.sh"

NOW_EPOCH=$(date +%s)
NOW_NANO="${NOW_EPOCH}000000000"

if [ $# -lt 2 ]; then
    echo "Usage: tokens_metrics.sh <type> <entry1> [entry2] ..."
    exit 0
fi

TYPE="$1"
shift

DATAPOINTS_JSONL=""

echo "========================================="
echo " OTLP Metric: grafana_token (${TYPE})"
echo "========================================="
printf "  %-18s %-28s %-65s %-10s %-14s %s\n" "type" "account_name" "token_name" "status" "expiry_state" "value"
echo "-----------------------------------------"

for ENTRY in "$@"; do
    IFS='|' read -r ACCOUNT_NAME STATUS TOKEN_NAME TOKEN_EXPIRES <<< "$ENTRY"

    if [ "$TOKEN_EXPIRES" = "Never" ]; then
        DAYS_LEFT_VAL=-999
        EXPIRY_STATE="never"
    else
        EXPIRE_EPOCH=$(to_epoch "$TOKEN_EXPIRES") || true
        if [ -z "$EXPIRE_EPOCH" ]; then
            continue
        fi
        DAYS_LEFT_VAL=$(floor_days $(( EXPIRE_EPOCH - NOW_EPOCH )))
        EXPIRY_STATE="days"
    fi

    printf "  %-18s %-28s %-65s %-10s %-14s %s\n" "$TYPE" "$ACCOUNT_NAME" "$TOKEN_NAME" "$STATUS" "$EXPIRY_STATE" "$DAYS_LEFT_VAL"

    DATAPOINTS_JSONL+=$(jq -n \
        --arg days "$DAYS_LEFT_VAL" \
        --arg time "$NOW_NANO" \
        --arg type "$TYPE" \
        --arg account "$ACCOUNT_NAME" \
        --arg token "$TOKEN_NAME" \
        --arg status "$STATUS" \
        --arg expiry_state "$EXPIRY_STATE" \
        '{
            asInt: $days,
            timeUnixNano: $time,
            attributes: [
                { key: "type", value: { stringValue: $type } },
                { key: "account_name", value: { stringValue: $account } },
                { key: "token_name", value: { stringValue: $token } },
                { key: "status", value: { stringValue: $status } },
                { key: "expiry_state", value: { stringValue: $expiry_state } }
            ]
        }')
    DATAPOINTS_JSONL+=$'\n'
done

DATAPOINTS_JSON=$(echo "$DATAPOINTS_JSONL" | jq -s '.')

if [ "$(echo "$DATAPOINTS_JSON" | jq 'length')" -eq 0 ]; then
    echo ""
    echo "No valid data points to send."
    exit 0
fi

PAYLOAD=$(jq -n --argjson dps "$DATAPOINTS_JSON" '{
    resourceMetrics: [{
        resource: { attributes: [] },
        scopeMetrics: [{
            scope: { name: "token-monitor" },
            metrics: [{
                name: "grafana_token",
                gauge: { dataPoints: $dps }
            }]
        }]
    }]
}')

echo ""
echo "Sending data point(s) to OTLP endpoint..."

RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 \
    -X POST "$OTLP_ENDPOINT" \
    -H "Content-Type: application/json" \
    -u "${OTLP_INSTANCE_ID}:${OTLP_TOKEN}" \
    -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo "Metrics sent successfully."
else
    echo "Failed to send metrics. HTTP: $HTTP_CODE"
    echo "$BODY"
    exit 1
fi
