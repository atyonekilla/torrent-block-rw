# Torrent Blocker RW

`Torrent Blocker RW` — Bash-агент для Remnawave. Он опрашивает Remnawave API, читает torrent/P2P reports и временно блокирует IP клиента через `nftables`.

Подходит для входных серверов, которые сами должны банить клиентов на своём firewall.

## Что умеет

- опрашивает Remnawave Torrent Blocker reports через API;
- блокирует IPv4 через `nftables` с timeout;
- помнит последний обработанный report через `last_id`;
- запускается по `systemd` timer;
- имеет CLI-меню.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/atyonekilla/torrent-block-rw/main/install.sh | sudo bash
```

Установщик сначала проверяет Remnawave API. Если URL или API-токен неверные, установка завершится до создания каталога установки, настройки `systemd` и `nftables`.

Недостающие зависимости ставятся автоматически. Уже установленные пакеты пропускаются, а `apt update` запускается только если есть что устанавливать.

Обычная установка создаёт одну панель:

```text
/opt/torrent-blocker/
/etc/systemd/system/torrent-blocker.service
/etc/systemd/system/torrent-blocker.timer
/usr/local/bin/torrent-blocker-menu
```

```bash
sudo torrent-blocker-menu
```

Путь в меню:

```text
Настройки -> Подключить ещё одну панель
```

Для второй панели, например `panel2`, будут созданы:

```text
/opt/torrent-blocker-panel2/
/etc/systemd/system/torrent-blocker-panel2.service
/etc/systemd/system/torrent-blocker-panel2.timer
/usr/local/bin/torrent-blocker-panel2-menu
```

Перед созданием файлов меню проверит URL панели и API-токен. Если панель недоступна, новая установка не будет создана.

Все установки используют общий `nftables` set `inet torrent_guard blocked_ipv4`, поэтому IP блокируется на одном firewall сервера.

Для автоматизации имя установки всё ещё можно передать переменной:

```bash
curl -fsSL https://raw.githubusercontent.com/atyonekilla/torrent-block-rw/main/install.sh | sudo TORRENT_BLOCKER_INSTANCE=panel2 bash
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
Имя входной ноды
Пропускать ли старые reports
```

Рекомендуется пропустить старые reports, чтобы блокироваться начали только новые нарушения.

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

Для дополнительной установки имя добавляется в путь и unit-файлы: `/opt/torrent-blocker-panel2`, `torrent-blocker-panel2.timer`.

## Конфиг

```bash
sudo nano /opt/torrent-blocker/.env
```

```env
INSTANCE_NAME="default"
SERVICE_UNIT="torrent-blocker.service"
TIMER_UNIT="torrent-blocker.timer"
MENU_BIN="/usr/local/bin/torrent-blocker-menu"

REMNAWAVE_API_BASE="https://admin.example.com"
REMNAWAVE_API_TOKEN="PASTE_YOUR_REMNAWAVE_API_TOKEN_HERE"

INGRESS_NODE_NAME="gateway-1 (203.0.113.10)"

BAN_TIMEOUT="1h"
PAGE_SIZE="100"
MAX_PAGES="5"

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_TOPIC_ID=""
```

Примеры `BAN_TIMEOUT`: `30m`, `1h`, `6h`, `1d`.

## Дополнительно

Уведомления можно включить после установки через меню:

```bash
sudo torrent-blocker-menu
```

Доступность Telegram API в России может быть ограничена регуляторами. Если тест не отправляется, возможно нужен доступ через разрешённый прокси.

Если вводишь ID супергруппы без `-100`, например `1234567890`, меню автоматически сохранит его как `-1001234567890`.

## Команды

Меню:

```bash
sudo torrent-blocker-menu
```

Для дополнительной установки:

```bash
sudo torrent-blocker-panel2-menu
```

Проверить сейчас:

```bash
sudo /opt/torrent-blocker/torrent-blocker
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
sudo rm -f /usr/local/bin/torrent-blocker-menu

sudo nft delete table inet torrent_guard
```

Для дополнительной установки замени имя unit и каталог, например:

```bash
sudo systemctl disable --now torrent-blocker-panel2.timer
sudo rm -f /etc/systemd/system/torrent-blocker-panel2.service
sudo rm -f /etc/systemd/system/torrent-blocker-panel2.timer
sudo rm -rf /opt/torrent-blocker-panel2/
sudo rm -f /usr/local/bin/torrent-blocker-panel2-menu
sudo systemctl daemon-reload
```

`nft delete table inet torrent_guard` выполняй только когда удалены все установки, потому что ban-list общий для всех панелей.

## Лицензия

MIT License.
