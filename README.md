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
| [`dns`](docs/dns.md) | `services.swag.dns` | dnsmasq for the internal zone, extra local records, upstream forwarding | Other modules derive their default names from the zone (`auth.lan.example.com`, `ldap.lan.example.com`) |
| [`web`](docs/web.md) | `services.swag.web` | nginx vhost registry, ACME DNS-01 certificates, firewall | Admin UIs and forward-auth gates register themselves here |
| [`directory`](docs/directory.md) | `services.swag.directory` | lldap with declarative users and groups, and an enrollment endpoint for new accounts | Admin UI on `ldap.<zone>`; Authentik's bind account is created for you |
| [`authentik`](docs/authentik.md) | `services.swag.authentik` | Authentik server, worker and outposts; OIDC clients, forward-auth apps, MFA, invitations, public login | Syncs from the directory, registers its vhosts, adds tunnel ingress |
| [`accounts`](docs/accounts.md) | `services.swag.accounts` | App-side accounts that follow the directory: blocks people who left a group, links old IDs, keeps held names | One unit per app; the app is reached through a small adapter |
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
        # Everything; or pick nixosModules.dns, .web, .directory, .authentik, .accounts.
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
{
  # A name and a certificate.
  services.swag.web.vhosts."wiki.lan.example.com" = {
    port = 8080;
    tls = true;
  };

  # A login. Only the family group may use it.
  services.swag.authentik.oidcClients.wiki = {
    clientSecretFile = "/run/secrets/wiki-oidc"; # the app reads the same file
    redirectUris = [ "https://wiki.lan.example.com/oauth/callback" ];
    groups = [ "family" ];
  };
}
```

Apps without a login of their own go behind
[forward auth](docs/authentik.md#apps-without-a-login), and
[accounts](docs/accounts.md) keeps an app's own accounts in line with the
directory. App-specific glue belongs in a small module next to the app, not
in nixos-swag.

## Documentation

- **[A worked example](docs/example.md)**: one host, the whole stack, two
  apps, from the secrets to day-to-day operations.
- **[dns](docs/dns.md)**: the internal zone, local records, why a domain
  you own.
- **[web](docs/web.md)**: vhosts, certificates, shaping a vhost.
- **[directory](docs/directory.md)**: users and groups, what config owns,
  group files, enrollment and held names.
- **[authentik](docs/authentik.md)**: OIDC clients, forward auth, the
  directory sync, user IDs, invitations, MFA, going public.
- **[accounts](docs/accounts.md)**: blocking, linking and held names in the
  apps themselves; the SQL adapter and writing your own.
- **[Keeping state](docs/state.md)**: one path for everything the stack
  remembers, and moving a running host onto it.

Each page ends with every option of its module.

## Tests

```sh
nix flake check
```

| Check | What it proves |
|---|---|
| `directory` | Users, groups and initial passwords are provisioned; group members are published by directory ID; secrets are readable only by the unit that needs them; a password the user changed survives re-provisioning; provisioning is idempotent |
| `accounts` | People outside the group are blocked and their sessions revoked, and lifted when back, while an admin's block and local accounts are left alone; an account known by an old ID is linked, a link whose new ID is taken is refused; more blocks than the limit apply none; no members file or subject map changes nothing; a failed step still publishes held names; dry run changes nothing; an app that can't block is matched by name and has its sessions revoked once; the SQL adapter on sqlite3 and postgres |
| `state` | Turning on `stateDir` for a running host copies lldap's and app accounts state once (DynamicUser's private folder included) and bind-mounts it back; every user keeps their ID; the originals stay; a later start copies nothing |
| `authentik-directory` | Authentik's bind account gets its managed password; users and group memberships sync from lldap into Authentik; a password set in Authentik is written back to lldap; deleting a directory user through nginx is refused with a reason while local users can be deleted, and the reset command rebuilds one with the same ID; directory users carry the directory's ID, OIDC clients send it, local users keep Authentik's, the subject map pairs old and new IDs, and the ID survives the user being re-created; a user deleted in lldap is removed from Authentik, a superuser is not; more removals than the limit apply none; no secret on a command line |
| `authentik-oidc` | OIDC clients get the declared IDs, redirect URIs, grants, group bindings and secrets; discovery is served; no secret in the store or the process table |
| `authentik-enrollment` | An invitation creates the account in the directory with its groups, and it syncs and logs in, even when a sync was already running; the form reports a taken username or short password without writing anything; a used invitation is refused; logins outside the access group wait for approval; an invitation can't grant other groups; a name an app still holds is taken; the enrollment socket is closed to other users; no password on a command line or in the journal |
| `docs` | Every option of every module is in its page under `docs/`; every link and heading anchor in the docs resolves (no VM) |
| `authentik-public` | The public name resolves locally; the admin interface is refused through the tunnel only; the local name redirects; logins without a second factor are sent to enrollment |

Each check but `docs` boots a NixOS VM, so you need KVM.

## License

[AGPL-3.0](LICENSE).
