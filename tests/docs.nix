# The docs keep up with the modules: every option appears, in backticks, in
# its module's page (docs/<module>.md, docs/state.md for stateDir), and
# every relative link and #anchor in README.md and docs/ resolves.
# Evaluation only, no VM.
{ pkgs, self }:
let
  inherit (pkgs) lib;

  options =
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [ self.nixosModules.default ];
    }).options.services.swag;

  names = map (o: o.name) (
    lib.filter (o: o.visible && !o.internal) (lib.optionAttrSetToDocList options)
  );
  # Containers (an option with options under it) are documented by their
  # leaves.
  leaves = lib.filter (n: !lib.any (m: lib.hasPrefix "${n}." m) names) names;

  # services.swag.<module>.<rest> → { page; written = how the page names it }.
  entry =
    name:
    let
      parts = lib.splitString "." name;
      module = lib.elemAt parts 2;
      rest = lib.drop 3 parts;
    in
    if module == "stateDir" then
      {
        page = "state.md";
        written = name;
      }
    else
      {
        page = "${module}.md";
        # accounts.<name>.accessGroup is written accessGroup.
        written = lib.concatStringsSep "." (if module == "accounts" then lib.drop 1 rest else rest);
      };

  expected = pkgs.writeText "swag-options.json" (builtins.toJSON (map entry leaves));
in
pkgs.runCommand "swag-docs"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    docs = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../README.md
        ../LICENSE
        ../docs
      ];
    };
  }
  ''
    python3 -I ${./docs.py} "$docs" ${expected}
    touch $out
  ''
