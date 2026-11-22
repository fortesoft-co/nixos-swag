# directory

`nixosModules.directory` · options under `services.swag.directory`

The user directory: [lldap](https://github.com/lldap/lldap) with users and
groups declared in config. It belongs to no app and no identity provider.
[authentik](authentik.md) syncs from it, LDAP-only apps can bind to it, and
[accounts](accounts.md) reads its group files. Replace any of them and the
people stay.

```nix
services.swag.directory = {
  enable = true;
  baseDn = "dc=example,dc=com";
  adminPasswordFile = "/run/secrets/lldap-admin";
  dashboard.tls = true;                       # https://ldap.lan.example.com
  groups.family = { };
  users.alice = {
    email = "alice@example.com";
    displayName = "Alice";
    groups = [ "family" ];
    initialPasswordFile = "/run/secrets/alice-initial";
  };
};
```

`swag-directory-provision.service` creates what's declared through lldap's
API, after every start of lldap and on every switch.

## What config owns, and what it doesn't

| | Config owns it | Left to people |
|---|---|---|
| Admin password | reset to `adminPasswordFile` on every start | |
| A user's email | reset when it differs | |
| A user's display name | when set | when `null` |
| Group memberships | the listed ones, added back if missing | others, added by hand, stay |
| A user's password | `passwordFile`: set whenever it doesn't bind | `initialPasswordFile`: set once at creation, then theirs |
| Users and groups not in config | | left alone |
| A user removed from config | | **not** deleted; delete them in the admin UI |

So declared passwords are *initial* passwords. Once alice changes hers, in
lldap or through Authentik's write-back, a deploy never touches it again.
`passwordFile` is for service accounts other modules bind as, such as
Authentik's own.

The admin UI is on `ldap.<internalDomain>` when [dns](dns.md) and
[web](web.md) are on the host (`dashboard.domain` to choose another name),
and the admin password is entered there, so turn on `dashboard.tls`.

## Group files

`groupMembers` (`/run/swag-directory/groups`) has one file per declared
group, one line per member:

```
3f2b8c1e-… alice
9a07d5aa-… bob
```

The first field is the account's directory ID (`entryUUID`), which is also
the ID Authentik sends apps. `swag-directory-groups.service` writes them
after provisioning and every 10 minutes, replacing a file only when it
changed, so a path unit watching it fires only on real changes. They hold
usernames and IDs, nothing secret (mode 0644). [accounts](accounts.md)
uses them to block people who left a group.

## Enrollment endpoint

`enrollment.enable` opens a local socket through which a sign-up front end
creates directory accounts. [authentik](authentik.md#inviting-people) turns
it on for you when its own enrollment is on; you only set it directly to
build a different front end.

- One instance per connection, holding the lldap admin password as a
  systemd credential. Only members of `clientGroup` can connect.
- It grants only `grantableGroups`, and never lldap's admin groups.
- It checks the username and email are free and the password is at least
  `minPasswordLength` before writing anything, and never logs the password.
- Names listed in `heldNamesDir` count as taken (see below).

### Held names

`enrollment.heldNamesDir` (`/run/swag-directory/held-names`) is where apps
list the usernames they still have accounts under, one file per app, one
name per line. Sign-up refuses those names, so a newcomer can't take over
an old account an app still keeps under that name. [accounts](accounts.md)
writes these files for you. A name is free again once every app has let go
of it, which is an admin step: delete the old account in the app.

## Keeping the directory

The directory holds every user's ID. Lose it and everyone gets a new ID on
the next sync, and apps that know people by ID see strangers. Back up
`stateDir` (lldap's database is SQLite: stop `lldap.service` while you copy
it), or put it somewhere that outlives the host with
[`services.swag.stateDir`](state.md).

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | Run lldap and provision it. |
| `baseDn` | required | LDAP base DN; users under `ou=people`, groups under `ou=groups`. Changing it means re-binding every client. |
| `adminUsername` | `"admin"` | lldap's built-in admin. |
| `adminPasswordFile` | required | Runtime file with the admin password. Config owns it. |
| `jwtSecretFile` | `null` | Runtime file with lldap's JWT secret; `null` = lldap generates one and keeps it. |
| `stateDir` | `/var/lib/lldap` | Where the database lives; follows [`services.swag.stateDir`](state.md). |
| `dashboard.domain` | `ldap.<internalDomain>` | Admin UI vhost; `null` without dns = no vhost. |
| `dashboard.tls` | `false` | Serve the admin UI over TLS. Recommended. |
| `ldap.address` | `"127.0.0.1"` | LDAP listener. `0.0.0.0` to serve the LAN. |
| `ldap.port` | `3890` | LDAP port. |
| `http.address` | `"127.0.0.1"` | Web UI and API listener. |
| `http.port` | `17170` | Web UI and API port. |
| `groups` | `{ }` | Groups to create. lldap's built-ins need no entry. |
| `users` | `{ }` | Users to create, keyed by username. Other modules may add entries. |
| `users.<name>.email` | required | Email; unique, and OIDC apps match people by it. Config owns it. |
| `users.<name>.displayName` | `null` | Display name; `null` = leave it. |
| `users.<name>.groups` | `[ ]` | Groups to add the user to. Additive. |
| `users.<name>.initialPasswordFile` | `null` | First password, set only at creation. |
| `users.<name>.passwordFile` | `null` | Config-owned password, for service accounts. Not with `initialPasswordFile`. |
| `groupMembers` | read-only | Directory of group files (see above). |
| `enrollment.enable` | `false` | Open the enrollment socket. |
| `enrollment.socket` | read-only | `/run/swag-directory-enroll.sock`. |
| `enrollment.clientGroup` | `"swag-directory-enroll-clients"` | Unix group allowed to connect. |
| `enrollment.grantableGroups` | `[ ]` | Groups an enrollment may give; must be declared. |
| `enrollment.minPasswordLength` | `12` | Shortest password accepted. |
| `enrollment.heldNamesDir` | read-only | Directory of held-name files, one per app. |
