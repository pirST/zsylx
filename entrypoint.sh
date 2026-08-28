#!/usr/bin/env bash
# =============================================================================
# entrypoint: поднимает zapret (nftables NFQUEUE + nfqws) и запускает Xray
# в роли SOCKS5-входа. Трафик из freedom-outbound Xray уходит через output-hook
# и обрабатывается nfqws (обход DPI). Опционально — dnsproxy: его DoH-апстримы
# идут тем же egress и тоже попадают в nfqws.
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
    [[ -n "${DNSPROXY_PID:-}" ]] && kill "$DNSPROXY_PID" 2>/dev/null || true
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

# Добавить запись в файл, если её ещё нет. nfqws читает списки от nobody.
append_unique() {
    local file="$1" value="$2"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    chmod 644 "$file" 2>/dev/null || true
    grep -qxF "$value" "$file" 2>/dev/null && return 0
    printf '%s\n' "$value" >> "$file"
}

# Нормализовать токен ZAPRET_EXTRA_HOSTS: срезать схему URL, путь и порт.
normalize_extra_host() {
    local token="$1"
    token="${token%%#*}"
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -z "$token" ]] && return 0

    token="${token#https://}"
    token="${token#http://}"
    token="${token#tls://}"
    token="${token#quic://}"
    token="${token#h3://}"
    token="${token#udp://}"
    token="${token#tcp://}"
    token="${token%%/*}"

    if [[ "$token" == \[*\]* ]]; then
        token="${token#\[}"
        token="${token%%\]*}"
    elif [[ "$token" != *:*:* && "$token" == *:* ]]; then
        # hostname:port или IPv4:port, но не IPv6
        token="${token%%:*}"
    fi

    printf '%s\n' "$token"
}

# ZAPRET_EXTRA_HOSTS — домены (list-general-user.txt) и IP/CIDR (ipset-all.txt),
# которые стратегия прогоняет через nfqws сверх штатных списков.
apply_zapret_extra_hosts() {
    local raw="${ZAPRET_EXTRA_HOSTS:-}"
    [[ -z "$raw" ]] && return 0

    local lists_dir="$REPO_DIR/lists"
    local user_dir="$ZAPRET_DIR/user-lists"
    mkdir -p "$lists_dir" "$user_dir"

    local hostlist="$lists_dir/list-general-user.txt"
    local user_hostlist="$user_dir/list-general-user.txt"
    local ipset="$lists_dir/ipset-all.txt"

    touch "$hostlist" "$user_hostlist" "$ipset"
    chmod 644 "$hostlist" "$user_hostlist" "$ipset" 2>/dev/null || true

    local data="$raw"
    if [[ -f "$raw" ]]; then
        data=$(cat "$raw")
        log "ZAPRET_EXTRA_HOSTS: читаю список из $raw"
    fi

    local added_hosts=0 added_ips=0
    local line token
    while IFS= read -r line; do
        # Разделители: запятая / точка с запятой / пробел
        line="${line//,/ }"
        line="${line//; / }"
        line="${line//;/ }"
        for token in $line; do
            token=$(normalize_extra_host "$token")
            [[ -z "$token" ]] && continue

            if [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ || "$token" == *:* ]]; then
                append_unique "$ipset" "$token"
                added_ips=$((added_ips + 1))
            else
                append_unique "$hostlist" "$token"
                append_unique "$user_hostlist" "$token"
                added_hosts=$((added_hosts + 1))
            fi
        done
    done < <(printf '%s\n' "$data")

    log "ZAPRET_EXTRA_HOSTS: доменов=$added_hosts, IP/CIDR=$added_ips"
}

# DNSPROXY_CONF — аргументы командной строки dnsproxy (как в dnsproxy --help).
# Пусто = не запускаем. Резолвер контейнера не трогаем: dnsproxy только
# для внешних клиентов, bootstrap не подставляем.
start_dnsproxy() {
    local conf="${DNSPROXY_CONF:-}"
    [[ -z "$conf" ]] && return 0

    if [[ ! -x /usr/local/bin/dnsproxy ]]; then
        handle_error "dnsproxy не найден (пересоберите образ)"
    fi

    log "Запуск dnsproxy: $conf"
    eval "dnsproxy $conf" &
    DNSPROXY_PID=$!

    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$DNSPROXY_PID" 2>/dev/null; then
            handle_error "dnsproxy не стартовал"
        fi
        sleep 0.2
    done

    log "dnsproxy запущен (pid=$DNSPROXY_PID), только внешние клиенты"
}

# --- Extra hosts, затем zapret ----------------------------------------------
apply_zapret_extra_hosts

log "Запуск zapret: strategy=$strategy, interface=$interface, backend=$FIREWALL_BACKEND"
run_zapret

# dnsproxy после nfqws, чтобы DoH-апстримы уже шли через очередь
start_dnsproxy

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

if [[ -n "${DNSPROXY_PID:-}" ]]; then
    wait -n "$XRAY_PID" "$DNSPROXY_PID"
    code=$?
    log "Один из процессов завершился (code=$code)"
    kill "$XRAY_PID" "$DNSPROXY_PID" 2>/dev/null || true
    stop_zapret 2>/dev/null || true
    exit "$code"
fi

wait "$XRAY_PID"
