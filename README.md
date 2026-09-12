# Project

A local development template built with Docker Compose, Bun, mise, Task,
Varlock, Lefthook, and Prettier.

## Quick start

Install [mise](https://mise.jdx.dev/), then run:

```sh
task init
task compose:services
```

Open:

- `http://pgadmin.example.arpa`
- `http://traefik.example.arpa`

Stop the services with:

```sh
task compose:services:down
```

> [!WARNING]
> This Compose setup is for local development. It publishes PostgreSQL and an
> unauthenticated Traefik dashboard, uses predictable fallback passwords, and
> logs SQL statements. Do not expose it to an untrusted network or deploy it as
> written.

## Environment

Varlock resolves committed defaults and ignored local overrides:

| File          | Git       | Contents                                  |
| ------------- | --------- | ----------------------------------------- |
| `.env.schema` | committed | Variable contract and non-secret defaults |
| `.env.local`  | ignored   | Local overrides and encrypted secrets     |

`task init` creates `.env.local` if needed and validates the resolved values.
Compose reads only these Varlock paths; its implicit `.env` loading is disabled.

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

## Checks

```sh
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
