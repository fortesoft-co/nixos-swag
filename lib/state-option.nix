# services.swag.stateDir, imported by every module by path (the module
# system imports one file once, so any combination of modules works).
{ lib, ... }:
with lib;
{
  options.services.swag.stateDir = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "/srv/swag";
    description = ''
      Where nixos-swag keeps persistent state: authentik/, lldap/ and
      accounts/ under it, so a reinstalled host with the same config and
      this path finds everything again. Each is bind-mounted at the
      service's usual /var/lib path. When first set, data already in the
      old place is copied over once (the original stays, for you to
      delete). The parent must be mounted by the host. null = the usual
      /var/lib paths.
    '';
  };
}
