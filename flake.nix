{
  description = "Self-hosted web gateway for NixOS: split-horizon DNS, an nginx vhost registry with ACME, a user directory and Authentik SSO, each usable on its own.";

  # Only for checks (NixOS VM tests); the modules use the host's nixpkgs.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Tunnel options come with the default module; point this input at your
  # own copy with inputs.nixos-swag.inputs.nixos-cloudflared.follows.
  inputs.nixos-cloudflared.url = "github:fortesoft-co/nixos-cloudflared";
  inputs.nixos-cloudflared.inputs.nixpkgs.follows = "nixpkgs";
  # Upstream Authentik module, brought in by nixosModules.authentik; follow it
  # from your own flake to pin a different revision.
  inputs.authentik-nix.url = "github:nix-community/authentik-nix";

  outputs =
    {
      self,
      nixpkgs,
      nixos-cloudflared,
      authentik-nix,
    }:
    {
      nixosModules = {
        dns = ./modules/dns;
        web = ./modules/web;
        directory = ./modules/directory;
        accounts = ./modules/accounts;
        alerts = ./modules/alerts;
        authentik = {
          imports = [
            ./modules/authentik
            authentik-nix.nixosModules.default
          ];
        };
        default = {
          imports = [
            self.nixosModules.dns
            self.nixosModules.web
            self.nixosModules.directory
            self.nixosModules.authentik
            self.nixosModules.accounts
            self.nixosModules.alerts
            nixos-cloudflared.nixosModules.default
          ];
        };
      };

      checks.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          directory = import ./tests/directory.nix { inherit pkgs self; };
          accounts = import ./tests/accounts.nix { inherit pkgs self; };
          state = import ./tests/state.nix { inherit pkgs self; };
          alerts = import ./tests/alerts.nix { inherit pkgs self; };
          web = import ./tests/web.nix { inherit pkgs self; };
          docs = import ./tests/docs.nix { inherit pkgs self; };
          authentik-directory = import ./tests/authentik-directory.nix { inherit pkgs self; };
          authentik-oidc = import ./tests/authentik-oidc.nix { inherit pkgs self; };
          authentik-public = import ./tests/authentik-public.nix { inherit pkgs self; };
          authentik-enrollment = import ./tests/authentik-enrollment.nix { inherit pkgs self; };
        };
    };
}
