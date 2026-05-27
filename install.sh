#!/usr/bin/env bash
set -euo pipefail

# Claude Agentic Relay — Installer bootstrapper
#
# Resolves the target release version, downloads its bundled installer, and
# executes it with all forwarded arguments. This keeps the installation
# pipeline aligned with the binary version being installed: the installer
# that runs is always the one shipped alongside that release's binary.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Chinouchi/WRAI.TH/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --version v0.7.0
#   curl -fsSL ... | bash -s -- --port 9000 --skip-projects
#
# Options handled here:
#   --version <tag>   Install a specific release (e.g. v0.7.0). Default: latest.
#   --help            Show this help.
#
# All other arguments are forwarded to the release's installer.

REPO="Chinouchi/WRAI.TH"
API_BASE="https://api.github.com/repos/${REPO}"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"

# ── Colors ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
else
  BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE=""
fi

info()    { echo "${BLUE}${BOLD}::${RESET} $*"; }
success() { echo "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo "${YELLOW}${BOLD}!${RESET} $*"; }
error()   { echo "${RED}${BOLD}✗${RESET} $*" >&2; }
die()     { error "$@"; exit 1; }

usage() {
  cat <<EOF
${BOLD}Claude Agentic Relay — Installer bootstrapper${RESET}

${BOLD}USAGE:${RESET}
    install.sh [--version <tag>] [installer options...]

${BOLD}BOOTSTRAPPER OPTIONS:${RESET}
    --version <tag>     Install a specific release (e.g. v0.7.0).
                        Default: latest release on ${REPO}.
    --help              Show this help (bootstrapper only).

${BOLD}INSTALLER OPTIONS (forwarded to the resolved installer):${RESET}
    See: ${DIM}install.sh --version <tag> -- --help${RESET}

${BOLD}EXAMPLES:${RESET}
    # Install the latest release:
    curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash

    # Install a specific version:
    curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh \\
        | bash -s -- --version v0.7.0

    # Install latest, on a custom port, without auto-start service:
    curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh \\
        | bash -s -- --port 9000 --no-service
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────────

VERSION=""
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then die "--version requires a tag (e.g. --version v0.7.0)"; fi
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      PASSTHROUGH+=("$1")
      shift
      ;;
  esac
done

# ── Dependency check ─────────────────────────────────────────────────────────

if ! command -v curl &>/dev/null; then
  die "curl is required but not installed."
fi

# ── Resolve version ──────────────────────────────────────────────────────────

if [[ -z "$VERSION" ]]; then
  info "Resolving latest release for ${BOLD}${REPO}${RESET}..."
  LATEST_JSON=$(curl -fsSL "${API_BASE}/releases/latest" 2>/dev/null) || \
    die "Could not fetch latest release from ${API_BASE}/releases/latest
       (Has the fork published any release yet? Visit https://github.com/${REPO}/releases.)"

  VERSION=$(echo "$LATEST_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
  if [[ -z "$VERSION" ]]; then
    die "Could not parse tag_name from GitHub API response."
  fi
  success "Latest: ${BOLD}${VERSION}${RESET}"
else
  info "Target version: ${BOLD}${VERSION}${RESET}"

  # Verify the requested release exists.
  if ! curl -fsSL -o /dev/null "${API_BASE}/releases/tags/${VERSION}" 2>/dev/null; then
    die "Release ${VERSION} not found on ${REPO}.
       Available releases: https://github.com/${REPO}/releases"
  fi
  success "Release found"
fi

# ── Download release installer ───────────────────────────────────────────────

INSTALLER_URL="${DOWNLOAD_BASE}/${VERSION}/install.sh"
TMP_INSTALLER=$(mktemp)
trap 'rm -f "$TMP_INSTALLER"' EXIT

info "Downloading installer for ${VERSION}..."
if ! curl -fsSL "$INSTALLER_URL" -o "$TMP_INSTALLER"; then
  die "Failed to download installer asset from:
       ${INSTALLER_URL}
       The release exists but its install.sh asset is missing. This usually
       means the release workflow did not upload it — check the Actions logs."
fi

if [[ ! -s "$TMP_INSTALLER" ]]; then
  die "Downloaded installer is empty: ${INSTALLER_URL}"
fi

chmod +x "$TMP_INSTALLER"

# ── Hand off to the resolved installer ───────────────────────────────────────

info "Running installer ${BOLD}${VERSION}${RESET}..."
echo

exec bash "$TMP_INSTALLER" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
