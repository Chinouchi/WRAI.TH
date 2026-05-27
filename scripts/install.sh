#!/usr/bin/env bash
set -euo pipefail

# Claude Agentic Relay — Cross-platform installer (macOS + Linux)
#
# This is the real installer, shipped as a release asset. End-users should not
# call it directly — they hit the bootstrapper at the repo root which resolves
# the right release and invokes this script with the matching version.
#
# Usage (direct, for testing / debugging):
#   ./install.sh
#   ./install.sh --port 9000 --skip-projects --no-service
#   ./install.sh --uninstall

REPO="Chinouchi/WRAI.TH"
BINARY_NAME="agent-relay"
SERVICE_LABEL="com.agent-relay"
DEFAULT_PORT=8090

# Stamped by the release workflow before this script is uploaded as a release
# asset. When unstamped (dev / source checkout), falls back to "main" so URLs
# resolve to the current repo state.
RELAY_VERSION="@@RELAY_VERSION@@"
if [[ "$RELAY_VERSION" == "@@RELAY_VERSION@@" ]] || [[ -z "$RELAY_VERSION" ]]; then
  RELAY_VERSION="main"
fi

# ── Colors ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  MAGENTA=$(tput setaf 5)
  CYAN=$(tput setaf 6)
else
  BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN=""
fi

info()    { echo "${BLUE}${BOLD}::${RESET} $*"; }
success() { echo "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo "${YELLOW}${BOLD}!${RESET} $*"; }
error()   { echo "${RED}${BOLD}✗${RESET} $*" >&2; }
step()    { echo; echo "${MAGENTA}${BOLD}[$1/7]${RESET} ${BOLD}$2${RESET}"; }

die() { error "$@"; exit 1; }

# ── Spinner ──────────────────────────────────────────────────────────────────

SPINNER_PID=""

spinner_start() {
  local msg="$1"
  if [[ ! -t 1 ]]; then
    echo "  $msg..."
    return
  fi
  (
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
      printf "\r  ${CYAN}%s${RESET} %s" "${frames[$i]}" "$msg"
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
}

SKILL_BUNDLE_DIR=""

cleanup_on_exit() {
  spinner_stop
  if [[ -n "$SKILL_BUNDLE_DIR" ]] && [[ -d "$SKILL_BUNDLE_DIR" ]]; then
    rm -rf "$SKILL_BUNDLE_DIR"
  fi
}

trap 'cleanup_on_exit' EXIT

# ── Args ─────────────────────────────────────────────────────────────────────

UNINSTALL=false
SKIP_PROJECTS=false
NO_SERVICE=false
PORT=$DEFAULT_PORT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uninstall)    UNINSTALL=true ;;
      --skip-projects) SKIP_PROJECTS=true ;;
      --no-service)   NO_SERVICE=true ;;
      --port)         shift; PORT="${1:-$DEFAULT_PORT}" ;;
      --port=*)       PORT="${1#*=}" ;;
      -h|--help)      usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

usage() {
  cat <<EOF
${BOLD}Claude Agentic Relay Installer${RESET}

${BOLD}USAGE:${RESET}
    install.sh [OPTIONS]

${BOLD}OPTIONS:${RESET}
    --port <PORT>       Set relay port (default: $DEFAULT_PORT)
    --skip-projects     Skip project scanning step
    --no-service        Don't install auto-start service
    --uninstall         Remove relay, service, and skill
    -h, --help          Show this help
EOF
}

# ── Platform detection ───────────────────────────────────────────────────────

OS=""
ARCH=""
BIN_DIR=""

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$OS" in
    darwin) OS="darwin" ;;
    linux)  OS="linux" ;;
    *)      die "Unsupported OS: $OS" ;;
  esac

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)   ARCH="amd64" ;;
    arm64|aarch64)   ARCH="arm64" ;;
    *)               die "Unsupported architecture: $ARCH" ;;
  esac

  if [[ "$OS" == "darwin" ]]; then
    if [[ -w "/usr/local/bin" ]]; then
      BIN_DIR="/usr/local/bin"
    else
      BIN_DIR="$HOME/.local/bin"
      mkdir -p "$BIN_DIR"
    fi
  else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
  fi
}

# ── Banner ───────────────────────────────────────────────────────────────────

banner() {
  echo
  echo "${CYAN}${BOLD}  ╔═══════════════════════════════════════╗${RESET}"
  echo "${CYAN}${BOLD}  ║   Claude Agentic Relay — Installer    ║${RESET}"
  echo "${CYAN}${BOLD}  ╚═══════════════════════════════════════╝${RESET}"
  echo
  info "Platform: ${BOLD}${OS}/${ARCH}${RESET}"
  info "Binary:   ${BOLD}${BIN_DIR}/${BINARY_NAME}${RESET}"
  info "Port:     ${BOLD}${PORT}${RESET}"
  echo
}

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
  echo
  echo "${RED}${BOLD}  Uninstalling Claude Agentic Relay${RESET}"
  echo

  # Stop service
  if [[ "$OS" == "darwin" ]]; then
    local plist="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
    if [[ -f "$plist" ]]; then
      info "Stopping launchd service..."
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      rm -f "$plist"
      success "Removed launchd service"
    fi
  else
    if systemctl --user is-active "$BINARY_NAME" &>/dev/null; then
      info "Stopping systemd service..."
      systemctl --user stop "$BINARY_NAME" 2>/dev/null || true
      systemctl --user disable "$BINARY_NAME" 2>/dev/null || true
    fi
    local unit="$HOME/.config/systemd/user/${BINARY_NAME}.service"
    if [[ -f "$unit" ]]; then
      rm -f "$unit"
      systemctl --user daemon-reload 2>/dev/null || true
      success "Removed systemd service"
    fi
  fi

  # Remove binary and ar symlink
  local bin_path="${BIN_DIR}/${BINARY_NAME}"
  local ar_path="${BIN_DIR}/ar"
  if [[ -L "$ar_path" ]] && [[ "$(readlink "$ar_path")" == "$bin_path" ]]; then
    if [[ -w "$(dirname "$ar_path")" ]]; then
      rm -f "$ar_path"
    else
      sudo rm -f "$ar_path"
    fi
    success "Removed ar symlink"
  fi
  if [[ -f "$bin_path" ]]; then
    if [[ -w "$bin_path" ]] || [[ -w "$(dirname "$bin_path")" ]]; then
      rm -f "$bin_path"
    else
      sudo rm -f "$bin_path"
    fi
    success "Removed binary"
  fi

  # Remove skill (new location)
  local skill_dir="$HOME/.claude/skills/relay"
  if [[ -d "$skill_dir" ]]; then
    rm -rf "$skill_dir"
    success "Removed /relay skill"
  fi

  # Remove legacy command (older installs)
  local legacy_cmd="$HOME/.claude/commands/relay.md"
  if [[ -f "$legacy_cmd" ]]; then
    rm -f "$legacy_cmd"
    success "Removed legacy /relay command"
  fi

  # Remove activity hooks (scripts + settings.json entries)
  local hooks_dir="$HOME/.claude/hooks"
  local settings_file="$HOME/.claude/settings.json"
  local hook_scripts=(
    "ingest-pre-tool.sh"
    "ingest-post-tool.sh"
    "ingest-stop.sh"
    "ingest-subagent-start.sh"
    "ingest-subagent-stop.sh"
  )
  local removed_count=0
  for script in "${hook_scripts[@]}"; do
    if [[ -f "${hooks_dir}/${script}" ]]; then
      rm -f "${hooks_dir}/${script}"
      ((removed_count++))
    fi
  done
  if [[ $removed_count -gt 0 ]]; then
    success "Removed ${removed_count} activity hook script(s)"
  fi

  # Strip our entries from settings.json (match by command path prefix)
  if [[ -f "$settings_file" ]] && command -v python3 &>/dev/null; then
    cp "$settings_file" "${settings_file}.bak" 2>/dev/null || true
    python3 -c "
import json, os

path = os.path.expanduser('$settings_file')
with open(path) as f:
    data = json.load(f)

prefix = '${hooks_dir}/ingest-'
hooks = data.get('hooks', {})
for event in list(hooks.keys()):
    hooks[event] = [
        h for h in hooks[event]
        if not (isinstance(h, dict) and any(
            sub.get('command', '').startswith(prefix)
            for sub in h.get('hooks', [])
            if isinstance(sub, dict)
        ))
    ]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    data.pop('hooks', None)

with open(path, 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
" 2>/dev/null && info "Cleaned hook entries from ${DIM}${settings_file}${RESET}"
  fi

  # Data directory
  local data_dir="$HOME/.agent-relay"
  if [[ -d "$data_dir" ]]; then
    echo
    warn "Data directory exists: ${BOLD}${data_dir}${RESET}"
    if [[ -t 0 ]]; then
      read -rp "  Delete relay data (messages, agents)? [y/N] " answer
      if [[ "${answer,,}" == "y" ]]; then
        rm -rf "$data_dir"
        success "Removed data directory"
      else
        info "Kept data directory"
      fi
    else
      info "Run ${BOLD}rm -rf ${data_dir}${RESET} to delete relay data"
    fi
  fi

  echo
  success "${BOLD}Uninstall complete${RESET}"
  exit 0
}

# ── Symlink ──────────────────────────────────────────────────────────────────

create_ar_symlink() {
  local bin_path="$1"
  local bin_dir
  bin_dir=$(dirname "$bin_path")
  local ar_path="${bin_dir}/ar"

  # Don't overwrite if 'ar' is something else (e.g. GNU ar archiver)
  if command -v ar &>/dev/null; then
    local existing
    existing=$(command -v ar)
    if [[ "$existing" != "$ar_path" ]]; then
      # ar exists and it's not our symlink — skip
      return 0
    fi
  fi

  ln -sf "$bin_path" "$ar_path" 2>/dev/null || true
}

# ── Step 0: Dependency check ────────────────────────────────────────────────

check_dependencies() {
  step 0 "Checking dependencies"

  local missing_required=()
  local missing_optional=()

  # Required: curl (for downloads + health check)
  if ! command -v curl &>/dev/null; then
    missing_required+=("curl")
  else
    success "curl"
  fi

  # Build deps (optional — fallback to prebuilt if missing)
  if command -v go &>/dev/null; then
    local go_version
    go_version=$(go version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+' | head -1)
    success "go (${go_version})"
  else
    missing_optional+=("go (will download prebuilt binary instead of building from source)")
  fi

  if command -v cc &>/dev/null || command -v gcc &>/dev/null || command -v clang &>/dev/null; then
    success "C compiler"
  elif command -v go &>/dev/null; then
    missing_optional+=("C compiler (cc/gcc/clang — needed for CGO/SQLite, will download prebuilt)")
  fi

  # git (for clone if building from source)
  if command -v git &>/dev/null; then
    success "git"
  else
    missing_optional+=("git (needed for build from source)")
  fi

  # jq — needed for hook scripts
  if command -v jq &>/dev/null; then
    success "jq"
  else
    missing_optional+=("jq (activity hooks use jq to parse JSON — hooks will be installed but won't work without it)")
  fi

  # python3 or jq — for config merging
  if command -v python3 &>/dev/null; then
    success "python3 (for config merging)"
  elif command -v jq &>/dev/null; then
    success "jq (for config merging)"
  else
    missing_optional+=("python3 or jq (for merging .mcp.json — will create new files but can't merge with existing)")
  fi

  # Report
  if [[ ${#missing_required[@]} -gt 0 ]]; then
    echo
    for dep in "${missing_required[@]}"; do
      error "Missing required: ${BOLD}${dep}${RESET}"
    done
    die "Install the missing dependencies and retry."
  fi

  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    echo
    for dep in "${missing_optional[@]}"; do
      warn "Optional: ${dep}"
    done
  fi
}

# ── Step 1: Install binary ──────────────────────────────────────────────────

install_binary() {
  step 1 "Installing binary"

  local bin_path="${BIN_DIR}/${BINARY_NAME}"
  # BIN_DIR is already writable (detect_platform ensures this)

  # Check existing install
  if [[ -f "$bin_path" ]]; then
    local existing_version
    existing_version=$("$bin_path" --version 2>/dev/null || echo "unknown")
    warn "Existing install detected: ${BOLD}${existing_version}${RESET}"
    if [[ -t 0 ]]; then
      read -rp "  Upgrade? [Y/n] " answer
      if [[ "${answer,,}" == "n" ]]; then
        info "Skipping binary install"
        return 0
      fi
    fi
  fi

  # Check write permissions (fallback to ~/.local/bin if needed)
  if [[ ! -w "$BIN_DIR" ]]; then
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    bin_path="${BIN_DIR}/${BINARY_NAME}"
    warn "Using ${BIN_DIR} (no write access to /usr/local/bin)"
  fi

  # Try build from source first
  if try_build_from_source; then
    local tmp_bin="./agent-relay"
    install -m 755 "$tmp_bin" "$bin_path"
    rm -f "$tmp_bin"
    # Create 'ar' shortcut symlink
    create_ar_symlink "$bin_path"
    success "Built and installed from source"
    return 0
  fi

  # Fallback to prebuilt
  info "Downloading prebuilt binary..."
  download_prebuilt "$bin_path"
}

try_build_from_source() {
  if ! command -v go &>/dev/null; then
    info "Go not found, will download prebuilt binary"
    return 1
  fi

  # CGO requires a C compiler
  if ! command -v cc &>/dev/null && ! command -v gcc &>/dev/null; then
    warn "No C compiler found (needed for CGO/SQLite), will download prebuilt"
    return 1
  fi

  info "Go found, building from source..."

  local tmpdir
  tmpdir=$(mktemp -d)

  local ver
  ver=$(target_release)

  # Clone the matching tag when one is available; fall back to default branch
  # when no release exists (fresh fork) or in dev mode.
  local -a clone_args=(--depth 1)
  if [[ "$ver" != "dev" ]] && [[ "$ver" != "main" ]]; then
    clone_args+=(--branch "$ver")
  fi

  spinner_start "Cloning ${ver}"
  if ! git clone "${clone_args[@]}" "https://github.com/${REPO}.git" "$tmpdir/src" &>/dev/null 2>&1; then
    spinner_stop
    warn "Clone failed, will download prebuilt"
    rm -rf "$tmpdir"
    return 1
  fi
  spinner_stop

  local build_output="${PWD}/agent-relay"
  spinner_start "Building binary (this may take a minute)"
  if ! (cd "$tmpdir/src" && CGO_ENABLED=1 go build -tags fts5 -ldflags="-s -w -X main.Version=${ver}" -o "$build_output" . 2>/dev/null); then
    spinner_stop
    warn "Build failed, will download prebuilt"
    rm -rf "$tmpdir"
    return 1
  fi
  spinner_stop

  rm -rf "$tmpdir"
  return 0
}

target_release() {
  # If the installer was stamped at release time, use that exact version so
  # binaries, source, skill, and hooks all match. Otherwise query the API for
  # the latest published release.
  if [[ "$RELAY_VERSION" != "main" ]]; then
    echo "$RELAY_VERSION"
    return 0
  fi
  local version
  version=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
  echo "${version:-dev}"
}

download_prebuilt() {
  local bin_path="$1"
  local version
  version=$(target_release)
  if [[ "$version" == "dev" ]] || [[ "$version" == "main" ]]; then
    die "No releases found and Go not available. Install Go (https://go.dev/dl/) and retry."
  fi

  local archive_name="agent-relay-${OS}-${ARCH}.tar.gz"
  local url="https://github.com/${REPO}/releases/download/${version}/${archive_name}"

  spinner_start "Downloading ${version} for ${OS}/${ARCH}"

  local tmpdir
  tmpdir=$(mktemp -d)

  if ! curl -fsSL "$url" -o "$tmpdir/archive.tar.gz"; then
    spinner_stop
    rm -rf "$tmpdir"
    die "Download failed. Check https://github.com/${REPO}/releases for available builds."
  fi
  spinner_stop

  tar -xzf "$tmpdir/archive.tar.gz" -C "$tmpdir"
  install -m 755 "$tmpdir/agent-relay" "$bin_path"

  rm -rf "$tmpdir"
  # Create 'ar' shortcut symlink
  create_ar_symlink "$bin_path"
  success "Installed ${BOLD}${version}${RESET} from prebuilt"
}

# ── Skill bundle ─────────────────────────────────────────────────────────────
#
# Downloads `skill-relay.tar.gz` from the target release (one HTTP request) and
# extracts it to a temp dir. Both install_hooks and install_skill consume the
# extracted files. On failure (asset missing on an older release, or running in
# dev mode), falls back to per-file raw fetch from RELAY_VERSION.
#
# Result lives in $SKILL_BUNDLE_DIR with this layout:
#   $SKILL_BUNDLE_DIR/SKILL.md
#   $SKILL_BUNDLE_DIR/references/tools-reference.md
#   $SKILL_BUNDLE_DIR/hooks/ingest-*.sh

ensure_skill_bundle() {
  [[ -n "$SKILL_BUNDLE_DIR" ]] && return 0

  SKILL_BUNDLE_DIR=$(mktemp -d)

  # Try the release tarball first.
  local version
  version=$(target_release)
  if [[ "$version" != "dev" ]] && [[ "$version" != "main" ]]; then
    local url="https://github.com/${REPO}/releases/download/${version}/skill-relay.tar.gz"
    if curl -fsSL "$url" -o "$SKILL_BUNDLE_DIR/bundle.tar.gz" 2>/dev/null \
       && tar -xzf "$SKILL_BUNDLE_DIR/bundle.tar.gz" -C "$SKILL_BUNDLE_DIR" 2>/dev/null; then
      rm -f "$SKILL_BUNDLE_DIR/bundle.tar.gz"
      return 0
    fi
    rm -f "$SKILL_BUNDLE_DIR/bundle.tar.gz"
  fi

  # Fallback: per-file raw fetch. Used when the tarball asset is missing on
  # the targeted release (older releases) or in dev mode (RELAY_VERSION=main).
  mkdir -p "$SKILL_BUNDLE_DIR/references" "$SKILL_BUNDLE_DIR/hooks"
  local raw_base="https://raw.githubusercontent.com/${REPO}/${RELAY_VERSION}/skill/relay"
  curl -fsSL "${raw_base}/SKILL.md" \
    -o "$SKILL_BUNDLE_DIR/SKILL.md" 2>/dev/null || true
  curl -fsSL "${raw_base}/references/tools-reference.md" \
    -o "$SKILL_BUNDLE_DIR/references/tools-reference.md" 2>/dev/null || true
  local h
  for h in ingest-pre-tool.sh ingest-post-tool.sh ingest-stop.sh \
           ingest-subagent-start.sh ingest-subagent-stop.sh; do
    curl -fsSL "${raw_base}/hooks/${h}" \
      -o "$SKILL_BUNDLE_DIR/hooks/${h}" 2>/dev/null || true
  done
}

# ── Step 2: Install service ─────────────────────────────────────────────────

install_service() {
  step 2 "Setting up auto-start service"

  if [[ "$NO_SERVICE" == true ]]; then
    info "Skipped (--no-service)"
    return 0
  fi

  if [[ "$OS" == "darwin" ]]; then
    install_launchd_service
  else
    install_systemd_service
  fi
}

install_launchd_service() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="${plist_dir}/${SERVICE_LABEL}.plist"
  local bin_path="${BIN_DIR}/${BINARY_NAME}"

  mkdir -p "$plist_dir"

  # Stop existing service
  if launchctl list "$SERVICE_LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null || true
  fi

  local env_block=""
  if [[ "$PORT" != "$DEFAULT_PORT" ]]; then
    env_block="    <key>EnvironmentVariables</key>
    <dict>
        <key>PORT</key>
        <string>${PORT}</string>
    </dict>"
  fi

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${bin_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/tmp/agent-relay.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/agent-relay.err</string>
${env_block}
</dict>
</plist>
EOF

  launchctl bootstrap "gui/$(id -u)" "$plist_path" 2>/dev/null || \
    launchctl load "$plist_path" 2>/dev/null || true

  success "Installed launchd service (starts on login, restarts on crash)"
}

install_systemd_service() {
  local unit_dir="$HOME/.config/systemd/user"
  local unit_path="${unit_dir}/${BINARY_NAME}.service"
  local bin_path="${BIN_DIR}/${BINARY_NAME}"

  mkdir -p "$unit_dir"

  cat > "$unit_path" <<EOF
[Unit]
Description=Claude Agentic Relay
After=network.target

[Service]
Type=simple
ExecStart=${bin_path}
Restart=on-failure
RestartSec=5
Environment=PORT=${PORT}

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable "$BINARY_NAME" 2>/dev/null || true
  systemctl --user restart "$BINARY_NAME" 2>/dev/null || true

  success "Installed systemd user service (auto-start, restarts on crash)"

  # Check if lingering is enabled (needed for user services without login)
  if command -v loginctl &>/dev/null && ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "yes"; then
    warn "Tip: Run ${BOLD}loginctl enable-linger${RESET} to keep the service running after logout"
  fi
}

# ── Step 3: Install hooks ──────────────────────────────────────────────────

install_hooks() {
  step 3 "Installing activity tracking hooks"

  local hooks_dir="$HOME/.claude/hooks"
  local settings_file="$HOME/.claude/settings.json"
  mkdir -p "$hooks_dir"

  ensure_skill_bundle

  # Claude Code hook event → script filename
  local hooks_map=(
    "PreToolUse:ingest-pre-tool.sh"
    "PostToolUse:ingest-post-tool.sh"
    "Stop:ingest-stop.sh"
    "SubagentStart:ingest-subagent-start.sh"
    "SubagentStop:ingest-subagent-stop.sh"
  )

  local installed_scripts=()
  local missing_scripts=()
  for entry in "${hooks_map[@]}"; do
    local script="${entry#*:}"
    local src="${SKILL_BUNDLE_DIR}/hooks/${script}"
    local dest="${hooks_dir}/${script}"
    if [[ -f "$src" ]]; then
      install -m 755 "$src" "$dest"
      installed_scripts+=("$script")
    else
      missing_scripts+=("$script")
    fi
  done

  if [[ ${#installed_scripts[@]} -eq 0 ]]; then
    warn "No hooks found in skill bundle (${SKILL_BUNDLE_DIR})"
    warn "Activity tracking will not work"
    return 0
  fi

  if [[ ${#missing_scripts[@]} -gt 0 ]]; then
    warn "Some hooks missing from bundle: ${missing_scripts[*]}"
  fi

  # Backup settings.json before merging
  if [[ -f "$settings_file" ]]; then
    cp "$settings_file" "${settings_file}.bak" 2>/dev/null || true
  fi

  if ! command -v python3 &>/dev/null; then
    warn "Hook auto-config requires python3 — add hooks manually to ${BOLD}${settings_file}${RESET}"
    return 0
  fi

  # Build Python list of (event, command) for installed hooks only
  local py_entries=""
  for entry in "${hooks_map[@]}"; do
    local event="${entry%%:*}"
    local script="${entry#*:}"
    local installed=false
    local s
    for s in "${installed_scripts[@]}"; do
      [[ "$s" == "$script" ]] && installed=true && break
    done
    [[ "$installed" == true ]] || continue
    py_entries+="    ('${event}', '${hooks_dir}/${script}'),"$'\n'
  done

  python3 -c "
import json, os

path = os.path.expanduser('$settings_file')
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)

hooks = data.setdefault('hooks', {})

entries = [
${py_entries}]

for event, hook_cmd in entries:
    event_hooks = hooks.setdefault(event, [])
    already = any(
        h.get('hooks', [{}])[0].get('command', '') == hook_cmd
        if isinstance(h, dict) else False
        for h in event_hooks
    )
    if not already:
        event_hooks.append({
            'hooks': [{'type': 'command', 'command': hook_cmd, 'timeout': 5}]
        })

with open(path, 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
" 2>/dev/null

  success "Installed activity hooks (${#installed_scripts[@]} of ${#hooks_map[@]})"
}

# ── Step 4: Install skill ───────────────────────────────────────────────────

install_skill() {
  step 4 "Installing /relay skill"

  local skill_dir="$HOME/.claude/skills/relay"
  local refs_dir="${skill_dir}/references"
  mkdir -p "$refs_dir"

  # Migrate from legacy command location.
  local legacy_cmd="$HOME/.claude/commands/relay.md"
  if [[ -f "$legacy_cmd" ]]; then
    rm -f "$legacy_cmd"
    info "Removed legacy ${DIM}${legacy_cmd}${RESET}"
  fi

  ensure_skill_bundle

  local skill_ok=false
  if [[ -f "$SKILL_BUNDLE_DIR/SKILL.md" ]]; then
    install -m 644 "$SKILL_BUNDLE_DIR/SKILL.md" "${skill_dir}/SKILL.md"
    skill_ok=true
  fi

  local refs_ok=false
  if [[ -f "$SKILL_BUNDLE_DIR/references/tools-reference.md" ]]; then
    install -m 644 "$SKILL_BUNDLE_DIR/references/tools-reference.md" "${refs_dir}/tools-reference.md"
    refs_ok=true
  fi

  if [[ "$skill_ok" == false ]]; then
    warn "SKILL.md missing from bundle — relay skill will be incomplete"
  fi
  if [[ "$refs_ok" == false ]]; then
    warn "tools-reference.md missing from bundle — skill reference unavailable"
  fi

  if [[ "$skill_ok" == true ]] || [[ "$refs_ok" == true ]]; then
    success "Installed /relay skill at ${DIM}${skill_dir}${RESET}"
  fi
}

# ── Step 5: Scan and configure projects ──────────────────────────────────────

scan_and_configure_projects() {
  step 5 "Scanning for Claude Code projects"

  if [[ "$SKIP_PROJECTS" == true ]]; then
    info "Skipped (--skip-projects)"
    return 0
  fi

  info "Looking for projects with ${BOLD}.mcp.json${RESET} or ${BOLD}CLAUDE.md${RESET}..."

  local -a projects=()
  local -a project_names=()

  # Scan home directory (depth 2) for Claude Code projects
  while IFS= read -r -d '' dir; do
    local project_dir
    project_dir=$(dirname "$dir")
    # Deduplicate
    local already=false
    for p in "${projects[@]+"${projects[@]}"}"; do
      if [[ "$p" == "$project_dir" ]]; then
        already=true
        break
      fi
    done
    if [[ "$already" == false ]]; then
      projects+=("$project_dir")
    fi
  done < <(find "$HOME" -maxdepth 3 \( -name "CLAUDE.md" -o -name ".mcp.json" \) -print0 2>/dev/null | tr '\0' '\n' | head -100 | tr '\n' '\0')

  # Filter out non-project directories
  local -a valid_projects=()
  for p in "${projects[@]+"${projects[@]}"}"; do
    # Skip hidden dirs, node_modules, etc.
    local basename
    basename=$(basename "$p")
    case "$basename" in
      .*|node_modules|vendor|.git) continue ;;
    esac
    # Skip the relay's own directory
    if [[ "$p" == *"claude-agentic-relay"* ]] || [[ "$p" == *"agent-relay"* ]]; then
      continue
    fi
    valid_projects+=("$p")
  done

  if [[ ${#valid_projects[@]} -eq 0 ]]; then
    info "No Claude Code projects found"
    info "You can manually add relay to any project's ${BOLD}.mcp.json${RESET} later:"
    echo
    echo "  ${DIM}{\"mcpServers\": {\"agent-relay\": {\"type\": \"http\", \"url\": \"http://localhost:${PORT}/mcp\"}}}${RESET}"
    return 0
  fi

  echo
  info "Found ${BOLD}${#valid_projects[@]}${RESET} project(s):"
  echo

  local i=1
  for p in "${valid_projects[@]}"; do
    local name
    name=$(detect_agent_name "$(basename "$p")")
    project_names+=("$name")

    local has_relay=""
    if [[ -f "$p/.mcp.json" ]] && grep -q "agent-relay" "$p/.mcp.json" 2>/dev/null; then
      has_relay=" ${GREEN}(already configured)${RESET}"
    fi

    printf "  ${BOLD}%2d)${RESET} %-40s → agent: ${CYAN}%s${RESET}%s\n" "$i" "${p/#$HOME/~}" "$name" "$has_relay"
    ((i++))
  done

  echo
  if [[ ! -t 0 ]]; then
    info "Non-interactive mode — skipping project configuration"
    info "Run the installer interactively to configure projects"
    return 0
  fi

  read -rp "  Configure which projects? (${BOLD}a${RESET}ll / comma-separated numbers / ${BOLD}n${RESET}one) " choice

  case "${choice,,}" in
    n|none) info "Skipped project configuration"; return 0 ;;
    a|all|"") ;;
    *)
      local -a selected=()
      IFS=',' read -ra nums <<< "$choice"
      for num in "${nums[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#valid_projects[@]} )); then
          selected+=("$((num - 1))")
        fi
      done
      if [[ ${#selected[@]} -eq 0 ]]; then
        warn "No valid selections"
        return 0
      fi
      local -a filtered_projects=()
      local -a filtered_names=()
      for idx in "${selected[@]}"; do
        filtered_projects+=("${valid_projects[$idx]}")
        filtered_names+=("${project_names[$idx]}")
      done
      valid_projects=("${filtered_projects[@]}")
      project_names=("${filtered_names[@]}")
      ;;
  esac

  echo
  for i in "${!valid_projects[@]}"; do
    configure_project "${valid_projects[$i]}" "${project_names[$i]}"
  done
}

detect_agent_name() {
  local dirname="$1"
  local lower
  lower=$(echo "$dirname" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    *api*|*backend*|*server*)         echo "backend" ;;
    *front*|*web*|*dashboard*|*ui*)   echo "frontend" ;;
    *infra*|*deploy*|*ops*|*devops*)  echo "infra" ;;
    *mobile*|*ios*|*android*|*app*)   echo "mobile" ;;
    *docs*|*doc*|*wiki*)              echo "docs" ;;
    *test*|*qa*|*e2e*)                echo "qa" ;;
    *)
      # Sanitize: lowercase, replace non-alphanumeric with -, trim dashes
      echo "$dirname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
      ;;
  esac
}

configure_project() {
  local project_dir="$1"
  local agent_name="$2"
  local mcp_path="${project_dir}/.mcp.json"

  local project_name
  project_name=$(echo "$(basename "$project_dir")" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
  local relay_entry="{\"type\":\"http\",\"url\":\"http://localhost:${PORT}/mcp\"}"

  if [[ -f "$mcp_path" ]]; then
    # Check if already configured
    if grep -q "agent-relay" "$mcp_path" 2>/dev/null; then
      success "${project_dir/#$HOME/~} — already configured"
      return 0
    fi

    # Backup before merging
    cp "$mcp_path" "${mcp_path}.bak" 2>/dev/null || true

    # Merge into existing .mcp.json using python3 or jq
    if command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
with open('$mcp_path', 'r') as f:
    data = json.load(f)
data.setdefault('mcpServers', {})
data['mcpServers']['agent-relay'] = json.loads('$relay_entry')
with open('$mcp_path', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" 2>/dev/null
    elif command -v jq &>/dev/null; then
      local tmp
      tmp=$(mktemp)
      jq --argjson entry "$relay_entry" '.mcpServers["agent-relay"] = $entry' "$mcp_path" > "$tmp" && mv "$tmp" "$mcp_path"
    else
      warn "No python3 or jq found — cannot safely merge .mcp.json"
      warn "Manually add agent-relay to ${mcp_path}"
      return 1
    fi
  else
    # Create new .mcp.json
    cat > "$mcp_path" <<EOF
{
  "mcpServers": {
    "agent-relay": ${relay_entry}
  }
}
EOF
  fi

  # Add relay hint to CLAUDE.md if not already present
  local claude_md="${project_dir}/CLAUDE.md"
  local relay_marker="<!-- agent-relay -->"
  if [[ -f "$claude_md" ]]; then
    if ! grep -q "$relay_marker" "$claude_md" 2>/dev/null; then
      cat >> "$claude_md" <<RELAYEOF

$relay_marker
## Agent Relay

This project uses [Agent Relay](https://github.com/Synergix-lab/WRAI.TH) for multi-agent coordination.

- Use \`/relay\` to check inbox, send messages, dispatch tasks, and run autonomous work loops
- Use \`/relay create_project\` to set up the full colony (teams, goals, profiles, sprint tasks)
- Full docs: \`skill/relay/SKILL.md\` (skill reference) and \`docs/\` (guides)
RELAYEOF
    fi
  fi

  success "${project_dir/#$HOME/~} → ${CYAN}${agent_name}${RESET}"
}

# ── Step 5: Verify installation ─────────────────────────────────────────────

verify_installation() {
  step 6 "Verifying installation"

  local bin_path="${BIN_DIR}/${BINARY_NAME}"

  # Check binary
  if [[ ! -x "$bin_path" ]]; then
    error "Binary not found at ${bin_path}"
    return 1
  fi

  local version
  version=$("$bin_path" --version 2>/dev/null || echo "unknown")
  success "Binary: ${BOLD}${version}${RESET}"

  # Check ar symlink
  local ar_path="${BIN_DIR}/ar"
  if [[ -L "$ar_path" ]]; then
    success "Shortcut: ${BOLD}ar${RESET} → agent-relay"
  fi

  # Check hooks
  local hooks_dir="$HOME/.claude/hooks"
  local expected_hooks=(
    "ingest-pre-tool.sh"
    "ingest-post-tool.sh"
    "ingest-stop.sh"
    "ingest-subagent-start.sh"
    "ingest-subagent-stop.sh"
  )
  local hooks_found=0
  for h in "${expected_hooks[@]}"; do
    [[ -x "${hooks_dir}/${h}" ]] && ((hooks_found++))
  done
  if [[ $hooks_found -eq ${#expected_hooks[@]} ]]; then
    success "Hooks: activity tracking installed (${hooks_found}/${#expected_hooks[@]})"
  elif [[ $hooks_found -gt 0 ]]; then
    warn "Hooks: partial install (${hooks_found}/${#expected_hooks[@]})"
  else
    warn "Hooks: activity tracking not found"
  fi

  # Check skill
  if [[ -f "$HOME/.claude/skills/relay/SKILL.md" ]]; then
    success "Skill: /relay installed"
  else
    warn "Skill: not found"
  fi

  # Check port availability and service status
  if [[ "$NO_SERVICE" != true ]]; then
    # Wait a moment for the service to start
    sleep 1

    local health_ok=false
    for attempt in 1 2 3; do
      if curl -sf "http://localhost:${PORT}/health" &>/dev/null || \
         curl -sf "http://localhost:${PORT}/mcp" &>/dev/null; then
        health_ok=true
        break
      fi
      sleep 1
    done

    if [[ "$health_ok" == true ]]; then
      success "Service: relay running on port ${PORT}"
    else
      warn "Service: relay not responding yet (may need a moment to start)"
      info "Check logs: ${DIM}cat /tmp/agent-relay.log${RESET}"
    fi
  fi

  # Check PATH
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo
    warn "${BIN_DIR} is not in your PATH"
    info "Add to your shell profile:"
    if [[ "$OS" == "darwin" ]]; then
      echo "  ${DIM}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc${RESET}"
    else
      echo "  ${DIM}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc${RESET}"
    fi
  fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  echo
  echo "${GREEN}${BOLD}  ╔═══════════════════════════════════════╗${RESET}"
  echo "${GREEN}${BOLD}  ║      Installation complete!            ║${RESET}"
  echo "${GREEN}${BOLD}  ╚═══════════════════════════════════════╝${RESET}"
  echo
  info "The relay is running on ${BOLD}http://localhost:${PORT}${RESET}"
  echo
  info "Next steps:"
  echo "  1. Open Claude Code in any configured project"
  echo "  2. Use ${BOLD}/relay${RESET} to check your inbox"
  echo "  3. Use ${BOLD}/relay send <agent> <message>${RESET} to talk to another agent"
  echo
  info "CLI shortcut: ${BOLD}ar serve${RESET}, ${BOLD}ar status${RESET}, ${BOLD}ar agents${RESET} (alias for agent-relay)"
  echo
  info "Add relay to more projects by adding to ${BOLD}.mcp.json${RESET}:"
  echo "  ${DIM}{\"mcpServers\": {\"agent-relay\": {\"type\": \"http\", \"url\": \"http://localhost:${PORT}/mcp\"}}}${RESET}"
  echo
  info "Uninstall: ${DIM}curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --uninstall${RESET}"
  echo
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  detect_platform

  if [[ "$UNINSTALL" == true ]]; then
    do_uninstall
  fi

  banner
  check_dependencies

  # Check port conflict
  if lsof -i ":${PORT}" &>/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    local existing_pid
    existing_pid=$(lsof -t -i ":${PORT}" -sTCP:LISTEN 2>/dev/null | head -1 || \
                   lsof -t -i ":${PORT}" 2>/dev/null | head -1 || true)
    if [[ -n "$existing_pid" ]]; then
      local existing_cmd
      existing_cmd=$(ps -p "$existing_pid" -o args= 2>/dev/null | head -1 || echo "unknown")
      if [[ "$existing_cmd" == *"agent-relay"* ]]; then
        info "Relay already running on port ${PORT} (PID ${existing_pid})"
      else
        warn "Port ${PORT} is in use by ${BOLD}${existing_cmd}${RESET} (PID ${existing_pid})"
        warn "Use ${BOLD}--port <number>${RESET} to pick a different port"
      fi
    fi
  fi

  install_binary || warn "Binary install incomplete — see above"
  install_service
  install_hooks
  install_skill
  scan_and_configure_projects
  verify_installation || true
  print_summary
}

main "$@"
