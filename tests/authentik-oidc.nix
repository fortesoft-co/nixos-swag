# services.swag.authentik.oidcClients: each client becomes an OAuth2
# provider + application with the declared redirect URIs, group bindings and
# the client secret from its file, and serves a discovery document at
# <url>/application/o/<slug>/.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "swag-authentik-oidc";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.authentik ];

      virtualisation.memorySize = 6144;
      virtualisation.cores = 4;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        before = [
          "authentik-secrets.service"
          "authentik-provider-secret-setup.service"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo 'test-secret-key-0123456789abcdef0123456789abcdef' > /run/test-secrets/ak-secret
          echo 'akadmin-password-1' > /run/test-secrets/ak-admin
          echo 'test-api-token-0123456789' > /run/test-secrets/ak-token
          echo 'notes-client-secret-0123456789' > /run/test-secrets/notes
          echo 'wiki-client-secret-0123456789' > /run/test-secrets/wiki
        '';
      };
      systemd.services.authentik-secrets.requires = [ "test-secrets.service" ];

      services.swag.authentik = {
        enable = true;
        url = "http://127.0.0.1:9000";
        secrets.AUTHENTIK_SECRET_KEY = "/run/test-secrets/ak-secret";
        bootstrap = {
          email = "admin@example.com";
          passwordFile = "/run/test-secrets/ak-admin";
          tokenFile = "/run/test-secrets/ak-token";
        };
        oidcClients = {
          notes = {
            name = "Notes";
            clientSecretFile = "/run/test-secrets/notes";
            redirectUris = [
              "https://notes.example.com/oauth/callback"
              "https://notes.example.com/oauth/callback2"
            ];
            launchUrl = "https://notes.example.com/";
          };
          wiki = {
            clientId = "wiki-client";
            clientSecretFile = "/run/test-secrets/wiki";
            redirectUris = [ "https://wiki.example.com/cb" ];
            # Built in, so it exists when the blueprint applies.
            groups = [ "authentik Admins" ];
          };
        };
      };
    };

  testScript = ''
    import json

    api = "http://127.0.0.1:9000/api/v3"
    auth = "-H 'Authorization: Bearer test-api-token-0123456789'"

    def get(path):
        return json.loads(machine.succeed(f"curl -sf {auth} '{api}{path}'"))

    machine.wait_for_unit("authentik.service")
    machine.wait_for_open_port(9000, timeout=600)
    machine.wait_for_unit("authentik-provider-secret-setup.service", timeout=600)

    with subtest("providers carry the declared client IDs, redirect URIs and secrets"):
        notes = get("/providers/oauth2/?name=notes")["results"][0]
        assert notes["client_id"] == "notes", notes
        assert notes["client_type"] == "confidential", notes
        assert sorted(notes["grant_types"]) == ["authorization_code", "refresh_token"], notes
        assert notes["client_secret"] == "notes-client-secret-0123456789", "notes secret not synced"
        assert [u["url"] for u in notes["redirect_uris"]] == [
            "https://notes.example.com/oauth/callback",
            "https://notes.example.com/oauth/callback2",
        ], notes
        assert all(u["matching_mode"] == "strict" for u in notes["redirect_uris"]), notes
        wiki = get("/providers/oauth2/?name=wiki")["results"][0]
        assert wiki["client_id"] == "wiki-client", wiki
        assert wiki["client_secret"] == "wiki-client-secret-0123456789", "wiki secret not synced"

    with subtest("applications exist, with launch URL and group restriction"):
        app = get("/core/applications/notes/")
        assert app["name"] == "Notes" and app["meta_launch_url"] == "https://notes.example.com/", app
        wiki_app = get("/core/applications/wiki/")
        bindings = get(f"/policies/bindings/?target={wiki_app['pk']}")["results"]
        assert [b["group_obj"]["name"] for b in bindings] == ["authentik Admins"], bindings
        assert get(f"/policies/bindings/?target={app['pk']}")["results"] == [], "notes should be open to everyone"

    with subtest("discovery documents are served under the configured url"):
        doc = json.loads(machine.succeed(
            "curl -sf http://127.0.0.1:9000/application/o/notes/.well-known/openid-configuration"
        ))
        assert doc["issuer"] == "http://127.0.0.1:9000/application/o/notes/", doc["issuer"]

    with subtest("no client secret in the store or on a command line"):
        machine.fail("grep -rlF notes-client-secret /nix/store/*-authentik-blueprints/ 2>/dev/null")
        machine.fail("ps -eo args | grep -F -e notes-client-secret -e wiki-client-secret | grep -v grep")
  '';
}
