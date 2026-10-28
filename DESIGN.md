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
install.sh                    copy this checkout to a router over ssh, without packaging
scripts/po2lmo.py             .po -> .lmo (Python port of LuCI's po2lmo)
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

## Additions in 0.2

Everything above still holds. This section adds fields and features. Field names here are
part of the API.

### More runtime facts (TurrisOS 9.1.3)

- busybox `traceroute -n -q 1 -w 1 -m 12 <ip>` (and `traceroute6`) prints hop lines like
  ` 1  217.61.32.1  2.794 ms` or ` 3  *`.
- busybox `nslookup <name> <server>` exits 0 on success and 1 on NXDOMAIN/failure. It queries
  both A and AAAA.
- `logread -l N` works. Do **not** rely on `-e` (on Turris it ignores the filter) or on log
  timestamps (they mix UTC and local time). Filter lines in ucode.
- pppd messages: `Modem hangup`, `LCP terminated by peer`, `No response to N echo-requests`,
  `Terminating on signal 15`, `CHAP authentication failed` / `PAP authentication failed`,
  `Timeout waiting for PADO packets` / `Unable to complete PPPoE Discovery`.
- `/proc/stat` lines `cpu` and `cpuN`: user nice system idle iowait irq softirq steal...
  Busy % = 100 * (1 - (Δidle + Δiowait) / Δtotal).
- A VLAN device has a `/sys/class/net/<dev>/lower_<phys>` link. CRC errors are counted on
  the physical device (`statistics/rx_crc_errors`).
- `network.interface.wan6 status` → `ipv6-prefix[0].address` + `mask` (delegated prefix).
- curl is installed on Turris. Vanilla OpenWrt has uclient-fetch by default.

### New UCI options (all optional)

```
	option interface6 ''            # default: <interface>6 if it exists
	option loss_threshold '5'       # % loss over 60 s on reference targets -> 'loss' event
	option dns_enabled '1'          # 0 disables DNS probing
	option dns_server '127.0.0.1'   # missing: 127.0.0.1; empty: probing disabled
	list dns_name 'openwrt.org'
	list dns_name 'wikipedia.org'
	list dns_name 'example.com'
	option dns_interval '30'        # seconds
	option plan_down ''             # contracted speed, Mbit/s
	option plan_up ''
	option notify_url ''            # empty disables notifications
	option notify_type 'ntfy'       # ntfy | webhook
	option notify_token ''          # optional, sent as "Authorization: Bearer <token>"
	option notify_language 'en'     # en | it
	option notify_min_outage '60'   # seconds
	option notify_loss '0'          # notify 'loss' events
	option notify_speed_pct '0'     # notify speed tests below this % of plan (0 = off)
	option notify_gap '1'           # notify monitor gaps (router or service down)
```

### New bucket fields (merged like the others)

```
crc:  int                          // Δ rx_crc_errors of the physical WAN device (sum)
cpu:  [busy_sum, n, busy_max, core_max]   // per-second total busy %, count, max; max per-core busy %
dns:  [sent, ok, t_sum_ms, t_max_ms]
h:    { "<label>": [c0..c17] }     // RTT histogram per target
```

- Histogram bin upper edges in ms are `[1, 2, 3, 4, 6, 8, 10, 15, 20, 30, 40, 60, 80, 100,
  150, 200, 400, ∞]`. Bin i counts replies with `rtt <= edge[i]` and `> edge[i-1]`.
- Merge rules:
  - sum: `crc`, `cpu[0..1]`, `dns[0..2]` and the histogram counts;
  - max: `cpu[2..3]` and `dns[3]`.
- Percentiles come from the histogram: find the bin where the cumulative count crosses the
  rank, then interpolate linearly inside it. The last bin uses 800 ms as its upper bound.
  Expose this as a helper used by `status`, `report` and the LuCI page (the page has its own
  JS copy).

### Sampling additions

- **CPU**: every 1-s tick, read `/proc/stat` and compute the total busy % and the max
  per-core busy % for that second. The bucket accumulates them, and `live.cpu` keeps the last
  second. During a speed test, also accumulate `cpu_avg`, `cpu_max` and `core_max` into the
  result row.
- **CRC**: in the same tick, read `rx_crc_errors` of the physical device. That is the target
  of the `lower_*` link of `device` if there is one, otherwise `device` itself. Use the same
  reset rules as the other counters.
- **DNS**: every `dns_interval` s, run `nslookup <name> <server>` round-robin over `dns_name`,
  without overlapping runs. Time it with the monotonic clock from spawn to exit. Kill it after
  5 s, which counts as a failure; exit 0 = ok. Account it in the bucket of the start second.
- **IPv6 prefix**: every 60 s, read the `interface6` status. On a prefix change, add an
  `ip_change` event.

### Event additions

- `ip_change` (closed, duration 0): `detail: { family: "ipv4"|"ipv6-prefix", old, new }`.
  Emit it whenever the value changes between polls and both values are non-null, including
  inside a `wan_down`. The `old_ip`/`new_ip` detail on `wan_down` stays.
- `wan_down.detail.cause`: one of `peer_hangup`, `peer_terminated`, `echo_timeout`,
  `local_restart`, `auth_failed`, `no_pado`, `other`. It is `null` when the protocol is not
  PPPoE or no pppd line was found.
  - Compute it when the event closes, and for the fast-reconnect case when it is recorded.
    Read `logread -l 400` synchronously with `fs.popen` (rare, so blocking is fine) and keep
    the lines containing `pppd[`.
  - The cause is the last line matching one of the patterns above.
  - `detail.log` holds the last ≤ 6 pppd lines, with any leading timestamp/host prefix up to
    `pppd[` removed, and each line truncated to 160 chars.
- `loss` (degraded line): after each probe batch, compute the loss % of the reference targets
  over the last 60 s.
  - Open the event when the loss is above `loss_threshold` and no `internet_down` is open.
  - Close it when the 60-s loss has been ≤ `loss_threshold` for 60 s (or when an
    `internet_down` opens, so the two never overlap).
  - `detail: { max_loss_pct, speedtest: bool }`, where `speedtest` says whether a test ran
    during the event.
- **Traceroute**: when an `internet_down` or `loss` event opens, start a traceroute to the
  first reference target. Use `traceroute6` for an IPv6 target, with
  `-n -q 1 -w 1 -m 12`, asynchronously with output to a file. At most one trace per 10 min.
  Parse the hops into `detail.trace = [{ hop, ip|null, rtt|null }]`. If the event closes while
  its trace is still running, delay appending it to `events.jsonl` until the trace ends
  (20 s at most).

### Speed-test additions

The result row gains `cpu_avg`, `cpu_max`, `core_max`, plus `down_pct` and `up_pct`
(100 * measured / plan, `null` without a plan).

### Notifications

- Use curl (`curl -fsS -m 15 ... --data-binary @file`). It is optional: without it, set
  `status.notify.available=false` and log it once.
- **ntfy**: POST the message text to `notify_url`, with the headers `Title`, `Priority`
  (`default`, or `high` for outages over 10 min) and `Tags` (`warning` / `white_check_mark` /
  `turtle` / `information_source`).
- **webhook**: POST JSON `{ event, title, message, data }` with
  `Content-Type: application/json`.
- Both send `Authorization: Bearer <token>` when a token is set.
- Triggers:
  1. **Recovery.** An `internet_down` closes with a duration ≥ `notify_min_outage`. Send
     "Connection restored after 11 min 32 s (17:02–17:14). Cause: line hang-up (PPPoE).
     Gateway reachable during the outage: no." Take the cause from an overlapping `wan_down`
     (any overlap ±60 s) and mention an overlapping `link_down`. The data is sent at recovery
     because during an outage there is no connectivity.
  2. **Monitor gap.** At startup, a `monitor_gap` was recorded and `notify_gap` is on.
  3. **Loss.** A `loss` event closes and `notify_loss` is on.
  4. **Slow speed test.** A speed test has `down_pct` or `up_pct` below `notify_speed_pct`.
     A scheduled test that fails is also sent.
- Text comes from a small `en`/`it` dictionary chosen by `notify_language`, with local times
  as HH:MM.
- **Queue:** at most 50 entries, saved in `state.json`. Send one at a time and retry the head
  every 60 s on failure. Drop entries older than 24 h. `status.notify = { enabled, available,
  queued, last_sent, last_error }`.
- New ubus method `notify_test {}` → queues a test message → `{ queued: true }` or
  `{ error: "disabled"|"not_available" }`.

### API additions

- **`status`:**
  - `live.cpu = { busy, core_max }`
  - `live.dns = { server, last_ms, ok_last, rtt_avg, fail_pct }` (5 min)
  - `live.targets[].p95` (5 min)
  - `interface.ipv6_prefix`
  - `interface.last_cause`: cause of the most recent `wan_down`
  - `plan = { down, up }` (`null` when unset)
  - the `notify` object above
  - S gains `crc, err, drop, cpu_avg, cpu_max, core_max, dns_avg_ms, dns_fail_pct, rtt_p95`.
- **`series`:** rows carry the new bucket fields.
- **`report { months = 12 }`** → `{ plan, months: [ M... ] }`, newest month first, the current
  month included. Each M:
  ```
  { month: "YYYY-MM", mon_s, down_s, uptime_pct, outages /* internet_down+wan_down starting in month */,
    outages_1m /* of those, duration >= 60 */, longest_s, rx, tx, rx_peak_bps, tx_peak_bps,
    loss_pct, rtt_avg, rtt_p95, jitter_avg, dns_avg_ms, dns_fail_pct, err, drop, crc, cpu_avg,
    speedtests: { n, ok, down_avg, down_min, up_avg, up_min, down_pct_avg, up_pct_avg } }
  ```
  Build it from the day rows (plus the current partial day), the events and the speed tests.
- **`notify_test {}`** (see above).
- **ACL:** read `report`, write `notify_test`.

### LuCI additions

- **Overview:**
  - line-state card: IPv6 prefix and last disconnect cause, shown as a translated label;
  - latency card: a p95 column and a DNS row;
  - new **Router** card: CPU now, 24-h average, peak core, and errors/drops/CRC over 24 h.
- **Charts:**
  - **Latency distribution:** a heatmap for one target (chips to pick it, default = first
    reference target). x = buckets, y = histogram bins on a log-like scale, colour = share of
    replies in the bucket, with the median line on top.
  - **Errors & drops:** bars for err, drop and crc.
  - **Router CPU %:** average and peak-core lines, 0–100.
  - **DNS response time:** avg line with failure bars.
  - Keep the existing latency and throughput charts.
- **Tables:**
  - **Outages:** adds a cause column (translated labels for every cause) and the `loss` type,
    and an expandable trace (`<details>`) with its hops.
  - **Public IP history:** a new table built from `ip_change` events, which no longer appear in
    the outages table.
  - **Speed tests:** add % of plan, CPU avg and peak core.
  - **Daily summary:** add p95, DNS avg/fail %, and err/drop/crc.
- **New tab "Report"** (`linequality/report`, order 2; settings becomes order 3):
  - the 12-month table from `report`;
  - selecting a month shows a detail block written for an ISP complaint: availability,
    outages (count, ≥1 min, longest), speed tests vs plan, latency/loss;
  - a **Print** button (`window.print()`) with print CSS that hides the LuCI header and menu.
- **Settings:**
  - Probes tab: `loss_threshold`, `dns_server`, `dns_name`, `dns_interval`, `interface6`;
  - Speed test tab: `plan_down`, `plan_up`;
  - new **Notifications** tab with all `notify_*` options (`notify_token` as a password
    field) and a **Send test notification** button calling `notify_test`.
- New strings go in the pot and in the Italian po.

## Changes in 0.2.1

Fixes found on the first week of data from a Turris Omnia NG (TurrisOS 9.1.4).

- **Boot grace.** At startup, if the system uptime (`/proc/uptime`) is below `BOOT_GRACE`
  (300 s), the daemon is *booting* until the WAN is first seen up or the uptime reaches
  300 s. While booting, `live()` is false (`live()` = clock synced and not booting) and
  nothing is recorded: no link/WAN/internet events, no probes, no DNS probes, no seconds
  in the buckets, no scheduled speed test. `check_gap` also waits for `live()`, so the
  `monitor_gap` covers the boot until the WAN came up. Before, the WAN coming up after a
  reboot was logged as `link_down` + `wan_down` + `internet_down` (cause `other`). If the
  WAN is still down after 300 s, the outage is real and starts then. A daemon restart on a
  router that has been up for longer than 300 s is not a boot.
- **Outages are merged.** `outage_stats` (used for `disconnects`, `outages`, `outages_1m`,
  `longest_s`) merges `internet_down` and `wan_down` events that overlap or are within
  `OUTAGE_SLACK` (5 s) into one disconnection, from the first start to the last end. A
  PPPoE drop opens both events, which used to count as two outages.
- **Short ticks are skipped.** ucode's `uloop.interval` keeps its phase, so when the loop is
  blocked past an expiry the late tick is followed by an on-time one a few ms later. CPU
  busy % over that sliver came out as 100 % (one jiffy, no idle), and rates were computed
  over a few ms. A tick less than `MIN_TICK` (0.5 s) after the previous one now returns
  without touching the snapshots; the next tick covers the time. Rows written before 0.2.1
  keep their inflated `cpu` maxima.
- **Cheaper `status`.** `build_summary` merged every minute bucket for `today` and `24h`
  (up to 1440 merges each) and every hour row for `month`/`30d`; on the Omnia NG a `status`
  call took 0.9 s, and the overview polls it every 5 s, blocking the loop (hence the late
  ticks above). `rows_since(from)` now picks minute buckets up to the first whole hour,
  hour rows up to the first whole local day, then day rows (pending ones included), which
  gives the same totals with a few dozen merges. `series 24h` (0.5 s, polled every 60 s)
  still merges minutes.
