# v6watch

IPv6 prefix delegation watchdog for Asuswrt-Merlin: detects delegated prefixes
that silently stop being routed and recovers automatically.

## The problem

Many ISPs provide native IPv6 through DHCPv6 with Prefix Delegation (PD): the
router receives a prefix (for example a /56), uses one /64 of it on the LAN and
announces it to your devices.

Sometimes the ISP **stops routing the delegated prefix while the lease is still
valid**, without sending a DHCPv6 Reconfigure or a zero lifetime. Nothing on the
router notices:

- the router keeps announcing the prefix, so devices keep a "valid" IPv6
  address that no longer reaches the Internet;
- the router's own WAN address (IA_NA, from a different prefix) still works, so
  the router itself looks fine;
- connections that are already open often keep working, while new ones hang
  intermittently until the app restarts or the device reconnects;
- only a new DHCPv6 exchange (renew, or a WAN restart) brings it back. With a
  preferred lifetime of days, the next automatic renew can be days away.

DHCPv6 has no way for a client to verify that a delegated prefix actually
works. v6watch adds that check.

[docs/diagnosis.md](docs/diagnosis.md) explains how to tell whether you have
this problem, and [docs/isp-evidence.md](docs/isp-evidence.md) how to collect
captures to send to your ISP.

## How it works

Every 5 minutes (via `cru`), v6watch:

1. takes the first global, non-ULA IPv6 address of the LAN bridge (`br0`);
2. pings two public hosts **using that address as source**
   (`ping6 -I <address>`), so the test goes through the delegated prefix and
   not through the WAN address;
3. if neither host answers:
   - sends `SIGUSR1` to `odhcp6c`, which triggers a DHCPv6 renew that keeps the
     current prefix, and checks again after 30 seconds;
   - if the prefix is still not routed, runs `service restart_wan`, **at most
     once per hour**;
4. logs prefix changes, failures, recoveries and a daily "still working" entry.

When the prefix fails, v6watch also tests the router's WAN address, so the log
tells a dead delegated prefix apart from a general IPv6 outage.

Logs go to syslog (tag `v6watch`) and to a persistent file on `/jffs`. To spare
the flash, v6watch writes to `/jffs` only when something happens: during a long
outage only the first failure and the recovery are written there, the repeated
messages go to syslog only.

## Requirements

- Asuswrt-Merlin 384.15 or later (add-on support), with
  **Administration > System > Enable JFFS custom scripts and configs** enabled.
- Native IPv6 with DHCPv6 prefix delegation (the firmware's `odhcp6c` client).
- No Entware packages are needed.

Tested on an ASUS RT-BE88U with Asuswrt-Merlin 3006.102.9, FTTH over IPoE.
Reports from other models and connection types are welcome.

## Install

Over SSH on the router:

```sh
cd /tmp
curl -fsSL https://github.com/Syxhen/v6watch/archive/refs/heads/main.tar.gz | tar xz
sh v6watch-main/install.sh
rm -rf v6watch-main
```

The installer:

- checks the prerequisites;
- copies the files to `/jffs/addons/v6watch.d/`;
- creates `v6watch.conf` only if it does not exist yet;
- appends one line, ending in `# v6watch`, to `/jffs/scripts/services-start`
  (created if missing) so that the cron job is recreated at every boot. Lines of
  other add-ons are never changed;
- creates the cron job and runs a first check.

Running it again upgrades the script and changes nothing else.

## Usage

```sh
/jffs/addons/v6watch.d/v6watch.sh check    # test now, print the result, change nothing
/jffs/addons/v6watch.d/v6watch.sh run      # what cron runs: test and recover if needed
/jffs/addons/v6watch.d/v6watch.sh cron     # recreate the cron job (after changing the schedule)
/jffs/addons/v6watch.d/v6watch.sh uncron   # remove the cron job until the next reboot
/jffs/addons/v6watch.d/v6watch.sh version
```

Example output of `check`:

```
v6watch 0.1.0
LAN address: 2001:db8:0:2e00::1 (br0)
WAN address: 2001:db8:ffff:1::2 (wan0)
  2606:4700:4700::1111: reply
  2001:4860:4860::8888: reply
Delegated prefix is routed
```

## Logs

```sh
cat /jffs/addons/v6watch.d/v6watch.log     # persistent, last 1000 lines
grep v6watch /tmp/syslog.log               # syslog, including repeated messages
```

Example:

```
2026-10-20 09:15:02 Watching LAN prefix: 2001:db8:0:2e00::1 (router uptime 52h)
2026-10-21 12:00:04 Daily check: 2001:db8:0:2e00::1 routed (router uptime 78h)
2026-10-22 03:40:05 Prefix of 2001:db8:0:2e00::1 not routed (WAN address 2001:db8:ffff:1::2 works): trying a DHCPv6 renew
2026-10-22 03:40:41 Still not routed: restarting the WAN
2026-10-22 03:42:12 After the WAN restart: new prefix 2001:db8:0:2e00::1 -> 2001:db8:0:5a00::1, routed (outage lasted 2 min)
```

The router uptime shown next to prefix changes
(`LAN prefix changed: ... (router uptime 93h)`) helps to tell changes made by
the ISP apart from the ones caused by a reboot: it comes from `/proc/uptime`,
so a WAN restart does not reset it.

## Configuration

Edit `/jffs/addons/v6watch.d/v6watch.conf`. Every setting is commented out and
shows its default; uncomment a line to change it. Changes apply at the next
run, except `CRON_SCHEDULE`, which needs `v6watch.sh cron`.

| Setting | Default | Meaning |
|---|---|---|
| `LAN_IF` | `br0` | LAN interface that carries the delegated prefix |
| `TARGETS` | Cloudflare and Google DNS | hosts pinged from the delegated prefix |
| `PING_COUNT` / `PING_TIMEOUT` | `2` / `3` | pings per target, seconds to wait |
| `RENEW_WAIT` | `30` | seconds between the renew and the new check |
| `RESTART_WAIT` | `90` | seconds between the WAN restart and the new check |
| `RESTART_MIN_INTERVAL` | `3600` | minimum seconds between two WAN restarts |
| `DAILY_CHECK` | `1200` | time (HHMM) of the daily log entry, empty to disable |
| `CRON_SCHEDULE` | `*/5 * * * *` | how often v6watch runs |
| `LOG_FILE` / `LOG_LINES` | `.../v6watch.log` / `1000` | persistent log and its size |
| `STATE_FILE` | `.../v6watch.prefix` | last seen LAN address |

## How fast do devices drop a dead prefix?

When the WAN restart brings a new prefix, devices also need to stop using the
old one. That depends on the lifetimes the router announces in its Router
Advertisements, not on v6watch. Check them with:

```sh
grep -nE 'dhcp-range|ra-param' /etc/dnsmasq.conf
```

A line like `ra-param=br0,10,600` means an RA every 10 seconds and a prefix
valid for 10 minutes: devices abandon the old prefix within 10 minutes.

## A new prefix after every WAN restart?

Some ISPs hand out a different delegated prefix at every DHCPv6 Solicit, even
when the router keeps the same DUID and IAID and sends no Release. That is the
ISP's behaviour, not v6watch's: v6watch only triggers the restart. If your
contract promises a static prefix, `LAN prefix changed` entries with a high
router uptime in the log, together with the captures described in
[docs/isp-evidence.md](docs/isp-evidence.md), are what to send to your ISP.

## Uninstall

```sh
sh /jffs/addons/v6watch.d/uninstall.sh             # remove everything
sh /jffs/addons/v6watch.d/uninstall.sh --keep-log  # keep the log in /jffs/addons/v6watch.d
```

Only the v6watch line is removed from `/jffs/scripts/services-start`.

## Limitations

- A WAN restart also drops IPv4 for about a minute.
- During a general IPv6 outage (the WAN address fails too) v6watch still
  restarts the WAN, at most once per `RESTART_MIN_INTERVAL`.
- Only the main LAN is checked; guest networks on other /64s of the same
  delegated prefix are not.
- v6watch is meant for single-WAN setups, and the installer warns when Dual
  WAN is enabled. With Dual WAN, for example with the WAN Failover add-on,
  the two get in each other's way: a v6watch WAN restart looks like a failure
  of the primary WAN and triggers a failover, and while traffic leaves through
  the secondary WAN the primary ISP's delegated prefix is not routed, so
  v6watch would report it as dead and restart the WAN.
- PPPoE has not been tested.

## Roadmap

- Notifications (for example Telegram) when a prefix stops working.
- Guest network support.
- OpenWrt port (it uses the same `odhcp6c`).
- amtm integration.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
