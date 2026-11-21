# User directory — lldap as the source of truth for users and groups.
#
# Runs nixpkgs' services.lldap and provisions services.swag.directory.users
# and .groups into it (swag-directory-provision, a oneshot driving lldap's
# GraphQL API). Other services consume the directory over LDAP: Authentik
# syncs users from it, LDAP-only apps can bind to it directly.
#
# Enrollment (optional): swag-directory-enroll.socket, one instance per
# connection, creates accounts for a sign-up front end (Authentik's
# enrollment flow). The socket's group is the access control; the instance
# grants only grantableGroups (see enroll.py).
#
# Secrets: the admin password (and the JWT secret, when given) reach lldap as
# systemd credentials, and the admin password plus each user's initial
# password reach the provisioning unit the same way. systemd reads the
# root-only source files and exposes copies only to that unit, so no other
# user or service — the lldap user included, for the provisioning secrets —
# can read them. Nothing secret is passed on a command line.
#
# Passwords: the admin password follows config (reset on every start). A
# user's initialPasswordFile is applied only when provisioning creates the
# user; from then on the password is theirs to change.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
with lib;
let
  cfg = config.services.swag.directory;
  state = import ../../lib/state.nix { inherit lib pkgs; };

  # Integration blocks are wrapped in optionalAttrs on the option's existence
  # (options never depend on config, so no recursion): a false mkIf still
  # counts as a definition, which fails when the other module isn't imported.
  webDeclared = options.services ? swag.web;
  hasWeb = options.services ? swag.web && config.services.swag.web.enable;
  hasDns = options.services ? swag.dns && config.services.swag.dns.enable;

  dashboardDomain =
    if cfg.dashboard.domain != null then
      cfg.dashboard.domain
    else if hasDns then
      "ldap.${config.services.swag.dns.internalDomain}"
    else
      null;

  # Read from the vhost, so a host overriding its tls directly counts too.
  dashboardTls =
    hasWeb && dashboardDomain != null
    && (config.services.swag.web.vhosts.${dashboardDomain}.tls or false);

  # systemd places LoadCredential= files here (CREDENTIALS_DIRECTORY).
  lldapCreds = "/run/credentials/lldap.service";

  usersWithPassword = filterAttrs (
    _: u: u.initialPasswordFile != null || u.passwordFile != null
  ) cfg.users;

  # The units' Python, next to the lldap client they share (a store path,
  # so the script directory on sys.path can't be written to).
  scripts = pkgs.runCommand "swag-directory-scripts" { } ''
    mkdir $out
    cp ${./lldap.py} $out/lldap.py
    cp ${./provision.py} $out/provision.py
    cp ${./enroll.py} $out/enroll.py
    cp ${./groups.py} $out/groups.py
  '';
  # -E -s: no PYTHON* environment, no user site; unlike -I, keeps the
  # script's directory on sys.path for lldap.py.
  python = "${pkgs.python3}/bin/python3 -E -s";

  lldapClientConfig = {
    httpUrl = "http://127.0.0.1:${toString cfg.http.port}";
    ldapUrl = "ldap://127.0.0.1:${toString cfg.ldap.port}";
    inherit (cfg) baseDn adminUsername;
    ldappasswd = "${pkgs.openldap}/bin/ldappasswd";
    ldapwhoami = "${pkgs.openldap}/bin/ldapwhoami";
  };

  provisionConfig = pkgs.writeText "swag-directory.json" (
    builtins.toJSON (
      lldapClientConfig
      // {
        groups = attrNames cfg.groups;
        users = mapAttrs (_: u: {
          inherit (u) email displayName groups;
          hasInitialPassword = u.initialPasswordFile != null;
          managedPassword = u.passwordFile != null;
        }) cfg.users;
      }
    )
  );

  en = cfg.enrollment;
  enrollConfig = pkgs.writeText "swag-directory-enroll.json" (
    builtins.toJSON (lldapClientConfig // { inherit (en) grantableGroups minPasswordLength heldNamesDir; })
  );

  # The units that hold the lldap admin password: no identity of their own,
  # nothing writable but a private /tmp, network only to localhost.
  adminUnitHardening = {
    DynamicUser = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectProc = "invisible";
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
    ];
    IPAddressAllow = "localhost";
    IPAddressDeny = "any";
    UMask = "0077";
  };

  groupsConfig = pkgs.writeText "swag-directory-groups.json" (
    builtins.toJSON (lldapClientConfig // { groups = attrNames cfg.groups; })
  );
  # Splits groups.py's output into one file per group, replacing a file
  # only when it changed (so watchers fire on real changes). Runs as root
  # after the sandboxed script, which can't write there.
  groupsOut = "${dirOf cfg.groupMembers}/.groups.out";
  publishGroups = pkgs.writeShellScript "swag-directory-groups-publish" ''
    set -eu
    dir=${cfg.groupMembers}
    for g in ${escapeShellArgs (attrNames cfg.groups)}; do
      : > "$dir/.$g.new"
    done
    while read -r kind group id name; do
      case "$kind" in
        GROUP) [ -e "$dir/.$group.new" ] && printf '%s %s\n' "$id" "$name" >> "$dir/.$group.new" ;;
      esac
    done < ${groupsOut}
    for g in ${escapeShellArgs (attrNames cfg.groups)}; do
      ${pkgs.coreutils}/bin/sort -o "$dir/.$g.new" "$dir/.$g.new"
      if ${pkgs.diffutils}/bin/cmp -s "$dir/.$g.new" "$dir/$g"; then
        rm "$dir/.$g.new"
      else
        chmod 0644 "$dir/.$g.new"
        mv "$dir/.$g.new" "$dir/$g"
        echo "group $g: $(${pkgs.coreutils}/bin/wc -l < "$dir/$g") members published" >&2
      fi
    done
    rm -f ${groupsOut}
  '';

  builtinGroups = [
    "lldap_admin"
    "lldap_password_manager"
    "lldap_strict_readonly"
  ];
  unknownGroups = filter (g: !(cfg.groups ? ${g}) && !(elem g builtinGroups)) (
    unique (concatMap (u: u.groups) (attrValues cfg.users))
  );
in
{
  imports = [
    ./options.nix
    ../../lib/state-option.nix
  ];

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = all (u: u.initialPasswordFile == null || u.passwordFile == null) (attrValues cfg.users);
          message = "services.swag.directory.users: set initialPasswordFile or passwordFile on a user, not both.";
        }
        {
          assertion = all (g: builtins.match "[A-Za-z0-9_][A-Za-z0-9._-]*" g != null) (attrNames cfg.groups);
          message = "services.swag.directory.groups: names may use letters, digits, '.', '_' and '-', and not start with '.' or '-' (each becomes a file under groupMembers).";
        }
        {
          assertion = unknownGroups == [ ];
          message = "services.swag.directory.users reference undeclared groups: ${concatStringsSep ", " unknownGroups}. Declare them in services.swag.directory.groups.";
        }
      ];

      services.lldap = {
        enable = true;
        settings = {
          ldap_base_dn = cfg.baseDn;
          ldap_user_dn = cfg.adminUsername;
          ldap_host = cfg.ldap.address;
          ldap_port = cfg.ldap.port;
          http_host = cfg.http.address;
          http_port = cfg.http.port;
          ldap_user_pass_file = "${lldapCreds}/admin-password";
          force_ldap_user_pass_reset = "always";
        }
        // optionalAttrs (cfg.jwtSecretFile != null) {
          jwt_secret_file = "${lldapCreds}/jwt-secret";
        }
        // optionalAttrs (dashboardDomain != null) {
          http_url = "${if dashboardTls then "https" else "http"}://${dashboardDomain}";
        };
      };

      systemd.services.lldap.serviceConfig.LoadCredential = [
        "admin-password:${cfg.adminPasswordFile}"
      ]
      ++ optional (cfg.jwtSecretFile != null) "jwt-secret:${cfg.jwtSecretFile}";

      systemd.tmpfiles.rules = [
        "d ${dirOf cfg.groupMembers} 0755 root root -"
        "d ${cfg.groupMembers} 0755 root root -"
        "d ${en.heldNamesDir} 0755 root root -"
      ];

      # Group members for apps (groupMembers): after every provisioning run
      # and every 10 minutes, so changes made in lldap's UI arrive too.
      systemd.services.swag-directory-groups = {
        description = "Publish directory group members for apps";
        after = [ "lldap.service" "swag-directory-provision.service" ];
        requires = [ "lldap.service" ];
        wantedBy = [ "swag-directory-provision.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${python} ${scripts}/groups.py ${groupsConfig}";
          # Opened by systemd as root, before the sandbox applies. append, not
          # truncate: the setting applies to ExecStartPost too, which would
          # empty the file before reading it; ExecStartPre clears it instead.
          ExecStartPre = "+${pkgs.coreutils}/bin/rm -f ${groupsOut}";
          StandardOutput = "append:${groupsOut}";
          ExecStartPost = "+${publishGroups}";
          LoadCredential = [ "admin-password:${cfg.adminPasswordFile}" ];
        }
        // adminUnitHardening;
      };
      systemd.timers.swag-directory-groups = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitInactiveSec = "10min";
        };
      };

      systemd.services.swag-directory-provision = {
        description = "Provision declared users and groups into lldap";
        after = [ "lldap.service" ];
        requires = [ "lldap.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ provisionConfig ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${python} ${scripts}/provision.py ${provisionConfig}";
          LoadCredential = [
            "admin-password:${cfg.adminPasswordFile}"
          ]
          ++ mapAttrsToList (
            name: u:
            "user-${name}:${if u.passwordFile != null then u.passwordFile else u.initialPasswordFile}"
          ) usersWithPassword;
        }
        // adminUnitHardening;
      };
    }

    # Enrollment endpoint: one service instance per connection, with the
    # connection as stdin/stdout. The socket is the access control.
    (mkIf en.enable {
      assertions = [
        {
          assertion = all (g: cfg.groups ? ${g}) en.grantableGroups;
          message = "services.swag.directory.enrollment.grantableGroups must be declared in services.swag.directory.groups: ${concatStringsSep ", " (filter (g: !(cfg.groups ? ${g})) en.grantableGroups)}.";
        }
        {
          assertion = !(any (g: elem g builtinGroups) en.grantableGroups);
          message = "services.swag.directory.enrollment.grantableGroups can't include lldap's built-in groups (${concatStringsSep ", " builtinGroups}).";
        }
      ];

      users.groups.${en.clientGroup} = { };

      systemd.sockets.swag-directory-enroll = {
        description = "Directory enrollment endpoint";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = en.socket;
          SocketUser = "root";
          SocketGroup = en.clientGroup;
          SocketMode = "0660";
          Accept = true;
          MaxConnections = 8;
        };
      };

      systemd.services."swag-directory-enroll@" = {
        description = "Create a directory account";
        after = [
          "lldap.service"
          "swag-directory-provision.service"
        ];
        requires = [ "lldap.service" ];
        serviceConfig = {
          ExecStart = "${python} ${scripts}/enroll.py ${enrollConfig}";
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
          LoadCredential = [ "admin-password:${cfg.adminPasswordFile}" ];
          RuntimeMaxSec = "60s";
        }
        // adminUnitHardening;
      };
    })

    # The directory on a path of your choice (stateDir). nixpkgs' lldap uses
    # DynamicUser, whose StateDirectory can't sit on a bind mount (systemd
    # would move it to /var/lib/private), so a relocated lldap runs as a
    # static lldap user. Copying the old data first matters here: an empty
    # database would be provisioned afresh, with new IDs for everyone.
    (mkIf (cfg.stateDir != "/var/lib/lldap") (mkMerge [
      (state.relocate {
        name = "lldap";
        source = cfg.stateDir;
        target = "/var/lib/lldap";
        owner = "lldap:lldap";
        oldPaths = [
          "/var/lib/lldap"
          "/var/lib/private/lldap"
        ];
      })
      {
        users.users.lldap = {
          isSystemUser = true;
          group = "lldap";
        };
        users.groups.lldap = { };
        systemd.services.lldap = {
          serviceConfig.DynamicUser = mkForce false;
          unitConfig.RequiresMountsFor = [ "/var/lib/lldap" ];
        };
      }
    ]))

    # Admin web UI on swag web.
    (optionalAttrs webDeclared (mkIf (hasWeb && dashboardDomain != null) {
      services.swag.web.vhosts.${dashboardDomain} = {
        host = "127.0.0.1";
        port = cfg.http.port;
        tls = mkDefault cfg.dashboard.tls;
      };
    }))
  ]);
}
