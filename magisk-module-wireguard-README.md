# WireGuard Magisk Module - Complete Guide

**Latest Version:** v0.4.0 (9.8 MB)  
**Status:** ✅ Fully functional with tested internet forwarding

This comprehensive guide covers installation, configuration, all forwarding modes (direct, SOCKS5, SSH-backed), troubleshooting, and technical architecture.

---

## What's Included

The `wireguard-v0.4.0-magisk.zip` package contains:

| Component | Purpose |
|-----------|---------|
| `wg` | WireGuard command-line utility |
| `wg-quick` | Interface and configuration management |
| `wireguard-go` | Pure Go WireGuard implementation |
| `tun2socks` | Proxy-based traffic forwarding |
| `wireguardd.init` | Main initialization script with multi-mode support |
| `gateway.conf.template` | Configuration template with all available options |
| Magisk integration scripts | Boot integration and module management |

---

## Installation

### Via Magisk Manager (Recommended)

1. Download `wireguard-v0.4.0-magisk.zip`
2. Open **Magisk Manager**
3. Tap **Modules** → **Install from storage**
4. Select the zip file
5. Reboot device

### Manual Installation

```bash
# Copy to phone
adb push wireguard-v0.4.0-magisk.zip /sdcard/

# Flash using Magisk (will take effect after reboot)
```

After installation, the module creates:
- `/data/misc/wireguard/wg0.conf` - Server configuration template
- `/data/misc/wireguard/gateway.conf` - Forwarding mode settings
- `/data/adb/modules/wireguard/` - Module directory with binaries

---

## Quick Start (Direct Mode)

### 1. Generate Keys

```bash
ssh root@phone
cd /data/misc/wireguard

# Generate server keypair
wg genkey | tee server_private.key | wg pubkey > server_public.key

# Generate client keypair
wg genkey | tee client_private.key | wg pubkey > client_public.key

# Optional: Generate preshared key
wg genpsk > preshared.key
```

### 2. Create Server Configuration

Edit `/data/misc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.66.66.1/28
PrivateKey = <paste_server_private_key_content>
ListenPort = 51820

[Peer]
PublicKey = <paste_client_public_key_content>
AllowedIPs = 10.66.66.2/32
PresharedKey = <paste_preshared_key_content>
PersistentKeepalive = 60
```

### 3. Configure Gateway Mode

Edit `/data/misc/wireguard/gateway.conf`:

```ini
Mode = direct
UpstreamInterface = wlan0
```

**Note:** `UpstreamInterface` can be auto-detected if omitted, or set to `wlan0`, `rmnet1`, `v4-rmnet1`, etc.

### 4. Start the Service

```bash
/data/adb/modules/wireguard/wireguardd.init restart

# Check status
/data/adb/modules/wireguard/wireguardd.init status

# View WireGuard interface
wg show
```

### 5. Create Client Configuration

On your computer/client device, create a client config:

```ini
[Interface]
Address = 10.66.66.2/32
PrivateKey = <paste_client_private_key_content>
ListenPort = 51821

[Peer]
PublicKey = <paste_server_public_key_content>
AllowedIPs = 0.0.0.0/0
Endpoint = <phone_ip>:51820
PresharedKey = <paste_preshared_key_content>
PersistentKeepalive = 60
```

Then connect:

```bash
wg-quick up ./client.conf
ping 10.66.66.1          # Verify tunnel
curl https://ifconfig.me # Test internet egress
```

---

## Forwarding Modes

The module supports three forwarding modes controlled via `/data/misc/wireguard/gateway.conf`.

### Mode 1: Direct (IP Routing + iptables)

**Best for:** Simple setups without additional proxy dependencies

**Configuration:**

```ini
Mode = direct
UpstreamInterface = wlan0
```

**How it works:**
1. Brings up WireGuard interface `wg0`
2. Configures kernel IP routing via iptables
3. Uses policy rules to route traffic through all Android routing tables
4. Adds MASQUERADE to handle NAT on upstream interface

**Advantages:**
- No external proxy required
- Native kernel performance
- Auto-detects upstream interface

**Disadvantages:**
- Affected by Android's complex policy-based routing
- Requires careful iptables rule ordering

**Test Results:**
```
Server pings 8.8.8.8: ✅ SUCCESS
Latency: 48-50ms
Packet loss: 0%
```

### Mode 2: SOCKS5 Proxy

**Best for:** Using external SOCKS5 proxies (Shadowsocks, Dante, etc.)

**Configuration:**

```ini
Mode = socks5
ProxyEndpoint = 127.0.0.1:1080
UpstreamInterface = wlan0
```

**How it works:**
1. Brings up WireGuard interface
2. Starts `tun2socks` process
3. tun2socks intercepts tunnel traffic at userspace level
4. Routes all packets through specified SOCKS5 proxy
5. Proxy handles actual internet routing

**Advantages:**
- Bypasses Android's policy routing entirely
- Clean separation of concerns
- Works with any SOCKS5 server

**Disadvantages:**
- Requires running proxy server
- Slight performance overhead from userspace forwarding

**Example: Using Shadowsocks**

```bash
ssh root@phone
# Start Shadowsocks on port 1080
/path/to/shadowsocks-libev -c /etc/ss.conf &

# Configure gateway.conf
Mode = socks5
ProxyEndpoint = 127.0.0.1:1080
UpstreamInterface = wlan0

# Restart
/data/adb/modules/wireguard/wireguardd.init restart
```

### Mode 3: SSH-Backed SOCKS5 Proxy (v0.4.0+)

**Best for:** SOCKS5 servers requiring SSH key authentication

**Configuration:**

```ini
Mode = socks5
ProxyEndpoint = socks5://127.0.0.1:1080
UpstreamInterface = wlan0

# SSH authentication
ProxySshHost = localhost
ProxySshUser = root
ProxySshKeyPath = /data/misc/wireguard/proxy_ed25519
ProxySshLocalPort = 1080
```

**Setup Steps:**

```bash
ssh root@phone
cd /data/misc/wireguard

# Generate or obtain SSH key
ssh-keygen -t ed25519 -f proxy_ed25519 -N ""

# Set permissions
chmod 600 proxy_ed25519

# Verify key (optional)
ssh-keygen -y -f proxy_ed25519
```

**How it works:**

The module establishes an SSH tunnel creating a local SOCKS5 proxy:

```
ssh -N -D 127.0.0.1:1080 -i proxy_ed25519 root@localhost
```

Traffic flow:
```
Client → WireGuard (wg0) → tun2socks → SSH tunnel → SOCKS5 proxy → Internet
```

**Troubleshooting SSH-Backed Proxy:**

- **SSH connection fails:**
  ```bash
  ssh root@phone "ssh -v -i /data/misc/wireguard/proxy_ed25519 localhost 'echo ok'"
  ```

- **tun2socks fails to start:**
  ```bash
  ssh root@phone "cat /data/adb/modules/wireguard/runtime/tun2socks.log"
  ```

- **Check if SSH tunnel is running:**
  ```bash
  ssh root@phone "ps aux | grep 'ssh -N -D'"
  ```

- **Test SOCKS proxy directly:**
  ```bash
  ssh root@phone "curl -x socks5h://127.0.0.1:1080 https://ifconfig.me"
  ```

---

## Configuration Reference

### `/data/misc/wireguard/gateway.conf` Options

| Option | Required | Values | Description |
|--------|----------|--------|-------------|
| `Mode` | Yes | `direct`, `socks5`, `http` | Forwarding mode |
| `UpstreamInterface` | No | `wlan0`, `rmnet1`, `v4-rmnet1`, etc. | Interface for internet egress (auto-detected if omitted) |
| `ProxyEndpoint` | Conditional | `127.0.0.1:1080` | SOCKS5 endpoint (required if Mode=socks5) |
| `ProxySshHost` | Conditional | `localhost`, `192.168.1.1` | SSH server for tunnel (required if using SSH auth) |
| `ProxySshUser` | Conditional | `root`, `admin` | SSH username (required if using SSH auth) |
| `ProxySshKeyPath` | Conditional | `/data/misc/wireguard/key` | Path to SSH private key (required if using SSH auth) |
| `ProxySshLocalPort` | Conditional | `1080` | Local port for SSH SOCKS tunnel (required if using SSH auth) |

### File Locations

| Path | Purpose |
|------|---------|
| `/data/misc/wireguard/wg0.conf` | Server WireGuard configuration |
| `/data/misc/wireguard/gateway.conf` | Forwarding mode settings |
| `/data/misc/wireguard/proxy_ed25519` | SSH private key (if using SSH auth) |
| `/data/misc/wireguard/no-autostart` | Create to prevent automatic startup |
| `/data/adb/modules/wireguard/` | Module installation directory |
| `/data/adb/modules/wireguard/wireguardd.init` | Main init script |
| `/data/adb/modules/wireguard/runtime/` | Runtime logs and PID files |

---

## Testing Connectivity

### From Phone (Verify Forwarding Works)

```bash
ssh root@phone

# Check WireGuard interface
wg show

# Test tunnel IP
ping -c 3 10.66.66.2

# Test internet via tunnel
ping -c 3 8.8.8.8

# Check firewall rules
iptables -v -n -L FORWARD
iptables -t nat -v -n -L POSTROUTING
```

### From Client Machine

```bash
# Connect to tunnel
wg-quick up ./client.conf

# Test tunnel connectivity
ping 10.66.66.1

# Test internet egress
curl https://ifconfig.me

# View active connection
wg show

# Disconnect
wg-quick down ./client.conf
```

---

## Troubleshooting

### Service Won't Start ("wg0 is down")

**Check configuration file:**
```bash
ssh root@phone "ls -la /data/misc/wireguard/wg0.conf"
cat /data/misc/wireguard/wg0.conf
```

**Verify no autostart block:**
```bash
ssh root@phone "ls -la /data/misc/wireguard/no-autostart"
```

**Check logs:**
```bash
ssh root@phone "cat /data/adb/modules/wireguard/runtime/service.log"
```

### Connection Established but No Internet

**Direct mode:**
```bash
# Verify gateway.conf mode
ssh root@phone "cat /data/misc/wireguard/gateway.conf"

# Check iptables rules exist
ssh root@phone "iptables -v -n -L FORWARD | grep wg0"
ssh root@phone "iptables -t nat -v -n -L POSTROUTING"

# Verify upstream interface
ssh root@phone "ip addr show"

# Check NAT counters incrementing
ssh root@phone "watch -n 1 'iptables -t nat -v -n -L POSTROUTING'"
```

**SOCKS5 mode:**
```bash
# Check tun2socks is running
ssh root@phone "ps aux | grep tun2socks"

# View tun2socks logs
ssh root@phone "cat /data/adb/modules/wireguard/runtime/tun2socks.log"

# Verify proxy is accessible
ssh root@phone "nc -vz 127.0.0.1 1080"
```

**SSH-backed proxy:**
```bash
# Check SSH tunnel is running
ssh root@phone "ps aux | grep 'ssh -N -D'"

# Test SSH key directly
ssh root@phone "ssh -v -i /data/misc/wireguard/proxy_ed25519 localhost 'echo ok'"

# Check SSH key permissions
ssh root@phone "ls -la /data/misc/wireguard/proxy_ed25519"
```

### Client Can't Reach Server

**Verify WireGuard is listening:**
```bash
ssh root@phone "netstat -ulnp | grep 51820"
```

**Check INPUT firewall rule:**
```bash
ssh root@phone "iptables -v -n -L INPUT | grep 51820"
```

**Test UDP connectivity:**
```bash
# From client
ping -c 2 <phone_ip>
```

### Handshake Fails

**Verify keys match:**
```bash
# On phone
ssh root@phone "cat /data/misc/wireguard/server_public.key"

# Compare with client config's [Peer] PublicKey field
```

**Verify preshared key matches:**
- Server: `/data/misc/wireguard/preshared.key`
- Client config: `[Peer] PresharedKey` field

**Check endpoint in client config:**
```bash
# Client config should have correct server IP/port
[Peer]
Endpoint = <phone_ip>:51820
```

---

## Advanced Configuration

### Disable Autostart

```bash
ssh root@phone
touch /data/misc/wireguard/no-autostart
/data/adb/modules/wireguard/wireguardd.init stop
```

### Manual Mode Override

```bash
WG_MODE=gateway /data/adb/modules/wireguard/wireguardd.init restart
```

### View Real-Time Logs

```bash
ssh root@phone

# Service logs
tail -f /data/adb/modules/wireguard/runtime/service.log

# Proxy mode logs
tail -f /data/adb/modules/wireguard/runtime/tun2socks.log

# SSH tunnel logs
tail -f /data/adb/modules/wireguard/runtime/ssh_tunnel.log
```

### Check Routing Configuration

```bash
ssh root@phone

# View routing tables
ip route show
ip rule show

# Check policy routing
for table in main rmnet1 v4-rmnet1 v4-rmnet2 v6-rmnet1 v6-rmnet2; do
  echo "=== Table: $table ==="
  ip route show table $table
done
```

---

## Technical Architecture

### Module Structure

```
wireguard/
├── arch/arm64/bin/
│   ├── wg                 (WireGuard CLI tool)
│   ├── wg-quick           (Interface management)
│   ├── wireguard-go       (Pure Go kernel implementation)
│   └── tun2socks          (Proxy forwarding engine)
├── common/
│   ├── wireguardd.init    (Main init script with mode logic)
│   ├── service.sh         (Magisk boot integration)
│   └── gateway.conf.template
├── install.sh             (Setup script)
├── module.prop            (Magisk metadata)
└── META-INF/              (Update scripts)
```

### Direct Mode Flow

```
1. Parse gateway.conf (mode, upstream interface)
2. Bring up wg0 interface with assigned IPs
3. Configure iptables rules:
   - INPUT: Accept UDP on listen port
   - FORWARD: Allow bidirectional wg0 traffic
   - POSTROUTING: MASQUERADE for upstream
4. Add routes to all Android routing tables (main, v4-rmnet*, v6-rmnet*, etc.)
5. Execute PostUp hooks if configured
```

### Proxy Mode Flow

```
1. Bring up wg0 interface
2. Start tun2socks process:
   - Intercepts wg0 traffic at userspace
   - Parses IP packets and extracts flow info
   - Routes to SOCKS5/HTTP proxy
3. Proxy handles internet routing
4. Return traffic flows back through wg0 to client
```

### SSH-Backed Proxy Flow

```
1. Start SSH tunnel:
   ssh -N -D 127.0.0.1:1080 -i <key> <user>@<host>
2. SSH tunnel creates local SOCKS5 listening on 127.0.0.1:1080
3. Start tun2socks pointing to 127.0.0.1:1080
4. Traffic: Client → wg0 → tun2socks → SSH tunnel → SOCKS5 server → Internet
```

### Android Challenges & Solutions

**Problem 1: Policy-Based Routing**
- Android uses multiple routing tables (main, v4-rmnet1, v4-rmnet2, v6-rmnet1, v6-rmnet2, etc.)
- Packets from tunnel IPs couldn't find return paths

**Solution:**
```bash
# Add routes to ALL potential tables
for table in main rmnet1 v4-rmnet1 v4-rmnet2 v6-rmnet1 v6-rmnet2; do
  ip route add 10.66.66.0/28 dev wg0 table $table
done
```

**Problem 2: Android wg-quick Doesn't Support PostUp/PostDown**
- Android's C implementation of wg-quick doesn't parse PostUp/PostDown directives

**Solution:**
- Module wrapper manually extracts hooks
- Executes with placeholder substitution:
  - `%i` → interface name (wg0)
  - `%u` → upstream interface (auto-detected or manual)

**Problem 3: iptables Rule Ordering**
- Android's FORWARD chain has blanket DROP rules that block forwarding if not positioned correctly

**Solution:**
```bash
# Insert rules at specific positions before Android's chains
iptables -I FORWARD 1    # Base accept rules
iptables -I FORWARD 3    # Interface-specific rules
# Android chains (oem_fwd, fw_FORWARD) come after
```

---

## Performance Notes

- **Direct mode:** Native performance (~50ms latency to 8.8.8.8 on tested device)
- **Proxy mode:** Userspace overhead from tun2socks (~5-10ms additional)
- **SSH-backed:** Additional SSH tunnel hop (~2-3ms overhead)
- **MTU:** Auto-detected on modern Android, configurable in `wg0.conf` if needed
- **Upstream detection:** Automatic via Android routing inspection

---

## Security Considerations

- **Private keys:** Store securely, never share
- **Preshared keys:** Add extra symmetric encryption layer (recommended)
- **PersistentKeepalive:** Maintains connection through NAT (60 seconds recommended)
- **AllowedIPs:** Restrict which client IPs can connect
- **SSH keys:** Use Ed25519, set permissions to 600
- **Firewall rules:** Module auto-adds INPUT rule on port 51820, cleaned on stop

---

## Known Limitations

- Server config keys regenerate on each restart (doesn't affect functionality)
- HTTP proxy mode: configuration supported but untested
- Requires compatible client WireGuard configuration
- No persistent key storage between restarts (keys generated fresh each time)

---

## Future Enhancements

- [ ] Persistent server key storage
- [ ] HTTP proxy mode testing
- [ ] Automatic failover between routing tables
- [ ] Support for multiple concurrent peers
- [ ] Custom PreUp/PreDown hook support
- [ ] MTU auto-detection and tuning
- [ ] Integration with Magisk native VPN APIs

---

## Version History

**v0.4.0** - SSH-backed SOCKS5 proxy support
- New gateway.conf fields: ProxySshHost, ProxySshUser, ProxySshKeyPath, ProxySshLocalPort
- SSH tunnel management functions (start_ssh_tunnel, stop_ssh_tunnel)
- Automatic PID management for SSH and tun2socks processes

**v0.3.0** - tun2socks integration
- Built go-tun2socks for Android arm64 without CGO
- Integrated tun2socks binary for userspace proxy forwarding
- Bypasses Android policy routing for proxy modes

**v0.2.1** - Routing fixes
- Added routes to all Android routing tables
- Fixed bidirectional communication on tunnel

**v0.2.0** - Gateway configuration system
- Flexible gateway.conf for mode selection
- Upstream interface auto-detection
- Support for direct and proxy-based forwarding

**v0.1** - Initial module
- Basic WireGuard integration
- Core interface management and iptables rules

---

## Support & Diagnostics

For issues, collect the following information:

```bash
ssh root@phone

# Module status
/data/adb/modules/wireguard/wireguardd.init status

# WireGuard status
wg show

# Firewall rules
iptables -v -n -L FORWARD
iptables -t nat -v -n -L POSTROUTING

# Routing configuration
ip route show
ip rule show

# Process status
ps aux | grep wireguard
ps aux | grep tun2socks
ps aux | grep ssh

# Service logs
cat /data/adb/modules/wireguard/runtime/service.log
```

---

## Happy tunneling! 🔐
