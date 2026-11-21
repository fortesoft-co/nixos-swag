{
  config,
  lib,
  options,
  pkgs,
  ...
}:
with lib;
let
  hasDirectory = options.services ? swag.directory && config.services.swag.directory.enable;
  ds =
    if options.services ? swag.authentik then config.services.swag.authentik.directorySource else null;
  # Also while idAttribute is null: the map isn't written then, and a
  # configured but missing map makes the run check nobody, rather than
  # compare Authentik's hashed IDs with the directory's and block everyone.
  hasSubjectMap = ds != null && config.services.swag.authentik.enable && ds.enable;

  statements = types.coercedTo types.str singleton (types.listOf types.str);

  sqlType = types.submodule {
    options = {
      identity = mkOption {
        type = types.enum [
          "subject"
          "name"
        ];
        description = ''
          What the subjects in `queries.list` are: directory IDs (the OIDC
          sub, for apps that find people by it) or usernames (for apps that
          find people by name).
        '';
      };

      database = {
        type = mkOption {
          type = types.enum [
            "sqlite3"
            "postgres"
          ];
          description = "Database engine.";
        };
        path = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "sqlite3: the database file. Give the unit write access with serviceConfig.ReadWritePaths.";
        };
        host = mkOption {
          type = types.str;
          default = "/run/postgresql";
          description = "postgres: socket directory (or host).";
        };
        port = mkOption {
          type = types.port;
          default = 5432;
          description = "postgres: port.";
        };
        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "postgres: role, usually the unit's user (peer authentication, no password).";
        };
        name = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "postgres: database name.";
        };
        psql = mkOption {
          type = types.str;
          default = "${config.services.postgresql.package}/bin/psql";
          defaultText = literalExpression ''"''${config.services.postgresql.package}/bin/psql"'';
          description = "postgres: the psql binary.";
        };
      };

      queries = {
        list = mkOption {
          type = types.str;
          description = ''
            Rows of (id, name, subject, blocked), one per subject the app's
            sign-in finds the account by; an account without any has one
            row with subject NULL (it is then never blocked or linked).
          '';
        };
        names = mkOption {
          type = types.str;
          description = "Rows of (name): every name a newcomer must not take (users, organizations, aliases).";
        };
        block = mkOption {
          type = statements;
          default = [ ];
          description = ''
            Statements that block the account :id, reversibly, closing every
            way in that doesn't pass through the identity provider (tokens,
            keys, app passwords). Never a delete. Empty = the app can't block.
          '';
        };
        unblock = mkOption {
          type = statements;
          default = [ ];
          description = "Statements that undo `block` for :id.";
        };
        revoke = mkOption {
          type = statements;
          default = [ ];
          description = "Statements that end :id's sessions and tokens. Run after every block.";
        };
        link = mkOption {
          type = statements;
          default = [ ];
          description = "Statements that make account :id answer to :subject as well (ID migrations).";
        };
      };
    };
  };

  appType = types.submodule (
    { name, config, ... }:
    {
      options = {
        accessGroup = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "git-users";
          description = ''
            Directory group whose members may use the app. Accounts of
            anyone else are blocked (never deleted), and unblocked when they
            are back. null = only publish held names.
          '';
        };

        membersFile = mkOption {
          type = types.nullOr types.str;
          default =
            if config.accessGroup != null && hasDirectory then
              "${directory.groupMembers}/${config.accessGroup}"
            else
              null;
          defaultText = literalExpression ''"''${config.services.swag.directory.groupMembers}/''${accessGroup}"'';
          description = ''
            File of "<directory ID> <username>" lines, one per member of
            accessGroup. Defaults to the directory's file on this host.
          '';
        };

        subjectMap = mkOption {
          type = types.nullOr types.str;
          default = if hasSubjectMap then ds.subjectMap else null;
          defaultText = literalExpression "config.services.swag.authentik.directorySource.subjectMap, when Authentik syncs a directory on this host";
          description = ''
            File of "<old ID> <new ID>" lines. An account known by an old ID
            counts as the new one and, when the adapter can link, is linked
            to it. While the file isn't there (Authentik not sending
            directory IDs yet), nobody is blocked or unblocked. null = IDs
            never change.
          '';
        };

        heldNamesFile = mkOption {
          type = types.nullOr types.str;
          default = if hasDirectory then "${directory.enrollment.heldNamesDir}/${name}" else null;
          defaultText = literalExpression ''"''${config.services.swag.directory.enrollment.heldNamesDir}/<name>"'';
          description = ''
            Where the names the app holds are published, for enrollment to
            refuse. Replaced whole, only when it changed. null = don't
            publish.
          '';
        };

        adapter = {
          command = mkOption {
            type = types.nullOr (types.coercedTo types.str singleton (types.listOf types.str));
            default = null;
            example = literalExpression ''[ "''${myAdapter}/bin/my-adapter" "--config" "/etc/my-adapter.json" ]'';
            description = ''
              The adapter: a command (and its first arguments) answering
              `<op> [args...]` with one JSON object on stdout; see the
              "App accounts" section of the README.
            '';
          };
          sql = mkOption {
            type = types.nullOr sqlType;
            default = null;
            description = "Use the built-in SQL adapter instead of a command.";
          };
        };

        serviceConfig = mkOption {
          type = types.attrs;
          default = { };
          example = literalExpression ''{ User = "gitea"; Group = "gitea"; }'';
          description = ''
            Settings for the unit the run and the adapter share: the user
            that can reach the app, credentials (LoadCredential), writable
            paths. Defaults to the swag-accounts system user and a hardened sandbox.
          '';
        };

        after = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "gitea.service" ];
          description = "Units the app needs to be up first.";
        };

        interval = mkOption {
          type = types.str;
          default = "10min";
          description = "How often to check, besides whenever membersFile or subjectMap changes.";
        };

        maxBlocksPerRun = mkOption {
          type = types.ints.positive;
          default = 5;
          description = ''
            Most accounts one run may block. A run that would block more
            blocks none and fails: a group that suddenly lost most of its
            members is more likely a mistake.
          '';
        };

        dryRun = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Log what would be blocked, unblocked or linked, and change
            nothing in the app. On by default: read the unit's journal once,
            then turn it off. Held names are published either way.
          '';
        };
      };
    }
  );

  directory = config.services.swag.directory;
in
{
  options.services.swag.accounts = mkOption {
    type = types.attrsOf appType;
    default = { };
    description = ''
      Apps whose own accounts follow the directory: accounts of people who
      left the access group are blocked, accounts known by an old ID are
      linked to the new one, and the names the app holds are kept from
      sign-up. One unit per app, swag-accounts-<name>.
    '';
  };
}
