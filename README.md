# host-route

Send an explicit list of hostnames out an existing split-tunnel VPN, and leave every other destination on the kernel route that is already the default.

A VPN profile that only installs its own prefixes does not change the default route. A name that resolves to a shared address, such as a CDN anycast address, therefore leaves from the normal path. Putting that CDN's address ranges on the tunnel would send unrelated sites through it as well. This program reads the TLS or QUIC server name and steers only the names you list.

## Requirements

Install these with your distribution's package manager before `install.sh`. The script checks that the commands are on `PATH` and stops if one is missing. It does not install them.

| Command | Project |
| --- | --- |
| `sing-box` | [sing-box](https://sing-box.sagernet.org/installation/package-manager/) |
| `python3` | Python 3 |
| `ip` | iproute2 |
| `systemctl`, `systemd-notify` | systemd |
| `nmcli` | NetworkManager |
| `dig` | BIND |
| `curl` | curl |

The VPN profile named in `/etc/host-route/config` must be connected before `start`. root is required for the TUN device and the policy rules.

sing-box is GPL-3.0. The scripts in this repository are MIT; see `LICENSE`.

## Install

```bash
git clone https://github.com/YOUR_USER/host-route.git
cd host-route
sudo ./install.sh
```

Set the VPN profile name, then start:

```bash
sudoedit /etc/host-route/config
sudo host-route start
```

`install.sh` is safe to run again. It replaces the program and the systemd unit. It creates `/etc/host-route/hosts.txt` and `/etc/host-route/config` only when those files are absent.

| Path | What it is |
| --- | --- |
| `/usr/local/bin/host-route` | The command |
| `/usr/bin/host-route` | Symlink, added when `sudo` does not search `/usr/local/bin` |
| `/usr/bin/sing-box` | From the `sing-box` package |
| `/etc/host-route/hosts.txt` | The list you edit |
| `/etc/host-route/config` | `connection=` is the NetworkManager profile |
| `/etc/systemd/system/host-route.service` | Supervises the route |
| `/run/host-route/` | Runtime files, created when the route is started |

## Why this does not enable sing-box.service

The `sing-box` package installs `sing-box.service`. That unit runs as the user `sing-box`, starts at boot after the network is online, and loads every config file in `/etc/sing-box`. It restarts itself after a failure.

This route cannot use that unit:

- The config is generated when a specific VPN profile has an address, and the interface name is part of the config. At boot that profile is often still down.
- Listed names are policy-routed with a firewall mark, DNS is kept on the main table, and firewalld has to trust the capture interface. None of that is in the sing-box config, so a service that only execs `sing-box` would leave those rules out, or leave them behind after a crash.
- `Restart=on-failure` would put the capture rules back after a start that had just rolled them back.

`install.sh` leaves `sing-box.service` disabled when it is not already running. `host-route.service` is the supervisor. It runs as root, notifies systemd only after DNS and HTTPS through the default path succeed, and does not restart on failure. `sudo host-route start` is `systemctl start host-route`. Logs from the supervisor are in the journal (`journalctl -u host-route`). sing-box's own log is `/run/host-route/sing-box.log`.

The unit is not enabled for boot. Start it when the VPN is up, or install the dispatcher below.

## Host list

Edit `/etc/host-route/hosts.txt`, then reload:

```bash
sudoedit /etc/host-route/hosts.txt
sudo host-route reload
```

One hostname per line. Blank lines and `#` comments are ignored. A line that starts with `*.` matches that name and its subdomains.

```text
app.example.com
*.corp.example.com
```

The VPN profile name is `connection=` in `/etc/host-route/config`. Override it for one command with `HOST_ROUTE_CONNECTION`.

## Commands

```bash
sudo host-route start
sudo host-route status
sudo host-route reload
sudo host-route stop
host-route check
```

`check` validates the host list and the generated sing-box config without changing routes. `start`, `stop`, `reload`, and `run` need root.

To bring the route up and down with the VPN:

```bash
sudo host-route install-dispatcher
```

That writes `/etc/NetworkManager/dispatcher.d/90-host-route`. The script reads `connection=` when the VPN changes, so editing the config does not require installing it again. Remove it with `sudo host-route uninstall-dispatcher`.

Set `HOST_ROUTE_LOG=info` on the start command when you need to see which outbound a connection used (`tunnel` or `direct`).

## What the route does

Applications are delivered to a local TUN named `hostroute`. sing-box reads the server name, then dials the real destination:

- A listed name is marked and sent out the configured VPN.
- Any other name is marked and handed back to the kernel. It follows the default route that is already in place, whether that is the physical network or another VPN that owns the default route.
- Addresses that already have a more specific kernel route, including the VPN's own prefixes and the local LAN, never enter `hostroute`.

## Limits

The match is the TLS or QUIC server name. A connection that does not present one stays on the default path. This capture is IPv4. Ping is not steered.

Traffic that was going to follow the default route takes a short pass through `hostroute` so the name can be read, then goes back out that same default route.

firewalld's default zone rejects packets that arrive on an interface it does not know. The handshake comes back on `hostroute` addressed to this host, so while the route is up that interface is placed in the trusted zone. Stop removes it. A host without firewalld is unchanged.

A second VPN that installs its own `ip rule` at a priority number below 9000 takes packets before the name can be read. A VPN that only changes the default route is followed for every name that is not on the list.

## Uninstall

```bash
sudo ./install.sh uninstall
```

`/etc/host-route/` is kept. To remove it as well:

```bash
sudo ./install.sh uninstall --purge
```

sing-box stays installed. Remove that package with your package manager when nothing else uses it.

## Files in this repository

| File | Purpose |
| --- | --- |
| `host-route` | The program |
| `host-route.service` | systemd unit installed to `/etc/systemd/system` |
| `install.sh` | System install and uninstall |
| `hosts.txt` | Seed host list copied to `/etc` on first install |
| `config` | Seed `connection=` copied to `/etc` on first install |
| `LICENSE` | MIT license for these scripts |
