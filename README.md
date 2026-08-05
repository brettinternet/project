# Project

## Features

- mise
- Taskfile
- docker
- .env
- direnv
- lefthook
- Prettier
- Backlog.md work queue driven by a CAO agent loop

## Usage

### Setup

Initialize and setup dependencies.

```sh
task init
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

Replace `${DOMAIN}` with the value of the local domain, such as `example.arpa`.

<details>
<summary>Setup local DNS for ${DOMAIN} to point to 127.0.0.1.</summary>

##### dnsmasq

Install `dnsmasq`.

Ensure development DNS works by first editing `dnsmasq.conf`.

```sh
sudo vim $(brew --prefix)/etc/dnsmasq.conf
```

```conf
# /opt/homebrew/etc/dnsmasq.conf or /etc/dnsmasq.conf
address=/${DOMAIN}/127.0.0.1
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

Navigate to http://${DOMAIN}
