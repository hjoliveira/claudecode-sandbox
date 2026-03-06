#!/usr/bin/env bash
#
# sandbox.sh — Run Claude Code in a Docker-based sandbox.
#
# Works on any OS with Docker installed. Does NOT require root on the host.
#
# Usage:
#   ./sandbox.sh --dir /path/to/project --domains "api.anthropic.com,github.com" [-- claude args...]
#
set -euo pipefail

IMAGE_NAME="claude-sandbox"
ALLOWED_DIR=""
ALLOWED_DOMAINS=""
DNS_SERVER="${DNS_SERVER:-8.8.8.8}"
VERBOSE="${VERBOSE:-0}"
CLAUDE_ARGS=()

usage() {
    cat <<'USAGE'
Usage: ./sandbox.sh [OPTIONS] [-- claude-code-args...]

Options:
  --dir DIR           Directory to expose to Claude Code (required)
  --domains LIST      Comma-separated list of allowed domains (required)
  --dns-server IP     DNS server for resolving domains (default: 8.8.8.8)
  --verbose           Enable verbose logging
  --build             Force rebuild the Docker image
  -h, --help          Show this help message

Environment:
  ANTHROPIC_API_KEY   API key (optional; omit to log in interactively)

Examples:
  ./sandbox.sh --dir ./my-project --domains "api.anthropic.com"
  ./sandbox.sh --dir /home/user/code --domains "api.anthropic.com,github.com" -- --model sonnet
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
        --build)      FORCE_BUILD=1; shift ;;
        -h|--help)    usage ;;
        --)           shift; CLAUDE_ARGS=("$@"); break ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$ALLOWED_DIR" || -z "$ALLOWED_DOMAINS" ]]; then
    echo "Error: --dir and --domains are required."
    usage
fi

API_KEY_ENV=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    API_KEY_ENV=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$FORCE_BUILD" == "1" ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building Docker image '$IMAGE_NAME'..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Run the sandbox container
# ---------------------------------------------------------------------------
exec docker run --rm -it \
    --cap-add=NET_ADMIN \
    --cap-drop=ALL \
    --security-opt no-new-privileges:false \
    ${API_KEY_ENV[@]+"${API_KEY_ENV[@]}"} \
    -e "ALLOWED_DOMAINS=$ALLOWED_DOMAINS" \
    -e "DNS_SERVER=$DNS_SERVER" \
    -e "VERBOSE=$VERBOSE" \
    -v "$ALLOWED_DIR:/home/sandbox/project" \
    --tmpfs /tmp:size=512M \
    "$IMAGE_NAME" \
    ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
