#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
PROJECT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"

INSTALL_REF="${INSTALL_REF:-main}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/atyonekilla/torrent-block-rw/${INSTALL_REF}}"
TMP_PROJECT_DIR=""
INSTALL_FROM_STDIN=false
[[ -n "${BASH_SOURCE[0]:-}" ]] || INSTALL_FROM_STDIN=true
UPDATE_STAGE=""
BACKUP_DIR=""
UPDATE_IN_PROGRESS=false
UPDATE_FILES_DIRTY=false
UPDATE_TIMER_WAS_ACTIVE=false
UPDATE_TARGETS=()
INSTALL_LOCK_DIR="${TORRENT_BLOCKER_INSTALL_LOCK_DIR:-/run/lock}"

INSTANCE_NAME=""
APP_DIR=""
ENV_FILE=""

SERVICE_UNIT=""
TIMER_UNIT=""
SERVICE_DST=""
TIMER_DST=""
MENU_BIN=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ "$UPDATE_IN_PROGRESS" == true ]]; then
    echo "Обновление прервано; восстанавливаю предыдущую версию..." >&2
    if ! rollback_update; then
      echo "Ошибка отката. Резервная копия: $BACKUP_DIR. Проверьте сервис перед запуском." >&2
      status=1
    fi
  fi
  if [[ -n "$UPDATE_STAGE" && -d "$UPDATE_STAGE" ]]; then
    rm -rf "$UPDATE_STAGE"
  fi
  if [[ -n "$TMP_PROJECT_DIR" && -d "$TMP_PROJECT_DIR" ]]; then
    rm -rf "$TMP_PROJECT_DIR"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

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
  if [[ "$INSTALL_FROM_STDIN" == false && -f "${PROJECT_DIR}/torrent-blocker" && -f "${PROJECT_DIR}/common.sh" ]]; then
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

stage_systemd_units() {
  local SERVICE_DST="$1" TIMER_DST="$2"
  write_systemd_units
}

validate_project_files() {
  local file
  for file in torrent-blocker common.sh; do
    [[ -s "$PROJECT_DIR/$file" ]] || { echo "Ошибка: не загружен $file" >&2; return 1; }
    bash -n "$PROJECT_DIR/$file" || return 1
  done
}

acquire_install_lock() {
  exec 7>"${INSTALL_LOCK_DIR}/torrent-blocker-install-${INSTANCE_NAME}.lock"
  if ! flock -n 7; then
    echo "Ошибка: установка/обновление этого экземпляра уже выполняется." >&2
    return 1
  fi
}

atomic_install() {
  local source_file="$1" target="$2" mode="$3" tmp
  tmp="$(mktemp "${target}.XXXXXX")" || return 1
  if ! install -m "$mode" "$source_file" "$tmp" || ! mv -Tf "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}

backup_update_files() {
  local i target
  mkdir -p "$APP_DIR/backups"
  chmod 700 "$APP_DIR/backups"
  BACKUP_DIR="$(mktemp -d "$APP_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
  mkdir "$BACKUP_DIR/files"
  for i in "${!UPDATE_TARGETS[@]}"; do
    target="${UPDATE_TARGETS[$i]}"
    printf '%s\t%s\n' "$i" "$target" >> "$BACKUP_DIR/manifest.tsv"
    if [[ -e "$target" || -L "$target" ]]; then
      cp -a -- "$target" "$BACKUP_DIR/files/$i"
    fi
  done
  # For manual recovery only. Automatic rollback must not rewind live report data.
  cp -a -- "$ENV_FILE" "$BACKUP_DIR/config.env"
  cp -a -- "$APP_DIR/last_id" "$BACKUP_DIR/last_id"
}

rollback_update() {
  local i target tmp failed=false
  if [[ "$UPDATE_FILES_DIRTY" == true ]]; then
    systemctl stop "$TIMER_UNIT" || return 1
    for i in "${!UPDATE_TARGETS[@]}"; do
      target="${UPDATE_TARGETS[$i]}"
      if [[ -e "$BACKUP_DIR/files/$i" || -L "$BACKUP_DIR/files/$i" ]]; then
        tmp="$(mktemp -d "$(dirname "$target")/.torrent-blocker-rollback.XXXXXX")" || return 1
        if ! cp -a -- "$BACKUP_DIR/files/$i" "$tmp/item" || ! mv -Tf "$tmp/item" "$target"; then
          failed=true
        fi
        rm -rf "$tmp"
      else
        rm -f -- "$target" || failed=true
      fi
    done
    systemctl daemon-reload || failed=true
  fi
  if [[ "$failed" == false && "$UPDATE_TIMER_WAS_ACTIVE" == true ]]; then
    systemctl start "$TIMER_UNIT" || failed=true
  fi
  [[ "$failed" == false ]] || return 1
  echo "Предыдущая версия и состояние таймера восстановлены." >&2
}

update_existing_installation() {
  local expected_instance="$INSTANCE_NAME" expected_service="$SERVICE_UNIT"
  local expected_timer="$TIMER_UNIT" expected_menu="$MENU_BIN" menu_target
  local -a menu_targets=("$MENU_BIN")
  load_env
  if [[ "$INSTANCE_NAME" != "$expected_instance" || "$SERVICE_UNIT" != "$expected_service" ||
        "$TIMER_UNIT" != "$expected_timer" ||
        ( "$MENU_BIN" != "$expected_menu" && "$MENU_BIN" != "${expected_menu}-menu" ) ]]; then
    echo "Ошибка: нестандартные пути/имена units в конфиге. Автообновление остановлено без замены файлов." >&2
    return 1
  fi

  if [[ "$MENU_BIN" != "$expected_menu" ]]; then
    menu_targets+=("$MENU_BIN")
  fi
  UPDATE_STAGE="$(mktemp -d "$APP_DIR/.update.XXXXXX")"
  install -m 700 "$PROJECT_DIR/torrent-blocker" "$UPDATE_STAGE/torrent-blocker"
  install -m 600 "$PROJECT_DIR/common.sh" "$UPDATE_STAGE/common.sh"
  # Read-only validation with the new executable and the original configuration.
  TORRENT_BLOCKER_APP_DIR="$APP_DIR" bash "$UPDATE_STAGE/torrent-blocker" --check-config
  cat > "$UPDATE_STAGE/menu" <<EOF
#!/usr/bin/env bash
exec "${APP_DIR}/torrent-blocker" --menu "\$@"
EOF
  stage_systemd_units "$UPDATE_STAGE/service" "$UPDATE_STAGE/timer"
  mkdir -p "$(dirname "$MENU_BIN")"
  UPDATE_TARGETS=("$APP_DIR/torrent-blocker" "$APP_DIR/common.sh" "${menu_targets[@]}" "$SERVICE_DST" "$TIMER_DST")
  if systemctl is-active --quiet "$TIMER_UNIT"; then
    UPDATE_TIMER_WAS_ACTIVE=true
  fi
  UPDATE_IN_PROGRESS=true
  if [[ "$UPDATE_TIMER_WAS_ACTIVE" == true ]]; then
    systemctl stop "$TIMER_UNIT"
  fi
  # Let a running poll finish; do not interrupt it mid-report or mid-firewall update.
  exec 9>"$APP_DIR/torrent-blocker.lock"
  flock -w 300 -x 9
  backup_update_files
  UPDATE_FILES_DIRTY=true
  atomic_install "$UPDATE_STAGE/common.sh" "$APP_DIR/common.sh" 600
  atomic_install "$UPDATE_STAGE/torrent-blocker" "$APP_DIR/torrent-blocker" 700
  for menu_target in "${menu_targets[@]}"; do
    atomic_install "$UPDATE_STAGE/menu" "$menu_target" 755
  done
  # Preserve customized units, schedules, masks and all systemd drop-ins.
  if [[ ! -e "$SERVICE_DST" && ! -L "$SERVICE_DST" ]]; then
    atomic_install "$UPDATE_STAGE/service" "$SERVICE_DST" 644
  fi
  if [[ ! -e "$TIMER_DST" && ! -L "$TIMER_DST" ]]; then
    atomic_install "$UPDATE_STAGE/timer" "$TIMER_DST" 644
  fi
  systemctl daemon-reload
  TORRENT_BLOCKER_APP_DIR="$APP_DIR" bash "$APP_DIR/torrent-blocker" --check-config
  # start never changes enabled/disabled state. Disabled timers stay disabled.
  if [[ "$UPDATE_TIMER_WAS_ACTIVE" == true ]]; then
    systemctl start "$TIMER_UNIT"
  fi
  UPDATE_IN_PROGRESS=false
  flock -u 9
  echo "Обновление завершено. Конфиг, last_id, баны и настройки systemd сохранены."
  echo "Резервная копия: $BACKUP_DIR"
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
  validate_project_files
  source "${PROJECT_DIR}/common.sh"
  install_dependencies
  configure_instance
  acquire_install_lock

  echo
  echo "╭────────────────────────────────────╮"
  echo "│     Установка Torrent Blocker      │"
  echo "╰────────────────────────────────────╯"
  echo "Установка: ${INSTANCE_NAME}"
  echo "Каталог:   ${APP_DIR}"
  echo

  if [[ -f "$ENV_FILE" ]]; then
    echo "Обнаружена существующая установка. Обновляю без повторного ввода настроек."
    update_existing_installation
    return
  fi
  if [[ -e "$APP_DIR/torrent-blocker" ]]; then
    echo "Ошибка: найдена старая установка без .env. Восстановите конфиг перед обновлением." >&2
    return 1
  fi
  collect_new_config

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

  write_env_file

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

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
