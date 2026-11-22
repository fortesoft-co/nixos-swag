# Keeping state

Option `services.swag.stateDir`, in every module

```nix
services.swag.stateDir = "/srv/swag";   # e.g. on a backed-up drive
```

Everything the stack has to remember then lives under one path:

| Folder | What | Mounted at |
|---|---|---|
| `lldap/` | the [directory](directory.md), every user's ID included | `/var/lib/lldap` |
| `authentik/` | [Authentik](authentik.md)'s media and certificates | `/var/lib/authentik` |
| `accounts/` | which blocks are [accounts](accounts.md)' own | `/var/lib/swag-accounts` |

Each is bind-mounted at the service's usual path, so nothing else in the
config changes. A reinstalled host with the same config and that path
comes back with the same people and the same IDs, and no app sees
strangers.

Not included: Authentik's database is in Postgres
(`services.postgresql.dataDir`), and certificates are reissued on their own.
Move or back up Postgres separately.

`directory.stateDir` and `authentik.stateDir` override one folder each.

## Turning it on for a running host

One switch. For each folder, the first time it is missing or empty:

- the old data is copied in (from `/var/lib/<name>`, or the DynamicUser
  copy in `/var/lib/private/<name>`), into a temporary folder first and
  then moved into place, so an interrupted copy is never mistaken for a
  finished one;
- the original stays where it was, for you to delete once you're happy;
- later starts copy nothing.

lldap and Authentik then run as static system users instead of
DynamicUser, since a DynamicUser's state can't sit on a bind mount.

The switch mounts the new folders. A folder whose mount changed (moving
`stateDir`, or Authentik's from a path you set before) needs a reboot to
switch over; until then the old mount keeps working.

**Moving data that's already outside `/var/lib`.** The copy only reads the
usual paths. If, say, Authentik's files already lived on the drive under
another name, move them into the new folder yourself before switching:

```sh
mkdir -p /srv/swag
mv /srv/authentik /srv/swag/authentik   # same filesystem: a rename
```

## Requirements

- The parent of `stateDir` is mounted by the host (in `fileSystems`); each
  folder's setup waits for it.
- `lldap/` and `authentik/` are owned by their service's user, fixed on
  every boot; in `accounts/`, each app's unit owns its own folder.
- Without a `stateDir` nothing changes: services use `/var/lib` as before.

## Backups

Stop the services that write while you copy (lldap's database is SQLite):
`lldap.service`, `authentik.service`, `authentik-worker.service`, and
Postgres for Authentik's database. Restoring is the reverse: put the folders
back under `stateDir` before the first boot.

| Option | Default | |
|---|---|---|
| `services.swag.stateDir` | `null` | Where the stack keeps its state; `null` = the usual `/var/lib` paths. |
