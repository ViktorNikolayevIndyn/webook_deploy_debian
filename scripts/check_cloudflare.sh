#!/bin/bash
set -e

echo "=== check_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-check] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[cf-check] ERROR: config file not found: $CONFIG_FILE"
    exit 1
  fi
}

need_bin cloudflared
need_bin jq
need_bin curl
ensure_config

echo "[cf-check] ROOT_DIR    = $ROOT_DIR"
echo "[cf-check] CONFIG_FILE = $CONFIG_FILE"
echo

echo "[cf-check] cloudflared tunnel list:"
cloudflared tunnel list || true
echo

# собираем домены для проверки
echo "[cf-check] Collecting domains from projects.json ..."

domains_json="$(
  jq -c '
    [
      # webhook host
      if .webhook and .webhook.cloudflare then
        {
          kind: "webhook",
          host: (
            if (.webhook.cloudflare.subdomain // "") != "" then
              .webhook.cloudflare.subdomain + "." + .webhook.cloudflare.rootDomain
            else
              .webhook.cloudflare.rootDomain
            end
          ),
          protocol: (.webhook.cloudflare.protocol // "http")
        }
      else empty end,

      # project hosts
      (
        .projects[]? |
        select(.cloudflare != null) |
        {
          kind: "project",
          name: .name,
          host: (
            if (.cloudflare.subdomain // "") != "" then
              .cloudflare.subdomain + "." + .cloudflare.rootDomain
            else
              .cloudflare.rootDomain
            end
          ),
          protocol: (.cloudflare.protocol // "http")
        }
      )
    ]
  ' "$CONFIG_FILE"
)"

if [ -z "$domains_json" ] || [ "$domains_json" = "[]" ]; then
  echo "[cf-check] No domains found in config."
  echo "=== check_cloudflare.sh finished ==="
  exit 0
fi

echo "[cf-check] Domains to probe:"
echo "$domains_json" | jq -r '.[] | "  - " + .protocol + "://" + .host + " (" + .kind + (if .name then ":" + .name else "" end) + ")"'
echo

# проверка через curl
echo "[cf-check] Curl probes:"

echo "$domains_json" | jq -c '.[]' | while read -r item; do
  proto=$(echo "$item" | jq -r '.protocol')
  host=$(echo "$item"  | jq -r '.host')
  kind=$(echo "$item"  | jq -r '.kind')
  name=$(echo "$item"  | jq -r '.name // ""')

  url="${proto}://${host}"

  label="$kind"
  if [ -n "$name" ] && [ "$name" != "null" ]; then
    label="${label}:${name}"
  fi

  echo "---- ${label} -> ${url} ----"
  curl -k -I --max-time 5 "$url" || echo "[cf-check] curl failed for $url"
  echo
done

echo "=== check_cloudflare.sh finished ==="
