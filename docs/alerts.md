# alerts

`nixosModules.alerts` · options under `services.swag.alerts`

A message when something breaks: a unit fails, and you hear about it once,
with the failed run's last journal lines. While it keeps failing you hear
nothing more; when it works again you get one "recovered". Messages go
through [Apprise](https://github.com/caronc/apprise), so any service it
speaks works: ntfy, Gotify, Matrix, email, Discord, Telegram, Pushover and
about a hundred more.

```nix
services.swag.alerts = {
  enable = true;
  urlsFile = "/run/secrets/alert-urls";
};
```

```
# /run/secrets/alert-urls: one Apprise URL per line
ntfys://tk_yourtoken@ntfy.example.com/gateway
```

What an alert looks like:

```
gateway: authentik-directory-prune.service failed
authentik-directory-prune.service failed (exit-code) at 2026-11-22 03:10:02 UTC.

2026-11-22T03:10:02+0000 gateway authentik-directory-prune-start[2214]: source directory: 12 users are gone
from the directory, more than the limit of 5 per run; removing none. Check the directory, ...
```

## What's watched

- **`scope = "swag"`** (the default): the stack's own units on this host:
  the directory and its provisioning, Authentik and its setup units, app
  accounts, certificates, nginx, dnsmasq, the tunnel, and state setup.
  Add your own with `units`, e.g. a backup job.
- **`scope = "all"`**: every service on the host, including the ones you
  write, with no per-unit config.

Under the hood, each watched unit gets a drop-in with
`OnFailure=swag-alert-failed@%N.service` and
`OnSuccess=swag-alert-ok@%N.service` (with `"all"`, one drop-in for every
service). The alert units clear both for themselves, so an alert that
fails never sets off another. Check what a unit has with
`systemctl show -p OnFailure <unit>`.

## How it behaves

- **Once per failing streak.** A failure marks the unit as failing in
  `/run/swag-alerts`; failures while it's marked send nothing; the first
  success sends "recovered" and clears the mark. The marks are in `/run`,
  so a unit still failing after a reboot is reported once more.
- **Retried.** Delivery is tried again for about eight minutes, so a
  failure early in boot still gets out once the network is up. One that
  still can't be delivered leaves no mark, so the next failure tries again;
  the alert unit fails, and the journal says why
  (`journalctl -u 'swag-alert-*'`).
- **Cheap when all is well.** With `scope = "all"`, every service that
  finishes cleanly starts `swag-alert-ok@`, which checks for a mark and
  exits.

## Keep the alert path outside what it watches

If your ntfy (or Matrix, or mail server) runs on the same host behind
Authentik's forward auth, and Authentik is what broke, the alert can't get
out. Point Apprise at something that doesn't depend on the stack: a
self-hosted service the host reaches directly (on loopback or the LAN,
with a token), or one off the host, which is a trade-off of its own.

Alerts can't tell you the host itself is down: nothing on it runs. For
that, have the host ping an outside check regularly and let that side
alert when the pings stop (a dead man's switch; Healthchecks and Uptime
Kuma are self-hostable).

## Secrets

Apprise URLs often carry a token, so `urlsFile` is a runtime file, root
only. It reaches the alert units as a systemd credential, never a command
line or the Nix store. The units run as the `swag-alerts` system user, in
the `systemd-journal` group to read the failed run's lines. Journal lines
are sent as they are: the swag modules never log secrets, but a unit you
add with `units` or `scope = "all"` might, so lower `journalLines` (0 sends
none) if that matters.

## Your own notifier

`command` gets each alert as one JSON object on stdin, alongside Apprise or
instead of it:

```json
{"event": "failed", "host": "gateway", "unit": "nginx.service",
 "result": "exit-code", "since": "2026-11-22 03:10:02 UTC",
 "at": "2026-11-22 03:10:02 UTC", "lines": ["..."]}
```

`event` is `"failed"` or `"recovered"`. Exit 0 means delivered. Give it
credentials through `serviceConfig.LoadCredential`.

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | Send alerts. Needs `urlsFile` or `command`. |
| `urlsFile` | `null` | Runtime file of Apprise URLs, one per line. |
| `command` | `null` | A command that gets each alert as JSON on stdin. |
| `scope` | `"swag"` | `"swag"`: the stack's units plus `units`; `"all"`: every service. |
| `units` | `[ ]` | More units to watch with `"swag"`, full names (`backup.service`). |
| `journalLines` | `20` | Journal lines per alert, from the failed run. |
| `serviceConfig` | `{ }` | Merged into the alert units, e.g. credentials for `command`. |
