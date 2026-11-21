# Relocating a service's persistent state (services.swag.stateDir), shared
# by the nixos-swag modules.
{ lib, pkgs }:
with lib;
{
  # Config that keeps `target` (the path the service uses) on `source`: a
  # bind mount target ← source, prepared by <name>-state-dir.service.
  #
  # The first time (source missing or empty), the data in `oldPaths` (real
  # directories only, in order) is copied into it, into a temporary
  # directory first and then moved, so an interrupted copy is never taken
  # for a finished one. The originals stay.
  #
  # A symlink at `target` (a DynamicUser StateDirectory points
  # /var/lib/<name> into /var/lib/private) is replaced by a directory in
  # the activation script: systemd resolves a mount point through
  # symlinks when it loads the mount unit, so it would bind-mount over
  # /var/lib/private/<name> instead. Activation runs before that load, on
  # boot and on switch (where the service was already stopped).
  #
  # `owner` = "user:group" to own everything in source, or null
  # to leave ownership to the units (StateDirectory= fixes its own).
  #
  # The units using it must not use DynamicUser (systemd would move a
  # DynamicUser StateDirectory to /var/lib/private, and a mount point can't
  # be moved), and should have RequiresMountsFor = target.
  relocate =
    {
      name,
      source,
      target,
      owner ? null,
      oldPaths ? [ ],
    }:
    {
      fileSystems.${target} = {
        device = source;
        fsType = "none";
        options = [
          "bind"
          "x-systemd.requires=${name}-state-dir.service"
          "x-systemd.after=${name}-state-dir.service"
        ];
        depends = [ (dirOf source) ];
      };
      system.activationScripts."swag-state-${name}".text = ''
        if [ -L ${escapeShellArg target} ]; then rm ${escapeShellArg target}; fi
        mkdir -p ${escapeShellArg target}
      '';
      systemd.services."${name}-state-dir" = {
        description = "Prepare ${source} for ${target}";
        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.util-linux
        ];
        # In the local-fs phase, so the bind mount that requires this unit
        # doesn't cycle back through sysinit.target (DefaultDependencies
        # would add After=sysinit.target). /etc/passwd is on the root fs and
        # written before local-fs.target, so chown by name resolves.
        before = [ "local-fs.target" ];
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = [ (dirOf source) ];
        };
        # Restarting it would restart the mount that requires it, under a
        # running service. A changed script takes effect at the next boot.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          src=${escapeShellArg source}
          if [ ! -d "$src" ] || [ -z "$(ls -A "$src")" ]; then
            partial="$src.partial"
            rm -rf "$partial"
            mkdir -p "$partial"
            for old in ${escapeShellArgs oldPaths}; do
              if [ -d "$old" ] && [ ! -L "$old" ] && ! mountpoint -q "$old" \
                && [ -n "$(ls -A "$old")" ]; then
                echo "copying $old into $src (the original stays)"
                cp -a "$old"/. "$partial"/
                # Top-level symlinks point into a DynamicUser's private
                # directory; that copy comes from its own oldPaths entry.
                find "$partial" -mindepth 1 -maxdepth 1 -type l -delete
              fi
            done
            if [ ! -e "$src" ] || rmdir "$src" 2>/dev/null; then
              mv "$partial" "$src"
            else
              # An empty mount point of its own: can't be replaced.
              cp -a "$partial"/. "$src"/
              rm -rf "$partial"
            fi
          fi
          ${
            if owner != null then
              ''chown -R ${escapeShellArg owner} "$src"''
            else
              ''chown root:root "$src" && chmod 0755 "$src"''
          }
        '';
      };
    };
}
