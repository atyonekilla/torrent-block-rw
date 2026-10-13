#!/usr/bin/env bash
# Shared installer/runtime helpers. Configuration is data, never shell code.

prompt_input() (
  local prompt="$1" secret="${2:-false}" value="" tty_fd status=0 tty_settings=""
  if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
    echo "Ошибка: нужен интерактивный терминал для ввода настроек (SSH с TTY)." >&2
    return 1
  fi
  trap 'if [[ -n "$tty_settings" ]]; then stty "$tty_settings" <&"$tty_fd"; fi; exec {tty_fd}>&-' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  if [[ "$secret" == true ]]; then
    tty_settings="$(stty -g <&"$tty_fd")" || return 1
    # Disable echo before displaying the prompt, including fast paste/autofill.
    stty -echo <&"$tty_fd" || return 1
  fi
  printf '%s' "$prompt" >&"$tty_fd"
  IFS= read -r -u "$tty_fd" value || status=$?
  if [[ "$secret" == true ]]; then
    printf '\n' >&"$tty_fd"
  fi
  if (( status != 0 )); then
    printf '\nОшибка: ввод прерван.\n' >&"$tty_fd"
    return 1
  fi
  printf '%s' "$value"
)

config_key_allowed() {
  case "$1" in
    INSTANCE_NAME|SERVICE_UNIT|TIMER_UNIT|MENU_BIN|REMNAWAVE_API_BASE|REMNAWAVE_API_TOKEN|INGRESS_NODE_NAME|BAN_TIMEOUT|PAGE_SIZE|MAX_PAGES|REPORT_NODE_NAME|ALLOWLIST_IPV4) return 0 ;;
    # Historical settings are retained as data for upgrades; no notifications are sent.
    TELEGRAM_ENABLED|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|TELEGRAM_TOPIC_ID) return 0 ;;
    *) return 1 ;;
  esac
}

escape_env_value() {
  local value="${1:-}"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '%s' "$value"
}

load_config_file() {
  local file="$1" line key raw value char next i number=0
  [[ -f "$file" ]] || { echo "Ошибка: не найден конфиг $file" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if ! [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      echo "Ошибка: неверная строка конфига $number" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}" raw="${BASH_REMATCH[2]}"
    config_key_allowed "$key" || { echo "Ошибка: неизвестный ключ $key" >&2; return 1; }
    value="$raw"
    if [[ "$raw" == \"* ]]; then
      [[ ${#raw} -ge 2 && "$raw" == *\" ]] || return 1
      raw="${raw:1:${#raw}-2}"
      value=""
      for ((i=0; i<${#raw}; i++)); do
        char="${raw:i:1}"
        if [[ "$char" == \\ ]]; then
          next="${raw:i+1:1}"
          case "$next" in
            \\|'"'|'$'|'`') char="$next"; i=$((i + 1)) ;;
          esac
        elif [[ "$char" == '"' ]]; then
          echo "Ошибка: неэкранированная кавычка в строке $number" >&2
          return 1
        fi
        value+="$char"
      done
    elif [[ "$raw" == \'* ]]; then
      [[ ${#raw} -ge 2 && "$raw" == *\' ]] || return 1
      value="${raw:1:${#raw}-2}"
    fi
    printf -v "$key" '%s' "$value"
  done < "$file"
}

get_env() (
  local key="$1"
  config_key_allowed "$key" || return 1
  [[ -f "$ENV_FILE" ]] || return 0
  load_config_file "$ENV_FILE" || return 1
  printf '%s' "${!key-}"
)

set_env() {
  local key="$1" value="$2" tmp line found=false escaped
  config_key_allowed "$key" || return 1
  escaped="$(escape_env_value "$value")" || return 1
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      if [[ "$found" == false ]]; then
        printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"
        found=true
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$ENV_FILE"
  if [[ "$found" == false ]]; then
    printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
}

validate_timeout() {
  [[ "$1" =~ ^[1-9][0-9]{0,5}[smhd]$ ]] || {
    echo "Ошибка: время блокировки должно быть положительным: 30s, 30m, 1h или 1d (до 999999 единиц)." >&2
    return 1
  }
}

timeout_seconds() {
  local value="${1%?}" unit="${1: -1}"
  case "$unit" in
    s) printf '%s' "$value" ;;
    m) printf '%s' "$((value * 60))" ;;
    h) printf '%s' "$((value * 3600))" ;;
    d) printf '%s' "$((value * 86400))" ;;
  esac
}

validate_pagination() {
  if ! [[ "$1" =~ ^[1-9][0-9]{0,2}$ ]] || (( $1 > 500 )); then
    echo "Ошибка: PAGE_SIZE должен быть числом от 1 до 500 без ведущих нулей." >&2
    return 1
  fi
  if ! [[ "$2" =~ ^[1-9][0-9]?$ ]] || (( $2 > 50 )); then
    echo "Ошибка: MAX_PAGES должен быть числом от 1 до 50 без ведущих нулей." >&2
    return 1
  fi
}

validate_api_config() {
  [[ "$1" =~ ^https://[^/?#[:space:]]+(/[^?#[:space:]]*)?$ ]] || {
    echo "Ошибка: URL панели должен использовать HTTPS без query/fragment." >&2
    return 1
  }
  [[ -n "$2" && "$2" != *$'\n'* && "$2" != *$'\r'* ]] || {
    echo "Ошибка: API-токен пуст или содержит перевод строки." >&2
    return 1
  }
}

validate_reports() {
  jq -e '
    def valid_id:
      (type == "number" or (type == "string" and test("^[0-9]+$")))
      and (tonumber > 0 and tonumber <= 9007199254740991 and (tonumber | floor) == tonumber);
    def optional_object: . == null or type == "object";
    type == "object" and (.response | type == "object")
    and (.response.records | type == "array")
    and all(.response.records[];
      type == "object" and (.id | valid_id)
      and (.report | type == "object")
      and (.report.actionReport | optional_object)
      and (.report.xrayReport | optional_object)
      and (.node | optional_object) and (.user | optional_object)
      and all([.report.actionReport.ip, .report.actionReport.clientIp, .report.actionReport.client_ip,
        .report.xrayReport.source, .report.xrayReport.sourceIp, .report.xrayReport.protocol,
        .report.xrayReport.outboundTag, .report.xrayReport.outbound, .node.name, .nodeName][];
        . == null or type == "string")
      and all([.report.actionReport.blocked, .report.actionReport.isBlocked][];
        . == null or type == "boolean"))
    and ((.response.records | map(.id | tonumber)) ==
      (.response.records | map(.id | tonumber) | sort | reverse))
  ' "$1" >/dev/null 2>&1
}

fetch_reports() {
  local api_base="$1" api_token="$2" size="$3" start="$4"
  local body_file header_file http_code
  validate_api_config "$api_base" "$api_token" || return 1
  body_file="$(mktemp)" || return 1
  header_file="$(mktemp)" || { rm -f "$body_file"; return 1; }
  printf 'Authorization: Bearer %s\nAccept: application/json\n' "$api_token" > "$header_file"
  if ! http_code="$(curl -sS --proto '=https' --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-delay 1 -H "@$header_file" -o "$body_file" -w '%{http_code}' \
    "${api_base%/}/api/node-plugins/torrent-blocker?size=${size}&start=${start}")"; then
    rm -f "$body_file" "$header_file"
    echo "Ошибка: не удалось подключиться к Remnawave API" >&2
    return 1
  fi
  rm -f "$header_file"
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]] || ! validate_reports "$body_file"; then
    echo "Ошибка: Remnawave API: HTTP $http_code или неверная структура reports." >&2
    rm -f "$body_file"
    return 1
  fi
  jq '.response.records |= map(.id |= tonumber)' "$body_file"
  local status=$?
  rm -f "$body_file"
  return "$status"
}

# Write a complete config atomically; reject multiline values before publishing it.
write_config_file() {
  local target="$1" tmp key value escaped
  shift
  tmp="$(mktemp "${target}.XXXXXX")" || return 1
  while (( $# > 0 )); do
    key="$1" value="$2"
    shift 2
    if ! config_key_allowed "$key" || ! escaped="$(escape_env_value "$value")" ||
        ! printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  done
  mv "$tmp" "$target"
}
