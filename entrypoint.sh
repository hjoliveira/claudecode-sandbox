#!/usr/bin/env bash
#
# entrypoint.sh — Docker entrypoint for Claude Code sandbox.
#
# Resolves ALLOWED_DOMAINS to IPs, sets up iptables egress rules,
# then drops privileges and runs Claude Code.
#
set -euo pipefail

ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-}"
DNS_SERVER="${DNS_SERVER:-8.8.8.8}"
VERBOSE="${VERBOSE:-0}"

log() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo "[sandbox] $*" >&2
    fi
}


# ---------------------------------------------------------------------------
# Match sandbox user UID/GID to host user so bind-mounted files are accessible
# ---------------------------------------------------------------------------
HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"

if [[ -n "$HOST_UID" && "$HOST_UID" != "$(id -u sandbox)" ]]; then
    usermod -u "$HOST_UID" sandbox 2>/dev/null || true
    log "Set sandbox UID to $HOST_UID"
fi
if [[ -n "$HOST_GID" && "$HOST_GID" != "$(id -g sandbox)" ]]; then
    groupmod -g "$HOST_GID" sandbox 2>/dev/null || true
    log "Set sandbox GID to $HOST_GID"
fi

# Fix ownership of sandbox home directory itself
chown sandbox:sandbox /home/sandbox 2>/dev/null || true


# ---------------------------------------------------------------------------
# If no domain whitelist is set, run claude directly (no network filtering)
# ---------------------------------------------------------------------------
if [[ -z "$ALLOWED_DOMAINS" ]]; then
    echo "Warning: ALLOWED_DOMAINS is empty — running without network restrictions." >&2
    export HOME=/home/sandbox
    export BROWSER=false
    export NO_UPDATE_NOTIFIER=1
    exec gosu sandbox claude "$@"
fi

# ---------------------------------------------------------------------------
# Resolve domains to IPs
# ---------------------------------------------------------------------------
IFS=',' read -ra DOMAIN_LIST <<< "$ALLOWED_DOMAINS"
declare -a ALLOWED_IPV4=()
declare -a ALLOWED_IPV6=()

resolve_domain() {
    local domain="$1"
    # Resolve multiple times to catch CDN/load-balancer IP rotation
    for _attempt in 1 2 3; do
        dig +short "$domain" @"$DNS_SERVER" A 2>/dev/null | grep -E '^[0-9]+\.' || true
        dig +short "$domain" @"$DNS_SERVER" AAAA 2>/dev/null | grep -E '^[0-9a-f]+:' || true
    done | sort -u
}

for domain in "${DOMAIN_LIST[@]}"; do
    domain="$(echo "$domain" | xargs)"
    log "Resolving $domain..."

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" =~ ^[0-9]+\. ]]; then
            log "  -> $ip"
            ALLOWED_IPV4+=("$ip")
        else
            log "  -> $ip"
            ALLOWED_IPV6+=("$ip")
        fi
    done < <(resolve_domain "$domain")

    if [[ ${#ALLOWED_IPV4[@]} -eq 0 && ${#ALLOWED_IPV6[@]} -eq 0 ]]; then
        echo "Warning: Could not resolve $domain — no IPs found." >&2
    fi
done

if [[ ${#ALLOWED_IPV4[@]} -eq 0 && ${#ALLOWED_IPV6[@]} -eq 0 ]]; then
    echo "Error: No IPs resolved from the domain whitelist. Check your domains and DNS." >&2
    exit 1
fi

ALLOWED_IPV4+=("$DNS_SERVER")
log "Allowed IPv4: ${ALLOWED_IPV4[*]}"
[[ ${#ALLOWED_IPV6[@]} -gt 0 ]] && log "Allowed IPv6: ${ALLOWED_IPV6[*]}"

# ---------------------------------------------------------------------------
# Configure iptables OUTPUT rules
# ---------------------------------------------------------------------------
log "Configuring iptables egress rules"

# --- IPv4 rules ---
iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -d "$DNS_SERVER" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d "$DNS_SERVER" -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

for ip in "${ALLOWED_IPV4[@]}"; do
    iptables -A OUTPUT -d "$ip" -j ACCEPT
done

iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable

# --- IPv6 rules ---
if [[ ${#ALLOWED_IPV6[@]} -gt 0 ]]; then
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -P OUTPUT DROP
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    for ip in "${ALLOWED_IPV6[@]}"; do
        ip6tables -A OUTPUT -d "$ip" -j ACCEPT
    done

    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-addr-unreachable
else
    # No IPv6 addresses resolved — block all IPv6 egress
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
fi

log "Network rules applied"

# ---------------------------------------------------------------------------
# Drop to non-root user and run Claude Code
# ---------------------------------------------------------------------------
export HOME=/home/sandbox

# Prevent Node.js from trying to open a browser for OAuth — there's no
# display in the container, and xdg-open can hang waiting for D-Bus.
export BROWSER=false

# Disable npm update-notifier (would try to reach registry.npmjs.org, blocked)
export NO_UPDATE_NOTIFIER=1

if [[ "$VERBOSE" == "1" ]]; then
    log "Launching Claude Code as sandbox user"
    log "Testing privilege drop..."
    gosu sandbox node -e 'console.error("[sandbox] node: ok, uid=" + process.getuid())' || true
    log "Testing claude --version..."
    gosu sandbox claude --version 2>&1 | head -1 || true
    log "Testing network from sandbox user..."
    gosu sandbox node -e '
const dns = require("dns"), net = require("net");
dns.resolve4("statsig.anthropic.com", (err, addrs) => {
  if (err) { console.error("[sandbox] DNS statsig:", err.code); return; }
  console.error("[sandbox] DNS statsig:", addrs.join(", "));
  const s = net.connect(443, addrs[0]);
  s.on("connect", () => { console.error("[sandbox] TCP statsig:443 OK"); s.destroy(); });
  s.on("error", (e) => console.error("[sandbox] TCP statsig:443 FAIL:", e.code));
  s.setTimeout(5000, () => { console.error("[sandbox] TCP statsig:443 TIMEOUT"); s.destroy(); });
});
dns.resolve4("api.anthropic.com", (err, addrs) => {
  if (err) { console.error("[sandbox] DNS api:", err.code); return; }
  console.error("[sandbox] DNS api:", addrs.join(", "));
  const s = net.connect(443, addrs[0]);
  s.on("connect", () => { console.error("[sandbox] TCP api:443 OK"); s.destroy(); });
  s.on("error", (e) => console.error("[sandbox] TCP api:443 FAIL:", e.code));
  s.setTimeout(5000, () => { console.error("[sandbox] TCP api:443 TIMEOUT"); s.destroy(); });
});
' 2>&1 || true
    sleep 3
    log "Starting claude (with strace for 10s)..."
    # Trace network + poll/select syscalls for first 10 seconds, then kill strace
    timeout 10 strace -f -e trace=connect,poll,select,epoll_wait,recvfrom \
        -o /tmp/claude-strace.log \
        gosu sandbox claude "$@" &
    STRACE_PID=$!
    sleep 11
    kill $STRACE_PID 2>/dev/null || true
    wait $STRACE_PID 2>/dev/null || true
    log "=== strace output (last 40 lines) ==="
    tail -40 /tmp/claude-strace.log >&2 || true
    log "=== end strace ==="
    log "Now launching claude normally..."
fi

exec gosu sandbox claude "$@"
