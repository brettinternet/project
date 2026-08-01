# Project

## Features

- mise
- Taskfile
- docker
- .env
- direnv
- lefthook
- Prettier

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
