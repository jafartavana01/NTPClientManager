#!/usr/bin/env bash
# NTP Client Manager - offline/on-premises systemd-timesyncd administration TUI
# Branding is UI-only and is never written into exports/configuration.

set -o pipefail
umask 027

APP_NAME="NTP Client Manager"
APP_VERSION="1.0.0"
BRAND="@JAFAR TAVANA"
APP_ETC="/etc/ntp-manager"
APP_CONF="$APP_ETC/ntp-manager.conf"
APP_LOG_DIR="/var/log/ntp-manager"
APP_BACKUP_DIR="/var/backups/ntp-manager"
APP_STATE_DIR="/var/lib/ntp-manager"
TIMESYNCD_CONF="/etc/systemd/timesyncd.conf"
TIMESYNCD_DROPIN_DIR="/etc/systemd/timesyncd.conf.d"
MANAGED_DROPIN="$TIMESYNCD_DROPIN_DIR/90-ntp-manager.conf"
TMP_ROOT="${TMPDIR:-/tmp}"

MONITOR_INTERVAL=2
LOG_RETENTION_DAYS=30
BACKUP_RETENTION_DAYS=90
DIAG_LOG_PERIOD="1 hour ago"
NTP_TEST_TIMEOUT=3
TUI="bash"

C_OK="✓ OK"
C_ERR="✗ ERROR"
C_WARN="! WARNING"
C_UNKNOWN="- UNKNOWN"

# ---------- generic helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
now_human() { date '+%Y-%m-%d %H:%M:%S'; }
log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
trim() { awk '{$1=$1;print}' <<<"$*"; }
join_by() { local IFS="$1"; shift; echo "$*"; }

safe_mkdir() {
  local d="$1" mode="${2:-0750}"
  if is_root; then
    mkdir -p "$d" && chmod "$mode" "$d"
  fi
}

log_action() {
  local level="$1"; shift
  local msg="$*"
  if is_root; then
    safe_mkdir "$APP_LOG_DIR" 0750
    printf '%s %s %s\n' "$(log_ts)" "$level" "$msg" >> "$APP_LOG_DIR/ntp-manager.log" 2>/dev/null || true
  fi
}

log_server_test() {
  local msg="$*"
  if is_root; then
    safe_mkdir "$APP_LOG_DIR" 0750
    printf '%s %s\n' "$(log_ts)" "$msg" >> "$APP_LOG_DIR/server-tests.log" 2>/dev/null || true
  fi
}

log_failure() {
  local msg="$*"
  if is_root; then
    safe_mkdir "$APP_LOG_DIR" 0750
    printf '%s %s\n' "$(log_ts)" "$msg" >> "$APP_LOG_DIR/failures.log" 2>/dev/null || true
  fi
}

load_settings() {
  [[ -r "$APP_CONF" ]] || return 0
  local key val
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      MONITOR_INTERVAL) [[ "$val" =~ ^[1-9][0-9]*$ ]] && MONITOR_INTERVAL="$val" ;;
      LOG_RETENTION_DAYS) [[ "$val" =~ ^[1-9][0-9]*$ ]] && LOG_RETENTION_DAYS="$val" ;;
      BACKUP_RETENTION_DAYS) [[ "$val" =~ ^[1-9][0-9]*$ ]] && BACKUP_RETENTION_DAYS="$val" ;;
      DIAG_LOG_PERIOD) [[ -n "$val" ]] && DIAG_LOG_PERIOD="$val" ;;
      NTP_TEST_TIMEOUT) [[ "$val" =~ ^[1-9][0-9]*$ ]] && NTP_TEST_TIMEOUT="$val" ;;
    esac
  done < "$APP_CONF"
}

save_settings() {
  require_root "Save application settings" || return 1
  safe_mkdir "$APP_ETC" 0750 || return 1
  local tmp
  tmp=$(mktemp "$TMP_ROOT/ntp-manager-settings.XXXXXX") || return 1
  cat > "$tmp" <<EOF2
MONITOR_INTERVAL=$MONITOR_INTERVAL
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS
BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
DIAG_LOG_PERIOD=$DIAG_LOG_PERIOD
NTP_TEST_TIMEOUT=$NTP_TEST_TIMEOUT
EOF2
  install -m 0640 "$tmp" "$APP_CONF"
  rm -f "$tmp"
  log_action INFO "Application settings updated"
}

init_owned_dirs() {
  is_root || return 0
  safe_mkdir "$APP_ETC" 0750
  safe_mkdir "$APP_LOG_DIR" 0750
  safe_mkdir "$APP_BACKUP_DIR" 0700
  safe_mkdir "$APP_STATE_DIR" 0750
  touch "$APP_LOG_DIR/ntp-manager.log" "$APP_LOG_DIR/sync-history.log" "$APP_LOG_DIR/server-tests.log" "$APP_LOG_DIR/failures.log" 2>/dev/null || true
  chmod 0640 "$APP_LOG_DIR"/*.log 2>/dev/null || true
}

cleanup_retention() {
  is_root || return 0
  find "$APP_LOG_DIR" -type f -name '*.log.*' -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  find "$APP_BACKUP_DIR" -type f -mtime "+$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ---------- UI ----------
detect_tui() {
  if have whiptail; then TUI="whiptail"
  elif have dialog; then TUI="dialog"
  else TUI="bash"
  fi
}

maybe_offer_cached_whiptail() {
  [[ "$TUI" == "bash" ]] || return 0
  have apt-get || return 0
  is_root || return 0
  # Offline-safe attempt: --no-download permits installation only when required .debs are already cached.
  if apt-cache show whiptail >/dev/null 2>&1; then
    if ui_yesno "Optional TUI" "whiptail/dialog is not installed. A pure-Bash fallback is available.\n\nTry installing whiptail using ONLY packages already present in the local APT cache (no downloads)?"; then
      if DEBIAN_FRONTEND=noninteractive apt-get --no-download -y install whiptail >/dev/null 2>&1; then
        detect_tui
        log_action INFO "Installed whiptail from local APT cache"
      else
        ui_msg "Offline TUI" "whiptail was not installable from the local APT cache. Continuing with the functional pure-Bash fallback."
      fi
    fi
  fi
}

brand_title() { printf '%s | %s' "$APP_NAME" "$BRAND"; }

ui_msg() {
  local title="$1" text="$2"
  case "$TUI" in
    whiptail) whiptail --title "$title" --msgbox "$text\n\n$BRAND" 22 78 ;;
    dialog) dialog --title "$title" --msgbox "$text\n\n$BRAND" 22 78 ;;
    *) printf '\n=== %s ===\n%s\n\n%70s\n' "$title" "$text" "$BRAND"; read -r -p "Press Enter to continue..." _ ;;
  esac
}

ui_yesno() {
  local title="$1" text="$2"
  case "$TUI" in
    whiptail) whiptail --title "$title" --yesno "$text\n\n$BRAND" 18 78 ;;
    dialog) dialog --title "$title" --yesno "$text\n\n$BRAND" 18 78 ;;
    *) local a; read -r -p "$title: $text [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] ;;
  esac
}

ui_input() {
  local title="$1" prompt="$2" default="${3:-}" out rc
  case "$TUI" in
    whiptail)
      out=$(whiptail --title "$title" --inputbox "$prompt\n\n$BRAND" 18 78 "$default" 3>&1 1>&2 2>&3); rc=$? ;;
    dialog)
      out=$(dialog --stdout --title "$title" --inputbox "$prompt\n\n$BRAND" 18 78 "$default"); rc=$? ;;
    *)
      read -r -p "$prompt${default:+ [$default]}: " out; rc=0; [[ -z "$out" ]] && out="$default" ;;
  esac
  [[ $rc -eq 0 ]] || return 1
  printf '%s' "$out"
}

ui_password() {
  local title="$1" prompt="$2" out rc
  case "$TUI" in
    whiptail) out=$(whiptail --title "$title" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3); rc=$? ;;
    dialog) out=$(dialog --stdout --title "$title" --passwordbox "$prompt" 12 70); rc=$? ;;
    *) read -r -s -p "$prompt: " out; echo; rc=0 ;;
  esac
  [[ $rc -eq 0 ]] || return 1
  printf '%s' "$out"
}

ui_menu() {
  local title="$1" prompt="$2"; shift 2
  local out rc
  case "$TUI" in
    whiptail) out=$(whiptail --title "$title" --menu "$prompt\n\n$BRAND" 24 86 15 "$@" 3>&1 1>&2 2>&3); rc=$? ;;
    dialog) out=$(dialog --stdout --title "$title" --menu "$prompt\n\n$BRAND" 24 86 15 "$@"); rc=$? ;;
    *)
      local -a args=("$@"); local i=0 n=1 choice
      echo; echo "=== $title ==="; echo "$prompt"
      while (( i < ${#args[@]} )); do printf ' %2d) %-22s %s\n' "$n" "${args[$i]}" "${args[$((i+1))]}"; i=$((i+2)); n=$((n+1)); done
      printf '%70s\n' "$BRAND"
      read -r -p "Select (blank=Back): " choice
      [[ -n "$choice" && "$choice" =~ ^[0-9]+$ ]] || return 1
      i=$(( (choice-1)*2 )); (( i >= 0 && i < ${#args[@]} )) || return 1
      out="${args[$i]}"; rc=0 ;;
  esac
  [[ $rc -eq 0 ]] || return 1
  printf '%s' "$out"
}

ui_textbox_file() {
  local title="$1" file="$2"
  case "$TUI" in
    whiptail) whiptail --title "$title" --scrolltext --textbox "$file" 25 100 ;;
    dialog) dialog --title "$title" --textbox "$file" 25 100 ;;
    *) less -R "$file" 2>/dev/null || cat "$file" ;;
  esac
}

ui_tailbox_file() {
  local title="$1" file="$2"
  case "$TUI" in
    dialog) dialog --title "$title" --tailbox "$file" 25 100 ;;
    whiptail) ui_textbox_file "$title" "$file" ;;
    *) tail -f "$file" ;;
  esac
}

show_text() {
  local title="$1" text="$2" tmp
  tmp=$(mktemp "$TMP_ROOT/ntp-manager-view.XXXXXX") || return 1
  printf '%s\n\n%90s\n' "$text" "$BRAND" > "$tmp"
  ui_textbox_file "$title" "$tmp"
  rm -f "$tmp"
}

require_root() {
  local op="${1:-This operation}"
  if is_root; then return 0; fi
  if have sudo && ui_yesno "Administrative privileges" "$op requires root privileges.\n\nRe-run this application with sudo now?"; then
    exec sudo -- "$0"
  fi
  ui_msg "Permission required" "$op was not performed because root privileges are required."
  return 1
}

# ---------- system detection/status ----------
os_pretty() { . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Unknown}"; }
os_release() { . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-Unknown}"; }
systemd_version() { systemctl --version 2>/dev/null | head -1 | awk '{print $2}'; }
current_timezone() { timedatectl show -p Timezone --value 2>/dev/null || timedatectl 2>/dev/null | awk -F': ' '/Time zone:/ {print $2}' | awk '{print $1}'; }
ntp_enabled_state() { timedatectl show -p NTP --value 2>/dev/null || echo "N/A"; }
clock_sync_state() { timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "N/A"; }
service_active() { systemctl is-active systemd-timesyncd 2>/dev/null || echo "unknown"; }
service_enabled() { systemctl is-enabled systemd-timesyncd 2>/dev/null || echo "unknown"; }

show_system_detection() {
  local out
  out="Ubuntu       : $(os_pretty)
Release      : $(os_release)
Kernel       : $(uname -r)
Hostname     : $(hostname)
Architecture : $(uname -m)
Systemd      : $(systemd_version)

timesyncd    : $(systemctl status systemd-timesyncd >/dev/null 2>&1 && echo AVAILABLE || echo NOT/INACTIVE)
timedatectl  : $(have timedatectl && echo AVAILABLE || echo MISSING)
systemctl    : $(have systemctl && echo AVAILABLE || echo MISSING)
journalctl   : $(have journalctl && echo AVAILABLE || echo MISSING)
whiptail     : $(have whiptail && echo AVAILABLE || echo MISSING)
dialog       : $(have dialog && echo AVAILABLE || echo MISSING)
python3      : $(have python3 && echo AVAILABLE || echo MISSING)"
  show_text "System Detection" "$out"
}

# ---------- config parsing ----------
get_ini_values() {
  local key="$1" file
  local values=()
  for file in "$TIMESYNCD_CONF" "$TIMESYNCD_DROPIN_DIR"/*.conf; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line; do
      line="${line%%#*}"; line="${line%%;*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      if [[ "$line" =~ ^[[:space:]]*$key[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        values+=("${BASH_REMATCH[1]}")
      fi
    done < "$file"
  done
  if ((${#values[@]})); then printf '%s\n' "${values[-1]}"; fi
}

get_configured_servers() { get_ini_values "NTP" | xargs 2>/dev/null || true; }
get_fallback_servers() { get_ini_values "FallbackNTP" | xargs 2>/dev/null || true; }

current_ntp_server() {
  local s
  if timedatectl timesync-status >/dev/null 2>&1; then
    s=$(timedatectl timesync-status 2>/dev/null | awk -F': ' '/Server:/ {print $2; exit}')
    [[ -n "$s" ]] && { printf '%s' "$s"; return; }
  fi
  if timedatectl show-timesync >/dev/null 2>&1; then
    s=$(timedatectl show-timesync -p ServerName --value 2>/dev/null)
    [[ -z "$s" ]] && s=$(timedatectl show-timesync -p ServerAddress --value 2>/dev/null)
    [[ -n "$s" ]] && { printf '%s' "$s"; return; }
  fi
  printf 'N/A'
}

show_overview() {
  local rtc_tz rtc_line
  rtc_tz=$(timedatectl show -p LocalRTC --value 2>/dev/null || echo "N/A")
  [[ "$rtc_tz" == "yes" ]] && rtc_line="Local Time" || rtc_line="UTC"
  local out="Hostname          : $(hostname)
Current Time      : $(date '+%Y-%m-%d %H:%M:%S.%3N')
UTC Time          : $(date -u '+%Y-%m-%d %H:%M:%S.%3N')
Timezone          : $(current_timezone)
RTC               : $rtc_line

NTP Service       : $(service_active)
Service Enabled   : $(service_enabled)
NTP Enabled       : $(ntp_enabled_state)
Clock Synchronized: $(clock_sync_state)

Current NTP Server: $(current_ntp_server)
Configured Servers: $(get_configured_servers | sed 's/^$/N/A/')"
  show_text "NTP Overview" "$out"
}

show_current_time() {
  show_text "Current Time" "Local Time     : $(date '+%Y-%m-%d %H:%M:%S.%3N %Z')
UTC Time       : $(date -u '+%Y-%m-%d %H:%M:%S.%3N UTC')
Timezone       : $(current_timezone)
Unix Timestamp : $(date +%s)"
}

# ---------- time/RTC ----------
set_timezone() {
  have timedatectl || { ui_msg "Unavailable" "timedatectl is not available."; return; }
  local query tz current
  query=$(ui_input "Timezone Search" "Enter a search term (example: Tehran, Baku, Europe) or leave empty to view all:" "") || return
  local tmp; tmp=$(mktemp "$TMP_ROOT/tz.XXXXXX") || return
  timedatectl list-timezones 2>/dev/null | { if [[ -n "$query" ]]; then grep -i -- "$query" || true; else cat; fi; } > "$tmp"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; ui_msg "No matches" "No timezone matched '$query'."; return; }
  if [[ "$TUI" == "bash" ]]; then cat "$tmp"; fi
  tz=$(ui_input "Set Timezone" "Enter an exact timezone from timedatectl list-timezones:" "$(head -1 "$tmp")") || { rm -f "$tmp"; return; }
  rm -f "$tmp"
  timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz" || { ui_msg "Invalid timezone" "'$tz' is not a valid timezone on this server."; return; }
  current=$(current_timezone)
  ui_yesno "Review Timezone Change" "Current timezone : $current\nNew timezone     : $tz\n\nApply this change?" || return
  require_root "Change timezone" || return
  if timedatectl set-timezone "$tz"; then log_action INFO "Timezone changed $current -> $tz"; ui_msg "Timezone" "Timezone changed successfully to $tz."; else log_failure "Timezone change failed: $current -> $tz"; ui_msg "Error" "Failed to change timezone."; fi
}

rtc_management() {
  local choice localrtc newmode
  while true; do
    choice=$(ui_menu "RTC Management" "RTC configuration" \
      "VIEW" "View RTC/System time" \
      "UTC" "Set RTC to UTC (recommended)" \
      "LOCAL" "Set RTC to local time" \
      "BACK" "Back") || return
    case "$choice" in
      VIEW)
        show_text "RTC Status" "$(timedatectl status 2>/dev/null)" ;;
      UTC|LOCAL)
        require_root "Change RTC mode" || continue
        localrtc=$(timedatectl show -p LocalRTC --value 2>/dev/null || echo no)
        [[ "$choice" == "UTC" ]] && newmode=0 || newmode=1
        ui_yesno "RTC Warning" "Changing RTC mode can affect systems that dual-boot or expect a specific hardware-clock convention.\n\nCurrent LocalRTC=$localrtc\nSet LocalRTC=$newmode?" || continue
        if timedatectl set-local-rtc "$newmode" --adjust-system-clock; then log_action INFO "RTC mode changed LocalRTC=$newmode"; ui_msg "RTC" "RTC mode updated."; else ui_msg "Error" "Failed to change RTC mode."; fi ;;
      BACK) return ;;
    esac
  done
}

# ---------- NTP probe ----------
validate_address() {
  local a="$1"
  [[ -n "$a" && ${#a} -le 253 && "$a" =~ ^[A-Za-z0-9_.:%-]+$ ]] || return 1
  getent ahosts "$a" >/dev/null 2>&1 || getent hosts "$a" >/dev/null 2>&1 || [[ "$a" =~ : ]] || return 1
}

python_ntp_probe() {
  local host="$1" timeout="$2"
  python3 - "$host" "$timeout" <<'PY'
import socket, struct, sys, time, datetime, math
host=sys.argv[1]; timeout=float(sys.argv[2])
NTP_DELTA=2208988800

def ntp_to_unix(b):
    sec, frac = struct.unpack('!II', b)
    if sec == 0 and frac == 0: return 0.0
    return sec - NTP_DELTA + frac/2**32

def fmt(t):
    if not t: return 'N/A'
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).astimezone().isoformat(timespec='milliseconds')
try:
    infos=socket.getaddrinfo(host,123,0,socket.SOCK_DGRAM)
except Exception as e:
    print('RESULT=FAIL'); print('REASON=DNS/address resolution failed: '+str(e)); sys.exit(2)
last=None
for fam,stype,proto,canon,sa in infos:
    s=socket.socket(fam,socket.SOCK_DGRAM); s.settimeout(timeout)
    try:
        pkt=bytearray(48); pkt[0]=(0<<6)|(4<<3)|3
        t1=time.time(); ntp=t1+NTP_DELTA; sec=int(ntp); frac=int((ntp-sec)*2**32); struct.pack_into('!II',pkt,40,sec,frac)
        start=time.perf_counter(); s.sendto(pkt,sa); data,peer=s.recvfrom(512); end=time.perf_counter(); t4=time.time()
        if len(data)<48: raise ValueError('short NTP packet')
        li=(data[0]>>6)&3; vn=(data[0]>>3)&7; mode=data[0]&7; stratum=data[1]; poll=struct.unpack('!b',bytes([data[2]]))[0]; precision=struct.unpack('!b',bytes([data[3]]))[0]
        root_delay=struct.unpack('!i',data[4:8])[0]/65536.0
        root_disp=struct.unpack('!I',data[8:12])[0]/65536.0
        refid=data[12:16]
        try: refid_text=socket.inet_ntoa(refid) if stratum>1 else refid.decode('ascii','replace')
        except: refid_text=refid.hex()
        tref=ntp_to_unix(data[16:24]); torig=ntp_to_unix(data[24:32]); t2=ntp_to_unix(data[32:40]); t3=ntp_to_unix(data[40:48])
        valid=(mode in (4,5) and vn in (3,4) and t3>0 and stratum<=15 and li!=3)
        delay=(t4-t1)-(t3-t2) if (t2 and t3) else (end-start)
        offset=((t2-t1)+(t3-t4))/2 if (t2 and t3) else (t3-t4)
        print('RESULT='+('PASS' if valid else 'FAIL'))
        print('RESOLVED='+str(peer[0])); print('UDP123=PASS'); print('NTP_RESPONSE='+('PASS' if valid else 'FAIL'))
        print('LI='+str(li)); print('VERSION='+str(vn)); print('MODE='+str(mode)); print('STRATUM='+str(stratum)); print('POLL='+str(poll)); print('PRECISION='+str(precision))
        print('REFERENCE_ID='+refid_text); print('REFERENCE_TIME='+fmt(tref)); print('ORIGIN_TIME='+fmt(torig)); print('RECEIVE_TIME='+fmt(t2)); print('TRANSMIT_TIME='+fmt(t3))
        print('SERVER_TIME='+fmt(t3)); print('LOCAL_TIME='+fmt(t4)); print('OFFSET_SECONDS={:.9f}'.format(offset)); print('DELAY_SECONDS={:.9f}'.format(delay)); print('ROOT_DELAY_SECONDS={:.6f}'.format(root_delay)); print('ROOT_DISPERSION_SECONDS={:.6f}'.format(root_disp))
        if not valid: print('REASON=Received packet is not a valid usable server response')
        sys.exit(0 if valid else 3)
    except Exception as e:
        last=e
    finally:
        s.close()
print('RESULT=FAIL'); print('UDP123=FAIL'); print('NTP_RESPONSE=FAIL'); print('REASON=No valid NTP response received: '+str(last)); sys.exit(4)
PY
}

fallback_ntp_probe() {
  local host="$1" out="RESULT=FAIL\nREASON=No built-in NTP probe is available. Python 3 is not installed, and no supported NTP query utility was detected."
  if have ntpdate; then
    local r; r=$(ntpdate -q -t "$NTP_TEST_TIMEOUT" "$host" 2>&1); local rc=$?
    if [[ $rc -eq 0 ]]; then out="RESULT=PASS\nUDP123=PASS\nNTP_RESPONSE=PASS\nUTILITY=ntpdate\nRAW=$r"; fi
  elif have sntp; then
    local r; r=$(sntp -t "$NTP_TEST_TIMEOUT" "$host" 2>&1); local rc=$?
    if [[ $rc -eq 0 ]]; then out="RESULT=PASS\nUDP123=PASS\nNTP_RESPONSE=PASS\nUTILITY=sntp\nRAW=$r"; fi
  fi
  printf '%b\n' "$out"
}

probe_ntp_server_raw() {
  local server="$1"
  if have python3; then python_ntp_probe "$server" "$NTP_TEST_TIMEOUT"; else fallback_ntp_probe "$server"; fi
}

probe_value() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' <<<"$2"; }

format_probe_result() {
  local server="$1" raw="$2"
  local result resolved udp resp version stratum refid stime ltime offset delay reason rootd rootdisp
  result=$(probe_value RESULT "$raw"); resolved=$(probe_value RESOLVED "$raw"); udp=$(probe_value UDP123 "$raw"); resp=$(probe_value NTP_RESPONSE "$raw"); version=$(probe_value VERSION "$raw"); stratum=$(probe_value STRATUM "$raw"); refid=$(probe_value REFERENCE_ID "$raw"); stime=$(probe_value SERVER_TIME "$raw"); ltime=$(probe_value LOCAL_TIME "$raw"); offset=$(probe_value OFFSET_SECONDS "$raw"); delay=$(probe_value DELAY_SECONDS "$raw"); reason=$(probe_value REASON "$raw"); rootd=$(probe_value ROOT_DELAY_SECONDS "$raw"); rootdisp=$(probe_value ROOT_DISPERSION_SECONDS "$raw")
  [[ -z "$resolved" ]] && resolved="N/A"; [[ -z "$udp" ]] && udp="UNKNOWN"; [[ -z "$resp" ]] && resp="UNKNOWN"; [[ -z "$version" ]] && version="N/A"; [[ -z "$stratum" ]] && stratum="N/A"; [[ -z "$refid" ]] && refid="N/A"; [[ -z "$stime" ]] && stime="N/A"; [[ -z "$ltime" ]] && ltime="$(date '+%Y-%m-%dT%H:%M:%S.%3N%:z')"; [[ -z "$offset" ]] && offset="N/A"; [[ -z "$delay" ]] && delay="N/A"; [[ -z "$rootd" ]] && rootd="N/A"; [[ -z "$rootdisp" ]] && rootdisp="N/A"
  local offms="$offset" delayms="$delay"
  if [[ "$offset" =~ ^-?[0-9.]+$ ]]; then offms=$(awk -v x="$offset" 'BEGIN{printf "%+.3f ms",x*1000}'); fi
  if [[ "$delay" =~ ^-?[0-9.]+$ ]]; then delayms=$(awk -v x="$delay" 'BEGIN{printf "%.3f ms",x*1000}'); fi
  printf 'Server Address     : %s\nResolved Address   : %s\nUDP Port           : 123\n\nUDP/123            : %s\nNTP Response       : %s\nNTP Version        : %s\nStratum            : %s\nReference ID       : %s\nRoot Delay         : %s s\nRoot Dispersion    : %s s\n\nNTP Server Time    : %s\nLocal Time         : %s\nClock Offset       : %s\nResponse Time      : %s\n\nRESULT             : %s%s\n' "$server" "$resolved" "$udp" "$resp" "$version" "$stratum" "$refid" "$rootd" "$rootdisp" "$stime" "$ltime" "$offms" "$delayms" "$([[ "$result" == PASS ]] && echo '✓ VALID NTP SERVER' || echo '✗ NTP SERVER UNAVAILABLE')" "${reason:+\nReason             : $reason}"
}

test_ntp_server() {
  local server="$1" raw rc
  raw=$(probe_ntp_server_raw "$server"); rc=$?
  format_probe_result "$server" "$raw"
  log_server_test "server=$server result=$(probe_value RESULT "$raw") resolved=$(probe_value RESOLVED "$raw") offset=$(probe_value OFFSET_SECONDS "$raw") delay=$(probe_value DELAY_SECONDS "$raw")"
  return $rc
}

# ---------- backups/atomic config ----------
backup_config() {
  require_root "Create backup" || return 1
  safe_mkdir "$APP_BACKUP_DIR" 0700 || return 1
  local stamp dest
  stamp=$(date '+%Y%m%d-%H%M%S')
  dest="$APP_BACKUP_DIR/$stamp"
  mkdir -p "$dest" || return 1
  [[ -e "$TIMESYNCD_CONF" ]] && cp -a "$TIMESYNCD_CONF" "$dest/timesyncd.conf" || touch "$dest/timesyncd.conf.MISSING"
  if [[ -d "$TIMESYNCD_DROPIN_DIR" ]]; then cp -a "$TIMESYNCD_DROPIN_DIR" "$dest/timesyncd.conf.d"; fi
  printf '%s\n' "$(current_timezone)" > "$dest/timezone"
  printf '%s\n' "$(timedatectl show -p LocalRTC --value 2>/dev/null || echo no)" > "$dest/localrtc"
  printf '%s\n' "$(ntp_enabled_state)" > "$dest/ntp-enabled"
  chmod -R go-rwx "$dest" 2>/dev/null || true
  log_action INFO "Backup created $dest"
  printf '%s' "$dest"
}

validate_server_token() {
  local s="$1"
  [[ -n "$s" && ${#s} -le 253 && "$s" =~ ^[A-Za-z0-9_.:%-]+$ ]]
}

validate_server_list() {
  local list="$1" seen=" " s
  [[ -n "$(trim "$list")" ]] || { echo "ERROR: NTP server list is empty."; return 1; }
  for s in $list; do
    validate_server_token "$s" || { echo "ERROR: Invalid NTP server token: $s"; return 1; }
    if [[ "$seen" == *" $s "* ]]; then echo "WARNING: Duplicate NTP server: $s"; else seen+="$s "; fi
  done
  return 0
}

write_managed_config() {
  local servers="$1" fallback="$2"
  require_root "Modify NTP configuration" || return 1
  validate_server_list "$servers" >/tmp/ntp-manager-validation.$$ 2>&1 || { ui_msg "Validation error" "$(cat /tmp/ntp-manager-validation.$$)"; rm -f /tmp/ntp-manager-validation.$$; return 1; }
  rm -f /tmp/ntp-manager-validation.$$
  safe_mkdir "$TIMESYNCD_DROPIN_DIR" 0755 || return 1
  local tmp; tmp=$(mktemp "$TIMESYNCD_DROPIN_DIR/.90-ntp-manager.conf.XXXXXX") || return 1
  cat > "$tmp" <<EOF2
# Managed by ntp-manager.sh. Other timesyncd settings remain untouched.
[Time]
NTP=$servers
FallbackNTP=$fallback
EOF2
  chmod 0644 "$tmp"
  mv -f "$tmp" "$MANAGED_DROPIN"
  systemctl daemon-reload >/dev/null 2>&1 || true
  return 0
}

verify_after_change() {
  sleep 2
  local state="Service: $(service_active)\nNTP Enabled: $(ntp_enabled_state)\nClock Synchronized: $(clock_sync_state)\nCurrent Server: $(current_ntp_server)"
  ui_msg "Verification" "$state\n\nIf synchronization is not yet confirmed, timesyncd may need additional polling time."
}

apply_server_list() {
  local servers="$1" fallback="${2:-$(get_fallback_servers)}" desc="${3:-Update NTP servers}"
  local backup
  backup=$(backup_config) || return 1
  if write_managed_config "$servers" "$fallback"; then
    log_action INFO "$desc; servers=$servers"
    systemctl restart systemd-timesyncd >/dev/null 2>&1 || { log_failure "Restart failed after: $desc"; ui_msg "Service warning" "Configuration was written, but restarting systemd-timesyncd failed. Backup: $backup"; return 1; }
    verify_after_change
  else
    ui_msg "Error" "Configuration update failed. Backup was created at $backup."
    return 1
  fi
}

# ---------- server management ----------
add_ntp_server() {
  local server raw rc review choice current newlist
  server=$(ui_input "Add NTP Server" "Enter IPv4, IPv6, hostname, or internal DNS name:" "") || return
  validate_address "$server" || { ui_msg "Invalid address" "The address/hostname could not be validated or resolved locally: $server"; return; }
  while true; do
    raw=$(probe_ntp_server_raw "$server"); rc=$?
    review=$(format_probe_result "$server" "$raw")
    show_text "NTP Server Test" "$review"
    if [[ $rc -eq 0 ]]; then
      choice=$(ui_menu "Server Review" "Review complete. Select an action." "APPLY" "Apply Server" "TEST" "Test Again" "CANCEL" "Cancel") || return
      case "$choice" in
        TEST) continue ;;
        CANCEL) return ;;
        APPLY)
          current=$(get_configured_servers)
          if grep -qw -- "$server" <<<"$current"; then ui_msg "Already configured" "$server is already in the NTP server list."; return; fi
          newlist=$(trim "$current $server")
          ui_yesno "Apply Server" "TEST passed.\n\nCurrent servers: ${current:-N/A}\nNew servers    : $newlist\n\nReview → Backup → Apply → Restart → Verify\n\nApply?" || return
          apply_server_list "$newlist" "$(get_fallback_servers)" "Added NTP server $server"
          return ;;
      esac
    else
      choice=$(ui_menu "Failed NTP Test" "The server did not pass a valid NTP test." "TEST" "Test Again" "OVERRIDE" "Advanced override and add anyway" "CANCEL" "Cancel") || return
      case "$choice" in
        TEST) continue ;;
        CANCEL) return ;;
        OVERRIDE)
          ui_yesno "Advanced Override" "WARNING: This server did NOT return a valid NTP response.\n\nAdding it may leave the host unsynchronized. Continue anyway?" || return
          current=$(get_configured_servers); newlist=$(trim "$current $server")
          apply_server_list "$newlist" "$(get_fallback_servers)" "Added NTP server $server with failed-test override"
          return ;;
      esac
    fi
  done
}

remove_ntp_server() {
  local current=( $(get_configured_servers) )
  ((${#current[@]})) || { ui_msg "NTP Servers" "No configured NTP servers were found."; return; }
  local args=() s sel new=()
  for s in "${current[@]}"; do args+=("$s" "Configured NTP server"); done
  args+=("BACK" "Cancel")
  sel=$(ui_menu "Remove NTP Server" "Select a server to remove." "${args[@]}") || return
  [[ "$sel" == BACK ]] && return
  ui_yesno "Confirm Removal" "Remove $sel?\n\nA backup will be created before configuration is changed." || return
  for s in "${current[@]}"; do [[ "$s" == "$sel" ]] || new+=("$s"); done
  if ((${#new[@]}==0)); then
    ui_yesno "Empty NTP List" "This removes the last configured NTP server. Continue?" || return
    require_root "Remove last NTP server" || return
    local backup; backup=$(backup_config) || return
    safe_mkdir "$TIMESYNCD_DROPIN_DIR" 0755
    cat > "$MANAGED_DROPIN" <<EOF2
# Managed by ntp-manager.sh
[Time]
NTP=
FallbackNTP=$(get_fallback_servers)
EOF2
    chmod 0644 "$MANAGED_DROPIN"; systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
    log_action INFO "Removed NTP server $sel; list now empty"
    verify_after_change
  else
    apply_server_list "${new[*]}" "$(get_fallback_servers)" "Removed NTP server $sel"
  fi
}

test_all_ntp_servers() {
  local servers=( $(get_configured_servers) )
  ((${#servers[@]})) || { ui_msg "Test All" "No NTP servers are configured."; return; }
  local out="" s raw res off delay
  for s in "${servers[@]}"; do
    raw=$(probe_ntp_server_raw "$s"); res=$(probe_value RESULT "$raw"); off=$(probe_value OFFSET_SECONDS "$raw"); delay=$(probe_value DELAY_SECONDS "$raw")
    [[ "$off" =~ ^-?[0-9.]+$ ]] && off=$(awk -v x="$off" 'BEGIN{printf "%+.3f ms",x*1000}') || off="N/A"
    [[ "$delay" =~ ^-?[0-9.]+$ ]] && delay=$(awk -v x="$delay" 'BEGIN{printf "%.3f ms",x*1000}') || delay="N/A"
    out+=$(printf '%-35s UDP/123=%-5s NTP=%-5s Offset=%-12s Delay=%s\n' "$s" "$(probe_value UDP123 "$raw")" "$([[ "$res" == PASS ]] && echo PASS || echo FAIL)" "$off" "$delay")
  done
  show_text "All NTP Server Tests" "$out"
}

show_ntp_config() {
  local eff=""
  if have systemd-analyze; then eff=$(systemd-analyze cat-config systemd/timesyncd.conf 2>/dev/null || true); fi
  [[ -z "$eff" ]] && eff="$(for f in "$TIMESYNCD_CONF" "$TIMESYNCD_DROPIN_DIR"/*.conf; do [[ -r "$f" ]] && { echo "### $f"; cat "$f"; echo; }; done)"
  show_text "NTP Configuration" "Configured NTP     : $(get_configured_servers | sed 's/^$/N/A/')
Fallback NTP       : $(get_fallback_servers | sed 's/^$/N/A/')
Managed Drop-in    : $MANAGED_DROPIN

Effective / available configuration:
$eff"
}

# ---------- synchronization/service ----------
enable_ntp() { require_root "Enable NTP" || return; ui_yesno "Enable NTP" "Run timedatectl set-ntp true?" || return; timedatectl set-ntp true && log_action INFO "NTP enabled"; verify_after_change; }
disable_ntp() { require_root "Disable NTP" || return; ui_yesno "Disable NTP" "This disables automatic network time synchronization. Continue?" || return; timedatectl set-ntp false && log_action INFO "NTP disabled"; verify_after_change; }
service_action() {
  local action="$1"
  require_root "$action systemd-timesyncd" || return
  ui_yesno "Service Action" "Run: systemctl $action systemd-timesyncd ?" || return
  if systemctl "$action" systemd-timesyncd; then log_action INFO "systemd-timesyncd $action"; verify_after_change; else log_failure "systemd-timesyncd $action failed"; ui_msg "Error" "Service action failed."; fi
}
force_sync() {
  require_root "Force/restart synchronization" || return
  ui_yesno "Force Synchronization" "systemd-timesyncd has no universal one-shot force-sync command.\n\nThis operation will restart systemd-timesyncd to trigger immediate reselection/polling. Continue?" || return
  systemctl restart systemd-timesyncd && log_action INFO "Forced synchronization by restarting systemd-timesyncd"
  verify_after_change
}

show_sync_status() {
  local out="=== timedatectl status ===
$(timedatectl status 2>&1)

=== timedatectl show ===
$(timedatectl show 2>&1)"
  if timedatectl timesync-status >/dev/null 2>&1; then out+="\n\n=== timedatectl timesync-status ===\n$(timedatectl timesync-status 2>&1)"; else out+="\n\n=== timesync-status ===\nNot supported by this systemd version"; fi
  if timedatectl show-timesync >/dev/null 2>&1; then out+="\n\n=== timedatectl show-timesync ===\n$(timedatectl show-timesync 2>&1)"; else out+="\n\n=== show-timesync ===\nNot supported by this systemd version"; fi
  show_text "Synchronization Status" "$out"
}

# ---------- logs/monitoring ----------
recent_logs() {
  local choice since
  choice=$(ui_menu "NTP Logs" "Select journal period." "10M" "Last 10 minutes" "1H" "Last hour" "24H" "Last 24 hours" "BOOT" "Since boot" "CUSTOM" "Custom --since value" "BACK" "Back") || return
  case "$choice" in
    10M) since="10 minutes ago";; 1H) since="1 hour ago";; 24H) since="24 hours ago";; BOOT) since="";; CUSTOM) since=$(ui_input "Custom period" "Enter journalctl --since value:" "$DIAG_LOG_PERIOD") || return;; BACK) return;;
  esac
  local tmp; tmp=$(mktemp "$TMP_ROOT/ntp-journal.XXXXXX") || return
  if [[ "$choice" == BOOT ]]; then journalctl -u systemd-timesyncd -b --no-pager > "$tmp" 2>&1; else journalctl -u systemd-timesyncd --since "$since" --no-pager > "$tmp" 2>&1; fi
  ui_textbox_file "systemd-timesyncd Journal" "$tmp"; rm -f "$tmp"
}

failed_logs() {
  local tmp; tmp=$(mktemp "$TMP_ROOT/ntp-failed.XXXXXX") || return
  journalctl -u systemd-timesyncd --since "$DIAG_LOG_PERIOD" --no-pager 2>&1 | grep -Ei 'fail|error|timeout|unreach|invalid|denied' > "$tmp" || true
  [[ -s "$tmp" ]] || echo "No matching failed/error events found in selected period." > "$tmp"
  ui_textbox_file "Failed NTP Events" "$tmp"; rm -f "$tmp"
}

live_log_monitor() {
  local tmp; tmp=$(mktemp "$TMP_ROOT/ntp-livejournal.XXXXXX") || return
  journalctl -u systemd-timesyncd -n 100 --no-pager > "$tmp" 2>&1
  if [[ "$TUI" == dialog ]]; then
    (journalctl -u systemd-timesyncd -f --no-pager >> "$tmp" 2>&1) & local pid=$!; dialog --title "Live NTP Log Monitoring" --tailbox "$tmp" 25 100; kill "$pid" 2>/dev/null || true
  else
    show_text "Live Log Monitoring" "Live follow is best with dialog. Current environment shows recent events instead.\n\n$(cat "$tmp")"
  fi
  rm -f "$tmp"
}

extract_timesync_field() {
  local prop="$1"
  timedatectl show-timesync -p "$prop" --value 2>/dev/null || true
}

record_sync_history() {
  is_root || return 0
  safe_mkdir "$APP_LOG_DIR" 0750
  printf '%s server=%s synchronized=%s service=%s offset=%s\n' "$(log_ts)" "$(current_ntp_server)" "$(clock_sync_state)" "$(service_active)" "$(extract_timesync_field OffsetUSec)" >> "$APP_LOG_DIR/sync-history.log" 2>/dev/null || true
}

live_monitor() {
  local tmp; tmp=$(mktemp "$TMP_ROOT/ntp-monitor.XXXXXX") || return
  if [[ ! -t 0 || "$TUI" != "bash" ]]; then
    # whiptail/dialog cannot refresh an info box portably while capturing keys; use terminal mode.
    clear
  fi
  printf 'Live monitoring. Press q to exit.\n'
  while true; do
    local offset rootdist poll last servers
    offset=$(extract_timesync_field OffsetUSec); rootdist=$(extract_timesync_field RootDistanceMaxUSec); poll=$(extract_timesync_field PollIntervalUSec); last=$(extract_timesync_field LastSyncUSec); servers=$(get_configured_servers)
    printf '\033[H\033[2J'
    printf '%s\n%s\n\n' "$APP_NAME - Live Monitoring" "$BRAND"
    printf 'Current time       : %s\nTimezone           : %s\nNTP service        : %s\nSynchronization    : %s\nCurrent NTP server : %s\nOffset             : %s\nRoot distance      : %s\nPoll interval      : %s\nLast sync          : %s\nConfigured servers : %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "$(current_timezone)" "$(service_active)" "$(clock_sync_state)" "$(current_ntp_server)" "${offset:-N/A}" "${rootdist:-N/A}" "${poll:-N/A}" "${last:-N/A}" "${servers:-N/A}"
    printf 'Reachability:\n'
    local s raw
    for s in $servers; do raw=$(probe_ntp_server_raw "$s" 2>/dev/null); printf '  %-35s %s\n' "$s" "$([[ "$(probe_value RESULT "$raw")" == PASS ]] && echo OK || echo FAILED)"; done
    printf '\nPress q to exit. Refresh interval: %ss\n' "$MONITOR_INTERVAL"
    record_sync_history
    IFS= read -r -s -n 1 -t "$MONITOR_INTERVAL" key || true
    [[ "$key" == q || "$key" == Q || "$key" == $'\e' ]] && break
  done
  rm -f "$tmp"
}

# ---------- validation/export/import ----------
validate_config() {
  local errors=() warnings=() info=() servers fallback tz
  servers=$(get_configured_servers); fallback=$(get_fallback_servers); tz=$(current_timezone)
  if [[ -z "$servers" ]]; then errors+=("NTP server list is empty."); else
    local s seen=" "
    for s in $servers; do
      validate_server_token "$s" || errors+=("Invalid NTP server token: $s")
      [[ "$seen" == *" $s "* ]] && warnings+=("Duplicate NTP server: $s") || seen+="$s "
    done
  fi
  timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz" || errors+=("Current timezone is not recognized by timedatectl: $tz")
  [[ -r "$MANAGED_DROPIN" ]] && grep -q '^\[Time\]' "$MANAGED_DROPIN" || info+=("Managed drop-in is absent or not currently used.")
  local s raw
  for s in $servers; do raw=$(probe_ntp_server_raw "$s"); [[ "$(probe_value RESULT "$raw")" == PASS ]] || warnings+=("NTP server did not answer test: $s"); done
  local out="ERRORS:\n"
  ((${#errors[@]})) && out+="$(printf ' - %s\n' "${errors[@]}")" || out+=" - None\n"
  out+="\nWARNINGS:\n"; ((${#warnings[@]})) && out+="$(printf ' - %s\n' "${warnings[@]}")" || out+=" - None\n"
  out+="\nINFO:\n"; ((${#info[@]})) && out+="$(printf ' - %s\n' "${info[@]}")" || out+=" - Configuration syntax checks completed.\n"
  show_text "Configuration Validation" "$out"
  ((${#errors[@]}==0))
}

export_config() {
  local default="/tmp/ntp-config-$(hostname).ntp" path
  path=$(ui_input "Export Configuration" "Enter export file path:" "$default") || return
  [[ "$path" == /* ]] || { ui_msg "Invalid path" "Use an absolute path."; return; }
  local parent; parent=$(dirname "$path")
  [[ -d "$parent" && -w "$parent" ]] || { ui_msg "Cannot write" "Directory is not writable: $parent"; return; }
  local rtc; rtc=$(timedatectl show -p LocalRTC --value 2>/dev/null || echo no); [[ "$rtc" == yes ]] && rtc="LOCAL" || rtc="UTC"
  local tmp; tmp=$(mktemp "$parent/.ntp-export.XXXXXX") || return
  cat > "$tmp" <<EOF2
[Export]
FormatVersion=1
Created=$(now_iso)
SourceHostname=$(hostname)

[Time]
Timezone=$(current_timezone)
RTC=$rtc

[NTP]
Servers=$(get_configured_servers)
FallbackNTP=$(get_fallback_servers)

[Service]
Enabled=$(ntp_enabled_state)
EOF2
  chmod 0644 "$tmp"; mv -f "$tmp" "$path"
  log_action INFO "Exported configuration $path"
  ui_msg "Export Complete" "Configuration exported to:\n$path\n\nThe file contains portable time/NTP settings only. SourceHostname is metadata and will not be applied on import."
}

parse_export_file() {
  local file="$1" line section key val
  IMP_FORMAT="" IMP_CREATED="" IMP_SOURCE="" IMP_TZ="" IMP_RTC="" IMP_SERVERS="" IMP_FALLBACK="" IMP_ENABLED=""
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; [[ -z "$line" || "$line" =~ ^[[:space:]]*[#\;] ]] && continue
    if [[ "$line" =~ ^\[([A-Za-z]+)\]$ ]]; then section="${BASH_REMATCH[1]}"; continue; fi
    [[ "$line" == *=* ]] || return 2
    key="${line%%=*}"; val="${line#*=}"; key=$(trim "$key"); val=$(trim "$val")
    case "$section:$key" in
      Export:FormatVersion) IMP_FORMAT="$val";; Export:Created) IMP_CREATED="$val";; Export:SourceHostname) IMP_SOURCE="$val";;
      Time:Timezone) IMP_TZ="$val";; Time:RTC) IMP_RTC="$val";; NTP:Servers) IMP_SERVERS="$val";; NTP:FallbackNTP) IMP_FALLBACK="$val";; Service:Enabled) IMP_ENABLED="$val";;
      *) return 3;;
    esac
  done < "$file"
  [[ "$IMP_FORMAT" == 1 ]] || return 4
  [[ -n "$IMP_TZ" && -n "$IMP_SERVERS" ]] || return 5
  validate_server_list "$IMP_SERVERS" >/dev/null || return 6
  timedatectl list-timezones 2>/dev/null | grep -Fxq "$IMP_TZ" || return 7
  [[ "$IMP_RTC" == UTC || "$IMP_RTC" == LOCAL ]] || return 8
  [[ "$IMP_ENABLED" == yes || "$IMP_ENABLED" == no || "$IMP_ENABLED" == true || "$IMP_ENABLED" == false ]] || return 9
}

import_review_text() {
  local mode="$1" curtz curservers curfb curen currtc changes=""
  curtz=$(current_timezone); curservers=$(get_configured_servers); curfb=$(get_fallback_servers); curen=$(ntp_enabled_state); currtc=$(timedatectl show -p LocalRTC --value 2>/dev/null || echo no); [[ "$currtc" == yes ]] && currtc=LOCAL || currtc=UTC
  [[ "$curtz" != "$IMP_TZ" ]] && changes+="Timezone      $curtz -> $IMP_TZ\n"
  [[ "$curservers" != "$IMP_SERVERS" ]] && changes+="NTP Servers   ${curservers:-N/A} -> $IMP_SERVERS\n"
  [[ "$curfb" != "$IMP_FALLBACK" ]] && changes+="Fallback NTP  ${curfb:-N/A} -> ${IMP_FALLBACK:-N/A}\n"
  [[ "$curen" != "$IMP_ENABLED" ]] && changes+="NTP Enabled   $curen -> $IMP_ENABLED\n"
  [[ "$currtc" != "$IMP_RTC" ]] && changes+="RTC Mode      $currtc -> $IMP_RTC\n"
  printf 'Source Server : %s\nExport Date   : %s\nFormat        : Version %s\nImport Mode   : %s\n\nCURRENT SERVER\nTimezone      : %s\nRTC           : %s\nNTP Servers   : %s\nFallback NTP  : %s\nNTP Enabled   : %s\n\nIMPORTED CONFIGURATION\nTimezone      : %s\nRTC           : %s\nNTP Servers   : %s\nFallback NTP  : %s\nNTP Enabled   : %s\n\nCHANGES\n%b' "$IMP_SOURCE" "$IMP_CREATED" "$IMP_FORMAT" "$mode" "$curtz" "$currtc" "${curservers:-N/A}" "${curfb:-N/A}" "$curen" "$IMP_TZ" "$IMP_RTC" "$IMP_SERVERS" "${IMP_FALLBACK:-N/A}" "$IMP_ENABLED" "${changes:-No differences detected.\n}"
}

test_imported_servers() {
  local failed=0 out="" s raw
  for s in $IMP_SERVERS; do raw=$(probe_ntp_server_raw "$s"); if [[ "$(probe_value RESULT "$raw")" == PASS ]]; then out+="$s  ✓ VALID\n"; else out+="$s  ✗ FAILED\n"; failed=1; fi; done
  show_text "Imported NTP Server Tests" "$out"
  return $failed
}

apply_import() {
  local mode="$1" file="$2" backup
  require_root "Import configuration" || return
  backup=$(backup_config) || return
  case "$mode" in
    COMPLETE)
      timedatectl set-timezone "$IMP_TZ" || return 1
      [[ "$IMP_RTC" == UTC ]] && timedatectl set-local-rtc 0 --adjust-system-clock || timedatectl set-local-rtc 1 --adjust-system-clock
      write_managed_config "$IMP_SERVERS" "$IMP_FALLBACK" || return 1
      [[ "$IMP_ENABLED" =~ ^(yes|true)$ ]] && timedatectl set-ntp true || timedatectl set-ntp false ;;
    NTP) write_managed_config "$IMP_SERVERS" "$IMP_FALLBACK" || return 1 ;;
    TZ) timedatectl set-timezone "$IMP_TZ" || return 1 ;;
    NTPTZ) timedatectl set-timezone "$IMP_TZ" || return 1; write_managed_config "$IMP_SERVERS" "$IMP_FALLBACK" || return 1 ;;
  esac
  systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
  log_action INFO "Imported configuration $file mode=$mode"
  verify_after_change
}

import_config() {
  local file mode review failed
  file=$(ui_input "Import Configuration" "Enter exported configuration path:" "/tmp/ntp-config.ntp") || return
  parse_export_file "$file"; local rc=$?
  if [[ $rc -ne 0 ]]; then ui_msg "Invalid Import" "The import file failed validation (code $rc). Nothing was changed."; return; fi
  mode=$(ui_menu "Import Mode" "Choose what to import." "COMPLETE" "Import complete configuration" "NTP" "Import NTP servers only" "TZ" "Import timezone only" "NTPTZ" "Import NTP + timezone" "PREVIEW" "Preview only" "BACK" "Cancel") || return
  [[ "$mode" == BACK ]] && return
  review=$(import_review_text "$mode"); show_text "Import Review" "$review"
  [[ "$mode" == PREVIEW ]] && return
  if [[ "$mode" == COMPLETE || "$mode" == NTP || "$mode" == NTPTZ ]]; then
    if ui_yesno "Test Imported Servers" "Test imported NTP servers before applying? (recommended)"; then
      test_imported_servers; failed=$?
      if [[ $failed -ne 0 ]]; then ui_yesno "Failed Imported Server" "One or more imported NTP servers failed a real NTP test.\n\nContinue only with explicit override?" || return; fi
    fi
  fi
  ui_yesno "Apply Import" "Review completed.\n\nBackup → Apply selected settings → Restart if needed → Verify\n\nApply imported configuration?" || return
  apply_import "$mode" "$file"
}

# ---------- restore ----------
list_backups() {
  [[ -d "$APP_BACKUP_DIR" ]] || { ui_msg "Backups" "No backup directory exists."; return; }
  local out; out=$(find "$APP_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
  show_text "Backups" "${out:-No backups found.}"
}

restore_config() {
  require_root "Restore backup" || return
  local dirs=() d args=() sel
  while IFS= read -r d; do [[ -n "$d" ]] && dirs+=("$d"); done < <(find "$APP_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
  ((${#dirs[@]})) || { ui_msg "Restore" "No backups found."; return; }
  for d in "${dirs[@]}"; do args+=("$d" "Backup snapshot"); done
  sel=$(ui_menu "Restore Backup" "Select backup to restore." "${args[@]}") || return
  local src="$APP_BACKUP_DIR/$sel" review="Restore snapshot: $src\n\n"
  [[ -f "$src/timesyncd.conf" ]] && review+="timesyncd.conf: present\n" || review+="timesyncd.conf: originally missing/unknown\n"
  [[ -d "$src/timesyncd.conf.d" ]] && review+="timesyncd.conf.d: present\n"
  review+="Timezone: $(cat "$src/timezone" 2>/dev/null || echo N/A)\nRTC Local: $(cat "$src/localrtc" 2>/dev/null || echo N/A)\nNTP enabled: $(cat "$src/ntp-enabled" 2>/dev/null || echo N/A)"
  show_text "Restore Review" "$review"
  ui_yesno "Confirm Restore" "Restore this backup? A new safety backup of the current state will be created first." || return
  backup_config >/dev/null || return
  if [[ -f "$src/timesyncd.conf" ]]; then cp -a "$src/timesyncd.conf" "$TIMESYNCD_CONF"; elif [[ -f "$src/timesyncd.conf.MISSING" ]]; then rm -f "$TIMESYNCD_CONF"; fi
  # Restore only the application-managed drop-in; never delete or overwrite unrelated drop-ins.
  safe_mkdir "$TIMESYNCD_DROPIN_DIR" 0755
  if [[ -f "$src/timesyncd.conf.d/$(basename "$MANAGED_DROPIN")" ]]; then
    cp -a "$src/timesyncd.conf.d/$(basename "$MANAGED_DROPIN")" "$MANAGED_DROPIN"
  else
    rm -f "$MANAGED_DROPIN"
  fi
  local tz rtc nen; tz=$(cat "$src/timezone" 2>/dev/null || true); rtc=$(cat "$src/localrtc" 2>/dev/null || true); nen=$(cat "$src/ntp-enabled" 2>/dev/null || true)
  [[ -n "$tz" ]] && timedatectl set-timezone "$tz" >/dev/null 2>&1 || true
  [[ "$rtc" == yes ]] && timedatectl set-local-rtc 1 --adjust-system-clock >/dev/null 2>&1 || [[ "$rtc" == no ]] && timedatectl set-local-rtc 0 --adjust-system-clock >/dev/null 2>&1 || true
  [[ "$nen" == yes || "$nen" == true ]] && timedatectl set-ntp true >/dev/null 2>&1 || [[ "$nen" == no || "$nen" == false ]] && timedatectl set-ntp false >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true; systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
  log_action INFO "Restored backup $src"
  verify_after_change
}

create_backup_interactive() { local b; b=$(backup_config) && ui_msg "Backup" "Backup created:\n$b"; }
delete_old_backups() { require_root "Delete old backups" || return; ui_yesno "Delete Old Backups" "Delete backup directories older than $BACKUP_RETENTION_DAYS days?" || return; find "$APP_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} + 2>/dev/null; log_action INFO "Deleted backups older than $BACKUP_RETENTION_DAYS days"; ui_msg "Backups" "Retention cleanup complete."; }

# ---------- diagnostics ----------
diagnostic_report() {
  local default="/tmp/ntp-diagnostic-$(hostname)-$(date +%Y%m%d-%H%M%S).txt" path
  path=$(ui_input "Diagnostic Report" "Save diagnostic report to:" "$default") || return
  local tmp; tmp=$(mktemp "$TMP_ROOT/ntp-diagnostic.XXXXXX") || return
  {
    echo "NTP CLIENT MANAGER DIAGNOSTIC REPORT"; echo "Generated: $(now_iso)"; echo
    echo "== System Information =="; echo "OS: $(os_pretty)"; echo "Kernel: $(uname -r)"; echo "Hostname: $(hostname)"; echo "Architecture: $(uname -m)"; echo "Systemd: $(systemd_version)"; echo
    echo "== Time =="; echo "Local: $(date '+%Y-%m-%d %H:%M:%S.%3N %Z')"; echo "UTC: $(date -u '+%Y-%m-%d %H:%M:%S.%3N UTC')"; echo "Timezone: $(current_timezone)"; echo
    echo "== timedatectl status =="; timedatectl status 2>&1; echo
    echo "== timesyncd service =="; systemctl status systemd-timesyncd --no-pager 2>&1; echo
    echo "== NTP configuration =="; for f in "$TIMESYNCD_CONF" "$TIMESYNCD_DROPIN_DIR"/*.conf; do [[ -r "$f" ]] && { echo "--- $f"; cat "$f"; }; done; echo
    echo "== Synchronization =="; timedatectl timesync-status 2>&1 || echo "timesync-status not supported"; timedatectl show-timesync 2>&1 || echo "show-timesync not supported"; echo
    echo "== Server connectivity tests =="; local s raw; for s in $(get_configured_servers); do echo "--- $s"; raw=$(probe_ntp_server_raw "$s" 2>&1); format_probe_result "$s" "$raw"; done; echo
    echo "== Recent journal ($DIAG_LOG_PERIOD) =="; journalctl -u systemd-timesyncd --since "$DIAG_LOG_PERIOD" --no-pager 2>&1
  } > "$tmp"
  if cp "$tmp" "$path" 2>/dev/null; then chmod 0640 "$path" 2>/dev/null || true; log_action INFO "Diagnostic report saved $path"; ui_msg "Diagnostics" "Report saved to:\n$path\n\nNo credentials or secrets are intentionally included."; else ui_msg "Error" "Could not write report to $path"; fi
  rm -f "$tmp"
}

# ---------- settings/cleanup ----------
settings_menu() {
  local c v
  while true; do
    c=$(ui_menu "Settings" "Application-specific settings" "INTERVAL" "Monitoring interval: ${MONITOR_INTERVAL}s" "LOGRET" "Log retention: ${LOG_RETENTION_DAYS} days" "BAKRET" "Backup retention: ${BACKUP_RETENTION_DAYS} days" "DIAG" "Diagnostic log period: $DIAG_LOG_PERIOD" "TIMEOUT" "NTP test timeout: ${NTP_TEST_TIMEOUT}s" "REMOVE" "Remove NTP Manager Data" "BACK" "Back") || return
    case "$c" in
      INTERVAL) v=$(ui_input "Monitoring Interval" "Seconds:" "$MONITOR_INTERVAL") || continue; [[ "$v" =~ ^[1-9][0-9]*$ ]] && MONITOR_INTERVAL="$v" && save_settings ;;
      LOGRET) v=$(ui_input "Log Retention" "Days:" "$LOG_RETENTION_DAYS") || continue; [[ "$v" =~ ^[1-9][0-9]*$ ]] && LOG_RETENTION_DAYS="$v" && save_settings ;;
      BAKRET) v=$(ui_input "Backup Retention" "Days:" "$BACKUP_RETENTION_DAYS") || continue; [[ "$v" =~ ^[1-9][0-9]*$ ]] && BACKUP_RETENTION_DAYS="$v" && save_settings ;;
      DIAG) v=$(ui_input "Diagnostic Log Period" "journalctl --since value:" "$DIAG_LOG_PERIOD") || continue; [[ -n "$v" ]] && DIAG_LOG_PERIOD="$v" && save_settings ;;
      TIMEOUT) v=$(ui_input "NTP Test Timeout" "Seconds:" "$NTP_TEST_TIMEOUT") || continue; [[ "$v" =~ ^[1-9][0-9]*$ ]] && NTP_TEST_TIMEOUT="$v" && save_settings ;;
      REMOVE)
        require_root "Remove NTP Manager application-owned data" || continue
        ui_yesno "Remove Application Data" "This removes ONLY application-owned directories:\n$APP_ETC\n$APP_LOG_DIR\n$APP_BACKUP_DIR\n$APP_STATE_DIR\n\nIt will NOT remove systemd-timesyncd or $TIMESYNCD_CONF.\n\nContinue?" || continue
        rm -rf "$APP_ETC" "$APP_LOG_DIR" "$APP_BACKUP_DIR" "$APP_STATE_DIR"; ui_msg "Cleanup" "Application-owned data removed. System NTP configuration was not removed." ;;
      BACK) return ;;
    esac
  done
}

# ---------- menus ----------
time_menu() { local c; while true; do c=$(ui_menu "Time & Timezone" "Choose an action." "TIME" "View current/local/UTC time" "TZ" "Change timezone" "RTC" "RTC management" "BACK" "Back") || return; case "$c" in TIME) show_current_time;; TZ) set_timezone;; RTC) rtc_management;; BACK) return;; esac; done; }
servers_menu() { local c; while true; do c=$(ui_menu "NTP Servers" "TEST → REVIEW → APPLY" "ADD" "Add NTP server" "REMOVE" "Remove NTP server" "TESTALL" "Test all configured servers" "BACK" "Back") || return; case "$c" in ADD) add_ntp_server;; REMOVE) remove_ntp_server;; TESTALL) test_all_ntp_servers;; BACK) return;; esac; done; }
sync_menu() { local c; while true; do c=$(ui_menu "Synchronization" "NTP synchronization controls" "STATUS" "View synchronization state" "ENABLE" "Enable NTP" "DISABLE" "Disable NTP" "FORCE" "Force/restart synchronization" "BACK" "Back") || return; case "$c" in STATUS) show_sync_status;; ENABLE) enable_ntp;; DISABLE) disable_ntp;; FORCE) force_sync;; BACK) return;; esac; done; }
service_menu() { local c; while true; do c=$(ui_menu "Service" "systemd-timesyncd service controls" "START" "Start timesyncd" "STOP" "Stop timesyncd" "RESTART" "Restart timesyncd" "STATUS" "Service status" "BACK" "Back") || return; case "$c" in START) service_action start;; STOP) service_action stop;; RESTART) service_action restart;; STATUS) show_text "Service Status" "$(systemctl status systemd-timesyncd --no-pager 2>&1)";; BACK) return;; esac; done; }
monitor_menu() { local c; while true; do c=$(ui_menu "Monitoring" "Monitoring and logs" "RECENT" "Recent NTP events" "FAILED" "Failed NTP events" "LIVELOG" "Live log monitoring" "LIVE" "Live NTP dashboard" "HISTORY" "Application monitoring history" "BACK" "Back") || return; case "$c" in RECENT) recent_logs;; FAILED) failed_logs;; LIVELOG) live_log_monitor;; LIVE) live_monitor;; HISTORY) show_text "Local History" "$(cat "$APP_LOG_DIR/sync-history.log" 2>/dev/null || echo 'No application-generated history yet.')";; BACK) return;; esac; done; }
backup_menu() { local c; while true; do c=$(ui_menu "Backup / Restore" "Configuration snapshots" "VIEW" "View backups" "CREATE" "Create backup" "RESTORE" "Restore backup" "DELETE" "Delete old backups" "BACK" "Back") || return; case "$c" in VIEW) list_backups;; CREATE) create_backup_interactive;; RESTORE) restore_config;; DELETE) delete_old_backups;; BACK) return;; esac; done; }
diagnostics_menu() { local c; while true; do c=$(ui_menu "Diagnostics" "Validation and diagnostic tools" "SYSTEM" "System detection" "VALIDATE" "Validate configuration" "REPORT" "Generate diagnostic report" "SYNC" "Synchronization information" "BACK" "Back") || return; case "$c" in SYSTEM) show_system_detection;; VALIDATE) validate_config;; REPORT) diagnostic_report;; SYNC) show_sync_status;; BACK) return;; esac; done; }

first_run() {
  [[ -e "$APP_CONF" || -d "$APP_STATE_DIR" ]] && return 0
  if is_root; then
    ui_yesno "First Run" "$APP_NAME\n\nSystem detected:\n$(os_pretty)\nsystemd-timesyncd: $(have timedatectl && echo detected || echo unavailable)\n\nNo application configuration found. Initialize NTP Manager?" || exit 0
    init_owned_dirs
    save_settings >/dev/null 2>&1 || true
    log_action INFO "NTP Manager initialized"
  else
    ui_msg "First Run" "No application configuration was found. Read-only functions can still be used. Administrative initialization will occur when run with sudo."
  fi
}

startup_checks() {
  local critical=(bash systemctl timedatectl journalctl awk sed grep date getent)
  local missing=() c
  for c in "${critical[@]}"; do have "$c" || missing+=("$c"); done
  if ((${#missing[@]})); then printf 'Missing required commands: %s\n' "${missing[*]}" >&2; exit 1; fi
  if ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1 && ! systemctl status systemd-timesyncd >/dev/null 2>&1; then
    ui_msg "Compatibility Warning" "systemd-timesyncd does not appear to be available on this host. The application can display some system information, but NTP management requires systemd-timesyncd."
  fi
}

show_main_menu() {
  local c
  while true; do
    c=$(ui_menu "$APP_NAME" "Keyboard: ↑↓ Navigate | ENTER Select | ESC Back\nHost: $(hostname) | Time: $(date '+%Y-%m-%d %H:%M:%S') | Sync: $(clock_sync_state)" \
      "OVERVIEW" "Overview" \
      "TIME" "Time & Timezone" \
      "CONFIG" "NTP Configuration" \
      "SERVERS" "NTP Servers" \
      "SYNC" "Synchronization" \
      "SERVICE" "Service" \
      "MONITOR" "Monitoring" \
      "DIAG" "Diagnostics" \
      "EXPORT" "Export Configuration" \
      "IMPORT" "Import Configuration" \
      "BACKUP" "Backup / Restore" \
      "SETTINGS" "Settings" \
      "EXIT" "Exit") || break
    case "$c" in
      OVERVIEW) show_overview;; TIME) time_menu;; CONFIG) show_ntp_config;; SERVERS) servers_menu;; SYNC) sync_menu;; SERVICE) service_menu;; MONITOR) monitor_menu;; DIAG) diagnostics_menu;; EXPORT) export_config;; IMPORT) import_config;; BACKUP) backup_menu;; SETTINGS) settings_menu;; EXIT) break;;
    esac
  done
}

main() {
  detect_tui
  startup_checks
  maybe_offer_cached_whiptail
  load_settings
  init_owned_dirs
  cleanup_retention
  first_run
  show_main_menu
}

main "$@"
