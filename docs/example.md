# A worked example

One host, `gateway`, running the whole stack for a household: a wiki that
signs people in with OIDC, a dashboard with no login of its own, invitations
for new people, MFA for everyone, and a login that works from outside
without opening a port. Everything here is generic (`example.com`, made-up
apps); swap in your own.

By the end:

| Name | What | Reachable |
|---|---|---|
| `auth.example.com` | Authentik: login, user settings, app launcher | LAN and internet (admin UI LAN only) |
| `ldap.lan.example.com` | the directory's admin UI | LAN |
| `wiki.lan.example.com` | the wiki, OIDC sign-in | LAN |
| `dashboard.lan.example.com` | the dashboard, behind forward auth | LAN |

## Before you start

- **A domain with its DNS on Cloudflare.** Needed for certificates
  (DNS-01) and the tunnel. Other DNS providers work for certificates; the
  tunnel is Cloudflare's.
- **A Cloudflare API token** with *Account › Cloudflare Tunnel › Edit*,
  *Zone › DNS › Edit* and *Zone › Zone › Read*, and your account ID.
- **A secrets manager** that leaves root-only files at runtime:
  [agenix](https://github.com/ryantm/agenix),
  [sops-nix](https://github.com/Mic92/sops-nix), or files you put there.
  This example uses `/run/secrets/<name>`.
- **A static LAN address** for the host, here `192.168.1.10`, and access to
  your router's DHCP settings.

## Secrets

| File | Contents | Make it with |
|---|---|---|
| `cloudflare-token` | the API token | Cloudflare's dashboard |
| `cloudflare-account-id` | the account ID | Cloudflare's dashboard |
| `lldap-admin` | directory admin password | `openssl rand -base64 24` |
| `authentik-secret-key` | Authentik's signing key | `openssl rand -base64 60` |
| `authentik-admin` | akadmin's password | `openssl rand -base64 24` |
| `authentik-api-token` | akadmin's API token | `openssl rand -hex 32` |
| `authentik-bind` | Authentik's directory account | `openssl rand -base64 24` |
| `authentik-proxy-token` | forward-auth outpost token | `openssl rand -hex 32` |
| `alice-initial`, `bob-initial` | first passwords | anything; they change it |
| `wiki-oidc` | the wiki's client secret | `openssl rand -hex 32` |

Each file holds the raw value, mode 0400, owned by root. The wiki reads
`wiki-oidc` too, so give that one to the wiki's group (mode 0440), or use
the wiki module's own secret handling.

## flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-swag.url = "github:fortesoft-co/nixos-swag";
  };

  outputs = { nixpkgs, nixos-swag, ... }: {
    nixosConfigurations.gateway = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-swag.nixosModules.default
        ./hardware-configuration.nix
        ./gateway.nix
        ./apps.nix
      ];
    };
  };
}
```

## gateway.nix: the stack

```nix
{ config, ... }:
let
  secret = name: "/run/secrets/${name}";
in
{
  networking.hostName = "gateway";

  # The state lives on its own disk, so a reinstall finds it again.
  fileSystems."/srv" = {
    device = "/dev/disk/by-label/srv";
    fsType = "ext4";
  };
  services.swag.stateDir = "/srv/swag";

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };

  # lan.example.com → this host, everything else upstream.
  services.swag.dns = {
    enable = true;
    domain = "example.com";
    address = "192.168.1.10";
    upstreamServers = [ "192.168.1.1" "9.9.9.9" ];
  };

  services.swag.web = {
    enable = true;
    acme.dnsCredentials.CLOUDFLARE_DNS_API_TOKEN = secret "cloudflare-token";
  };

  # The people. Groups: who may use what.
  services.swag.directory = {
    enable = true;
    baseDn = "dc=example,dc=com";
    adminPasswordFile = secret "lldap-admin";
    dashboard.tls = true;
    groups = {
      family = { };
      wiki-users = { };
    };
    users = {
      alice = {
        email = "alice@example.com";
        displayName = "Alice";
        groups = [ "members" "family" "wiki-users" "lldap_admin" ];
        initialPasswordFile = secret "alice-initial";
      };
      bob = {
        email = "bob@example.com";
        displayName = "Bob";
        groups = [ "members" "family" ];
        initialPasswordFile = secret "bob-initial";
      };
    };
  };

  services.swag.authentik = {
    enable = true;
    secrets.AUTHENTIK_SECRET_KEY = secret "authentik-secret-key";
    bootstrap = {
      email = "admin@example.com";
      passwordFile = secret "authentik-admin";
      tokenFile = secret "authentik-api-token";
    };
    dashboard = {
      tls = true;
      publicDomain = "auth.example.com";
    };
    directorySource = {
      enable = true;
      bindPasswordFile = secret "authentik-bind";
    };
    mfa.enforce = true;
    enrollment = {
      enable = true;                       # logins need `members`
      grantableGroups = [ "family" "wiki-users" ];
    };
    outposts.proxy = {
      enable = true;
      tokenKeyFile = secret "authentik-proxy-token";
    };
  };

  # The tunnel for auth.example.com.
  services.cloudflared-tunnel = {
    enable = true;
    accountIdFile = secret "cloudflare-account-id";
    apiTokenFile = secret "cloudflare-token";
  };
}
```

`members` isn't declared above: enrollment declares its access group
itself. Alice is in `lldap_admin`, so she can manage people in the
directory's admin UI with her own account.

## apps.nix: the apps

The wiki and the dashboard stand in for whatever you run. Each app's own
settings (where it listens, its database, its OIDC settings) come from its
own module; what's shown is the part swag needs.

```nix
{ config, ... }:
let
  auth = config.services.swag.authentik;
in
{
  # ── The wiki: OIDC sign-in, accounts kept in line ──────────────────────
  services.swag.web.vhosts."wiki.lan.example.com" = {
    port = 8080;
    tls = true;
  };

  services.swag.authentik.oidcClients.wiki = {
    name = "Wiki";
    clientSecretFile = "/run/secrets/wiki-oidc";
    redirectUris = [ "https://wiki.lan.example.com/oauth/callback" ];
    launchUrl = "https://wiki.lan.example.com/";
    groups = [ "wiki-users" ];
  };

  # In the wiki's own config:
  #   issuer:   ${auth.url}/application/o/wiki/
  #   client:   wiki, secret from /run/secrets/wiki-oidc
  #   username: the preferred_username claim; ID: the sub claim

  # Authentik's group gate only guards sign-in; this closes the wiki's
  # own ways in (API tokens, sessions) for people who left wiki-users.
  services.swag.accounts.wiki = {
    accessGroup = "wiki-users";
    adapter.sql = {
      identity = "subject";
      database = { type = "sqlite3"; path = "/var/lib/wiki/wiki.db"; };
      queries = {
        list = "SELECT id, name, oidc_sub, disabled FROM users";
        names = "SELECT name FROM users";
        block = [
          "UPDATE users SET disabled = 1 WHERE id = :id"
          "DELETE FROM api_tokens WHERE user_id = :id"
        ];
        unblock = "UPDATE users SET disabled = 0 WHERE id = :id";
        revoke = "DELETE FROM sessions WHERE user_id = :id";
      };
    };
    serviceConfig = {
      User = "wiki";
      ReadWritePaths = [ "/var/lib/wiki" ];
    };
    after = [ "wiki.service" ];
    # dryRun stays on for the first deploy; see below.
  };

  # ── The dashboard: no login of its own, so forward auth ─────────────────
  services.swag.web.vhosts."dashboard.lan.example.com" = {
    port = 3000;
    tls = true;
  };
  services.swag.authentik.apps.dashboard.host = "https://dashboard.lan.example.com";
}
```

The `block` above deletes the wiki's API tokens, which a later `unblock`
can't bring back. That's a choice: tokens are cheap to recreate, and a
token that outlives the person is the hole being closed. If your app can
disable tokens instead, prefer that.

## First deploy

```sh
nixos-rebuild switch --flake .#gateway --target-host root@192.168.1.10
```

Then, on your router, hand out `192.168.1.10` as the DNS server over DHCP,
and renew a client's lease.

Check, in order:

1. **Names**: `dig wiki.lan.example.com @192.168.1.10` answers
   `192.168.1.10`.
2. **Certificates**: `systemctl list-units 'acme-*'` all succeeded;
   `https://ldap.lan.example.com` opens without a warning.
3. **The directory**: sign in to the admin UI as `admin`; alice and bob
   are there, in their groups.
4. **Authentik**: `https://auth.example.com` from the LAN and from your
   phone on mobile data. Sign in as alice with her initial password; she's
   asked to set up a passkey or authenticator app, then lands on the
   launcher with Wiki and Dashboard.
5. **The wiki**: signing in through Authentik works; bob, outside
   `wiki-users`, is refused by Authentik.
6. **Accounts**: `journalctl -u swag-accounts-wiki` shows what it would
   block (dry run). If that's what you expect, set
   `services.swag.accounts.wiki.dryRun = false` and deploy again.

Have alice and bob change their passwords in Authentik (*Settings →
Change password*); it's written back to the directory, and config never
resets it.

## Day to day

**Someone new.** In Authentik's admin UI, *Directory → Invitations →
Create*, flow `swag-enrollment`, fixed data `{"groups": ["family"]}`.
Send the link. They choose a username and password, land in `members` and
`family`, and set up MFA at their first login.

**Wiki access.** Add or remove them from `wiki-users` in the directory's
admin UI. Within 10 minutes `swag-accounts-wiki` blocks the account of
someone who left, or lifts its own block for someone who's back, and
Authentik's gate follows at its next directory sync. Declared in config
instead, a change reaches Authentik on the deploy itself.

**Someone leaves for good.** Delete them in the directory's admin UI.
Within 10 minutes they're gone from Authentik too. The wiki keeps their
account, blocked, with their pages; their username stays taken until you
delete that account in the wiki.

**Lock someone out for now.** Deactivate them in Authentik. Reactivate to
undo.

**Lost authenticator.** `swag-authentik-reset-user bob` on the host: bob
keeps his password and his ID in every app, and sets up MFA again.

**Backups.** Back up `/srv/swag` and Postgres (Authentik's database), with
`lldap`, `authentik` and `authentik-worker` stopped while you copy.

**Reinstalling the host.** Install NixOS with the same config, with `/srv`
on the same disk (or restored). Everyone signs in as before, with the same
IDs, so the wiki finds the same accounts. MFA devices, sessions and
anything set in Authentik's admin UI (invitations, for one) live in its
database: restore Postgres too, or everyone sets up MFA again.
