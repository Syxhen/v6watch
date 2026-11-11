# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- The installer warns when Dual WAN is enabled; the README explains why
  v6watch and Dual WAN (e.g. the WAN Failover add-on) get in each other's way.
- Every release comes with a `v6watch.tar.gz` archive, built and attached by
  GitHub Actions when a version tag is pushed.
- `RESTART_MAX_INTERVAL` (default one day): while WAN restarts do not bring
  the prefix back, the wait between them doubles after each one up to this
  value, instead of restarting every hour for the whole outage.
- `RESTART_ON_WAN_FAIL`: set it to `0` to skip the WAN restart when the WAN
  address fails too. The default keeps restarting.
- A LAN left with no usable global address while `odhcp6c` is running is now
  logged and recovered like a prefix that is not routed; before, v6watch did
  nothing.

### Changed
- The WAN is restarted after `FAIL_THRESHOLD` consecutive failed checks
  (default 2) instead of at the first one, so a short IPv6 glitch no longer
  drops IPv4 too. The DHCPv6 renew is still tried at the first failure.
  `FAIL_THRESHOLD=1` gives the previous behaviour.
- The README installs the latest release instead of the `main` branch, so
  unreleased changes no longer reach users.

## [0.1.0] - 2026-10-28

First public version.

### Added
- `v6watch.sh`, run every 5 minutes by `cru`: checks that the delegated prefix
  on the LAN is routed with `ping6 -I`, asks `odhcp6c` for a DHCPv6 renew when
  it is not and, if that does not help, restarts the WAN at most once per hour.
- When the delegated prefix fails, the router's WAN address is tested too, to
  tell a dead prefix apart from a general IPv6 outage.
- Persistent log of prefix changes (with the router uptime), failures,
  recoveries with the outage duration, and a daily check. During an outage only
  the first failure and the recovery are written to `/jffs`.
- Commands: `run`, `check`, `cron`, `uncron`, `version`.
- Configuration file `v6watch.conf` for the LAN interface, ping targets,
  timings, restart rate limit, daily check, cron schedule and paths.
- Merlin add-on layout in `/jffs/addons/v6watch.d/`.
- `install.sh` and `uninstall.sh`: prerequisite checks, idempotent install,
  only their own line in `/jffs/scripts/services-start`.
- Documentation: README, diagnosis guide, guide to collecting evidence for the
  ISP.
- ShellCheck on every push (GitHub Actions).

[Unreleased]: https://github.com/Syxhen/v6watch/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Syxhen/v6watch/releases/tag/v0.1.0
