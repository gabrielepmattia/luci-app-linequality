#!/usr/bin/ucode
// linequalityd - WAN line-quality collector: traffic, loss, latency, outages, speed tests.
// See DESIGN.md for the data model and the ubus API.
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as ubus from 'ubus';
import * as uci from 'uci';

const VERSION = '0.2.0';
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
const HIST_EDGES = [1, 2, 3, 4, 6, 8, 10, 15, 20, 30, 40, 60, 80, 100, 150, 200, 400];   // ms, plus an open last bin
const HIST_TOP = 800;                // upper bound of the last bin for percentiles
const TRACE_GAP = 600;               // at most one traceroute per this many seconds
const TRACE_MAX = 20;                // seconds a closed event waits for its trace
const NOTE_MAX = 50;                 // notification queue cap
const NOTE_TTL = 86400;              // queued notifications older than this are dropped
const NOTE_RETRY = 60;

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
let iface = { up: null, uptime: null, at: null, l3_device: null, device: null, phys: null, proto: null,
              carrier: null, ipv4: null, gateway: null };
let targets = {};                    // label -> { last, prev, host }
let run = { n: 0, times: [], gw: null };   // current run of probes lost on every reference target
let traffic = { mono: null, prev: null, rx_bps: 0, tx_bps: 0, cpu_prev: null, cpu: null, crc_prev: null };
let dns = { idx: 0, proc: null, mono: null, killed: false, watchdog: null, last_ms: null, ok_last: null };
let prefix6 = null;                  // current delegated IPv6 prefix
let last_prefix = null;              // last non-null prefix, to detect changes
let trace = { proc: null, out: null, ev: null, closing: false, watchdog: null, last_at: 0 };
let loss = { win: [], low_since: null, max: 0, end: null };   // 60-s loss window of the reference targets
let notes = { queue: [], proc: null, next_try: 0, last_sent: null, last_error: null, warned: false };
let probe = { proc: null, timer: null };
let spd = { running: false, started_at: null, trigger: null, proc: null, out: null, killed: false,
            idle_rtt: null, loaded_sum: 0, loaded_n: 0, window_end: null,
            cpu_sum: 0, cpu_n: 0, cpu_max: 0, core_max: 0,
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

// Like num() but 0 is a valid value.
function numz(v, def) {
	let n = +v;
	return (v == null || v == '' || n != n) ? def : n;
}

function as_list(v) {
	return v == null ? [] : (type(v) == 'array' ? v : [v]);
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

function find_exe(name) {
	for (let d in ['/usr/bin', '/usr/sbin', '/bin', '/sbin', '/usr/local/bin'])
		if (fs.access(d + '/' + name, 'x'))
			return d + '/' + name;
	return null;
}

function kill_proc(p) {
	if (p)
		system(['kill', '-TERM', '' + p.pid()]);
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
	// timelocal() does not wrap months below 1, so do the year arithmetic here
	let l = localtime(t);
	let idx = l.year * 12 + l.mon - 1 + add_months;
	return timelocal({ year: int(idx / 12), mon: idx % 12 + 1, mday: 1, hour: 0, min: 0, sec: 0, isdst: -1 });
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

// ---------------------------------------------------------------- histogram, cpu

function new_hist() {
	let h = [];
	for (let i = 0; i <= length(HIST_EDGES); i++)
		push(h, 0);
	return h;
}

function hist_bin(rtt) {
	for (let i = 0; i < length(HIST_EDGES); i++)
		if (rtt <= HIST_EDGES[i])
			return i;
	return length(HIST_EDGES);
}

function hist_add(a, b) {
	for (let i = 0; i < length(a); i++)
		a[i] += b[i] ?? 0;
}

// Sum of the histograms of `labels` in bucket m.
function hist_of(m, labels) {
	let h = new_hist();
	for (let label in labels)
		if (m.h?.[label])
			hist_add(h, m.h[label]);
	return h;
}

// Percentile q (0..1) from histogram counts, interpolated linearly inside the bin.
function hist_pct(h, q) {
	let total = 0;
	for (let c in h)
		total += c;
	if (!total)
		return null;
	let rank = q * total, cum = 0;
	for (let i = 0; i < length(h); i++) {
		if (h[i] > 0 && cum + h[i] >= rank) {
			let lo = i ? HIST_EDGES[i - 1] : 0;
			let hi = HIST_EDGES[i] ?? HIST_TOP;
			return rnd(lo + (hi - lo) * (rank - cum) / h[i], 100);
		}
		cum += h[i];
	}
	return HIST_TOP;
}

// "cpu" and "cpuN" lines of /proc/stat -> [{ total, idle }], index 0 = all cores.
function cpu_parse(txt) {
	let out = [];
	for (let line in split(txt ?? '', '\n')) {
		let m = match(line, /^cpu[0-9]* +(.*)$/);
		if (!m)
			continue;
		let f = map(split(trim(m[1]), /\s+/), v => +v);
		let total = 0;
		for (let i = 0; i < 8 && i < length(f); i++)
			total += f[i];
		push(out, { total, idle: (f[3] ?? 0) + (f[4] ?? 0) });
	}
	return out;
}

// Busy % (total and busiest core) between two snapshots; null when they do not compare.
function cpu_busy(prev, cur) {
	if (!length(prev) || length(prev) != length(cur))
		return null;
	let busy = (a, b) => b.total > a.total
		? min(100.0, max(0.0, 100.0 * (1 - (b.idle - a.idle) * 1.0 / (b.total - a.total)))) : 0.0;
	let core_max = 0.0;
	for (let i = 1; i < length(cur); i++)
		core_max = max(core_max, busy(prev[i], cur[i]));
	return { busy: rnd(busy(prev[0], cur[0]), 100), core_max: rnd(core_max, 100) };
}

// Counter delta of the physical device; 0 when the device changed or the counter reset.
function crc_delta(prev, cur) {
	return (prev && cur && prev.dev == cur.dev && cur.v >= prev.v) ? cur.v - prev.v : 0;
}

// ---------------------------------------------------------------- buckets

function new_bucket(t) {
	return { t, rx: 0, tx: 0, rx_peak: 0, tx_peak: 0, err: 0, drop: 0, crc: 0,
	         down_s: 0, wan_down_s: 0, mon_s: 0, st: 0, cpu: [0, 0, 0, 0], dns: [0, 0, 0, 0], p: {}, h: {} };
}

function bucket_at(t) {
	let k = t - t % 60;
	return minutes[k] ??= new_bucket(k);
}

// Add bucket b into a; used for every roll-up and for series down-sampling.
function merge(a, b) {
	for (let k in ['rx', 'tx', 'err', 'drop', 'crc', 'down_s', 'wan_down_s', 'mon_s'])
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
	for (let i in [0, 1])
		a.cpu[i] += b.cpu?.[i] ?? 0;
	for (let i in [2, 3])
		a.cpu[i] = max(a.cpu[i], b.cpu?.[i] ?? 0);
	for (let i in [0, 1, 2])
		a.dns[i] += b.dns?.[i] ?? 0;
	a.dns[3] = max(a.dns[3], b.dns?.[3] ?? 0);
	for (let label, v in b.h ?? {})
		hist_add(a.h[label] ??= new_hist(), v);
	return a;
}

function tidy(row) {
	for (let label, v in row.p) {
		v[2] = rnd(v[2], 1000);
		v[5] = rnd(v[5], 1000);
	}
	row.cpu[0] = rnd(row.cpu[0], 100);
	row.dns[2] = rnd(row.dns[2], 100);
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

// ---------------------------------------------------------------- notifications

const I18N = {
	en: {
		yes: 'yes', no: 'no',
		link: ' The physical link was down as well.',
		causes: { peer_hangup: 'line hang-up (PPPoE)', peer_terminated: 'session terminated by the provider',
		          echo_timeout: 'provider not answering (echo timeout)', local_restart: 'local restart of the connection',
		          auth_failed: 'authentication failed', no_pado: 'no answer from the provider (PADO)',
		          other: 'other', none: 'unknown' },
		restored: 'Connection restored',
		restored_msg: 'Connection restored after %s (%s–%s). Cause: %s. Gateway reachable during the outage: %s.',
		monitor_gap: 'Monitoring gap',
		monitor_gap_msg: 'No data from %s to %s (%s): the router or the service was not running.',
		loss: 'Degraded line',
		loss_msg: 'Packet loss up to %s%% between %s and %s (%s).',
		slow: 'Slow speed test',
		slow_msg: 'Speed test below plan: down %s Mbit/s (%s%% of plan), up %s Mbit/s (%s%%).',
		failed: 'Speed test failed',
		failed_msg: 'The scheduled speed test failed: %s.',
		test: 'Test notification',
		test_msg: 'linequality can reach you.'
	},
	it: {
		yes: 'sì', no: 'no',
		link: ' Anche il collegamento fisico era giù.',
		causes: { peer_hangup: 'caduta della linea (PPPoE)', peer_terminated: 'sessione terminata dal provider',
		          echo_timeout: 'il provider non risponde (echo timeout)', local_restart: 'riavvio locale della connessione',
		          auth_failed: 'autenticazione fallita', no_pado: 'nessuna risposta dal provider (PADO)',
		          other: 'altra', none: 'sconosciuta' },
		restored: 'Connessione ripristinata',
		restored_msg: 'Connessione ripristinata dopo %s (%s–%s). Causa: %s. Gateway raggiungibile durante il disservizio: %s.',
		monitor_gap: 'Monitoraggio interrotto',
		monitor_gap_msg: 'Nessun dato dalle %s alle %s (%s): router o servizio non attivi.',
		loss: 'Linea degradata',
		loss_msg: 'Perdita di pacchetti fino al %s%% tra le %s e le %s (%s).',
		slow: 'Speed test lento',
		slow_msg: 'Speed test sotto il piano: down %s Mbit/s (%s%% del piano), up %s Mbit/s (%s%%).',
		failed: 'Speed test fallito',
		failed_msg: 'Lo speed test pianificato è fallito: %s.',
		test: 'Notifica di prova',
		test_msg: 'linequality riesce a raggiungerti.'
	}
};

const NOTE_TAGS = { restored: 'white_check_mark', monitor_gap: 'warning', loss: 'turtle', slow: 'turtle',
                    failed: 'warning', test: 'information_source' };

function fmt_hm(t) {
	let l = localtime(t);
	return sprintf('%02d:%02d', l.hour, l.min);
}

function fmt_dur(s) {
	s = int(s);
	if (s < 60)
		return sprintf('%d s', s);
	if (s < 3600)
		return sprintf('%d min %d s', int(s / 60), s % 60);
	return sprintf('%d h %d min', int(s / 3600), int(s % 3600 / 60));
}

// Notification text for `kind`; x carries { ev, row, cause, link } depending on the kind.
function build_note(lang, kind, x) {
	let d = I18N[lang] ?? I18N.en;
	let ev = x.ev, row = x.row;
	let a = [];
	switch (kind) {
	case 'restored':
		a = [fmt_dur(ev.duration), fmt_hm(ev.start), fmt_hm(ev.end), d.causes[x.cause ?? 'none'] ?? d.causes.other,
		     ev.detail?.gateway_ok ? d.yes : d.no];
		break;
	case 'monitor_gap':
		a = [fmt_hm(ev.start), fmt_hm(ev.end), fmt_dur(ev.duration)];
		break;
	case 'loss':
		a = [ev.detail?.max_loss_pct, fmt_hm(ev.start), fmt_hm(ev.end), fmt_dur(ev.duration)];
		break;
	case 'slow':
		a = [row.down, row.down_pct ?? '-', row.up, row.up_pct ?? '-'];
		break;
	case 'failed':
		a = [row.error];
		break;
	}
	return {
		kind, title: d[kind], message: sprintf(d[kind + '_msg'], ...a) + (kind == 'restored' && x.link ? d.link : ''),
		tags: NOTE_TAGS[kind], priority: (kind == 'restored' && ev.duration > 600) ? 'high' : 'default',
		data: ev ?? row ?? {}
	};
}

function notify_cmd() {
	if (args.notify_cmd)
		return fs.access(args.notify_cmd, 'x') ? args.notify_cmd : null;
	return find_exe('curl');
}

function notify_headers(n) {
	let h = cfg.notify_type == 'webhook'
		? ['Content-Type: application/json']
		: ['Title: ' + n.title, 'Priority: ' + n.priority, 'Tags: ' + n.tags];
	if (cfg.notify_token)
		push(h, 'Authorization: Bearer ' + cfg.notify_token);
	return h;
}

// The argv curl is started with (the dev flag --notify-cmd replaces only argv[0]).
// Headers come from a file so that the token does not show up in ps.
function notify_argv(hdr, body) {
	return ['-fsS', '-m', '15', '-X', 'POST', '-H', '@' + hdr, '--data-binary', '@' + body, cfg.notify_url];
}

let notify_kick;

function notify_done(code, n, body, hdr, errf) {
	let err = trim(split(fs.readfile(errf) ?? '', '\n')[0] ?? '');
	fs.unlink(body);
	fs.unlink(hdr);
	fs.unlink(errf);
	notes.proc = null;
	if (code == 0) {
		if (notes.queue[0] == n)
			shift(notes.queue);
		notes.last_sent = time();
		notes.last_error = null;
		log('notification sent: ' + n.title);
		notify_kick();
		return;
	}
	notes.last_error = err || sprintf('exit code %d', code);
	notes.next_try = time() + NOTE_RETRY;
	log('notification failed: ' + notes.last_error);
}

// Send the head of the queue unless one is already in flight or a retry is pending.
notify_kick = function() {
	let now = time();
	if (notes.proc || !cfg.notify_url || now < notes.next_try)
		return;
	notes.queue = filter(notes.queue, n => now - n.t <= NOTE_TTL);
	if (!length(notes.queue))
		return;
	let cmd = notify_cmd();
	if (!cmd) {
		if (!notes.warned)
			log('notifications are enabled but curl is not installed');
		notes.warned = true;
		return;
	}
	let n = notes.queue[0];
	let body = sprintf('/tmp/%s-notify.body', args.ubus_name);
	let hdr = sprintf('/tmp/%s-notify.hdr', args.ubus_name);
	let errf = body + '.err';
	let payload = cfg.notify_type == 'webhook'
		? sprintf('%J', { event: n.kind, title: n.title, message: n.message, data: n.data }) : n.message;
	fs.writefile(body, payload);
	fs.writefile(hdr, '');
	fs.chmod(hdr, 0o600);
	fs.writefile(hdr, join('\n', notify_headers(n)) + '\n');
	notes.proc = uloop.process('/bin/sh', ['-c', 'err=$1; shift; exec "$@" >/dev/null 2>"$err"', 'sh', errf, cmd, ...notify_argv(hdr, body)],
		null, guard(code => notify_done(code, n, body, hdr, errf), 'notify'));
	if (!notes.proc) {
		notes.next_try = now + NOTE_RETRY;
		fs.unlink(body);
		fs.unlink(hdr);
	}
};

function notify_push(note) {
	if (!cfg.notify_url)
		return;
	push(notes.queue, { ...note, t: time() });
	while (length(notes.queue) > NOTE_MAX)
		shift(notes.queue);
	notify_kick();
}

function overlapping(type, ev) {
	for (let o in [...events.rows, ...values(open)])
		if (o.type == type && o.start <= ev.end + 60 && (o.end ?? FOREVER) >= ev.start - 60)
			return o;
	return null;
}

// Called once an event is final (closed and, if it has one, traced).
function notify_event(ev) {
	if (!cfg.notify_url)
		return;
	if (ev.type == 'internet_down' && ev.duration >= cfg.notify_min_outage)
		notify_push(build_note(cfg.notify_language, 'restored',
			{ ev, cause: overlapping('wan_down', ev)?.detail?.cause, link: overlapping('link_down', ev) != null }));
	else if (ev.type == 'monitor_gap' && cfg.notify_gap)
		notify_push(build_note(cfg.notify_language, 'monitor_gap', { ev }));
	else if (ev.type == 'loss' && cfg.notify_loss)
		notify_push(build_note(cfg.notify_language, 'loss', { ev }));
}

function notify_speedtest(row) {
	let thr = cfg.notify_speed_pct;
	if (!cfg.notify_url || !(thr > 0))
		return;
	if (!row.ok && row.trigger == 'schedule')
		notify_push(build_note(cfg.notify_language, 'failed', { row }));
	else if (row.ok && ((row.down_pct ?? 100) < thr || (row.up_pct ?? 100) < thr))
		notify_push(build_note(cfg.notify_language, 'slow', { row }));
}

// ---------------------------------------------------------------- events

function ref_labels() {
	let refs = filter(cfg.targets, t => t != 'gateway');
	return length(refs) ? refs : ['gateway'];
}

function open_event(type, start, detail) {
	let ev = { id: type + '-' + start, type, start, end: null, duration: null, detail: detail ?? {} };
	open[type] = ev;
	log(sprintf('event %s opened', ev.id));
	return ev;
}

function commit_event(ev) {
	store_add(events, ev);
	notify_event(ev);
}

function finish_event(ev, end, extra) {
	ev.end = end;
	ev.duration = end - ev.start;
	for (let k, v in extra ?? {})
		ev.detail[k] = v;
	log(sprintf('event %s closed after %ds', ev.id, ev.duration));
	if (trace.proc && trace.ev == ev)
		trace.closing = true;   // stored when the trace ends
	else
		commit_event(ev);
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

// Hops of a busybox traceroute -n output.
function parse_trace(txt) {
	let hops = [];
	for (let line in split(txt ?? '', '\n')) {
		let m = match(line, /^ *([0-9]+) +(.*)$/);
		if (!m)
			continue;
		let ip = match(m[2], /^([0-9a-fA-F:.]+)( |$)/)?.[1];
		let rtt = match(m[2], /([0-9.]+) ms/)?.[1];
		push(hops, { hop: +m[1], ip: ip ?? null, rtt: rtt == null ? null : +rtt * 1.0 });
	}
	return hops;
}

function trace_done(code) {
	trace.watchdog?.cancel();
	let hops = parse_trace(fs.readfile(trace.out));
	fs.unlink(trace.out);
	let ev = trace.ev;
	trace.proc = null;
	trace.ev = null;
	if (length(hops))
		ev.detail.trace = hops;
	if (trace.closing) {
		trace.closing = false;
		commit_event(ev);
	}
}

// Trace the path to the first reference target for a new event (at most one per TRACE_GAP).
function trace_start(ev) {
	let now = time();
	let host = targets[ref_labels()[0]]?.host;
	if (trace.proc || !host || now - trace.last_at < TRACE_GAP)
		return;
	let out = sprintf('/tmp/%s-trace.out', args.ubus_name);
	let cmd = sprintf('exec %s -n -q 1 -w 1 -m 12 %s >%s 2>&1',
	                  index(host, ':') >= 0 ? 'traceroute6' : 'traceroute', shq(host), shq(out));
	trace.proc = uloop.process('/bin/sh', ['-c', cmd], null, guard(trace_done, 'trace'));
	if (!trace.proc)
		return;
	trace.last_at = now;
	trace.out = out;
	trace.ev = ev;
	trace.closing = false;
	trace.watchdog = uloop.timer(TRACE_MAX * 1000, guard(() => kill_proc(trace.proc), 'trace'));
}

// pppd lines (from `pppd[` on) out of a syslog dump.
function pppd_extract(txt) {
	let out = [];
	for (let line in split(txt ?? '', '\n')) {
		let i = index(line, 'pppd[');
		if (i >= 0)
			push(out, substr(line, i, 160));
	}
	return out;
}

const CAUSES = [
	[/Modem hangup/, 'peer_hangup'],
	[/LCP terminated by peer/, 'peer_terminated'],
	[/No response to [0-9]+ echo-requests/, 'echo_timeout'],
	[/Terminating on signal/, 'local_restart'],
	[/(CHAP|PAP) authentication failed/, 'auth_failed'],
	[/Timeout waiting for PADO packets|Unable to complete PPPoE Discovery/, 'no_pado']
];

// The last matching line decides; 'other' when pppd said something else, null when it said nothing.
function classify_cause(lines) {
	let cause = null;
	for (let l in lines)
		for (let c in CAUSES)
			if (match(l, c[0]))
				cause = c[1];
	return cause ?? (length(lines) ? 'other' : null);
}

// detail fields (cause + recent pppd lines) for a wan_down that just ended.
function cause_detail(proto) {
	if (proto != 'pppoe')
		return { cause: null };
	let p = fs.popen('logread -l 400 2>/dev/null', 'r');
	let txt = p?.read('all');
	p?.close();
	let lines = pppd_extract(txt);
	let d = { cause: classify_cause(lines) };
	if (length(lines))
		d.log = slice(lines, max(0, length(lines) - 6));
	return d;
}

function add_seconds(field, t, n) {
	for (let i = 0; i < n; i++)
		bucket_at(t + i)[field]++;
}

// Disconnections (internet_down + wan_down) starting in [from, to): count, those >= 60 s, longest.
function outage_stats(evs, from, to, now) {
	let o = { outages: 0, outages_1m: 0, longest_s: 0 };
	for (let ev in evs) {
		if (ev.start < from || ev.start >= to || (ev.type != 'internet_down' && ev.type != 'wan_down'))
			continue;
		let dur = ev.duration ?? max(0, now - ev.start);
		o.outages++;
		if (dur >= 60)
			o.outages_1m++;
		o.longest_s = max(o.longest_s, dur);
	}
	return o;
}

function count_disconnects(from) {
	return outage_stats([...events.rows, ...values(open)], from, FOREVER, time()).outages;
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

function ip_change(family, old, cur, t) {
	log(sprintf('%s changed %s -> %s', family, old, cur));
	add_closed('ip_change', t, t, { family, old, 'new': cur });
}

function track_link_events(up, uptime, ip, carrier, now) {
	let ipchg = (ip && last_ip && ip != last_ip) ? { old_ip: last_ip, new_ip: ip } : null;

	if (up && iface.up && iface.uptime != null && uptime < iface.uptime) {
		// session restarted between two polls: record the outage we missed
		let end = max(now - uptime, iface.at);
		add_closed('wan_down', iface.at, end, { ...(ipchg ?? {}), ...cause_detail(iface.proto) });
		add_seconds('wan_down_s', iface.at, end - iface.at);
	}
	else if (!up && !open.wan_down)
		open_event('wan_down', now);
	else if (up && open.wan_down)
		close_event('wan_down', now, { ...(ipchg ?? {}), ...cause_detail(iface.proto) });

	if (ipchg)
		ip_change('ipv4', last_ip, ip, now);

	if (carrier == false && !open.link_down)
		open_event('link_down', now);
	else if (carrier == true && open.link_down)
		close_event('link_down', now);
}

// The device CRC errors are counted on: the lower device of a VLAN, else the device itself.
function phys_device(dev) {
	if (!dev)
		return null;
	for (let f in fs.lsdir('/sys/class/net/' + dev) ?? [])
		if (index(f, 'lower_') == 0)
			return substr(f, 6);
	return dev;
}

function apply_iface(r, carrier, now) {
	let up = r?.up == true;
	let uptime = up ? (r.uptime ?? 0) : 0;
	let ip = r?.['ipv4-address']?.[0]?.address;
	if (synced(now))
		track_link_events(up, uptime, ip, carrier, now);
	if (ip)
		last_ip = ip;
	iface = { up, uptime, at: now, l3_device: r?.l3_device, device: r?.device, phys: phys_device(r?.device),
	          proto: r?.proto ?? iface.proto, carrier, ipv4: ip ?? null, gateway: up ? find_gateway(r) : null };
}

function read_carrier(dev) {
	let v = dev ? trim(fs.readfile('/sys/class/net/' + dev + '/carrier') ?? '') : '';
	return v == '1' ? true : v == '0' ? false : null;
}

function poll() {
	let r = conn.call('network.interface.' + cfg.interface, 'status');
	apply_iface(r, read_carrier(r?.device), time());
}

// Delegated IPv6 prefix; a change is an ip_change event.
function poll6() {
	let r = conn.call('network.interface.' + cfg.interface6, 'status');
	let p = r?.['ipv6-prefix']?.[0];
	prefix6 = p?.address ? sprintf('%s/%d', p.address, p.mask) : null;
	if (!prefix6)
		return;
	if (last_prefix && prefix6 != last_prefix && synced())
		ip_change('ipv6-prefix', last_prefix, prefix6, time());
	last_prefix = prefix6;
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

function read_crc(dev) {
	let v = fs.readfile(sprintf('/sys/class/net/%s/statistics/rx_crc_errors', dev));
	return v == null ? null : { dev, v: +v };
}

// Add this second's CPU load to the bucket (and to the running speed test).
function cpu_account(b, cpu) {
	traffic.cpu = cpu;
	b.cpu[0] += cpu.busy;
	b.cpu[1]++;
	b.cpu[2] = max(b.cpu[2], cpu.busy);
	b.cpu[3] = max(b.cpu[3], cpu.core_max);
	if (spd.running) {
		spd.cpu_sum += cpu.busy;
		spd.cpu_n++;
		spd.cpu_max = max(spd.cpu_max, cpu.busy);
		spd.core_max = max(spd.core_max, cpu.core_max);
	}
}

function tick() {
	let m = clock(true);
	let mono = m[0] + m[1] / 1e9;
	let dt = traffic.mono != null ? mono - traffic.mono : null;
	traffic.mono = mono;
	let cur = iface.l3_device ? read_counters(iface.l3_device) : null;
	let prev = traffic.prev;
	traffic.prev = cur;
	let crc = iface.phys ? read_crc(iface.phys) : null;
	let crc_prev = traffic.crc_prev;
	traffic.crc_prev = crc;
	let snap = cpu_parse(fs.readfile('/proc/stat'));
	let cpu = cpu_busy(traffic.cpu_prev, snap);
	traffic.cpu_prev = snap;
	if (dt == null || !synced())
		return;

	let secs = min(max(int(dt + 0.5), 1), 5);
	let d = counter_deltas(prev, cur);
	let b = bucket_at(time());
	b.rx += d.rx_bytes;
	b.tx += d.tx_bytes;
	b.err += d.rx_errors + d.tx_errors;
	b.drop += d.rx_dropped + d.tx_dropped;
	b.crc += crc_delta(crc_prev, crc);
	b.mon_s += secs;
	if (cpu)
		cpu_account(b, cpu);
	traffic.rx_bps = int(d.rx_bytes * 8.0 / dt);
	traffic.tx_bps = int(d.tx_bytes * 8.0 / dt);
	b.rx_peak = max(b.rx_peak, traffic.rx_bps);
	b.tx_peak = max(b.tx_peak, traffic.tx_bps);
	if (open.wan_down)
		b.wan_down_s += secs;
	if (spd.running)
		b.st = 1;
}

// ---------------------------------------------------------------- dns

function dns_done(t, code) {
	dns.watchdog?.cancel();
	let m = clock(true);
	let ms = rnd((m[0] + m[1] / 1e9 - dns.mono) * 1000, 100);
	let ok = code == 0 && !dns.killed;
	dns.proc = null;
	dns.last_ms = ok ? ms : null;
	dns.ok_last = ok;
	if (!synced(t))
		return;
	let d = bucket_at(t).dns;
	d[0]++;
	if (ok) {
		d[1]++;
		d[2] += ms;
		d[3] = max(d[3], ms);
	}
}

// One lookup, round-robin over the configured names, never overlapping.
function dns_probe() {
	if (!cfg.dns_server || !length(cfg.dns_names) || dns.proc || !synced())
		return;
	let name = cfg.dns_names[dns.idx++ % length(cfg.dns_names)];
	let t = time();
	let m = clock(true);
	dns.mono = m[0] + m[1] / 1e9;
	dns.killed = false;
	dns.proc = uloop.process('/bin/sh', ['-c', sprintf('exec nslookup %s %s >/dev/null 2>&1', shq(name), shq(cfg.dns_server))],
		null, guard(code => dns_done(t, code), 'dns'));
	if (dns.proc)
		dns.watchdog = uloop.timer(5000, guard(() => {
			dns.killed = true;
			kill_proc(dns.proc);
		}, 'dns'));
}

// ---------------------------------------------------------------- probes

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
	notify_speedtest(row);
	log(sprintf('speed test finished: ok=%s down=%s up=%s', row.ok, row.down, row.up));
}

function account(t, label, rtt) {
	let p = bucket_at(t).p[label] ??= NEW_PROBE();
	let tg = targets[label] ??= { last: null, prev: null, host: null };
	p[0]++;
	tg.last = rtt;
	if (rtt == null)
		return;
	(bucket_at(t).h[label] ??= new_hist())[hist_bin(rtt)]++;
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
		trace_start(open_event('internet_down', run.times[0], { gateway_ok: run.gw, wan_up: iface.up == true }));
		for (let tt in run.times)
			add_seconds('down_s', tt, 1);
		run.times = [];
		loss.win = [];
	}
}

// One evaluation of the 60-s loss: 'open', 'close' or null. ls keeps the worst loss seen and,
// on 'close', the time the event ended (loss back under the threshold, or the outage start).
function loss_step(ls, t, loss_pct, thr, is_open, down) {
	if (down) {
		ls.end = t;
		return is_open ? 'close' : null;
	}
	if (loss_pct > thr) {
		ls.low_since = null;
		ls.max = is_open ? max(ls.max, loss_pct) : loss_pct;
		return is_open ? null : 'open';
	}
	if (!is_open)
		return null;
	ls.low_since ??= t;
	if (t - ls.low_since < 60)
		return null;
	ls.end = ls.low_since;
	ls.low_since = null;
	return 'close';
}

function loss_feed(t, sent, recv) {
	push(loss.win, [t, sent, recv]);
	while (length(loss.win) && loss.win[0][0] <= t - 60)
		shift(loss.win);
}

// After a batch: open/close the 'loss' event from the last 60 s on the reference targets.
function loss_check(t) {
	let sent = 0, recv = 0;
	for (let w in loss.win) {
		sent += w[1];
		recv += w[2];
	}
	let lp = sent ? 100.0 * (sent - recv) / sent : 0;
	let act = loss_step(loss, t, lp, cfg.loss_threshold, open.loss != null, open.internet_down != null);
	if (act == 'open')
		trace_start(open_event('loss', t, { max_loss_pct: rnd(loss.max, 10), speedtest: spd.running || spd.pending != null }));
	else if (open.loss) {
		open.loss.detail.max_loss_pct = max(open.loss.detail.max_loss_pct ?? 0, rnd(loss.max, 10));
		if (spd.running || spd.pending)
			open.loss.detail.speedtest = true;
		if (act == 'close')
			close_event('loss', loss.end);
	}
}

function process_batch(start, list, txt) {
	if (!synced(start))
		return;
	let res = parse_fping(txt);
	let refs = ref_labels();
	for (let i = 0; i < PROBES; i++) {
		let t = start + i;
		let have_ref = false, ref_ok = false, gw = null, rs = 0, rr = 0;
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
			rs++;
			if (rtt != null) {
				ref_ok = true;
				rr++;
				if ((spd.running || spd.pending) && t >= spd.started_at && (spd.window_end == null || t <= spd.window_end)) {
					spd.loaded_sum += rtt;
					spd.loaded_n++;
				}
			}
		}
		if (!have_ref)
			continue;
		run_probe(t, ref_ok, gw);
		if (!open.internet_down)
			loss_feed(t, rs, rr);
	}
	loss_check(start + PROBES - 1);
	if (spd.pending)
		finish_speedtest();
}

let probe_next;

function probe_retry(ms) {
	probe.timer = uloop.timer(ms, guard(probe_next, 'probe'));
}

function probe_done(start, list, file) {
	probe.proc = null;
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
	return find_exe('librespeed-cli');
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

function plan_pct(v, plan) {
	return (plan && v != null) ? rnd(100.0 * v / plan, 10) : null;
}

function speedtest_done(code) {
	let end = time();
	let txt = fs.readfile(spd.out);
	let err = fs.readfile(spd.out + '.err');
	fs.unlink(spd.out);
	fs.unlink(spd.out + '.err');
	spd.watchdog?.cancel();
	spd.proc = null;

	let row = { t: spd.started_at, dur: end - spd.started_at, trigger: spd.trigger, ok: false, error: null,
	            server: null, ping: null, jitter: null, down: null, up: null, bytes_rx: null, bytes_tx: null,
	            idle_rtt: spd.idle_rtt, loaded_rtt: null, cpu_avg: null, cpu_max: null, core_max: null,
	            down_pct: null, up_pct: null };
	let res = code == 0 ? parse_speedtest(txt ?? '') : null;
	if (res) {
		row.ok = true;
		for (let k, v in res)
			row[k] = v;
		row.down_pct = plan_pct(row.down, cfg.plan_down);
		row.up_pct = plan_pct(row.up, cfg.plan_up);
	}
	else
		row.error = spd.killed ? 'timeout' : (split(trim(err ?? ''), '\n')[0] || sprintf('exit code %d', code));

	if (spd.cpu_n) {
		row.cpu_avg = rnd(spd.cpu_sum / spd.cpu_n, 100);
		row.cpu_max = spd.cpu_max;
		row.core_max = spd.core_max;
	}
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
	spd.cpu_sum = 0;
	spd.cpu_n = 0;
	spd.cpu_max = 0;
	spd.core_max = 0;
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

// Metrics of the rows with from <= t < to (reference targets for latency and loss).
function stats_of(rows, from, to) {
	let m = new_bucket(0);
	for (let r in rows)
		if (r.t >= from && r.t < (to ?? FOREVER))
			merge(m, r);
	let sent = 0, recv = 0, rsum = 0, jsum = 0, jn = 0;
	let refs = ref_labels();
	for (let label in refs) {
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
		loss_pct: pct(sent - recv, sent),
		rtt_avg: recv ? rnd(rsum * 1.0 / recv, 100) : null,
		rtt_p95: hist_pct(hist_of(m, refs), 0.95),
		jitter_avg: jn ? rnd(jsum * 1.0 / jn, 100) : null,
		err: m.err, drop: m.drop, crc: m.crc,
		cpu_avg: m.cpu[1] ? rnd(m.cpu[0] / m.cpu[1], 100) : null,
		cpu_max: m.cpu[1] ? m.cpu[2] : null,
		core_max: m.cpu[1] ? m.cpu[3] : null,
		dns_avg_ms: m.dns[1] ? rnd(m.dns[2] / m.dns[1], 100) : null,
		dns_fail_pct: pct(m.dns[0] - m.dns[1], m.dns[0])
	};
}

function summarize(rows, from) {
	let s = stats_of(rows, from);
	s.disconnects = count_disconnects(from);
	return s;
}

function col_avg(rows, k) {
	let v = filter(map(rows, r => r[k]), x => x != null);
	let sum = 0;
	for (let x in v)
		sum += x;
	return length(v) ? rnd(sum / length(v), 100) : null;
}

function col_min(rows, k) {
	let v = filter(map(rows, r => r[k]), x => x != null);
	return length(v) ? min(...v) : null;
}

// One row of the monthly report, from day rows, events and speed tests.
function month_report(rows, evs, tsts, from, to, now) {
	let s = stats_of(rows, from, to);
	let o = outage_stats(evs, from, to, now);
	let l = localtime(from);
	let tr = filter(tsts, r => r.t >= from && r.t < to);
	let oks = filter(tr, r => r.ok);
	let m = { month: sprintf('%04d-%02d', l.year, l.mon) };
	for (let k in ['mon_s', 'down_s', 'uptime_pct'])
		m[k] = s[k];
	m.outages = o.outages;
	m.outages_1m = o.outages_1m;
	m.longest_s = o.longest_s;
	for (let k in ['rx', 'tx', 'rx_peak_bps', 'tx_peak_bps', 'loss_pct', 'rtt_avg', 'rtt_p95', 'jitter_avg',
	               'dns_avg_ms', 'dns_fail_pct', 'err', 'drop', 'crc', 'cpu_avg'])
		m[k] = s[k];
	m.speedtests = { n: length(tr), ok: length(oks),
	                 down_avg: col_avg(oks, 'down'), down_min: col_min(oks, 'down'),
	                 up_avg: col_avg(oks, 'up'), up_min: col_min(oks, 'up'),
	                 down_pct_avg: col_avg(oks, 'down_pct'), up_pct_avg: col_avg(oks, 'up_pct') };
	return m;
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
		let h = new_hist();
		for (let k, m in minutes) {
			let p = m.t >= now - 300 ? m.p[label] : null;
			if (!p)
				continue;
			sent += p[0];
			recv += p[1];
			rsum += p[2];
			jsum += p[5];
			jn += p[6];
			if (m.h?.[label])
				hist_add(h, m.h[label]);
		}
		push(out, { label, host: tg.host ?? null, last_rtt: tg.last ?? null, loss_pct: pct(sent - recv, sent),
		            rtt_avg: recv ? rnd(rsum * 1.0 / recv, 100) : null, p95: hist_pct(h, 0.95),
		            jitter: jn ? rnd(jsum * 1.0 / jn, 100) : null });
	}
	return out;
}

function live_dns(now) {
	let d = [0, 0, 0];
	for (let k, m in minutes)
		if (m.t >= now - 300)
			for (let i in [0, 1, 2])
				d[i] += m.dns[i];
	return { server: cfg.dns_server || null, last_ms: dns.last_ms, ok_last: dns.ok_last,
	         rtt_avg: d[1] ? rnd(d[2] / d[1], 100) : null, fail_pct: pct(d[0] - d[1], d[0]) };
}

// Cause of the most recent wan_down.
function last_cause() {
	let list = [...events.rows, ...values(open)];
	let best = null;
	for (let ev in list)
		if (ev.type == 'wan_down' && (!best || ev.start > best.start))
			best = ev;
	return best?.detail?.cause ?? null;
}

function plan_obj() {
	return (cfg.plan_down || cfg.plan_up) ? { down: cfg.plan_down, up: cfg.plan_up } : null;
}

function api_status() {
	let now = time();
	let l = tests.rows;
	return {
		version: VERSION, now, started,
		tz_offset: timegm(localtime(now)) - now,
		interface: { name: cfg.interface, up: iface.up == true, uptime: iface.uptime ?? 0,
		             l3_device: iface.l3_device ?? null, device: iface.device ?? null,
		             carrier: iface.carrier, ipv4: iface.ipv4, gateway: iface.gateway,
		             ipv6_prefix: prefix6, last_cause: last_cause() },
		live: { rx_bps: traffic.rx_bps, tx_bps: traffic.tx_bps, cpu: traffic.cpu, dns: live_dns(now),
		        targets: live_targets(now) },
		open_events: values(open),
		summary: build_summary(now),
		plan: plan_obj(),
		notify: { enabled: cfg.notify_url != '', available: notify_cmd() != null, queued: length(notes.queue),
		          last_sent: notes.last_sent, last_error: notes.last_error },
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

function api_report(months) {
	let now = time();
	let rows = all_days();
	let evs = [...events.rows, ...values(open)];
	let out = [];
	for (let i = 0; i < months; i++)
		push(out, month_report(rows, evs, tests.rows, month_start(now, -i), month_start(now, 1 - i), now));
	return { plan: plan_obj(), months: out };
}

function api_notify_test() {
	if (!cfg.notify_url)
		return { error: 'disabled' };
	if (!notify_cmd())
		return { error: 'not_available' };
	notify_push(build_note(cfg.notify_language, 'test', {}));
	return { queued: true };
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
		speedtest_run: wrap(a => api_speedtest_run(), {}),
		report: wrap(a => api_report(min(max(int(a.months || 12), 1), 120)), { months: 0 }),
		notify_test: wrap(a => api_notify_test(), {})
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
		case '--notify-cmd': o.notify_cmd = argv[++i]; break;
		case '--plan': o.plan = argv[++i]; break;
		case '--notify-url': o.notify_url = argv[++i]; break;
		case '--notify-type': o.notify_type = argv[++i]; break;
		case '--notify-loss': o.notify_loss = true; break;
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
	let list = length(args.targets) ? args.targets : as_list(s.target);
	let plan = args.plan ? split(args.plan, '/') : [s.plan_down, s.plan_up];
	let iface_name = s.interface || 'wan';
	// IP literals only: a host name would vanish from fping's output while DNS
	// is down, exactly when the outage should be recorded
	list = filter(list ?? [], t => {
		let ok = t == 'gateway' || iptoarr(t) != null;
		if (!ok)
			log(sprintf('ignoring target %s: not an IP address', t));
		return ok;
	});
	cfg = {
		interface: iface_name,
		interface6: s.interface6 || iface_name + '6',
		targets: length(list) ? list : ['gateway', '1.1.1.1', '8.8.8.8'],
		down_after: int(num(s.down_after, 3)),
		data_dir: args.data_dir || s.data_dir || '/etc/linequality',
		hourly_retention_days: int(num(s.hourly_retention_days, 90)),
		daily_retention_days: int(num(s.daily_retention_days, 1095)),
		schedule: filter(split(trim(s.speedtest_schedule ?? ''), /\s+/), t => match(t, /^([01][0-9]|2[0-3]):[0-5][0-9]$/)),
		speedtest_duration: int(num(s.speedtest_duration, 10)),
		speedtest_concurrent: int(num(s.speedtest_concurrent, 3)),
		speedtest_server: s.speedtest_server || '',
		loss_threshold: numz(s.loss_threshold, 5),
		dns_server: s.dns_enabled == '0' ? '' : (s.dns_server ?? '127.0.0.1'),
		dns_names: s.dns_name != null ? as_list(s.dns_name) : ['openwrt.org', 'wikipedia.org', 'example.com'],
		dns_interval: int(num(s.dns_interval, 30)),
		plan_down: num(plan[0], null),
		plan_up: num(plan[1], null),
		notify_url: args.notify_url || s.notify_url || '',
		notify_type: (args.notify_type || s.notify_type) == 'webhook' ? 'webhook' : 'ntfy',
		notify_token: s.notify_token || '',
		notify_language: s.notify_language == 'it' ? 'it' : 'en',
		notify_min_outage: numz(s.notify_min_outage, 60),
		notify_loss: args.notify_loss || s.notify_loss == '1',
		notify_speed_pct: numz(s.notify_speed_pct, 0),
		notify_gap: s.notify_gap != '0'
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
	// merge into a fresh bucket: older versions saved buckets without the newer fields
	for (let m in s.minutes ?? [])
		minutes[m.t] = merge(new_bucket(m.t), m);
	for (let ev in s.open ?? [])
		open[ev.type] = ev;
	spd.last_slot = s.last_speedtest_slot ?? null;
	last_ip = s.last_ip ?? null;
	last_prefix = s.last_prefix ?? null;
	notes.queue = s.notify_queue ?? [];
	if (open.internet_down)
		run = { n: cfg.down_after, times: [], gw: open.internet_down.detail?.gateway_ok };
}

function save_state() {
	let s = { version: 1, saved_at: time(), minutes: values(minutes), open: values(open),
	          last_speedtest_slot: spd.last_slot, last_ip, last_prefix, notify_queue: notes.queue };
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
	if (trace.closing)
		commit_event(trace.ev);
	save_state();
	for (let p in [probe.proc, spd.proc, dns.proc, trace.proc, notes.proc])
		kill_proc(p);
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
		uloop.interval(60000, guard(poll6, 'poll6')),
		uloop.interval(cfg.dns_interval * 1000, guard(dns_probe, 'dns')),
		uloop.interval(15000, guard(notify_kick, 'notify')),
		retention_timer,
		uloop.signal('SIGTERM', guard(shutdown, 'shutdown')),
		uloop.signal('SIGINT', guard(shutdown, 'shutdown')));

	guard(poll, 'poll')();
	guard(poll6, 'poll6')();
	probe_next();
	log(sprintf('linequalityd %s started, data in %s', VERSION, cfg.data_dir));
	uloop.run();
}

// ---------------------------------------------------------------- self test

// Pure-function tests of the 0.2 additions.
function selftest_v02(check, mk, T) {
	let near = (a, b) => a != null && absdiff(a, b) < 0.011;
	let hist = (...c) => { let h = new_hist(); for (let i = 0; i < length(c); i++) h[i] = c[i]; return h; };

	// histogram
	check('hist bins', hist_bin(0.5) == 0 && hist_bin(1) == 0 && hist_bin(1.01) == 1 && hist_bin(400) == 16 && hist_bin(400.5) == 17);
	check('hist 18 bins', length(new_hist()) == 18);
	check('hist p50 first bin', near(hist_pct(hist(10, 10), 0.5), 1.0));
	check('hist p75 interpolates', near(hist_pct(hist(10, 10), 0.75), 1.5));
	check('hist last bin uses 800', near(hist_pct(hist(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4), 0.5), 600));
	check('hist empty', hist_pct(new_hist(), 0.95) == null);

	// merge of the new fields
	let a = new_bucket(0), b = new_bucket(60);
	b.crc = 3;
	b.cpu = [10.0, 2, 8.0, 6.0];
	b.dns = [2, 1, 30.0, 30.0];
	b.h.x = hist(1, 2);
	merge(a, b);
	b.cpu = [4.0, 1, 9.0, 3.0];
	b.dns = [1, 1, 5.0, 5.0];
	merge(a, b);
	check('merge crc', a.crc == 6);
	check('merge cpu', a.cpu[0] == 14 && a.cpu[1] == 3 && a.cpu[2] == 9 && a.cpu[3] == 6);
	check('merge dns', a.dns[0] == 3 && a.dns[1] == 2 && a.dns[2] == 35 && a.dns[3] == 30);
	check('merge hist', a.h.x[0] == 2 && a.h.x[1] == 4 && b.h.x[0] == 1);
	merge(a, { t: 0, p: {} });
	check('merge old row without new fields', a.crc == 6 && a.cpu[1] == 3);

	// cpu busy from two /proc/stat snapshots
	let s1 = cpu_parse('cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0\nintr 1 2 3\n');
	let s2 = cpu_parse('cpu  150 0 150 850 50 0 0 0 0 0\ncpu0 90 0 90 420 0 0 0 0 0 0\ncpu1 60 0 60 430 50 0 0 0 0 0\nintr 4 5 6\n');
	let cb = cpu_busy(s1, s2);
	check('cpu parse', length(s1) == 3 && s1[0].total == 1000 && s1[0].idle == 800);
	check('cpu busy', near(cb?.busy, 50) && near(cb?.core_max, 80));
	check('cpu no change', cpu_busy(s1, s1)?.busy == 0);
	check('cpu mismatch', cpu_busy(s1, s2[0]) == null && cpu_busy(null, s2) == null);
	check('crc delta', crc_delta({ dev: 'a', v: 5 }, { dev: 'a', v: 9 }) == 4 && crc_delta({ dev: 'a', v: 5 }, { dev: 'b', v: 9 }) == 0
	      && crc_delta({ dev: 'a', v: 5 }, { dev: 'a', v: 2 }) == 0 && crc_delta(null, { dev: 'a', v: 2 }) == 0);

	// logread cause classification
	let ts = 'Tue Oct 20 12:00:01 2026 daemon.info ';
	let lines = (...l) => pppd_extract(join('\n', map(l, x => ts + x)));
	check('pppd extract', length(lines('pppd[1]: Modem hangup', 'netifd: foo', 'pppd[1]: Connection terminated.')) == 2
	      && index(lines('pppd[1]: Modem hangup')[0], 'pppd[') == 0);
	check('pppd line truncated', length(pppd_extract('x pppd[1]: ' + join('', map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20], () => 'abcdefghij')))[0]) == 160);
	check('cause hangup', classify_cause(lines('pppd[1]: Modem hangup', 'pppd[1]: Connection terminated.')) == 'peer_hangup');
	check('cause terminated', classify_cause(lines('pppd[1]: LCP terminated by peer (x)')) == 'peer_terminated');
	check('cause echo then signal: last wins', classify_cause(lines('pppd[1]: No response to 5 echo-requests', 'pppd[1]: Terminating on signal 15')) == 'local_restart');
	check('cause echo', classify_cause(lines('pppd[1]: No response to 5 echo-requests', 'pppd[1]: Serial link appears to be disconnected.')) == 'echo_timeout');
	check('cause auth', classify_cause(lines('pppd[1]: CHAP authentication failed')) == 'auth_failed' && classify_cause(lines('pppd[1]: PAP authentication failed')) == 'auth_failed');
	check('cause pado', classify_cause(lines('pppd[1]: Timeout waiting for PADO packets')) == 'no_pado'
	      && classify_cause(lines('pppd[1]: Unable to complete PPPoE Discovery')) == 'no_pado');
	check('cause other / none', classify_cause(lines('pppd[1]: Connect: pppoe-wan <--> eth4')) == 'other' && classify_cause([]) == null);
	check('cause not pppoe', cause_detail('dhcp').cause == null && !('log' in cause_detail('dhcp')));

	// traceroute parsing
	let hops = parse_trace('traceroute to 1.1.1.1 (1.1.1.1), 12 hops max, 38 byte packets\n 1  217.61.32.1  2.794 ms\n 2  10.1.1.1  3.5 ms\n 3  *\n 4  1.1.1.1  9.1 ms\n');
	check('trace hops', length(hops) == 4 && hops[0].hop == 1 && hops[0].ip == '217.61.32.1' && hops[0].rtt == 2.794
	      && hops[2].ip == null && hops[2].rtt == null && hops[3].ip == '1.1.1.1');
	check('trace v6 and empty', parse_trace(' 1  2001:db8::1  1.5 ms\n')[0].ip == '2001:db8::1' && length(parse_trace('traceroute: bad address\n')) == 0);

	// loss window logic
	let ls = { win: [], low_since: null, max: 0, end: null };
	check('loss opens', loss_step(ls, 0, 10, 5, false, false) == 'open' && ls.max == 10);
	check('loss stays open', loss_step(ls, 10, 20, 5, true, false) == null && ls.max == 20);
	check('loss low starts timer', loss_step(ls, 20, 2, 5, true, false) == null && ls.low_since == 20);
	check('loss glitch resets timer', loss_step(ls, 30, 9, 5, true, false) == null && ls.low_since == null);
	loss_step(ls, 40, 2, 5, true, false);
	check('loss not closed before 60 s', loss_step(ls, 99, 1, 5, true, false) == null);
	check('loss closes after 60 s', loss_step(ls, 100, 1, 5, true, false) == 'close' && ls.end == 40);
	check('loss closes on outage', loss_step(ls, 200, 100, 5, true, true) == 'close' && ls.end == 200);
	check('loss ignored during outage', loss_step(ls, 210, 100, 5, false, true) == null);
	loss.win = [];
	for (let i = 0; i < 70; i++)
		loss_feed(i, 2, 1);
	check('loss window keeps 60 s', length(loss.win) == 60);

	// loss event through the batch processor: one reference answers, the other never does
	cfg.targets = ['1.1.1.1', '8.8.8.8'];
	minutes = {};
	open = {};
	loss = { win: [], low_since: null, max: 0, end: null };
	let L = [{ label: '1.1.1.1', host: '1.1.1.1' }, { label: '8.8.8.8', host: '8.8.8.8' }];
	let good = '1.1.1.1 : 5 5 5 5 5 5 5 5 5 5\n8.8.8.8 : 6 6 6 6 6 6 6 6 6 6\n';
	let half = '1.1.1.1 : 5 5 5 5 5 5 5 5 5 5\n8.8.8.8 : - - - - - - - - - -\n';
	let nev = length(events.rows);
	process_batch(T, L, half);
	check('loss event opens', open.loss != null && !open.internet_down && open.loss.detail.max_loss_pct == 50);
	for (let i = 1; i <= 14; i++)
		process_batch(T + i * 10, L, good);
	check('loss event closes', !open.loss && length(events.rows) == nev + 1 && events.rows[nev].type == 'loss' && events.rows[nev].duration >= 60);
	let ok_hist = true;
	for (let k, m in minutes)
		for (let label, p in m.p) {
			let n = 0;
			for (let c in m.h[label] ?? [])
				n += c;
			ok_hist = ok_hist && n == p[1];
		}
	check('hist counts equal replies', ok_hist && length(keys(minutes)) > 0);
	cfg.targets = ['gateway', '1.1.1.1', '8.8.8.8'];

	// notification text
	let ev = { type: 'internet_down', start: T, end: T + 692, duration: 692, detail: { gateway_ok: false } };
	let en = build_note('en', 'restored', { ev, cause: 'peer_hangup', link: false });
	check('note en', en.message == sprintf('Connection restored after 11 min 32 s (%s–%s). Cause: line hang-up (PPPoE). Gateway reachable during the outage: no.', fmt_hm(T), fmt_hm(T + 692))
	      && en.title == 'Connection restored' && en.priority == 'high' && en.tags == 'white_check_mark');
	let it = build_note('it', 'restored', { ev: { ...ev, duration: 300, end: T + 300, detail: { gateway_ok: true } }, cause: null, link: true });
	check('note it', index(it.message, 'Connessione ripristinata dopo 5 min 0 s') == 0 && index(it.message, 'Causa: sconosciuta') > 0
	      && index(it.message, 'sì') > 0 && index(it.message, 'collegamento fisico') > 0 && it.priority == 'default');
	check('note fallback language', build_note('xx', 'test', {}).title == 'Test notification');
	check('note gap/loss', index(build_note('en', 'monitor_gap', { ev: { start: T, end: T + 3600, duration: 3600 } }).message, '(1 h 0 min)') > 0
	      && index(build_note('it', 'loss', { ev: { start: T, end: T + 90, duration: 90, detail: { max_loss_pct: 12.5 } } }).message, 'fino al 12.5%') > 0);
	check('note speed', index(build_note('en', 'slow', { row: { down: 50, down_pct: 50, up: 10, up_pct: null } }).message, 'down 50 Mbit/s (50% of plan), up 10 Mbit/s (-%)') > 0
	      && index(build_note('en', 'failed', { row: { error: 'timeout' } }).message, 'failed: timeout') > 0);
	cfg.notify_url = 'https://ntfy.example/topic';
	cfg.notify_token = 'tk';
	let hv = notify_headers(en);
	let av = notify_argv('/tmp/h', '/tmp/b');
	check('ntfy headers', 'Title: Connection restored' in hv && 'Priority: high' in hv && 'Tags: white_check_mark' in hv
	      && 'Authorization: Bearer tk' in hv);
	check('curl argv', '@/tmp/h' in av && '@/tmp/b' in av && av[length(av) - 1] == cfg.notify_url
	      && length(filter(av, x => index(x, 'tk') >= 0)) == 0);
	cfg.notify_type = 'webhook';
	hv = notify_headers(en);
	check('webhook headers', 'Content-Type: application/json' in hv && !('Title: Connection restored' in hv));
	cfg.notify_url = '';
	cfg.notify_token = '';
	cfg.notify_type = 'ntfy';

	let v01 = { t: 60, rx: 5, tx: 6, rx_peak: 7, tx_peak: 8, err: 1, drop: 2, down_s: 3, wan_down_s: 4, mon_s: 60, st: 0,
	            p: { gateway: [60, 59, 120, 1, 3, 10, 58] } };
	let up = merge(new_bucket(v01.t), v01);
	check('v0.1 bucket upgrade', up.rx == 5 && up.mon_s == 60 && up.crc == 0 && length(up.cpu) == 4 && length(up.dns) == 4
	      && up.p.gateway[1] == 59 && up.p.gateway[3] == 1 && type(up.h) == 'object');

	// speed-test additions
	check('plan pct', plan_pct(90, 100) == 90 && plan_pct(33.3, 100) == 33.3 && plan_pct(90, null) == null && plan_pct(null, 100) == null);

	// report: two day rows in the month, one outside; events and speed tests likewise
	cfg.targets = ['1.1.1.1'];
	let from = month_start(T, 0), to = month_start(T, 1);
	check('month_start negative', month_start(T, -13) < month_start(T, -12) && month_start(T, -1) < from);
	let day = t => {
		let r = mk(t, 1000, 7, { '1.1.1.1': [100, 90, 900.0, 5.0, 50.0, 10.0, 50] });
		r.mon_s = 86400;
		r.down_s = 600;
		r.crc = 2;
		r.err = 1;
		r.cpu = [100.0, 2, 80.0, 60.0];
		r.dns = [10, 9, 90.0, 20.0];
		r.h['1.1.1.1'] = hist(0, 0, 90);
		return r;
	};
	let drows = [day(from - 86400), day(from), day(from + 86400)];
	let evs = [
		{ type: 'internet_down', start: from + 100, duration: 120 }, { type: 'wan_down', start: from + 200, duration: 30 },
		{ type: 'link_down', start: from + 300, duration: 500 }, { type: 'internet_down', start: from - 10, duration: 999 },
		{ type: 'internet_down', start: from + 5000, duration: null }
	];
	let tst = [
		{ t: from + 10, ok: true, down: 90, up: 9, down_pct: 90, up_pct: 90 }, { t: from + 20, ok: true, down: 70, up: 7, down_pct: 70, up_pct: null },
		{ t: from + 30, ok: false }, { t: from - 5, ok: true, down: 1, up: 1 }
	];
	let m = month_report(drows, evs, tst, from, to, from + 5100);
	check('report month key', m.month == substr(date_str(from), 0, 7));
	check('report availability', m.mon_s == 172800 && m.down_s == 1200 && near(m.uptime_pct, 99.31));
	check('report outages', m.outages == 3 && m.outages_1m == 2 && m.longest_s == 120);
	check('report traffic/errors', m.rx == 2000 && m.rx_peak_bps == 7 && m.crc == 4 && m.err == 2 && near(m.cpu_avg, 50));
	check('report quality', near(m.loss_pct, 10) && near(m.rtt_avg, 10) && near(m.rtt_p95, 2.95) && near(m.dns_avg_ms, 10) && near(m.dns_fail_pct, 10));
	check('report speedtests', m.speedtests.n == 3 && m.speedtests.ok == 2 && m.speedtests.down_avg == 80 && m.speedtests.down_min == 70
	      && m.speedtests.up_min == 7 && m.speedtests.down_pct_avg == 80 && m.speedtests.up_pct_avg == 90);
	let empty = month_report([], [], [], from, to, T);
	check('report empty month', empty.uptime_pct == null && empty.outages == 0 && empty.speedtests.down_avg == null && empty.rtt_p95 == null);
}

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
	        daily_retention_days: 1095, schedule: [], loss_threshold: 5, notify_url: '', notify_type: 'ntfy',
	        notify_token: '', notify_language: 'en', notify_min_outage: 60, notify_loss: false, notify_gap: true };
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
	check('ip_change event', events.rows[2].type == 'ip_change' && events.rows[2].duration == 0 && events.rows[2].detail.family == 'ipv4' && events.rows[2].detail.old == '1.2.3.4' && events.rows[2].detail['new'] == '5.6.7.8');
	apply_iface(up(8, '5.6.7.8'), false, T + 35);
	check('link_down opens', open.link_down != null);
	apply_iface(up(13, '5.6.7.8'), true, T + 40);
	check('link_down closes', !open.link_down && events.rows[3].type == 'link_down');

	run = { n: 0, times: [], gw: null };
	run_probe(T, true, true);
	run_probe(T + 1, false, true);
	run_probe(T + 2, false, false);
	check('no event below down_after', !open.internet_down);
	run_probe(T + 3, false, false);
	check('internet_down opens at first lost probe', open.internet_down?.start == T + 1 && open.internet_down.detail.gateway_ok == true);
	run_probe(T + 4, false, false);
	run_probe(T + 5, true, true);
	check('internet_down closes', !open.internet_down && events.rows[4].type == 'internet_down' && events.rows[4].duration == 4);
	let ds = 0;
	for (let k, m in minutes)
		ds += m.down_s;
	check('down_s counted', ds == 4);
	run_probe(T + 6, false, null);
	run_probe(T + 7, true, true);
	check('short loss ignored', !open.internet_down && length(events.rows) == 5);

	// counters
	check('counter reset gives zero', counter_deltas({ dev: 'a', rx_bytes: 10 }, { dev: 'a', rx_bytes: 5 }).rx_bytes == 0);
	check('counter delta', counter_deltas({ dev: 'a', rx_bytes: 10, tx_bytes: 0, rx_errors: 0, tx_errors: 0, rx_dropped: 0, tx_dropped: 0 },
	                                       { dev: 'a', rx_bytes: 30, tx_bytes: 0, rx_errors: 0, tx_errors: 0, rx_dropped: 0, tx_dropped: 0 }).rx_bytes == 20);

	selftest_v02(check, mk, T);

	system(['rm', '-rf', cfg.data_dir]);
	warn(failed ? sprintf('%d FAILED\n', failed) : 'all passed\n');
	exit(failed ? 1 : 0);
}

args = parse_args(ARGV);
if (args.selftest)
	selftest();
else
	main();
