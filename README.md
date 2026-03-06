# Claude Code Sandboxed Execution

Run Claude Code CLI in a sandboxed environment with:

1. **Filesystem isolation** — Claude Code can only access a single directory you specify
2. **Network whitelisting** — Claude Code can only reach domains you explicitly allow

Two approaches are provided:

| Approach | Host root required? | Cross-platform? | Isolation depth |
|----------|-------------------|-----------------|-----------------|
| **Docker** (`sandbox-docker.sh`) | No | macOS, Linux, Windows | Full (namespaces + seccomp + capabilities) |
| **Native** (`sandbox.sh`) | Yes (`sudo`) | Linux only | Namespaces + iptables |

## Quick Start (Docker — recommended)

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running
- `ANTHROPIC_API_KEY` environment variable set

### Run

```bash
# 1. Clone this repo
git clone <repo-url> && cd claudecode-sandbox

# 2. Run Claude Code sandboxed to ./my-project, allowing only the Claude API
./sandbox-docker.sh \
  --dir ./my-project \
  --domains "api.anthropic.com"

# 3. With more domains and verbose logging
./sandbox-docker.sh \
  --dir ~/code/my-app \
  --domains "api.anthropic.com,github.com,api.github.com,registry.npmjs.org" \
  --verbose

# 4. Pass extra arguments to claude after --
./sandbox-docker.sh \
  --dir ./my-project \
  --domains "api.anthropic.com" \
  -- --model sonnet --print "fix the tests"

# 5. Force rebuild the image (e.g. after updating Claude Code)
./sandbox-docker.sh --build \
  --dir ./my-project \
  --domains "api.anthropic.com"
```

### Docker Compose

You can also use `docker compose` directly:

```bash
# Edit docker-compose.yml to set your volume mount and domains, then:
export ANTHROPIC_API_KEY=sk-ant-...
docker compose run --rm claude
```

### Docker Options

| Flag | Description | Default |
|------|-------------|---------|
| `--dir DIR` | Project directory to expose (required) | — |
| `--domains LIST` | Comma-separated allowed domains (required) | — |
| `--dns-server IP` | DNS server for resolving domains | `8.8.8.8` |
| `--verbose` | Print debug info to stderr | off |
| `--build` | Force rebuild the Docker image | off |

### How It Works (Docker)

```
┌─────────────────────────────────────────────────┐
│  Host (any OS)                                   │
│                                                  │
│  ./sandbox-docker.sh                             │
│       │                                          │
│       ▼                                          │
│  docker run --cap-add=NET_ADMIN --cap-drop=ALL   │
│  ┌──────────────────────────────────────────┐    │
│  │  Container                               │    │
│  │                                          │    │
│  │  entrypoint.sh:                          │    │
│  │    1. Resolve ALLOWED_DOMAINS → IPs      │    │
│  │    2. iptables OUTPUT rules (whitelist)   │    │
│  │    3. Drop to non-root user (gosu)       │    │
│  │    4. exec claude                        │    │
│  │                                          │    │
│  │  Filesystem:                             │    │
│  │    /home/sandbox/project (bind mount)    │    │
│  │        └── your project dir              │    │
│  │                                          │    │
│  │  Network (iptables OUTPUT chain):        │    │
│  │    ALLOW → dns-server:53                 │    │
│  │    ALLOW → api.anthropic.com IPs         │    │
│  │    ALLOW → github.com IPs                │    │
│  │    DROP  → everything else               │    │
│  │                                          │    │
│  │  Security:                               │    │
│  │    --cap-drop=ALL (except NET_ADMIN)     │    │
│  │    --security-opt no-new-privileges      │    │
│  │    Claude runs as non-root user          │    │
│  └──────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

Security layers provided by Docker beyond the native approach:
- **seccomp** profile restricts available syscalls
- **capability dropping** — only `NET_ADMIN` is granted (for iptables); all others are dropped
- **no-new-privileges** — prevents privilege escalation inside the container
- **cgroup isolation** — CPU/memory limits can be added via `--memory` / `--cpus`
- **User isolation** — Claude runs as a non-root user inside the container; no root on the host

## Domain Whitelist Recommendations

| Domain | Why |
|--------|-----|
| `api.anthropic.com` | **Required.** Claude API calls. |
| `github.com` | Git push/pull over HTTPS. |
| `api.github.com` | GitHub API (PRs, issues, etc.). |
| `registry.npmjs.org` | `npm install` |
| `pypi.org` + `files.pythonhosted.org` | `pip install` |

## Limitations & Considerations

- **DNS caching**: Domain IPs are resolved at container startup. If IPs change during a long session, the new IPs won't be allowed. Restart the container to refresh.
- **CDN domains**: Services like npm/pip may fetch from CDN subdomains. You may need to whitelist additional domains (e.g., `registry.npmmirror.com`).
- **Docker Desktop overhead**: On macOS/Windows, Docker runs inside a lightweight VM, which adds some memory overhead compared to native Linux containers.

## Alternative: Native Linux (sandbox.sh)

If you're on Linux and prefer a lightweight, zero-dependency approach (no Docker), the native script uses `unshare` to create mount, network, and PID namespaces directly. **Requires root.**

### Requirements

- Linux (kernel 3.8+)
- `unshare`, `mount`, `iptables`, `dig` (from `dnsutils` / `bind-utils`)
- Root access (or `sudo`)
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)

### Usage

```bash
sudo ./sandbox.sh \
  --dir ./my-project \
  --domains "api.anthropic.com"
```

| Flag | Description | Default |
|------|-------------|---------|
| `--dir DIR` | Project directory to expose (required) | — |
| `--domains LIST` | Comma-separated allowed domains (required) | — |
| `--claude-bin PATH` | Path to `claude` binary | `claude` (from `$PATH`) |
| `--dns-server IP` | DNS server for resolving domains | `8.8.8.8` |
| `--verbose` | Print debug info to stderr | off |

## Alternative: Bubblewrap (rootless)

[Bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) can achieve similar filesystem isolation without root:

```bash
bwrap \
  --ro-bind /usr /usr \
  --ro-bind /lib /lib \
  --ro-bind /lib64 /lib64 \
  --ro-bind /bin /bin \
  --ro-bind /sbin /sbin \
  --ro-bind /etc /etc \
  --bind /path/to/project /project \
  --proc /proc \
  --dev /dev \
  --tmpfs /tmp \
  --chdir /project \
  --unshare-net \
  -- claude
```

Note: `--unshare-net` disables *all* networking. For selective domain whitelisting with `bwrap`, combine it with a userspace proxy like `slirp4netns` + a filtering proxy.
