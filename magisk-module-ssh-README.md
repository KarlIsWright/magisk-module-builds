# SSH for Magisk
This README documents the built Magisk module package (runtime behavior and usage), not the build script.

## Module identity
- Module ID: `ssh`
- Name: `SSH for Magisk`
- Current packaged version: `v0.27.2`
- Package filename (current): `magisk_ssh-v0.27.2-magisk.zip`
- Target architecture in current package: `arm64`

## What this module installs
After flashing, the module provides OpenSSH + Rsync commands via `/system/bin`:
- `ssh`
- `scp`
- `sftp`
- `sftp-server`
- `ssh-keygen`
- `sshd`
- `sshd-session`
- `sshd-auth`
- `rsync`

Implementation details:
- `/system/bin/<command>` entries are wrapper symlinks.
- Real binaries are stored under:
  - `/system/usr/libexec/ssh-core/`
- OpenSSL runtime library is mounted at:
  - `/system/usr/lib/libcrypto.so`

## Persistent runtime/config data
The module stores runtime/config under:
- `/data/ssh/sshd_config`
- `/data/ssh/root/.ssh/authorized_keys`
- `/data/ssh/shell/.ssh/authorized_keys`
- `/data/ssh/sshd.pid` (runtime)
- generated host keys in `/data/ssh` (on first start)

## Installation
1. Open Magisk app.
2. Install module from storage (`magisk_ssh-v0.27.2-magisk.zip`).
3. Reboot.

## First-time setup
The installer ensures both authorized_keys files exist. Add your public keys:
- `/data/ssh/root/.ssh/authorized_keys` for root login
- `/data/ssh/shell/.ssh/authorized_keys` for shell login

Recommended permissions:
- `authorized_keys`: `0600`
- `~/.ssh` directories: `0700`

Default daemon config path:
- `/data/ssh/sshd_config`

Important default in shipped config:
- `PasswordAuthentication no` (key-based auth only unless you change config)

## Service behavior
Autostart:
- Enabled by default at boot via module `service.sh`.
- Disable autostart by creating:
  - `/data/ssh/no-autostart`

Manual control:
- `/data/adb/modules/ssh/opensshd.init start`
- `/data/adb/modules/ssh/opensshd.init stop`
- `/data/adb/modules/ssh/opensshd.init restart`

Notes:
- `opensshd.init start` runs `ssh-keygen -A` before starting `sshd`.
- Actual Magisk module mount path can vary by Magisk version; adjust path if needed.

## Connection examples
- Unprivileged user:
  - `ssh shell@<device_ip>`
- Root user:
  - `ssh root@<device_ip>`

## Uninstall behavior
On uninstall, module removes `/data/ssh` by default.

To preserve keys/config across uninstall:
- create sentinel file:
  - `/data/ssh/KEEP_ON_UNINSTALL`

## Troubleshooting quick checks
- Check service process:
  - `ps -A | grep sshd`
- Try manual restart:
  - `/data/adb/modules/ssh/opensshd.init restart`
- Verify key file permissions:
  - `ls -l /data/ssh/root/.ssh/authorized_keys /data/ssh/shell/.ssh/authorized_keys`

