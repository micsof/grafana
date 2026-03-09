# Grafana Token Monitor

A set of scripts that monitor token expiration for **Grafana service accounts** and **Grafana Cloud access policies**. When tokens are approaching expiry (or already expired), the tooling sends OTLP metrics to Grafana Cloud and Slack notifications to a configured channel.

## Architecture

```
tokens/
├── bash/
│   ├── tokens_service_accounts.sh   (Grafana Instance API)
│   ├── tokens_cloud_policies.sh     (Grafana Cloud API)
│   ├── tokens_metrics.sh            (OTLP push)
│   ├── tokens_slack.sh              (Slack alert)
│   └── functions.sh                 (shared utilities)
├── python/
│   ├── tokens_monitor.py            (all-in-one Python version)
│   └── requirements.txt
└── README.md

vault/
└── config.cfg                       (credentials & configuration)
```

There are two independent approaches to run the monitor — pick one:

| Approach | Entry point | Description |
|----------|-------------|-------------|
| **Bash** | `bash/tokens_service_accounts.sh` + `bash/tokens_cloud_policies.sh` | Each script collects tokens of its type and delegates to `tokens_metrics.sh` and `tokens_slack.sh`. |
| **Python** | `python/tokens_monitor.py` | Single script that fetches both token types and pushes OTLP metrics (no Slack yet). |

## Files

### `bash/tokens_service_accounts.sh`

Fetches all service accounts from the Grafana Instance API (paginated), retrieves each account's tokens, and forwards the collected entries to `tokens_metrics.sh` and `tokens_slack.sh`.

- Skips Grafana-managed service accounts (names starting with `extsvc-`).
- Marks each account as `enabled` or `disabled` based on `isDisabled`.
- **API used:** `GET {API_URL}/api/serviceaccounts/search` and `GET {API_URL}/api/serviceaccounts/{id}/tokens`.

### `bash/tokens_cloud_policies.sh`

Fetches access policies and their associated tokens from the Grafana Cloud API, then forwards the results to `tokens_metrics.sh` and `tokens_slack.sh`.

- Matches tokens to policies via `accessPolicyId`.
- Uses `displayName` (falling back to `name`) for the policy label.
- **API used:** `GET {CLOUD_POLICIES_URL}` (access policies) and `GET {CLOUD_TOKENS_URL}` (cloud tokens).

### `bash/tokens_metrics.sh`

Receives token entries from a caller script and pushes a `grafana_token` gauge metric to the OTLP endpoint via HTTP/JSON.

```
Usage: tokens_metrics.sh <type> <entry1> [entry2] ...
       type  = "service_account" | "cloud_policy"
       entry = "account_name|status|token_name|expiration"
```

Each data point includes these attributes/labels:

| Attribute | Description |
|-----------|-------------|
| `type` | `service_account` or `cloud_policy` |
| `account_name` | Name of the service account or cloud policy |
| `token_name` | Name of the individual token |
| `status` | `enabled` or `disabled` |
| `expiry_state` | `days` (has expiration) or `never` (no expiration set) |

The gauge value is the number of **days until expiration**:

- Positive values indicate days remaining before the token expires.
- Negative values indicate the token has already expired (e.g. `-3` means expired 3 days ago).
- **`-999`** is a sentinel value used for tokens that are set to **never expire** (`expiry_state: never`). This allows easy filtering in Grafana dashboards.

#### Grafana Dashboard Panels Examples

Tokens with an expiration date — the gauge shows days until (or since) expiry:

![Tokens Expiry State — Days](images/grafana_tokens_expiry_days.png)

Tokens set to never expire — shown with the `-999` sentinel value:

![Tokens Expiry State — Never](images/grafana_tokens_expiry_never.png)

### `bash/tokens_slack.sh`

Receives token entries from a caller script and sends a formatted Slack notification listing tokens that have an expiration date.

```
Usage: tokens_slack.sh <type> <entry1> [entry2] ...
       type  = "service_account" | "cloud_policy"
       entry = "account_name|status|token_name|expiration"
```

Severity indicators in the Slack message:

| Condition | Icon |
|-----------|------|
| Already expired | :red_circle: **EXPIRED** |
| 0–3 days left | :red_circle: |
| 4–7 days left | :warning: |
| 8+ days left | :large_yellow_circle: |

Long messages are automatically split into multiple Slack Block Kit sections to stay within the 3000-character limit.

### `python/tokens_monitor.py`

A self-contained Python replacement that combines the logic of the bash scripts. It fetches both service account tokens and cloud policy tokens, then pushes OTLP metrics — all in a single run.

```
python3 tokens_monitor.py
```

Requires the `requests` library (see `python/requirements.txt`).

### `bash/functions.sh`

Shared utility functions sourced by the bash scripts:

- **`to_epoch`** — Converts an ISO 8601 date string to a Unix epoch timestamp (handles both macOS `date` and GNU `date`).
- **`floor_days`** — Converts a difference in seconds to whole days (floors toward negative infinity for negative values).

### `vault/config.cfg`

Central configuration file sourced by all scripts. A template is provided as `vault/config.cfg.example` — copy it and fill in your values:

```bash
cp vault/config.cfg.example vault/config.cfg
```

| Variable | Purpose |
|----------|---------|
| `API_URL` | Grafana instance base URL |
| `API_TOKEN` | Grafana service account token with `serviceaccounts:read` scope |
| `CLOUD_API_URL` | Grafana Cloud token API base URL |
| `CLOUD_API_TOKEN` | Grafana Cloud token with `accesspolicies:read` scope |
| `CLOUD_REGION` | Grafana Cloud stack region |
| `CLOUD_STACK_ID` | Grafana Cloud stack identifier |
| `CLOUD_POLICIES_URL` | Derived URL for fetching access policies |
| `CLOUD_TOKENS_URL` | Derived URL for fetching cloud tokens |
| `OTLP_ENDPOINT` | OTLP HTTP endpoint for metrics ingestion |
| `OTLP_INSTANCE_ID` | Instance ID for OTLP basic auth |
| `OTLP_TOKEN` | Token for OTLP basic auth (`metrics:write` scope) |
| `SLACK_TOKEN` | Slack bot token with `chat:write` scope |
| `SLACK_CHANNEL_ID` | Target Slack channel for notifications |

> **Security note:** `config.cfg` contains secrets (API tokens, Slack token). Ensure it is not committed to public repositories and is properly secured.

## Prerequisites

- **bash** (4.x+), **curl**, **jq**
- **Python 3.10+** and `requests` (for `tokens_monitor.py`)
- Grafana service account token with `serviceaccounts:read` and `serviceaccounts.permissions:read` scopes
- Grafana Cloud API token with `accesspolicies:read` scope
- OTLP write token with `metrics:write` scope
- Slack bot token with `chat:write` scope

## Usage

### Bash — run both monitors

```bash
# Monitor service account tokens
bash code/bash/tokens_service_accounts.sh

# Monitor cloud policy tokens
bash code/bash/tokens_cloud_policies.sh
```

### Python — single command

```bash
pip install -r code/python/requirements.txt
python3 code/python/tokens_monitor.py
```

### Scheduled execution

Consider using a serverless or CI/CD scheduled job (e.g. Azure Functions Timer Trigger, 
GitHub Actions scheduled workflow, or GitLab CI/CD scheduled pipeline).
