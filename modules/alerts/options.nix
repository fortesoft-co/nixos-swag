{ lib, ... }:
with lib;
let
  inherit (import ../../lib/types.nix { inherit lib; }) secretPath;
in
{
  options.services.swag.alerts = {
    enable = mkEnableOption ''
      alerts when a unit fails: one message when it starts failing, none
      while it keeps failing, and one when it succeeds again'';

    urlsFile = mkOption {
      type = types.nullOr secretPath;
      default = null;
      example = "/run/secrets/alert-urls";
      description = ''
        Runtime path to a root-only file of Apprise URLs, one per line
        (e.g. `ntfys://token@ntfy.example.com/gateway`,
        `mailtos://user:password@mail.example.com`): every alert goes to
        each. URLs often carry a token, so the file reaches only the alert
        unit, as a systemd credential. See Apprise's documentation for the
        services and their URL forms.
      '';
    };

    command = mkOption {
      type = types.nullOr (types.coercedTo types.str singleton (types.listOf types.str));
      default = null;
      example = literalExpression ''[ "''${myNotifier}/bin/notify" ]'';
      description = ''
        A command (and its first arguments) that gets each alert as one
        JSON object on stdin: event ("failed" or "recovered"), host, unit,
        result, since, at, and lines (the failed run's last journal lines).
        Runs alongside urlsFile when both are set; give it credentials
        with serviceConfig.LoadCredential.
      '';
    };

    scope = mkOption {
      type = types.enum [
        "swag"
        "all"
      ];
      default = "swag";
      description = ''
        Which units to watch. "swag": the stack's own units on this host
        (directory, Authentik, app accounts, certificates, nginx, dnsmasq,
        the tunnel, state setup) plus `units`. "all": every service on the
        host, the ones you write included.
      '';
    };

    units = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "restic-backups-daily.service"
        "wiki.service"
      ];
      description = "More units to watch with scope = \"swag\".";
    };

    journalLines = mkOption {
      type = types.ints.between 0 200;
      default = 20;
      description = "How many of the failed run's last journal lines an alert carries.";
    };

    serviceConfig = mkOption {
      type = types.attrs;
      default = { };
      example = literalExpression ''{ LoadCredential = [ "token:/run/secrets/notify-token" ]; }'';
      description = "Settings merged into the alert units, e.g. credentials for `command`.";
    };
  };
}
