{
  lib,
  ...
}:
with lib;
let
  inherit (import ../../lib/types.nix { inherit lib; }) secretPath;
in
{
  options.services.swag.directory = {
    enable = mkEnableOption "the user directory (lldap): users and groups as the source of truth for the other services";

    baseDn = mkOption {
      type = types.str;
      example = "dc=example,dc=com";
      description = ''
        LDAP base DN. Users live under ou=people and groups under ou=groups
        of it. Changing it later means re-binding every LDAP client.
      '';
    };

    adminUsername = mkOption {
      type = types.str;
      default = "admin";
      description = "Username of lldap's built-in admin account.";
    };

    adminPasswordFile = mkOption {
      type = secretPath;
      description = ''
        Runtime path to a file holding the lldap admin password, readable by
        root. It reaches lldap and the provisioning unit as a systemd
        credential, so neither the lldap user nor any other service can read
        the source file. Config is authoritative for the admin password: it
        is reset to this value on every start.
      '';
    };

    jwtSecretFile = mkOption {
      type = types.nullOr secretPath;
      default = null;
      description = ''
        Runtime path to a file holding lldap's JWT signing secret, readable
        by root. null = lldap generates one on first start and keeps it in
        its own state directory (readable only by the lldap user).
      '';
    };

    enrollment = {
      enable = mkEnableOption ''
        the enrollment endpoint: a local socket through which a sign-up front
        end (services.swag.authentik.enrollment) creates directory accounts.
        One instance per connection; it holds the lldap admin password as a
        systemd credential, and only members of clientGroup can connect
      '';

      socket = mkOption {
        type = types.str;
        default = "/run/swag-directory-enroll.sock";
        readOnly = true;
        description = "Path of the enrollment socket.";
      };

      clientGroup = mkOption {
        type = types.str;
        default = "swag-directory-enroll-clients";
        description = ''
          Unix group allowed to connect to the socket (mode 0660). Add the
          front end's unit to it with SupplementaryGroups.
        '';
      };

      grantableGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "members" "git-users" ];
        description = ''
          Groups an enrollment may put the new account in; a request asking
          for any other group is refused. Each must be declared in
          services.swag.directory.groups, and lldap's built-in groups
          (lldap_admin, …) can never be granted.
        '';
      };

      minPasswordLength = mkOption {
        type = types.ints.between 8 128;
        default = 12;
        description = "Shortest password a new account may have.";
      };
    };

    ldap = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address the LDAP listener binds to. Use 0.0.0.0 to serve LDAP clients on the LAN.";
      };
      port = mkOption {
        type = types.port;
        default = 3890;
        description = "LDAP listener port.";
      };
    };

    http = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address lldap's web UI and API bind to.";
      };
      port = mkOption {
        type = types.port;
        default = 17170;
        description = "Port of lldap's web UI and API.";
      };
    };

    dashboard.domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        server_name for lldap's admin web UI vhost on swag web. null =
        "ldap.<internalDomain>" when swag dns is on this host, otherwise no
        vhost.
      '';
    };

    dashboard.tls = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Serve the admin UI vhost over TLS with an ACME certificate
        (services.swag.web.vhosts.<domain>.tls). Recommended: the admin
        password is entered there.
      '';
    };

    groups = mkOption {
      type = types.attrsOf (types.submodule { });
      default = { };
      example = literalExpression ''{ family = { }; git-admins = { }; }'';
      description = ''
        Groups to create, keyed by name. lldap's built-in groups
        (lldap_admin, lldap_password_manager, lldap_strict_readonly) exist
        already and need no entry.
      '';
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            email = mkOption {
              type = types.str;
              description = ''
                Account email. It is unique in lldap, and OIDC apps match
                users by it. Config is authoritative: provisioning resets it
                when it differs.
              '';
            };
            displayName = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Display name. null = leave whatever the directory has.";
            };
            groups = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''
                Groups the user is added to: names from
                services.swag.directory.groups or lldap's built-ins.
                Additive: memberships added by hand are left alone.
              '';
            };
            initialPasswordFile = mkOption {
              type = types.nullOr secretPath;
              default = null;
              description = ''
                Runtime path to a file holding the user's first password,
                readable by root. It is set only when provisioning creates
                the user; afterwards the user owns their password and config
                never touches it. The file reaches the provisioning unit as a
                systemd credential, so only that unit can read it.
              '';
            };
            passwordFile = mkOption {
              type = types.nullOr secretPath;
              default = null;
              description = ''
                Runtime path to a file holding a password that config owns,
                readable by root: provisioning sets it whenever the account
                can't bind with it. Meant for service accounts other modules
                bind as (e.g. Authentik's). Mutually exclusive with
                initialPasswordFile; same credential handling.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Users to create in the directory, keyed by username. Other modules
        can add entries; attrsOf merges them. Users created by hand are left
        alone, and a user removed here is not deleted from the directory.
      '';
    };
  };
}
