# luci-app-linequality

WAN line-quality monitor for OpenWrt and TurrisOS, with a LuCI dashboard.

It answers the questions you ask when the internet "feels slow": how much
traffic went through, how fast it was, whether packets are being lost, how
often the line dropped and for how long.

- **Traffic**: totals for today, this month and any range, average and peak
  throughput (1-second resolution).
- **Latency, jitter and packet loss** towards your provider's gateway and any
  IP addresses you choose, probed once per second with `fping`.
- **Outage log**: internet unreachable, PPPoE/WAN session down (including fast
  reconnects and public-IP changes), physical link down, and the time the
  monitor itself was not running. Each entry has a start, an end and a duration.
- **Uptime %** and total downtime over 24 h, 7 d and 30 d.
- **Speed tests** with `librespeed-cli`, on demand or on a schedule, with a
  configurable duration and number of parallel connections. Latency is measured
  during the test as well, so you also get a bufferbloat figure (loaded − idle RTT).
- **History**: minute resolution for 48 h, hourly for 90 days, daily for 3 years
  (all configurable).

Everything runs on the router. There is no cloud service and the page does not
load external scripts.

## Requirements

- OpenWrt 24.10 or newer, or TurrisOS 9.
- `ucode` with the `fs`, `ubus`, `uloop` and `uci` modules, and `fping`. They are
  pulled in as package dependencies.
- Optional: `librespeed-cli` for speed tests.

## Install

Packages are attached to each [release](https://github.com/gabrielepmattia/luci-app-linequality/releases):
`.ipk` for OpenWrt 24.10 and TurrisOS, `.apk` for OpenWrt 25.12 and newer.
Both packages are architecture-independent.

```sh
# OpenWrt 24.10 / TurrisOS
opkg update
opkg install ./linequality_*.ipk ./luci-app-linequality_*.ipk
# OpenWrt 25.12+
apk add --allow-untrusted ./linequality-*.apk ./luci-app-linequality-*.apk
```

Then open **Status → Line quality** in LuCI.

### Build from source

Add this repository as a feed in an OpenWrt SDK or buildroot:

```
src-git linequality https://github.com/gabrielepmattia/luci-app-linequality.git
```

```sh
./scripts/feeds update linequality && ./scripts/feeds install -a -p linequality
make package/linequality/compile package/luci-app-linequality/compile
```

## Configuration

Use the **Settings** tab, or `/etc/config/linequality`:

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `1` | Run the collector |
| `interface` | `wan` | Logical interface to monitor |
| `target` | `gateway`, `1.1.1.1`, `8.8.8.8` | IP addresses to probe; `gateway` resolves to the provider-side address |
| `down_after` | `3` | Seconds with every probe lost before an outage is recorded |
| `data_dir` | `/etc/linequality` | Where history is stored (kept across sysupgrade) |
| `hourly_retention_days` | `90` | How long hourly rows are kept |
| `daily_retention_days` | `1095` | How long daily rows are kept |
| `speedtest_schedule` | *(empty)* | Space-separated local times, e.g. `04:30` |
| `speedtest_duration` | `10` | Seconds per direction |
| `speedtest_concurrent` | `3` | Parallel connections |
| `speedtest_server` | *(auto)* | LibreSpeed server id (`librespeed-cli --list`) |

An outage is recorded when every target other than the gateway stops
answering. The outage record also notes whether the gateway was still
reachable, so you can tell whether the line or something further upstream failed.

Target lists only accept IP addresses. A host name would stop resolving
during an outage, which is exactly when the outage needs to be seen.

### A note on speed tests

A speed test saturates the line, and on a multi-gigabit connection a single run
can transfer several gigabytes. Keep the duration short and the schedule sparse
if your plan has a data cap.

## Flash wear

Samples are kept in RAM. On flash, the collector only appends one line per
finished hour, per finished day, per event and per speed test. The 48-hour
minute history is written once, on a clean shutdown or service restart. If power
is cut, at most the current hour is lost, and the gap appears in the outage log.

## ubus API

The collector publishes the `linequality` object (`status`, `series`, `events`,
`speedtests`, `speedtest_run`). For example:

```sh
ubus call linequality status
ubus call linequality series '{"range":"24h"}'
```

The response formats are documented in [DESIGN.md](DESIGN.md).

## Development

```sh
# copy the files to a router over ssh, without building packages
# (set PO2LMO=/path/to/po2lmo to install translations too)
scripts/dev-install.sh root@192.168.1.1
scripts/dev-install.sh root@192.168.1.1 --uninstall

# pure-function self test, runs anywhere ucode is installed
ucode linequality/files/linequalityd.uc --selftest
```

The collector also takes `--data-dir`, `--ubus-name`, `--target` and
`--speedtest-cmd`. With them you can run a second, throw-away instance next to
the real one.

Translations live in `luci-app-linequality/po/`. Italian is included.

## License

[Apache-2.0](LICENSE)
