#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/torrent-blocker"

SERVICE_SRC="${PROJECT_DIR}/systemd/torrent-blocker.service"
TIMER_SRC="${PROJECT_DIR}/systemd/torrent-blocker.timer"

SERVICE_DST="/etc/systemd/system/torrent-blocker.service"
TIMER_DST="/etc/systemd/system/torrent-blocker.timer"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ошибка: установку нужно запускать от root"
  exit 1
fi

if [[ ! -f "${PROJECT_DIR}/torrent-blocker" ]]; then
  echo "Ошибка: не найден файл ${PROJECT_DIR}/torrent-blocker"
  exit 1
fi

if [[ ! -f "${PROJECT_DIR}/menu" ]]; then
  echo "Ошибка: не найден файл ${PROJECT_DIR}/menu"
  exit 1
fi

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "Ошибка: не найден файл $SERVICE_SRC"
  exit 1
fi

if [[ ! -f "$TIMER_SRC" ]]; then
  echo "Ошибка: не найден файл $TIMER_SRC"
  exit 1
fi

echo
echo "╭────────────────────────────────────╮"
echo "│     Установка Torrent Blocker      │"
echo "╰────────────────────────────────────╯"
echo

echo "Установка зависимостей..."
apt update
apt install -y curl jq nftables ca-certificates nano

systemctl enable --now nftables

echo
echo "Создание директории ${APP_DIR}..."
mkdir -p "${APP_DIR}"
chmod 700 "${APP_DIR}"

echo "Копирование файлов..."
install -m 700 "${PROJECT_DIR}/torrent-blocker" "${APP_DIR}/torrent-blocker"
install -m 700 "${PROJECT_DIR}/menu" "${APP_DIR}/menu"

if [[ ! -f "${APP_DIR}/.env" ]]; then
  echo
  read -rp "Remnawave API URL, пример https://admin.example.com: " REMNAWAVE_API_BASE

  if [[ -z "$REMNAWAVE_API_BASE" ]]; then
    echo "Ошибка: Remnawave API URL не может быть пустым"
    exit 1
  fi

  read -rsp "Remnawave API token: " REMNAWAVE_API_TOKEN
  echo

  if [[ -z "$REMNAWAVE_API_TOKEN" ]]; then
    echo "Ошибка: Remnawave API token не может быть пустым"
    exit 1
  fi

  read -rp "Время блокировки [1h]: " BAN_TIMEOUT
  BAN_TIMEOUT="${BAN_TIMEOUT:-1h}"

  if ! [[ "$BAN_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
    echo "Ошибка: время блокировки должно быть в формате 30s, 30m, 1h или 1d"
    exit 1
  fi

  cat > "${APP_DIR}/.env" <<EOF
REMNAWAVE_API_BASE="${REMNAWAVE_API_BASE%/}"
REMNAWAVE_API_TOKEN="${REMNAWAVE_API_TOKEN}"

BAN_TIMEOUT="${BAN_TIMEOUT}"
PAGE_SIZE="100"
MAX_PAGES="5"

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ADMIN_ID=""
EOF

  chmod 600 "${APP_DIR}/.env"
else
  echo "Файл ${APP_DIR}/.env уже существует, не перезаписываю"
fi

touch "${APP_DIR}/last_id"
chmod 600 "${APP_DIR}/last_id"

if [[ ! -s "${APP_DIR}/last_id" ]]; then
  echo
  read -rp "Пропустить старые torrent reports? [Y/n]: " SKIP_OLD
  SKIP_OLD="${SKIP_OLD:-Y}"

  if [[ "$SKIP_OLD" =~ ^[YyДд]$ ]]; then
    set -a
    source "${APP_DIR}/.env"
    set +a

    echo "Получение текущего последнего report id..."

    if ! CURRENT_MAX_ID="$(curl -fsS \
      --connect-timeout 10 \
      --retry 2 \
      -H "Authorization: Bearer ${REMNAWAVE_API_TOKEN}" \
      -H "Accept: application/json" \
      "${REMNAWAVE_API_BASE%/}/api/node-plugins/torrent-blocker?size=100&start=0" \
      | jq -r '[.response.records[]?.id // 0] | max // 0')"; then

      echo "Ошибка: не удалось получить reports из Remnawave API"
      echo "Проверь URL панели и API-токен"
      exit 1
    fi

    echo "${CURRENT_MAX_ID}" > "${APP_DIR}/last_id"
    echo "Старые reports пропущены. last_id=${CURRENT_MAX_ID}"
  else
    echo "0" > "${APP_DIR}/last_id"
    echo "Старые reports будут обработаны с id > 0"
  fi
fi

echo
echo "Создание nftables ban-list..."

nft add table inet torrent_guard 2>/dev/null || true
nft add set inet torrent_guard blocked_ipv4 '{ type ipv4_addr; flags timeout; }' 2>/dev/null || true
nft add chain inet torrent_guard input '{ type filter hook input priority -110; policy accept; }' 2>/dev/null || true

if ! nft list chain inet torrent_guard input 2>/dev/null | grep -q 'ip saddr @blocked_ipv4 drop'; then
  nft add rule inet torrent_guard input ip saddr @blocked_ipv4 drop
fi

echo
echo "Установка systemd..."

install -m 644 "${SERVICE_SRC}" "${SERVICE_DST}"
install -m 644 "${TIMER_SRC}" "${TIMER_DST}"

ln -sf "${APP_DIR}/menu" /usr/local/bin/torrent-blocker-menu

systemctl daemon-reload
systemctl enable --now torrent-blocker.timer
systemctl restart torrent-blocker.timer

echo
echo "Готово."
echo
echo "Файлы установлены в:"
echo "  ${APP_DIR}"
echo
echo "Команды:"
echo "  torrent-blocker-menu"
echo "  /opt/torrent-blocker/torrent-blocker"
echo "  systemctl status torrent-blocker.timer --no-pager"
echo "  journalctl -u torrent-blocker.service -n 100 --no-pager"
echo "  nft list set inet torrent_guard blocked_ipv4"
echo