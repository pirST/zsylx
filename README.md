# zsylx 

Docker-образ для обхода DPI на базе [zapret-discord-youtube-linux](https://github.com/Sergeydigl3/zapret-discord-youtube-linux)
(`nfqws` от [bol-van/zapret](https://github.com/bol-van/zapret) + стратегии
[Flowseal](https://github.com/Flowseal/zapret-discord-youtube)) с
[Xray-core](https://github.com/XTLS/Xray-core) в роли **SOCKS5- и HTTP-входа**
и опциональным [dnsproxy](https://github.com/AdguardTeam/dnsproxy) для **DoH**.

## Как это работает

```
client ──SOCKS5/HTTP──> Xray (inbound socks + http)
                            │ freedom outbound
                            ▼
                    egress контейнера
                            │ nftables: output hook → NFQUEUE 220
                            ▼
                         nfqws  ──► обход DPI (fragmentation / fake / desync)
                            ▼
                        Интернет

client ──DNS :53──> dnsproxy ──DoH (HTTPS/HTTP3)──► тот же egress → nfqws
```

1. Клиент подключается к SOCKS5- (`1080`) или HTTP-порту (`8080`) Xray.
2. Xray отправляет трафик наружу через `freedom`-outbound — обычными сокетами.
3. Исходящие пакеты попадают в цепочку `output` nftables и уходят в `NFQUEUE`.
4. `nfqws` применяет выбранную стратегию обхода DPI к этим пакетам.
5. Если задан `DNSPROXY_CONF`, поднимается dnsproxy как **внешний** DNS-сервер
   (резолвер самого контейнера не меняется). Его DoH-апстримы — исходящий
   HTTPS/QUIC контейнера, поэтому проходят через `nfqws`, если хосты/IP
   апстримов указаны в `ZAPRET_EXTRA_HOSTS` (или уже есть в списках стратегии).

Итог: любой клиент, использующий контейнер как SOCKS5- или HTTP-прокси, получает
обход DPI. Внешний клиент, указывающий контейнер как DNS, получает DoH через
тот же обход.

## Требования

- Docker / Docker Compose.
- Возможность выдать контейнеру capability **`NET_ADMIN`** (для nftables/NFQUEUE).
- На **хосте** должен быть загружен модуль ядра `nfnetlink_queue`:

```bash
sudo modprobe nfnetlink_queue
```

## Быстрый старт

```bash
docker compose up --build -d
```

Проверка (через SOCKS5, HTTP и DNS):

```bash
curl -x socks5h://127.0.0.1:1080 https://www.youtube.com -I
curl -x http://127.0.0.1:8080     https://www.youtube.com -I
dig @127.0.0.1 youtube.com +short
```

## Запуск без compose

```bash
docker build -t zsylx:latest .

docker run -d --name zsylx \
  --cap-add=NET_ADMIN \
  -p 1080:1080/tcp -p 1080:1080/udp -p 8080:8080/tcp \
  -p 53:53/tcp -p 53:53/udp \
  -e STRATEGY=general.bat \
  -e DNSPROXY_CONF="-l 0.0.0.0 -p 53 -u https://dns.google/dns-query --cache" \
  -e ZAPRET_EXTRA_HOSTS="dns.google cloudflare-dns.com dns.adguard-dns.com" \
  zsylx:latest
```

## Конфигурация (переменные окружения)

| Переменная     | По умолчанию  | Описание                                                        |
|----------------|---------------|-----------------------------------------------------------------|
| `STRATEGY`     | `general.bat` | Имя `.bat`-стратегии из `zapret-latest/` или `custom-strategies/` |
| `INTERFACE`    | `any`         | Сетевой интерфейс для правил nftables                           |
| `SOCKS_PORT`   | `1080`        | Порт SOCKS5-входа Xray                                          |
| `HTTP_PORT`    | `8080`        | Порт HTTP-входа Xray                                            |
| `ENABLE_HTTP`  | `true`        | Включить HTTP-вход (`false` — только SOCKS5)                    |
| `PROXY_USER`   | —             | Логин (вместе с `PROXY_PASS` включает авторизацию для SOCKS5 и HTTP) |
| `PROXY_PASS`   | —             | Пароль                                                          |
| `GAMEFILTER_TCP` / `GAMEFILTER_UDP` | `false` | Включить gamefilter диапазоны портов                  |
| `DNSPROXY_CONF` | —            | Аргументы командной строки `dnsproxy` (см. `dnsproxy --help`). Пусто — не запускать |
| `ZAPRET_EXTRA_HOSTS` | —       | Домены и IP/CIDR (через пробел, запятую или перевод строки), которые nfqws обрабатывает сверх списков стратегии. Можно указать путь к файлу |

> `SOCKS_USER` / `SOCKS_PASS` всё ещё поддерживаются как синонимы `PROXY_USER` / `PROXY_PASS`.

### dnsproxy и DoH через zapret

`DNSPROXY_CONF` — это аргументы командной строки, которые передаются
`dnsproxy` как есть. Конфиг-файл не используется, bootstrap и listen
сами не подставляются. Резолвер контейнера (`/etc/resolv.conf`) не
меняется: dnsproxy слушает только внешних клиентов.

```yaml
environment:
  DNSPROXY_CONF: "-l 0.0.0.0 -p 53 -u https://dns.google/dns-query --cache"
  ZAPRET_EXTRA_HOSTS: "dns.google 8.8.8.8"
```

Домены из `ZAPRET_EXTRA_HOSTS` попадают в `list-general-user.txt`,
IP и CIDR — в `ipset-all.txt`. Стратегии Flowseal уже подключают оба списка.

Если на хосте порт 53 занят (часто `systemd-resolved`), смените проброс, например
на `5353:53`.

## Healthcheck

В образ встроен `HEALTHCHECK`: каждые 30 секунд он делает запрос наружу
**через SOCKS5-порт** (а значит — через `nfqws`). Если задан `DNSPROXY_CONF`,
дополнительно проверяется, что процесс `dnsproxy` жив. Если Xray упал, `nfqws` не
поднялся, dnsproxy умер или обход DPI сломался — контейнер помечается как
`unhealthy`.

```bash
docker ps                       # колонка STATUS: (healthy) / (unhealthy)
docker inspect --format '{{.State.Health.Status}}' zsylx
```

Настраивается переменными: `HEALTHCHECK_URL` (по умолчанию
`https://www.gstatic.com/generate_204`), `HEALTHCHECK_TIMEOUT` (сек).

### Выбор другой стратегии

Посмотреть доступные стратегии в собранном образе:

```bash
docker run --rm zsylx:latest bash -c 'ls /opt/zapret/zapret-latest/*.bat /opt/zapret/custom-strategies/*.bat'
```

Затем запустить с нужной:

```bash
docker run -d --name zsylx --cap-add=NET_ADMIN -p 1080:1080 \
  -e STRATEGY=general_alt.bat zsylx:latest
```

## Версии (build args)

| Аргумент           | По умолчанию | Описание                                            |
|--------------------|--------------|-----------------------------------------------------|
| `ZAPRET_VERSION`   | (пусто)      | Версия `nfqws` (напр. `v72.9`). Пусто = рекомендованная |
| `STRATEGY_VERSION` | (пусто)      | Коммит/тег стратегий Flowseal. Пусто = рекомендованная |
| `XRAY_VERSION`     | `v26.3.27`   | Тег релиза Xray-core                                |
| `DNSPROXY_VERSION` | `v0.84.1`    | Тег релиза [dnsproxy](https://github.com/AdguardTeam/dnsproxy) |

Пример:

```bash
docker build --build-arg ZAPRET_VERSION=v72.9 -t zsylx:latest .
```

## Замечания

- nftables-правила создаются в сетевом namespace контейнера и исчезают вместе с ним.
- Это **адаптер**: ни одна стратегия не гарантирует разблокировку всего. Если не
  работает — попробуйте другую `STRATEGY` (см. список выше).
- Только nftables-бэкенд (в образе установлен `nftables`).
