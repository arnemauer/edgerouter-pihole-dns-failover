# EdgeRouter Pi-hole DNS failover

A small script for Ubiquiti **EdgeRouter** devices (EdgeOS, e.g. EdgeRouter X / X SFP)
that keeps DNS working on your network when your Pi-hole goes down.

The router acts as the DNS server for your clients and forwards all queries to the
Pi-hole. Every minute the script checks whether the Pi-hole still answers DNS
queries. If it doesn't, the router forwards to public resolvers instead. When the
Pi-hole is back, the router forwards to the Pi-hole again.

```
             normal                          Pi-hole down
clients ──► router ──► Pi-hole     clients ──► router ──► 1.1.1.1 / 9.9.9.9
```

Because clients always talk to the router, failover takes effect immediately; no
DHCP lease has to expire.

## How it works

- The router queries a few external domains (`TEST_DOMAINS`) at the Pi-hole. One
  valid answer means healthy. This also tests the Pi-hole's own upstream, not just
  whether the VM/container is running.
- After `FAIL_THRESHOLD` (default 2) failed checks in a row, `service dns forwarding
  name-server` is set to `FALLBACK_DNS` (default `1.1.1.1 9.9.9.9`).
- This only happens if the fallback itself answers. If the whole internet connection
  is down, nothing is changed.
- After `RECOVER_THRESHOLD` (default 3) successful checks in a row, it is set back to
  `PRIMARY_DNS` (the Pi-hole).
- Changes are logged to syslog with tag `dns-failover`.

## Compatibility

| Platform | Supported |
|---|---|
| EdgeRouter (EdgeMAX, EdgeOS 1.x/2.x) | Yes |
| UniFi Security Gateway (USG) | No: the UniFi controller overwrites config changes |
| UniFi OS gateways (UDM, UCG, UXG) | No: different OS without the EdgeOS config tools |

The script uses `dig`, `host` or `nslookup`, whichever is available (EdgeOS 2.x ships
`host`).

## Prerequisites: router configuration

The examples below assume:

| | |
|---|---|
| Router LAN IP | `192.168.1.1` |
| Pi-hole IP | `192.168.1.2` |
| LAN interface | `switch0` |
| DHCP scope | shared-network `LAN`, subnet `192.168.1.0/24` |
| Local domain | `lan` |

Adjust them to your own network (`show interfaces`, `show service dhcp-server`).

### 1. DNS forwarding on the router

```sh
configure
delete service dns forwarding

# listen on the LAN (add one listen-on per interface/VLAN)
set service dns forwarding listen-on switch0

# upstream: the Pi-hole (the script only changes this setting)
set service dns forwarding name-server 192.168.1.2

# no cache on the router, so Pi-hole statistics stay accurate
set service dns forwarding cache-size 0

# let the Pi-hole see which client sent the query
set service dns forwarding options add-mac
set service dns forwarding options add-subnet=32,128

# the router answers local hostnames itself
set service dns forwarding options expand-hosts
set service dns forwarding options domain=lan
set service dns forwarding options local=/lan/
set service dns forwarding options bogus-priv

# the router itself uses public DNS, independent of the Pi-hole
set system name-server 1.1.1.1

commit ; save ; exit
```

Do **not** add `system` or `dhcp <interface>` under `service dns forwarding`; with
those, dnsmasq also uses other servers and queries bypass the Pi-hole.

### 2. DHCP: hand out the router as DNS server and register hostnames

```sh
configure
delete service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 dns-server
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 dns-server 192.168.1.1
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 domain-name lan
set service dhcp-server hostfile-update enable
commit ; save ; exit
```

With `hostfile-update`, DHCP clients are written to `/etc/hosts`, so `nas` and
`nas.lan` resolve on the router, also while the Pi-hole is down. Clients pick up the
new DNS server on their next lease renewal (reconnecting Wi-Fi forces this).

Devices with a static IP outside DHCP can be added manually:

```sh
configure
set system static-host-mapping host-name proxmox.lan alias proxmox
set system static-host-mapping host-name proxmox.lan inet 192.168.1.5
commit ; save ; exit
```

If you had *Local DNS records* in the Pi-hole, move them to the router this way, so
they keep working during a failover.

### 3. Pi-hole settings

- **Conditional forwarding** (optional, for client names in the dashboard): point it
  to the router (`192.168.1.1`, domain `lan`, your LAN subnet). Because the router
  uses `local=/lan/` and `bogus-priv`, this does not create a forwarding loop.
- **Rate limiting**: if the Pi-hole sees most queries coming from the router, the
  default limit (1000 queries per minute per client) can be too low. Raise or disable
  it (`dns.rateLimit` in Pi-hole v6, `RATE_LIMIT=0/0` in `/etc/pihole/pihole-FTL.conf`
  in v5).
- **Interface settings**: the Pi-hole must answer queries from the router
  ("Allow only local requests" works when the router is on the same subnet).

## Installation

1. Copy the script to the router. `/config` survives reboots and firmware upgrades.

   ```sh
   scp dns-forward-failover.sh <user>@192.168.1.1:/tmp/
   ssh <user>@192.168.1.1
   sudo mkdir -p /config/scripts
   sudo mv /tmp/dns-forward-failover.sh /config/scripts/
   sudo chmod 755 /config/scripts/dns-forward-failover.sh
   ```

2. Configure it. Either edit the defaults at the top of the script, or (recommended,
   so you can replace the script later) create `/config/scripts/dns-forward-failover.conf`
   based on [`dns-forward-failover.conf.example`](dns-forward-failover.conf.example):

   ```sh
   sudo tee /config/scripts/dns-forward-failover.conf >/dev/null <<'CONF'
   PIHOLE_IP="192.168.1.2"
   PRIMARY_DNS="192.168.1.2"
   FALLBACK_DNS="1.1.1.1 9.9.9.9"
   CONF
   ```

3. Test it (changes nothing):

   ```sh
   sudo /config/scripts/dns-forward-failover.sh status
   ```

   Expected output:

   ```
   Pi-hole 192.168.1.2: OK
   dns forwarding name-server: 192.168.1.2
   ```

4. Run it every minute with the task scheduler:

   ```sh
   configure
   set system task-scheduler task dns-failover executable path /config/scripts/dns-forward-failover.sh
   set system task-scheduler task dns-failover interval 1m
   commit ; save ; exit
   ```

## Configuration

| Setting | Default | Description |
|---|---|---|
| `PIHOLE_IP` | `192.168.1.2` | Pi-hole to check |
| `PRIMARY_DNS` | `192.168.1.2` | Router upstream(s) while the Pi-hole is healthy |
| `FALLBACK_DNS` | `1.1.1.1 9.9.9.9` | Router upstream(s) while the Pi-hole is down |
| `TEST_DOMAINS` | `cloudflare.com google.com` | Domains used for the health check |
| `QUERY_TIMEOUT` | `2` | Timeout per query in seconds |
| `FAIL_THRESHOLD` | `2` | Failed checks in a row before failing over |
| `RECOVER_THRESHOLD` | `3` | Successful checks in a row before switching back |
| `REQUIRE_WORKING_FALLBACK` | `1` | Only fail over if the fallback answers |
| `SAVE_CONFIG` | `0` | `1` = also `save` after a change, so it survives a reboot |

With `SAVE_CONFIG=0` changes are only committed. After a reboot the saved config
(Pi-hole) is active again and the script corrects itself within a few minutes. This
avoids unnecessary writes to flash.

## Testing failover

1. Stop the Pi-hole (e.g. shut down its VM or container).
2. Wait about 2 minutes, then on the router:

   ```sh
   show dns forwarding nameservers
   show log | match dns-failover
   ```

   You should see `1.1.1.1` / `9.9.9.9` and a log line
   `Pi-hole 192.168.1.2 is not answering (2 checks), dns forwarding -> 1.1.1.1 9.9.9.9`.
3. Start the Pi-hole again. After about 3 minutes the router forwards to the Pi-hole
   again.

## Troubleshooting

- **`status` shows `NO ANSWER` while the Pi-hole works**: run
  `host -W 2 -t A cloudflare.com <pihole-ip>` on the router. If that returns an
  address, run `sudo bash -x /config/scripts/dns-forward-failover.sh status` and check
  where the check fails.
- **Manual changes to `name-server` are reverted**: while the Pi-hole is healthy the
  script always restores `PRIMARY_DNS`. Disable the task first:
  `delete system task-scheduler task dns-failover`.
- **Commit errors after enabling the script**: the script re-executes itself with
  group `vyattacfg` so config file permissions stay correct. Make sure it is started
  via the task scheduler or with `sudo`.

## Uninstall

```sh
configure
delete system task-scheduler task dns-failover
commit ; save ; exit
sudo rm /config/scripts/dns-forward-failover.sh /config/scripts/dns-forward-failover.conf
```

## License

MIT, see [LICENSE](LICENSE).
