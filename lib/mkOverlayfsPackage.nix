# Author: Libor Štěpánek 2025
{
  pkgs,
  stdenv,
}: {
  basePackage,
  executablePath,
  executableName,
  overlayDependencies ? [],
  extraEnvCommands ? "",
  extraPreLaunchCommands ? "",
  interpreter ? "",
  basePackageName ? basePackage.pname,
}:
stdenv.mkDerivation {
  pname = basePackage.pname + "-overlay";
  version = basePackage.version;
  meta.executableName = executableName;
  unpackPhase = ''true'';

  buildPhase = let

    # the script which serves as a stand-in for the executable specified by 'executablePath' and named as 'executableName'
    entryScript = pkgs.writeShellScript "runApp" ''
      
      # Checking the location for the writable layer
      if [ -z ''${HOME+x} ]; then
          exit 1
      fi

      if [ -z ''${XDG_DATA_HOME+x} ]; then
          XDG_DATA_HOME="$HOME/.local/share"
      fi

      export appdir="$XDG_DATA_HOME/${basePackageName}"
      export originalUser="$USER"
      export tempdir=$(mktemp -d)

      ${extraEnvCommands}

      mkdir --parents "$appdir" "$tempdir/bind" "$tempdir/overlay" || exit 1

      # Creating the mount namespace and launching the environment script
      ${pkgs.util-linux}/bin/unshare --map-root-user --mount "__STOREPATH__/libexec/${executableName}-setupEnv.sh" "$@"

      rm -r "$tempdir"
    '';

    # The environment script, launched from the entry script
    envScript = {
      executablePath,
      overlayDependencies,
      extraPreLaunchCommands,
    }: let
      deps = builtins.map (x: "\"" + x + "\"") overlayDependencies;
    in
      pkgs.writeShellScript "runEnv" ''
        set -euxo pipefail

        deps=(${pkgs.lib.strings.concatStringsSep " " deps});
        depsstring="";

        # Creating a bind mount for each dependency, overriding their permissions and ownership
        for i in "''${!deps[@]}"; do
          mkdir "$tempdir/bind/$i"
          dep="''${deps[$i]}"
          if [[ -e "$dep/basePackage" ]]; then
            target="$dep/basePackage"
          else
            target="$dep"
          fi
          
          echo "Making bind mount $i in $tempdir for $target"
          ${pkgs.bindfs}/bin/bindfs --perms=+w --force-user=0 --force-group=0 "$target" "$tempdir/bind/$i" || { echo "bindfs failed"; exit 1; }
          depsstring=":"$tempdir/bind/$i"=ro''${depsstring}"
        done

        # Repeating the same for the base package
        mkdir "$tempdir/bind/''${#deps[@]}"
        echo "Making bind mount base in $tempdir for ''${#deps[@]}"
        ${pkgs.bindfs}/bin/bindfs --perms=+w --force-user=0 --force-group=0 "__STOREPATH__/basePackage" "$tempdir/bind/''${#deps[@]}" || { echo "bindfs failed"; exit 1; }

        # Joining all dependencies with unionfs
        echo "Making unionfs mount, despstring: $depsstring"
        ${pkgs.unionfs-fuse}/bin/unionfs -o cow "$appdir=rw:$tempdir/bind/''${#deps[@]}=ro$depsstring" "$tempdir/overlay" || { echo "unionfs failed"; exit 1; }

        cd "$tempdir/overlay/"

        ${extraPreLaunchCommands}

        # Launching the user namespace to map the original user and running the specified application
        ${pkgs.util-linux}/bin/unshare --map-user="$originalUser" ${interpreter} "$tempdir/overlay/${executablePath}" "$@"
      '';
  in ''
    set -euxo pipefail
    mkdir bin libexec
    ln --symbolic ${basePackage} basePackage

    # If package is executable, copy scripts, replace placeholder values with store path and name them appropriately
    if [[ "" != "${executableName}" ]]; then
      cp ${entryScript} ./bin/${executableName}
      sed -i "s#__STOREPATH__#$out#g" ./bin/${executableName}

      cp ${(envScript {inherit executablePath overlayDependencies extraPreLaunchCommands;})} ./libexec/${executableName}-setupEnv.sh
      sed -i "s#__STOREPATH__#$out#g" ./libexec/${executableName}-setupEnv.sh
      chmod a+x ./libexec/${executableName}-setupEnv.sh ./bin/${executableName} ./libexec/${executableName}-setupEnv.sh
    fi
  '';

  installPhase = ''
    mkdir $out
    mv bin basePackage libexec $out/
  '';
}
