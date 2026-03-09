#!/usr/bin/env bash
#
# integration.sh — Integration tests for the Claude Code sandbox.
#
# Tests Docker image build, entrypoint domain validation, DNS resolution,
# iptables network isolation, and privilege dropping.
#
# Usage:
#   ./tests/integration.sh [--keep-image]
#
set -euo pipefail

IMAGE_NAME="claude-sandbox-test"
KEEP_IMAGE=0
PASS=0
FAIL=0
ERRORS=()

for arg in "$@"; do
    case "$arg" in
        --keep-image) KEEP_IMAGE=1 ;;
    esac
done

cleanup() {
    if [[ "$KEEP_IMAGE" == "0" ]]; then
        docker rmi "$IMAGE_NAME" &>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1")
    echo "  FAIL: $1"
}

# Run a command inside the sandbox container.
# Usage: run_in_container [docker-run-flags...] -- [command...]
# The image name and project volume are handled automatically.
run_in_container() {
    local -a docker_flags=()
    local -a cmd=()
    local tmpdir
    tmpdir="$(mktemp -d)"
    local seen_separator=0

    for arg in "$@"; do
        if [[ "$seen_separator" == "0" ]]; then
            if [[ "$arg" == "--" ]]; then
                seen_separator=1
            else
                docker_flags+=("$arg")
            fi
        else
            cmd+=("$arg")
        fi
    done

    docker run --rm \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=CHOWN \
        --cap-add=DAC_OVERRIDE \
        --cap-add=FOWNER \
        --dns 8.8.8.8 \
        -v "$tmpdir:/home/sandbox/project" \
        "${docker_flags[@]}" \
        "$IMAGE_NAME" \
        "${cmd[@]}"
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

# ── Build ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Building Docker image ==="
if docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"; then
    pass "Docker image builds successfully"
else
    fail "Docker image build failed"
    echo "FATAL: Cannot continue without a working image."
    exit 1
fi

# ── Test 1: Entrypoint runs without ALLOWED_DOMAINS ─────────────────────
# When ALLOWED_DOMAINS is empty, the entrypoint should print a warning
# and run the given command (instead of claude) without network filtering.

echo ""
echo "=== Test: No ALLOWED_DOMAINS prints warning ==="
# The entrypoint exec's `gosu sandbox claude "$@"` when empty. We override
# the entrypoint to a script that sources the early parts but replaces the
# final exec with our test command.
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=" \
    --entrypoint /bin/bash \
    -- -c '
        # Run entrypoint but replace "claude" with our test command.
        # Since entrypoint exec-s into gosu, we cannot run commands after it.
        # Instead, just test the warning path directly.
        export ALLOWED_DOMAINS=""
        export DNS_SERVER=8.8.8.8
        export VERBOSE=0
        source <(sed "s|exec gosu sandbox claude|exec gosu sandbox echo sandbox-ok #|" /entrypoint.sh)
    ' 2>&1) || true

if echo "$output" | grep -q "without network restrictions"; then
    pass "Warning printed when ALLOWED_DOMAINS is empty"
else
    fail "Missing warning when ALLOWED_DOMAINS is empty"
fi

if echo "$output" | grep -q "sandbox-ok"; then
    pass "Command executes when ALLOWED_DOMAINS is empty"
else
    fail "Command did not execute when ALLOWED_DOMAINS is empty"
fi

# ── Test 2: Invalid domain name is rejected ──────────────────────────────

echo ""
echo "=== Test: Invalid domain validation ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=not_a_valid_domain!" \
    -e "DNS_SERVER=8.8.8.8" \
    --entrypoint /bin/bash \
    -- -c '
        export ALLOWED_DOMAINS="not_a_valid_domain!"
        export DNS_SERVER=8.8.8.8
        export VERBOSE=0
        /entrypoint.sh echo "should-not-run" 2>&1
        echo "EXIT_CODE=$?"
    ' 2>&1) || true

if echo "$output" | grep -q "Invalid domain name"; then
    pass "Invalid domain name rejected"
else
    fail "Invalid domain name was not rejected"
fi

if echo "$output" | grep -q "should-not-run"; then
    fail "Command ran despite invalid domain"
else
    pass "Command blocked with invalid domain"
fi

# ── Test 3: Valid domain resolves and iptables rules are applied ─────────

echo ""
echo "=== Test: Network isolation with allowed domain ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    -e "VERBOSE=1" \
    --entrypoint /bin/bash \
    -- -c '
        # Run entrypoint but replace claude exec with a marker
        sed "s|exec gosu sandbox claude|echo ENTRYPOINT_OK; exec gosu sandbox echo done #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>&1
    ' 2>&1) || true

if echo "$output" | grep -q "Network rules applied\|ENTRYPOINT_OK"; then
    pass "Entrypoint completes with valid domain"
else
    fail "Entrypoint did not complete with valid domain"
fi

# ── Test 4: iptables blocks disallowed traffic ───────────────────────────

echo ""
echo "=== Test: Blocked egress to non-whitelisted host ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    --entrypoint /bin/bash \
    -- -c '
        # Run entrypoint setup (iptables) but skip the final exec into claude
        sed "s|exec gosu sandbox claude|# replaced|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>/dev/null || true

        # Now iptables rules should be in place. Try reaching a non-whitelisted host.
        if curl -s --connect-timeout 5 http://example.com >/dev/null 2>&1; then
            echo "BLOCKED=no"
        else
            echo "BLOCKED=yes"
        fi
    ' 2>&1) || true

if echo "$output" | grep -q "BLOCKED=yes"; then
    pass "Egress to non-whitelisted host is blocked"
else
    fail "Egress to non-whitelisted host was NOT blocked"
fi

# ── Test 5: iptables allows whitelisted traffic ──────────────────────────

echo ""
echo "=== Test: Allowed egress to whitelisted host ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    --entrypoint /bin/bash \
    -- -c '
        sed "s|exec gosu sandbox claude|# replaced|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>/dev/null || true

        # api.anthropic.com should be reachable — any HTTP status means connection worked
        if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.anthropic.com 2>/dev/null | grep -qE "^[1-5]"; then
            echo "ALLOWED=yes"
        else
            echo "ALLOWED=no"
        fi
    ' 2>&1) || true

if echo "$output" | grep -q "ALLOWED=yes"; then
    pass "Egress to whitelisted host is allowed"
else
    fail "Egress to whitelisted host was blocked"
fi

# ── Test 6: Privilege drop — command runs as non-root ────────────────────

echo ""
echo "=== Test: Privilege dropping ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=" \
    --entrypoint /bin/bash \
    -- -c '
        # Replace claude with id so we can check the UID
        sed "s|exec gosu sandbox claude|exec gosu sandbox id -u #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>/dev/null
    ' 2>&1) || true

if echo "$output" | grep -qE "^[1-9][0-9]*$"; then
    pass "Process runs as non-root user"
else
    fail "Process may be running as root"
fi

# ── Test 7: .claude.json persistence via volume ──────────────────────────

echo ""
echo "=== Test: .claude.json persistence ==="
tmpdir="$(mktemp -d)"
mkdir -p "$tmpdir/claude-json"
echo '{"test":"value"}' > "$tmpdir/claude-json/.claude.json"

output=$(docker run --rm \
    --cap-drop=ALL \
    --cap-add=NET_ADMIN \
    --cap-add=SETUID \
    --cap-add=SETGID \
    --cap-add=CHOWN \
    --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER \
    --dns 8.8.8.8 \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    -v "$tmpdir/claude-json:/home/sandbox/.claude-json" \
    -v "$tmpdir:/home/sandbox/project" \
    --entrypoint /bin/bash \
    "$IMAGE_NAME" \
    -c '
        sed "s|exec gosu sandbox claude|exec gosu sandbox cat /home/sandbox/.claude.json #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>/dev/null
    ' 2>&1) || true
rm -rf "$tmpdir"

if echo "$output" | grep -q '"test":"value"'; then
    pass ".claude.json symlinked from volume"
else
    fail ".claude.json persistence not working"
fi

# ── Test 8: IPv4 address is accepted without DNS resolution ─────────────

echo ""
echo "=== Test: IPv4 address accepted directly ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=1.2.3.4" \
    -e "DNS_SERVER=8.8.8.8" \
    -e "VERBOSE=1" \
    --entrypoint /bin/bash \
    -- -c '
        sed "s|exec gosu sandbox claude|echo ENTRYPOINT_OK; exec gosu sandbox echo done #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>&1
    ' 2>&1) || true

if echo "$output" | grep -q "Using IPv4 address directly"; then
    pass "IPv4 address accepted without DNS resolution"
else
    fail "IPv4 address was not accepted directly"
fi

if echo "$output" | grep -q "ENTRYPOINT_OK"; then
    pass "Entrypoint completes with IPv4 address"
else
    fail "Entrypoint did not complete with IPv4 address"
fi

# ── Test 9: IPv6 address is accepted without DNS resolution ─────────────

echo ""
echo "=== Test: IPv6 address accepted directly ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=2001:db8::1" \
    -e "DNS_SERVER=8.8.8.8" \
    -e "VERBOSE=1" \
    --entrypoint /bin/bash \
    -- -c '
        sed "s|exec gosu sandbox claude|echo ENTRYPOINT_OK; exec gosu sandbox echo done #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>&1
    ' 2>&1) || true

if echo "$output" | grep -q "Using IPv6 address directly"; then
    pass "IPv6 address accepted without DNS resolution"
else
    fail "IPv6 address was not accepted directly"
fi

if echo "$output" | grep -q "ENTRYPOINT_OK"; then
    pass "Entrypoint completes with IPv6 address"
else
    fail "Entrypoint did not complete with IPv6 address"
fi

# ── Test 10: Mix of domains and IP addresses ──────────────────────────────

echo ""
echo "=== Test: Mixed domains and IP addresses ==="
output=$(run_in_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com,8.8.4.4" \
    -e "DNS_SERVER=8.8.8.8" \
    -e "VERBOSE=1" \
    --entrypoint /bin/bash \
    -- -c '
        sed "s|exec gosu sandbox claude|echo ENTRYPOINT_OK; exec gosu sandbox echo done #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>&1
    ' 2>&1) || true

if echo "$output" | grep -q "Using IPv4 address directly" && echo "$output" | grep -q "Resolving api.anthropic.com"; then
    pass "Mixed domains and IP addresses processed correctly"
else
    fail "Mixed domains and IP addresses not processed correctly"
fi

if echo "$output" | grep -q "ENTRYPOINT_OK"; then
    pass "Entrypoint completes with mixed domains and IPs"
else
    fail "Entrypoint did not complete with mixed domains and IPs"
fi

# ── Test 11: Sandbox user can write to mounted project directory ──────────

echo ""
echo "=== Test: Mounted project directory is writable ==="
tmpdir="$(mktemp -d)"
# Ensure the tmpdir is owned by the current user (simulates host project dir)
chmod 755 "$tmpdir"

output=$(docker run --rm \
    --cap-drop=ALL \
    --cap-add=NET_ADMIN \
    --cap-add=SETUID \
    --cap-add=SETGID \
    --cap-add=CHOWN \
    --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER \
    --dns 8.8.8.8 \
    -e "ALLOWED_DOMAINS=" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    -v "$tmpdir:/home/sandbox/project" \
    --entrypoint /bin/bash \
    "$IMAGE_NAME" \
    -c '
        sed "s|exec gosu sandbox claude|exec gosu sandbox bash -c \"touch /home/sandbox/project/testfile \&\& echo WRITE_OK\" #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>/dev/null
    ' 2>&1) || true

if echo "$output" | grep -q "WRITE_OK"; then
    pass "Sandbox user can write to mounted project directory"
else
    fail "Sandbox user cannot write to mounted project directory"
fi
rm -rf "$tmpdir"

# ── Test 12: Auto-detect UID/GID from project directory ──────────────────

echo ""
echo "=== Test: Auto-detect UID/GID from project dir (no HOST_UID/HOST_GID) ==="
tmpdir="$(mktemp -d)"
chmod 755 "$tmpdir"

output=$(docker run --rm \
    --cap-drop=ALL \
    --cap-add=NET_ADMIN \
    --cap-add=SETUID \
    --cap-add=SETGID \
    --cap-add=CHOWN \
    --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER \
    --dns 8.8.8.8 \
    -e "ALLOWED_DOMAINS=" \
    -e "VERBOSE=1" \
    -v "$tmpdir:/home/sandbox/project" \
    --entrypoint /bin/bash \
    "$IMAGE_NAME" \
    -c '
        sed "s|exec gosu sandbox claude|exec gosu sandbox bash -c \"touch /home/sandbox/project/testfile \&\& echo WRITE_OK\" #|" /entrypoint.sh > /tmp/test-entry.sh
        chmod +x /tmp/test-entry.sh
        /tmp/test-entry.sh 2>&1
    ' 2>&1) || true

if echo "$output" | grep -q "Auto-detected HOST_UID"; then
    pass "UID auto-detected from project directory"
else
    fail "UID not auto-detected from project directory"
fi

if echo "$output" | grep -q "WRITE_OK"; then
    pass "Sandbox user can write after UID/GID auto-detection"
else
    fail "Sandbox user cannot write after UID/GID auto-detection"
fi
rm -rf "$tmpdir"

# ── Test 13: default-domains.conf is read by sandbox.sh ──────────────────

echo ""
echo "=== Test: default-domains.conf parsing ==="
if [[ -f "$SCRIPT_DIR/default-domains.conf" ]]; then
    domain_count=$(grep -vc '^#\|^$' "$SCRIPT_DIR/default-domains.conf")
    if [[ "$domain_count" -gt 0 ]]; then
        pass "default-domains.conf contains $domain_count domains"
    else
        fail "default-domains.conf is empty"
    fi
else
    fail "default-domains.conf not found"
fi

# ── Summary ──────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi
