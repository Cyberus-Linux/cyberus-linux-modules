# Cyberus Linux Modules

This repository is a collection of curated modules that work great
with [Cyberus Linux](https://cyberus-linux.com/) (and NixOS).

## Module Documentation

Detailed module documentation and Getting Started guides are soon available on
[docs.cyberus-linux.com](https://docs.cyberus-linux.com/).

All modules are available via `nixosModules` of this Flake. If you don't use
Flakes, import the module file in `/modules` directly. We will streamline this
later!

Modules have different purposes and semantics, and thus interfaces. Read the
usage for your chosen modules for more details about their use.

## Available Modules

These are the modules that are currently available. Modules marked
**Testing** or **Beta** are still in development and may change
significantly. Modules marked **Stable** will only change in
backward-compatible ways.

Module documentation lives on
[docs.cyberus-linux.com](https://docs.cyberus-linux.com/modules/). Click the
module link to go directly to the documentation of a specific module.

Modules may not be supported on all releases. We use the following
status symbols:

- ✅ - Supported
- 🚧 - Planned/WIP
- ❌ - Not Planned

| Module                                                                       | Status     | Unstable | 26.05 | 24.05 | Description                                     |
|------------------------------------------------------------------------------|------------|----------|-------|-------|-------------------------------------------------|
| [`profiles`](https://docs.cyberus-linux.com/modules/cyberus-linux-profiles/) | **Stable** | ✅       | 🚧    | ✅    | Different opinionated settings for Cyberus Linux |
| [`vms`](https://docs.cyberus-linux.com/modules/cyberus-linux-vms/)           | **Beta**   | ✅       | 🚧    | ❌    | Declarative way to run generic VMs               |

## Hardware Support

Cyberus Linux works fine on many platforms. Especially Intel/AMD systems
should in general Just Work. We maintain opinionated hardware support
for platforms that have sharp edges.

Just like modules, hardware support status depends on the release.

| Platform                | Status      | Unstable | 26.05 | 24.05 |
|-------------------------|-------------|----------|-------|-------|
| Nvidia Jetson Orin Nano | **Testing** | ✅       | 🚧    | ❌    |
