#!/bin/bash
set -euo pipefail

# Usage: tokens_metrics.sh "service_account|cloud_policy" "account_name|status|token_name|expiration|created|lastused" ...

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../vault/config.cfg"
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
printf "  %-18s %-28s %-65s %-10s %-14s %-14s %-14s %s\n" "type" "account_name" "token_name" "status" "expiry_state" "created" "lastused" "value"
echo "-----------------------------------------"

for ENTRY in "$@"; do
    IFS='|' read -r ACCOUNT_NAME STATUS TOKEN_NAME TOKEN_EXPIRES CREATED LASTUSED <<< "$ENTRY"

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

    # created: days since creation
    if [ -n "$CREATED" ]; then
        CREATED_EPOCH=$(to_epoch "$CREATED") || true
        CREATED_DAYS=$([ -n "$CREATED_EPOCH" ] && floor_days $(( NOW_EPOCH - CREATED_EPOCH )) || echo "0")
    else
        CREATED_DAYS="0"
    fi

    # lastused: days since last used, or -999 if never
    if [ -z "$LASTUSED" ] || [ "$LASTUSED" = "Never" ]; then
        LASTUSED_DAYS="-999"
    else
        LASTUSED_EPOCH=$(to_epoch "$LASTUSED") || true
        LASTUSED_DAYS=$([ -n "$LASTUSED_EPOCH" ] && floor_days $(( NOW_EPOCH - LASTUSED_EPOCH )) || echo "-999")
    fi

    # Truncate long values so columns stay aligned (printf doesn't truncate, only pads)
    printf "  %-18s %-28s %-65s %-10s %-14s %-14s %-14s %s\n" \
        "${TYPE:0:18}" \
        "${ACCOUNT_NAME:0:28}" \
        "${TOKEN_NAME:0:65}" \
        "${STATUS:0:10}" \
        "${EXPIRY_STATE:0:14}" \
        "${CREATED_DAYS:0:14}" \
        "${LASTUSED_DAYS:0:14}" \
        "$DAYS_LEFT_VAL"

    DATAPOINTS_JSONL+=$(jq -n \
        --arg days "$DAYS_LEFT_VAL" \
        --arg time "$NOW_NANO" \
        --arg type "$TYPE" \
        --arg account "$ACCOUNT_NAME" \
        --arg token "$TOKEN_NAME" \
        --arg status "$STATUS" \
        --arg expiry_state "$EXPIRY_STATE" \
        --arg created "$CREATED_DAYS" \
        --arg lastused "$LASTUSED_DAYS" \
        '{
            asInt: $days,
            timeUnixNano: $time,
            attributes: [
                { key: "type", value: { stringValue: $type } },
                { key: "account_name", value: { stringValue: $account } },
                { key: "token_name", value: { stringValue: $token } },
                { key: "status", value: { stringValue: $status } },
                { key: "expiry_state", value: { stringValue: $expiry_state } },
                { key: "created", value: { stringValue: $created } },
                { key: "lastused", value: { stringValue: $lastused } }
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
