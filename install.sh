#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
PROJECT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd || pwd)"

INSTALL_REF="${INSTALL_REF:-main}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/atyonekilla/torrent-block-rw/${INSTALL_REF}}"
TMP_PROJECT_DIR=""

INSTANCE_NAME=""
APP_DIR=""
ENV_FILE=""

SERVICE_UNIT=""
TIMER_UNIT=""
SERVICE_DST=""
TIMER_DST=""
MENU_BIN=""

cleanup() {
  if [[ -n "$TMP_PROJECT_DIR" && -d "$TMP_PROJECT_DIR" ]]; then
    rm -rf "$TMP_PROJECT_DIR"
  fi
}

trap cleanup EXIT

prompt_input() {
  local prompt="$1"
  local value

  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$prompt" value </dev/tty || true
  elif [[ -t 0 ]]; then
    IFS= read -r -p "$prompt" value || true
  else
    echo "Ошибка: нужен интерактивный терминал для ввода настроек" >&2
    echo "Запусти установку из обычной SSH-сессии: curl ... | sudo bash" >&2
    exit 1
  fi

  printf '%s' "$value"
}

download_file() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "$(dirname "$target_path")"

  curl -fsSL \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 3 \
    --retry-delay 1 \
    -o "$target_path" \
    "${REPO_RAW_BASE%/}/${source_path}"
}

prepare_project_files() {
  if [[ -f "${PROJECT_DIR}/torrent-blocker" ]]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required to download project files"
    exit 1
  fi

  echo "Downloading Torrent Blocker files from ${REPO_RAW_BASE%/}..."

  TMP_PROJECT_DIR="$(mktemp -d)"
  download_file "torrent-blocker" "${TMP_PROJECT_DIR}/torrent-blocker"

  PROJECT_DIR="$TMP_PROJECT_DIR"
}

configure_instance() {
  local input

  input="${TORRENT_BLOCKER_INSTANCE:-${INSTANCE_NAME:-default}}"

  INSTANCE_NAME="${input:-default}"

  if ! [[ "$INSTANCE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    echo "Ошибка: имя установки может содержать только A-Z, a-z, 0-9 и дефис"
    exit 1
  fi

  if [[ "$INSTANCE_NAME" == "default" ]]; then
    APP_DIR="/opt/torrent-blocker"
    SERVICE_UNIT="torrent-blocker.service"
    TIMER_UNIT="torrent-blocker.timer"
    MENU_BIN="/usr/local/bin/torrent-blocker-menu"
  else
    APP_DIR="/opt/torrent-blocker-${INSTANCE_NAME}"
    SERVICE_UNIT="torrent-blocker-${INSTANCE_NAME}.service"
    TIMER_UNIT="torrent-blocker-${INSTANCE_NAME}.timer"
    MENU_BIN="/usr/local/bin/torrent-blocker-${INSTANCE_NAME}-menu"
  fi

  ENV_FILE="${APP_DIR}/.env"
  SERVICE_DST="/etc/systemd/system/${SERVICE_UNIT}"
  TIMER_DST="/etc/systemd/system/${TIMER_UNIT}"
}

default_ingress_node_name() {
  local host_name public_ip local_ip

  host_name="$(hostname 2>/dev/null || echo "unknown-host")"
  public_ip="$(curl -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"

  if [[ -z "$public_ip" ]]; then
    read -r local_ip _ < <(hostname -I 2>/dev/null || true)
  fi

  if [[ -n "$public_ip" ]]; then
    echo "${host_name} (${public_ip})"
  elif [[ -n "${local_ip:-}" ]]; then
    echo "${host_name} (${local_ip})"
  else
    echo "$host_name"
  fi
}

escape_env_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"

  echo "$value"
}

set_env() {
  local key="$1"
  local value="$2"
  local escaped_value
  local tmp

  escaped_value="$(escape_env_value "$value")"
  tmp="$(mktemp)"

  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$escaped_value" '
      BEGIN { q = sprintf("%c", 34) }
      $0 ~ "^" k "=" { $0 = k "=" q v q }
      { print }
    ' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    echo "${key}=\"${escaped_value}\"" >> "$tmp"
  fi

  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

get_env() {
  local key="$1"

  if [[ -f "$ENV_FILE" ]]; then
    grep "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- | sed 's/^"//; s/"$//' || true
  fi
}

ask_ingress_node_name() {
  local default_name

  default_name="$(default_ingress_node_name)"
  INGRESS_NODE_NAME="$(prompt_input "Имя входной ноды [${default_name}]: ")"
  INGRESS_NODE_NAME="${INGRESS_NODE_NAME:-$default_name}"
}

html_escape() {
  local value="${1:-}"

  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"

  echo "$value"
}

load_env() {
  set -a
  source "$ENV_FILE"
  set +a

  INSTANCE_NAME="${INSTANCE_NAME:-default}"
  SERVICE_UNIT="${SERVICE_UNIT:-torrent-blocker.service}"
  TIMER_UNIT="${TIMER_UNIT:-torrent-blocker.timer}"
  MENU_BIN="${MENU_BIN:-/usr/local/bin/torrent-blocker-menu}"

  BAN_TIMEOUT="${BAN_TIMEOUT:-1h}"
  PAGE_SIZE="${PAGE_SIZE:-100}"
  MAX_PAGES="${MAX_PAGES:-5}"
  INGRESS_NODE_NAME="${INGRESS_NODE_NAME:-$(default_ingress_node_name)}"

  TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-false}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_ADMIN_ID="${TELEGRAM_ADMIN_ID:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-${TELEGRAM_ADMIN_ID}}"
  TELEGRAM_TOPIC_ID="${TELEGRAM_TOPIC_ID:-}"
}

fetch_remnawave_reports() {
  local size="$1"
  local start="$2"
  local url body_file http_code first_char

  url="${REMNAWAVE_API_BASE%/}/api/node-plugins/torrent-blocker?size=${size}&start=${start}"
  body_file="$(mktemp)"

  if ! http_code="$(curl -sS \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 2 \
    --retry-delay 1 \
    -H "Authorization: Bearer ${REMNAWAVE_API_TOKEN}" \
    -H "Accept: application/json" \
    -o "$body_file" \
    -w "%{http_code}" \
    "$url")"; then

    rm -f "$body_file"
    echo "Ошибка: не удалось подключиться к Remnawave API" >&2
    echo "URL: $url" >&2
    return 1
  fi

  if [[ ! "$http_code" =~ ^2 ]]; then
    echo "Ошибка: Remnawave API вернул HTTP $http_code" >&2
    echo "URL: $url" >&2
    echo "Ответ:" >&2
    head -c 800 "$body_file" >&2
    echo >&2
    rm -f "$body_file"
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$body_file" >/dev/null 2>&1; then
      echo "Ошибка: Remnawave API вернул не JSON" >&2
      echo "URL: $url" >&2
      echo "Ответ:" >&2
      head -c 800 "$body_file" >&2
      echo >&2
      rm -f "$body_file"
      return 1
    fi
  else
    first_char="$(awk '{ gsub(/[[:space:]]/, ""); if (length($0) > 0) { print substr($0, 1, 1); exit } }' "$body_file")"

    if [[ "$first_char" != "{" && "$first_char" != "[" ]]; then
      echo "Ошибка: Remnawave API вернул не JSON" >&2
      echo "URL: $url" >&2
      echo "Ответ:" >&2
      head -c 800 "$body_file" >&2
      echo >&2
      rm -f "$body_file"
      return 1
    fi
  fi

  cat "$body_file"
  rm -f "$body_file"
}

check_remnawave_panel() {
  echo
  echo "Проверка доступности панели Remnawave..."

  if [[ -z "${REMNAWAVE_API_BASE:-}" ]]; then
    echo "Ошибка: REMNAWAVE_API_BASE не задан"
    return 1
  fi

  if [[ -z "${REMNAWAVE_API_TOKEN:-}" ]]; then
    echo "Ошибка: REMNAWAVE_API_TOKEN не задан"
    return 1
  fi

  if ! fetch_remnawave_reports 1 0 >/dev/null; then
    echo "Проверь URL панели, API-токен и доступ с сервера к панели."
    return 1
  fi

  echo "ОК: панель доступна, API-токен работает"
}

collect_new_config() {
  echo
  REMNAWAVE_API_BASE="$(prompt_input "Remnawave API URL, пример https://admin.example.com: ")"

  if [[ -z "$REMNAWAVE_API_BASE" ]]; then
    echo "Ошибка: Remnawave API URL не может быть пустым"
    exit 1
  fi

  REMNAWAVE_API_BASE="${REMNAWAVE_API_BASE%/}"

  REMNAWAVE_API_TOKEN="$(prompt_input "Remnawave API token: ")"

  if [[ -z "$REMNAWAVE_API_TOKEN" ]]; then
    echo "Ошибка: Remnawave API token не может быть пустым"
    exit 1
  fi

  check_remnawave_panel

  BAN_TIMEOUT="$(prompt_input "Время блокировки [1h]: ")"
  BAN_TIMEOUT="${BAN_TIMEOUT:-1h}"

  if ! [[ "$BAN_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
    echo "Ошибка: время блокировки должно быть в формате 30s, 30m, 1h или 1d"
    exit 1
  fi

  PAGE_SIZE="100"
  MAX_PAGES="5"

  ask_ingress_node_name

  TELEGRAM_ENABLED="false"
  TELEGRAM_BOT_TOKEN=""
  TELEGRAM_CHAT_ID=""
  TELEGRAM_TOPIC_ID=""
}

write_env_file() {
  cat > "$ENV_FILE" <<EOF
INSTANCE_NAME="${INSTANCE_NAME}"
SERVICE_UNIT="${SERVICE_UNIT}"
TIMER_UNIT="${TIMER_UNIT}"
MENU_BIN="${MENU_BIN}"

REMNAWAVE_API_BASE="${REMNAWAVE_API_BASE%/}"
REMNAWAVE_API_TOKEN="${REMNAWAVE_API_TOKEN}"

INGRESS_NODE_NAME="$(escape_env_value "$INGRESS_NODE_NAME")"

BAN_TIMEOUT="${BAN_TIMEOUT}"
PAGE_SIZE="${PAGE_SIZE:-100}"
MAX_PAGES="${MAX_PAGES:-5}"

TELEGRAM_ENABLED="${TELEGRAM_ENABLED}"
TELEGRAM_BOT_TOKEN="$(escape_env_value "$TELEGRAM_BOT_TOKEN")"
TELEGRAM_CHAT_ID="$(escape_env_value "$TELEGRAM_CHAT_ID")"
TELEGRAM_TOPIC_ID="$(escape_env_value "$TELEGRAM_TOPIC_ID")"
EOF

  chmod 600 "$ENV_FILE"
}

install_dependencies() {
  local -a packages missing_packages
  local package

  packages=(curl jq nftables util-linux ca-certificates nano)
  missing_packages=()

  for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
      missing_packages+=("$package")
    fi
  done

  if (( ${#missing_packages[@]} == 0 )); then
    echo "Все зависимости уже установлены, пропускаю apt install"
    return 0
  fi

  echo "Установка недостающих зависимостей: ${missing_packages[*]}"
  apt update
  apt install -y "${missing_packages[@]}"
}

write_systemd_units() {
  cat > "$SERVICE_DST" <<EOF
[Unit]
Description=Torrent Blocker (${INSTANCE_NAME}) - опрос Remnawave reports и локальная блокировка IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/torrent-blocker
EOF

  cat > "$TIMER_DST" <<EOF
[Unit]
Description=Запуск Torrent Blocker (${INSTANCE_NAME}) каждые 15 секунд

[Timer]
OnBootSec=30
OnUnitActiveSec=15s
AccuracySec=1s
Unit=${SERVICE_UNIT}

[Install]
WantedBy=timers.target
EOF
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ошибка: установку нужно запускать от root"
  exit 1
fi

prepare_project_files
configure_instance

echo
echo "╭────────────────────────────────────╮"
echo "│     Установка Torrent Blocker      │"
echo "╰────────────────────────────────────╯"
echo "Установка: ${INSTANCE_NAME}"
echo "Каталог:   ${APP_DIR}"
echo

HAS_EXISTING_ENV="false"

if [[ -f "${APP_DIR}/.env" ]]; then
  HAS_EXISTING_ENV="true"
  echo "Файл $ENV_FILE уже существует, не перезаписываю"
  load_env
  check_remnawave_panel
else
  collect_new_config
fi

echo
install_dependencies

systemctl enable --now nftables

echo
echo "Создание директории ${APP_DIR}..."
mkdir -p "${APP_DIR}"
chmod 700 "${APP_DIR}"

echo "Копирование файлов..."
install -m 700 "${PROJECT_DIR}/torrent-blocker" "${APP_DIR}/torrent-blocker"
rm -f "${APP_DIR}/menu"

if [[ "$HAS_EXISTING_ENV" == "false" ]]; then
  write_env_file
else
  set_env "INSTANCE_NAME" "$INSTANCE_NAME"
  set_env "SERVICE_UNIT" "$SERVICE_UNIT"
  set_env "TIMER_UNIT" "$TIMER_UNIT"
  set_env "MENU_BIN" "$MENU_BIN"

  if [[ -z "$(get_env INGRESS_NODE_NAME)" ]]; then
    echo
    echo "В конфиге не задано имя входной ноды."
    ask_ingress_node_name
    set_env "INGRESS_NODE_NAME" "$INGRESS_NODE_NAME"
  fi
fi

load_env

touch "${APP_DIR}/last_id"
chmod 600 "${APP_DIR}/last_id"

if [[ ! -s "${APP_DIR}/last_id" ]]; then
  echo
  SKIP_OLD="$(prompt_input "Пропустить старые torrent reports? [Y/n]: ")"
  SKIP_OLD="${SKIP_OLD:-Y}"

  if [[ "$SKIP_OLD" =~ ^[YyДд]$ ]]; then
    set -a
    source "${APP_DIR}/.env"
    set +a

    echo "Получение текущего последнего report id..."

    if ! CURRENT_MAX_ID="$(fetch_remnawave_reports 100 0 | jq -r '[.response.records[]?.id // 0] | max // 0')"; then

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

write_systemd_units

ln -sf "${APP_DIR}/torrent-blocker" "$MENU_BIN"

systemctl daemon-reload
systemctl enable --now "$TIMER_UNIT"
systemctl restart "$TIMER_UNIT"

echo
echo "Готово."
echo
echo "Файлы установлены в:"
echo "  ${APP_DIR}"
echo
echo "Команды:"
echo "  ${MENU_BIN##*/}                                  - меню управления"
echo "  ${APP_DIR}/torrent-blocker --menu                - меню напрямую"
echo "  ${APP_DIR}/torrent-blocker                       - проверка сейчас"
echo "  systemctl status ${TIMER_UNIT} --no-pager        - статус таймера"
echo "  journalctl -u ${SERVICE_UNIT} -n 100 --no-pager  - последние логи"
echo "  nft list set inet torrent_guard blocked_ipv4     - заблокированные IP"
echo
