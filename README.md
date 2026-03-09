# Claude Code Sandboxed Execution

Run Claude Code CLI in a Docker-based sandbox with:

1. **Filesystem isolation** — Claude Code can only access a single directory you specify
2. **Network whitelisting** — Claude Code can only reach domains you explicitly allow
3. **No root on host** — only Docker is required; works on macOS, Linux, and Windows

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running
- `ANTHROPIC_API_KEY` environment variable set (optional — omit to log in interactively inside the container)
- `ANTHROPIC_AUTH_TOKEN` environment variable set (optional — alternative to API key)
- `ANTHROPIC_BASE_URL` environment variable set (optional — override the Anthropic API base URL)

## Quick Start

```bash
# 1. Clone this repo
git clone <repo-url> && cd claudecode-sandbox

# 2. Run Claude Code sandboxed to ./my-project (Anthropic domains included by default)
./sandbox.sh --dir ./my-project

# 3. Allow additional domains and enable verbose logging
./sandbox.sh \
  --dir ~/code/my-app \
  --domains "github.com,api.github.com,registry.npmjs.org" \
  --verbose

# 4. Allow specific IP addresses (IPv4 or IPv6) in addition to or instead of domains
./sandbox.sh \
  --dir ./my-project \
  --domains "192.168.1.100,10.0.0.1,2001:db8::1"

# 5. Pass extra arguments to claude after --
./sandbox.sh \
  --dir ./my-project \
  -- --model sonnet --print "fix the tests"

# 6. Force rebuild the image (e.g. after updating Claude Code)
./sandbox.sh --build --dir ./my-project
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--dir DIR` | Project directory to expose (required) | — |
| `--domains LIST` | Additional comma-separated allowed domains or IP addresses | — |
| `--dns-server IP` | DNS server for resolving domains | `8.8.8.8` |
| `--verbose` | Print debug info to stderr | off |
| `--tmpfs-size SIZE` | Size of /tmp tmpfs mount | `512M` |
| `--build` | Force rebuild the Docker image | off |

## How It Works

```
┌─────────────────────────────────────────────────┐
│  Host (any OS)                                   │
│                                                  │
│  ./sandbox.sh                                    │
│       │                                          │
│       ▼                                          │
│  docker run --cap-add=NET_ADMIN --cap-drop=ALL   │
│  ┌──────────────────────────────────────────┐    │
│  │  Container                               │    │
│  │                                          │    │
│  │  entrypoint.sh:                          │    │
│  │    1. Resolve ALLOWED_DOMAINS → IPs      │    │
│  │    2. iptables OUTPUT rules (whitelist)   │    │
│  │    3. Drop to non-root user (gosu)         │    │
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
│  │    --cap-drop=ALL +NET_ADMIN +CHOWN      │    │
│  │    +SETUID/SETGID +DAC_OVERRIDE +FOWNER  │    │
│  │    Claude runs as non-root user          │    │
│  └──────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

### Security layers

- **seccomp** profile restricts available syscalls
- **Capability dropping** — only `NET_ADMIN`, `SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE`, and `FOWNER` are granted; all others are dropped
- **cgroup isolation** — CPU/memory limits can be added via `--memory` / `--cpus`
- **User isolation** — Claude runs as a non-root user inside the container; no root on the host

## Domain Whitelist

The following Anthropic domains are **always included** automatically:

| Domain | Why |
|--------|-----|
| `api.anthropic.com` | Claude API calls |
| `claude.ai` | Authentication |
| `platform.claude.com` | Authentication |
| `statsig.anthropic.com` | Feature flags |

Use `--domains` to allow additional services or specific IP addresses:

| Domain / IP | Why |
|-------------|-----|
| `github.com` | Git push/pull over HTTPS. |
| `api.github.com` | GitHub API (PRs, issues, etc.). |
| `registry.npmjs.org` | `npm install` |
| `pypi.org` + `files.pythonhosted.org` | `pip install` |
| `192.168.1.100` | Private/on-premise service by IPv4 address |
| `2001:db8::1` | Private/on-premise service by IPv6 address |

IP addresses are added directly to the firewall rules without DNS resolution, which is useful for private network services or when you want to allow a fixed IP without relying on DNS.

## Limitations & Considerations

- **DNS caching**: Domain IPs are resolved at container startup. If IPs change during a long session, the new IPs won't be allowed. Restart the container to refresh.
- **CDN domains**: Services like npm/pip may fetch from CDN subdomains. You may need to whitelist additional domains (e.g., `registry.npmmirror.com`).
- **Docker Desktop overhead**: On macOS/Windows, Docker runs inside a lightweight VM, which adds some memory overhead compared to native Linux containers.
