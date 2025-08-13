#!/usr/bin/env bash
set -euo pipefail

# Kiosk Setup Script for Ubuntu
# - Installs and configures Chromium kiosk, Apache/PHP status page, Plymouth logo, DHCP timeout
# - Disables energy saving
# - Autologins a kiosk user and starts Chromium in kiosk mode on each monitor
# - Idempotent and can run headless without hanging
# - Provides progress display and detailed logging

# ==========================
# Configurables (can be overridden in /etc/kiosk-setup.conf)
# ==========================

DEFAULT_KIOSK_USER="kiosk"
DEFAULT_BOOT_URL="http://localhost/"
DEFAULT_BOOT_LOGO_PATH="/usr/share/plymouth/themes/kiosk/logo.png"
DEFAULT_PLYMOUTH_THEME_NAME="kiosk"
DEFAULT_DHCP_TIMEOUT_SECONDS=15
DEFAULT_DISABLE_ENERGY_SAVING="true"
DEFAULT_WINDOW_MANAGER="openbox"
DEFAULT_TTY_AUTLOGIN="tty1"
DEFAULT_APACHE_DOCROOT="/var/www/html"
DEFAULT_LOG_FILE="/var/log/kiosk-setup.log"

# Global state
DRY_RUN="false"
LOG_FILE="${DEFAULT_LOG_FILE}"
CONFIG_FILE_PATH="/etc/kiosk-setup.conf"
TOTAL_STEPS=0
CURRENT_STEP=0

# Read CLI flags
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN="true"
      ;;
    --config=*)
      CONFIG_FILE_PATH="${arg#*=}"
      ;;
    *)
      ;;
  esac
done

# Utility: run command with optional dry-run
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
    return 0
  fi
  eval "$@"
}

# Utility: log
log() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[$timestamp] $*"
  else
    echo "[$timestamp] $*" | tee -a "$LOG_FILE"
  fi
}

# Utility: progress bar
progress_init() {
  TOTAL_STEPS=$1
  CURRENT_STEP=0
}

progress_step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
  local done=$((percent / 2))
  local left=$((50 - done))
  printf "\r[%-*s%*s] %3d%% %s" "$done" "##############################################" "$left" "" "$percent" "$1"
  if [[ $CURRENT_STEP -eq $TOTAL_STEPS ]]; then
    printf "\n"
  fi
}

# Require root unless dry-run
require_root() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Running in dry-run mode; root is not required."
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
  fi
}

# Prepare logging
setup_logging() {
  if [[ "$DRY_RUN" == "false" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    # Redirect all stdout/stderr to tee
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    # For dry-run, log to stdout only
    LOG_FILE="/dev/null"
  fi
  log "Starting kiosk setup (dry-run=$DRY_RUN)"
}

# Detect apt and set noninteractive
ensure_apt_noninteractive() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "apt-get not found. This script targets Ubuntu/Debian systems."
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  export APT_LISTCHANGES_FRONTEND=none
}

# Load or create config
load_or_create_config() {
  if [[ -f "$CONFIG_FILE_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE_PATH"
    log "Loaded configuration from $CONFIG_FILE_PATH"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY-RUN] Would create default configuration at $CONFIG_FILE_PATH"
      KIOSK_USER="${DEFAULT_KIOSK_USER}"
      BOOT_URL="${DEFAULT_BOOT_URL}"
      BOOT_LOGO_PATH="${DEFAULT_BOOT_LOGO_PATH}"
      PLYMOUTH_THEME_NAME="${DEFAULT_PLYMOUTH_THEME_NAME}"
      DHCP_TIMEOUT_SECONDS=${DEFAULT_DHCP_TIMEOUT_SECONDS}
      DISABLE_ENERGY_SAVING="${DEFAULT_DISABLE_ENERGY_SAVING}"
      WINDOW_MANAGER="${DEFAULT_WINDOW_MANAGER}"
      TTY_AUTLOGIN="${DEFAULT_TTY_AUTLOGIN}"
      APACHE_DOCROOT="${DEFAULT_APACHE_DOCROOT}"
      LOG_FILE="${DEFAULT_LOG_FILE}"
    else
      write_file_if_changed "$CONFIG_FILE_PATH" "# Kiosk Setup Configuration\nKIOSK_USER=\"${DEFAULT_KIOSK_USER}\"\nBOOT_URL=\"${DEFAULT_BOOT_URL}\"\nBOOT_LOGO_PATH=\"${DEFAULT_BOOT_LOGO_PATH}\"\nPLYMOUTH_THEME_NAME=\"${DEFAULT_PLYMOUTH_THEME_NAME}\"\nDHCP_TIMEOUT_SECONDS=${DEFAULT_DHCP_TIMEOUT_SECONDS}\nDISABLE_ENERGY_SAVING=\"${DEFAULT_DISABLE_ENERGY_SAVING}\"\nWINDOW_MANAGER=\"${DEFAULT_WINDOW_MANAGER}\"\nTTY_AUTLOGIN=\"${DEFAULT_TTY_AUTLOGIN}\"\nAPACHE_DOCROOT=\"${DEFAULT_APACHE_DOCROOT}\"\nLOG_FILE=\"${DEFAULT_LOG_FILE}\"\n"
      # shellcheck disable=SC1090
      source "$CONFIG_FILE_PATH"
      log "Created default configuration at $CONFIG_FILE_PATH"
    fi
  fi

  # Apply defaults if any missing
  KIOSK_USER=${KIOSK_USER:-$DEFAULT_KIOSK_USER}
  BOOT_URL=${BOOT_URL:-$DEFAULT_BOOT_URL}
  BOOT_LOGO_PATH=${BOOT_LOGO_PATH:-$DEFAULT_BOOT_LOGO_PATH}
  PLYMOUTH_THEME_NAME=${PLYMOUTH_THEME_NAME:-$DEFAULT_PLYMOUTH_THEME_NAME}
  DHCP_TIMEOUT_SECONDS=${DHCP_TIMEOUT_SECONDS:-$DEFAULT_DHCP_TIMEOUT_SECONDS}
  DISABLE_ENERGY_SAVING=${DISABLE_ENERGY_SAVING:-$DEFAULT_DISABLE_ENERGY_SAVING}
  WINDOW_MANAGER=${WINDOW_MANAGER:-$DEFAULT_WINDOW_MANAGER}
  TTY_AUTLOGIN=${TTY_AUTLOGIN:-$DEFAULT_TTY_AUTLOGIN}
  APACHE_DOCROOT=${APACHE_DOCROOT:-$DEFAULT_APACHE_DOCROOT}
  LOG_FILE=${LOG_FILE:-$DEFAULT_LOG_FILE}
}

# Helpers to ensure file content
write_file_if_changed() {
  local destination="$1"
  local content="$2"
  local current=""
  if [[ -f "$destination" ]]; then
    current="$(cat "$destination")"
  fi
  if [[ "$current" != "$content" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would write to $destination:" && echo "$content"
    else
      mkdir -p "$(dirname "$destination")"
      printf "%s" "$content" > "$destination"
    fi
  fi
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  if [[ -f "$file" ]] && grep -Fqx "$line" "$file"; then
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would append to $file: $line"
  else
    mkdir -p "$(dirname "$file")"
    echo "$line" >> "$file"
  fi
}

# Create kiosk user if needed
ensure_kiosk_user() {
  if id -u "$KIOSK_USER" >/dev/null 2>&1; then
    log "User $KIOSK_USER already exists"
  else
    run_cmd useradd -m -s /bin/bash "$KIOSK_USER"
    log "Created user $KIOSK_USER"
  fi
}

# Install packages
install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    run_cmd apt-get update -y
    # Try chromium via apt and snap as fallback
    local base_packages=(\
      apache2 php libapache2-mod-php \
      xserver-xorg xinit openbox x11-xserver-utils xdotool xrandr \
      plymouth plymouth-themes \
      ca-certificates curl jq \
      )

    run_cmd apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${base_packages[@]}"

    if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
      # Try apt chromium
      run_cmd apt-get install -y chromium-browser || true
    fi
    if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
      # Fallback to snap
      if command -v snap >/dev/null 2>&1; then
        run_cmd snap install chromium
        # Create convenience symlink if needed
        if [[ -x /snap/bin/chromium ]] && [[ ! -e /usr/local/bin/chromium ]]; then
          run_cmd ln -sf /snap/bin/chromium /usr/local/bin/chromium
        fi
      else
        log "snap not available and chromium not installed; kiosk may not start."
      fi
    fi
  else
    log "apt-get is unavailable. Skipping package installation."
  fi
}

# Configure Apache/PHP status page
configure_apache_status_page() {
  local index_php_path="$APACHE_DOCROOT/index.php"
  local index_content
  read -r -d '' index_content <<'PHP'
<?php
function h($s){return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');}
$hostname = trim(shell_exec('hostname'));
$ips = trim(shell_exec("hostname -I 2>/dev/null || ip -o -4 addr show | awk '{print \$4}'"));
$kernel = php_uname();
$cpu = trim(shell_exec('lscpu 2>/dev/null | sed -n "1,20p"'));
$mem = trim(shell_exec('free -h 2>/dev/null'));
$disk = trim(shell_exec('df -h / 2>/dev/null'));
?>
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Device Status</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; }
    pre { background: #f7f7f7; padding: 1rem; border-radius: 6px; overflow:auto }
    .kv { margin: 0.4rem 0; }
    .kv span { display:inline-block; width: 180px; font-weight:bold; }
  </style>
</head>
<body>
  <h1>Device Status</h1>
  <div class="kv"><span>Hostname</span> <?=h($hostname)?></div>
  <div class="kv"><span>IP Addresses</span> <?=h($ips)?></div>
  <div class="kv"><span>Kernel</span> <?=h($kernel)?></div>
  <h2>CPU</h2>
  <pre><?=h($cpu)?></pre>
  <h2>Memory</h2>
  <pre><?=h($mem)?></pre>
  <h2>Disk</h2>
  <pre><?=h($disk)?></pre>
</body>
</html>
PHP
  write_file_if_changed "$index_php_path" "$index_content"
  # Ensure index.php served first
  local dir_conf="/etc/apache2/mods-available/dir.conf"
  if [[ -f "$dir_conf" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would ensure DirectoryIndex prioritizes index.php in $dir_conf"
    else
      sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm/' "$dir_conf" || true
    fi
  fi
  # Remove default index.html if present to avoid overshadowing
  if [[ -f "$APACHE_DOCROOT/index.html" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would remove $APACHE_DOCROOT/index.html"
    else
      rm -f "$APACHE_DOCROOT/index.html"
    fi
  fi
  run_cmd a2enmod php* || true
  run_cmd systemctl enable --now apache2 || true
}

# Configure Plymouth theme with logo
configure_plymouth_theme() {
  local theme_dir="/usr/share/plymouth/themes/${PLYMOUTH_THEME_NAME}"
  local plymouth_file="$theme_dir/${PLYMOUTH_THEME_NAME}.plymouth"
  local script_file="$theme_dir/${PLYMOUTH_THEME_NAME}.script"

  local plymouth_content
  read -r -d '' plymouth_content <<PLY
[Plymouth Theme]
Name=${PLYMOUTH_THEME_NAME}
Description=Simple logo with text messages
ModuleName=script

[script]
ImageDir=${theme_dir}
ScriptFile=${script_file}
PLY

  local script_content
  read -r -d '' script_content <<'PLYSCRIPT'
// Simple Plymouth script that shows a logo centered, with messages underneath

Window.SetBackgroundTopColor (0.0, 0.0, 0.0);       // black
Window.SetBackgroundBottomColor (0.0, 0.0, 0.0);    // black

logo_image = Image ("logo.png");
logo_sprite = Sprite (logo_image);
logo_sprite.SetX (Window.GetWidth ()/2 - logo_image.GetWidth ()/2);
logo_sprite.SetY (Window.GetHeight ()/2 - logo_image.GetHeight ()/2 - 40);

txt = Text ("Starting...");
txt.SetX (Window.GetWidth ()/2 - txt.GetWidth ()/2);
txt.SetY (Window.GetHeight ()/2 + logo_image.GetHeight ()/2);

detail = Text ("");
detail.SetX (10);
detail.SetY (Window.GetHeight () - 30);

timeout = 0; // Required variable

fun message_callback (message)
{
  txt.SetText (message);
}

Plymouth.SetUpdateStatusFunction (message_callback);
PLYSCRIPT

  # Create theme files
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would create plymouth theme at $theme_dir"
  else
    mkdir -p "$theme_dir"
  fi
  write_file_if_changed "$plymouth_file" "$plymouth_content"
  write_file_if_changed "$script_file" "$script_content"

  # Ensure logo exists; create placeholder if BOOT_LOGO_PATH not present
  if [[ -f "$BOOT_LOGO_PATH" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would copy $BOOT_LOGO_PATH to $theme_dir/logo.png"
    else
      cp -f "$BOOT_LOGO_PATH" "$theme_dir/logo.png"
    fi
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would create placeholder logo at $theme_dir/logo.png"
    else
      convert -size 400x200 xc:black -gravity center -pointsize 24 -fill white -annotate 0 "Kiosk" "$theme_dir/logo.png" 2>/dev/null || \
      (echo -n > "$theme_dir/logo.png")
    fi
  fi

  # Set theme and rebuild initramfs if possible
  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    run_cmd plymouth-set-default-theme -R "$PLYMOUTH_THEME_NAME" || true
  fi
}

# Configure DHCP timeout
configure_dhcp_timeout() {
  local dhclient_conf="/etc/dhcp/dhclient.conf"
  local line="timeout ${DHCP_TIMEOUT_SECONDS};"
  if [[ -f "$dhclient_conf" ]]; then
    if grep -qE '^\s*timeout\s+\d+;' "$dhclient_conf"; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would replace existing timeout in $dhclient_conf with $line"
      else
        sed -i -E "s/^\s*timeout\s+\d+;/${line}/" "$dhclient_conf"
      fi
    else
      ensure_line_in_file "$line" "$dhclient_conf"
    fi
  else
    write_file_if_changed "$dhclient_conf" "$line\n"
  fi
}

# Disable energy saving
configure_energy_saving() {
  # For the virtual console
  ensure_line_in_file "BLANK_TIME=0" "/etc/kbd/config"
  ensure_line_in_file "POWERDOWN_TIME=0" "/etc/kbd/config"

  # For X sessions, add to kiosk user's X startup
  local xprofile="/home/${KIOSK_USER}/.xprofile"
  local xprofile_content='\n# Disable DPMS and screensaver\nxset -dpms\nxset s off\nxset s noblank\n'
  if [[ -d "/home/${KIOSK_USER}" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would append energy saving disables to $xprofile"
    else
      mkdir -p "$(dirname "$xprofile")"
      grep -Fqx "xset -dpms" "$xprofile" 2>/dev/null || echo -e "$xprofile_content" >> "$xprofile"
      chown "$KIOSK_USER:$KIOSK_USER" "$xprofile" || true
    fi
  fi
}

# Configure autologin and X init
configure_autologin_xinit() {
  # Autologin on tty1
  local override_dir="/etc/systemd/system/getty@${TTY_AUTLOGIN}.service.d"
  local override_path="$override_dir/override.conf"
  local override_content
  read -r -d '' override_content <<UNIT
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=idle
UNIT
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would write $override_path"
  else
    mkdir -p "$override_dir"
  fi
  write_file_if_changed "$override_path" "$override_content"
  run_cmd systemctl daemon-reload || true
  run_cmd systemctl restart "getty@${TTY_AUTLOGIN}.service" || true

  # Start X on login if on tty1
  local profile_file="/home/${KIOSK_USER}/.profile"
  local profile_snippet='\nif [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/'"${TTY_AUTLOGIN}"'" ]; then\n  export XDG_SESSION_TYPE=x11\n  startx\nfi\n'
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would ensure startx snippet in $profile_file"
  else
    mkdir -p "/home/${KIOSK_USER}"
    touch "$profile_file"
    grep -Fq "startx" "$profile_file" || echo -e "$profile_snippet" >> "$profile_file"
    chown "$KIOSK_USER:$KIOSK_USER" "$profile_file" || true
  fi
}

# Launcher that runs Chromium kiosk on every connected monitor
install_kiosk_launcher() {
  local launcher="/usr/local/bin/kiosk-launcher.sh"
  local launcher_content
  read -r -d '' launcher_content <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

BOOT_URL_DEFAULT="http://localhost/"
CONFIG_FILE="/etc/kiosk-setup.conf"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

BOOT_URL="${BOOT_URL:-$BOOT_URL_DEFAULT}"

# Ensure window manager
if ! pgrep -x openbox >/dev/null 2>&1; then
  (openbox-session >/tmp/openbox.log 2>&1 &)
  sleep 1
fi

# Detect monitors
if command -v xrandr >/dev/null 2>&1; then
  mapfile -t monitors < <(xrandr --listmonitors 2>/dev/null | awk 'NR>1 {print $4}')
  if [[ ${#monitors[@]} -eq 0 ]]; then
    mapfile -t monitors < <(xrandr --query | awk '/ connected/{print $1}')
  fi
else
  monitors=("default")
fi

# Chromium binary
CHROME_BIN="$(command -v chromium || true)"
if [[ -z "$CHROME_BIN" ]]; then
  CHROME_BIN="$(command -v chromium-browser || true)"
fi
if [[ -z "$CHROME_BIN" ]]; then
  CHROME_BIN="/snap/bin/chromium"
fi

# Common chromium flags for kiosk mode
COMMON_FLAGS=(
  --no-first-run
  --no-default-browser-check
  --disable-translate
  --incognito
  --kiosk
  --start-fullscreen
  --disable-session-crashed-bubble
  --disable-features=TranslateUI
  --disable-infobars
  --overscroll-history-navigation=0
)

# Launch one window per monitor
INDEX=0
for mon in "${monitors[@]}"; do
  # Optionally position windows per monitor
  # Using --window-position and --window-size requires querying geometry
  if command -v xrandr >/dev/null 2>&1; then
    geom=$(xrandr | awk -v m="$mon" '$0~m" connected"{print $3}' | sed 's/+.*//')
    width=${geom%x*}
    height=${geom#*x}
    xpos=$(xrandr | awk -v m="$mon" '$0~m" connected"{print $3}' | awk -F'+' '{print $2}')
    ypos=$(xrandr | awk -v m="$mon" '$0~m" connected"{print $3}' | awk -F'+' '{print $3}')
    ("$CHROME_BIN" "${COMMON_FLAGS[@]}" --window-position="${xpos:-0},${ypos:-0}" --window-size="${width:-1920},${height:-1080}" "$BOOT_URL" >/tmp/chromium-${INDEX}.log 2>&1 &)
  else
    ("$CHROME_BIN" "${COMMON_FLAGS[@]}" "$BOOT_URL" >/tmp/chromium-${INDEX}.log 2>&1 &)
  fi
  INDEX=$((INDEX+1))
  sleep 0.5
done

# Keep session alive
wait
LAUNCH
  write_file_if_changed "$launcher" "$launcher_content"
  if [[ "$DRY_RUN" == "false" ]]; then
    chmod +x "$launcher"
  fi

  # Xinitrc for kiosk user to run launcher
  local xinit="/home/${KIOSK_USER}/.xinitrc"
  local xinit_content="#!/usr/bin/env bash\nset -e\nexport DISPLAY=:0\nexport XAUTHORITY=\"/home/${KIOSK_USER}/.Xauthority\"\n\n# Disable DPMS/screensaver\nxset -dpms\nxset s off\nxset s noblank\n\n# Start Openbox and kiosk launcher\n/usr/local/bin/kiosk-launcher.sh\n"
  write_file_if_changed "$xinit" "$xinit_content"
  if [[ "$DRY_RUN" == "false" ]]; then
    chmod +x "$xinit"
    chown "$KIOSK_USER:$KIOSK_USER" "$xinit" || true
  fi
}

# Progress plan: list of major steps
compute_total_steps() {
  TOTAL_STEPS=10
}

main() {
  require_root
  setup_logging
  ensure_apt_noninteractive
  load_or_create_config
  ensure_kiosk_user
  compute_total_steps

  progress_step "Installing packages"
  install_packages

  progress_step "Configuring Apache/PHP status page"
  configure_apache_status_page

  progress_step "Configuring Plymouth theme"
  configure_plymouth_theme

  progress_step "Configuring DHCP timeout"
  configure_dhcp_timeout

  progress_step "Disabling energy saving"
  configure_energy_saving

  progress_step "Configuring autologin and X init"
  configure_autologin_xinit

  progress_step "Installing kiosk launcher"
  install_kiosk_launcher

  progress_step "Enabling services"
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl enable apache2 || true
    run_cmd systemctl restart apache2 || true
  fi

  progress_step "Verifying Chromium presence"
  if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
    log "Chromium is not installed; please ensure chromium is available."
  else
    log "Chromium is available."
  fi

  progress_step "Setup complete"
  log "Kiosk setup completed successfully. Reboot to apply Plymouth theme and autologin."
}

# Initialize progress bar
progress_init 10
main "$@"