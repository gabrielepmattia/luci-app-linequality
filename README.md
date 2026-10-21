# luci-app-linequality

WAN line-quality monitor for OpenWrt and TurrisOS, with a LuCI dashboard.

It answers the questions you ask when the internet "feels slow": how much
traffic went through, how fast it was, whether packets are being lost, how
often the line dropped and for how long.

- **Traffic**: totals for today, this month and any range, average and peak
  throughput (1-second resolution).
- **Latency, jitter and packet loss** towards your provider's gateway and any
  IP addresses you choose, probed once per second with `fping`. Besides the
  average you get the 95th percentile and a heatmap of the latency distribution.
- **Outage log**: internet unreachable, PPPoE/WAN session down (including fast
  reconnects), physical link down, periods of heavy packet loss, and the time
  the monitor itself was not running. Each entry has a start, an end and a
  duration. PPPoE drops carry their cause (provider hang-up, LCP echo timeout,
  authentication failure, …) and the relevant pppd log lines. When the internet
  becomes unreachable or packet loss starts, a traceroute is taken so you can
  see where the path broke.
- **Public IP history**: IPv4 address and delegated IPv6 prefix changes.
- **Uptime %** and total downtime over 24 h, 7 d and 30 d.
- **Line errors**: interface errors, drops and CRC errors of the physical port.
- **Router CPU** (average and busiest core), so you can tell a slow line from
  a router that cannot keep up.
- **DNS response time** of the router's resolver (or any server you choose).
- **Speed tests** with `librespeed-cli`, on demand or on a schedule, with a
  configurable duration and number of parallel connections. Latency is measured
  during the test as well, so you also get a bufferbloat figure (loaded − idle
  RTT), plus the router CPU load during the test. Enter your contracted speed
  and each result is shown as a percentage of it.
- **Monthly report** for the last 12 months, with a printable statement per
  month (availability, outages, latency, speed tests against the contracted
  speed) to back a complaint to your provider.
- **Notifications** via [ntfy](https://ntfy.sh) or a JSON webhook when the
  connection comes back after an outage, and optionally on packet loss, slow
  speed tests and monitoring gaps. Messages in English or Italian.
- **History**: minute resolution for 48 h, hourly for 90 days, daily for 3 years
  (all configurable).

Everything runs on the router. There is no cloud service and the page does not
load external scripts.

## Requirements

- OpenWrt 24.10 or newer, or TurrisOS 9.
- `ucode` with the `fs`, `ubus`, `uloop` and `uci` modules, and `fping`. They are
  pulled in as package dependencies.
- Optional: `librespeed-cli` for speed tests, `curl` for notifications.

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
| `plan_down`, `plan_up` | *(empty)* | Contracted speed in Mbit/s, used for the % of plan and the report |
| `loss_threshold` | `5` | Packet loss % over 60 s that records a degraded-line event |
| `interface6` | `<interface>6` | Interface holding the delegated IPv6 prefix |
| `dns_enabled` | `1` | Measure DNS response time |
| `dns_server` | `127.0.0.1` | Resolver to measure |
| `dns_name` | `openwrt.org`, `wikipedia.org`, `example.com` | Names looked up in turn |
| `dns_interval` | `30` | Seconds between lookups |
| `notify_url` | *(empty)* | ntfy topic URL or webhook URL; empty disables notifications |
| `notify_type` | `ntfy` | `ntfy` or `webhook` |
| `notify_token` | *(empty)* | Bearer token sent in the `Authorization` header |
| `notify_language` | `en` | `en` or `it` |
| `notify_min_outage` | `60` | Seconds; shorter outages are not notified |
| `notify_loss` | `0` | Also notify packet-loss events |
| `notify_speed_pct` | `0` | Notify speed tests below this % of the plan (0: off) |
| `notify_gap` | `1` | Notify when the router or the service was down |

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
`speedtests`, `speedtest_run`, `report`, `notify_test`). For example:

```sh
ubus call linequality status
ubus call linequality series '{"range":"24h"}'
ubus call linequality report '{"months":3}'
```

The response formats are documented in [DESIGN.md](DESIGN.md).

## Development

```sh
# copy this checkout to a router over ssh, without building packages
# (the host defaults to $LINEQUALITY_HOST, then root@192.168.1.1)
./install.sh root@192.168.1.1
./install.sh root@192.168.1.1 --uninstall

# pure-function self test, runs anywhere ucode is installed
ucode linequality/files/linequalityd.uc --selftest
```

The collector also takes `--data-dir`, `--ubus-name`, `--target`,
`--speedtest-cmd` and `--notify-cmd`. With them you can run a second, throw-away
instance next to the real one.

Translations live in `luci-app-linequality/po/`. Italian is included.
`install.sh` compiles them with LuCI's `po2lmo` when it is installed, otherwise
with `scripts/po2lmo.py`, a Python port that writes identical files.

## License

[Apache-2.0](LICENSE)
