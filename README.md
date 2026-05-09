# Torrent Blocker RW

**Torrent Blocker RW** — Bash-агент для автоматической блокировки IP-адресов, замеченных в torrent/P2P-трафике по отчётам Remnawave Torrent Blocker.

Скрипт опрашивает Remnawave API, получает новые reports, извлекает IP клиента и добавляет его в `nftables` ban-list с автоматическим timeout-разбаном.

Проект подходит для схемы, где входной сервер сам должен блокировать IP клиентов на уровне firewall.

---

## Как это работает

```text
Пользователь использует torrent/P2P
        ↓
Remnawave Torrent Blocker создаёт report
        ↓
Torrent Blocker RW опрашивает Remnawave API
        ↓
Находит новый torrent report
        ↓
Берёт IP клиента из report.actionReport.ip
        ↓
Добавляет IP в nftables
        ↓
IP блокируется на заданное время
```

Пример блокировки:

```bash
nft add element inet torrent_guard blocked_ipv4 "{ 46.173.35.204 timeout 1h }"
```

После истечения timeout IP удаляется автоматически.

---

## Возможности

- Автоматический опрос Remnawave Torrent Blocker reports
- Работа через Remnawave API
- Блокировка IP через `nftables`
- Автоматический разбан через timeout
- Обработка только новых reports через `last_id`
- Systemd timer для регулярного запуска
- Компактное CLI-меню
- Метка входной ноды для схем с несколькими входными серверами
- Telegram-уведомления в личку, чат или нужный топик Telegram
- Простая установка через `install.sh`

---

## Для какой схемы подходит

Проект подходит, если используется схема:

```text
Клиент
  ↓
Входной сервер
  ↓
Основной сервер / Xray / Remnawave node
```

В такой схеме основной сервер может видеть реальный IP клиента в report, но не всегда может заблокировать его на уровне firewall, потому что фактическое подключение идёт через входной сервер.

Правильный вариант:

```text
Входной сервер сам опрашивает Remnawave API
и сам блокирует IP клиента у себя
```

---

## Требования

Поддерживается Ubuntu/Debian-based сервер.

Нужные пакеты:

```text
curl
jq
nftables
systemd
```

Установщик поставит их автоматически.

---

## Структура проекта

```text
torrent-block-rw/
├── install.sh
├── torrent-blocker
├── menu
├── .env.example
├── .gitignore
└── systemd/
    ├── torrent-blocker.service
    └── torrent-blocker.timer
```

После установки файлы будут размещены в:

```text
/opt/torrent-blocker/
├── torrent-blocker
├── menu
├── .env
└── last_id
```

---

## Установка

### 1. Клонировать репозиторий

```bash
git clone https://github.com/atyonekilla/torrent-block-rw.git
cd torrent-block-rw
```

### 2. Выдать права на запуск

```bash
chmod +x install.sh torrent-blocker menu
```

### 3. Запустить установку

```bash
sudo bash install.sh
```

Установщик попросит:

```text
Remnawave API URL
Remnawave API token
Имя входной ноды
Время блокировки IP
Пропускать ли старые reports
```

Пример значений:

```text
Remnawave API URL: https://admin.example.com
Имя входной ноды: gateway-1 (203.0.113.10)
Время блокировки: 1h
Пропустить старые reports: Y
```

Если имя входной ноды оставить пустым, установщик подставит дефолт вида `hostname (ip)`.

Рекомендуется пропустить старые reports, чтобы скрипт начал блокировать только новые нарушения.

---

## После установки

Файлы будут размещены в:

```text
/opt/torrent-blocker/
├── torrent-blocker
├── menu
├── .env
└── last_id
```

Systemd-файлы:

```text
/etc/systemd/system/torrent-blocker.service
/etc/systemd/system/torrent-blocker.timer
```

---

## Запуск меню

```bash
sudo torrent-blocker-menu
```

Или:

```bash
sudo /opt/torrent-blocker/menu
```

---

## Проверка работы

```bash
systemctl status torrent-blocker.timer --no-pager
journalctl -u torrent-blocker.service -n 100 --no-pager
nft list set inet torrent_guard blocked_ipv4
```

---

## Ручной запуск проверки

```bash
sudo /opt/torrent-blocker/torrent-blocker
```

---

## Конфигурация

Файл конфигурации:

```bash
sudo nano /opt/torrent-blocker/.env
```

Пример:

```env
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

После изменения `.env` перезапускать timer не нужно — конфиг читается при каждом запуске.

---
### Параметры

| Параметр | Описание |
|---|---|
| `REMNAWAVE_API_BASE` | URL панели Remnawave |
| `REMNAWAVE_API_TOKEN` | API-токен Remnawave |
| `INGRESS_NODE_NAME` | Имя входной ноды/сервера, которое будет видно в логах и Telegram-алертах |
| `BAN_TIMEOUT` | Время блокировки IP |
| `PAGE_SIZE` | Количество reports за один запрос |
| `MAX_PAGES` | Максимум страниц за один запуск |
| `TELEGRAM_ENABLED` | Включены ли Telegram-уведомления |
| `TELEGRAM_BOT_TOKEN` | Токен Telegram-бота |
| `TELEGRAM_CHAT_ID` | ID личного чата, группы или супергруппы, куда отправлять уведомления |
| `TELEGRAM_TOPIC_ID` | ID топика (`message_thread_id`) внутри Telegram-группы. Оставь пустым, если топик не нужен |
| `TELEGRAM_ADMIN_ID` | Старое имя для личного `chat_id`; поддерживается как fallback для существующих конфигов |

---

## Примеры времени блокировки

```env
BAN_TIMEOUT="30m"
BAN_TIMEOUT="1h"
BAN_TIMEOUT="6h"
BAN_TIMEOUT="1d"
```

---

## Запуск меню

После установки доступна команда:

```bash
sudo torrent-blocker-menu
```

Или напрямую:

```bash
sudo /opt/torrent-blocker/menu
```

Меню:

```text
╭────────────────────────────────────╮
│        Torrent Blocker             │
╰────────────────────────────────────╯

Сервис:   ВКЛ
Telegram: ВЫКЛ

1) Включить / отключить
2) Проверить сейчас
3) Статус
4) Заблокированные IP
5) Логи
6) Telegram
7) Конфиг
0) Выход
```

---

## Telegram-уведомления

В меню пункт:

```text
6) Telegram
```

Доступные действия:

```text
1) Настроить Telegram
2) Включить / отключить
3) Отправить тест
0) Назад
```

При настройке можно указать:

```text
Telegram Chat ID: -1001234567890
Telegram Topic ID / message_thread_id: 42
```

`TELEGRAM_CHAT_ID` — это цель отправки: личный чат, группа или супергруппа. Для отправки в топик добавь бота в группу, отправь любое сообщение в нужный топик и укажи `message_thread_id` как `TELEGRAM_TOPIC_ID`. Если топик не нужен, оставь `TELEGRAM_TOPIC_ID` пустым.

Chat ID и Topic ID можно взять из Bot API:

```text
https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getUpdates
```

Нужные поля в ответе: `message.chat.id` и, для топика, `message.message_thread_id`.

При блокировке IP придёт сообщение:

```text
🚫 Торрент заблокирован

🖥 Сервер
• Входная нода: gateway-1 (203.0.113.10)

⛔ Блокировка
• IP клиента: 46.173.35.204
• Срок: 1h

👤 Пользователь
• ID: 1701
• Логин: 1701
• UUID: ...

📄 Report
• ID: 678
• Нода: poland
• Страна: PL
• Создан: 09.05.2026 16:46:00 UTC
```

Уведомления отправляются на `TELEGRAM_CHAT_ID`. Если в старом конфиге задан только `TELEGRAM_ADMIN_ID`, он будет использован как `chat_id`.

---

## Проверка работы

Статус timer:

```bash
systemctl status torrent-blocker.timer --no-pager
```

Логи последнего запуска:

```bash
journalctl -u torrent-blocker.service -n 100 --no-pager
```

Список заблокированных IP:

```bash
nft list set inet torrent_guard blocked_ipv4
```

Ручной запуск проверки:

```bash
sudo /opt/torrent-blocker/torrent-blocker
```

---

## Как проверить вручную

Добавить тестовый IP на 30 секунд:

```bash
sudo nft add element inet torrent_guard blocked_ipv4 "{ 203.0.113.10 timeout 30s }"
```

Проверить список:

```bash
sudo nft list set inet torrent_guard blocked_ipv4
```

Через 30 секунд IP исчезнет автоматически.

---

## Управление systemd

Включить автоматический запуск:

```bash
sudo systemctl enable --now torrent-blocker.timer
```

Отключить:

```bash
sudo systemctl disable --now torrent-blocker.timer
```

Перезапустить timer:

```bash
sudo systemctl restart torrent-blocker.timer
```

Запустить проверку вручную:

```bash
sudo systemctl start torrent-blocker.service
```

---

## Что именно блокируется

Скрипт берёт IP в таком порядке:

```text
1. report.actionReport.ip
2. report.xrayReport.source без порта
```

Report считается подходящим для блокировки, если выполняется одно из условий:

```text
report.actionReport.blocked = true
protocol = bittorrent
outboundTag = RW_TB_OUTBOUND_BLOCK
```

---

## Где хранится last_id

Файл:

```text
/opt/torrent-blocker/last_id
```

Он нужен, чтобы не обрабатывать одни и те же reports повторно.

При первом запуске установщик может пропустить старые reports и сохранить текущий последний ID.

## Удаление

Остановить сервис:

```bash
sudo systemctl disable --now torrent-blocker.timer
```

Удалить systemd-файлы:

```bash
sudo rm -f /etc/systemd/system/torrent-blocker.service
sudo rm -f /etc/systemd/system/torrent-blocker.timer
sudo systemctl daemon-reload
```

Удалить файлы проекта:

```bash
sudo rm -rf /opt/torrent-blocker
sudo rm -f /usr/local/bin/torrent-blocker-menu
```

Удалить nftables-таблицу:

```bash
sudo nft delete table inet torrent_guard
```

---

## Лицензия

MIT License.
