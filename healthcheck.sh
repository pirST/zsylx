#!/usr/bin/env bash
# =============================================================================
# Healthcheck: проверяет, что трафик реально проходит через SOCKS5-вход Xray
# (и, значит, через цепочку nfqws). Возвращает 0 — healthy, 1 — unhealthy.
# =============================================================================
set -e

PORT="${SOCKS_PORT:-1080}"
URL="${HEALTHCHECK_URL:-https://www.gstatic.com/generate_204}"
TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"

# Если dnsproxy включён через DNSPROXY_CONF — он должен быть жив.
if [[ -n "${DNSPROXY_CONF:-}" ]]; then
    pgrep -x dnsproxy >/dev/null || exit 1
fi

# Если задана авторизация — передаём её в curl.
auth_arg=()
USER="${PROXY_USER:-${SOCKS_USER:-}}"
PASS="${PROXY_PASS:-${SOCKS_PASS:-}}"
if [[ -n "$USER" && -n "$PASS" ]]; then
    auth_arg=(--proxy-user "${USER}:${PASS}")
fi

exec curl -fsS --max-time "$TIMEOUT" \
    -x "socks5h://127.0.0.1:${PORT}" \
    "${auth_arg[@]}" \
    -o /dev/null "$URL"
