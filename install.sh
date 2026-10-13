#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
PROJECT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"

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
  if [[ -f "${PROJECT_DIR}/torrent-blocker" && -f "${PROJECT_DIR}/common.sh" ]]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required to download project files"
    exit 1
  fi

  echo "Downloading Torrent Blocker files from ${REPO_RAW_BASE%/}..."

  TMP_PROJECT_DIR="$(mktemp -d)"
  download_file "torrent-blocker" "${TMP_PROJECT_DIR}/torrent-blocker"
  download_file "common.sh" "${TMP_PROJECT_DIR}/common.sh"

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
    MENU_BIN="/usr/local/bin/torrent-blocker"
  else
    APP_DIR="/opt/torrent-blocker-${INSTANCE_NAME}"
    SERVICE_UNIT="torrent-blocker-${INSTANCE_NAME}.service"
    TIMER_UNIT="torrent-blocker-${INSTANCE_NAME}.timer"
    MENU_BIN="/usr/local/bin/torrent-blocker-${INSTANCE_NAME}"
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
    read -r local_ip _ < <(hostname -I 2>/dev/null || true) || true
  fi

  if [[ -n "$public_ip" ]]; then
    echo "${host_name} (${public_ip})"
  elif [[ -n "${local_ip:-}" ]]; then
    echo "${host_name} (${local_ip})"
  else
    echo "$host_name"
  fi
}







load_env() {
  load_config_file "$ENV_FILE" || return 1

  INSTANCE_NAME="${INSTANCE_NAME:-default}"
  SERVICE_UNIT="${SERVICE_UNIT:-torrent-blocker.service}"
  TIMER_UNIT="${TIMER_UNIT:-torrent-blocker.timer}"
  MENU_BIN="${MENU_BIN:-/usr/local/bin/torrent-blocker}"

  BAN_TIMEOUT="${BAN_TIMEOUT:-1h}"
  PAGE_SIZE="${PAGE_SIZE:-100}"
  MAX_PAGES="${MAX_PAGES:-5}"
  INGRESS_NODE_NAME="${INGRESS_NODE_NAME:-$(default_ingress_node_name)}"
  validate_timeout "$BAN_TIMEOUT" || return 1
  validate_pagination "$PAGE_SIZE" "$MAX_PAGES" || return 1
}

fetch_remnawave_reports() {
  fetch_reports "$REMNAWAVE_API_BASE" "$REMNAWAVE_API_TOKEN" "$1" "$2"
}

check_remnawave_panel() {
  local check_error

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

  if ! check_error="$(fetch_remnawave_reports 1 0 2>&1 >/dev/null)"; then
    if [[ -n "$check_error" ]]; then
      echo "$check_error"
    fi

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

  REMNAWAVE_API_TOKEN="$(prompt_input "Remnawave API token (ввод скрыт): " true)"

  if [[ -z "$REMNAWAVE_API_TOKEN" ]]; then
    echo "Ошибка: Remnawave API token не может быть пустым"
    exit 1
  fi

  check_remnawave_panel

  BAN_TIMEOUT="$(prompt_input "Время блокировки [1h]: ")"
  BAN_TIMEOUT="${BAN_TIMEOUT:-1h}"

  validate_timeout "$BAN_TIMEOUT" || return 1

  PAGE_SIZE="100"
  MAX_PAGES="5"
  INGRESS_NODE_NAME="$(default_ingress_node_name)"
}

write_env_file() {
  write_config_file "$ENV_FILE" \
    INSTANCE_NAME "$INSTANCE_NAME" SERVICE_UNIT "$SERVICE_UNIT" TIMER_UNIT "$TIMER_UNIT" MENU_BIN "$MENU_BIN" \
    REMNAWAVE_API_BASE "${REMNAWAVE_API_BASE%/}" REMNAWAVE_API_TOKEN "$REMNAWAVE_API_TOKEN" \
    INGRESS_NODE_NAME "$INGRESS_NODE_NAME" BAN_TIMEOUT "$BAN_TIMEOUT" \
    PAGE_SIZE "${PAGE_SIZE:-100}" MAX_PAGES "${MAX_PAGES:-5}" REPORT_NODE_NAME "" ALLOWLIST_IPV4 ""
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
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/torrent-blocker --run
EOF

  cat > "$TIMER_DST" <<EOF
[Unit]
Description=Запуск Torrent Blocker (${INSTANCE_NAME}) каждые 15 секунд

[Timer]
OnBootSec=5
OnUnitActiveSec=15s
AccuracySec=1s
Unit=${SERVICE_UNIT}

[Install]
WantedBy=timers.target
EOF
}

write_menu_command() {
  mkdir -p "$(dirname "$MENU_BIN")"
  rm -f "$MENU_BIN"

  cat > "$MENU_BIN" <<EOF
#!/usr/bin/env bash
exec "${APP_DIR}/torrent-blocker" --menu "\$@"
EOF

  chmod 755 "$MENU_BIN"

  if [[ "$INSTANCE_NAME" == "default" ]]; then
    rm -f /usr/local/bin/torrent-blocker-menu
  else
    rm -f "/usr/local/bin/torrent-blocker-${INSTANCE_NAME}-menu"
  fi
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Ошибка: установку нужно запускать от root"
    exit 1
  fi

  if ! command -v apt >/dev/null || ! command -v dpkg-query >/dev/null || ! command -v systemctl >/dev/null; then
    echo "Ошибка: установщик поддерживает Debian/Ubuntu с systemd." >&2
    exit 1
  fi
  prepare_project_files
  source "${PROJECT_DIR}/common.sh"
  install_dependencies
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
    configure_instance
    check_remnawave_panel
  else
    collect_new_config
  fi


  echo
  echo "Создание директории ${APP_DIR}..."
  mkdir -p "${APP_DIR}"
  chmod 700 "${APP_DIR}"

  # Stop scheduled work before replacing executable/config files.
  for existing_unit in "$TIMER_UNIT" "$SERVICE_UNIT"; do
    if systemctl cat "$existing_unit" >/dev/null 2>&1; then
      systemctl stop "$existing_unit"
    fi
  done
  exec 9>"${APP_DIR}/torrent-blocker.lock"
  flock -x 9

  echo "Копирование файлов..."
  install -m 700 "${PROJECT_DIR}/torrent-blocker" "${APP_DIR}/torrent-blocker"
  install -m 600 "${PROJECT_DIR}/common.sh" "${APP_DIR}/common.sh"
  rm -f "${APP_DIR}/menu"

  if [[ "$HAS_EXISTING_ENV" == "false" ]]; then
    write_env_file
  else
    set_env "INSTANCE_NAME" "$INSTANCE_NAME"
    set_env "SERVICE_UNIT" "$SERVICE_UNIT"
    set_env "TIMER_UNIT" "$TIMER_UNIT"
    set_env "MENU_BIN" "$MENU_BIN"

    if [[ -z "$(get_env INGRESS_NODE_NAME)" ]]; then
      INGRESS_NODE_NAME="$(default_ingress_node_name)"
      set_env "INGRESS_NODE_NAME" "$INGRESS_NODE_NAME"
    fi
  fi

  load_env

  touch "${APP_DIR}/last_id"
  chmod 600 "${APP_DIR}/last_id"

  if [[ ! -s "${APP_DIR}/last_id" ]]; then
    echo
    load_config_file "${APP_DIR}/.env"

    echo "Получение текущего последнего report id..."

    if ! CURRENT_MAX_ID="$(fetch_remnawave_reports 100 0 | jq -r '[.response.records[]?.id // 0] | max // 0')"; then

      echo "Ошибка: не удалось получить reports из Remnawave API"
      echo "Проверь URL панели и API-токен"
      exit 1
    fi

    echo "${CURRENT_MAX_ID}" > "${APP_DIR}/last_id"
    echo "Старые reports пропущены. last_id=${CURRENT_MAX_ID}"
  fi

  echo
  echo "Создание nftables ban-list..."

  "${APP_DIR}/torrent-blocker" --restore

  echo
  echo "Установка systemd..."

  write_systemd_units
  write_menu_command

  systemctl daemon-reload
  flock -u 9
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
  echo "  ${APP_DIR}/torrent-blocker --run                 - проверка сейчас"
  echo "  systemctl status ${TIMER_UNIT} --no-pager        - статус таймера"
  echo "  journalctl -u ${SERVICE_UNIT} -n 100 --no-pager  - последние логи"
  echo "  nft list set inet torrent_guard blocked_ipv4     - заблокированные IP"
  echo

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
