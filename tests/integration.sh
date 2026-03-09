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

run_container() {
    # Run the sandbox container with given env vars and command.
    # Automatically adds required caps and a dummy project dir.
    local tmpdir
    tmpdir="$(mktemp -d)"
    docker run --rm \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=CHOWN \
        --cap-add=DAC_OVERRIDE \
        --cap-add=FOWNER \
        -v "$tmpdir:/home/sandbox/project" \
        "$@" \
        "$IMAGE_NAME"
    rm -rf "$tmpdir"
}

# ── Build ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Building Docker image ==="
if docker build -t "$IMAGE_NAME" "$SCRIPT_DIR" >/dev/null 2>&1; then
    pass "Docker image builds successfully"
else
    fail "Docker image build failed"
    echo "FATAL: Cannot continue without a working image."
    exit 1
fi

# ── Test 1: Entrypoint runs without ALLOWED_DOMAINS (no network filtering) ──

echo ""
echo "=== Test: No ALLOWED_DOMAINS prints warning ==="
output=$(run_container \
    -e ALLOWED_DOMAINS="" \
    --entrypoint /entrypoint.sh \
    -- echo "sandbox-ok" 2>&1) || true

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
output=$(run_container \
    -e "ALLOWED_DOMAINS=not_a_valid_domain!" \
    -e "DNS_SERVER=8.8.8.8" \
    --entrypoint /entrypoint.sh \
    -- echo "should-not-run" 2>&1) || true

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
output=$(run_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    -e "VERBOSE=1" \
    --entrypoint /bin/bash \
    -- -c '/entrypoint.sh echo "setup-done" 2>&1 && echo "ENTRYPOINT_OK"' 2>&1) || true

if echo "$output" | grep -q "Network rules applied\|ENTRYPOINT_OK\|setup-done"; then
    pass "Entrypoint completes with valid domain"
else
    fail "Entrypoint did not complete with valid domain"
fi

# ── Test 4: iptables blocks disallowed traffic ───────────────────────────

echo ""
echo "=== Test: Blocked egress to non-whitelisted host ==="

# We'll use a custom entrypoint that sets up rules then tries to curl a
# non-whitelisted host. The curl should fail.
output=$(run_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    --entrypoint /bin/bash \
    -- -c '
        /entrypoint.sh true 2>/dev/null
        # Now running as root still (bash -c), iptables rules are set.
        # Try reaching a host NOT in the whitelist — should be blocked.
        if curl -s --connect-timeout 5 http://example.com >/dev/null 2>&1; then
            echo "BLOCKED=no"
        else
            echo "BLOCKED=yes"
        fi
    ' 2>&1) || true

if echo "$output" | grep -q "BLOCKED=yes"; then
    pass "Egress to non-whitelisted host is blocked"
else
    fail "Egress to non-whitelisted host was NOT blocked (may need --privileged for iptables in CI)"
fi

# ── Test 5: iptables allows whitelisted traffic ──────────────────────────

echo ""
echo "=== Test: Allowed egress to whitelisted host ==="
output=$(run_container \
    -e "ALLOWED_DOMAINS=api.anthropic.com" \
    -e "DNS_SERVER=8.8.8.8" \
    --entrypoint /bin/bash \
    -- -c '
        /entrypoint.sh true 2>/dev/null
        if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.anthropic.com 2>/dev/null | grep -qE "^[2-4]"; then
            echo "ALLOWED=yes"
        else
            echo "ALLOWED=no"
        fi
    ' 2>&1) || true

if echo "$output" | grep -q "ALLOWED=yes"; then
    pass "Egress to whitelisted host is allowed"
else
    fail "Egress to whitelisted host was blocked (may need --privileged for iptables in CI)"
fi

# ── Test 6: Privilege drop — Claude runs as non-root ─────────────────────

echo ""
echo "=== Test: Privilege dropping ==="
output=$(run_container \
    -e "ALLOWED_DOMAINS=" \
    --entrypoint /entrypoint.sh \
    -- id -u 2>&1) || true

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
    -e "ALLOWED_DOMAINS=" \
    -v "$tmpdir/claude-json:/home/sandbox/.claude-json" \
    -v "$tmpdir:/home/sandbox/project" \
    --entrypoint /entrypoint.sh \
    "$IMAGE_NAME" \
    cat /home/sandbox/.claude.json 2>&1) || true
rm -rf "$tmpdir"

if echo "$output" | grep -q '"test":"value"'; then
    pass ".claude.json symlinked from volume"
else
    fail ".claude.json persistence not working"
fi

# ── Test 8: default-domains.conf is read by sandbox.sh ───────────────────

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
