# Torrent Blocker RW

`Torrent Blocker RW` — Bash-агент для Remnawave. Внимание! Только для входных серверов без remnanode. Опрашивает Remnawave API, читает torrent/P2P reports и временно блокирует IP клиента через `nftables`.

Подходит для входных серверов без remnanode, которые сами должны банить клиентов на своём firewall.

## Что умеет

- опрашивает Remnawave Torrent Blocker reports через API;
- блокирует IPv4 через `nftables` с timeout;
- сохраняет баны с временем окончания и восстанавливает их при следующем запуске;
- проверяет формат отчётов и не продвигает курсор при неполной выборке;
- поддерживает несколько панелей с общим журналом и lock на firewall.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/atyonekilla/torrent-block-rw/main/install.sh | sudo bash
```

Поддерживаются Debian/Ubuntu с systemd. Установка требует интерактивного терминала (например, SSH с TTY), root и доступа к панели по HTTPS.

Установщик ставит зависимости, затем проверяет Remnawave API. Если URL или API-токен неверные, установка завершится до создания каталога установки, настройки `systemd` и `nftables`.

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

Приглашения выводятся напрямую в терминал, даже если stderr перенаправлен. Ввод API-токена скрыт. Без управляющего терминала или при прерывании ввода установка завершается с ошибкой.

Старые reports пропускаются автоматически, чтобы блокироваться начали только новые нарушения.
Имя входной ноды задаётся автоматически. При необходимости его можно поменять вручную в конфиге через меню.

## Файлы

```text
/opt/torrent-blocker/
├── torrent-blocker
├── common.sh
├── .env
└── last_id
```

```text
/etc/systemd/system/torrent-blocker.service
/etc/systemd/system/torrent-blocker.timer
/var/lib/torrent-blocker/bans.json
/run/lock/torrent-blocker-firewall.lock
```

`bans.json` общий для всех панелей на сервере; содержит IPv4 и абсолютное время окончания бана. При первом запуске после обновления текущие временные баны импортируются из nftables.

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
REPORT_NODE_NAME=""
ALLOWLIST_IPV4=""
```

Примеры `BAN_TIMEOUT`: `30m`, `1h`, `6h`, `1d`. Нулевые значения и ведущие нули не допускаются; число — от 1 до 999999.

Конфиг читается как данные: `KEY="value"`, `KEY='value'` или `KEY=value`, одна настройка на строку. Пустые строки и отдельные строки комментариев разрешены. Подстановки `$VAR`, `$()` и команды не исполняются. В двойных кавычках поддерживаются экранированные `\\`, `\"`, `\$` и обратная кавычка. Неизвестные ключи считаются ошибкой.

`INGRESS_NODE_NAME` — подпись сервера в логах. `REPORT_NODE_NAME` — отдельный необязательный фильтр: точное совпадение с именем ноды в отчёте. Пустое значение обрабатывает все ноды панели. Не задавайте здесь имя входного сервера, если отчёты создаются на другой ноде.

`ALLOWLIST_IPV4="203.0.113.10 198.51.100.20"` исключает указанные адреса из **новых** блокировок этого экземпляра. CIDR не поддерживается. Для общего исключения задайте список во всех экземплярах. Уже действующие баны сохраняются до истечения срока.

`PAGE_SIZE` — сколько reports запрашивать из Remnawave API за один запрос. Допустимые значения: от `1` до `500`.

`MAX_PAGES` — сколько страниц reports максимум проверять за один запуск. Допустимые значения: от `1` до `50`.

При `PAGE_SIZE="100"` и `MAX_PAGES="5"` скрипт читает до `500` последних reports за запуск. API должен возвращать `.response.records` с положительными целочисленными `id` по убыванию; неверная структура или порядок вызывают ошибку.

Сначала агент собирает выборку до уже обработанного ID или конца списка, затем применяет новые отчёты по возрастанию ID. Курсор сохраняется после каждой успешной обработки. Если лимит страниц исчерпан раньше, агент завершится с ошибкой, не применяя новые отчёты и не продвигая `last_id`. Увеличьте `PAGE_SIZE`/`MAX_PAGES` и повторите запуск; максимальное окно — 25000 записей. При большем отставании требуется отдельная процедура выгрузки/обработки истории: автоматического пропуска нет.

Если API удаляет непрочитанные отчёты или изменяет историю во время offset-пагинации, гарантировать полноту выборки невозможно. Агент рассчитан на добавление новых записей с возрастающими ID.

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

## Поведение firewall

Правило действует в `input` и блокирует весь входящий трафик от IP, включая SSH и другие службы. IPv6 и транзитный трафик через `forward` не блокируются. Это агент для IPv4-клиентов, подключающихся к локальной службе входного сервера.

При каждом запуске агент восстанавливает неистёкшие баны из журнала, даже если API недоступен. После перезагрузки восстановление произойдёт при первом запуске включённого таймера (не мгновенно при загрузке системы). Оставшийся срок сохраняется; более короткий бан из другой панели не сокращает существующий. Перевод системных часов влияет на абсолютные сроки.

Отключение таймера останавливает опрос, но не снимает баны. Ручное удаление элемента из nftables тоже не снимает запись из журнала: она восстановится при следующем запуске. Для восстановления без обращения к API:

```bash
sudo /opt/torrent-blocker/torrent-blocker --restore
```

Обновляйте скрипт и `common.sh` вместе через установщик. При обновлении таймер и выполняющийся сервис останавливаются перед заменой файлов; после успешной установки таймер включается снова. Если установка прервалась, устраните ошибку и запустите её повторно.

## Проверки разработки

```bash
bash -n common.sh install.sh torrent-blocker
shellcheck -x common.sh install.sh torrent-blocker
python3 -m unittest discover -s tests -v
```

Нужны Bash, Python 3, jq, nftables и util-linux. Тесты API используют заглушки. Проверка реального nftables выполняется только в отдельном user/network namespace и пропускается, если среда это запрещает. CI запускает синтаксическую проверку, ShellCheck и тесты.

## Удаление

```bash
sudo systemctl disable --now torrent-blocker.timer
sudo systemctl stop torrent-blocker.service

sudo rm -f /etc/systemd/system/torrent-blocker.service
sudo rm -f /etc/systemd/system/torrent-blocker.timer
sudo systemctl daemon-reload

sudo rm -rf /opt/torrent-blocker/
sudo rm -f /usr/local/bin/torrent-blocker

# Только если удалены ВСЕ экземпляры Torrent Blocker на сервере:
sudo nft delete table inet torrent_guard
sudo rm -rf /var/lib/torrent-blocker/
```

Для дополнительных панелей удалите их собственные units, каталог и команду меню. Общую таблицу и журнал сохраняйте, пока ими пользуется хотя бы один экземпляр.

## Лицензия

MIT License.
