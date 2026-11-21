# services.swag.stateDir on a running host: lldap (nixpkgs' DynamicUser) and
# app accounts state start in /var/lib; switching to a config with stateDir
# copies them once into it and bind-mounts them back, and the directory
# keeps every user's ID (an empty database would be provisioned afresh,
# with new IDs). The originals stay; a later start copies nothing.
{ pkgs, self }:
let
  adapter = pkgs.writeShellScript "demo-adapter" ''
    case "$1" in
      describe) echo '{"protocol": 1, "identity": "subject", "ops": []}' ;;
      list) echo '{"accounts": []}' ;;
      names) echo '{"names": ["demo-name"]}' ;;
      *) exit 1 ;;
    esac
  '';
in
pkgs.testers.runNixOSTest {
  name = "swag-state";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.directory
        self.nixosModules.accounts
      ];

      environment.systemPackages = [ pkgs.openldap ];

      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        before = [
          "lldap.service"
          "swag-directory-provision.service"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo 'admin-password-1' > /run/test-secrets/admin
        '';
      };
      systemd.services.lldap.requires = [ "test-secrets.service" ];

      services.swag.directory = {
        enable = true;
        baseDn = "dc=example,dc=com";
        adminPasswordFile = "/run/test-secrets/admin";
        users.alice.email = "alice@example.com";
      };
      services.swag.accounts.demo.adapter.command = "${adapter}";

      specialisation.persist.configuration =
        { config, lib, ... }:
        {
          services.swag.stateDir = "/persist/swag";
          # Test VMs replace fileSystems with their own disks; hand them the
          # modules' bind mounts (the same helper builds both).
          virtualisation.fileSystems =
            let
              state = import ../lib/state.nix { inherit lib pkgs; };
              mount =
                name: source: target:
                (state.relocate { inherit name source target; }).fileSystems;
            in
            mount "lldap" "/persist/swag/lldap" "/var/lib/lldap"
            // mount "swag-accounts" "/persist/swag/accounts" "/var/lib/swag-accounts";
        };
    };

  testScript = ''
    ldap = "-x -H ldap://127.0.0.1:3890 -D uid=admin,ou=people,dc=example,dc=com -w admin-password-1"

    def alice_id():
        return machine.succeed(
            f"ldapsearch {ldap} -b ou=people,dc=example,dc=com '(uid=alice)' entryUUID"
            " | sed -n 's/^entryUUID: //p'"
        ).strip()

    machine.wait_for_unit("swag-directory-provision.service")
    machine.wait_until_succeeds("grep -qx demo-name /run/swag-directory/held-names/demo", timeout=60)
    before = alice_id()
    assert before, "alice has no ID"
    machine.succeed("test -L /var/lib/lldap && test -f /var/lib/private/lldap/users.db")
    # State an app kept under DynamicUser, as before the static user.
    machine.succeed(
        "install -d -m 0700 /var/lib/private/swag-accounts/olddyn"
        " && echo '{\"blocked\": [\"7\"]}' > /var/lib/private/swag-accounts/olddyn/state.json"
        " && ln -s ../private/swag-accounts/olddyn /var/lib/swag-accounts/olddyn"
        " && echo kept > /var/lib/swag-accounts/demo/marker"
    )

    with subtest("switching to stateDir copies the state once and mounts it back"):
        machine.succeed("/run/current-system/specialisation/persist/bin/switch-to-configuration test >&2")
        machine.wait_for_unit("lldap.service")
        machine.wait_for_unit("swag-directory-provision.service")
        machine.succeed("findmnt -no SOURCE /var/lib/lldap | grep -q /persist/swag/lldap")
        machine.succeed("findmnt -no SOURCE /var/lib/swag-accounts | grep -q /persist/swag/accounts")
        machine.succeed("test -f /persist/swag/lldap/users.db")
        assert machine.succeed("stat -c %U /persist/swag/lldap/users.db").strip() == "lldap"
        assert machine.succeed("cat /persist/swag/accounts/demo/marker").strip() == "kept"
        machine.succeed("grep -q '\"7\"' /persist/swag/accounts/olddyn/state.json")
        machine.fail("find /persist/swag/accounts -maxdepth 1 -type l | grep .")
        machine.fail("test -e /persist/swag/lldap.partial")

    with subtest("the directory keeps every user's ID"):
        assert alice_id() == before, f"{before} -> {alice_id()}"

    with subtest("the originals stay"):
        machine.succeed("test -f /var/lib/private/lldap/users.db")
        machine.succeed("test -f /var/lib/private/swag-accounts/olddyn/state.json")

    with subtest("a later start copies nothing and changes nothing"):
        machine.succeed("echo changed > /persist/swag/accounts/demo/marker")
        machine.succeed("systemctl stop lldap.service && systemctl restart lldap-state-dir.service var-lib-lldap.mount")
        machine.succeed("systemctl stop swag-accounts-demo.service && systemctl restart swag-accounts-state-dir.service 'var-lib-swag\\x2daccounts.mount'")
        machine.succeed("systemctl start lldap.service swag-accounts-demo.service")
        out = machine.succeed("journalctl -u lldap-state-dir -u swag-accounts-state-dir -o cat")
        assert out.count("copying /var/lib/private/lldap") == 1, out
        assert machine.succeed("cat /persist/swag/accounts/demo/marker").strip() == "changed"
        assert alice_id() == before

    with subtest("the app's unit runs on the relocated state"):
        machine.succeed("systemctl start swag-accounts-demo.service")
        machine.succeed("grep -qx demo-name /run/swag-directory/held-names/demo")
  '';
}
