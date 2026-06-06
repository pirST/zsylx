# zsylx 

Docker-образ для обхода DPI на базе [zapret-discord-youtube-linux](https://github.com/Sergeydigl3/zapret-discord-youtube-linux)
(`nfqws` от [bol-van/zapret](https://github.com/bol-van/zapret) + стратегии
[Flowseal](https://github.com/Flowseal/zapret-discord-youtube)) с
[Xray-core](https://github.com/XTLS/Xray-core) в роли **SOCKS5- и HTTP-входа**.

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
```

1. Клиент подключается к SOCKS5- (`1080`) или HTTP-порту (`8080`) Xray.
2. Xray отправляет трафик наружу через `freedom`-outbound — обычными сокетами.
3. Исходящие пакеты попадают в цепочку `output` nftables и уходят в `NFQUEUE`.
4. `nfqws` применяет выбранную стратегию обхода DPI к этим пакетам.

Итог: любой клиент, использующий контейнер как SOCKS5- или HTTP-прокси, получает обход DPI.

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

Проверка (через SOCKS5 и через HTTP):

```bash
curl -x socks5h://127.0.0.1:1080 https://www.youtube.com -I
curl -x http://127.0.0.1:8080     https://www.youtube.com -I
```

## Запуск без compose

```bash
docker build -t zsylx:latest .

docker run -d --name zsylx \
  --cap-add=NET_ADMIN \
  -p 1080:1080/tcp -p 1080:1080/udp -p 8080:8080/tcp \
  -e STRATEGY=general.bat \
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

> `SOCKS_USER` / `SOCKS_PASS` всё ещё поддерживаются как синонимы `PROXY_USER` / `PROXY_PASS`.

## Healthcheck

В образ встроен `HEALTHCHECK`: каждые 30 секунд он делает запрос наружу
**через SOCKS5-порт** (а значит — через `nfqws`). Если Xray упал, `nfqws` не
поднялся или обход DPI сломался — контейнер помечается как `unhealthy`.

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

Пример:

```bash
docker build --build-arg ZAPRET_VERSION=v72.9 -t zsylx:latest .
```

## Замечания

- nftables-правила создаются в сетевом namespace контейнера и исчезают вместе с ним.
- Это **адаптер**: ни одна стратегия не гарантирует разблокировку всего. Если не
  работает — попробуйте другую `STRATEGY` (см. список выше).
- Только nftables-бэкенд (в образе установлен `nftables`).
