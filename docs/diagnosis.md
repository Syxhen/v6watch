# Do I have this problem?

The typical symptom: IPv6 works most of the time, but now and then new
connections from LAN devices hang (apps that never load, backups that stall),
while connections already open keep working. Reconnecting Wi-Fi or Ethernet, or
restarting the app, often "fixes" it for a while, because the device falls back
to IPv4 or picks another address.

The commands below run over SSH on the router. They use the documentation
prefix `2001:db8::/32`: replace the addresses with yours. Run them **while the
problem is happening**; once the WAN has been restarted everything looks fine.

## 1. Which prefix is on the LAN, which address is on the WAN

```sh
ip -6 addr show br0 | grep global
ip -6 addr show wan0 | grep global
ip -6 route | grep default
```

Example:

```
inet6 2001:db8:0:2e00::1/64 scope global dynamic          <- br0: delegated prefix
inet6 fd12:3456:789a::1/64 scope global                   <- br0: ULA, ignore it
inet6 2001:db8:ffff:1::2/128 scope global dynamic         <- wan0: WAN address (IA_NA)
default via fe80::1 dev wan0 proto ra metric 1024 ...
```

Linux reports ULA addresses (`fc00::/7`, usually `fd..`) as `scope global` too:
they are not routed on the Internet, skip them. On some models the WAN
interface is not called `wan0`: the `dev` of the default route tells you its
name.

## 2. Does the router reach the Internet, and from the delegated prefix?

```sh
ping6 -c 3 2606:4700:4700::1111
ping6 -c 3 -I 2001:db8:0:2e00::1 2606:4700:4700::1111
```

The first ping uses the WAN address as source, the second forces a source in
the delegated prefix. **If the first one works and the second one does not, the
ISP is not routing your delegated prefix.** This is exactly the test v6watch
runs.

## 3. Do the replies come back?

Start a ping from a LAN PC (`ping -6 2606:4700:4700::1111`) and, on the router:

```sh
tcpdump -ni wan0 icmp6 and host 2606:4700:4700::1111
```

`tcpdump` comes from Entware (`opkg install tcpdump`). With the problem you see
echo requests leaving with a source in the delegated prefix and no echo reply
at all: the packets leave the router correctly, the return path is missing
upstream.

## 4. Is the router's firewall dropping anything?

```sh
ip6tables -Z FORWARD
ip6tables -L FORWARD -v -n
```

Reset the counters, repeat the ping from the LAN and list them again. If the
ACCEPT rules for outgoing traffic grow and no DROP rule does, the router is
forwarding the traffic and the problem is not local.

## 5. DHCPv6 client and LAN announcements

```sh
ps w | grep [o]dhcp6c
nvram get ipv6_dhcp6c_release
grep -nE 'dhcp-range|ra-param|enable-ra' /etc/dnsmasq.conf
```

- `odhcp6c ... -P 56:...` shows the requested prefix length.
- `-k`, or `ipv6_dhcp6c_release` set to `0`, means no Release is sent when the
  client stops: the ISP is not told to drop the prefix on a WAN restart.
- `ra-param=br0,10,600` means an RA every 10 seconds with a prefix valid for
  600 seconds, so devices drop a replaced prefix within 10 minutes.

## 6. On the devices

On Windows, see the addresses and their remaining lifetimes:

```
netsh interface ipv6 show addresses
```

On Linux: `ip -6 addr show`; on macOS: `ifconfig`. A device with an address
from the delegated prefix that has a long valid lifetime, while step 2 fails,
is a device stuck on an orphaned prefix.

## 7. Confirm with a WAN restart

```sh
service restart_wan
```

If the delegated prefix works again right after the restart (step 2), and
maybe it is a different one, you have the problem v6watch is made for.
Note that `service restart_wan` destroys and recreates the WAN interface: a
`tcpdump` running on `wan0` stops, use `-i any` for captures that span a
restart.

Next: [collect evidence for your ISP](isp-evidence.md).
