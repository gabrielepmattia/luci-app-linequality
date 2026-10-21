# luci-app-linequality — design

A WAN line-quality monitor for OpenWrt (24.10+) and TurrisOS 9: traffic totals,
average/peak throughput, packet loss, latency and jitter, a log of outages with
their duration, uptime %, and optional speed tests (manual or scheduled).
Everything runs on the router, with no cloud and no external chart libraries.

The repository is a small package feed with two packages:

| Package | Contents |
|---|---|
| `linequality` | collector daemon (ucode), procd init script, UCI config, ubus API |
| `luci-app-linequality` | LuCI JS views (overview + settings), menu, rpcd ACL, translations |

```
linequality/
  Makefile
  files/
    linequality.config        -> /etc/config/linequality
    linequality.init          -> /etc/init.d/linequality
    linequality.keep          -> /lib/upgrade/keep.d/linequality
    linequalityd.uc           -> /usr/share/linequality/linequalityd.uc
luci-app-linequality/
  Makefile                    (include $(TOPDIR)/feeds/luci/luci.mk)
  htdocs/luci-static/resources/view/linequality/overview.js
  htdocs/luci-static/resources/view/linequality/settings.js
  root/usr/share/luci/menu.d/luci-app-linequality.json
  root/usr/share/rpcd/acl.d/luci-app-linequality.json
  po/templates/linequality.pot
  po/it/linequality.po
scripts/dev-install.sh        copy files to a router over ssh, without packaging
.github/workflows/build.yml   build ipk/apk with openwrt/gh-action-sdk
```

## Runtime facts (verified on TurrisOS 9.1.3, ucode 2025.07.18)

- Modules: `fs`, `uloop` (`init run end timer interval process handle signal task`),
  `ubus` (`connect`, conn `publish call listener`), `uci` (`cursor`), `math`.
- `json(str)` parses, `sprintf('%J', v)` serializes. `time()` = epoch seconds,
  `clock(true)` = monotonic `[sec, nsec]`, `localtime(t)` honours the router timezone.
- There is no `getpid()`.
- A process cannot synchronously `call` an ubus object it publishes itself (it deadlocks).
- `uloop.process(exe, args, env, cb)` gives only the exit code, so redirect output to a
  file with `/bin/sh -c '... >file 2>&1'` and read the file in `cb`.
- `network.interface.<iface> status` gives `up`, `uptime`, `l3_device` (e.g. `pppoe-wan`),
  `device` (e.g. `eth4.835`), `ipv4-address[0].address`, `ipv4-address[0].ptpaddress`
  (the PPPoE peer) and `route[]` (`target 0.0.0.0` + `nexthop`).
- fping 5.3: `fping -C 10 -p 1000 -t 800 -q host...` prints one line per host **on stderr**,
  `host : 2.68 2.54 - 2.72 ...` (`-` = lost), exit code 1 if anything was lost. It handles IPv6.
- librespeed-cli 1.0.13: `--json --duration N --concurrent N [--server ID]`;
  speeds in Mbit/s. The JSON may be an array of one object; accept both forms.

## Daemon: `linequalityd.uc`

Run by procd as `/usr/bin/ucode /usr/share/linequality/linequalityd.uc`.
Dev flags (parsed from `ARGV`): `--data-dir DIR`, `--ubus-name NAME`
(default `linequality`), `--speedtest-cmd PATH` (fake speed test for testing),
`--debug`. The flags override UCI.

### UCI (`/etc/config/linequality`)

```
config linequality 'main'
	option enabled '1'
	option interface 'wan'
	list target 'gateway'
	list target '1.1.1.1'
	list target '8.8.8.8'
	option down_after '3'
	option data_dir '/etc/linequality'
	option hourly_retention_days '90'
	option daily_retention_days '1095'
	option speedtest_schedule ''
	option speedtest_duration '10'
	option speedtest_concurrent '3'
	option speedtest_server ''
```

- Targets must be IP addresses (a host name would vanish from fping's output while DNS is
  down); anything else is ignored with a log line.
- `target 'gateway'` resolves on every probe batch to the PPPoE `ptpaddress`, or else to the
  default-route `nexthop`. Its label stays `gateway`. Every other target uses its own string as label.
- "Reference targets" are all targets except `gateway`. If only `gateway` is configured, it is the reference.
- `speedtest_schedule`: space-separated local `HH:MM` times; empty means no scheduled test.

### Sampling

1. **Traffic, every 1 s** (`uloop.interval(1000)`): read `rx_bytes tx_bytes rx_errors
   tx_errors rx_dropped tx_dropped` from `/sys/class/net/<l3_device>/statistics/`. Use
   deltas, and compute the elapsed time from the monotonic clock. If the device changed or a
   counter went backwards, that tick contributes a delta of 0. Per-second rate in bit/s is
   `delta*8/elapsed`. Keep the last value for `live`.
2. **Interface state, every 5 s**: call `network.interface.<iface> status`. Also read
   `/sys/class/net/<device>/carrier`.
   - `up` true→false opens a `wan_down` event; false→true closes it.
   - If `uptime` went down while both polls were up, there was a fast reconnect that the
     polls missed: add a closed `wan_down` event with `start` = previous poll and `end` = `now - uptime`.
   - If the IPv4 address changed, record `{old_ip, new_ip}` in the `detail` of the
     `wan_down` event that is closing (if any) and log it.
   - carrier 1→0 opens `link_down`; 0→1 closes it.
3. **Probes, continuously**: run one fping batch (`-C 10 -p 1000 -t 800 -q`) over the
   resolved targets. Start the next batch as soon as the previous one exits, so there are no
   gaps. Remember the batch's wall-clock start. Probe `i` belongs to second `start+i`. For
   each target and probe:
   - `sent++`; if there was a reply, `recv++`, plus rtt sum/min/max.
   - Jitter: `|rtt - prev_rtt|` for that target, accumulated as `jit_sum`/`jit_n`.
   - Internet down: the probe is "all lost" when every reference target lost it. Keep a
     consecutive counter that carries across batches. When it reaches `down_after`, open an
     `internet_down` event with `start` = time of the first lost probe. The first probe that
     comes back closes it, and its time is `end`. `detail`: `{gateway_ok: bool}` (did the
     gateway reply during the outage), `wan_up: bool`.
   - Count the seconds inside an `internet_down` event into the minute bucket's `down_s`.
     Count `wan_down` seconds into `wan_down_s`.

Do not record anything while `time() < 1700000000` (clock not synced yet).

### Buckets

A minute bucket is keyed by `floor(t/60)*60`:

```
{ t, rx, tx,                 // bytes
  rx_peak, tx_peak,          // bit/s, max of the 1-s rates
  err, drop,                 // rx+tx errors, rx+tx dropped (deltas)
  down_s, wan_down_s,        // seconds of internet_down / wan_down
  mon_s,                     // seconds actually monitored (1-s ticks counted)
  st,                        // 1 if a speed test ran in this minute
  p: { "<label>": [sent, recv, rtt_sum, rtt_min, rtt_max, jit_sum, jit_n] } }
```

Probe results arrive about 10 s late, so minute buckets stay mutable. Keep 48 h of minute
buckets in RAM.

**Merge rule** (used for all roll-ups and for `series` down-sampling):
- sum `rx tx err drop down_s wan_down_s mon_s`, and every `p` field except min/max;
- max of `rx_peak tx_peak st`;
- min of `rtt_min` and max of `rtt_max` (ignore nulls).

A minute's hour is finalized when the hour is over and 120 s have passed. The hour row
(`t` = hour start) is appended to `hours-YYYY-MM.jsonl`. When the local day is over (plus
120 s), its hours are merged into a day row and appended to `days.jsonl`. The day row has
`t` = local midnight epoch and `d: "YYYY-MM-DD"`.

### Events

```
{ id, type: "internet_down"|"wan_down"|"link_down"|"monitor_gap",
  start, end /* null while open */, duration /* s, null while open */, detail: {} }
```

`id` = `"<type>-<start>"`. Append closed events to `events.jsonl`. Open events live in
memory and in `state.json`.

`monitor_gap`: at startup, take the newest of `state.json.saved_at` and the end of the last
persisted hour. If now minus that is more than 120 s, add a closed `monitor_gap` event
covering the gap, with `detail.clean` = whether `state.json` was written on a clean shutdown.

### Persistence (`data_dir`, created if missing; flash-friendly)

- `hours-YYYY-MM.jsonl`, `days.jsonl`, `events.jsonl`, `speedtests.jsonl`: append-only,
  one JSON object per line.
- `state.json`: written atomically (tmp file + `fs.rename`) **only** on SIGTERM/SIGINT
  (`uloop.signal`), followed by `uloop.end()`. It holds `saved_at`, the minute buckets, the
  partial hour/day, open events, and `last_speedtest_slot`. It must finish well within
  procd's 5 s `term_timeout`. On startup, load it if present and newer than 48 h.
- Retention runs once a day: delete `hours-*.jsonl` older than `hourly_retention_days`, and
  rewrite `days.jsonl` / `events.jsonl` / `speedtests.jsonl` keeping the newest
  `daily_retention_days` days / 5000 events / 1000 tests.
- At startup, load the hour rows inside the retention window, all day rows, the newest 5000
  events and the newest 1000 speed tests.

### Speed test

- Available if `librespeed-cli` is in `PATH` (or `--speedtest-cmd` is given).
- Command: `librespeed-cli --json --duration D --concurrent C [--server S]`, with output to a
  temp file. Only one test runs at a time.
- While the test runs, mark minutes `st=1`. Compute `idle_rtt` = mean RTT of the reference
  targets in the 10 min before the test, and `loaded_rtt` = mean RTT during the test
  (bufferbloat).
- Result row: `{ t, dur, trigger: "manual"|"schedule", ok, error, server, ping, jitter,
  down, up /* Mbit/s */, bytes_rx, bytes_tx, idle_rtt, loaded_rtt }`. Append it to
  `speedtests.jsonl`.
- Schedule: once a minute, compare local `HH:MM` with `speedtest_schedule`, and do not run
  twice in the same slot (`last_speedtest_slot`).

### ubus API (object `linequality`)

All times are epoch seconds and all rates bit/s; volumes are bytes.

`status {}` →
```
{ version, now, started, tz_offset /* s east of UTC */,
  interface: { name, up, uptime, l3_device, device, carrier, ipv4, gateway },
  live: { rx_bps, tx_bps,
          targets: [ { label, host, last_rtt, loss_pct, rtt_avg, jitter } ] },   // last 5 min
  open_events: [ event... ],
  summary: { today: S, month: S, "24h": S, "7d": S, "30d": S },
  speedtest: { available, running, started_at, schedule /* raw UCI string */, duration, concurrent, last: result|null } }
S = { rx, tx, rx_avg_bps, tx_avg_bps, rx_peak_bps, tx_peak_bps,
      mon_s, down_s, wan_down_s, uptime_pct /* 100*(1-down_s/mon_s), null if mon_s=0 */,
      disconnects /* internet_down + wan_down events starting in window */,
      loss_pct, rtt_avg, jitter_avg /* reference targets */ }
```
`today` and `month` are local calendar periods up to now. The others are rolling windows.

`series { range: "1h"|"24h"|"7d"|"30d"|"1y" }` →
`{ range, step, rows: [bucket...] }`, sorted by `t`. Steps: 1h → 60 (minutes),
24h → 300 (5 min, merged), 7d → 3600, 30d → 3600, 1y → 86400 (day rows). The current
partial hour/day is included, built from the minutes.

`events { limit = 200, since = 0 }` → `{ events: [...] }`, newest first, open events included.

`speedtests { limit = 50 }` → `{ results: [...] }`, newest first.

`speedtest_run {}` → `{ started: true }` or `{ error: "running"|"not_available" }`.

### procd init

`START=95 STOP=10 USE_PROCD=1`. Skip if `enabled=0`. `respawn 3600 5 5`,
`stdout 1 stderr 1`, `procd_add_reload_trigger linequality`. A reload restarts the service,
which is fine because state is saved on SIGTERM.

## LuCI app

Menu: **Status → Line quality** (`admin/status/linequality`), with the tabs **Overview**
(`linequality/overview`) and **Settings** (`linequality/settings`). The ACL gives read access
to `status series events speedtests` and uci `linequality`, and write access to
`speedtest_run` and uci `linequality`.

Overview (polls `status` every 5 s and `series` every 60 s and on range change):
- Cards:
  - line state (online / degraded / offline, session uptime, public IP);
  - uptime % and downtime, 24h / 7d / 30d, with the number of disconnects;
  - traffic today / this month ↓↑;
  - average and peak speed (24 h) plus live ↓↑;
  - latency / loss / jitter per target (5 min);
  - last speed test (↓ ↑ ping, bufferbloat Δ = loaded−idle RTT) with a **Run speed test** button.
- Range selector: 1h · 24h · 7d · 30d · 1y.
- Chart: latency, one line per target (avg RTT per bucket), with loss shown as bars along the
  bottom and outage periods (`down_s>0`) shaded.
- Chart: throughput ↓/↑ in Mbit/s, average per bucket = bytes*8/step, with peak as a faint line.
  Speed-test buckets are marked.
- Table: outages and disconnections (type, start, end, duration, detail).
- Table: speed-test history.
- Table: daily summary for the last 30 days (date, ↓, ↑, avg/peak, uptime %, loss %, RTT).

Charts are hand-written inline SVG (no external libraries). They are responsive (`viewBox`,
width 100%), have a hover read-out, and are legible on light and dark LuCI themes (axes in
`currentColor`).

Settings: a `form.Map('linequality')` with every UCI option. `interface` uses
`widgets.NetworkSelect`, `target` is a DynamicList, and the schedule and duration are validated.

All strings go through `_()` in English. The Italian translation is in `po/it/linequality.po`.
