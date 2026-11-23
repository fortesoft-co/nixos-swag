# authentik

`nixosModules.authentik` · options under `services.swag.authentik`

Single sign-on with [Authentik](https://goauthentik.io), configured from
Nix: OIDC clients, forward auth for apps without a login, users and groups
synced from the [directory](directory.md), invitations, enforced MFA and a
public login. Nothing needs the admin UI. It builds on
[authentik-nix](https://github.com/nix-community/authentik-nix), which the
flake brings in.

```nix
services.swag.authentik = {
  enable = true;
  secrets.AUTHENTIK_SECRET_KEY = "/run/secrets/authentik-secret-key";
  bootstrap = {
    email = "admin@example.com";
    passwordFile = "/run/secrets/authentik-admin";
    tokenFile = "/run/secrets/authentik-api-token";
  };
  dashboard.tls = true;                 # https://auth.lan.example.com
  directorySource = {
    enable = true;
    bindPasswordFile = "/run/secrets/authentik-bind";
  };
  mfa.enforce = true;
};
```

- [Setup and secrets](#setup-and-secrets)
- [Apps with OIDC](#apps-with-oidc)
- [Apps without a login](#apps-without-a-login)
- [Users from the directory](#users-from-the-directory)
- [User IDs apps see](#user-ids-apps-see)
- [Inviting people](#inviting-people)
- [MFA](#mfa)
- [Going public](#going-public)
- [Anything else](#anything-else)
- [Options](#options)

## Setup and secrets

Every secret is a runtime file. `secrets` maps the environment variables
Authentik reads to files; the module assembles them into a root-only
environment file at boot. `AUTHENTIK_SECRET_KEY` is required:

```sh
openssl rand -base64 60 > authentik-secret-key
```

`bootstrap` seeds `akadmin` on the first start, so there is no `/setup`
page to race. It is read only while no admin exists; afterwards akadmin is
the break-glass account, not a daily one. `passwordHashFile` takes a hash
(`ak hash_password`) instead of the password. `tokenFile` gives akadmin an
API token for scripts.

The database is a local Postgres created for you (`database.create`). Its
data is in `services.postgresql.dataDir`, which this module doesn't move:
back it up or relocate it on its own. Authentik's files (media,
certificates) are in `stateDir`, which follows
[`services.swag.stateDir`](state.md).

The admin UI is on `auth.<internalDomain>` when [dns](dns.md) and
[web](web.md) are on the host. It carries logins, so turn on
`dashboard.tls`. `url`, the base URL apps are given, follows it.

## Apps with OIDC

```nix
services.swag.authentik.oidcClients.wiki = {
  name = "Wiki";
  clientSecretFile = "/run/secrets/wiki-oidc";   # the app reads the same file
  redirectUris = [ "https://wiki.lan.example.com/oauth/callback" ];
  launchUrl = "https://wiki.lan.example.com/";
  groups = [ "family" ];
};
```

The client gets a confidential OAuth2 provider (authorization code and
refresh token grants; `openid`, `email` and `profile` scopes) and an
application in the launcher, through a generated blueprint. Only members of
`groups` pass (empty = everyone). `authentik-provider-secret-setup` keeps
the provider's secret equal to the file, so the app and Authentik never
disagree. Point the app at:

```
${config.services.swag.authentik.url}/application/o/wiki/.well-known/openid-configuration
```

For an app on another host, give it the same secret there. Writing the
client into an app's own config is app glue: it belongs in a small module
next to the app.

`providerSecrets` does the same secret-pinning for a provider you made
yourself (in a blueprint or the UI), keyed by its name.

## Apps without a login

Put them behind forward auth. The app's vhost gets an nginx `auth_request`
gate, so nothing reaches the app before the person signs in:

```nix
services.swag.web.vhosts."dashboard.lan.example.com" = { port = 3000; tls = true; };

services.swag.authentik = {
  outposts.proxy = {
    enable = true;
    tokenKeyFile = "/run/secrets/authentik-proxy-token";   # openssl rand -hex 32
  };
  apps.dashboard.host = "https://dashboard.lan.example.com";
};
```

Each app gets a proxy provider and an application, assigned to the proxy
outpost. `authentik-outpost-setup` creates the outpost and sets its token
from the file on every boot, so a rebuilt database needs nothing by hand.
`mode = "proxy"` makes the outpost itself the proxy (to `internalHost`)
instead of nginx.

The LDAP outpost (`outposts.ldap`) does the same for apps that only speak
LDAP but should see Authentik's users. Apps that can bind to the
[directory](directory.md) itself don't need it.

## Users from the directory

`directorySource.enable` syncs users and groups from LDAP into Authentik.
With [directory](directory.md) on the same host it is wired for you: the
URL and base DN, and Authentik's own bind account, declared in the
directory with `bindPasswordFile` as its password.

- **Passwords go back.** With `passwordWriteback`, a password changed in
  Authentik is written to the directory, so it holds everywhere. The bind
  account is in `lldap_password_manager` for that (`lldap_strict_readonly`
  without write-back).
- **Removed there, removed here.** Delete someone in lldap and within
  `removeDeletedUsers.interval` they're removed from Authentik as well:
  sessions, MFA devices, consents. A run that would remove more than
  `maxPerRun` removes none and fails `authentik-directory-prune.service`, as
  does a search that fails or finds nobody. Superusers are never removed.
  Apps that keep their own copy of the account keep it, data and all, but
  no longer let the person sign in (see [accounts](accounts.md) for the
  other ways in).
- **Locking out, keeping the account:** deactivate the user in Authentik.
- **Deleting a directory user in Authentik is refused** (through swag's
  nginx), with a message saying why: the directory still has them, and the
  sync would bring them back without their MFA devices. Users that don't
  come from the directory can be deleted as usual.
- **Rebuilding someone's Authentik side:** `swag-authentik-reset-user
  <name>` on the host deletes it on purpose and resyncs. Same directory ID
  and password, so apps still know them; they set up MFA again.

`users` declares Authentik-only users instead (service accounts, or a host
without a directory), with an optional `passwordFile` that
`authentik-user-password-setup` keeps in sync.

## User IDs apps see

OIDC apps know each person by the ID Authentik sends (`sub`). With the
directory, that is the directory account's own ID (`idAttribute`,
`entryUUID`), stored on the Authentik user by the sync:

- **It survives Authentik.** A user deleted in Authentik and brought back
  by the sync has the same ID, so apps still recognize them.
- **A reused username is a new person.** A new directory account gets a new
  ID even under an old name, so an app matching people by ID never hands
  it the previous owner's account.
- **Local users keep Authentik's ID.** akadmin and other users that don't
  come from the directory get Authentik's own hashed ID.

Apps that already knew people by Authentik's hashed ID (a directory added
later, or an existing install) learn the new one from
`directorySource.subjectMap`: a file of `<old ID> <new ID>` lines, written
from the directory before the sync switches anyone over and refreshed every
10 minutes. [accounts](accounts.md) watches it and links each account to
its new ID, keeping the old one, so nobody's sign-in breaks in the switch.

## Inviting people

```nix
services.swag.authentik.enrollment = {
  enable = true;
  grantableGroups = [ "git-users" ];   # what an invitation may hand out
};
services.swag.directory.users.alice.groups = [ "members" ];   # existing users
```

Enrollment needs the directory and `directorySource` on the same host: new
accounts are created in the directory, not in Authentik, and reach
Authentik through the sync.

- **Invitations.** In the admin UI, *Directory → Invitations*: pick the
  `swag-enrollment` flow, optionally with fixed data
  `{"groups": ["git-users"]}`, and send the link. The person fills in
  username, name, email and password. The form checks the username and
  email are free before anything is written. The account lands in
  `members` plus the invitation's groups and syncs within seconds (a few
  minutes if a sync was already running). No email server needed.
- **Who can log in.** Only members of `accessGroup` (`members`). Everyone
  else is told their account is waiting for approval; superusers are
  exempt. Put existing users in it before turning this on.
- **Open sign-up** (`signup = true`) adds a *Sign up* link to the login
  page. Those accounts get no groups. Approve someone by adding them to
  `members` in lldap's admin UI; reject them by deleting the account.
- **Names apps still hold are taken.** See
  [held names](directory.md#held-names).
- **Safe by construction.** Only the Authentik server can open the
  directory's enrollment socket, which refuses any group outside
  `grantableGroups` (and lldap's admin groups always) and never logs or
  stores the password.

## MFA

`mfa.enforce` requires a second factor on every login through the default
flow. People without one are walked through enrolling one of `methods`
(passkeys and security keys, authenticator apps) at their next login.
Recovery codes are accepted as a second factor (`recoveryCodes`); people
create them in their settings once they have another. API tokens are
unaffected.

## Going public

A public login takes Cloudflare credentials for the tunnel and a public
name. Your domain's DNS has to be on Cloudflare.

```nix
services.cloudflared-tunnel = {
  enable = true;
  accountIdFile = "/run/secrets/cloudflare-account-id";
  apiTokenFile = "/run/secrets/cloudflare-api-token";
};

services.swag.authentik.dashboard.publicDomain = "auth.example.com";
```

The token needs *Account › Cloudflare Tunnel › Edit*, *Zone › DNS › Edit*
and *Zone › Zone › Read*. It can be the one you gave [web](web.md) for
certificates, or a separate one.

On the next deploy, with no dashboard visits:

1. **The tunnel sets itself up.**
   [nixos-cloudflared](https://github.com/fortesoft-co/nixos-cloudflared)
   finds the tunnel named after the host, or creates it, keeps its token
   root-only and hands it to `cloudflared` as a systemd credential.
2. **Authentik joins it** as a [public site](web.md#public-sites):
   `auth.example.com` is added to the tunnel's ingress, pointed at nginx
   over HTTPS.
3. **The public record appears**: a proxied CNAME to the tunnel, in
   whichever of your zones holds the name.
4. **The LAN takes the short way.** [dns](dns.md) answers
   `auth.example.com` with this host, and nginx serves both paths with the
   same certificate.

```
                     ┌─ outside ─ Cloudflare ─ tunnel ─┐
browser ─ auth.example.com                             ├─ nginx (TLS) ─ Authentik
                     └─ LAN ─ dnsmasq says "this host" ┘
```

- **One login name everywhere.** `auth.lan.example.com` redirects to
  `auth.example.com`, because passkeys are bound to the name they were
  registered on.
- **Admin stays home.** Requests through the tunnel carry Cloudflare's
  `CF-Connecting-IP`, which clients can't set, and can't load
  `/if/admin/`. Login, user settings and app sign-ins work from anywhere.
  nginx takes the client address from that header, so Authentik's logs and
  reputation checks see real IPs.
- **Clients follow.** `url` becomes `https://auth.example.com`.
- **No inbound ports**: the tunnel connects out.

Turn on `mfa.enforce` before going public.

## Anything else

- **`settings`** is Authentik's whole `config.yml`, merged over the typed
  shorthands (`email`, `database`). Never put secrets there.
- **`environment`** sets non-secret environment variables; secrets go in
  `secrets`, or a ready-made `environmentFile` when `secrets` is empty.
- **`blueprints`** adds your own blueprints, as Nix attrsets (checked at
  build) or YAML files. Each needs the label
  `blueprints.goauthentik.io/instantiate: "true"` to apply.
- **`email`** configures SMTP; the password goes in
  `secrets.AUTHENTIK_EMAIL__PASSWORD`.

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | Run Authentik (server, worker, migrations). |
| `settings` | `{ }` | Freeform `config.yml`, wins over the shorthands. No secrets. |
| `email` | `{ }` | SMTP shorthand for `settings.email`; more keys are accepted as-is. |
| `email.host` | `"localhost"` | SMTP host. |
| `email.port` | `25` | SMTP port. |
| `email.username` | `null` | SMTP user; the password goes in `secrets`. |
| `email.use_tls` | `false` | STARTTLS. |
| `email.use_ssl` | `false` | Implicit TLS. |
| `email.from` | `"authentik@localhost"` | From address. |
| `database` | `{ }` | Database shorthand. |
| `database.create` | `true` | A local Postgres database and user; `false` = configure `settings.postgresql` yourself. |
| `secrets` | `{ }` | Env var → runtime file. Needs `AUTHENTIK_SECRET_KEY`. |
| `environment` | `{ }` | Non-secret env vars. |
| `environmentFile` | `null` | Your own env file, used when `secrets` is empty. |
| `stateDir` | `/var/lib/authentik` | Media and certificates; follows [`services.swag.stateDir`](state.md). |
| `openFirewall` | `true` | Open 3389 when the LDAP outpost is on. |
| `bootstrap` | `{ }` | akadmin, seeded on the first start. |
| `bootstrap.email` | `null` | akadmin's email. |
| `bootstrap.passwordFile` | `null` | akadmin's password. |
| `bootstrap.passwordHashFile` | `null` | akadmin's password hash, instead. |
| `bootstrap.tokenFile` | `null` | An API token for akadmin. |
| `dashboard` | `{ }` | The admin UI and login. |
| `dashboard.domain` | `auth.<internalDomain>` | Local vhost. |
| `dashboard.tls` | `false` | Serve it over TLS. Recommended. |
| `dashboard.publicDomain` | `null` | Public login name, through the tunnel (see above). |
| `url` | from the dashboard | Base URL apps and browsers use, no trailing slash. |
| `oidcClients` | `{ }` | OIDC applications, keyed by slug. |
| `oidcClients.<name>.name` | the slug | Name in the launcher. |
| `oidcClients.<name>.clientId` | the slug | Client ID. |
| `oidcClients.<name>.clientSecretFile` | required | Runtime file with the secret; the app reads it too. |
| `oidcClients.<name>.redirectUris` | required | Exact redirect URIs. |
| `oidcClients.<name>.launchUrl` | `null` | What the launcher opens. |
| `oidcClients.<name>.groups` | `[ ]` | Groups allowed; empty = everyone. |
| `providerSecrets` | `{ }` | Provider name → runtime file with its client secret. |
| `outposts` | `{ }` | Proxy and LDAP outposts. |
| `outposts.proxy.enable` | `false` | Forward auth for `apps`. |
| `outposts.proxy.listenHTTP` | `"127.0.0.1:9005"` | Where nginx reaches it. |
| `outposts.proxy.tokenKeyFile` | `null` | Runtime file with its token; required when on. |
| `outposts.ldap.enable` | `false` | LDAP for apps that can't do OIDC. |
| `outposts.ldap.listen` | `"0.0.0.0:3389"` | LDAP listener (the LAN by default). |
| `outposts.ldap.tokenKeyFile` | `null` | Runtime file with its token; required when on. |
| `apps` | `{ }` | Forward-auth apps, keyed by name. Needs the proxy outpost. |
| `apps.<name>.host` | required | The URL people use. Its vhost gets the gate. |
| `apps.<name>.internalHost` | `null` | Backend, for `mode = "proxy"` only. |
| `apps.<name>.mode` | `"forward_single"` | `forward_single`, `forward_domain` or `proxy`. |
| `apps.<name>.metaLaunchUrl` | `null` | Launcher URL; defaults to `host`. |
| `directorySource.enable` | `false` | Sync users and groups from LDAP. |
| `directorySource.name` | `"Directory"` | Source name in Authentik. |
| `directorySource.slug` | `"directory"` | Source slug, its stable identifier. |
| `directorySource.url` | the local directory | LDAP URI. |
| `directorySource.baseDn` | the local directory's | Base DN. |
| `directorySource.bindUser` | `"authentik"` | Account Authentik binds as; declared for you in the local directory. |
| `directorySource.bindPasswordFile` | required | Runtime file with its password. |
| `directorySource.passwordWriteback` | `true` | Write password changes back to the directory. |
| `directorySource.idAttribute` | `"entryUUID"` | Directory attribute apps get as the user's ID; `null` = Authentik's hashed ID. |
| `directorySource.subjectMap` | read-only | `/run/swag-authentik/subject-map`, old ID → new ID. |
| `directorySource.removeDeletedUsers.enable` | `true` | Remove Authentik users whose directory account is gone. |
| `directorySource.removeDeletedUsers.maxPerRun` | `5` | Most removals per run; more = none and the unit fails. |
| `directorySource.removeDeletedUsers.interval` | `"10min"` | How often to check. |
| `enrollment.enable` | `false` | Invitations, with accounts created in the directory. Gates logins on `accessGroup`. |
| `enrollment.slug` | `"swag-enrollment"` | Flow invitations point at. |
| `enrollment.title` | `"Create your account"` | Form heading. |
| `enrollment.signup` | `false` | Open sign-up too; those accounts wait for approval. |
| `enrollment.accessGroup` | `"members"` | Who may log in; invited accounts join it. |
| `enrollment.grantableGroups` | `[ ]` | Further groups an invitation may give. |
| `enrollment.pendingMessage` | `"Your account is waiting for approval."` | Shown to people outside `accessGroup`. |
| `mfa.enforce` | `false` | Require a second factor on every login. |
| `mfa.methods` | `[ "webauthn" "totp" ]` | Factors offered and accepted. |
| `mfa.recoveryCodes` | `true` | Accept recovery codes. |
| `users` | `{ }` | Authentik-only users, keyed by username. |
| `users.<name>.email` | required | Email. |
| `users.<name>.givenName` | `null` | Display name; defaults to the username. |
| `users.<name>.type` | `"internal"` | `internal`, `external` or `service`. |
| `users.<name>.passwordFile` | `null` | Runtime file with a password config owns. |
| `blueprints` | `{ }` | Your own blueprints: Nix attrsets or YAML files. |
