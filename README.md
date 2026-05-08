This software comes with absolutely no warrenty whatsoever either excplicit or implied.

Pro-Tip: ⚠️ Do not randomly download modules from untrusted sources just because they look cool.

# magisk-module-builds
couple of all-in-one scripts that build some neat magisk modules I made.


I've made a few magisk modules and rather than storing them all as source code,
instead, I createa bash script that simply downloads and builds everything locally for you.

scripts were tested on an ArchLinux box.

# magisk-module-shells.sh
creates a flashable magisk module that adds bash, zsh, & fish to your android! With [starship][https://starship.rs/] as well!


# magisk-module-ssh.sh
Project forked from [MagiskSSH][https://gitlab.com/d4rcm4rc/MagiskSSH],
openssl bumped to 4.0.0
openssh bumped to 10.3.p1
AND openssh compiled with tunnel support.

# magisk-module-wireguard.sh
A simple module that bundles wg, wg-quick, wireguard-go, and tun2socks.  
Flash the module zip in Magisk, reboot, then configure.

After installation, the module creates:
- `/data/misc/wireguard/wg0.conf` - Server configuration template
- `/data/misc/wireguard/gateway.conf` - Forwarding mode settings
- `/data/adb/modules/wireguard/` - Module directory with binaries

Service control is built in via wireguardd.init (start|stop|restart|status).
