#!/usr/bin/env bash

set +e
set +u
export LC_ALL=C
LOG_LINES=()
LOG_MIN=3
LOG_MAX=10

banner() {
  cat <<'EOF'
╔═════════════════════════════════════════════════════╗
║                                                     ║
║   ███████╗███████╗██████╗ ███████╗██╗  ██╗██████╗   ║
║   ██╔════╝██╔════╝██╔══██╗██╔════╝██║  ██║██╔══██╗  ║
║   ███████╗█████╗  ██████╔╝█████╗  ███████║██████╔╝  ║
║   ╚════██║██╔══╝  ██╔═══╝ ██╔══╝  ██╔══██║██╔══██╗  ║
║   ███████║███████╗██║     ███████╗██║  ██║██║  ██║  ║
║   ╚══════╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝  ║
║                                                     ║
║               k O J A I   B A B A ?                 ║
║                                                     ║
╚═════════════════════════════════════════════════════╝
EOF
}

add_log() {
  local msg="$1"
  local ts
  ts="$(date +"%H:%M:%S")"
  LOG_LINES+=("[$ts] $msg")
  if ((${#LOG_LINES[@]} > LOG_MAX)); then
    LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
  fi
}

render() {
  clear
  banner
  echo
  local shown_count="${#LOG_LINES[@]}"
  local height=$shown_count
  ((height < LOG_MIN)) && height=$LOG_MIN
  ((height > LOG_MAX)) && height=$LOG_MAX

  echo "┌───────────────────────────── ACTION LOG ─────────────────────────────┐"
  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    printf "│ %-68s │\n" "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-68s │\n" ""
  done

  echo "└──────────────────────────────────────────────────────────────────────┘"
  echo
}

pause_enter() {
  echo
  read -r -p "Press ENTER to return to menu..." _
}

die_soft() {
  add_log "ERROR: $1"
  render
  pause_enter
}
ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_octet() {
  local o="$1"
  [[ "$o" =~ ^[0-9]+$ ]] && ((o>=0 && o<=255))
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  valid_octet "$a" && valid_octet "$b" && valid_octet "$c" && valid_octet "$d"
}

valid_port() {
  local p="$1"
  is_int "$p" || return 1
  ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ \.0$ ]] || return 1
  return 0
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}
ask_until_valid() {
  local prompt="$1" validator="$2" __var="$3"
  local ans=""
  while true; do
    render
    read -r -e -p "$prompt " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "Empty input. Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: $prompt $ans"
      return 0
    else
      add_log "Invalid: $prompt $ans"
      add_log "Please enter a valid value."
    fi
  done
}

ask_ports() {
  local prompt="ForWard PORT (80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    read -r -e -p "$prompt " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Please try again."
      continue
    fi

    local -a ports=()
    local ok=1

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      valid_port "$raw" && ports+=("$raw") || ok=0

    elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
      local s="${raw%-*}"
      local e="${raw#*-}"
      if valid_port "$s" && valid_port "$e" && ((s<=e)); then
        local p
        for ((p=s; p<=e; p++)); do ports+=("$p"); done
      else
        ok=0
      fi

    elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
      IFS=',' read -r -a parts <<<"$raw"
      local part
      for part in "${parts[@]}"; do
        valid_port "$part" && ports+=("$part") || { ok=0; break; }
      done
    else
      ok=0
    fi

    if ((ok==0)); then
      add_log "Invalid ports: $raw"
      add_log "Examples: 80 | 80,2053 | 2050-2060"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports accepted: ${PORT_LIST[*]}"
    return 0
  done
}
ensure_iproute_only() {
  add_log "Checking required package: iproute2"
  render

  if command -v ip >/dev/null 2>&1; then
    add_log "iproute2 is already installed."
    return 0
  fi

  add_log "Installing missing package: iproute2"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y iproute2 >/dev/null 2>&1 && add_log "iproute2 installed successfully." || return 1
  return 0
}

ensure_packages() {
  add_log "Checking required packages: iproute2, socat"
  render
  local missing=()
  command -v ip >/dev/null 2>&1 || missing+=("iproute2")
  command -v socat >/dev/null 2>&1 || missing+=("socat")

  if ((${#missing[@]}==0)); then
    add_log "All required packages are installed."
    return 0
  fi

  add_log "Installing missing packages: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

install_haproxy() {
  if command -v haproxy >/dev/null 2>&1; then
    add_log "HAProxy is already installed."
    render
    pause_enter
    return 0
  fi
  add_log "Installing HAProxy..."
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y haproxy >/dev/null 2>&1 && add_log "HAProxy installed successfully." || add_log "HAProxy installation failed."
  render
  pause_enter
}

uninstall_haproxy() {
  if ! command -v haproxy >/dev/null 2>&1; then
    add_log "HAProxy is not installed."
    render
    pause_enter
    return 0
  fi
  add_log "Uninstalling HAProxy..."
  render
  apt-get purge -y haproxy >/dev/null 2>&1 && add_log "HAProxy uninstalled successfully." || add_log "HAProxy uninstallation failed."
  apt-get autoremove -y >/dev/null 2>&1
  render
  pause_enter
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }

unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }

enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }

show_unit_status_brief() {
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,12p'
}
make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Service already exists: $unit"
    return 2
  fi

  add_log "Creating: $path"
  render

  cat >"$path" <<EOF
[Unit]
Description=GRE Tunnel to (${remote_ip})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre${id} mode gre local ${local_ip} remote ${remote_ip} ttl 255 key ${key}
ExecStart=/sbin/ip addr add ${local_gre_ip}/30 dev gre${id}
ExecStart=/sbin/ip link set gre${id} up
ExecStop=/sbin/ip link set gre${id} down
ExecStop=/sbin/ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "GRE service created: $unit" || return 1
  return 0
}

make_fw_service() {
  local id="$1" port="$2" target_ip="$3"
  local unit="fw-gre${id}-${port}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Forwarder exists, skip: $unit"
    return 0
  fi

  add_log "Creating forwarder: fw-gre${id}-${port}"
  render

  cat >"$path" <<EOF
[Unit]
Description=forward gre${id} ${port}
After=network-online.target gre${id}.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${port},reuseaddr,fork TCP:${target_ip}:${port}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "Forwarder created: fw-gre${id}-${port}" || add_log "Failed writing forwarder: $unit"
}

update_haproxy_config() {
  local cfg_dir="/etc/haproxy/gre-forwards"
  local main_cfg="/etc/haproxy/haproxy-gre.cfg"
  local tmp_cfg="${main_cfg}.tmp.$$"
  mkdir -p "$cfg_dir"

  add_log "Regenerating HAProxy config..."

  cat >"$tmp_cfg" <<EOF
global
    maxconn 10000

defaults
    mode tcp
    timeout connect 5s
    timeout client 50s
    timeout server 50s
EOF

  local f
  for f in "$cfg_dir"/*.cfg; do
    [[ -e "$f" ]] && cat "$f" >> "$tmp_cfg"
  done

  if command -v haproxy >/dev/null 2>&1; then
    if ! haproxy -c -q -f "$tmp_cfg" >/dev/null 2>&1; then
      add_log "HAProxy config validation failed. Keeping old config."
      rm -f "$tmp_cfg"
      return 1
    fi
  else
    add_log "HAProxy binary not found. Config written but service not applied."
  fi

  if ! mv "$tmp_cfg" "$main_cfg"; then
    add_log "Failed writing HAProxy config: $main_cfg"
    rm -f "$tmp_cfg"
    return 1
  fi

  if ! unit_exists "haproxy-gre.service"; then
    cat >"/etc/systemd/system/haproxy-gre.service" <<EOF
[Unit]
Description=HAProxy Shared Forwarder for GRE
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/haproxy -f ${main_cfg}
ExecReload=/usr/sbin/haproxy -f ${main_cfg} -c -q
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemd_reload
    enable_now "haproxy-gre.service" && add_log "HAProxy service enabled and started." || { add_log "Failed to enable/start haproxy-gre.service"; return 1; }
  else
    systemctl restart "haproxy-gre.service" >/dev/null 2>&1 && add_log "HAProxy service restarted." || { add_log "Failed to restart haproxy-gre.service"; return 1; }
  fi

  return 0
}

make_haproxy_fw_service() {
  local id="$1" port="$2" target_ip="$3"
  local cfg_dir="/etc/haproxy/gre-forwards"
  local snippet_path="${cfg_dir}/fw-ha-gre${id}-${port}.cfg"

  if ! mkdir -p "$cfg_dir"; then
    add_log "Failed creating HAProxy snippet directory: $cfg_dir"
    return 1
  fi

  if [[ -f "$snippet_path" ]]; then
    add_log "HAProxy Forwarder already in config: GRE${id}:${port}"
    return 0
  fi

  add_log "Adding HAProxy snippet: GRE${id}:${port}"
  cat >"$snippet_path" <<EOF

frontend ft_gre${id}_${port}
    bind *:${port}
    default_backend bk_gre${id}_${port}

backend bk_gre${id}_${port}
    server srv1 ${target_ip}:${port} maxconn 10000
EOF

  [[ $? -eq 0 ]] && add_log "HAProxy snippet created: GRE${id}:${port}" || { add_log "Failed writing HAProxy snippet: GRE${id}:${port}"; return 1; }
}

iran_setup() {
  local ID IRANIP KHAREJIP GREBASE METHOD
  local -a PORT_LIST=()

  ask_until_valid "GRE Number :" is_int ID
  ask_until_valid "IRAN IP :" valid_ipv4 IRANIP
  ask_until_valid "KHAREJ IP :" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP RANG (Example : 10.80.70.0):" valid_gre_base GREBASE
  ask_ports

  while true; do
    render
    echo "Forwarding Method:"
    echo "1) Socat (Standard)"
    echo "2) HAProxy (High Performance)"
    echo
    read -r -e -p "Select method [1-2]: " METHOD
    METHOD="$(trim "$METHOD")"
    if [[ "$METHOD" == "2" ]]; then
       if ! command -v haproxy >/dev/null 2>&1; then
         add_log "HAProxy is not installed! Please install it from the main menu first."
         continue
       fi
    fi
    [[ "$METHOD" == "1" || "$METHOD" == "2" ]] && break
    add_log "Invalid selection: $METHOD"
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  add_log "KEY=${key} | IRAN=${local_gre_ip} | KHAREJ=${peer_gre_ip}"

  if [[ "$METHOD" == "1" ]]; then
    ensure_packages || { die_soft "Package installation failed."; return 0; }
  else
    ensure_iproute_only || { die_soft "Package installation failed (iproute2)."; return 0; }
  fi

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Creating forwarders..."
  local failed=0
  local p
  for p in "${PORT_LIST[@]}"; do
    if [[ "$METHOD" == "1" ]]; then
      make_fw_service "$ID" "$p" "$peer_gre_ip"
    else
      make_haproxy_fw_service "$ID" "$p" "$peer_gre_ip" || failed=1
    fi
  done

  if ((failed)); then
    die_soft "Failed creating one or more HAProxy forwarders."
    return 0
  fi

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID} + forwarders..."
  enable_now "gre${ID}.service"
  for p in "${PORT_LIST[@]}"; do
    if [[ "$METHOD" == "1" ]]; then
      enable_now "fw-gre${ID}-${p}.service"
    fi
  done

  if [[ "$METHOD" == "2" ]]; then
     update_haproxy_config || { die_soft "Failed applying HAProxy configuration."; return 0; }
  fi

  render
  echo "GRE IPs:"
  echo "  IRAN  : ${local_gre_ip}"
  echo "  KHAREJ: ${peer_gre_ip}"
  echo
  echo "Status:"
  show_unit_status_brief "gre${ID}.service"
  for p in "${PORT_LIST[@]}"; do
    echo
    if [[ "$METHOD" == "1" ]]; then
      show_unit_status_brief "fw-gre${ID}-${p}.service"
    else
      echo "Forwarder GRE${ID}:${p} (HAProxy) is active in haproxy-gre.service"
    fi
  done
  pause_enter
}

kharej_setup() {
  local ID KHAREJIP IRANIP GREBASE

  ask_until_valid "GRE Number(Like IRAN PLEASE) :" is_int ID
  ask_until_valid "KHAREJ IP :" valid_ipv4 KHAREJIP
  ask_until_valid "IRAN IP :" valid_ipv4 IRANIP
  ask_until_valid "GRE IP RANG (Example : 10.80.70.0) Like IRAN PLEASE:" valid_gre_base GREBASE

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  add_log "KEY=${key} | KHAREJ=${local_gre_ip} | IRAN=${peer_gre_ip}"

  ensure_iproute_only || { die_soft "Package installation failed (iproute2)."; return 0; }

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"

  render
  echo "GRE IPs:"
  echo "  KHAREJ: ${local_gre_ip}"
  echo "  IRAN  : ${peer_gre_ip}"
  echo
  show_unit_status_brief "gre${ID}.service"
  pause_enter
}

get_gre_ip_from_unit() {
  local id="$1"
  local path="/etc/systemd/system/gre${id}.service"
  if [[ -f "$path" ]]; then
     grep "ip addr add" "$path" | sed -E 's/.*ip addr add ([0-9.]+).*/\1/'
  fi
}

get_gre_ids() {
  local ids=()

  while IFS= read -r u; do
    [[ "$u" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^gre[0-9]+\.service$' || true)

  while IFS= read -r f; do
    f="$(basename "$f")"
    [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null || true)

  printf "%s\n" "${ids[@]}" | awk 'NF{a[$0]=1} END{for(k in a) print k}' | sort -n
}

MENU_SELECTED=-1

menu_select_index() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")
  local choice=""

  while true; do
    render
    echo "$title"
    echo

    if ((${#items[@]} == 0)); then
      echo "No service found."
      echo
      read -r -p "Press ENTER to go back..." _
      MENU_SELECTED=-1
      return 1
    fi

    local i
    for ((i=0; i<${#items[@]}; i++)); do
      printf "%d) %s\n" $((i+1)) "${items[$i]}"
    done
    echo "0) Back"
    echo

    read -r -e -p "$prompt " choice
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      MENU_SELECTED=-1
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#items[@]})); then
      MENU_SELECTED=$((choice-1))
      return 0
    fi

    add_log "Invalid selection: $choice"
  done
}

add_port_forward_menu() {
  local method="$1" # "socat" or "haproxy"
  if [[ "$method" == "haproxy" ]] && ! command -v haproxy >/dev/null 2>&1; then
    add_log "HAProxy is not installed."
    render
    pause_enter
    return 0
  fi

  mapfile -t GRE_IDS < <(get_gre_ids)
  if ((${#GRE_IDS[@]} == 0)); then
    add_log "No GRE tunnels found."
    render
    pause_enter
    return 0
  fi

  local -a GRE_LABELS=()
  local id ip
  for id in "${GRE_IDS[@]}"; do
    ip="$(get_gre_ip_from_unit "$id")"
    if [[ -n "$ip" ]]; then
      GRE_LABELS+=("GRE${id} [${ip%.*}.0/24]")
    else
      GRE_LABELS+=("GRE${id} [IP Unknown]")
    fi
  done

  if ! menu_select_index "Add Port Forward to GRE (${method^^})" "Select GRE Tunnel:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  local id="${GRE_IDS[$idx]}"
  local local_ip="$(get_gre_ip_from_unit "$id")"
  local peer_ip=""

  if [[ -z "$local_ip" ]]; then
    add_log "Error: Could not find GRE IP in gre${id}.service"
    render
    pause_enter
    return 0
  fi

  if [[ "$local_ip" =~ \.1$ ]]; then
    peer_ip="${local_ip%.*}.2"
  elif [[ "$local_ip" =~ \.2$ ]]; then
    peer_ip="${local_ip%.*}.1"
  else
    add_log "Could not determine peer IP for GRE${id} ($local_ip)"
    render
    pause_enter
    return 0
  fi

  add_log "Using Peer IP: $peer_ip"
  ask_ports # Sets PORT_LIST

  add_log "Creating ${method^^} forwarders for ports: ${PORT_LIST[*]}"
  local failed=0
  local p
  for p in "${PORT_LIST[@]}"; do
    if [[ "$method" == "socat" ]]; then
      make_fw_service "$id" "$p" "$peer_ip"
    else
      make_haproxy_fw_service "$id" "$p" "$peer_ip" || failed=1
    fi
  done

  if ((failed)); then
    die_soft "Failed creating one or more HAProxy forwarders."
    return 0
  fi

  if [[ "$method" == "socat" ]]; then
    add_log "Reloading systemd and starting Socat services..."
    systemd_reload
    for p in "${PORT_LIST[@]}"; do
      enable_now "fw-gre${id}-${p}.service"
    done
  else
    add_log "Regenerating HAProxy configuration and restarting..."
    update_haproxy_config || { die_soft "Failed applying HAProxy configuration."; return 0; }
  fi

  add_log "Process completed for GRE${id}"
  pause_enter
}

service_action_menu() {
  local unit="$1"
  local action=""

  while true; do
    render
    echo "Selected: $unit"
    echo
    echo "1) Enable & Start"
    echo "2) Restart"
    echo "3) Stop & Disable"
    echo "4) Status"
    echo "5) Remove (Permanently)"
    echo "0) Back"
    echo

    read -r -e -p "Select action: " action
    action="$(trim "$action")"

    case "$action" in
      1)
        add_log "Enable & Start: $unit"
        systemctl enable "$unit" >/dev/null 2>&1 && add_log "Enabled: $unit" || add_log "Enable failed: $unit"
        systemctl start "$unit"  >/dev/null 2>&1 && add_log "Started: $unit" || add_log "Start failed: $unit"
        ;;
      2)
        add_log "Restart: $unit"
        systemctl restart "$unit" >/dev/null 2>&1 && add_log "Restarted: $unit" || add_log "Restart failed: $unit"
        ;;
      3)
        add_log "Stop & Disable: $unit"
        systemctl stop "$unit"    >/dev/null 2>&1 && add_log "Stopped: $unit" || add_log "Stop failed: $unit"
        systemctl disable "$unit" >/dev/null 2>&1 && add_log "Disabled: $unit" || add_log "Disable failed: $unit"
        ;;
      4)
        render
        echo "---- STATUS ($unit) ----"
        systemctl --no-pager --full status "$unit" 2>&1 | sed -n '1,16p'
        echo "------------------------"
        pause_enter
        ;;
      5)
        render
        echo "Remove service: $unit"
        echo
        if [[ "$unit" =~ ^gre([0-9]+)\.service$ ]]; then
          echo "WARNING: This is a GRE tunnel. Removing it will also remove all associated forwarders."
        fi
        echo "Type YES to confirm deletion:"
        local confirm=""
        read -r -e -p "Confirm: " confirm
        confirm="$(trim "$confirm")"
        if [[ "$confirm" == "YES" ]]; then
           add_log "Removing $unit"
           
           if [[ "$unit" =~ ^gre([0-9]+)\.service$ ]]; then
             local id="${BASH_REMATCH[1]}"
             systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
             systemctl disable "gre${id}.service" >/dev/null 2>&1 || true
             rm -f "/etc/systemd/system/gre${id}.service"

             # Remove all socat forwarders for this GRE
             local -a fwd_units
             mapfile -t fwd_units < <(find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${id}-*.service" 2>/dev/null | awk -F/ '{print $NF}')
             for f in "${fwd_units[@]}"; do
                add_log "Removing Socat forwarder: $f"
                systemctl stop "$f" >/dev/null 2>&1 || true
                systemctl disable "$f" >/dev/null 2>&1 || true
                rm -f "/etc/systemd/system/$f"
             done

             # Remove all haproxy forwarders for this GRE
             local -a fwd_configs
             mapfile -t fwd_configs < <(find /etc/haproxy/gre-forwards -maxdepth 1 -type f -name "fw-ha-gre${id}-*.cfg" 2>/dev/null)
             if ((${#fwd_configs[@]} > 0)); then
               for f in "${fwd_configs[@]}"; do
                 add_log "Removing HAProxy snippet: $(basename "$f")"
                 rm -f "$f"
               done
               update_haproxy_config
             fi

           elif [[ "$unit" =~ ^fw-gre([0-9]+)-([0-9]+)\.service$ ]]; then
             systemctl stop "$unit" >/dev/null 2>&1 || true
             systemctl disable "$unit" >/dev/null 2>&1 || true
             rm -f "/etc/systemd/system/$unit"

           elif [[ "$unit" =~ ^fw-ha-gre([0-9]+)-([0-9]+)\.cfg$ ]]; then
             add_log "Removing HAProxy snippet: $unit"
             rm -f "/etc/haproxy/gre-forwards/$unit"
             update_haproxy_config
           fi

           systemctl daemon-reload >/dev/null 2>&1
           systemctl reset-failed >/dev/null 2>&1
           add_log "Successfully removed: $unit"
           pause_enter
           return 0
        else
           add_log "Removal cancelled."
        fi
        ;;
      0) return 0 ;;
      *) add_log "Invalid action: $action" ;;
    esac
  done
}

haproxy_management() {
  if ! command -v haproxy >/dev/null 2>&1; then
    add_log "HAProxy is not installed."
    render
    pause_enter
    return 0
  fi

  local sel=""
  while true; do
    render
    echo "HAProxy ManageMent"
    echo
    echo "1) Add Port Forward(s)"
    echo "2) HAProxy Service Control (haproxy-gre.service)"
    echo "3) View Full Config (/etc/haproxy/haproxy-gre.cfg)"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1) add_port_forward_menu "haproxy" ;;
      2) service_action_menu "haproxy-gre.service" ;;
      3)
        render
        echo "---- HAProxy GRE Config ----"
        if [[ -f /etc/haproxy/haproxy-gre.cfg ]]; then
          cat /etc/haproxy/haproxy-gre.cfg
        else
          echo "Config file not found."
        fi
        echo "----------------------------"
        pause_enter
        ;;
      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

socat_management() {
  local sel=""
  while true; do
    render
    echo "Socat ManageMent"
    echo
    echo "1) Add Port Forward(s)"
    echo "2) Manage Existing Forwards"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1) add_port_forward_menu "socat" ;;
      2)
        local -a SOCAT_UNITS
        mapfile -t SOCAT_UNITS < <(find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre*-*.service" 2>/dev/null | awk -F/ '{print $NF}' | sort -V)
        local -a FW_LABELS=()
        local u gid port

        for u in "${SOCAT_UNITS[@]}"; do
          if [[ "$u" =~ ^fw-gre([0-9]+)-([0-9]+)\.service$ ]]; then
            gid="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            FW_LABELS+=("GRE${gid}:${port}")
          else
            FW_LABELS+=("${u%.service}")
          fi
        done

        if menu_select_index "Socat Forwarders" "Select Socat Forwarder:" "${FW_LABELS[@]}"; then
          local fidx="$MENU_SELECTED"
          u="${SOCAT_UNITS[$fidx]}"
          add_log "Socat Forwarder selected: ${FW_LABELS[$fidx]}"
          service_action_menu "$u"
        fi
        ;;
      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

gre_management() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id ip
  for id in "${GRE_IDS[@]}"; do
    ip="$(get_gre_ip_from_unit "$id")"
    if [[ -n "$ip" ]]; then
      GRE_LABELS+=("GRE${id} [${ip%.*}.0/24]")
    else
      GRE_LABELS+=("GRE${id}")
    fi
  done

  if menu_select_index "GRE Services" "Select GRE Tunnel to manage:" "${GRE_LABELS[@]}"; then
    local idx="$MENU_SELECTED"
    id="${GRE_IDS[$idx]}"
    add_log "GRE selected: GRE${id}"
    service_action_menu "gre${id}.service"
  fi
}

uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Uninstall & Clean" "Select GRE to uninstall:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  while true; do
    render
    echo "Uninstall & Clean"
    echo
    echo "Target: GRE${id}"
    echo "This will remove:"
    echo "  - gre${id}.service"
    echo "  - All associated Socat & HAProxy forwarders"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Uninstall cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  add_log "Stopping gre${id}.service"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  # Socat
  local -a socat_fw
  mapfile -t socat_fw < <(find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${id}-*.service" 2>/dev/null | awk -F/ '{print $NF}')
  for u in "${socat_fw[@]}"; do
    add_log "Stopping $u"
    systemctl stop "$u" >/dev/null 2>&1 || true
    systemctl disable "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
  done

  # HAProxy
  local -a ha_fw
  mapfile -t ha_fw < <(find /etc/haproxy/gre-forwards -maxdepth 1 -type f -name "fw-ha-gre${id}-*.cfg" 2>/dev/null)
  if ((${#ha_fw[@]} > 0)); then
    for f in "${ha_fw[@]}"; do
      add_log "Removing HAProxy snippet: $(basename "$f")"
      rm -f "$f"
    done
    update_haproxy_config
  fi

  add_log "Removing GRE unit file..."
  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  
  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  add_log "Uninstall completed for GRE${id}"
  render
  pause_enter
}

main_menu() {
  local choice=""
  while true; do
    render
    echo "1 > IRAN SETUP"
    echo "2 > KHAREJ SETUP"
    echo "3 > GRE Tunnels ManageMent"
    echo "4 > Socat ManageMent"
    echo "5 > HAProxy ManageMent"
    echo "6 > Unistall & Clean"
    echo "7 > Install HAProxy"
    echo "8 > Uninstall HAProxy"
    echo "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Selected: IRAN SETUP"; iran_setup ;;
      2) add_log "Selected: KHAREJ SETUP"; kharej_setup ;;
      3) add_log "Selected: GRE ManageMent"; gre_management ;;
      4) add_log "Selected: Socat ManageMent"; socat_management ;;
      5) add_log "Selected: HAProxy ManageMent"; haproxy_management ;;
      6) add_log "Selected: Unistall & Clean"; uninstall_clean ;;
      7) add_log "Selected: Install HAProxy"; install_haproxy ;;
      8) add_log "Selected: Uninstall HAProxy"; uninstall_haproxy ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

ensure_root "$@"
add_log "SEPEHR GRE+FORWARDER installer."
main_menu
