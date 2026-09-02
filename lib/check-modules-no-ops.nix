# Instantiating against an arbitrary Nixpkgs:
#  $ nix-instantiate --attr result ./lib/check-modules-no-ops.nix --arg pkgs 'import <nixpkgs> {}'
# Using in a REPL with an arbitrary Nixpkgs:
#  $ nix repl -f ./lib/check-modules-no-ops.nix --arg pkgs 'import <nixpkgs> {}'
{
  pkgs,

  # Base configuration compared against.
  # There shouldn't be any need to change this with a NixOS evaluation.
  baseCfg ?
    let
      inherit (pkgs) lib;
    in
    {
      # Prevent stray warnings in the output.
      system.stateVersion = lib.mkDefault "00.00";

      # Manual builds will differ since new options are added. This is okay.
      documentation.nixos.enable = lib.mkDefault false;

      # Minimum config for evaluation purpose.
      # `boot.isContainer` will not work as hoped.
      fileSystems."/".fsType = lib.mkDefault "ext4";
      fileSystems."/".device = lib.mkDefault "nodev";
      boot.loader.grub.devices = lib.mkDefault [ "nodev" ];
      nixpkgs.hostPlatform = lib.mkDefault pkgs.stdenv.hostPlatform.system;
    },

  # Function that takes a `config` attribute set or function, and evaluates
  # a Modules system returning the bare attribute set from the evaluation.
  evalConfig ?
    config:
    (import (pkgs.path + "/nixos")) {
      configuration = {
        imports = [
          config
          baseCfg
        ];
      };
      # Use Flakes-required semantics around NixOS `system` argument.
      system = null;
    },

  # The modules being checked. Like `nixosModules` in Flakes.
  modules ? import ../modules,
}:

let
  inherit (pkgs) lib;

  # `walkOptions` applies `fn` to all “options” found in the `options`
  # attribute set of a NixOS module system evaluation.
  # Think of it like “`mapAttrs` but only for the option leaf nodes”.
  walkOptions =
    fn: options:
    walkOptions' {
      inherit fn;
      options =
        # Cleanup `options` eagerly.
        options // {
          meta = builtins.removeAttrs (options.meta or { }) [
            # meta.maintainers historically may contain bogus entries that abort evaluation.
            # This is problematic for no-op checking, so don't check for those.
            "maintainers"
          ];
        };
    };

  # Implementation details for `walkOptions`.
  walkOptions' =
    {
      options,
      attrPath ? [ ],
      fn,
    }:
    builtins.mapAttrs (
      name: value:
      let
        currPath = attrPath ++ [ name ];
      in
      if builtins.isAttrs value && (value._type or null != "option") then
        walkOptions' {
          options = value;
          attrPath = currPath;
          inherit fn;
        }
      else
        fn currPath value
    ) options;

  # Takes a module system option tree, and walk through it to simplify its
  # structure in a way that evaluates around the values being evaluated.
  # While incomplete, this provides a way to compare two different module
  # system evaluation.
  # It will be lacking some definition locations in `definitionLocations'`.
  # At the same time, this will catch (through `highestPrio`) those where the
  # definitions differ but couldn't be listed. Except for cases where both
  # the declarations can't be listed and the definitions have the same
  # priority, such as attribute sets and lists.
  # TIP: To further confirm no-op-ness, evaluate a "holistic" value, like the
  #      `system.build.toplevel` or other similar results.
  simplifyOptions = walkOptions (
    _path: option:
    let
      result = builtins.tryEval (
        let
          values = rec {
            # Evaluating `default` may fail, and that's expected.
            hasDefault = option ? default;
            # Some definition locations that we can evaluate.
            # Note that `defaultText` *very often* implies the option will not evaluate
            # when the modules is not configured entirely. So skip those values...
            definitionLocations' =
              if option ? defaultText then "(skipped possibly un-evaluatable option...)" else option.files;
            # Directly inherit values we can inherit.
            inherit (option)
              declarationPositions
              highestPrio
              options
              ;

            # The type *technically* can be changed, but is generally awkward to
            # compare, so pick a few representative values out.
            type = {
              inherit (option.type)
                _type
                description
                name
                ;
            }
            // (lib.optionalAttrs (option.type ? internal) { inherit (option) internal; });

            # While untrue, this allows us to call `walkOptions` to walk this simplified tree.
            _type = "option";
          }
          // (lib.optionalAttrs (option ? description) { inherit (option) description; })
          // (lib.optionalAttrs (option ? defaultText) { inherit (option) defaultText; });
        in
        # Fail eagerly, or else laziness will make this fail outside the `tryEval`.
        builtins.deepSeq (builtins.attrValues values) values
      );
    in
    if result.success then
      result.value
    # We treat (catchable) errors as being a comparable value.
    # Any error is equal to another error.
    # There won't be uncatchable errors in a correct module.
    else
      "« error at ${option} »"
  );

  # Compare NixOS module system `optionsA` and `optionsB`, returning the
  # options from `optionsB`, keeping only the options found in `optionsA`.
  # This is used to remove the added options from the new modules in the
  # `optionsB` evaluation.
  filterExistingOptionsFrom =
    optionsA: optionsB:

    walkOptions (
      attrPath: _:
      lib.attrByPath attrPath "« Options ${builtins.toJSON attrPath} missing in optionsB... »" optionsB
    ) optionsA;

  # Returns an attribute set with `{ a = ...; b = ...; }` where `a` is the
  # `simplifyOptions optionsA` and `b` is the result of keeping only the common
  # options with `optionsA` after `simplifyOptions optionsB`.
  # This result is what gets compared.
  prepareOptionsForComparison =
    optionsA: optionsB:

    rec {
      a = simplifyOptions optionsA;
      b = filterExistingOptionsFrom a (simplifyOptions optionsB);
    };

  compareEvals =
    name: evalA: evalB:

    let
      toplevelA = builtins.unsafeDiscardStringContext evalA.config.system.build.toplevel.drvPath;
      toplevelB = builtins.unsafeDiscardStringContext evalB.config.system.build.toplevel.drvPath;
      results =
        builtins.filter (result: result != null)
          # NOTE: we're not using multi-line strings `''` for these messages
          # since they include a final `\n`, and indentation management can be wonky.
          [
            (
              if toplevelA != toplevelB then
                builtins.concatStringsSep "\n" [
                  " - system.build.toplevel does not match:"
                  "   ${toplevelA} != ${toplevelB}"
                ]
              else
                null
            )
            (
              let
                inherit (prepareOptionsForComparison evalA.options evalB.options) a b;
                jsonA = builtins.toFile "evalA.json" (builtins.toJSON a);
                jsonB = builtins.toFile "evalB.json" (builtins.toJSON b);
              in
              if (a != b) then
                builtins.concatStringsSep "\n" [
                  " - Module system evaluations differ"
                  "   ${jsonA} != ${jsonB}"
                  "   Tip: use `jdiff --syntax rightonly --indent 2 ${jsonA} ${jsonB}` to compare."
                ]
              else
                null
            )
          ];
    in
    if results != [ ] then
      [
        ''
          Module '${toString name}' on ${evalA.pkgs.stdenv.hostPlatform.system} is not a no-op.
          ${builtins.concatStringsSep "\n" results}
        ''
      ]
    else
      [ ];

  # The default evaluation being compared against, without added modules.
  defaultEval = evalConfig { };

  # Given an attrset `{ moduleName = importedModule; }`, check each module
  # and throw with a list of module issues.
  checkModules =
    modules:
    let
      results = builtins.concatLists (
        lib.mapAttrsToList (name: module: compareEvals name defaultEval (evalConfig module)) modules
      );
    in
    if results != [ ] then builtins.throw (lib.concatStringsSep "\n" results) else true;

  # The trivial-to-access result value
  result = checkModules modules;
in
# We are exposing some of the functions so this can be more easily
# diagnosed withing a `nix repl` invocation.
{
  inherit
    # Functions
    checkModules
    evalConfig
    filterExistingOptionsFrom
    prepareOptionsForComparison
    simplifyOptions
    walkOptions

    # Values
    modules
    defaultEval

    # Result
    result
    ;
}
