#!/usr/bin/ucode
// linequalityd - WAN line-quality collector: traffic, loss, latency, outages, speed tests.
// See DESIGN.md for the data model and the ubus API.
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as ubus from 'ubus';
import * as uci from 'uci';

const VERSION = '0.1.0';
const MIN_VALID_TIME = 1700000000;   // below this the clock is not synced yet
const GAP_SECONDS = 120;             // grace before finalizing a period / reporting a monitor gap
const KEEP_SECONDS = 48 * 3600;      // minute buckets kept in RAM, max age of state.json
const PROBES = 10;                   // fping probes per batch (one per second)
const MAX_EVENTS = 5000;
const MAX_TESTS = 1000;
const FOREVER = 1e18;
const SPANS = { '1h': [3600, 60], '24h': [86400, 300], '7d': [7 * 86400, 3600],
                '30d': [30 * 86400, 3600], '1y': [365 * 86400, 86400] };
const NEW_PROBE = () => [0, 0, 0, null, null, 0, 0];   // sent recv rtt_sum rtt_min rtt_max jit_sum jit_n

let args = {};
let cfg = {};
let started = 0;
let conn = null;
let shutting_down = false;
let keep = [];                       // references to timers/signals so they are not collected

let minutes = {};                    // minute start -> bucket, last 48 h
let hours = [];                      // finalized hour rows, ascending
let last_hour_done = 0;
let last_day_done = 0;
let days, events, tests;             // jsonl stores
let open = {};                       // event type -> open event
let last_ip = null;
let iface = { up: null, uptime: null, at: null, l3_device: null, device: null, carrier: null, ipv4: null, gateway: null };
let targets = {};                    // label -> { last, prev, host }
let run = { n: 0, times: [], gw: null };   // current run of probes lost on every reference target
let traffic = { mono: null, prev: null, rx_bps: 0, tx_bps: 0 };
let probe = { proc: null, timer: null };
let spd = { running: false, started_at: null, trigger: null, proc: null, out: null, killed: false,
            idle_rtt: null, loaded_sum: 0, loaded_n: 0, window_end: null,
            pending: null, fin_timer: null, watchdog: null, last_slot: null };
let state_loaded = false;
let gap_checked = false;
let saved_at = 0;

// ---------------------------------------------------------------- helpers

function log(msg) {
	warn(msg, '\n');
}

function dbg(msg) {
	if (args.debug)
		warn('[debug] ', msg, '\n');
}

function log_exc(name, e) {
	log(sprintf('%s: %s (line %s)', name, e.message, e.stacktrace?.[0]?.line));
}

// Wrap a callback so an exception is logged and never reaches the event loop.
function guard(fn, name) {
	return function(...a) {
		try {
			return fn(...a);
		}
		catch (e) {
			log_exc(name, e);
		}
	};
}

function synced(t) {
	return (t ?? time()) >= MIN_VALID_TIME;
}

function num(v, def) {
	let n = +v;
	return n > 0 ? n : def;
}

function shq(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function absdiff(a, b) {
	return a > b ? a - b : b - a;
}

function rnd(x, f) {
	return int(x * f + 0.5) / (f * 1.0);
}

function pct(part, whole) {
	return whole > 0 ? rnd(100.0 * part / whole, 100) : null;
}

function parse_json(txt) {
	try {
		return json(txt);
	}
	catch (e) {
		return null;
	}
}

function mkdir_p(path) {
	if (fs.stat(path))
		return;
	mkdir_p(fs.dirname(path));
	fs.mkdir(path);
}

function write_atomic(path, txt) {
	let tmp = path + '.tmp';
	if (fs.writefile(tmp, txt) == null || !fs.rename(tmp, path)) {
		log(sprintf('cannot write %s: %s', path, fs.error()));
		return false;
	}
	return true;
}

function append_line(path, obj) {
	let f = fs.open(path, 'a');
	if (!f) {
		log(sprintf('cannot append to %s: %s', path, fs.error()));
		return;
	}
	f.write(sprintf('%J\n', obj));
	f.close();
}

function local_midnight(t, add_days) {
	let l = localtime(t);
	return timelocal({ year: l.year, mon: l.mon, mday: l.mday + add_days, hour: 0, min: 0, sec: 0, isdst: -1 });
}

function day_start(t) {
	return local_midnight(t, 0);
}

function next_day(t) {
	return local_midnight(t, 1);
}

function month_start(t, add_months) {
	let l = localtime(t);
	return timelocal({ year: l.year, mon: l.mon + add_months, mday: 1, hour: 0, min: 0, sec: 0, isdst: -1 });
}

function date_str(t) {
	let l = localtime(t);
	return sprintf('%04d-%02d-%02d', l.year, l.mon, l.mday);
}

// ---------------------------------------------------------------- jsonl stores

function store_new(name, cap) {
	return { path: cfg.data_dir + '/' + name, cap, rows: [], nlines: 0 };
}

function store_load(s) {
	let txt = fs.readfile(s.path);
	for (let line in split(txt ?? '', '\n')) {
		let row = line ? parse_json(line) : null;
		if (row) {
			push(s.rows, row);
			s.nlines++;
		}
	}
	if (length(s.rows) > s.cap)
		splice(s.rows, 0, length(s.rows) - s.cap);
}

function store_add(s, row) {
	push(s.rows, row);
	if (length(s.rows) > s.cap)
		shift(s.rows);
	append_line(s.path, row);
	s.nlines++;
}

// Rewrite the file from RAM, only when it holds more lines than the cap (saves flash writes).
function store_compact(s) {
	if (s.nlines <= s.cap)
		return;
	let txt = join('', map(s.rows, r => sprintf('%J\n', r)));
	if (write_atomic(s.path, txt))
		s.nlines = length(s.rows);
}

function init_stores() {
	days = store_new('days.jsonl', cfg.daily_retention_days);
	events = store_new('events.jsonl', MAX_EVENTS);
	tests = store_new('speedtests.jsonl', MAX_TESTS);
}

function month_files() {
	let files = [];
	for (let f in fs.lsdir(cfg.data_dir) ?? []) {
		let m = match(f, /^hours-([0-9]{4})-([0-9]{2})\.jsonl$/);
		if (m)
			push(files, { name: f, end: timelocal({ year: +m[1], mon: +m[2] + 1, mday: 1, hour: 0, min: 0, sec: 0, isdst: -1 }) });
	}
	return sort(files, (a, b) => a.end - b.end);
}

function load_hours(now) {
	let cutoff = now - cfg.hourly_retention_days * 86400;
	for (let f in month_files()) {
		if (f.end <= cutoff)
			continue;
		for (let line in split(fs.readfile(cfg.data_dir + '/' + f.name) ?? '', '\n')) {
			let row = line ? parse_json(line) : null;
			if (row && row.t >= cutoff)
				push(hours, row);
		}
	}
	sort(hours, (a, b) => a.t - b.t);
}

// ---------------------------------------------------------------- buckets

function new_bucket(t) {
	return { t, rx: 0, tx: 0, rx_peak: 0, tx_peak: 0, err: 0, drop: 0,
	         down_s: 0, wan_down_s: 0, mon_s: 0, st: 0, p: {} };
}

function bucket_at(t) {
	let k = t - t % 60;
	return minutes[k] ??= new_bucket(k);
}

// Add bucket b into a; used for every roll-up and for series down-sampling.
function merge(a, b) {
	for (let k in ['rx', 'tx', 'err', 'drop', 'down_s', 'wan_down_s', 'mon_s'])
		a[k] += b[k] ?? 0;
	for (let k in ['rx_peak', 'tx_peak', 'st'])
		a[k] = max(a[k], b[k] ?? 0);
	for (let label, v in b.p) {
		let x = a.p[label] ??= NEW_PROBE();
		for (let i in [0, 1, 2, 5, 6])
			x[i] += v[i];
		if (v[3] != null && (x[3] == null || v[3] < x[3]))
			x[3] = v[3];
		if (v[4] != null && (x[4] == null || v[4] > x[4]))
			x[4] = v[4];
	}
	return a;
}

function tidy(row) {
	for (let label, v in row.p) {
		v[2] = rnd(v[2], 1000);
		v[5] = rnd(v[5], 1000);
	}
	return row;
}

// Hour rows (UTC hours) that are over, newer than `after`, built from minute buckets.
function hour_rows(mins, after, now) {
	let groups = {};
	for (let k, m in mins) {
		let h = m.t - m.t % 3600;
		if (h > after && h + 3600 + GAP_SECONDS <= now)
			merge(groups[h] ??= new_bucket(h), m);
	}
	return map(sort(keys(groups)), k => groups[k]);
}

// Local-day rows that are over, newer than `after`, built from hour rows.
function day_rows(hrows, after, now) {
	let groups = {};
	for (let h in hrows) {
		if (h.t < after)
			continue;
		let d = day_start(h.t);
		if (d > after && next_day(d) + GAP_SECONDS <= now)
			merge(groups[d] ??= new_bucket(d), h);
	}
	return map(sort(keys(groups)), k => {
		groups[k].d = date_str(groups[k].t);
		return groups[k];
	});
}

function all_hours() {
	return [...hours, ...hour_rows(minutes, last_hour_done, FOREVER)];
}

function all_days() {
	return [...days.rows, ...day_rows(all_hours(), last_day_done, FOREVER)];
}

function rollup() {
	let now = time();
	if (!synced(now))
		return;
	for (let r in hour_rows(minutes, last_hour_done, now)) {
		tidy(r);
		push(hours, r);
		let l = localtime(r.t);
		append_line(sprintf('%s/hours-%04d-%02d.jsonl', cfg.data_dir, l.year, l.mon), r);
		last_hour_done = r.t;
	}
	for (let r in day_rows(hours, last_day_done, now)) {
		store_add(days, tidy(r));
		last_day_done = r.t;
	}
	for (let k in keys(minutes))
		if (minutes[k].t < now - KEEP_SECONDS)
			delete minutes[k];
}

function retention() {
	let cutoff = time() - cfg.hourly_retention_days * 86400;
	hours = filter(hours, h => h.t >= cutoff);
	for (let f in month_files())
		if (f.end <= cutoff)
			fs.unlink(cfg.data_dir + '/' + f.name);
	store_compact(days);
	store_compact(events);
	store_compact(tests);
}

// ---------------------------------------------------------------- events

function open_event(type, start, detail) {
	let ev = { id: type + '-' + start, type, start, end: null, duration: null, detail: detail ?? {} };
	open[type] = ev;
	log(sprintf('event %s opened', ev.id));
	return ev;
}

function finish_event(ev, end, extra) {
	ev.end = end;
	ev.duration = end - ev.start;
	for (let k, v in extra ?? {})
		ev.detail[k] = v;
	store_add(events, ev);
	log(sprintf('event %s closed after %ds', ev.id, ev.duration));
}

function close_event(type, end, extra) {
	let ev = open[type];
	if (!ev)
		return;
	delete open[type];
	finish_event(ev, max(end, ev.start), extra);
}

function add_closed(type, start, end, detail) {
	finish_event({ id: type + '-' + start, type, start, end: null, duration: null, detail: detail ?? {} }, end);
}

function add_seconds(field, t, n) {
	for (let i = 0; i < n; i++)
		bucket_at(t + i)[field]++;
}

function count_disconnects(from) {
	let n = 0;
	for (let ev in [...events.rows, ...values(open)])
		if (ev.start >= from && (ev.type == 'internet_down' || ev.type == 'wan_down'))
			n++;
	return n;
}

// ---------------------------------------------------------------- interface state

function find_gateway(r) {
	let a = r?.['ipv4-address']?.[0];
	if (a?.ptpaddress)
		return a.ptpaddress;
	for (let rt in r?.route ?? [])
		if (rt.target == '0.0.0.0' && rt.mask == 0 && rt.nexthop && rt.nexthop != '0.0.0.0')
			return rt.nexthop;
	return null;
}

function track_link_events(up, uptime, ip, carrier, now) {
	let ipchg = (ip && last_ip && ip != last_ip) ? { old_ip: last_ip, new_ip: ip } : null;
	if (ipchg)
		log(sprintf('ipv4 address changed %s -> %s', last_ip, ip));

	if (up && iface.up && iface.uptime != null && uptime < iface.uptime) {
		// session restarted between two polls: record the outage we missed
		let end = max(now - uptime, iface.at);
		add_closed('wan_down', iface.at, end, ipchg ?? {});
		add_seconds('wan_down_s', iface.at, end - iface.at);
	}
	else if (!up && !open.wan_down)
		open_event('wan_down', now);
	else if (up && open.wan_down)
		close_event('wan_down', now, ipchg);

	if (carrier == false && !open.link_down)
		open_event('link_down', now);
	else if (carrier == true && open.link_down)
		close_event('link_down', now);
}

function apply_iface(r, carrier, now) {
	let up = r?.up == true;
	let uptime = up ? (r.uptime ?? 0) : 0;
	let ip = r?.['ipv4-address']?.[0]?.address;
	if (synced(now))
		track_link_events(up, uptime, ip, carrier, now);
	if (ip)
		last_ip = ip;
	iface = { up, uptime, at: now, l3_device: r?.l3_device, device: r?.device, carrier,
	          ipv4: ip ?? null, gateway: up ? find_gateway(r) : null };
}

function read_carrier(dev) {
	let v = dev ? trim(fs.readfile('/sys/class/net/' + dev + '/carrier') ?? '') : '';
	return v == '1' ? true : v == '0' ? false : null;
}

function poll() {
	let r = conn.call('network.interface.' + cfg.interface, 'status');
	apply_iface(r, read_carrier(r?.device), time());
}

// ---------------------------------------------------------------- traffic

const COUNTERS = ['rx_bytes', 'tx_bytes', 'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped'];

function read_counters(dev) {
	let c = { dev };
	for (let k in COUNTERS) {
		let v = fs.readfile(sprintf('/sys/class/net/%s/statistics/%s', dev, k));
		if (v == null)
			return null;
		c[k] = +v;
	}
	return c;
}

// Per-counter deltas; all zero when the device changed or a counter went backwards.
function counter_deltas(prev, cur) {
	let d = {};
	for (let k in COUNTERS) {
		d[k] = (prev && cur && prev.dev == cur.dev) ? cur[k] - prev[k] : 0;
		if (d[k] < 0)
			return counter_deltas(null, null);
	}
	return d;
}

function tick() {
	let m = clock(true);
	let mono = m[0] + m[1] / 1e9;
	let dt = traffic.mono != null ? mono - traffic.mono : null;
	traffic.mono = mono;
	let cur = iface.l3_device ? read_counters(iface.l3_device) : null;
	let prev = traffic.prev;
	traffic.prev = cur;
	if (dt == null || !synced())
		return;

	let secs = min(max(int(dt + 0.5), 1), 5);
	let d = counter_deltas(prev, cur);
	let b = bucket_at(time());
	b.rx += d.rx_bytes;
	b.tx += d.tx_bytes;
	b.err += d.rx_errors + d.tx_errors;
	b.drop += d.rx_dropped + d.tx_dropped;
	b.mon_s += secs;
	traffic.rx_bps = int(d.rx_bytes * 8.0 / dt);
	traffic.tx_bps = int(d.tx_bytes * 8.0 / dt);
	b.rx_peak = max(b.rx_peak, traffic.rx_bps);
	b.tx_peak = max(b.tx_peak, traffic.tx_bps);
	if (open.wan_down)
		b.wan_down_s += secs;
	if (spd.running)
		b.st = 1;
}

// ---------------------------------------------------------------- probes

function ref_labels() {
	let refs = filter(cfg.targets, t => t != 'gateway');
	return length(refs) ? refs : ['gateway'];
}

function resolve_targets() {
	let list = [];
	for (let label in cfg.targets) {
		let host = label == 'gateway' ? iface.gateway : label;
		targets[label] ??= { last: null, prev: null, host: null };
		targets[label].host = host;
		if (host)
			push(list, { label, host });
	}
	return list;
}

function parse_fping(txt) {
	let res = {};
	for (let line in split(txt, '\n')) {
		let m = match(line, /^([^ ]+) *: +(.*)$/);
		if (!m)
			continue;
		let vals = split(trim(m[2]), /\s+/);
		if (length(filter(vals, v => v != '-' && !match(v, /^[0-9.]+$/))))
			continue;
		res[m[1]] = map(vals, v => v == '-' ? null : +v * 1.0);
	}
	return res;
}

function finish_speedtest() {
	let row = spd.pending;
	if (!row)
		return;
	spd.pending = null;
	spd.fin_timer?.cancel();
	row.loaded_rtt = spd.loaded_n ? rnd(spd.loaded_sum * 1.0 / spd.loaded_n, 100) : null;
	store_add(tests, row);
	log(sprintf('speed test finished: ok=%s down=%s up=%s', row.ok, row.down, row.up));
}

function account(t, label, rtt) {
	let p = bucket_at(t).p[label] ??= NEW_PROBE();
	let tg = targets[label] ??= { last: null, prev: null, host: null };
	p[0]++;
	tg.last = rtt;
	if (rtt == null)
		return;
	p[1]++;
	p[2] += rtt;
	if (p[3] == null || rtt < p[3])
		p[3] = rtt;
	if (p[4] == null || rtt > p[4])
		p[4] = rtt;
	if (tg.prev != null) {
		p[5] += absdiff(rtt, tg.prev);
		p[6]++;
	}
	tg.prev = rtt;
}

// One second in which every reference target either answered (ok) or not.
// gw: did the gateway answer (null when it was not probed).
function run_probe(t, ok, gw) {
	if (ok) {
		if (open.internet_down)
			close_event('internet_down', t);
		run = { n: 0, times: [], gw: null };
		return;
	}
	run.n++;
	if (gw != null)
		run.gw = (run.gw == true) || gw;
	if (open.internet_down) {
		add_seconds('down_s', t, 1);
		open.internet_down.detail.gateway_ok = run.gw;
		open.internet_down.detail.wan_up = open.internet_down.detail.wan_up || iface.up == true;
		return;
	}
	push(run.times, t);
	if (run.n >= cfg.down_after) {
		open_event('internet_down', run.times[0], { gateway_ok: run.gw, wan_up: iface.up == true });
		for (let tt in run.times)
			add_seconds('down_s', tt, 1);
		run.times = [];
	}
}

function process_batch(start, list, txt) {
	if (!synced(start))
		return;
	let res = parse_fping(txt);
	let refs = ref_labels();
	for (let i = 0; i < PROBES; i++) {
		let t = start + i;
		let have_ref = false, ref_ok = false, gw = null;
		for (let tg in list) {
			let series = res[tg.host];
			if (!series)
				continue;
			let rtt = series[i];
			account(t, tg.label, rtt);
			if (tg.label == 'gateway')
				gw = rtt != null;
			if (!(tg.label in refs))
				continue;
			have_ref = true;
			if (rtt != null) {
				ref_ok = true;
				if ((spd.running || spd.pending) && t >= spd.started_at && (spd.window_end == null || t <= spd.window_end)) {
					spd.loaded_sum += rtt;
					spd.loaded_n++;
				}
			}
		}
		if (have_ref)
			run_probe(t, ref_ok, gw);
	}
	if (spd.pending)
		finish_speedtest();
}

let probe_next;

function probe_retry(ms) {
	probe.timer = uloop.timer(ms, guard(probe_next, 'probe'));
}

function probe_done(start, list, file) {
	let txt = fs.readfile(file) ?? '';
	fs.unlink(file);
	try {
		process_batch(start, list, txt);
	}
	catch (e) {
		log_exc('batch', e);
	}
	// a batch that ended early (fping failed) must not turn into a busy loop
	let elapsed = time() - start;
	if (elapsed < PROBES - 2)
		probe_retry((PROBES - elapsed) * 1000);
	else
		probe_next();
}

probe_next = function() {
	if (shutting_down)
		return;
	let list = synced() ? resolve_targets() : [];
	if (!length(list))
		return probe_retry(1000);

	let hosts = [];
	for (let tg in list)
		if (!(tg.host in hosts))
			push(hosts, tg.host);
	let file = sprintf('/tmp/%s-fping.out', args.ubus_name);
	let cmd = sprintf('exec fping -C %d -p 1000 -t 800 -q %s >/dev/null 2>%s',
	                  PROBES, join(' ', map(hosts, shq)), shq(file));
	let start = time();
	probe.proc = uloop.process('/bin/sh', ['-c', cmd], null,
		guard(() => probe_done(start, list, file), 'probe'));
	if (!probe.proc)
		probe_retry(5000);
};

// ---------------------------------------------------------------- speed test

function st_command() {
	if (args.speedtest_cmd)
		return fs.access(args.speedtest_cmd, 'x') ? args.speedtest_cmd : null;
	for (let d in ['/usr/bin', '/usr/sbin', '/bin', '/sbin', '/usr/local/bin'])
		if (fs.access(d + '/librespeed-cli', 'x'))
			return d + '/librespeed-cli';
	return null;
}

function kill_proc(p) {
	if (p)
		system(['kill', '-TERM', '' + p.pid()]);
}

// Mean RTT of the reference targets over minute buckets in [from, to) without speed tests.
function mean_rtt(from, to) {
	let sum = 0, n = 0;
	for (let k, m in minutes) {
		if (m.t < from || m.t >= to || m.st)
			continue;
		for (let label in ref_labels()) {
			sum += m.p[label]?.[2] ?? 0;
			n += m.p[label]?.[1] ?? 0;
		}
	}
	return n ? rnd(sum * 1.0 / n, 100) : null;
}

function parse_speedtest(txt) {
	let j = parse_json(txt);
	if (type(j) == 'array')
		j = j[0];
	if (type(j) != 'object' || j.download == null)
		return null;
	return {
		server: j.server?.name ?? null,
		ping: j.ping == null ? null : rnd(j.ping, 100),
		jitter: j.jitter == null ? null : rnd(j.jitter, 100),
		down: rnd(j.download, 100),
		up: rnd(j.upload ?? 0, 100),
		bytes_rx: j.bytes_received ?? null,
		bytes_tx: j.bytes_sent ?? null
	};
}

function speedtest_done(code) {
	let end = time();
	let txt = fs.readfile(spd.out);
	let err = fs.readfile(spd.out + '.err');
	fs.unlink(spd.out);
	fs.unlink(spd.out + '.err');
	spd.watchdog?.cancel();

	let row = { t: spd.started_at, dur: end - spd.started_at, trigger: spd.trigger, ok: false, error: null,
	            server: null, ping: null, jitter: null, down: null, up: null, bytes_rx: null, bytes_tx: null,
	            idle_rtt: spd.idle_rtt, loaded_rtt: null };
	let res = code == 0 ? parse_speedtest(txt ?? '') : null;
	if (res) {
		row.ok = true;
		for (let k, v in res)
			row[k] = v;
	}
	else
		row.error = spd.killed ? 'timeout' : (split(trim(err ?? ''), '\n')[0] || sprintf('exit code %d', code));

	spd.running = false;
	spd.window_end = end;
	spd.pending = row;
	bucket_at(end).st = 1;
	// the probe batch in flight still holds loaded-RTT samples: finish on the next batch (or after 15 s)
	spd.fin_timer = uloop.timer(15000, guard(finish_speedtest, 'speedtest'));
}

function speedtest_start(trigger) {
	let cmd = st_command();
	if (!cmd)
		return 'not_available';
	if (spd.running)
		return 'running';
	finish_speedtest();

	let now = time();
	let out = sprintf('/tmp/%s-speedtest.out', args.ubus_name);
	let a = [cmd, '--json', '--duration', cfg.speedtest_duration, '--concurrent', cfg.speedtest_concurrent];
	if (cfg.speedtest_server)
		push(a, '--server', cfg.speedtest_server);
	let line = sprintf('exec %s >%s 2>%s', join(' ', map(a, shq)), shq(out), shq(out + '.err'));
	spd.proc = uloop.process('/bin/sh', ['-c', line], null, guard(speedtest_done, 'speedtest'));
	if (!spd.proc)
		return 'not_available';

	spd.running = true;
	spd.started_at = now;
	spd.trigger = trigger;
	spd.out = out;
	spd.killed = false;
	spd.window_end = null;
	spd.loaded_sum = 0;
	spd.loaded_n = 0;
	spd.idle_rtt = mean_rtt(now - 600, now);
	spd.watchdog = uloop.timer((cfg.speedtest_duration + 120) * 1000, guard(() => {
		spd.killed = true;
		kill_proc(spd.proc);
	}, 'speedtest'));
	bucket_at(now).st = 1;
	log(sprintf('speed test started (%s)', trigger));
	return null;
}

function schedule_check() {
	if (!length(cfg.schedule) || !synced())
		return;
	let now = time();
	let l = localtime(now);
	let hm = sprintf('%02d:%02d', l.hour, l.min);
	let slot = date_str(now) + ' ' + hm;
	if (!(hm in cfg.schedule) || spd.last_slot == slot)
		return;
	spd.last_slot = slot;
	let err = speedtest_start('schedule');
	if (err)
		log('scheduled speed test skipped: ' + err);
}

// ---------------------------------------------------------------- queries

function summarize(rows, from) {
	let m = new_bucket(0);
	for (let r in rows)
		if (r.t >= from)
			merge(m, r);
	let sent = 0, recv = 0, rsum = 0, jsum = 0, jn = 0;
	for (let label in ref_labels()) {
		let p = m.p[label];
		if (!p)
			continue;
		sent += p[0];
		recv += p[1];
		rsum += p[2];
		jsum += p[5];
		jn += p[6];
	}
	return {
		rx: m.rx, tx: m.tx,
		rx_avg_bps: m.mon_s ? int(m.rx * 8.0 / m.mon_s) : 0,
		tx_avg_bps: m.mon_s ? int(m.tx * 8.0 / m.mon_s) : 0,
		rx_peak_bps: m.rx_peak, tx_peak_bps: m.tx_peak,
		mon_s: m.mon_s, down_s: m.down_s, wan_down_s: m.wan_down_s,
		uptime_pct: m.mon_s ? max(0, rnd(100.0 * (m.mon_s - m.down_s) / m.mon_s, 100)) : null,
		disconnects: count_disconnects(from),
		loss_pct: pct(sent - recv, sent),
		rtt_avg: recv ? rnd(rsum * 1.0 / recv, 100) : null,
		jitter_avg: jn ? rnd(jsum * 1.0 / jn, 100) : null
	};
}

function build_summary(now) {
	let mins = values(minutes);
	let hrs = all_hours();
	return {
		today: summarize(mins, day_start(now)),
		month: summarize(hrs, month_start(now, 0)),
		'24h': summarize(mins, now - 86400),
		'7d': summarize(hrs, now - 7 * 86400),
		'30d': summarize(hrs, now - 30 * 86400)
	};
}

function live_targets(now) {
	let out = [];
	for (let label in cfg.targets) {
		let tg = targets[label] ?? {};
		let sent = 0, recv = 0, rsum = 0, jsum = 0, jn = 0;
		for (let k, m in minutes) {
			let p = m.t >= now - 300 ? m.p[label] : null;
			if (!p)
				continue;
			sent += p[0];
			recv += p[1];
			rsum += p[2];
			jsum += p[5];
			jn += p[6];
		}
		push(out, { label, host: tg.host ?? null, last_rtt: tg.last ?? null, loss_pct: pct(sent - recv, sent),
		            rtt_avg: recv ? rnd(rsum * 1.0 / recv, 100) : null, jitter: jn ? rnd(jsum * 1.0 / jn, 100) : null });
	}
	return out;
}

function api_status() {
	let now = time();
	let l = tests.rows;
	return {
		version: VERSION, now, started,
		tz_offset: timegm(localtime(now)) - now,
		interface: { name: cfg.interface, up: iface.up == true, uptime: iface.uptime ?? 0,
		             l3_device: iface.l3_device ?? null, device: iface.device ?? null,
		             carrier: iface.carrier, ipv4: iface.ipv4, gateway: iface.gateway },
		live: { rx_bps: traffic.rx_bps, tx_bps: traffic.tx_bps, targets: live_targets(now) },
		open_events: values(open),
		summary: build_summary(now),
		speedtest: { available: st_command() != null, running: spd.running, started_at: spd.running ? spd.started_at : null,
		             schedule: join(' ', cfg.schedule), duration: cfg.speedtest_duration,
		             concurrent: cfg.speedtest_concurrent, last: length(l) ? l[length(l) - 1] : null }
	};
}

function by_time(rows) {
	return sort(rows, (a, b) => a.t - b.t);
}

function api_series(range) {
	let spec = SPANS[range];
	if (!spec)
		return ubus.STATUS_INVALID_ARGUMENT;
	let now = time();
	let step = spec[1];
	let from = now - spec[0];
	let rows;
	if (range == '1h')
		rows = filter(values(minutes), m => m.t + step > from);
	else if (range == '24h') {
		let groups = {};
		for (let k, m in minutes)
			if (m.t + 60 > from) {
				let g = m.t - m.t % step;
				merge(groups[g] ??= new_bucket(g), m);
			}
		rows = values(groups);
	}
	else
		rows = filter(range == '1y' ? all_days() : all_hours(), r => r.t + step > from);
	return { range, step, rows: by_time(rows) };
}

function api_events(limit, since) {
	let rows = filter([...events.rows, ...values(open)], ev => (ev.end ?? FOREVER) >= since);
	sort(rows, (a, b) => b.start - a.start);
	return { events: slice(rows, 0, limit) };
}

function api_speedtests(limit) {
	let rows = tests.rows;
	return { results: reverse(slice(rows, max(0, length(rows) - limit))) };
}

function api_speedtest_run() {
	let err = speedtest_start('manual');
	return err ? { error: err } : { started: true };
}

function publish() {
	// ucode rejects undeclared arguments, and calls made through rpcd/LuCI always
	// carry ubus_rpc_session
	let wrap = (fn, argspec) => ({
		args: { ...argspec, ubus_rpc_session: '' },
		call: function(req) {
			try {
				return fn(req.args ?? {});
			}
			catch (e) {
				log_exc('ubus', e);
				return ubus.STATUS_UNKNOWN_ERROR;
			}
		}
	});
	return conn.publish(args.ubus_name, {
		status: wrap(a => api_status(), {}),
		series: wrap(a => api_series(a.range ?? '24h'), { range: '' }),
		events: wrap(a => api_events(a.limit || 200, a.since ?? 0), { limit: 0, since: 0 }),
		speedtests: wrap(a => api_speedtests(a.limit || 50), { limit: 0 }),
		speedtest_run: wrap(a => api_speedtest_run(), {})
	});
}

// ---------------------------------------------------------------- startup / shutdown

function parse_args(argv) {
	let o = { ubus_name: 'linequality', targets: [], debug: false };
	for (let i = 0; i < length(argv); i++) {
		switch (argv[i]) {
		case '--data-dir': o.data_dir = argv[++i]; break;
		case '--ubus-name': o.ubus_name = argv[++i]; break;
		case '--speedtest-cmd': o.speedtest_cmd = argv[++i]; break;
		case '--target': push(o.targets, argv[++i]); break;
		case '--debug': o.debug = true; break;
		case '--selftest': o.selftest = true; break;
		default:
			warn('unknown argument: ', argv[i], '\n');
			exit(2);
		}
	}
	return o;
}

function load_config() {
	let s = uci.cursor().get_all('linequality', 'main') ?? {};
	let list = length(args.targets) ? args.targets : (type(s.target) == 'string' ? [s.target] : s.target);
	// IP literals only: a host name would vanish from fping's output while DNS
	// is down, exactly when the outage should be recorded
	list = filter(list ?? [], t => {
		let ok = t == 'gateway' || iptoarr(t) != null;
		if (!ok)
			log(sprintf('ignoring target %s: not an IP address', t));
		return ok;
	});
	cfg = {
		interface: s.interface || 'wan',
		targets: length(list) ? list : ['gateway', '1.1.1.1', '8.8.8.8'],
		down_after: int(num(s.down_after, 3)),
		data_dir: args.data_dir || s.data_dir || '/etc/linequality',
		hourly_retention_days: int(num(s.hourly_retention_days, 90)),
		daily_retention_days: int(num(s.daily_retention_days, 1095)),
		schedule: filter(split(trim(s.speedtest_schedule ?? ''), /\s+/), t => match(t, /^([01][0-9]|2[0-3]):[0-5][0-9]$/)),
		speedtest_duration: int(num(s.speedtest_duration, 10)),
		speedtest_concurrent: int(num(s.speedtest_concurrent, 3)),
		speedtest_server: s.speedtest_server || ''
	};
}

function load_state(now) {
	let path = cfg.data_dir + '/state.json';
	let s = parse_json(fs.readfile(path) ?? '');
	fs.unlink(path);   // a later crash must not look like a clean shutdown
	if (type(s) != 'object' || !s.saved_at || now - s.saved_at > KEEP_SECONDS)
		return;
	state_loaded = true;
	saved_at = s.saved_at;
	for (let m in s.minutes ?? [])
		minutes[m.t] = m;
	for (let ev in s.open ?? [])
		open[ev.type] = ev;
	spd.last_slot = s.last_speedtest_slot ?? null;
	if (open.internet_down)
		run = { n: cfg.down_after, times: [], gw: open.internet_down.detail?.gateway_ok };
}

function save_state() {
	let s = { version: 1, saved_at: time(), minutes: values(minutes), open: values(open),
	          last_speedtest_slot: spd.last_slot };
	write_atomic(cfg.data_dir + '/state.json', sprintf('%J', s));
}

// Called once the clock is valid: report the time the daemon was not running.
function check_gap(now) {
	let last_end = length(hours) ? hours[length(hours) - 1].t + 3600 : 0;
	let ref = max(saved_at, last_end);
	gap_checked = true;
	if (ref > 0 && now - ref > GAP_SECONDS)
		add_closed('monitor_gap', ref, now, { clean: state_loaded });
}

function shutdown() {
	shutting_down = true;
	finish_speedtest();
	save_state();
	kill_proc(probe.proc);
	kill_proc(spd.proc);
	log('stopped');
	uloop.end();
}

function every_second() {
	if (!gap_checked && synced())
		check_gap(time());
	tick();
}

function main() {
	load_config();
	mkdir_p(cfg.data_dir);
	init_stores();
	for (let s in [days, events, tests])
		store_load(s);
	let now = time();
	load_hours(now);
	last_hour_done = length(hours) ? hours[length(hours) - 1].t : 0;
	last_day_done = length(days.rows) ? days.rows[length(days.rows) - 1].t : 0;
	load_state(now);
	started = now;

	uloop.init();
	conn = ubus.connect();
	if (!conn || !publish()) {
		log('cannot publish on ubus as ' + args.ubus_name);
		exit(1);
	}

	let retention_timer;
	retention_timer = uloop.timer(300000, guard(function() {
		retention();
		retention_timer.set(86400000);
	}, 'retention'));
	push(keep,
		uloop.interval(1000, guard(every_second, 'tick')),
		uloop.interval(5000, guard(poll, 'poll')),
		uloop.interval(30000, guard(rollup, 'rollup')),
		uloop.interval(20000, guard(schedule_check, 'schedule')),
		retention_timer,
		uloop.signal('SIGTERM', guard(shutdown, 'shutdown')),
		uloop.signal('SIGINT', guard(shutdown, 'shutdown')));

	guard(poll, 'poll')();
	probe_next();
	log(sprintf('linequalityd %s started, data in %s', VERSION, cfg.data_dir));
	uloop.run();
}

// ---------------------------------------------------------------- self test

function selftest() {
	let failed = 0;
	let check = (name, ok) => {
		if (!ok) {
			failed++;
			warn('FAIL ', name, '\n');
		}
		else
			warn('ok   ', name, '\n');
	};
	let mk = (t, rx, peak, p) => {
		let b = new_bucket(t);
		b.rx = rx;
		b.rx_peak = peak;
		b.mon_s = 60;
		b.p = p ?? {};
		return b;
	};

	// merge
	let a = mk(0, 100, 5, { x: [10, 9, 20.0, 1.0, 5.0, 2.0, 4] });
	merge(a, mk(60, 50, 9, { x: [10, 10, 30.0, 0.5, 4.0, 1.0, 5], y: [10, 0, 0, null, null, 0, 0] }));
	check('merge sums', a.rx == 150 && a.mon_s == 120 && a.p.x[0] == 20 && a.p.x[1] == 19 && a.p.x[2] == 50);
	check('merge peak/min/max', a.rx_peak == 9 && a.p.x[3] == 0.5 && a.p.x[4] == 5.0 && a.p.x[6] == 9);
	check('merge null rtt', a.p.y[3] == null && a.p.y[0] == 10);

	// hour roll-up: hour 0 (two minutes) and hour 1 (one minute)
	let base = 1800000000 - 1800000000 % 3600;
	let mins = {};
	for (let t in [base, base + 60, base + 3600 + 60])
		mins[t] = mk(t, 10, 1, { x: [10, 10, 25.0, 2.0, 3.0, 1.0, 9] });
	check('hour not final too early', length(hour_rows(mins, 0, base + 3600 + 119)) == 0);
	let hr = hour_rows(mins, 0, base + 3600 + 120);
	check('hour final after grace', length(hr) == 1 && hr[0].t == base && hr[0].rx == 20 && hr[0].p.x[0] == 20);
	check('hour after filter', length(hour_rows(mins, base, base + 7200 + 120)) == 1);
	check('hour pending includes partial', length(hour_rows(mins, 0, FOREVER)) == 2);

	// day roll-up across a local midnight
	let d0 = day_start(base + 7200);
	let hrows = [];
	for (let h in [d0 + 3600, d0 + 7200, next_day(d0) + 3600])
		push(hrows, mk(h, 100, 1));
	check('day not final before midnight+grace', length(day_rows(hrows, 0, next_day(d0) + 119)) == 0);
	let dr = day_rows(hrows, 0, next_day(d0) + 120);
	check('day final', length(dr) == 1 && dr[0].t == d0 && dr[0].rx == 200 && dr[0].d == date_str(d0));
	check('day pending includes today', length(day_rows(hrows, 0, FOREVER)) == 2);

	// fping parser
	let f = parse_fping('1.1.1.1 : 2.68 2.54 - 2.72\n8.8.8.8 : - - - -\nfping: junk\n9.9.9.9 : 3 x 4\n');
	check('fping parse', f['1.1.1.1'][0] == 2.68 && f['1.1.1.1'][2] == null && length(f['1.1.1.1']) == 4);
	check('fping all lost', length(filter(f['8.8.8.8'], v => v != null)) == 0);
	check('fping bad line skipped', f['9.9.9.9'] == null);

	// events, interface tracking and probe runs with a scratch data dir
	cfg = { interface: 'wan', targets: ['gateway', '1.1.1.1', '8.8.8.8'], down_after: 3,
	        data_dir: args.data_dir || '/tmp/linequality-selftest',
	        daily_retention_days: 1095, schedule: [] };
	system(['rm', '-rf', cfg.data_dir]);
	mkdir_p(cfg.data_dir);
	init_stores();
	minutes = {};
	open = {};
	let T = 1800000000;
	let up = (uptime, ip) => ({ up: true, uptime, 'ipv4-address': [{ address: ip, ptpaddress: '10.0.0.1' }], l3_device: 'pppoe-wan', device: 'eth4' });

	apply_iface(up(100, '1.2.3.4'), true, T);
	check('gateway from ptpaddress', iface.gateway == '10.0.0.1');
	apply_iface(up(105, '1.2.3.4'), true, T + 5);
	check('no event while stable', length(events.rows) == 0 && length(keys(open)) == 0);
	apply_iface(up(2, '1.2.3.4'), true, T + 10);
	check('fast reconnect', length(events.rows) == 1 && events.rows[0].type == 'wan_down' && events.rows[0].start == T + 5 && events.rows[0].end == T + 8);
	apply_iface({ up: false }, true, T + 20);
	check('wan_down opens', open.wan_down?.start == T + 20);
	apply_iface(up(3, '5.6.7.8'), true, T + 30);
	check('wan_down closes with ip change', !open.wan_down && events.rows[1].duration == 10 && events.rows[1].detail.old_ip == '1.2.3.4' && events.rows[1].detail.new_ip == '5.6.7.8');
	apply_iface(up(8, '5.6.7.8'), false, T + 35);
	check('link_down opens', open.link_down != null);
	apply_iface(up(13, '5.6.7.8'), true, T + 40);
	check('link_down closes', !open.link_down && events.rows[2].type == 'link_down');

	run = { n: 0, times: [], gw: null };
	run_probe(T, true, true);
	run_probe(T + 1, false, true);
	run_probe(T + 2, false, false);
	check('no event below down_after', !open.internet_down);
	run_probe(T + 3, false, false);
	check('internet_down opens at first lost probe', open.internet_down?.start == T + 1 && open.internet_down.detail.gateway_ok == true);
	run_probe(T + 4, false, false);
	run_probe(T + 5, true, true);
	check('internet_down closes', !open.internet_down && events.rows[3].type == 'internet_down' && events.rows[3].duration == 4);
	let ds = 0;
	for (let k, m in minutes)
		ds += m.down_s;
	check('down_s counted', ds == 4);
	run_probe(T + 6, false, null);
	run_probe(T + 7, true, true);
	check('short loss ignored', !open.internet_down && length(events.rows) == 4);

	// counters
	check('counter reset gives zero', counter_deltas({ dev: 'a', rx_bytes: 10 }, { dev: 'a', rx_bytes: 5 }).rx_bytes == 0);
	check('counter delta', counter_deltas({ dev: 'a', rx_bytes: 10, tx_bytes: 0, rx_errors: 0, tx_errors: 0, rx_dropped: 0, tx_dropped: 0 },
	                                       { dev: 'a', rx_bytes: 30, tx_bytes: 0, rx_errors: 0, tx_errors: 0, rx_dropped: 0, tx_dropped: 0 }).rx_bytes == 20);

	system(['rm', '-rf', cfg.data_dir]);
	warn(failed ? sprintf('%d FAILED\n', failed) : 'all passed\n');
	exit(failed ? 1 : 0);
}

args = parse_args(ARGV);
if (args.selftest)
	selftest();
else
	main();
