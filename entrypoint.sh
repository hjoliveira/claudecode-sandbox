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
# If no domain whitelist is set, run claude directly (no network filtering)
# ---------------------------------------------------------------------------
if [[ -z "$ALLOWED_DOMAINS" ]]; then
    echo "Warning: ALLOWED_DOMAINS is empty — running without network restrictions." >&2
    export HOME=/home/sandbox
    SANDBOX_UID="$(id -u sandbox)"
    SANDBOX_GID="$(id -g sandbox)"
    exec setpriv --reuid="$SANDBOX_UID" --regid="$SANDBOX_GID" --init-groups claude "$@"
fi

# ---------------------------------------------------------------------------
# Resolve domains to IPs
# ---------------------------------------------------------------------------
IFS=',' read -ra DOMAIN_LIST <<< "$ALLOWED_DOMAINS"
declare -a ALLOWED_IPS=()

for domain in "${DOMAIN_LIST[@]}"; do
    domain="$(echo "$domain" | xargs)"
    log "Resolving $domain..."

    ips="$(dig +short "$domain" @"$DNS_SERVER" A 2>/dev/null | grep -E '^[0-9]+\.' || true)"
    ips6="$(dig +short "$domain" @"$DNS_SERVER" AAAA 2>/dev/null | grep -E '^[0-9a-f]+:' || true)"

    if [[ -z "$ips" && -z "$ips6" ]]; then
        echo "Warning: Could not resolve $domain — no IPs found." >&2
    fi

    for ip in $ips $ips6; do
        log "  -> $ip"
        ALLOWED_IPS+=("$ip")
    done
done

if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
    echo "Error: No IPs resolved from the domain whitelist. Check your domains and DNS." >&2
    exit 1
fi

ALLOWED_IPS+=("$DNS_SERVER")
log "Allowed IPs: ${ALLOWED_IPS[*]}"

# ---------------------------------------------------------------------------
# Configure iptables OUTPUT rules
# ---------------------------------------------------------------------------
log "Configuring iptables egress rules"

iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT DROP

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -d "$DNS_SERVER" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d "$DNS_SERVER" -j ACCEPT

# Allow established/related
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow whitelisted IPs
for ip in "${ALLOWED_IPS[@]}"; do
    iptables -A OUTPUT -d "$ip" -j ACCEPT
done

# Reject everything else with a clear error
iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable

log "Network rules applied"

# ---------------------------------------------------------------------------
# Drop to non-root user and run Claude Code
# ---------------------------------------------------------------------------
log "Launching Claude Code as sandbox user"
export HOME=/home/sandbox
SANDBOX_UID="$(id -u sandbox)"
SANDBOX_GID="$(id -g sandbox)"
exec setpriv --reuid="$SANDBOX_UID" --regid="$SANDBOX_GID" --init-groups claude "$@"
