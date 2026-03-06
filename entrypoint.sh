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
# Restore ~/.claude.json from backup if missing (Claude Code requires it)
# ---------------------------------------------------------------------------
if [[ ! -f /home/sandbox/.claude.json ]]; then
    BACKUP="$(ls -t /home/sandbox/.claude/backups/.claude.json.backup.* 2>/dev/null | head -1)"
    if [[ -n "$BACKUP" ]]; then
        cp "$BACKUP" /home/sandbox/.claude.json
        chown sandbox:sandbox /home/sandbox/.claude.json 2>/dev/null || true
        log "Restored ~/.claude.json from backup"
    fi
fi

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
declare -a ALLOWED_IPV4=()
declare -a ALLOWED_IPV6=()

for domain in "${DOMAIN_LIST[@]}"; do
    domain="$(echo "$domain" | xargs)"
    log "Resolving $domain..."

    ips="$(dig +short "$domain" @"$DNS_SERVER" A 2>/dev/null | grep -E '^[0-9]+\.' || true)"
    ips6="$(dig +short "$domain" @"$DNS_SERVER" AAAA 2>/dev/null | grep -E '^[0-9a-f]+:' || true)"

    if [[ -z "$ips" && -z "$ips6" ]]; then
        echo "Warning: Could not resolve $domain — no IPs found." >&2
    fi

    for ip in $ips; do
        log "  -> $ip"
        ALLOWED_IPV4+=("$ip")
    done
    for ip in $ips6; do
        log "  -> $ip"
        ALLOWED_IPV6+=("$ip")
    done
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
log "Launching Claude Code as sandbox user"
export HOME=/home/sandbox
SANDBOX_UID="$(id -u sandbox)"
SANDBOX_GID="$(id -g sandbox)"
exec setpriv --reuid="$SANDBOX_UID" --regid="$SANDBOX_GID" --init-groups claude "$@"
