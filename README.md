# Claude Code Sandboxed Execution

Run Claude Code CLI in a sandboxed Linux environment with:

1. **Filesystem isolation** — Claude Code can only access a single directory you specify
2. **Network whitelisting** — Claude Code can only reach domains you explicitly allow

## How It Works

The sandbox uses three Linux kernel features:

| Mechanism | Purpose |
|-----------|---------|
| **Mount namespace** (`unshare --mount`) + `pivot_root` | Builds a minimal root filesystem. Only `/usr`, `/lib`, `/bin`, `/etc` (read-only) and your project directory (read-write) are visible. |
| **Network namespace** (`unshare --net`) + `iptables` | Creates an isolated network stack. `iptables OUTPUT` rules allow traffic only to IPs resolved from your domain whitelist. All other outbound traffic is rejected. |
| **PID namespace** (`unshare --pid`) | Isolates the process tree so sandboxed processes can't see or signal host processes. |

### Diagram

```
┌─────────────────────────────────────────────┐
│  Host                                        │
│                                              │
│  sudo ./sandbox.sh                           │
│       │                                      │
│       ▼                                      │
│  ┌──────────────────────────────────────┐    │
│  │  unshare (mount + net + pid)         │    │
│  │                                      │    │
│  │  Filesystem:                         │    │
│  │    /                (tmpfs)          │    │
│  │    /usr, /lib, ... (read-only bind)  │    │
│  │    /home/sandbox/project (rw bind)   │    │
│  │        └── your project dir          │    │
│  │                                      │    │
│  │  Network (iptables OUTPUT chain):    │    │
│  │    ALLOW → dns-server:53             │    │
│  │    ALLOW → api.anthropic.com IPs     │    │
│  │    ALLOW → github.com IPs            │    │
│  │    DROP  → everything else           │    │
│  │                                      │    │
│  │  $ claude  ← runs here              │    │
│  └──────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

## Requirements

- Linux (kernel 3.8+ for user namespaces, though root is used here)
- `unshare`, `mount`, `iptables`, `dig` (from `dnsutils` / `bind-utils`)
- Root access (or `sudo`)
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)

## Quick Start

```bash
# 1. Clone this repo
git clone <repo-url> && cd claudecode-sandbox

# 2. Run Claude Code sandboxed to ./my-project, allowing only the Claude API
sudo ./sandbox.sh \
  --dir ./my-project \
  --domains "api.anthropic.com"

# 3. Or with more domains and verbose logging
sudo ./sandbox.sh \
  --dir /home/user/code \
  --domains "api.anthropic.com,github.com,api.github.com,registry.npmjs.org" \
  --verbose

# 4. Pass extra arguments to claude after --
sudo ./sandbox.sh \
  --dir ./my-project \
  --domains "api.anthropic.com" \
  -- --model sonnet --print "fix the tests"
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--dir DIR` | Project directory to expose (required) | — |
| `--domains LIST` | Comma-separated allowed domains (required) | — |
| `--claude-bin PATH` | Path to `claude` binary | `claude` (from `$PATH`) |
| `--dns-server IP` | DNS server for resolving domains | `8.8.8.8` |
| `--verbose` | Print debug info to stderr | off |

## Domain Whitelist Recommendations

| Domain | Why |
|--------|-----|
| `api.anthropic.com` | **Required.** Claude API calls. |
| `github.com` | Git push/pull over HTTPS. |
| `api.github.com` | GitHub API (PRs, issues, etc.). |
| `registry.npmjs.org` | `npm install` |
| `pypi.org` + `files.pythonhosted.org` | `pip install` |

## Limitations & Considerations

- **DNS caching**: Domain IPs are resolved at startup. If a domain's IPs change during a long session, new IPs won't be allowed. Mitigate this by re-running the sandbox or using a local proxy approach instead.
- **CDN domains**: Some services (npm, pip) pull packages from CDN subdomains. You may need to whitelist additional domains like `*.cloudfront.net` — for that, a proxy-based approach is better.
- **Root required**: The mount/network namespace setup requires root. A rootless alternative using `bubblewrap` (`bwrap`) is possible and described below.

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

## Alternative: Container-Based (Docker/Podman)

For production use, a container provides the strongest isolation:

```bash
docker run --rm -it \
  -v /path/to/project:/project:rw \
  --network=sandbox-net \
  --cap-drop=ALL \
  claude-sandbox
```

Where `sandbox-net` is a Docker network with iptables rules restricting egress to whitelisted IPs.
