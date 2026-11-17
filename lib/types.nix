# Option types shared by the nixos-swag modules.
{ lib }:
{
  # A secret the host provides at runtime (agenix, sops-nix, systemd
  # credentials, ...). A string, not a Nix path: a path literal such as
  # ./secret would be copied into the world-readable Nix store.
  secretPath =
    lib.types.addCheck lib.types.str (
      s: lib.hasPrefix "/" s && !lib.hasPrefix "${builtins.storeDir}/" s
    )
    // {
      name = "secretPath";
      description = "absolute path to a runtime secret file (a string, outside the Nix store)";
    };
}
