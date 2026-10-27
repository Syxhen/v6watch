# Collecting evidence for your ISP

v6watch works around the problem, but only the ISP can fix it. A support ticket
gets much further with captures that show what happens. This page explains what
to collect and how.

All commands run over SSH on the router and need `tcpdump` from Entware
(`opkg install tcpdump`). `/tmp` is in RAM: for long captures write to a USB
drive instead.

## What to show

1. **The delegated prefix is not routed while its lease is valid.** Echo
   requests leave with a source in the delegated prefix and get no reply, while
   the same ping from the WAN address works.
2. **No signal was sent.** There is no DHCPv6 Reconfigure and no Reply with a
   zero lifetime for the prefix before it stops working.
3. **Only a new DHCPv6 exchange fixes it**, and the full exchange (Solicit,
   Advertise, Request, Reply) shows the prefix and the lifetimes offered.
4. If it applies: **the ISP assigns a different prefix at every Solicit**,
   although the DUID and IAID stay the same and no Release was sent.

## 1. Ping from the two sources

While the problem is happening:

```sh
ping6 -c 5 2606:4700:4700::1111
ping6 -c 5 -I 2001:db8:0:2e00::1 2606:4700:4700::1111
```

In a second SSH session, capture the same traffic on the WAN:

```sh
tcpdump -U -ni wan0 -w /tmp/ping.pcap icmp6 and host 2606:4700:4700::1111
```

Write down the date and time, with the time zone: the ISP will look for them in
its own logs.

## 2. The DHCPv6 exchange during a WAN restart

```sh
tcpdump -U -nvi any -w /tmp/dhcpv6.pcap 'udp port 546 or udp port 547'
```

Leave it running, then from another session:

```sh
service restart_wan
```

Stop the capture once IPv6 is back. `-i any` is needed because the restart
destroys and recreates `wan0`. To read it on the router:

```sh
tcpdump -nvr /tmp/dhcpv6.pcap
```

Look at the IA_PD option in the Advertise and Reply messages: the prefix, its
preferred lifetime (pltime), valid lifetime (vltime), T1 and T2. Repeat the
restart a couple of times to see whether the prefix changes at every Solicit.

## 3. The long view

`/jffs/addons/v6watch.d/v6watch.log` records every prefix change with the router
uptime, every failure and the daily check. A few weeks of log show how often
the prefix stops working and whether changes happen without a reboot.

## Copying the files to a PC

```sh
scp admin@192.0.2.1:/tmp/dhcpv6.pcap .
```

Use your router's address and admin user name; SSH must be enabled in
**Administration > System**. Open the files with Wireshark.

## Before you share anything

The captures and the log contain data that identifies you: your prefixes and
WAN address, the DUID (which usually contains the router's MAC address), the
IAID. That is fine for your ISP, which needs them to find your line.

**Do not post them publicly as they are**, for example in a GitHub issue or a
forum. Replace the real values with documentation ones: prefixes from
`2001:db8::/32` (RFC 3849), IPv4 addresses from `192.0.2.0/24`,
`198.51.100.0/24` or `203.0.113.0/24` (RFC 5737), MAC addresses like
`02:00:00:00:00:01`. For a pcap, `tcpdump -nvr file.pcap` output edited by hand is
easier to anonymize than the binary file.

## Writing the ticket

A short, factual message works best. Something like:

> Native IPv6 with DHCPv6-PD. On <date and time> the delegated prefix
> <prefix>/56 stopped being routed while its lease was valid (pltime <x>,
> vltime <y>): echo requests from the prefix leave my router with no reply,
> while my WAN address <address> works. No Reconfigure was received. A new
> DHCPv6 exchange restores the service, with a different prefix each time.
> Captures attached.
