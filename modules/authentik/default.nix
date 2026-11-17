# Authentik identity provider — preset over nix-community/authentik-nix.
#
# Applies `mkDefault`-style values to the upstream `services.authentik.*` (and
# `services.authentik-{proxy,ldap}.*`) option set for an opinionated homelab IdP:
# native authentik server + worker + migrate (DynamicUser, StateDirectory), an
# optional local postgres, the proxy outpost (nginx forward auth) and LDAP
# outpost (for apps that bind LDAP), secrets assembled from runtime files, and an admin web
# UI fronted by swag web (NOT upstream's services.authentik.nginx, which
# this module leaves off). State is relocatable to an external drive via a bind
# mount.
#
# nixos-swag's flake imports the upstream module together with this one
# (nixosModules.authentik), so services.authentik.* is always defined. To pin
# upstream yourself, override the input:
#
#   inputs.nixos-swag.inputs.authentik-nix.follows = "authentik-nix";
#
#   { nixos-swag, ... }: {
#     imports = [ nixos-swag.nixosModules.authentik ];
#     services.swag.authentik.enable = true;
#     services.swag.authentik.secrets.AUTHENTIK_SECRET_KEY = config.age.secrets.authentik-secret-key.path;
#   }
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
with lib;
let
  cfg = config.services.swag.authentik;

  settingsFormat = pkgs.formats.yaml { };

  # Bootstrap password/hash/token are runtime files merged into the same
  # env-file assembly as cfg.secrets (effectiveSecrets), so the one-shot
  # assembly handles them with no extra plumbing.
  bootstrapSecrets =
    optionalAttrs (cfg.bootstrap.passwordFile != null) { AUTHENTIK_BOOTSTRAP_PASSWORD = cfg.bootstrap.passwordFile; }
    // optionalAttrs (cfg.bootstrap.passwordHashFile != null) { AUTHENTIK_BOOTSTRAP_PASSWORD_HASH = cfg.bootstrap.passwordHashFile; }
    // optionalAttrs (cfg.bootstrap.tokenFile != null) { AUTHENTIK_BOOTSTRAP_TOKEN = cfg.bootstrap.tokenFile; };
  # Server env-var secrets = caller secrets + bootstrap password/hash/token.
  effectiveSecrets = cfg.secrets // bootstrapSecrets;
  hasServerSecrets = effectiveSecrets != { };
  # Outpost token keys: attrset of name → tokenKeyFile for enabled outposts
  # that have a token key declared. The module auto-provisions each outpost
  # + token in authentik's DB via an `ak shell` oneshot (authentik-outpost-
  # setup), and the authentik-secrets oneshot writes the per-outpost env file
  # (AUTHENTIK_TOKEN=<key>) that the outpost service reads.
  outpostTokens =
    optionalAttrs (cfg.outposts.proxy.enable && cfg.outposts.proxy.tokenKeyFile != null) {
      proxy = cfg.outposts.proxy.tokenKeyFile;
    }
    // optionalAttrs (cfg.outposts.ldap.enable && cfg.outposts.ldap.tokenKeyFile != null) {
      ldap = cfg.outposts.ldap.tokenKeyFile;
    };
  hasOutpostTokens = outpostTokens != { };
  needsAssembly = hasServerSecrets || hasOutpostTokens;
  # OAuth2 provider client secrets (providerSecrets): name → runtime file. The
  # authentik-provider-secret-setup oneshot waits for the provider (created
  # by a blueprint or manually) and overwrites its client_secret with the
  # declared value — the outpost-token pattern for OAuth2 clients: the file
  # is the single source of truth for BOTH authentik and the consumer.
  hasProviderSecrets = cfg.providerSecrets != { };
  # Fleet users: the module generates a users blueprint (existence only —
  # username/email/type; passwords never live in it) and a password-sync
  # oneshot (hashes+sets when differing). Any consumer module can append
  # entries via attrsOf merge.
  hasUsers = cfg.users != { };
  hasUserPasswords = any (u: u.passwordFile != null) (attrValues cfg.users);

  # swag web provides the nginx backbone + the services.swag.web.vhosts map
  # the admin UI registers with. swag dns provides the internal zone the
  # admin subdomain is derived from. Both via guarded `options.services ? swag.<module>`
  # checks so a host without them doesn't force the cfg namespace.
  hasLocalweb = options.services ? swag.web && config.services.swag.web.enable;
  hasLocaldns = options.services ? swag.dns && config.services.swag.dns.enable;
  hasCloudflared = options.services ? cloudflared && config.services.cloudflared.enable;

  # The local subdomain server_name for the admin UI vhost: "auth" under the
  # swag dns internal zone. null when swag dns is absent AND no explicit
  # dashboard.domain — then there's no local vhost (public access via
  # dashboard.publicDomain + cloudflared, or the host sets up nginx manually).
  # A let binding, not a config contribution, so it cannot recurse (see the
  # effectiveDomain pattern in nixos-hermes integrations-localweb).
  effectiveDomain =
    if cfg.dashboard.domain != null
    then cfg.dashboard.domain
    else if hasLocaldns
    then "auth.${config.services.swag.dns.internalDomain}"
    else null;

  # Env files assembled by the authentik-secrets oneshot from the runtime
  # secret files (raw values → `KEY=value` lines). systemd loads EnvironmentFile as
  # root before ExecStart, so root-only 0600 files are fine — the DynamicUser
  # authentik process never reads them, it gets the vars via systemd. Non-secret
  # env rides on systemd Environment instead (see below), so these files are
  # secrets only.
  secretsEnvFile = "/run/authentik-secrets/env";
  outpostEnvFile = name: "/run/authentik-secrets/${name}.env";

  # Units that must wait for the assembly oneshot: the three server units when
  # there are server secrets, plus each enabled outpost with a token key.
  assemblyDependents =
    (if hasServerSecrets then [
      "authentik.service"
      "authentik-worker.service"
      "authentik-migrate.service"
    ] else [ ])
    ++ optional (outpostTokens ? proxy) "authentik-proxy.service"
    ++ optional (outpostTokens ? ldap) "authentik-ldap.service";

  # The admin UI vhost: nginx fronts authentik's HTTP listener (:9000), NOT the
  # HTTPS one (:9443). This is the standard authentik reverse-proxy pattern: the
  # connection to authentik is HTTP so Django's is_secure() is false, and the
  # external scheme is driven by X-Forwarded-Proto (set by localweb's
  # recommendedProxySettings = $scheme). With an http:80 front, X-Forwarded-Proto
  # is http → authentik generates http URLs + non-Secure cookies → works. With a
  # future TLS front, X-Forwarded-Proto is https → authentik uses https. Proxying
  # to :9443 instead would force scheme=https always (SECURE_PROXY_SSL_HEADER
  # only upgrades, never downgrades) and break the http front with Secure cookies
  # + https URLs that have no listener. /static/ is served by nginx from the
  # upstream frontend package (no proxy); /ws/ is a websocket proxy to :9000.
  adminVhost = {
    host = "127.0.0.1";
    port = 9000;
    scheme = "http";
    extraLocations = {
      "/ws/" = {
        proxyPass = "http://127.0.0.1:9000";
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
      "/static/" = {
        alias = "${config.services.authentik.authentikComponents.frontend}/";
        extraConfig = "expires max; access_log off;";
      };
    };
  };

  # nginx forward auth against the proxy outpost, expressed through swag
  # web's generic vhost hooks (see the Forward-auth block below).
  outpostUrl = "http://${cfg.outposts.proxy.listenHTTP}";
  forwardAuthVhost = {
    rootExtraConfig = "auth_request /outpost.goauthentik.io/auth;";
    extraConfig = "error_page 401 = @authentik_login;";
    extraLocations = {
      "= /outpost.goauthentik.io/auth" = {
        recommendedProxySettings = false;
        extraConfig = ''
          internal;
          proxy_pass ${outpostUrl}/outpost.goauthentik.io/auth/nginx;
          proxy_set_header Host $host;
          proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
          proxy_set_header X-Forwarded-Host $http_host;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Cookie $http_cookie;
        '';
      };
      "/outpost.goauthentik.io/" = {
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_pass ${outpostUrl};
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Host $http_host;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
      "@authentik_login" = {
        extraConfig = ''
          return 302 $scheme://$http_host/outpost.goauthentik.io/start?rd=$request_uri;
        '';
      };
    };
  };

  # Properties from the authentik service's serviceConfig, passed to
  # `systemd-run` so the outpost-setup oneshot can run `manage.py shell` in
  # the same context as the authentik server (same user, env, state dir).
  # Same pattern as the upstream `ak` wrapper.
  akOptions = flatten (
    mapAttrsToList
      (k: vs: map (v: "--property ${k}=${if isBool v then boolToString v else toString v}") (toList vs))
      (removeAttrs config.systemd.services.authentik.serviceConfig [
        "ExecStart"
        "ExecStartPre"
        "Restart"
        "RestartSec"
        "WorkingDirectory"
      ])
  );

  managePy = "${config.services.authentik.authentikComponents.manage}/bin/manage.py";

  # Generates the shell script to provision one outpost + token via
  # `systemd-run → manage.py shell`. The oneshot runs as root; `systemd-run`
  # creates a transient unit as the authentik user with the server's
  # serviceConfig (akOptions), passing the token key via --setenv. The Python
  # code creates/updates the Outpost model and sets its token's key to the
  # pre-defined value. Idempotent: get_or_create + token.key = ... save.
  mkOutpostSetup = name: outpostName: typeEnum: tokenPath: hostEnv: hostBrowserEnv: ''
    TOKEN=$(cat ${tokenPath})
    ${config.systemd.package}/bin/systemd-run --wait --pipe --collect \
      ${concatStringsSep " \\\n      " akOptions} \
      --setenv OUTPOST_TOKEN="$TOKEN" \
      --setenv OUTPOST_NAME="${outpostName}" \
      --setenv OUTPOST_TYPE_ENUM="${typeEnum}" \
      ${hostEnv} \
      ${hostBrowserEnv} \
      --working-directory /var/lib/authentik \
      -- ${managePy} shell -c '
import os
from dataclasses import asdict
from authentik.outposts.models import Outpost, OutpostType
key = os.environ["OUTPOST_TOKEN"]
name = os.environ["OUTPOST_NAME"]
otype = os.environ["OUTPOST_TYPE_ENUM"]
type_map = {"proxy": OutpostType.PROXY, "ldap": OutpostType.LDAP}
outpost, created = Outpost.objects.get_or_create(
    name=name,
    defaults={"type": type_map[otype]},
)
# Set authentik_host in the outpost config (the admin UI reads this;
# AUTHENTIK_HOST env var overrides at runtime but the stored config is
# what the UI displays — without it the outpost shows a "domain not
# configured" warning).
config = outpost.config
config.authentik_host = os.environ.get("OUTPOST_HOST", "http://localhost:9000")
browser = os.environ.get("OUTPOST_HOST_BROWSER")
if browser:
    config.authentik_host_browser = browser
outpost.config = config
outpost.save()
token = outpost.token
token.key = key
token.save()
print(f"Outpost {name}: token set (created={created})")
'
  '';

  # Generates the shell script to overwrite one OAuth2 provider's
  # client_secret with the declared value (`manage.py shell` in a transient
  # unit as the authentik user). The provider row itself comes from a
  # blueprint (or the UI) — this poll-waits for it to appear (worker applies
  # blueprints asynchronously after boot), then overwrites the secret if it
  # differs. client_secret is a plain CharField in authentik (no hashing /
  # column encryption), so the ORM write is authoritative. Idempotent + safe
  # to re-run on every boot.
  mkProviderSecretSetup = name: secretPath: ''
    PROVIDER_SECRET=$(cat ${secretPath})
    ${config.systemd.package}/bin/systemd-run --wait --pipe --collect \
      ${concatStringsSep " \\\n      " akOptions} \
      --setenv PROVIDER_NAME="${name}" \
      --setenv PROVIDER_SECRET="$PROVIDER_SECRET" \
      --working-directory /var/lib/authentik \
      -- ${managePy} shell -c '
import os
import time
from authentik.providers.oauth2.models import OAuth2Provider

name = os.environ["PROVIDER_NAME"]
secret = os.environ["PROVIDER_SECRET"]

provider = None
for _ in range(90):
    try:
        provider = OAuth2Provider.objects.get(name=name)
        break
    except OAuth2Provider.DoesNotExist:
        time.sleep(2)

if provider is None:
    raise SystemExit(
        f"OAuth2Provider {name!r} did not exist after 180s (blueprint not applied?)"
    )

if provider.client_secret == secret:
    print(f"provider {name}: client_secret already in sync")
else:
    provider.client_secret = secret
    provider.save(update_fields=["client_secret"])
    print(f"provider {name}: client_secret overwritten")
'
  '';

  # Generates the shell script to set one fleet user's password (`manage.py
  # shell` in a transient unit as the authentik user). Poll-waits for the
  # user (the users blueprint applies via the worker asynchronously after
  # boot), then hashes+sets ONLY when the stored hash doesn't match the
  # declared password — set_password rehashes, and a rehash invalidates
  # other sessions, which is why this writes unconditionally.
  mkUserPasswordSetup = name: secretPath: ''
    USER_PASSWORD=$(cat ${secretPath})
    ${config.systemd.package}/bin/systemd-run --wait --pipe --collect \
      ${concatStringsSep " \\\n      " akOptions} \
      --setenv USER_NAME="${name}" \
      --setenv USER_PASSWORD="$USER_PASSWORD" \
      --working-directory /var/lib/authentik \
      -- ${managePy} shell -c '
import os
import time
from authentik.core.models import User

name = os.environ["USER_NAME"]
secret = os.environ["USER_PASSWORD"]

user = None
for _ in range(90):
    user = User.objects.filter(username=name).first()
    if user is not None:
        break
    time.sleep(2)

if user is None:
    raise SystemExit(
        f"User {name!r} did not exist after 180s (users blueprint not applied?)"
    )

if user.check_password(secret):
    print(f"user {name}: password already in sync")
else:
    user.set_password(secret)
    user.save(update_fields=["password"])
    print(f"user {name}: password set")
'
  '';

  # Non-secret env = caller env + the bootstrap email (AUTHENTIK_BOOTSTRAP_EMAIL),
  # applied to all three authentik units via systemd Environment.
  effectiveEnvironment = cfg.environment
    // optionalAttrs (cfg.bootstrap.email != null) { AUTHENTIK_BOOTSTRAP_EMAIL = cfg.bootstrap.email; };

  # Auto-generated blueprint for proxy forward-auth apps. Creates a
  # ProxyProvider + Application per app and assigns all to the proxy outpost.
  # Uses raw YAML (pkgs.writeText) instead of settingsFormat because !KeyOf
  # tags (cross-entry PK references) can't be produced by the Nix→YAML generator.
  hasProxyApps = cfg.apps != { } && cfg.outposts.proxy.enable;
  proxyAppsBlueprintYaml = concatStringsSep "\n" (
    [
      "version: 1"
      "metadata:"
      "  name: nix-config-proxy-apps"
      "  labels:"
      "    blueprints.goauthentik.io/instantiate: \"true\""
      "entries:"
      # Reference existing system flows (find by slug, don't change)
      "  - model: authentik_flows.flow"
      "    id: auth-flow"
      "    identifiers:"
      "      slug: default-provider-authorization-implicit-consent"
      "    state: present"
      "    attrs: {}"
      "  - model: authentik_flows.flow"
      "    id: inv-flow"
      "    identifiers:"
      "      slug: default-provider-invalidation-flow"
      "    state: present"
      "    attrs: {}"
    ]
    ++ flatten (mapAttrsToList (name: app: [
      "  - model: authentik_providers_proxy.proxyprovider"
      "    id: provider-${name}"
      "    identifiers:"
      "      name: \"${name}\""
      "    state: present"
      "    attrs:"
      "      name: \"${name}\""
      "      authorization_flow: !KeyOf auth-flow"
      "      invalidation_flow: !KeyOf inv-flow"
      "      external_host: \"${app.host}\""
      "      internal_host: \"${if app.internalHost != null then app.internalHost else ""}\""
      "      mode: ${app.mode}"
      "  - model: authentik_core.application"
      "    identifiers:"
      "      slug: \"${name}\""
      "    state: present"
      "    attrs:"
      "      name: \"${name}\""
      "      provider: !KeyOf provider-${name}"
      "      meta_launch_url: \"${if app.metaLaunchUrl != null then app.metaLaunchUrl else app.host}\""
    ]) cfg.apps)
    ++ [
      "  - model: authentik_outposts.outpost"
      "    identifiers:"
      "      name: \"authentik Embedded Proxy\""
      "    state: present"
      "    attrs:"
      "      providers:"
    ]
    ++ map (name: "        - !KeyOf provider-${name}") (attrNames cfg.apps)
  );
  proxyAppsBlueprint = pkgs.runCommand "proxy-apps-blueprint" { }
    ''
      mkdir $out
      cp ${pkgs.writeText "proxy-apps.yaml" proxyAppsBlueprintYaml} $out/proxy-apps.yaml
    '';

  # Custom blueprints + the system blueprints assembled into one blueprints_dir.
  # Uses cp (not symlinkJoin) because authentik's retrieve_file resolves symlinks
  # and checks the resolved path is inside blueprints_dir — symlinks to other
  # nix store paths fail that check ("Invalid blueprint path").
  blueprintsDir = pkgs.runCommand "authentik-blueprints" { }
    ''
      mkdir -p $out
      # System + default blueprints (real copies, not symlinks)
      cp -r ${config.services.authentik.authentikComponents.staticWorkdirDeps}/blueprints/. $out/
      # Custom blueprints from cfg.blueprints (attrsets → settingsFormat, or paths)
      ${concatStringsSep "\n" (mapAttrsToList (name: v:
        if isAttrs v
        then "cp ${settingsFormat.generate "blueprint-${name}.yaml" v} $out/blueprint-${name}.yaml"
        else "cp ${v} $out/$(basename ${v})"
      ) cfg.blueprints)}
      # Auto-generated proxy-apps blueprint
      ${optionalString hasProxyApps "cp ${proxyAppsBlueprint}/proxy-apps.yaml $out/proxy-apps.yaml"}
    '';
in
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.environmentFile != null || cfg.secrets ? AUTHENTIK_SECRET_KEY;
          message = "services.swag.authentik needs AUTHENTIK_SECRET_KEY — set services.swag.authentik.secrets.AUTHENTIK_SECRET_KEY (a runtime file holding `openssl rand -base64 60` output) or services.swag.authentik.environmentFile.";
        }
        {
          assertion = !(cfg.outposts.proxy.enable) || cfg.outposts.proxy.tokenKeyFile != null;
          message = "services.swag.authentik.outposts.proxy.enable requires outposts.proxy.tokenKeyFile (a runtime file containing the raw token key).";
        }
        {
          assertion = !(cfg.outposts.ldap.enable) || cfg.outposts.ldap.tokenKeyFile != null;
          message = "services.swag.authentik.outposts.ldap.enable requires outposts.ldap.tokenKeyFile (a runtime file containing the raw token key).";
        }
        {
          assertion = cfg.apps == { } || cfg.outposts.proxy.enable;
          message = "services.swag.authentik.apps requires outposts.proxy.enable + outposts.proxy.tokenKeyFile — apps are auto-assigned to the proxy outpost via blueprint.";
        }
        {
          assertion = cfg.dashboard.publicDomain == null || hasLocalweb;
          message = "services.swag.authentik.dashboard.publicDomain requires swag web (services.swag.web) on the host — the admin UI is fronted by nginx, not exposed directly.";
        }
        {
          assertion = cfg.dashboard.publicDomain == null || hasCloudflared;
          message = "services.swag.authentik.dashboard.publicDomain requires nixos-cloudflared on the host — publicDomain is specifically for cloudflared ingress. Use the local subdomain (swag dns) for LAN access.";
        }
        {
          assertion = !(cfg.bootstrap.passwordFile != null && cfg.bootstrap.passwordHashFile != null);
          message = "services.swag.authentik.bootstrap: set passwordFile OR passwordHashFile, not both (authentik errors if AUTHENTIK_BOOTSTRAP_PASSWORD and AUTHENTIK_BOOTSTRAP_PASSWORD_HASH are both set).";
        }
      ];
    }

    # ── Upstream surface ────────────────────────────────────────────────────
    {
      services.authentik = {
        enable = true;
        createDatabase = cfg.database.create;

        # Freeform settings deep-merged with the email shorthand. The upstream
        # module sets settings.postgresql defaults itself when createDatabase,
        # so we don't duplicate that here.
        settings = mkMerge [
          cfg.settings
          { email = cfg.email; }
          (mkIf (cfg.blueprints != { } || hasProxyApps) { blueprints_dir = "${blueprintsDir}"; })
        ];

        # When there are server secrets, use the assembled env file; otherwise
        # fall through to a caller-supplied environmentFile (the escape hatch for
        # another secrets backend). Both null → upstream default (no env file).
        environmentFile = if hasServerSecrets then secretsEnvFile else cfg.environmentFile;
      };

      # Non-secret env applied to all three authentik units (server/worker/
      # migrate) via systemd Environment — NOT the env file (secrets only).
      # Includes the bootstrap email (AUTHENTIK_BOOTSTRAP_EMAIL).
      systemd.services.authentik.environment = effectiveEnvironment;
      systemd.services.authentik-worker.environment = effectiveEnvironment;
      systemd.services.authentik-migrate.environment = effectiveEnvironment;
    }

    # ── Secrets: assemble env files ─────────────────────────────────────────
    # One convention everywhere: every secret file holds the RAW value. The oneshot
    # assembles `KEY=value` into a server env file (for `secrets` + bootstrap)
    # and a per-outpost env file (AUTHENTIK_TOKEN=<value>) for each outpost in
    # `outpostTokens`. systemd loads these as root before each service's
    # ExecStart; non-secret env rides on systemd Environment instead.
    (mkIf needsAssembly {
      systemd.services.authentik-secrets = {
        description = "Assemble authentik environment files from secret files";
        before = assemblyDependents;
        requiredBy = assemblyDependents;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "authentik-secrets";
          RuntimeDirectoryMode = "0750";
        };
        script = ''
          umask 077
          ${optionalString hasServerSecrets ''
            {
              ${concatStringsSep "\n" (
                # The \" here is inside the inner double-quoted Nix string (the
                # mapAttrsToList lambda arg), where \" escapes to a literal " —
                # so the produced shell line is printf '%s=%s\n' 'KEY' "$(cat ...)".
                mapAttrsToList (k: path:
                  "printf '%s=%s\n' '${k}' \"$(cat ${path})\""
                ) effectiveSecrets
              )}
            } > ${secretsEnvFile}
          ''}
          ${concatStringsSep "\n" (
            mapAttrsToList (name: path:
              "printf 'AUTHENTIK_TOKEN=%s\n' \"$(cat ${path})\" > ${outpostEnvFile name}"
            ) outpostTokens
          )}
        '';
      };
    })

    # ── Provider client secret sync ─────────────────────────────────────────
    # Overwrite OAuth2Provider.client_secret from secret files (providerSecrets).
    # Poll-waits for the provider (blueprints apply via the worker
    # asynchronously after boot); consumer units order after this unit.
    (mkIf hasProviderSecrets {
      systemd.services.authentik-provider-secret-setup = {
        description = "Sync declarative OAuth2 provider client secrets from secret files";
        after = [ "authentik-migrate.service" "authentik-worker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 300;
        };
        path = [ pkgs.coreutils ];
        script = concatStringsSep "\n" (
          # The option value is the runtime path of the raw secret; a path to
          # ciphertext would make systemd-run reject the multi-line env
          # assignment ("Cannot assign environment variable PROVIDER_SECRET=...").
          mapAttrsToList mkProviderSecretSetup cfg.providerSecrets
        );
      };
    })

    # ── Fleet users: blueprint + password sync ──────────────────────────────
    # The users blueprint goes through the ATTRSET branch of cfg.blueprints
    # (settingsFormat-rendered, stable filename — no !KeyOf-style tags hold
    # here because existence-only entries never need cross-entry pk refs).
    # The password oneshot runs after the worker and uses check_password to
    # skip no-op rehashes.
    (mkIf hasUsers {
      services.swag.authentik.blueprints."nix-config-users" = {
        version = 1;
        metadata.name = "nix-config-users";
        metadata.labels."blueprints.goauthentik.io/instantiate" = "true";
        entries = flatten (mapAttrsToList (name: u: [{
          model = "authentik_core.user";
          identifiers.username = name;
          state = "present";
          attrs = {
            name = if u.givenName != null then u.givenName else name;
            email = u.email;
            type = u.type;
            path = "users";
          };
        }]) config.services.swag.authentik.users);
      };

      systemd.services.authentik-user-password-setup = mkIf hasUserPasswords {
        description = "Sync declarative authentik user passwords from secret files";
        after = [ "authentik-migrate.service" "authentik-worker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 300;
        };
        path = [ pkgs.coreutils ];
        script = concatStringsSep "\n" (
          flatten (mapAttrsToList (name: u:
            optional (u.passwordFile != null) (
              mkUserPasswordSetup name u.passwordFile
            )
          ) cfg.users)
        );
      };
    })

    # ── Outpost auto-provision: create/update outpost + token in the DB ──────
    # An `ak shell` oneshot (runs as root, spawns a transient unit as the
    # authentik user via systemd-run) that creates/updates each enabled
    # outpost and sets its token key to the pre-defined value from the token
    # file. Idempotent (get_or_create + token.key = ...). Runs after
    # authentik-migrate (needs the DB schema) and authentik-secrets (needs
    # the server env file), before the outpost services (they need the
    # outpost + token to exist in the DB to authenticate).
    (mkIf hasOutpostTokens {
      systemd.services.authentik-outpost-setup = {
        description = "Provision authentik outposts + tokens from Nix configuration";
        after = [ "authentik-migrate.service" ]
          ++ optional hasServerSecrets "authentik-secrets.service";
        before = optional (outpostTokens ? proxy) "authentik-proxy.service"
          ++ optional (outpostTokens ? ldap) "authentik-ldap.service";
        requiredBy = optional (outpostTokens ? proxy) "authentik-proxy.service"
          ++ optional (outpostTokens ? ldap) "authentik-ldap.service";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 120;
        };
        path = [ pkgs.coreutils ];
        script = concatStringsSep "\n" (
          optional (outpostTokens ? proxy)
            (mkOutpostSetup "proxy" "authentik Embedded Proxy" "proxy"
              outpostTokens.proxy
              ''--setenv OUTPOST_HOST="http://localhost:9000"''
              (if effectiveDomain != null
               then ''--setenv OUTPOST_HOST_BROWSER="http://${effectiveDomain}"''
               else ''--setenv OUTPOST_HOST_BROWSER=""''))
          ++ optional (outpostTokens ? ldap)
            (mkOutpostSetup "ldap" "authentik Embedded LDAP" "ldap"
              outpostTokens.ldap
              ''--setenv OUTPOST_HOST="http://localhost:9000"''
              (if effectiveDomain != null
               then ''--setenv OUTPOST_HOST_BROWSER="http://${effectiveDomain}"''
               else ''--setenv OUTPOST_HOST_BROWSER=""''))
        );
      };
    })

    # ── Outposts: proxy (forward auth) + ldap ──────────────────────────────
    # AUTHENTIK_HOST is the URL the outpost uses to reach the authentik server
    # (API calls). For an embedded outpost on the same host, the direct HTTP
    # listener (localhost:9000) is most efficient — no nginx hop. The
    # AUTHENTIK_HOST_BROWSER override (the URL browsers use for auth redirects)
    # is set to the localweb-fronted domain when available, so end-user auth
    # flows redirect to the nginx URL, not localhost.
    (mkIf cfg.outposts.proxy.enable {
      services.authentik-proxy = {
        enable = true;
        listenHTTP = cfg.outposts.proxy.listenHTTP;
        environmentFile = outpostEnvFile "proxy";
      };
      systemd.services.authentik-proxy.environment = {
        AUTHENTIK_HOST = mkDefault "http://localhost:9000";
      }
      // optionalAttrs (effectiveDomain != null) {
        AUTHENTIK_HOST_BROWSER = mkDefault "http://${effectiveDomain}";
      };
    })

    (mkIf cfg.outposts.ldap.enable {
      services.authentik-ldap = {
        enable = true;
        environmentFile = outpostEnvFile "ldap";
      };
      # The upstream authentik-ldap module only exposes listenMetrics; the LDAP
      # listen address is the AUTHENTIK_LISTEN__LDAP env var.
      systemd.services.authentik-ldap.environment = {
        AUTHENTIK_LISTEN__LDAP = cfg.outposts.ldap.listen;
        AUTHENTIK_HOST = mkDefault "http://localhost:9000";
      }
      // optionalAttrs (effectiveDomain != null) {
        AUTHENTIK_HOST_BROWSER = mkDefault "http://${effectiveDomain}";
      };
    })

    # ── State relocation (bind mount) ──────────────────────────────────────
    # ── State relocation (bind mount) ────────────────────────
    # Upstream uses StateDirectory=authentik + DynamicUser=true. That is
    # INCOMPATIBLE with a bind mount at /var/lib/authentik: with DynamicUser,
    # systemd renames /var/lib/authentik → /var/lib/private/authentik (private
    # namespace) and you can't rename a mount point (EBUSY). So when relocating,
    # we disable DynamicUser and use a real `authentik` system user (stable
    # uid/gid) so StateDirectory stays public (/var/lib/authentik, no private
    # migration) and the bind mount provides the storage. The state-dir oneshot
    # creates + chowns the source to the authentik user so the service can write
    # through the mount. Slightly less isolation than upstream's DynamicUser,
    # but the only way to persist authentik media on an external drive. The
    # authentik DB (the important state) lives in postgres regardless.
    #
    # NB: leaving stateDir at the default /var/lib/authentik skips all of this
    # and keeps upstream's DynamicUser intact (media on the root fs).
    (mkIf (cfg.stateDir != "/var/lib/authentik") {
      users.users.authentik = {
        isSystemUser = true;
        group = "authentik";
      };
      users.groups.authentik = { };

      fileSystems."/var/lib/authentik" = {
        device = cfg.stateDir;
        fsType = "none";
        options = [
          "bind"
          "x-systemd.requires=authentik-state-dir.service"
          "x-systemd.after=authentik-state-dir.service"
        ];
        depends = [ (dirOf cfg.stateDir) ];
      };
      systemd.services.authentik-state-dir = {
        description = "Create + chown authentik state source directory for the bind mount";
        path = [ pkgs.coreutils ];
        # Run in the local-fs phase so the bind mount that Requires this unit
        # doesn't cycle back through sysinit. A plain service's DefaultDependencies
        # add After=sysinit.target, which would cycle:
        #   local-fs.target → var-lib-authentik.mount → this → sysinit.target → local-fs.target
        # DefaultDependencies=no drops that implicit edge; RequiresMountsFor orders
        # us after the parent mount (/Volumes/Server); Before=local-fs.target keeps
        # us in the local-fs phase. /etc/passwd lives on the root fs (mounted in the
        # initrd) and is written by systemd-sysusers before local-fs.target, so the
        # chown by name resolves the authentik user here.
        before = [ "local-fs.target" ];
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = [ (dirOf cfg.stateDir) ];
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p ${cfg.stateDir}
          chown -R authentik:authentik ${cfg.stateDir}
        '';
      };

      # Disable DynamicUser on all three authentik units so they run as the real
      # authentik user (stable uid) and StateDirectory stays public, letting the
      # bind mount provide the storage without the EBUSY private-namespace move.
      systemd.services.authentik.serviceConfig.DynamicUser = mkForce false;
      systemd.services.authentik-worker.serviceConfig.DynamicUser = mkForce false;
      systemd.services.authentik-migrate.serviceConfig.DynamicUser = mkForce false;
    })

    # ── Admin UI: local subdomain vhost via swag web ───────────────
    (mkIf (hasLocalweb && effectiveDomain != null) {
      services.swag.web.vhosts.${effectiveDomain} = adminVhost;
    })

    # ── Admin UI: public-domain vhost (same backend, for cloudflared) ──────
    (mkIf (hasLocalweb && cfg.dashboard.publicDomain != null) {
      services.swag.web.vhosts.${cfg.dashboard.publicDomain} = adminVhost;
    })

    # ── Cloudflared ingress to the public admin UI ──────────────────────────
    (mkIf (hasCloudflared && cfg.dashboard.publicDomain != null) {
      services.cloudflared.tunnels."${config.networking.hostName}".ingress."${cfg.dashboard.publicDomain}" =
        "http://127.0.0.1:80";
    })

    # ── Firewall: LDAP outpost (LAN-bound by default) ──────────────────────
    (mkIf (cfg.openFirewall && cfg.outposts.ldap.enable) {
      networking.firewall.allowedTCPPorts = [ 3389 ];
    })

    # ── Forward-auth: gate app vhosts with the proxy outpost ────────────────
    # For each app in cfg.apps, the vhost matching app.host's hostname gets
    # nginx auth_request wiring through swag web's generic hooks: the
    # subrequest on the root location (rootExtraConfig), the outpost
    # locations (extraLocations) and the login redirect on 401
    # (extraConfig). Several modules can contribute to the same vhost — the
    # app's own module sets host+port, this one adds the gate.
    (mkIf (cfg.apps != { } && cfg.outposts.proxy.enable && hasLocalweb) {
      services.swag.web.vhosts = genAttrs (mapAttrsToList (_: app:
        # Extract hostname from app.host URL (e.g. "http://hermes.lan.io" → "hermes.lan.io")
        builtins.head (builtins.match "https?://([^:/]+).*" app.host)
      ) cfg.apps) (_: forwardAuthVhost);
    })
  ]);
}