#!/usr/bin/env bash
#
# sandbox.sh — Run Claude Code CLI in a sandboxed environment with:
#   1. Filesystem access restricted to a single directory
#   2. Network access restricted to a whitelist of domains
#
# Usage:
#   sudo ./sandbox.sh --dir /path/to/project --domains "api.anthropic.com,github.com" [-- claude args...]
#
# Requirements: Linux with unshare, iptables, mount, and dig (dnsutils) installed.
#               Must be run as root (or with CAP_SYS_ADMIN + CAP_NET_ADMIN).

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults & argument parsing
# ---------------------------------------------------------------------------
ALLOWED_DIR=""
ALLOWED_DOMAINS=""
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_ARGS=()
DNS_SERVER="${DNS_SERVER:-8.8.8.8}"
VERBOSE="${VERBOSE:-0}"

usage() {
    cat <<'USAGE'
Usage: sudo ./sandbox.sh [OPTIONS] [-- claude-code-args...]

Options:
  --dir DIR           Directory to expose to Claude Code (required)
  --domains LIST      Comma-separated list of allowed domains (required)
  --claude-bin PATH   Path to claude binary (default: "claude" from PATH)
  --dns-server IP     DNS server for resolving domains (default: 8.8.8.8)
  --verbose           Enable verbose logging
  -h, --help          Show this help message

Examples:
  sudo ./sandbox.sh --dir ./my-project --domains "api.anthropic.com,github.com"
  sudo ./sandbox.sh --dir /home/user/code --domains "api.anthropic.com" -- --model sonnet
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)       ALLOWED_DIR="$2"; shift 2 ;;
        --domains)   ALLOWED_DOMAINS="$2"; shift 2 ;;
        --claude-bin) CLAUDE_BIN="$2"; shift 2 ;;
        --dns-server) DNS_SERVER="$2"; shift 2 ;;
        --verbose)   VERBOSE=1; shift ;;
        -h|--help)   usage ;;
        --)          shift; CLAUDE_ARGS=("$@"); break ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$ALLOWED_DIR" || -z "$ALLOWED_DOMAINS" ]]; then
    echo "Error: --dir and --domains are required."
    usage
fi

ALLOWED_DIR="$(realpath "$ALLOWED_DIR")"

if [[ ! -d "$ALLOWED_DIR" ]]; then
    echo "Error: Directory does not exist: $ALLOWED_DIR"
    exit 1
fi

log() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo "[sandbox] $*" >&2
    fi
}

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is required but not found. Install it and retry."
        exit 1
    fi
}

check_command unshare
check_command mount
check_command iptables
check_command dig

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (or via sudo)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve whitelisted domains to IPs
# ---------------------------------------------------------------------------
IFS=',' read -ra DOMAIN_LIST <<< "$ALLOWED_DOMAINS"
declare -a ALLOWED_IPS=()

for domain in "${DOMAIN_LIST[@]}"; do
    domain="$(echo "$domain" | xargs)"  # trim whitespace
    log "Resolving $domain..."
    ips="$(dig +short "$domain" @"$DNS_SERVER" A 2>/dev/null | grep -E '^[0-9]+\.' || true)"
    ips6="$(dig +short "$domain" @"$DNS_SERVER" AAAA 2>/dev/null | grep -E '^[0-9a-f]+:' || true)"

    if [[ -z "$ips" && -z "$ips6" ]]; then
        echo "Warning: Could not resolve $domain — no IPs found."
    fi

    for ip in $ips $ips6; do
        log "  -> $ip"
        ALLOWED_IPS+=("$ip")
    done
done

if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
    echo "Error: No IPs resolved from the domain whitelist. Check your domains and DNS."
    exit 1
fi

# Also allow DNS resolution itself
ALLOWED_IPS+=("$DNS_SERVER")

log "Allowed IPs: ${ALLOWED_IPS[*]}"

# ---------------------------------------------------------------------------
# Create the inner script that runs inside the namespace
# ---------------------------------------------------------------------------
INNER_SCRIPT="$(mktemp /tmp/sandbox-inner.XXXXXX.sh)"
chmod +x "$INNER_SCRIPT"

cat > "$INNER_SCRIPT" <<INNEREOF
#!/usr/bin/env bash
set -euo pipefail

VERBOSE="$VERBOSE"
log() {
    if [[ "\$VERBOSE" == "1" ]]; then
        echo "[sandbox-inner] \$*" >&2
    fi
}

# ---- Filesystem: create a minimal root and bind-mount essentials ----------
SANDBOX_ROOT="\$(mktemp -d /tmp/sandbox-root.XXXXXX)"
log "Setting up filesystem overlay at \$SANDBOX_ROOT"

mkdir -p "\$SANDBOX_ROOT"/{usr,lib,lib64,bin,sbin,etc,tmp,proc,sys,dev,run,var,home/sandbox/project}

# Bind-mount read-only system paths
for syspath in /usr /lib /lib64 /bin /sbin /etc /run; do
    if [[ -d "\$syspath" ]]; then
        mount --rbind "\$syspath" "\$SANDBOX_ROOT\$syspath"
        mount --make-rslave "\$SANDBOX_ROOT\$syspath"
    fi
done

# Mount special filesystems
mount -t proc proc "\$SANDBOX_ROOT/proc"
mount -t sysfs sysfs "\$SANDBOX_ROOT/sys"
mount -t devtmpfs devtmpfs "\$SANDBOX_ROOT/dev" 2>/dev/null || mount --rbind /dev "\$SANDBOX_ROOT/dev"
mount -t tmpfs tmpfs "\$SANDBOX_ROOT/tmp"

# Bind-mount the allowed project directory (read-write)
mount --bind "$ALLOWED_DIR" "\$SANDBOX_ROOT/home/sandbox/project"
log "Mounted $ALLOWED_DIR -> /home/sandbox/project"

# ---- Network: configure iptables in this network namespace ----------------
log "Setting up network rules"

# Bring up loopback
ip link set lo up

# Create a virtual ethernet pair for external connectivity
# (if running inside a network namespace, we need a veth pair or slirp)
# For simplicity, we set up iptables OUTPUT filtering in the host netns
# by using the --net flag at the unshare level.

# Flush and set default policies
iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT DROP

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS (UDP 53) to the configured DNS server
iptables -A OUTPUT -p udp --dport 53 -d $DNS_SERVER -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d $DNS_SERVER -j ACCEPT

# Allow established/related connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow traffic to each whitelisted IP
$(for ip in "${ALLOWED_IPS[@]}"; do
    echo "iptables -A OUTPUT -d $ip -j ACCEPT"
done)

iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable

log "Network rules applied. Allowed IPs: ${ALLOWED_IPS[*]}"

# ---- Pivot root into the sandbox -----------------------------------------
log "Pivoting into sandbox filesystem"
cd "\$SANDBOX_ROOT"
mkdir -p "\$SANDBOX_ROOT/.old-root"
pivot_root "\$SANDBOX_ROOT" "\$SANDBOX_ROOT/.old-root"

# Unmount old root
umount -l /.old-root 2>/dev/null || true
rmdir /.old-root 2>/dev/null || true

cd /home/sandbox/project

# ---- Launch Claude Code ---------------------------------------------------
log "Launching Claude Code"
exec "$CLAUDE_BIN" ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
INNEREOF

# ---------------------------------------------------------------------------
# Launch the sandboxed environment
# ---------------------------------------------------------------------------
log "Launching sandbox with unshare (mount + network + PID namespaces)"

# unshare creates new namespaces:
#   --mount  : isolated filesystem mounts
#   --net    : isolated network stack (iptables rules only apply here)
#   --pid    : isolated process ID space
#   --fork   : fork before exec (required for --pid)
#   --mount-proc : mount a new /proc for the PID namespace
exec unshare \
    --mount \
    --net \
    --pid \
    --fork \
    "$INNER_SCRIPT"
