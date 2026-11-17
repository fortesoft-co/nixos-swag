{
  description = "Self-hosted web gateway for NixOS: split-horizon DNS, an nginx vhost registry with ACME, and Authentik SSO, each usable on its own.";

  # Tunnel options come with the default module; point this input at your
  # own copy with inputs.nixos-swag.inputs.nixos-cloudflared.follows.
  inputs.nixos-cloudflared.url = "github:fortesoft-co/nixos-cloudflared";

  outputs =
    { self, nixos-cloudflared }:
    {
      nixosModules = {
        dns = ./modules/dns;
        web = ./modules/web;
        authentik = ./modules/authentik;
        default = {
          imports = [
            self.nixosModules.dns
            self.nixosModules.web
            self.nixosModules.authentik
            nixos-cloudflared.nixosModules.default
          ];
        };
      };
    };
}
