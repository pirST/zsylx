#!/usr/bin/env bash
# =============================================================================
# entrypoint: поднимает zapret (nftables NFQUEUE + nfqws) и запускает Xray
# в роли SOCKS5-входа. Трафик из freedom-outbound Xray уходит через output-hook
# и обрабатывается nfqws (обход DPI).
# =============================================================================
set -e

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

ZAPRET_DIR="${ZAPRET_DIR:-/opt/zapret}"
XRAY_CONFIG="${XRAY_CONFIG:-/opt/xray/config.json}"

# Переменные путей, которые ожидают библиотеки zapret (как в service.sh)
HOME_DIR_PATH="$ZAPRET_DIR"
BASE_DIR="$ZAPRET_DIR"
CONF_FILE="$ZAPRET_DIR/conf.env"
CUSTOM_STRATEGIES_DIR="$ZAPRET_DIR/custom-strategies"
REPO_DIR="$ZAPRET_DIR/zapret-latest"
NFQWS_PATH="$ZAPRET_DIR/nfqws"

# Подключаем библиотеки zapret
source "$ZAPRET_DIR/src/lib/elevate.sh"
source "$ZAPRET_DIR/src/lib/constants.sh"
source "$ZAPRET_DIR/src/lib/common.sh"
source "$ZAPRET_DIR/src/lib/firewall.sh"

# --- Конфигурация zapret ---------------------------------------------------
# Базовые значения берём из conf.env, затем перекрываем переменными окружения.
if [[ -f "$CONF_FILE" ]]; then
    load_config "$CONF_FILE"
fi

[[ -n "${STRATEGY:-}" ]]       && strategy="$STRATEGY"
[[ -n "${INTERFACE:-}" ]]      && interface="$INTERFACE"
[[ -n "${GAMEFILTER_TCP:-}" ]] && gamefiltertcp="$GAMEFILTER_TCP"
[[ -n "${GAMEFILTER_UDP:-}" ]] && gamefilterudp="$GAMEFILTER_UDP"
[[ -n "${FIREWALL_BACKEND_OVERRIDE:-}" ]] && FIREWALL_BACKEND="$FIREWALL_BACKEND_OVERRIDE"

: "${strategy:=general.bat}"
: "${interface:=any}"
: "${gamefiltertcp:=false}"
: "${gamefilterudp:=false}"
: "${FIREWALL_BACKEND:=nftables}"

# --- Проверки --------------------------------------------------------------
if [[ ! -x "$NFQWS_PATH" ]]; then
    handle_error "nfqws не найден в $NFQWS_PATH (пересоберите образ)"
fi

if ! nft list ruleset >/dev/null 2>&1; then
    log "ВНИМАНИЕ: nft недоступен. Запустите контейнер с --cap-add=NET_ADMIN"
    log "         и убедитесь, что на хосте загружен модуль nfnetlink_queue."
fi

# --- Очистка при остановке --------------------------------------------------
cleanup() {
    log "Получен сигнал остановки. Завершение работы..."
    [[ -n "${XRAY_PID:-}" ]] && kill "$XRAY_PID" 2>/dev/null || true
    stop_zapret 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# stop_zapret определён в src/cli/run.sh, но мы не подключаем CLI-модули —
# повторяем его поведение здесь.
stop_zapret() {
    stop_nfqws
    firewall_clear
}

# --- Запуск zapret ----------------------------------------------------------
log "Запуск zapret: strategy=$strategy, interface=$interface, backend=$FIREWALL_BACKEND"
run_zapret

# --- Подготовка конфига Xray -----------------------------------------------
# Генерируем рабочий конфиг: SOCKS5-вход + (опционально) HTTP-вход, общий
# freedom-outbound. Параметры берём из переменных окружения.
RUNTIME_XRAY_CONFIG="/tmp/xray.runtime.json"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
ENABLE_HTTP="${ENABLE_HTTP:-true}"

# Учётные данные общие для SOCKS5 и HTTP. PROXY_* приоритетнее,
# SOCKS_* поддерживаются для обратной совместимости.
PROXY_USER="${PROXY_USER:-${SOCKS_USER:-}}"
PROXY_PASS="${PROXY_PASS:-${SOCKS_PASS:-}}"

socks_auth="noauth"
socks_accounts=""
http_accounts=""
if [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]]; then
    accounts_json="[{\"user\": \"${PROXY_USER}\", \"pass\": \"${PROXY_PASS}\"}]"
    socks_auth="password"
    socks_accounts=", \"accounts\": ${accounts_json}"
    http_accounts="\"accounts\": ${accounts_json}, "
    log "Прокси: включена авторизация (пользователь: ${PROXY_USER})"
else
    log "Прокси: без авторизации"
fi

inbounds="{
      \"tag\": \"socks-in\",
      \"listen\": \"0.0.0.0\",
      \"port\": ${SOCKS_PORT},
      \"protocol\": \"socks\",
      \"settings\": { \"auth\": \"${socks_auth}\", \"udp\": true${socks_accounts} },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"] }
    }"

if [[ "$ENABLE_HTTP" == "true" ]]; then
    inbounds="${inbounds},
    {
      \"tag\": \"http-in\",
      \"listen\": \"0.0.0.0\",
      \"port\": ${HTTP_PORT},
      \"protocol\": \"http\",
      \"settings\": { ${http_accounts}\"allowTransparent\": false },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"] }
    }"
    log "HTTP-вход включён на порту ${HTTP_PORT}"
fi

cat > "$RUNTIME_XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    ${inbounds}
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } }
  ]
}
EOF

# --- Запуск Xray ------------------------------------------------------------
http_msg=""
[[ "$ENABLE_HTTP" == "true" ]] && http_msg=", HTTP :${HTTP_PORT}"
log "Запуск Xray: SOCKS5 :${SOCKS_PORT}${http_msg} ..."
xray run -c "$RUNTIME_XRAY_CONFIG" &
XRAY_PID=$!

log "Готово. nfqws обрабатывает egress контейнера."
wait "$XRAY_PID"
