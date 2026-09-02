# A `nixpkgs.lib` compatible lib must be provided.
{ lib }:

let
  self = {
    /**
      Applies the function `fn` on the direct children directories of `dir`.
    */
    mapDirs =
      fn: dir:
      let
        dirs = builtins.map (name: fn (dir + "/${name}")) (
          builtins.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir dir))
        );
      in
      dirs;

    /**
      Given a directory where children are structured by vendors and *thing*,
      returns an attribute set with combined `"${vendor}-${thing}"` names,
      and values representing that subdirectory.
    */
    getVendorsModules =
      dir:
      builtins.listToAttrs (
        builtins.concatLists (
          self.mapDirs (
            vendorDir:
            let
              vendor = builtins.baseNameOf vendorDir;
            in
            self.mapDirs (
              thingDir:
              let
                thing = builtins.baseNameOf thingDir;
              in
              {
                name = "${vendor}-${thing}";
                value = thingDir;
              }
            ) vendorDir
          ) dir
        )
      );

    /**
      Returns the Flake lock information for the given input name on this Flake.
    */
    getFlakeInput =
      name:
      let
        data = builtins.fromJSON (builtins.readFile ../flake.lock);
        nodeName = data.nodes.root.inputs.${name};
      in
      data.nodes.${nodeName};
  };
in
self
