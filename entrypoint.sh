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

# Fix ownership of sandbox home directory itself (must be writable for .claude.json)
chown sandbox:sandbox /home/sandbox
chmod 755 /home/sandbox


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
# Bootstrap container-local ~/.claude from the read-only host mount.
# Only copy credentials — skip host hooks, project caches, and org state
# that can break OAuth or reference host-only paths.
# ---------------------------------------------------------------------------
HOST_CLAUDE="/home/sandbox/.claude-host"
CONTAINER_CLAUDE="/home/sandbox/.claude"

if [[ -d "$HOST_CLAUDE" ]]; then
    mkdir -p "$CONTAINER_CLAUDE"

    # Copy credentials file if it exists
    if [[ -f "$HOST_CLAUDE/.credentials.json" ]]; then
        cp "$HOST_CLAUDE/.credentials.json" "$CONTAINER_CLAUDE/.credentials.json"
        log "Copied credentials from host"
    fi

    # Restore .claude.json from host backup if needed
    if [[ ! -f "/home/sandbox/.claude.json" ]]; then
        BACKUP=$(find "$HOST_CLAUDE/backups" -name '.claude.json.backup.*' 2>/dev/null | sort -t. -k4 -n | tail -1)
        if [[ -n "$BACKUP" ]]; then
            cp "$BACKUP" "/home/sandbox/.claude.json"
            log "Restored .claude.json from host backup"
        fi
    fi

    chown -R sandbox:sandbox "$CONTAINER_CLAUDE" /home/sandbox/.claude.json 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Drop to non-root user and run Claude Code
# ---------------------------------------------------------------------------
export HOME=/home/sandbox

# Prevent Node.js from trying to open a browser for OAuth — there's no
# display in the container, and xdg-open can hang waiting for D-Bus.
export BROWSER=false

# Disable npm update-notifier (would try to reach registry.npmjs.org, blocked)
export NO_UPDATE_NOTIFIER=1

log "Launching Claude Code as sandbox user"
exec gosu sandbox claude "$@"
