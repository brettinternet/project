# Project

## Features

- mise
- Taskfile
- docker
- Varlock
- lefthook
- Prettier
- cao
- backlog.md

## Usage

### Setup

Initialize and setup dependencies.

```sh
task init
```

Use Varlock's standard two-file model. Sensitivity is declared per variable in
the schema rather than implied by a filename.

| File          | Git       | Purpose                                                    |
| ------------- | --------- | ---------------------------------------------------------- |
| `.env.schema` | committed | Varlock contract, validation, and non-secret defaults      |
| `.env.local`  | ignored   | Local overrides and device-bound encrypted secret payloads |

`task init` creates `.env.local` without overwriting it and validates the
resolved environment. Project tasks do not load `.env` or `.env.local` into
their own process. Environment-dependent tasks, including Docker Compose,
resolve only `.env.schema` and `.env.local` through explicit `varlock run`
paths; Compose's implicit `.env` loading is disabled. `.env` remains ignored
only as a safeguard for legacy tooling.

Declare each secret in `.env.schema`:

```dotenv
# @sensitive @required
API_KEY=
```

Then add a prompt resolver to `.env.local` and resolve it:

```dotenv
API_KEY=varlock(prompt)
```

```sh
task setup:env:check
```

Varlock replaces the prompt with a device-bound encrypted payload. To encrypt
one value manually, run `task setup:env:encrypt` and paste the generated
reference into `.env.local`. Compose tasks already use `varlock run`; use the
generic wrapper for other secret-bearing commands:

```sh
# Interactively encrypt one value
task setup:env:encrypt
task compose:up
task setup:env:run -- some-command
task setup:env:lock
```

The pre-commit gate combines Gitleaks' generic detection with
`varlock scan --staged`, which checks staged files for configured secret
values. On macOS, resolving locally encrypted values may request Touch ID.

Compose does not pass arbitrary parent variables into containers. Map each
required value explicitly to only the service that needs it:

```yaml
services:
    app:
        environment:
            API_KEY: "${API_KEY}"
```

### Checks

Run the staged pre-commit gate before committing:

```sh
task check:staged
```

`task check` runs the full project check suite.

`task ci` is the gate: checks plus tests. A backlog task is not `Done` until it passes.

### Backlog

`backlog/` is the committed work queue, managed with [Backlog.md](https://github.com/MrLesk/Backlog.md).

```sh
task backlog       # the queue
task cao:next      # the next dependency-ready task
task standup       # what landed, what is blocked, what needs you
```

`cao/` runs that queue unattended on [CAO](https://github.com/awslabs/cli-agent-orchestrator): it
polls ready tasks, implements and independently verifies each one in its own attempt worktree, and
fast-forwards `main` only after `task ci` passes on the exact commit that will land.

```sh
task cao:install   # install CAO and the agent profiles
task cao:up        # start the local server and enable the schedules
task cao:status    # schedules, sessions, and runtime health
task cao:down      # stop this project's sessions and server
```

See [cao/README.md](cao/README.md) for the lifecycle, its safeguards, and what to change when reusing
this template on a new project.

#### DNS

The configured local domain defaults to `example.arpa`. Substitute your
`.env.local` override in the examples below when using a different value.

<details>
<summary>Setup local DNS for the configured domain to point to 127.0.0.1.</summary>

##### dnsmasq

Install `dnsmasq`.

Ensure development DNS works by first editing `dnsmasq.conf`.

```sh
sudo vim $(brew --prefix)/etc/dnsmasq.conf
```

```conf
# /opt/homebrew/etc/dnsmasq.conf or /etc/dnsmasq.conf
address=/example.arpa/127.0.0.1
resolv-file=/etc/resolver/arpa
port=53
```

Then, add the resolver:

```sh
mkdir -v /etc/resolver
sudo vim /etc/resolver/arpa
```

```sh
# /etc/resolver/arpa
nameserver 127.0.0.1
```

```sh
sudo brew services start dnsmasq
```

See also: https://gist.github.com/ogrrd/5831371

</details>

### Run

To run the demo locally, clone the repository and start the containers locally.

```sh
task up
```

Open the configured domain (default: http://example.arpa). To inspect a local
override:

```sh
task setup:env:run -- printenv DOMAIN
```
