# Magisk Shells
This README documents the built Magisk module package (runtime behavior and usage), not the build script.

## Module identity
- Module ID: `magisk-shells`
- Name: `Magisk Shells`
- Current packaged version: `v1.1`
- Package filename (current): `magisk-shells-v1.1-magisk.zip`
- Target architecture in current package: `arm64`

## What this module installs
Commands mounted into `/system/bin`:
- `bash`
- `zsh`
- `fish`
- `starship`
- `magisk-shells-init` (helper script)

Bundled assets:
- Oh My Zsh tree at module path `common/oh-my-zsh/`
- Shell template configs at `common/templates/`:
  - `.bashrc`
  - `.zshrc`
  - `config.fish`

Persistent data root:
- `/data/adb/magisk_shells`

## Installation behavior (what happens when flashed)
Installer logic is non-destructive where possible:
1. Extracts available binaries for `arm64` into module `/system/bin`.
2. Creates:
   - `/data/adb/magisk_shells/bash`
   - `/data/adb/magisk_shells/zsh`
   - `/data/adb/magisk_shells/fish`
3. Copies bundled Oh My Zsh into `/data/adb/magisk_shells/oh-my-zsh` if not already present.
4. Optionally installs template dotfiles into writable `$HOME` / `$XDG_CONFIG_HOME` only if target files do not already exist.
5. Writes a simple local README at `/data/adb/magisk_shells/README` if missing.

## Boot behavior
Module `service.sh` ensures these directories exist at boot:
- `/data/adb/magisk_shells/bash`
- `/data/adb/magisk_shells/zsh`
- `/data/adb/magisk_shells/fish`

No global environment variables are forced by the module.

## Quick start
Verify binaries:
- `bash --version`
- `zsh --version`
- `fish --version`
- `starship --version`

Use helper to seed configs into a writable HOME:
- `HOME=/data/adb/magisk_shells magisk-shells-init`

Suggested environment setup (example):
- `export HOME=/data/adb/magisk_shells`
- `export ZDOTDIR=/data/adb/magisk_shells/zsh`
- `export XDG_CONFIG_HOME=/data/adb/magisk_shells`

Then run:
- `zsh`
- `fish`
- `bash`

## Template behavior
`magisk-shells-init` and installer template copy are intentionally safe:
- they do **not** overwrite existing `~/.bashrc`, `~/.zshrc`, or `config.fish`
- they only populate missing files

This makes it safe to use the module alongside existing shell setups.

## Uninstall behavior
By default, uninstall removes:
- `/data/adb/magisk_shells`

To preserve user data across uninstall:
- create sentinel file:
  - `/data/adb/magisk_shells/KEEP_ON_UNINSTALL`

## Notes
- Current package is `arm64` only.
- Shell functionality depends on your execution context and environment variables.
- The module provides binaries and templates; it does not enforce a specific login shell policy.

