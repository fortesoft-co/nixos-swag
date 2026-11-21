# App accounts that follow the directory.
#
# For each services.swag.accounts.<name>, swag-accounts-<name>.service runs
# reconcile.py (the policy) against the app's adapter (the primitives):
# blocks accounts of people outside accessGroup and lifts its own blocks
# when they're back, links accounts known by an old ID to the new one, and
# publishes the names the app holds so sign-up refuses them. It runs every
# `interval` and whenever the members file or the subject map changes.
#
# swag knows no app: an adapter is a command speaking a small JSON protocol
# (see reconcile.py), or the built-in SQL adapter with the app's queries in
# config. The run and the adapter share one unit, so the app's credentials
# stay there (serviceConfig.LoadCredential) and swag holds none.
#
# Held names: the directory's held-names directory is root's, so the run
# writes the list into its own state directory and a root ExecStopPost
# moves it in, whole, only when it changed. ExecStopPost runs even when
# the run failed, so a link conflict or a tripped guard doesn't stop names
# being published.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
with lib;
let
  cfg = config.services.swag.accounts;
  hasDirectory = options.services ? swag.directory && config.services.swag.directory.enable;
  python = "${pkgs.python3}/bin/python3 -I";
  state = import ../../lib/state.nix { inherit lib pkgs; };
  swagState = config.services.swag.stateDir;

  stateDir = name: "/var/lib/swag-accounts/${name}";

  sqlConfig =
    name: s:
    pkgs.writeText "swag-accounts-${name}-sql.json" (
      builtins.toJSON {
        inherit (s) identity queries;
        database =
          if s.database.type == "sqlite3" then
            {
              type = "sqlite3";
              inherit (s.database) path;
            }
          else
            {
              type = "postgres";
              inherit (s.database)
                host
                port
                user
                name
                psql
                ;
            };
      }
    );

  adapterArgv =
    name: app:
    if app.adapter.sql != null then
      [
        "${pkgs.python3}/bin/python3"
        "-I"
        "${./sql-adapter.py}"
        "${sqlConfig name app.adapter.sql}"
      ]
    else
      app.adapter.command;

  runConfig =
    name: app:
    pkgs.writeText "swag-accounts-${name}.json" (
      builtins.toJSON {
        inherit name;
        inherit (app)
          membersFile
          subjectMap
          maxBlocksPerRun
          dryRun
          ;
        adapter = adapterArgv name app;
        stateFile = "${stateDir name}/state.json";
        namesOut = if app.heldNamesFile != null then "${stateDir name}/names" else null;
      }
    );

  publishNames =
    name: app:
    pkgs.writeShellScript "swag-accounts-${name}-publish" ''
      src=${stateDir name}/names
      dest=${escapeShellArg app.heldNamesFile}
      tmp="$(dirname "$dest")/.$(basename "$dest").tmp"
      [ -f "$src" ] || exit 0
      if ! ${pkgs.diffutils}/bin/cmp -s "$src" "$dest"; then
        ${pkgs.coreutils}/bin/install -m 0644 "$src" "$tmp"
        ${pkgs.coreutils}/bin/mv -f "$tmp" "$dest"
      fi
    '';

  watched =
    app:
    filter (p: p != null) [
      app.membersFile
      app.subjectMap
    ];

  appUnits =
    name: app:
    {
      services."swag-accounts-${name}" = {
        description = "Keep ${name}'s accounts in line with the directory";
        wantedBy = [ "multi-user.target" ];
        inherit (app) after;
        wants = app.after;
        # Path and timer triggers can come in bursts; every run is short
        # and idempotent.
        unitConfig = {
          StartLimitIntervalSec = 0;
          RequiresMountsFor = [ "/var/lib/swag-accounts" ];
        };
        serviceConfig = mkMerge [
          {
            Type = "oneshot";
            ExecStart = "${python} ${./reconcile.py} ${runConfig name app}";
            StateDirectory = "swag-accounts/${name}";
            StateDirectoryMode = "0700";
            # A static user, not DynamicUser: the state can then sit on
            # services.swag.stateDir's bind mount.
            User = mkDefault "swag-accounts";
            Group = mkDefault "swag-accounts";
            PrivateTmp = mkDefault true;
            ProtectSystem = mkDefault "strict";
            ProtectHome = mkDefault true;
            NoNewPrivileges = mkDefault true;
            PrivateDevices = mkDefault true;
            ProtectKernelTunables = mkDefault true;
            ProtectControlGroups = mkDefault true;
            RestrictSUIDSGID = mkDefault true;
            UMask = mkDefault "0077";
          }
          (mkIf (app.heldNamesFile != null) {
            ExecStopPost = "+${publishNames name app}";
          })
          app.serviceConfig
        ];
      };
      timers."swag-accounts-${name}" = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = app.interval;
          OnUnitInactiveSec = app.interval;
        };
      };
    }
    // optionalAttrs (watched app != [ ]) {
      paths."swag-accounts-${name}" = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = watched app;
      };
    };
in
{
  imports = [
    ./options.nix
    ../../lib/state-option.nix
  ];

  config = mkIf (cfg != { }) (mkMerge [
    (mkIf (swagState != null) (
      state.relocate {
        name = "swag-accounts";
        source = "${swagState}/accounts";
        target = "/var/lib/swag-accounts";
        # Each app's unit owns its own directory (StateDirectory=).
        oldPaths = [
          "/var/lib/swag-accounts"
          "/var/lib/private/swag-accounts"
        ];
      }
    ))
    {
      users.users.swag-accounts = {
        isSystemUser = true;
        group = "swag-accounts";
      };
      users.groups.swag-accounts = { };

      assertions = concatLists (
        mapAttrsToList (name: app: [
          {
            assertion = builtins.match "[A-Za-z0-9_-]+" name != null;
            message = "services.swag.accounts.${name}: names may use letters, digits, '_' and '-' (each becomes a unit and a file name).";
          }
          {
            assertion = (app.adapter.command != null) != (app.adapter.sql != null);
            message = "services.swag.accounts.${name}: set exactly one of adapter.command and adapter.sql.";
          }
          {
            assertion = app.accessGroup == null || app.membersFile != null;
            message = "services.swag.accounts.${name}: accessGroup needs membersFile, which defaults to the directory's file only when services.swag.directory is enabled on this host.";
          }
          {
            assertion =
              app.accessGroup == null
              || !hasDirectory
              || config.services.swag.directory.groups ? ${app.accessGroup};
            message = "services.swag.accounts.${name}: accessGroup ${toString app.accessGroup} is not declared in services.swag.directory.groups.";
          }
          {
            assertion =
              app.adapter.sql == null
              || (
                if app.adapter.sql.database.type == "sqlite3" then
                  app.adapter.sql.database.path != null
                else
                  app.adapter.sql.database.user != null && app.adapter.sql.database.name != null
              );
            message = "services.swag.accounts.${name}: adapter.sql.database needs path (sqlite3), or user and name (postgres).";
          }
        ]) cfg
      );

      warnings = concatLists (
        mapAttrsToList (
          name: app:
          optional (app.accessGroup != null && app.dryRun)
            "services.swag.accounts.${name} is in dryRun: it logs what it would block and changes nothing. Check `journalctl -u swag-accounts-${name}`, then set dryRun = false."
        ) cfg
      );

      systemd = mkMerge (mapAttrsToList appUnits cfg);
    }
  ]);
}
