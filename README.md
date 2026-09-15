# Project

A local development template built with Worktrunk, Hum, Docker Compose, Bun,
mise, Task, Varlock, Lefthook, and Prettier. It includes a runnable HTTP example
so checkout preparation, parallel stacks, readiness, and cleanup can be tested
before adding an application.

## Quick start

Install [mise](https://mise.jdx.dev/) and have a running Docker Engine with the
`docker compose` plugin available. Mise manages the project tools, not the Docker
daemon. Then run:

```sh
mise trust
mise install
mise exec -- task init
mise exec -- hum up --detach
```

Open:

- `http://127.0.0.1:3000` — example application, including its checkout identity.
- `http://pgadmin.example.arpa:8080` — database administration.
- `http://traefik.example.arpa:8080` — local routing dashboard.

Stop the services with:

```sh
mise exec -- hum down
```

> [!WARNING]
> This Compose setup is for local development. It publishes PostgreSQL and an
> unauthenticated Traefik dashboard, uses predictable fallback passwords, and
> logs SQL statements. Do not expose it to an untrusted network or deploy it as
> written.

## Environment

Varlock resolves committed defaults and ignored local overrides:

| File                  | Git       | Contents                                  |
| --------------------- | --------- | ----------------------------------------- |
| `.env.schema`         | committed | Variable contract and non-secret defaults |
| `.env.local`          | ignored   | Local overrides and encrypted secrets     |
| `.env.worktree.local` | ignored   | Generated worktree identity and ports     |

`task init` creates the local files if needed and validates the resolved values.
In the primary checkout, `.env.worktree.local` is empty and schema/local defaults
apply. Linked worktrees get deterministic Compose project names, domains, and
three separate ports. Repeated setup preserves edits to both local files.

Task's `ENV_RUN` is the single environment entrypoint for applications and Compose.
It loads these three Varlock paths in order, with worktree values last, and clears
ambient routing/identity variables inherited from another checkout. It also pins
Compose to this checkout's file and ignores inherited Compose file/profile settings. Change these
values in the local files, not with shell exports. Secrets can still be supplied
through Varlock's normal mechanisms. Compose's implicit `.env` loading is disabled.

Declare a secret in `.env.schema`:

```dotenv
# @sensitive @required
API_KEY=
```

Prompt for and encrypt its local value in `.env.local`:

```dotenv
API_KEY=varlock(prompt)
```

```sh
task setup:env:check
```

Run other commands with the resolved environment:

```sh
task setup:env:run -- some-command
```

Map each required value only to the service that uses it:

```yaml
services:
    app:
        environment:
            API_KEY: "${API_KEY}"
```

Useful environment tasks:

```sh
task setup:env:encrypt # Encrypt one value manually
task setup:env:lock    # Lock the local encryption session
```

The pre-commit hook runs Gitleaks and `varlock scan --staged`. On macOS,
unlocking local values may request Touch ID.

## Parallel worktrees

### One-time configuration

Worktrunk is pinned in `mise.toml`. Configure shell navigation and review the
repository hooks before allowing agents to use them unattended:

```sh
mise exec worktrunk -- wt config shell install zsh
mise exec worktrunk -- wt config approvals add
```

Worktree placement and optional Herdr UI integration are personal settings. Merge
this into `~/.config/worktrunk/config.toml`, not the shared repository config:

```toml
worktree-path = "{{ repo_path }}/.worktrees/{{ branch | sanitize }}"

[post-start]
herdr = '''
if [ "${HERDR_ENV:-}" = "1" ]; then
  herdr worktree open --cwd {{ repo_path }} --path {{ worktree_path }} --label {{ worktree_name }} --no-focus
fi
'''
```

Herdr opens/registers the already-created checkout after blocking preparation,
without stealing focus. Creation outside Herdr remains headless. Background hook
failures are visible through `wt config state logs`; Git checkout success alone
does not prove that the UI hook succeeded.

### Create and prepare

```sh
mise exec worktrunk -- wt switch --create feature-a --base main --no-cd --format=json
mise exec worktrunk -- wt switch --create feature-b --base main --no-cd --format=json
wt list
```

Use the returned `path` as the agent's working directory. `.config/wt.toml` runs
ordered, blocking hooks to install the mise toolchain, copy allowlisted
client dependencies, and run `task setup:worktree`. Setup does not start Docker,
start an application, or copy the primary checkout's secrets. A repository with
required secrets needs its own explicit provisioning step before assigning work.

For an existing or plain Git-created worktree:

```sh
mise exec -- task setup:worktree
```

### Reuse or run independently

From a worktree:

```sh
wt shared                         # Read-only status of the primary stack
wt up                             # Start/reuse this checkout's isolated stack
mise exec -- hum status
mise exec -- hum logs app --tail 30
mise exec -- hum restart app       # Apply changes without restarting Docker
```

The primary stack runs **primary-checkout code**, not worktree edits. Use it for
investigation or checks against existing behavior; do not treat it as verification
of branch changes. `wt up` uses Hum's idempotent `up --detach`: existing processes
are retained. Each isolated stack has a separate Compose project, data directory,
Traefik routing scope, and loopback ports. PostgreSQL, Traefik, and pgAdmin must all
pass their health checks before Hum starts the application and probes its HTTP
readiness endpoint.

Find a worktree's local app port without displaying secrets:

```sh
grep '^APP_PORT=' .env.worktree.local
```

Ports are deterministic, not reserved machine-wide. If one is occupied, startup
fails rather than silently choosing a different port. Edit `.env.worktree.local`
and restart the affected processes. Add database/cache/bucket namespaces to this
same generated environment when adapting the template to external shared services.

### Cleanup

After stopping agents and checking for unsaved work, remove a checkout from a
surviving workspace:

```sh
wt remove feature-a --foreground --no-delete-branch
```

The blocking pre-remove hook runs project-scoped `hum down` before deleting the
checkout. It never stops the primary stack. Close the corresponding Herdr workspace
separately after checking its panes. Avoid raw Git removal: it skips these hooks.

`hum down` removes this stack's containers/network but preserves its bind-mounted
data while the checkout exists. **Removing the
worktree also removes its ignored `docker/data` directory.** Export any data you
need before removal. The example keeps the Git branch with `--no-delete-branch`.

### Copy-on-write

`.worktreeinclude` allows only `client/node_modules`. Worktrunk reflinks files on
APFS, btrfs, and XFS, falling back to full copies elsewhere. These are independent
files, not shared mutable symlinks. Setup reconciles the copy with
`bun install --frozen-lockfile`. Do not copy `.env*`, database files, PID files,
certificates, Python virtual environments, or running-service state.

### Adapt the example

- Replace `scripts/dev-server.ts` / `app:start` with your application command.
- Keep an executable readiness probe in `hum.yaml` and a health check on every
  Compose service; missing container health is not treated as readiness.
- Extend `.env.schema` and `scripts/worktree-env.ts` with your required namespaces.
- Add language-specific dependency setup to `setup:worktree`; keep it non-starting.
- Retain one writer per checkout. Worktrees do not prevent merge conflicts.

## Checks

```sh
task test:worktree # Exercise environment isolation, readiness, and port conflicts
task check:staged # Check staged files before committing
task check        # Run every project check
```

## Local DNS

The default domain is `example.arpa`. To route it to `127.0.0.1` on macOS,
install `dnsmasq` and add this entry to its configuration:

```conf
# /opt/homebrew/etc/dnsmasq.conf or /etc/dnsmasq.conf
address=/example.arpa/127.0.0.1
```

Add the macOS resolver:

```sh
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/arpa >/dev/null <<'EOF'
nameserver 127.0.0.1
EOF
brew services start dnsmasq
```

For a different domain, update `.env.local`, the `dnsmasq` entry, and the
resolver filename.

## License

No license is provided. Public visibility does not grant permission to use,
modify, or distribute this code.
