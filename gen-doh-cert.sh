#!/usr/bin/env bash
# =============================================================================
# Генерация самоподписанного TLS-сертификата для DoH/DoT/DoQ-сервера dnsproxy.
# Пишет cert.pem и key.pem в /opt/dnsproxy/tls/ (или --out).
# =============================================================================
set -euo pipefail

OUT_DIR="${DNSPROXY_TLS_DIR:-/opt/dnsproxy/tls}"
CN="${DNSPROXY_TLS_CN:-localhost}"
DAYS="${DNSPROXY_TLS_DAYS:-3650}"
FORCE=0
SANS=()

usage() {
    cat <<'EOF'
Usage: gen-doh-cert [options]

Самоподписанный сертификат для режима сервера dnsproxy (DoH/DoT/DoQ).

  -n, --cn NAME     Common Name (по умолчанию: localhost или DNSPROXY_TLS_CN)
  -d, --days N      Срок действия в днях (по умолчанию: 3650)
  -s, --san NAME    Дополнительный SAN (домен или IP). Можно несколько раз.
  -o, --out DIR     Каталог для cert.pem и key.pem (по умолчанию: /opt/dnsproxy/tls)
  -f, --force       Перезаписать существующие файлы
  -h, --help        Справка

Примеры:
  gen-doh-cert --cn dns.example.com --san dns.example.com --san 192.168.1.10
  docker exec zsylx gen-doh-cert -n mydns.lan -s mydns.lan -f

После перегенерации перезапустите контейнер, чтобы dnsproxy подхватил новые файлы.
EOF
}

san_entry() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$v" == *:* ]]; then
        printf 'IP:%s' "$v"
    else
        printf 'DNS:%s' "$v"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--cn)   CN="$2"; shift 2 ;;
        -d|--days) DAYS="$2"; shift 2 ;;
        -s|--san)  SANS+=("$2"); shift 2 ;;
        -o|--out)  OUT_DIR="$2"; shift 2 ;;
        -f|--force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl не найден" >&2
    exit 1
fi

CERT="$OUT_DIR/cert.pem"
KEY="$OUT_DIR/key.pem"

if [[ -f "$CERT" || -f "$KEY" ]] && [[ "$FORCE" -ne 1 ]]; then
    echo "Уже есть $CERT / $KEY. Перезапись: gen-doh-cert --force" >&2
    exit 1
fi

declare -A seen=()
san_list=()
add_san() {
    local e
    e=$(san_entry "$1")
    [[ -n "${seen[$e]:-}" ]] && return 0
    seen[$e]=1
    san_list+=("$e")
}

add_san "$CN"
add_san localhost
add_san 127.0.0.1
for s in "${SANS[@]+"${SANS[@]}"}"; do
    add_san "$s"
done

san_joined=$(IFS=,; echo "${san_list[*]}")

mkdir -p "$OUT_DIR"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$KEY" \
    -out "$CERT" \
    -days "$DAYS" \
    -subj "/CN=${CN}" \
    -addext "subjectAltName=${san_joined}"
chmod 644 "$CERT"
chmod 600 "$KEY"

echo "Сертификат: $CERT"
echo "Ключ:       $KEY"
echo "CN:         $CN"
echo "SAN:        $san_joined"
echo "Срок:       $DAYS дней"
echo "Перезапустите контейнер, если dnsproxy уже запущен."
