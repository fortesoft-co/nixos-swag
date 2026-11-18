# nixos-swag

**swag** */swæɡ/* *(n., short for swagger)* — the walk of someone who knows
their setup is tight. Here: a homelab that does TLS, single sign-on, MFA and a
public login, and never once made you click through an admin panel to get
there.

nixos-swag is a self-hosted web gateway for NixOS: split-horizon DNS, an nginx
vhost registry with real certificates, a user directory, and Authentik single
sign-on. Each part is a NixOS module that works alone and wires itself to the
others when they share a host. Declare it, deploy it, and every service gets a
name, a certificate and a login.

The name is a nod to [linuxserver.io's SWAG](https://github.com/linuxserver/docker-swag),
the Secure Web Application Gateway, which put nginx, Let's Encrypt and fail2ban
in one container and named it with the same grin. nixos-swag keeps the attitude
and goes where the container couldn't: a user directory, single sign-on, MFA,
a Cloudflare tunnel that sets itself up, and all of it declared as code. (Not
affiliated with linuxserver.io.)

> **Status:** pre-1.0. Options may still change between commits. Tested against
> nixos-unstable.

## What you get

- **Names for everything.** dnsmasq serves an internal zone (`*.lan.example.com`)
  on your LAN and forwards the rest upstream. Any public name can also be
  answered locally, so the same hostname works inside and out without a trip
  through the internet.
- **Real certificates, even for LAN-only names.** ACME DNS-01 gets publicly
  trusted certificates for internal names. No private CA to install, no port 80
  open to the world.
- **A vhost registry.** A service adds one entry (`host`, `port`, `tls = true`)
  and gets an nginx vhost with TLS, HTTP→HTTPS redirects, WebSockets, basic auth
  or SSO, whichever it asks for.
- **A user directory that belongs to nobody.** [lldap](https://github.com/lldap/lldap)
  holds users and groups declared in config, independent of any one app or
  identity provider. Declared passwords are *initial* passwords: after the first
  login they belong to the user, and config never resets them.
- **Single sign-on.** [Authentik](https://goauthentik.io) syncs users and
  groups from the directory and writes password changes back to it. Users change
  their password once and it holds everywhere. Remove someone from the
  directory and they're removed from Authentik too, a few at a time at most,
  so a broken directory can't empty it.
- **OIDC clients from config.** Declare a client (redirect URIs, allowed groups)
  and get the provider, the application and its secret, with no admin UI step.
  Apps without their own login can sit behind Authentik's forward auth instead.
- **New people by invitation, straight into the directory.** Create an
  invitation in Authentik's admin UI and send the link. The person picks a
  username and password, and the account is created in lldap, not in
  Authentik, with the groups the invitation names. No email server needed,
  and no shell on the server. Open sign-up is one option away; those
  accounts wait until you approve them in the directory.
- **MFA, enforced.** One option makes every login require a second factor:
  passkeys and security keys, authenticator apps, and recovery codes. Users
  without one are walked through enrollment at their next login.
- **A public login, automagically.** Name a public domain and nixos-swag does
  the rest:
  - creates a Cloudflare tunnel ingress for it, plus the public DNS record (via
    [nixos-cloudflared](https://github.com/fortesoft-co/nixos-cloudflared));
  - answers the same name locally, so LAN clients never leave the LAN;
  - terminates TLS on both paths with the same certificate;
  - refuses the Authentik admin interface to anything that came through the
    tunnel, while login, user settings and app sign-ins work from anywhere.

  No inbound ports and no port forwarding.

## Secrets never leak

Most NixOS modules hand you a `passwordFile` option and leave the rest to you.
nixos-swag makes guarantees:

- **Nothing secret goes in the Nix store.** Every secret option takes a runtime
  path (`/run/agenix/…`, `/run/secrets/…`). A Nix path literal is rejected at
  evaluation, before it can be copied into the world-readable store.
- **Nothing secret is passed on a command line or in the environment.** Each
  secret reaches exactly the unit that needs it as a systemd credential
  (`LoadCredential=`). systemd reads the root-only source file and hands a copy
  to that unit alone. No other user or service can read it; the lldap daemon,
  for one, never sees the passwords used to provision its users. Where a
  tool only takes a secret as an argument, the module goes around it (an API, a
  private temp file, or a direct database write) rather than passing it.
- **Store paths stay clean.** Generated Authentik blueprints carry no client
  secrets or bind passwords. Those are set after the blueprints apply, from the
  credentials.

The VM tests check this: they grep the process table and the generated
blueprints for every test secret.

Use any secrets manager that leaves root-only files at runtime:
[agenix](https://github.com/ryantm/agenix), [sops-nix](https://github.com/Mic92/sops-nix),
or a file you put there yourself.

## Modules

| Module | Options | What it does | With the others on the host |
|---|---|---|---|
| `dns` | `services.swag.dns` | dnsmasq for the internal zone, extra local records, upstream forwarding | Other modules derive their default names from the zone (`auth.lan.example.com`, `ldap.lan.example.com`) |
| `web` | `services.swag.web` | nginx vhost registry, ACME DNS-01 certificates, firewall | Admin UIs and forward-auth gates register themselves here |
| `directory` | `services.swag.directory` | lldap with declarative users and groups, and an enrollment endpoint for new accounts | Admin UI on `ldap.<zone>`; Authentik's bind account is created for you |
| `authentik` | `services.swag.authentik` | Authentik server, worker and outposts; OIDC clients, forward-auth apps, MFA, invitations, public login | Syncs from the directory, registers its vhosts, adds tunnel ingress |
| `default` | all of the above | plus [nixos-cloudflared](https://github.com/fortesoft-co/nixos-cloudflared) for the tunnel (off until you enable it) | |

## Quick start

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixos-swag.url = "github:fortesoft-co/nixos-swag";

  outputs = { nixpkgs, nixos-swag, ... }: {
    nixosConfigurations.gateway = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Everything; or pick nixosModules.dns, .web, .directory, .authentik.
        nixos-swag.nixosModules.default
        ./gateway.nix
      ];
    };
  };
}
```

```nix
# gateway.nix — every *File is a runtime path to a root-only file
{
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };

  # Internal zone lan.example.com, answered with this host's LAN address.
  services.swag.dns = {
    enable = true;
    domain = "example.com";
    address = "192.168.1.10";
    upstreamServers = [ "192.168.1.1" "9.9.9.9" ];
  };

  # Certificates through Cloudflare DNS (any lego DNS provider works).
  services.swag.web = {
    enable = true;
    acme.dnsCredentials.CLOUDFLARE_DNS_API_TOKEN = "/run/secrets/cloudflare-dns-token";
  };

  # Users and groups: the source of truth.
  services.swag.directory = {
    enable = true;
    baseDn = "dc=example,dc=com";
    adminPasswordFile = "/run/secrets/lldap-admin";
    dashboard.tls = true; # https://ldap.lan.example.com
    groups.family = { };
    users.alice = {
      email = "alice@example.com";
      displayName = "Alice";
      groups = [ "family" ];
      initialPasswordFile = "/run/secrets/alice-initial";
    };
  };

  # Single sign-on, synced from the directory, with MFA.
  services.swag.authentik = {
    enable = true;
    secrets.AUTHENTIK_SECRET_KEY = "/run/secrets/authentik-secret-key";
    bootstrap = {
      email = "admin@example.com";
      passwordFile = "/run/secrets/authentik-admin";
      tokenFile = "/run/secrets/authentik-api-token";
    };
    dashboard.tls = true; # https://auth.lan.example.com
    directorySource = {
      enable = true;
      bindPasswordFile = "/run/secrets/authentik-bind";
    };
    mfa.enforce = true;
  };
}
```

Deploy it, and:

- `https://ldap.lan.example.com` and `https://auth.lan.example.com` are up, with
  valid certificates;
- alice exists in lldap and in Authentik, in the `family` group;
- her first login asks her to set up a passkey or an authenticator app.

## Plugging in an app

nixos-swag knows nothing about specific apps: they register themselves. An app
on port 8080 that speaks OIDC:

```nix
{ config, ... }:
{
  # A name and a certificate.
  services.swag.web.vhosts."wiki.lan.example.com" = {
    port = 8080;
    tls = true;
  };

  # A login. Only the family group may use it.
  services.swag.authentik.oidcClients.wiki = {
    name = "Wiki";
    clientSecretFile = "/run/secrets/wiki-oidc"; # the app reads the same file
    redirectUris = [ "https://wiki.lan.example.com/oauth/callback" ];
    launchUrl = "https://wiki.lan.example.com/";
    groups = [ "family" ];
  };

  # Point the app at:
  #   ${config.services.swag.authentik.url}/application/o/wiki/.well-known/openid-configuration
}
```

The client gets a confidential OAuth2 provider (authorization code and refresh
token grants; `openid`, `email` and `profile` scopes) and an application in
Authentik's launcher. Its secret is kept equal to the file.

App-specific glue, such as writing the client into the app's own config,
belongs in a small wrapper module next to the app, not in nixos-swag.

**No login of its own?** Put it behind Authentik's forward auth. The vhost gets
an nginx `auth_request` gate, and nothing reaches the app before the user signs
in:

```nix
services.swag.web.vhosts."dashboard.lan.example.com" = {
  port = 3000;
  tls = true;
};

services.swag.authentik = {
  outposts.proxy = {
    enable = true;
    tokenKeyFile = "/run/secrets/authentik-proxy-token";
  };
  apps.dashboard.host = "https://dashboard.lan.example.com";
};
```

## Inviting people

```nix
services.swag.authentik.enrollment = {
  enable = true;
  grantableGroups = [ "git-users" ];  # what an invitation may hand out
};
services.swag.directory.users.alice.groups = [ "members" ];  # existing users
```

- **Invitations.** In the admin UI, go to *Directory → Invitations*, pick the
  `swag-enrollment` flow, and optionally set fixed data
  `{"groups": ["git-users"]}`. Send the link. Following it, the person fills
  in username, name, email and password. The form checks the username and
  email are free before anything is written. The account lands in the
  directory in `members` plus the invitation's groups, and syncs into
  Authentik within seconds.
- **Who can log in.** Only members of `accessGroup` (default `members`).
  Everyone else is told their account is waiting for approval; superusers
  are exempt. Put your existing users in it before turning this on.
- **Open sign-up** (`signup = true`) adds a *Sign up* link to the login page.
  Those accounts get no groups. Approve someone by adding them to `members`
  in lldap's admin UI; reject them by deleting the account there.
- **Removing someone.** Delete them in lldap's admin UI. Within
  `directorySource.removeDeletedUsers.interval` (10 minutes) they're removed
  from Authentik as well: sessions, MFA devices, consents. A run that would
  remove more than `maxPerRun` (5) users removes none and fails
  `authentik-directory-prune.service`; superusers are never removed. Apps
  that keep their own copy of the account keep it, with its data, until you
  delete it there, but no longer let them sign in.
- **Locking someone out, keeping the account.** Deactivate them in
  Authentik. Don't delete them only in Authentik: the directory still has
  them, so the next sync brings them back, without their MFA devices.
- **Safe by construction.** The directory creates accounts through a local
  socket that only the Authentik server can open. It holds the lldap admin
  password as a systemd credential, refuses any group not in
  `grantableGroups` (and lldap's admin groups always), and never logs or
  stores the password it sets.

## Going public

A public login takes two things: Cloudflare credentials for the tunnel, and a
public name for Authentik. Your domain's DNS has to be on Cloudflare.

```nix
services.cloudflared-tunnel = {
  enable = true;
  accountIdFile = "/run/secrets/cloudflare-account-id";
  apiTokenFile = "/run/secrets/cloudflare-api-token";
};

services.swag.authentik.dashboard.publicDomain = "auth.example.com";
```

The API token needs these permissions:
- Account › Cloudflare Tunnel › Edit
- Zone › DNS › Edit
- Zone › Zone › Read

(The global API key with the account email works too, but it can do anything
on the account.) It can be the same token you give `services.swag.web` for
certificates, or a separate one.

On the next deploy, with no dashboard visits:

1. **The tunnel sets itself up.** nixos-cloudflared finds the tunnel named after
   the host in your account, or creates it. It stores the tunnel's token
   root-only and starts `cloudflared` with it as a systemd credential.
2. **Authentik joins it.** The authentik module adds `auth.example.com` to the
   tunnel's ingress, pointed at nginx over HTTPS with the right server name.
3. **The public record appears.** For every ingress hostname, nixos-cloudflared
   keeps a proxied CNAME to the tunnel in whichever of your zones holds it.
   Any other module that adds an ingress entry gets its record the same way.
4. **The LAN takes the short way.** swag dns answers `auth.example.com` with
   this host's address, so LAN clients never leave the LAN, and nginx serves
   both paths with the same certificate.

```
                     ┌─ outside ─ Cloudflare ─ tunnel ─┐
browser ─ auth.example.com                             ├─ nginx (TLS) ─ Authentik
                     └─ LAN ─ dnsmasq says "this host" ┘
```

What you end up with:

- **One login hostname everywhere.** The local `auth.lan.example.com` redirects
  to `auth.example.com`, because passkeys are bound to the hostname they were
  registered on.
- **Admin stays home.** Requests through the tunnel carry Cloudflare's
  `CF-Connecting-IP` header, which clients can't set, and can't load
  `/if/admin/`. On the LAN, the admin interface works as before. nginx also uses
  that header as the client address, so Authentik's logs and reputation checks
  see real IPs.
- **Clients follow.** `services.swag.authentik.url` becomes
  `https://auth.example.com`, so OIDC discovery URLs work for browsers anywhere.
- **No inbound ports.** The tunnel connects out, so nothing on your router is
  opened or forwarded.

Turn on `mfa.enforce` before going public.

## Tests

```sh
nix flake check
```

| Check | What it proves |
|---|---|
| `directory` | Users, groups and initial passwords are provisioned; secrets are readable only by the unit that needs them; a password the user changed survives re-provisioning; provisioning is idempotent |
| `authentik-directory` | Authentik's bind account gets its managed password; users and group memberships sync from lldap into Authentik; a password set in Authentik is written back to lldap; a user deleted in lldap is removed from Authentik, a superuser is not; more removals than the limit apply none; no secret on a command line |
| `authentik-oidc` | OIDC clients get the declared IDs, redirect URIs, grants, group bindings and secrets; discovery is served; no secret in the store or the process table |
| `authentik-enrollment` | An invitation creates the account in the directory with its groups, and it syncs and logs in; the form reports a taken username or short password without writing anything; a used invitation is refused; logins outside the access group wait for approval; an invitation can't grant other groups; the enrollment socket is closed to other users; no password on a command line or in the journal |
| `authentik-public` | The public name resolves locally; the admin interface is refused through the tunnel only; the local name redirects; logins without a second factor are sent to enrollment |

Each check boots a NixOS VM, so you need KVM.

## License

[AGPL-3.0](LICENSE).
