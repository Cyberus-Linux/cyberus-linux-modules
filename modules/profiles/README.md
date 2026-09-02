Profiles
========

Profiles implement collection of settings that are generally enabled together.

Since some options can be awkward to undo, it is important that the many *logical settings* that are set can be disabled.

The pattern used for profiles is the following:

```nix
{ config, lib, ... }:

let
  cfg = config.cyberus-linux.profiles.${profileName};
  # Makes an "enable" option that defaults to the `${profileName}.enable` state.
  mkDefaultEnable = description:
    (lib.mkEnableOption description) // {
      default = cfg.enable;
      defaultText = "config.cyberus-linux.profiles.${profileName}.enable";
    }
  ;
{
  options = {
    cyberus-linux.profiles.${profileName} = {
      enable = lib.mkEnableOption "the [...] options";
      # Then, as needed, discrete options for the collection.
      useFoo = mkDefaultEnable "enabling systemd-wide usage of foo";
      disableBar = mkDefaultEnable "disabling systemd-wide usage of bar";
      # etc...
    };
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.useFoo {
      services.foo.enable = true;
    });
    (lib.mkIf cfg.disableBar {
      services.bar.enable = false;
    });
  ];
}
```

It is important not to make the logic *weird* with the logical settings: they must ***all*** resolve to `cfg.enable` as their default value.
When usage of the profile is not enabled, including the options module should be a no-op.

In the previous example, making `useBar` rather than `disableBar` would have required making the option a negation, or making the implementation weird by checking both for `cfg.enable` and `cfg.useBar`.

### Why make discrete options when you can `mkForce`?

There are two main reasons.
First, this makes it possible for users of the modules to enable only a logical configuration from our module without enabling the whole profile.

Then, this also helps ensure we are not forcibly clobbering `mkDefault` or other `mkOverride` levels from the user's config when they want to enable a whole profile except one option.
This is especially needed for `listOf` type options, or `attrsOf` that may `mkMerge` badly, or unexpectedly.

Whether opting-in or opting-out is desired, both are important escape hatches for our modules users.
