# Torrent Blocker RW

`Torrent Blocker RW` — Bash-агент для Remnawave. Внимание! Только для входных серверов без remnanode. Опрашивает Remnawave API, читает torrent/P2P reports и временно блокирует IP клиента через `nftables`.

Подходит для входных серверов без remnanode, которые сами должны банить клиентов на своём firewall.

## Что умеет

- опрашивает Remnawave Torrent Blocker reports через API;
- блокирует IPv4 через `nftables` с timeout;

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/atyonekilla/torrent-block-rw/main/install.sh | sudo bash
```

Установщик сначала проверяет Remnawave API. Если URL или API-токен неверные, установка завершится до создания каталога установки, настройки `systemd` и `nftables`.

```text
/opt/torrent-blocker/
/etc/systemd/system/torrent-blocker.service
/etc/systemd/system/torrent-blocker.timer
/usr/local/bin/torrent-blocker
```

```bash
sudo torrent-blocker
```

Ручная установка:

```bash
git clone https://github.com/atyonekilla/torrent-block-rw.git
cd torrent-block-rw
chmod +x install.sh torrent-blocker
sudo bash install.sh
```

## Что спросит установщик

```text
Remnawave API URL
Remnawave API token
Время блокировки IP
```

Старые reports пропускаются автоматически, чтобы блокироваться начали только новые нарушения.
Имя входной ноды задаётся автоматически. При необходимости его можно поменять вручную в конфиге через меню.

## Файлы

```text
/opt/torrent-blocker/
├── torrent-blocker
├── .env
└── last_id
```

```text
/etc/systemd/system/torrent-blocker.service
/etc/systemd/system/torrent-blocker.timer
```

## Конфиг

```bash
sudo nano /opt/torrent-blocker/.env
```

```env
INSTANCE_NAME="default"
SERVICE_UNIT="torrent-blocker.service"
TIMER_UNIT="torrent-blocker.timer"
MENU_BIN="/usr/local/bin/torrent-blocker"

REMNAWAVE_API_BASE="https://admin.example.com"
REMNAWAVE_API_TOKEN="PASTE_YOUR_REMNAWAVE_API_TOKEN_HERE"

INGRESS_NODE_NAME="gateway-1 (203.0.113.10)"

BAN_TIMEOUT="1h"
PAGE_SIZE="100"
MAX_PAGES="5"
```

Примеры `BAN_TIMEOUT`: `30m`, `1h`, `6h`, `1d`.

`PAGE_SIZE` — сколько reports запрашивать из Remnawave API за один запрос. Допустимые значения: от `1` до `500`.

`MAX_PAGES` — сколько страниц reports максимум проверять за один запуск. Допустимые значения: от `1` до `50`.

При `PAGE_SIZE="100"` и `MAX_PAGES="5"` скрипт проверит до `500` последних reports за запуск. Уже обработанные или старые reports пропускаются по `last_id`.

## Команды

Меню:

```bash
sudo torrent-blocker
```

Проверить сейчас:

```bash
sudo /opt/torrent-blocker/torrent-blocker --run
```

Статус:

```bash
systemctl status torrent-blocker.timer --no-pager
```

Логи:

```bash
journalctl -u torrent-blocker.service -n 100 --no-pager
```

Заблокированные IP:

```bash
nft list set inet torrent_guard blocked_ipv4
```

Включить/отключить timer:

```bash
sudo systemctl enable --now torrent-blocker.timer
sudo systemctl disable --now torrent-blocker.timer
```

## Удаление

```bash
sudo systemctl disable --now torrent-blocker.timer

sudo rm -f /etc/systemd/system/torrent-blocker.service
sudo rm -f /etc/systemd/system/torrent-blocker.timer
sudo systemctl daemon-reload

sudo rm -rf /opt/torrent-blocker/
sudo rm -f /usr/local/bin/torrent-blocker

sudo nft delete table inet torrent_guard
```

## Лицензия

MIT License.
