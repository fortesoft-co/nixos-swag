# accounts

`nixosModules.accounts` · options under `services.swag.accounts.<name>`

[Authentik](authentik.md) decides who can sign in, but most apps keep
accounts of their own, and those have other ways in: API tokens, SSH keys,
app passwords, open sessions. This module keeps an app's accounts in line
with the [directory](directory.md), one unit per app
(`swag-accounts-<name>`), every 10 minutes and whenever group membership or
the subject map changes.

swag knows no app. Each app is reached through an **adapter**: the built-in
SQL adapter with the app's queries in config, or a command of your own. The
adapter runs in the same unit as the policy, so the app's credentials stay
there and swag holds none.

## What a run does

In this order:

1. **Old IDs → linked.** An account known by an old ID (from
   [the subject map](authentik.md#user-ids-apps-see)) is linked to the new
   one, keeping the old. If another account already has the new ID,
   nothing is moved, both are named in the journal, and the run fails.
2. **Left the group → blocked.** Accounts of people outside `accessGroup`
   are blocked, never deleted, and their sessions revoked. When they're
   back, the block is lifted, but only a block this module set: one an
   admin set stays. An app that can't block has its sessions revoked
   instead, if it can, and Authentik's gate does the rest.
3. **Held names → published.** Every name the app holds goes to
   [`heldNamesDir`](directory.md#held-names), so sign-up refuses it.

## Careful by default

- **New apps start in `dryRun`**: the journal says what would be blocked,
  unblocked or linked, and nothing changes in the app. A warning at deploy
  reminds you. Read `journalctl -u swag-accounts-<name>` once, then set
  `dryRun = false`. Held names are published either way.
- **Accounts the identity provider doesn't sign in** (local, service, bot:
  any account with no subjects) are never touched.
- **Nothing to compare with, nothing changes.** No members file yet, or a
  subject map that's configured but not written yet, and steps 1 and 2 do
  nothing. Without that guard, a missing map would mean comparing
  Authentik's hashed IDs with directory IDs and blocking everyone.
- **A run that would block more than `maxBlocksPerRun` blocks none** and
  fails. A group that suddenly lost most of its members is more likely a
  mistake.
- **A failed step doesn't stop the others**, and the unit fails at the end
  so you notice. Names are published even when the run failed.

Which blocks are its own is kept in
`/var/lib/swag-accounts/<name>/state.json`; that path follows
[`services.swag.stateDir`](state.md).

## SQL apps

For an app with its accounts in SQLite or Postgres, give the queries:

```nix
services.swag.accounts.wiki = {
  accessGroup = "members";
  adapter.sql = {
    identity = "subject";   # subjects are directory IDs ("name": usernames)
    database = { type = "sqlite3"; path = "/var/lib/wiki/wiki.db"; };
    queries = {
      # (id, name, subject, blocked), one row per ID sign-in finds it by
      list = "SELECT id, name, oidc_sub, disabled FROM users";
      names = "SELECT name FROM users";
      block = "UPDATE users SET disabled = 1 WHERE id = :id";
      unblock = "UPDATE users SET disabled = 0 WHERE id = :id";
      revoke = "DELETE FROM sessions WHERE user_id = :id";
    };
  };
  serviceConfig = { User = "wiki"; ReadWritePaths = [ "/var/lib/wiki" ]; };
  after = [ "wiki.service" ];
  dryRun = false;  # after reading the journal once
};
```

- **`list`** returns one row per subject the app's sign-in finds the
  account by: an account linked to two IDs is two rows. An account with
  none is one row with `NULL` as subject, and is left alone.
- **`block`, `unblock`, `revoke`, `link`** are lists of statements, or one
  string. Leave one empty and that op isn't offered. `:id` and `:subject`
  are bound as parameters, never pasted in.
- **`block` must be reversible and close every way in** that doesn't pass
  through the identity provider: tokens, keys, app passwords. Never a
  delete.
- **Postgres** works the same: `type = "postgres"`, `user` and `name`,
  over the local socket with peer authentication, so the unit's `User` is
  the role and there is no password.

`serviceConfig` is merged into the unit: the user that can reach the
database, `ReadWritePaths` for SQLite, `LoadCredential` for anything
secret. By default the unit runs as the `swag-accounts` system user in a
hardened sandbox.

## Any other app: an adapter

An adapter is a command set as `adapter.command` (a string, or a list for
its first arguments). It is called as `<command> <op> [args...]` and
answers with one JSON object on stdout:

| Op | Output | |
|---|---|---|
| `describe` | `{"protocol": 1, "identity": "subject"\|"name", "ops": [...]}` | required |
| `list` | `{"accounts": [{"id", "name", "subjects": [...], "blocked"}]}` | required |
| `names` | `{"names": [...]}` | required |
| `block <id>`, `unblock <id>`, `revoke <id>` | `{}` | optional |
| `link <id> <subject>` | `{}` | optional |

- `ops` lists the optional ops it supports.
- `identity` says what `subjects` are: directory IDs (`subject`, for apps
  that find people by the OIDC `sub`) or usernames (`name`, for apps that
  find them by name). Usernames are compared with the members file's
  second column.
- Exit 0 means done, including "already so". Logs go to stderr.

A sketch, for an app with a REST admin API:

```sh
#!/bin/sh
key=$(cat "$CREDENTIALS_DIRECTORY/api-key")   # LoadCredential, below
case "$1" in
  describe) echo '{"protocol": 1, "identity": "name", "ops": ["block", "unblock", "revoke"]}' ;;
  list)     curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:8000/admin/users \
              | jq '{accounts: [.[] | {id, name, subjects: [.name], blocked: .disabled}]}' ;;
  names)    curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:8000/admin/users \
              | jq '{names: [.[].name]}' ;;
  block)    curl -fsS -X POST -H "Authorization: Bearer $key" http://127.0.0.1:8000/admin/users/"$2"/disable && echo '{}' ;;
  unblock)  curl -fsS -X POST -H "Authorization: Bearer $key" http://127.0.0.1:8000/admin/users/"$2"/enable && echo '{}' ;;
  revoke)   curl -fsS -X DELETE -H "Authorization: Bearer $key" http://127.0.0.1:8000/admin/users/"$2"/sessions && echo '{}' ;;
  *) exit 1 ;;
esac
```

```nix
services.swag.accounts.gallery = {
  accessGroup = "family";
  adapter.command = "${galleryAdapter}";   # pkgs.writeShellScript, with curl and jq on its path
  serviceConfig.LoadCredential = [ "api-key:/run/secrets/gallery-api-key" ];
  after = [ "gallery.service" ];
};
```

Adapters for specific apps don't live in swag; keep them next to the app's
module.

## Without a group

Leave `accessGroup` unset and the unit only publishes held names: enough
for an app whose accounts you never want blocked, but whose names a
newcomer shouldn't take.

## Options

All under `services.swag.accounts.<name>`; `<name>` is the unit and file
name (letters, digits, `_`, `-`).

| Option | Default | |
|---|---|---|
| `accessGroup` | `null` | Directory group whose members may use the app. `null` = only publish names. |
| `membersFile` | the directory's group file | `<ID> <username>` lines; defaults to [`groupMembers`](directory.md#group-files)`/<accessGroup>`. |
| `subjectMap` | Authentik's, with a directory source | `<old ID> <new ID>` lines; `null` = IDs never change. |
| `heldNamesFile` | `<heldNamesDir>/<name>` | Where names are published; `null` = don't. |
| `adapter.command` | `null` | Your adapter. Set this or `adapter.sql`. |
| `adapter.sql.identity` | required | `"subject"` or `"name"`: what the subjects in `list` are. |
| `adapter.sql.database.type` | required | `"sqlite3"` or `"postgres"`. |
| `adapter.sql.database.path` | `null` | sqlite3: the database file. |
| `adapter.sql.database.host` | `"/run/postgresql"` | postgres: socket directory or host. |
| `adapter.sql.database.port` | `5432` | postgres: port. |
| `adapter.sql.database.user` | `null` | postgres: role, usually the unit's user. |
| `adapter.sql.database.name` | `null` | postgres: database. |
| `adapter.sql.database.psql` | the host's `psql` | postgres: client binary. |
| `adapter.sql.queries.list` | required | Rows of (id, name, subject, blocked). |
| `adapter.sql.queries.names` | required | Rows of (name): every name a newcomer must not take. |
| `adapter.sql.queries.block` | `[ ]` | Block `:id`, reversibly. |
| `adapter.sql.queries.unblock` | `[ ]` | Undo `block` for `:id`. |
| `adapter.sql.queries.revoke` | `[ ]` | End `:id`'s sessions and tokens. |
| `adapter.sql.queries.link` | `[ ]` | Make `:id` answer to `:subject` too. |
| `serviceConfig` | `{ }` | Merged into the unit: `User`, `LoadCredential`, `ReadWritePaths`. |
| `after` | `[ ]` | Units the app needs up first. |
| `interval` | `"10min"` | How often to run, besides on changes. |
| `maxBlocksPerRun` | `5` | Most blocks per run; more = none, and the run fails. |
| `dryRun` | `true` | Log what would change, change nothing. |
