# syntax=docker/dockerfile:1

# =============================================================================
# Stage 1: builder — скачивает nfqws + стратегии (zapret-discord-youtube-linux),
#          бинарники Xray-core и dnsproxy.
# =============================================================================
FROM debian:bookworm-slim AS builder

ARG ZAPRET_REPO=https://github.com/Sergeydigl3/zapret-discord-youtube-linux.git
ARG ZAPRET_REPO_REF=master
# Версии nfqws / стратегий. Пусто => используются рекомендованные (--default).
ARG ZAPRET_VERSION=""
ARG STRATEGY_VERSION=""
ARG XRAY_VERSION=v26.3.27
ARG DNSPROXY_VERSION=v0.84.1

# nftables нужен здесь только для прохождения check_dependencies в service.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git curl bash tar unzip grep sed coreutils findutils nftables \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 --branch "${ZAPRET_REPO_REF}" "${ZAPRET_REPO}" zapret

WORKDIR /opt/zapret
# Скачиваем nfqws (бинарник) и репозиторий стратегий Flowseal в zapret-latest/.
# Если версии не заданы — берём рекомендованные (протестированные) из constants.sh.
RUN set -eux; \
    if [ -n "${ZAPRET_VERSION}" ] || [ -n "${STRATEGY_VERSION}" ]; then \
        args=""; \
        [ -n "${ZAPRET_VERSION}" ] && args="$args -z ${ZAPRET_VERSION}"; \
        [ -n "${STRATEGY_VERSION}" ] && args="$args -s ${STRATEGY_VERSION}"; \
        bash service.sh download-deps $args; \
    else \
        bash service.sh download-deps --default; \
    fi; \
    test -f /opt/zapret/nfqws; \
    test -d /opt/zapret/zapret-latest

# --- Xray-core ---
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64)  xray_asset="Xray-linux-64.zip" ;; \
        arm64)  xray_asset="Xray-linux-arm64-v8a.zip" ;; \
        armhf)  xray_asset="Xray-linux-arm32-v7a.zip" ;; \
        i386)   xray_asset="Xray-linux-32.zip" ;; \
        *) echo "unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/xray-dist; \
    curl -fL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${xray_asset}" \
        -o /tmp/xray.zip; \
    unzip /tmp/xray.zip -d /opt/xray-dist; \
    chmod +x /opt/xray-dist/xray; \
    rm -f /tmp/xray.zip

# --- dnsproxy (AdGuardTeam) ---
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64)  dp_arch="amd64" ;; \
        arm64)  dp_arch="arm64" ;; \
        armhf)  dp_arch="arm7" ;; \
        i386)   dp_arch="386" ;; \
        *) echo "unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/dnsproxy-dist; \
    curl -fL "https://github.com/AdguardTeam/dnsproxy/releases/download/${DNSPROXY_VERSION}/dnsproxy-linux-${dp_arch}-${DNSPROXY_VERSION}.tar.gz" \
        -o /tmp/dnsproxy.tar.gz; \
    tar -xzf /tmp/dnsproxy.tar.gz -C /tmp; \
    mv "/tmp/linux-${dp_arch}/dnsproxy" /opt/dnsproxy-dist/dnsproxy; \
    chmod +x /opt/dnsproxy-dist/dnsproxy; \
    rm -rf /tmp/dnsproxy.tar.gz "/tmp/linux-${dp_arch}"

# =============================================================================
# Stage 2: runtime
# =============================================================================
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="zsylx" \
      org.opencontainers.image.description="DPI bypass via zapret (nfqws) + Xray SOCKS5 inbound + dnsproxy DoH"

# nftables — для NFQUEUE правил; библиотеки — для nfqws; procps — для pgrep/pkill;
# curl/git/sed/grep — нужны скриптам zapret в рантайме; openssl — gen-doh-cert.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nftables iproute2 \
        libnetfilter-queue1 libnfnetlink0 libcap2 zlib1g \
        ca-certificates curl git grep sed coreutils findutils procps bash openssl \
    && rm -rf /var/lib/apt/lists/*

# Бинарник и ассеты Xray
COPY --from=builder /opt/xray-dist/xray /usr/local/bin/xray
COPY --from=builder /opt/xray-dist/*.dat /usr/local/share/xray/

# dnsproxy
COPY --from=builder /opt/dnsproxy-dist/dnsproxy /usr/local/bin/dnsproxy

# Скрипты + скачанные nfqws/стратегии zapret
COPY --from=builder /opt/zapret /opt/zapret

# Наши конфиги и точка входа
COPY conf.env /opt/zapret/conf.env
COPY xray/config.json /opt/xray/config.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY gen-doh-cert.sh /usr/local/bin/gen-doh-cert
ARG DNSPROXY_TLS_CN=localhost
ARG DNSPROXY_TLS_DAYS=3650
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/gen-doh-cert \
    && gen-doh-cert --cn "${DNSPROXY_TLS_CN}" --days "${DNSPROXY_TLS_DAYS}" --force

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    ZAPRET_DIR=/opt/zapret \
    XRAY_CONFIG=/opt/xray/config.json \
    SOCKS_PORT=1080 \
    HTTP_PORT=8080 \
    ENABLE_HTTP=true \
    STRATEGY=general.bat \
    INTERFACE=any

EXPOSE 1080/tcp 1080/udp 8080/tcp 53/tcp 53/udp 443/tcp 853/tcp 853/udp

# Healthcheck: проверяет, что трафик реально ходит через SOCKS5-вход.
HEALTHCHECK --interval=30s --timeout=15s --start-period=20s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
