# Deploying as a background service

## Prerequisites

1. Build the release binary (from the repo root): `swift build -c release`,
   then copy `.build/release/WyomingParakeet` into `deploy/bin/`.
2. Put your CoreML model bundle at `deploy/models/parakeet-tdt-0.6b-v3/`
   (see the main [README](../README.md) for where to get the German model,
   or [CONVERSION.md](../CONVERSION.md) to convert your own).

## Install

```bash
./install.sh
```

It will ask for your password once (`sudo`, to create
`/usr/local/wyoming-parakeet-de`). It:
- Stops any previous instance
- Copies the binary and model bundle into `/usr/local/wyoming-parakeet-de/`
- Strips quarantine + ad-hoc codesigns the binary
- Verifies all required model files landed correctly
- Installs and starts the LaunchAgent

## After installing — two things only you can set

1. **Auto-login**: System Settings → Users & Groups → Login Options → set
   this account to log in automatically. A LaunchAgent only runs once
   someone's logged in — if the machine reboots and sits at the login
   screen, the server is down until someone logs in.
2. **Sleep disabled**: System Settings → Energy → prevent the Mac from
   sleeping automatically. If it sleeps, the ANE encoder and the listening
   socket both go with it.

The first time something (Home Assistant, or `health_check.sh` from another
machine) connects, macOS's firewall may prompt to allow incoming connections
for `WyomingParakeet` — you'll need to click Allow.

## Using a non-default model

If `--models-dir` points at something other than the German primeline
fine-tune, edit `local.wyoming-parakeet-de.plist`'s `--model-name`,
`--language`, `--attribution-name` and `--attribution-url` arguments before
running `install.sh` (or after, then reload — see the note `install.sh`
prints at the end).

## Verify it's running

```bash
launchctl print gui/$(id -u)/local.wyoming-parakeet-de
./health_check.sh                       # local
./health_check.sh <lan-ip-of-host> 10300  # from another machine on the LAN
```

Logs: `/usr/local/wyoming-parakeet-de/logs/{stdout,stderr}.log`

## Wire into Home Assistant

If Home Assistant runs as a VM on the same physical machine as this server
(e.g. HAOS in a UTM VM), prefer the **LAN IP over Tailscale/VPN addresses** —
HAOS's add-on containers frequently don't have a route to VPN interfaces the
host itself has, even when the host does. Confirm with `nc -zv <ip> 10300`
from inside HA (the Terminal & SSH add-on) before configuring the
integration, if you can.

1. Home Assistant → Settings → Devices & Services → Add Integration →
   **Wyoming Protocol** → this machine's IP, port `10300`.
2. It should discover an `stt.*` entity matching the `--model-name` /
   `--language` you configured.
3. Assign it to your Assist pipeline's speech-to-text step. Duplicating the
   pipeline first (rather than editing your existing one in place) keeps a
   one-click rollback if you want to compare against whatever you were using
   before.

## Uninstall

```bash
./uninstall.sh
```

Stops and removes the LaunchAgent; optionally removes
`/usr/local/wyoming-parakeet-de` (asks first).
