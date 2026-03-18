#!/usr/bin/env python3

import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import requests

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / ".." / "vault" / "config.cfg"
PER_PAGE = 100


@dataclass
class TokenEntry:
    token_type: str
    account_name: str
    status: str
    token_name: str
    expiration: str
    created: str
    last_used: str


def load_config(path: Path) -> dict:
    config = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("!"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] in ('"', "'"):
                quote = value[0]
                end = value.find(quote, 1)
                value = value[1:end] if end != -1 else value[1:]
            else:
                value = value.split("#")[0].strip()
            for var, val in config.items():
                value = value.replace(f"${{{var}}}", val)
            config[key] = value
    return config


def parse_expiration(raw: str | None) -> str:
    if raw is None or raw == "" or raw == "null":
        return "Never"
    return raw


def to_epoch(date_str: str) -> int | None:
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S+00:00", "%Y-%m-%dT%H:%M:%S-00:00", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
        except ValueError:
            continue
    return None


def to_epoch_or_sentinel(date_str: str, sentinel: int = -999) -> int:
    if not date_str or date_str == "Never":
        return sentinel
    epoch = to_epoch(date_str)
    return epoch if epoch is not None else sentinel


def days_left(expiration: str, now_epoch: int) -> tuple[int, str]:
    """Returns (days_left_value, expiry_state)."""
    if expiration == "Never":
        return -999, "never"
    epoch = to_epoch(expiration)
    if epoch is None:
        return 0, "unknown"
    return (epoch - now_epoch) // 86400, "days"


# --- Fetch Service Account tokens from Grafana Instance API ---
# Uses: {CLOUD_INSTANCE_URL}/api/serviceaccounts/search (paginated)
# Then:  {CLOUD_INSTANCE_URL}/api/serviceaccounts/{id}/tokens for each SA
# Skips Grafana managed service accounts (extsvc-*)

def fetch_service_accounts(config: dict) -> list[TokenEntry]:
    api_url = config["CLOUD_INSTANCE_URL"]
    api_token = config["CLOUD_INSTANCE_TOKEN"]
    entries = []
    page = 1

    while True:
        resp = requests.get(
            f"{api_url}/api/serviceaccounts/search",
            params={"perpage": PER_PAGE, "page": page},
            headers={"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"},
            timeout=30,
        )
        if resp.status_code != 200:
            print(f"ERROR: Failed to fetch service accounts (page {page}). HTTP: {resp.status_code}")
            sys.exit(1)

        data = resp.json()
        accounts = data.get("serviceAccounts", [])
        if not accounts:
            break

        for sa in accounts:
            sa_name = sa["name"]
            if sa_name.startswith("extsvc-"):
                continue
            sa_status = "disabled" if sa.get("isDisabled") else "enabled"
            sa_id = sa["id"]

            tok_resp = requests.get(
                f"{api_url}/api/serviceaccounts/{sa_id}/tokens",
                headers={"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"},
                timeout=30,
            )
            if tok_resp.status_code != 200:
                print(f"WARNING: Failed to fetch tokens for SA '{sa_name}' (ID: {sa_id}). HTTP: {tok_resp.status_code}")
                continue

            for token in tok_resp.json():
                entries.append(TokenEntry(
                    token_type="service_account",
                    account_name=sa_name,
                    status=sa_status,
                    token_name=token["name"],
                    expiration=parse_expiration(token.get("expiration")),
                    created=token.get("created", ""),
                    last_used=parse_expiration(token.get("lastUsedAt")),
                ))

        if len(accounts) < PER_PAGE:
            break
        page += 1

    return entries


# --- Fetch Cloud Policy tokens from Grafana Cloud API ---
# Uses: grafana.com/api/v1/accesspolicies (policies)
# And:  grafana.com/api/v1/tokens (tokens matched to policies by accessPolicyId)

def fetch_cloud_policies(config: dict) -> list[TokenEntry]:
    cloud_api_token = config["CLOUD_API_TOKEN"]
    policies_url = config["CLOUD_API_POLICIES"]
    tokens_url = config["CLOUD_API_TOKENS"]
    entries = []

    pol_resp = requests.get(policies_url, headers={"Authorization": f"Bearer {cloud_api_token}"}, timeout=30)
    if pol_resp.status_code != 200:
        print(f"ERROR: Failed to fetch cloud policies. HTTP: {pol_resp.status_code}")
        sys.exit(1)

    tok_resp = requests.get(tokens_url, headers={"Authorization": f"Bearer {cloud_api_token}"}, timeout=30)
    if tok_resp.status_code != 200:
        print(f"ERROR: Failed to fetch cloud tokens. HTTP: {tok_resp.status_code}")
        sys.exit(1)

    policies = pol_resp.json().get("items", [])
    tokens = tok_resp.json().get("items", [])

    tokens_by_policy: dict[str, list] = {}
    for t in tokens:
        pid = t.get("accessPolicyId", "")
        tokens_by_policy.setdefault(pid, []).append(t)

    for policy in policies:
        policy_id = policy["id"]
        display = policy.get("displayName") or policy.get("name", "")
        status = "enabled" if policy.get("status") == "active" else "disabled"

        for token in tokens_by_policy.get(policy_id, []):
            entries.append(TokenEntry(
                token_type="cloud_policy",
                account_name=display,
                status=status,
                token_name=token["name"],
                expiration=parse_expiration(token.get("expiresAt")),
                created=token.get("createdAt", ""),
                last_used=parse_expiration(token.get("lastUsedAt")),
            ))

    return entries


# --- Send OTLP metrics to Grafana Cloud ---
# Metric name: grafana_token (gauge)
# Labels: type, account_name, token_name, status, expiry_state, expires
# Sends to: OTLP_ENDPOINT using basic auth (OTLP_INSTANCE_ID:OTLP_TOKEN)

def send_metrics(entries: list[TokenEntry], config: dict) -> None:
    if not entries:
        return

    now_epoch = int(time.time())
    now_nano = f"{now_epoch}000000000"
    datapoints = []

    by_type: dict[str, list[TokenEntry]] = {}
    for e in entries:
        by_type.setdefault(e.token_type, []).append(e)

    for token_type, type_entries in by_type.items():
        print("=========================================")
        print(f" OTLP Metric: grafana_token ({token_type})")
        print("=========================================")
        print(f"  {'type':<18} {'account_name':<28} {'token_name':<65} {'status':<10} {'expiry_state':<14} {'created':<14} {'lastused':<14} value")
        print("-----------------------------------------")

        for e in type_entries:
            days_val, expiry_state = days_left(e.expiration, now_epoch)
            created_epoch = to_epoch(e.created) or now_epoch
            created_days = (now_epoch - created_epoch) // 86400
            lastused_epoch = to_epoch_or_sentinel(e.last_used)
            lastused_days = (now_epoch - lastused_epoch) // 86400 if lastused_epoch != -999 else -999

            # Truncate long values so columns stay aligned (format spec doesn't truncate, only pads)
            print(f"  {e.token_type[:18]:<18} {e.account_name[:28]:<28} {e.token_name[:65]:<65} {e.status[:10]:<10} {expiry_state[:14]:<14} {str(created_days)[:14]:<14} {str(lastused_days)[:14]:<14} {days_val}")

            datapoints.append({
                "asInt": str(days_val),
                "timeUnixNano": now_nano,
                "attributes": [
                    {"key": "type", "value": {"stringValue": e.token_type}},
                    {"key": "account_name", "value": {"stringValue": e.account_name}},
                    {"key": "token_name", "value": {"stringValue": e.token_name}},
                    {"key": "status", "value": {"stringValue": e.status}},
                    {"key": "expiry_state", "value": {"stringValue": expiry_state}},
                    {"key": "created", "value": {"stringValue": str(created_days)}},
                    {"key": "lastused", "value": {"stringValue": str(lastused_days)}},
                ],
            })

    if not datapoints:
        print("\nNo valid data points to send.")
        return

    payload = {
        "resourceMetrics": [{
            "resource": {"attributes": []},
            "scopeMetrics": [{
                "scope": {"name": "token-monitor"},
                "metrics": [{
                    "name": "grafana_token",
                    "gauge": {"dataPoints": datapoints},
                }],
            }],
        }],
    }

    print("\nSending data point(s) to OTLP endpoint...")

    resp = requests.post(
        config["OTLP_ENDPOINT"],
        json=payload,
        auth=(config["OTLP_INSTANCE_ID"], config["OTLP_TOKEN"]),
        headers={"Content-Type": "application/json"},
        timeout=30,
    )

    if resp.status_code == 200:
        print("Metrics sent successfully.")
    else:
        print(f"Failed to send metrics. HTTP: {resp.status_code}")
        print(resp.text)
        sys.exit(1)


# --- Main ---

def main():
    config = load_config(CONFIG_PATH)

    print("Fetching service account tokens...")
    sa_entries = fetch_service_accounts(config)
    print(f"Found {len(sa_entries)} service account token(s).\n")

    print("Fetching cloud policy tokens...")
    cp_entries = fetch_cloud_policies(config)
    print(f"Found {len(cp_entries)} cloud policy token(s).\n")

    all_entries = sa_entries + cp_entries

    if not all_entries:
        print("No tokens to report.")
        return

    send_metrics(all_entries, config)


if __name__ == "__main__":
    main()
