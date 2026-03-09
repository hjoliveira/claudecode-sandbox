#!/usr/bin/env bash
#
# sandbox.sh — Run Claude Code in a Docker-based sandbox.
#
# Works on any OS with Docker installed. Does NOT require root on the host.
#
# Usage:
#   ./sandbox.sh --dir /path/to/project [--domains "github.com,..."] [-- claude args...]
#
set -euo pipefail

IMAGE_NAME="claude-sandbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load default domains from config file (one per line, ignoring comments)
DEFAULT_DOMAINS_FILE="$SCRIPT_DIR/default-domains.conf"
if [[ -f "$DEFAULT_DOMAINS_FILE" ]]; then
    DEFAULT_DOMAINS=$(grep -v '^#' "$DEFAULT_DOMAINS_FILE" | grep -v '^$' | paste -sd ',' -)
else
    DEFAULT_DOMAINS="api.anthropic.com,claude.ai,platform.claude.com,statsig.anthropic.com,console.anthropic.com,auth.anthropic.com"
fi
ALLOWED_DIR=""
ALLOWED_DOMAINS=""
DNS_SERVER="${DNS_SERVER:-8.8.8.8}"
VERBOSE="${VERBOSE:-0}"
TMPFS_SIZE="512M"
CLAUDE_ARGS=()

usage() {
    cat <<'USAGE'
Usage: ./sandbox.sh [OPTIONS] [-- claude-code-args...]

Options:
  --dir DIR           Directory to expose to Claude Code (required)
  --domains LIST      Additional comma-separated allowed domains or IP addresses (optional)
  --dns-server IP     DNS server for resolving domains (default: 8.8.8.8)
  --verbose           Enable verbose logging
  --tmpfs-size SIZE   Size of /tmp tmpfs mount (default: 512M)
  --build             Force rebuild the Docker image
  -h, --help          Show this help message

Environment:
  ANTHROPIC_API_KEY     API key (optional; omit to log in interactively)
  ANTHROPIC_AUTH_TOKEN  Auth token (optional; alternative to API key)
  ANTHROPIC_BASE_URL   Base URL for the Anthropic API (optional)

Default domains (always included):
  api.anthropic.com, claude.ai, platform.claude.com, statsig.anthropic.com,
  console.anthropic.com, auth.anthropic.com

Examples:
  ./sandbox.sh --dir ./my-project
  ./sandbox.sh --dir /home/user/code --domains "github.com,api.github.com" -- --model sonnet
  ./sandbox.sh --dir ./my-project --domains "192.168.1.100,10.0.0.1"
USAGE
    exit 0
}

FORCE_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)        ALLOWED_DIR="$2"; shift 2 ;;
        --domains)    ALLOWED_DOMAINS="$2"; shift 2 ;;
        --dns-server) DNS_SERVER="$2"; shift 2 ;;
        --verbose)    VERBOSE=1; shift ;;
        --tmpfs-size) TMPFS_SIZE="$2"; shift 2 ;;
        --build)      FORCE_BUILD=1; shift ;;
        -h|--help)    usage ;;
        --)           shift; CLAUDE_ARGS=("$@"); break ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$ALLOWED_DIR" ]]; then
    echo "Error: --dir is required."
    usage
fi

# Merge default Anthropic domains with user-supplied domains
if [[ -n "$ALLOWED_DOMAINS" ]]; then
    ALLOWED_DOMAINS="${DEFAULT_DOMAINS},${ALLOWED_DOMAINS}"
else
    ALLOWED_DOMAINS="$DEFAULT_DOMAINS"
fi

ANTHROPIC_ENV=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ANTHROPIC_ENV+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi
if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    ANTHROPIC_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_AUTH_TOKEN")
fi
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    ANTHROPIC_ENV+=(-e "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
fi

# Resolve to absolute path (works on macOS and Linux)
ALLOWED_DIR="$(cd "$ALLOWED_DIR" && pwd)"

if [[ ! -d "$ALLOWED_DIR" ]]; then
    echo "Error: Directory does not exist: $ALLOWED_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build image if needed
# ---------------------------------------------------------------------------
if [[ "$FORCE_BUILD" == "1" ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building Docker image '$IMAGE_NAME'..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Persist container Claude config across runs
# ---------------------------------------------------------------------------
SANDBOX_CONFIG="${HOME}/.claudecode-sandbox"
mkdir -p "$SANDBOX_CONFIG/claude" "$SANDBOX_CONFIG/claude-json"

# ---------------------------------------------------------------------------
# Run the sandbox container
# ---------------------------------------------------------------------------
exec docker run --rm -it \
    --cap-drop=ALL \
    --cap-add=NET_ADMIN \
    --cap-add=SETUID \
    --cap-add=SETGID \
    --cap-add=CHOWN \
    --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER \
    --cap-add=AUDIT_WRITE \
    ${ANTHROPIC_ENV[@]+"${ANTHROPIC_ENV[@]}"} \
    -e "ALLOWED_DOMAINS=$ALLOWED_DOMAINS" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    --dns "$DNS_SERVER" \
    -e "DNS_SERVER=$DNS_SERVER" \
    -e "VERBOSE=$VERBOSE" \
    -v "$SANDBOX_CONFIG/claude:/home/sandbox/.claude" \
    -v "$SANDBOX_CONFIG/claude-json:/home/sandbox/.claude-json" \
    -v "$ALLOWED_DIR:/home/sandbox/project" \
    --tmpfs "/tmp:size=$TMPFS_SIZE" \
    "$IMAGE_NAME" \
    ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
