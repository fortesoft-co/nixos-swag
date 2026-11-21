{
  config,
  lib,
  ...
}:
with lib;
let
  inherit (import ../../lib/types.nix { inherit lib; }) secretPath;
in
{
  options.services.swag.authentik = {
    enable = mkEnableOption "Authentik identity provider";

    # ── Freeform config (full authentik config.yml surface) ──────────────
    settings = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Freeform authentik config, rendered to /etc/authentik/config.yml and
        deep-merged with the typed shorthands below (email, database). This is
        the full escape hatch — any key from authentik's config reference can
        be set here and never lags upstream. Typed shorthands are merged
        underneath, so keys here win on leaf conflicts. Never put secrets here
        (the Nix store is world-readable) — use services.swag.authentik.secrets.
      '';
    };

    # ── Typed shorthands ──────────────────────────────────────────────────
    email = mkOption {
      type = types.submodule {
        freeformType = types.attrs;
        options = {
          host = mkOption {
            type = types.str;
            default = "localhost";
            description = "SMTP host.";
          };
          port = mkOption {
            type = types.port;
            default = 25;
            description = "SMTP port.";
          };
          username = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              SMTP username. The password is NOT set here — declare it via
              services.swag.authentik.secrets.AUTHENTIK_EMAIL__PASSWORD.
            '';
          };
          use_tls = mkOption {
            type = types.bool;
            default = false;
            description = "Use STARTTLS for SMTP.";
          };
          use_ssl = mkOption {
            type = types.bool;
            default = false;
            description = "Use implicit TLS (SMTPS) for SMTP.";
          };
          from = mkOption {
            type = types.str;
            default = "authentik@localhost";
            description = "From address for authentik email.";
          };
        };
      };
      default = { };
      description = ''
        Email shorthand → settings.email. The SMTP password is a secret —
        declare it via services.swag.authentik.secrets.AUTHENTIK_EMAIL__PASSWORD (the env
        var authentik reads for the password).
      '';
    };

    database = mkOption {
      type = types.submodule {
        options = {
          create = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Let this module provision a local postgresql database + user via
              services.authentik.createDatabase. Set false to use an external
              database (configure settings.postgresql yourself via
              services.swag.authentik.settings). The local postgres data lives at
              services.postgresql.dataDir (default /var/lib/postgresql) —
              relocate it separately if you need it on an external drive; this
              option does not manage the postgres data directory.
            '';
          };
        };
      };
      default = { };
      description = "Database configuration shorthand.";
    };

    # ── Secrets (runtime files) ─────────────────────────────────────────────────
    secrets = mkOption {
      type = types.attrsOf secretPath;
      default = { };
      example = literalExpression ''
        {
          AUTHENTIK_SECRET_KEY = config.age.secrets.authentik-secret-key.path;
          AUTHENTIK_EMAIL__PASSWORD = "/run/secrets/authentik-email";
        }
      '';
      description = ''
        Secrets injected as environment variables at runtime. Each attribute
        maps an env var name (as authentik expects it, e.g.
        AUTHENTIK_SECRET_KEY, AUTHENTIK_EMAIL__PASSWORD) to the runtime path
        of a file holding the raw value, from any secrets tool (agenix,
        sops-nix, ...). The module assembles them into a single root-only
        environment file consumed by services.authentik.environmentFile, so
        the values never reach the Nix store.

        AUTHENTIK_SECRET_KEY is mandatory (authentik won't start without it);
        generate one with `openssl rand -base64 60`.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Non-secret environment variables for the authentik server/worker/migrate
        (written to the Nix store — do NOT put secrets here). Applied via systemd
        Environment, not the env file (which is secrets only). Bootstrap email
        (AUTHENTIK_BOOTSTRAP_EMAIL) is added here automatically.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr secretPath;
      default = null;
      description = ''
        Path to a pre-existing environment file (systemd EnvironmentFile format)
        — the escape hatch for another secrets backend. Used only when
        services.swag.authentik.secrets is empty (otherwise the module's assembled env file
        is used). Provide AUTHENTIK_SECRET_KEY (and any other required vars) in it.
      '';
    };

    # ── Outposts ─────────────────────────────────────────────────────────
    outposts = mkOption {
      type = types.submodule {
        options = {
          proxy = {
            enable = mkEnableOption "the authentik proxy outpost";
            # The proxy outpost serves nginx auth_request forward auth for apps
            # registered in services.swag.authentik.apps (the forward-auth wiring lands in
            # a follow-up; enabling the outpost now makes it available).
            listenHTTP = mkOption {
              type = types.str;
              default = "127.0.0.1:9005";
              description = ''
                Listen address for the proxy outpost HTTP server. nginx
                auth_request subrequests hit this. The default binds IPv4
                loopback — nginx (on the same host) reaches it; the browser
                reaches it via the /outpost.goauthentik.io/ location on the
                app vhost.
              '';
            };
            tokenKeyFile = mkOption {
              type = types.nullOr secretPath;
              default = null;
              description = ''
                Runtime path to a file containing the raw outpost token key. The
                module auto-provisions the outpost + token in authentik's
                database on every boot via an `ak shell` oneshot, setting the
                token key to this value — no admin UI step needed and
                reprovision-safe (the key comes from the file, not
                auto-generated). Generate with e.g. `openssl rand -hex 32`
                and keep it in your secrets tool. Required when
                outposts.proxy.enable is true.
              '';
            };
          };
          ldap = {
            enable = mkEnableOption "the authentik LDAP outpost";
            listen = mkOption {
              type = types.str;
              default = "0.0.0.0:3389";
              description = ''
                Listen address for the LDAP outpost. LDAP clients (Nextcloud,
                Gitea, Jellyfin, ...) bind here. The default 0.0.0.0:3389
                exposes it on the LAN — gate it via firewall or bind loopback +
                a tunnel for apps that don't run on this host. Port 3389 avoids
                the privileged 389.
              '';
            };
            tokenKeyFile = mkOption {
              type = types.nullOr secretPath;
              default = null;
              description = ''
                Runtime path to a file containing the raw outpost token key. Same
                convention as outposts.proxy.tokenKeyFile. Required when
                outposts.ldap.enable is true.
              '';
            };
          };
        };
      };
      default = { };
      description = ''
        Authentik outposts. The proxy outpost serves nginx forward auth
        (auth_request) for web apps; the LDAP outpost serves apps that
        authenticate via LDAP. Each enabled outpost needs a token key —
        declare it via outposts.<name>.tokenKeyFile (a runtime file holding
        the raw key). The module auto-provisions the outpost + token in
        authentik's database on every boot via an `ak shell` oneshot, so no
        admin UI step is needed and the setup is reprovision-safe.
      '';
    };

    # ── NixOS-only: service knobs ────────────────────────────────────────
    stateDir = mkOption {
      type = types.str;
      default =
        if config.services.swag.stateDir != null then
          "${config.services.swag.stateDir}/authentik"
        else
          "/var/lib/authentik";
      defaultText = literalExpression ''"''${services.swag.stateDir}/authentik", or "/var/lib/authentik" when that is null'';
      description = ''
        Where Authentik's files live (media, certificates; its database is
        separate, see services.swag.authentik.database). Anything but
        /var/lib/authentik is bind-mounted there, with a static authentik
        user instead of upstream's DynamicUser; data already in
        /var/lib/authentik (or /var/lib/private/authentik) is copied over
        once. The parent must be mounted by the host.
      '';
    };

    # ── Admin web UI (authentik's own dashboard) ──────────────────────────
    dashboard = mkOption {
      type = types.submodule {
        options = {
          domain = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              server_name for the authentik admin UI nginx vhost. When null
              and swag dns (services.swag.dns) is enabled, this defaults to
              "auth" under the internal zone (auth.<internalDomain>) — so a
              homelab running swag dns only needs services.swag.authentik.enable, no
              explicit domain. Set explicitly to override the auto-derived
              subdomain. Requires swag web on the host (the admin UI
              is fronted by nginx on the shared port 80, not by upstream's
              services.authentik.nginx, which this module leaves off). nginx
              proxies to authentik's HTTP listener (loopback:9000) so the
              external scheme is driven by X-Forwarded-Proto (http on port 80,
              https if the vhost is later TLS-fronted) — see the adminVhost
              comment in swag authentik.nix for why :9000 not :9443.
            '';
          };

          tls = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Serve the local admin UI vhost (dashboard.domain) over TLS
              with an ACME certificate (services.swag.web.vhosts.<domain>.tls).
              Recommended: it carries logins and OIDC traffic. The derived
              services.swag.authentik.url follows the vhost's scheme.
            '';
          };

          publicDomain = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "auth.example.com";
            description = ''
              Public name for Authentik's login, the same inside and out
              (split horizon), e.g. auth.example.com:

              - a TLS vhost for it on swag web (ACME, DNS-01);
              - with swag dns on this host, a local record pointing it here,
                so LAN clients never leave the LAN;
              - a cloudflared ingress reaching that vhost over HTTPS;
              - the local dashboard.domain redirects to it, so passkeys,
                which are bound to one hostname, work everywhere;
              - services.swag.authentik.url defaults to https://<it>.

              Requests that arrive through the tunnel (they carry
              Cloudflare's CF-Connecting-IP header, which clients cannot
              set) can't load the admin interface (/if/admin/); login, user
              settings and app sign-ins work from anywhere. nginx takes the
              client address from that header for Authentik's logs and
              reputation checks. Pair it with services.swag.authentik.mfa.
            '';
          };
        };
      };
      default = { };
      description = ''
        Authentik's own admin web UI. Local access is automatic when
        swag web + swag dns are on the host (an "auth" subdomain is
        registered on port 80). nginx proxies to authentik's HTTP listener
        (loopback:9000); the external scheme follows X-Forwarded-Proto. Public
        access is via dashboard.publicDomain (cloudflared) — authentik's own
        login gates the admin UI.
      '';
    };

    # ── MFA on the default login flow ───────────────────────────────────────
    mfa = {
      enforce = mkEnableOption ''
        requiring a second factor on every login through the default
        authentication flow. Users without one are asked to enroll one of
        `methods` on their next login. API tokens are unaffected'';

      methods = mkOption {
        type = types.nonEmptyListOf (types.enum [ "webauthn" "totp" ]);
        default = [ "webauthn" "totp" ];
        description = ''
          Factors offered at enrollment and accepted at login: webauthn
          (passkeys, security keys, platform authenticators) and totp
          (authenticator apps).
        '';
      };

      recoveryCodes = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Accept static recovery codes as the second factor. Users create
          them in their settings (MFA devices) once they have a primary
          factor; they are not offered as the only factor at enrollment.
        '';
      };
    };

    # ── Enrollment: invitations (and optionally open sign-up) ───────────────
    enrollment = {
      enable = mkEnableOption ''
        new accounts through Authentik, created in the directory
        (services.swag.directory with enrollment on the same host, and
        directorySource). An admin creates an invitation in the admin UI
        (Directory → Invitations, flow `slug`) and sends its link; following
        it, the person picks a username and password and lands in
        accessGroup plus any groups the invitation lists in its fixed data
        as `groups` (each must be in grantableGroups).

        Turning this on gates every login on accessGroup: existing users must
        be members of it (declare it in services.swag.directory.users), or
        they're told their account awaits approval. Superusers (akadmin) are
        exempt'';

      slug = mkOption {
        type = types.str;
        default = "swag-enrollment";
        description = "Slug of the enrollment flow, the one invitations point at.";
      };

      title = mkOption {
        type = types.str;
        default = "Create your account";
        description = "Heading of the enrollment flow.";
      };

      signup = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Also let people sign up without an invitation, through a "Sign up"
          link on the login page. Their accounts are created in the directory
          with no groups, and can't log in until an admin adds them to
          accessGroup (in the directory's admin UI).
        '';
      };

      accessGroup = mkOption {
        type = types.str;
        default = "members";
        description = ''
          Directory group whose members may log in. Declared in the
          directory by this module; invited accounts join it.
        '';
      };

      grantableGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "git-users" ];
        description = ''
          Further groups an invitation may give (fixed data
          `{"groups": ["git-users"]}`). Must be declared in
          services.swag.directory.groups.
        '';
      };

      pendingMessage = mkOption {
        type = types.str;
        default = "Your account is waiting for approval.";
        description = "Shown when someone outside accessGroup logs in.";
      };
    };

    # ── Forward-auth app registry → auto-generated proxy blueprint ──────────
    apps = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          host = mkOption {
            type = types.str;
            description = ''
              External host URL for the app (e.g.
              "http://my-app.lan.example.com"). Used as the proxy provider's
              external_host — the URL users access the app at, and the
              server_name nginx matches for the auth_request subrequest.
            '';
          };
          internalHost = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Internal backend URL for the app (e.g.
              "http://127.0.0.1:8080"). Only used in proxy mode (the
              outpost itself proxies traffic). Leave null for forward_auth
              mode (nginx proxies, the outpost only handles auth_request).
            '';
          };
          mode = mkOption {
            type = types.enum [ "forward_single" "forward_domain" "proxy" ];
            default = "forward_single";
            description = ''
              Proxy provider mode. `forward_single` is the standard nginx
              auth_request pattern (one subdomain per app). `forward_domain`
              is for wildcard/domain-level forward auth. `proxy` makes the
              outpost itself proxy traffic to internalHost (no nginx needed).
            '';
          };
          metaLaunchUrl = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Launch URL for the app in authentik's app launcher. Defaults to
              the host URL.
            '';
          };
        };
      });
      default = { };
      description = ''
        Applications registered for authentik proxy forward auth. Each app
        auto-generates a ProxyProvider + Application in authentik via a
        blueprint (applied on every boot), and is assigned to the proxy
        outpost. No admin UI step needed — the blueprint is the source of
        truth. Requires outposts.proxy.enable + outposts.proxy.tokenKeyFile.
      '';
    };

    # ── Bootstrap: one-time akadmin seed (skips the /setup flow) ───────────
    bootstrap = mkOption {
      type = types.submodule {
        options = {
          email = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Email for the akadmin user, seeded on first start (while no admin
              exists). Non-secret — stored in the Nix store. Set together with a
              password to skip the /setup flow and pre-create the admin.
            '';
          };
          passwordFile = mkOption {
            type = types.nullOr secretPath;
            default = null;
            description = ''
              Runtime path to a file containing the plaintext akadmin password
              (mapped to AUTHENTIK_BOOTSTRAP_PASSWORD, read only on first
              start). Mutually exclusive with passwordHashFile. The value is
              assembled into the root-only env file at runtime — never the
              Nix store.
            '';
          };
          passwordHashFile = mkOption {
            type = types.nullOr secretPath;
            default = null;
            description = ''
              Runtime path to a file containing a pre-hashed akadmin password (the
              value of AUTHENTIK_BOOTSTRAP_PASSWORD_HASH). Preferred over
              passwordFile. Generate the hash with the upstream `ak` helper
              (e.g. `ak hash_password`). Mutually exclusive with passwordFile.
            '';
          };
          tokenFile = mkOption {
            type = types.nullOr secretPath;
            default = null;
            description = ''
              Runtime path to a file containing an API token for akadmin
              (AUTHENTIK_BOOTSTRAP_TOKEN), seeded on first start. Lets you drive
              authentik via API/Terraform after bootstrap without a GUI login.
            '';
          };
        };
      };
      default = { };
      description = ''
        One-time bootstrap of the akadmin user (skips the /setup flow). Read by
        authentik only on the first startup while no admin exists; afterwards
        ignored (manage the admin via the UI/API/blueprints). For ongoing
        declarative config (apps, providers, flows, outposts), use
        services.swag.authentik.blueprints.
      '';
    };

    # ── Blueprints: declarative config-as-code ───────────────────────────────
    blueprints = mkOption {
      type = types.attrsOf (types.either types.path types.attrs);
      default = { };
      example = literalExpression ''
        {
          hermes-forward-auth = {
            version = 1;
            metadata.name = "hermes-forward-auth";
            metadata.labels."blueprints.goauthentik.io/instantiate" = "true";
            entries = [ { ... } ];
          };
        }
      '';
      description = ''
        Custom authentik blueprints, keyed by filename (without .yaml). Each
        value is either a path to a YAML file or (preferred) a Nix attrset
        rendered to YAML — so the config lives in Nix and is validated at build.
        Blueprints are auto-discovered and applied on startup (and re-applied
        periodically); use them to declaratively define applications, providers
        (proxy/LDAP/OIDC), outposts, flows, users, groups, brands. The module
        assembles these with the system blueprints into blueprints_dir. Each
        blueprint needs
          metadata.labels."blueprints.goauthentik.io/instantiate" = "true"
        to auto-apply. Schema: https://goauthentik.io/blueprints/schema.json
      '';
    };

    # ── OIDC client registry → auto-generated blueprint ─────────────────────
    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://auth.lan.example.com";
      description = ''
        Base URL browsers and OIDC clients reach Authentik at, without a
        trailing slash. Issuer and discovery URLs of oidcClients are built
        from it: <url>/application/o/<slug>/. Defaults to
        http(s)://<dashboard.domain> when the admin UI has a local domain,
        https when that vhost has TLS.
      '';
    };

    oidcClients = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                description = "Display name of the application in Authentik's launcher.";
              };
              clientId = mkOption {
                type = types.str;
                default = name;
                description = "OAuth2 client ID the app presents.";
              };
              clientSecretFile = mkOption {
                type = secretPath;
                description = ''
                  Runtime path to a file holding the client secret, readable
                  by root. authentik-provider-secret-setup sets it on the
                  provider, getting it as a systemd credential; the app
                  reads the same file.
                '';
              };
              redirectUris = mkOption {
                type = types.nonEmptyListOf types.str;
                description = "Allowed redirect URIs, matched exactly.";
              };
              launchUrl = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "URL the app launcher opens.";
              };
              groups = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [ "git-users" ];
                description = ''
                  Groups allowed to use the application; members of any of
                  them pass. Empty = every user. The groups must exist in
                  Authentik (e.g. synced from the directory) when the
                  blueprint applies.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = ''
        OIDC applications, keyed by slug. Each gets a confidential OAuth2
        provider (scopes openid, email, profile; signed with Authentik's
        self-signed key) and an Application, through a generated blueprint,
        and its client secret is kept equal to clientSecretFile. The issuer
        is <url>/application/o/<slug>/, and the app reads clientSecretFile
        too; for an app on another host, hand it the same secret there.
      '';
    };

    # ── Provider client secrets (the outpost-token pattern for OAuth2) ───────
    providerSecrets = mkOption {
      type = types.attrsOf secretPath;
      default = { };
      description = ''
        OAuth2 provider client secrets to enforce, keyed by provider NAME —
        each value is the runtime path of a file holding the raw client secret.
        A boot-time oneshot (authentik-provider-secret-setup) waits for the
        provider to exist (declare it via services.swag.authentik.blueprints, or make
        it in the UI) and overwrites its client_secret with the file's value
        — the outpost-token pattern: the file is the single source of
        truth for authentik AND the consumer app, so no UI copy step exists.
        Consumer units should order after
        authentik-provider-secret-setup.service.
      '';
    };

    # ── Directory source: users and groups from LDAP ────────────────────────
    directorySource = {
      enable = mkEnableOption ''
        syncing users and groups from an LDAP directory. With
        services.swag.directory on the same host the connection is
        configured for you, including Authentik's own bind account there
      '';
      name = mkOption {
        type = types.str;
        default = "Directory";
        description = "Display name of the LDAP source in Authentik.";
      };
      slug = mkOption {
        type = types.str;
        default = "directory";
        description = "Slug of the LDAP source in Authentik (its stable identifier).";
      };
      url = mkOption {
        type = types.str;
        example = "ldap://127.0.0.1:3890";
        description = ''
          LDAP server URI. Defaults to the local services.swag.directory
          listener when that module is enabled on this host.
        '';
      };
      baseDn = mkOption {
        type = types.str;
        example = "dc=example,dc=com";
        description = ''
          Base DN of the directory. Defaults to services.swag.directory.baseDn
          when that module is enabled on this host.
        '';
      };
      bindUser = mkOption {
        type = types.str;
        default = "authentik";
        description = ''
          Directory account Authentik binds as (uid under ou=people). With
          services.swag.directory on this host the account is declared there
          automatically, in lldap_password_manager when passwordWriteback is
          on (lldap_strict_readonly otherwise).
        '';
      };
      bindPasswordFile = mkOption {
        type = secretPath;
        description = ''
          Runtime path to a file holding the bind account's password,
          readable by root. It reaches only the unit that stores it in
          Authentik, as a systemd credential; with services.swag.directory on
          this host it is also the account's managed password there.
        '';
      };
      passwordWriteback = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Write password changes made in Authentik back to the directory, so
          the directory stays the source of truth for passwords too.
        '';
      };
      idAttribute = mkOption {
        type = types.nullOr types.str;
        default = "entryUUID";
        description = ''
          Directory attribute holding each account's permanent ID (lldap and
          OpenLDAP: entryUUID). The sync stores it on the Authentik user, and
          OIDC clients from services.swag.authentik.oidcClients send it to
          apps as the user's ID (sub). It belongs to the directory account,
          so it survives the Authentik user being deleted and re-created,
          and a new account that reuses a username gets a new one. Users
          without it (local Authentik users) keep Authentik's own hashed ID.
          Apps that already know users by the hashed ID learn the new one
          from subjectMap. null = apps get Authentik's hashed ID for
          everyone.
        '';
      };
      subjectMap = mkOption {
        type = types.str;
        default = "/run/swag-authentik/subject-map";
        readOnly = true;
        description = ''
          File listing, one user per line, "<old ID> <new ID>": the hashed ID
          an app may know a directory user by, and the directory ID OIDC
          clients send instead. Written by authentik-subject-map.service from
          the directory itself, so it is complete before the sync switches a
          user over; refreshed every 10 minutes, and only rewritten when it
          changes. App-side modules watch it and link each
          account to its new ID. Mode 0644; it holds no secrets or usernames.
        '';
      };
      removeDeletedUsers = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Remove an Authentik user once their directory account is gone, so
            the directory decides who exists: removing someone there removes
            them here too (sessions, MFA devices, consents). Checked every
            interval by authentik-directory-prune.service. Only users that came
            from this source are considered, and superusers are never removed.
            To lock someone out but keep their account, deactivate them in
            Authentik instead; deleting a user only in Authentik doesn't
            remove them, the next sync brings them back.
          '';
        };
        maxPerRun = mkOption {
          type = types.ints.positive;
          default = 5;
          description = ''
            Most users one run may remove. A run that would remove more removes
            none and fails the unit instead: a directory answering with far
            fewer users than before is more likely misconfigured or damaged
            than emptied on purpose. The search failing, or finding no users
            at all, is refused the same way.
          '';
        };
        interval = mkOption {
          type = types.str;
          default = "10min";
          description = "How often to check, as a systemd time span.";
        };
      };
    };

    # ── Fleet users: declarative authentik users ────────────────────────────
    users = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          email = mkOption {
            type = types.str;
            description = ''
              Account email. OIDC apps match users by this claim and
              authentik's login asks for it — pick a value worth typing.
            '';
          };
          givenName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Display name; defaults to the username.";
          };
          type = mkOption {
            type = types.enum [ "internal" "external" "service" ];
            default = "internal";
            description = ''
              internal = interactive human account; service = machine account
              (no password expected, authenticate via API tokens instead).
            '';
          };
          passwordFile = mkOption {
            type = types.nullOr secretPath;
            default = null;
            description = ''
              Runtime path to a file holding the raw password. A boot-time oneshot
              (authentik-user-password-setup) poll-waits for the user (the
              users blueprint applies via the worker asynchronously) and
              hashes+sets the password ONLY when it differs — changing the
              file and re-running the oneshot (a switch does) changes the
              password; untouched, nothing
              rehashes and no sessions drop. authentik hashes passwords
              server-side; the declared file remains the single source of
              truth.
            '';
          };
        };
      });
      default = { };
      description = ''
        Declarative users, keyed by username. The module generates a users
        blueprint (applied on worker boot) and a password-sync oneshot per
        user with a passwordFile. akadmin (seeded by cfg.bootstrap) remains
        the break-glass admin, not a daily driver. Consumer modules may add
        their own entries — attrsOf merges across modules.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the firewall for the LDAP outpost (3389) when it is enabled and
        LAN-bound. The authentik server (9000/9443) binds loopback and is
        fronted by swag web on port 80 (opened there), so no extra
        firewall hole is needed for the admin UI. Disable if you tunnel
        everything.
      '';
    };
  };
}