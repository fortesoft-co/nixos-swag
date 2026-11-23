# Alerts when a unit fails.
#
# A drop-in on each watched unit (scope = "swag": the stack's units plus
# `units`; "all": a service.d drop-in for every service) adds
#   OnFailure=swag-alert-failed@%N.service
#   OnSuccess=swag-alert-ok@%N.service
# and those run alert.py, which sends one message per failing streak
# through Apprise and/or a command. The alert units carry a drop-in of the
# same file name that clears both settings: systemd lets a unit's own
# drop-in replace a service.d one with that name, so an alert that fails
# never sets off another.
#
# The drop-ins go through systemd.packages, built from the names of the
# host's services, so no service definition depends on another.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.swag.alerts;
  stateDir = "/run/swag-alerts";

  # Units the swag modules (and the services they configure) create.
  ownPrefixes = [
    "swag-"
    "authentik"
    "lldap"
    "acme-"
    "nginx"
    "dnsmasq"
    "cloudflared-"
  ];
  isOurs =
    name:
    any (p: hasPrefix p name) ownPrefixes && !hasSuffix "@" name && !hasPrefix "swag-alert-" name;
  watched =
    map (n: "${n}.service") (filter isOurs (attrNames config.systemd.services)) ++ cfg.units;

  hooks = pkgs.writeText "swag-alerts.conf" ''
    [Unit]
    OnFailure=swag-alert-failed@%N.service
    OnSuccess=swag-alert-ok@%N.service
  '';
  noHooks = pkgs.writeText "swag-alerts.conf" ''
    [Unit]
    OnFailure=
    OnSuccess=
  '';
  dropIns = pkgs.runCommand "swag-alerts-dropins" { } (
    ''
      d=$out/lib/systemd/system
      put() { mkdir -p "$d/$1.d"; ln -s "$2" "$d/$1.d/swag-alerts.conf"; }
      put swag-alert-failed@.service ${noHooks}
      put swag-alert-ok@.service ${noHooks}
    ''
    + (
      if cfg.scope == "all" then
        "put service ${hooks}\n"
      else
        concatMapStrings (u: "put ${escapeShellArg u} ${hooks}\n") watched
    )
  );

  runConfig = pkgs.writeText "swag-alerts.json" (
    builtins.toJSON {
      inherit stateDir;
      inherit (cfg) journalLines command;
      journalctl = "${config.systemd.package}/bin/journalctl";
      apprise = if cfg.urlsFile != null then getExe pkgs.apprise else null;
    }
  );

  run = mode: "${pkgs.python3}/bin/python3 -I ${./alert.py} ${mode} ${runConfig}";
  # OnSuccess= fires for every watched unit that finishes cleanly (every
  # service, with scope = "all"); nothing to say unless it was failing.
  okFastPath = pkgs.writeShellScript "swag-alert-ok" ''
    [ -e ${stateDir}/"''${MONITOR_UNIT//\//_}" ] || exit 0
    exec ${run "ok"}
  '';

  alertUnit = mode: {
    description = "Report %i ${if mode == "failed" then "failing" else "working again"}";
    # Ordered after early boot and the network, but pulling in none of it:
    # with default dependencies, an alert for an early-boot oneshot would
    # require sysinit.target while it is still starting, which starts that
    # oneshot again, which sets off the alert again. network.target, not
    # network-online.target: waiting for the latter would mean pulling it
    # in; alert.py's retries cover a network that isn't up yet.
    unitConfig.DefaultDependencies = false;
    after = [
      "sysinit.target"
      "basic.target"
      "network.target"
    ];
    conflicts = [ "shutdown.target" ];
    before = [ "shutdown.target" ];
    serviceConfig = mkMerge [
      {
        Type = "oneshot";
        ExecStart = if mode == "ok" then "${okFastPath}" else run mode;
        # alert.py retries delivery for a few minutes (the network may not
        # be up yet for a failure early in boot).
        TimeoutStartSec = "15min";
        User = "swag-alerts";
        Group = "swag-alerts";
        # Reading the failed run's journal lines.
        SupplementaryGroups = [ "systemd-journal" ];
        LoadCredential = optional (cfg.urlsFile != null) "urls:${cfg.urlsFile}";
        ReadWritePaths = [ stateDir ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        UMask = "0077";
      }
      cfg.serviceConfig
    ];
  };
in
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.urlsFile != null || cfg.command != null;
        message = "services.swag.alerts needs somewhere to send alerts: urlsFile (Apprise URLs) or command.";
      }
    ];

    users.users.swag-alerts = {
      isSystemUser = true;
      group = "swag-alerts";
    };
    users.groups.swag-alerts = { };

    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 swag-alerts swag-alerts -" ];
    systemd.packages = [ dropIns ];
    systemd.services."swag-alert-failed@" = alertUnit "failed";
    systemd.services."swag-alert-ok@" = alertUnit "ok";
  };
}
