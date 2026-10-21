'use strict';
'require view';
'require rpc';
'require dom';

var callReport = rpc.declare({
	object: 'linequality',
	method: 'report',
	params: [ 'months' ],
	expect: { '': {} }
});

var callEvents = rpc.declare({
	object: 'linequality',
	method: 'events',
	params: [ 'limit', 'since' ],
	expect: { '': {} }
});

var CSS = [
	'.lq { --lq-bad:#dc2626; --lq-ok:#16a34a; --lq-warn:#d97706; --lq-grid:rgba(128,128,128,.28); --lq-line:rgba(128,128,128,.4); }',
	'@media (prefers-color-scheme: dark) { :root:not([data-darkmode="false"]) .lq { --lq-bad:#f87171; --lq-ok:#4ade80; --lq-warn:#fbbf24; } }',
	':root[data-darkmode="true"] .lq { --lq-bad:#f87171; --lq-ok:#4ade80; --lq-warn:#fbbf24; }',
	'.lq .lq-cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:12px; margin:.6em 0 1em 0; }',
	'.lq .lq-card { border:1px solid var(--lq-line); border-radius:6px; padding:10px 14px; min-width:0; break-inside:avoid; }',
	'.lq .lq-card h4 { margin:0 0 .5em 0; padding:0; font-size:.95em; opacity:.75; font-weight:600; border:0; }',
	'.lq .lq-kv { display:flex; justify-content:space-between; gap:12px; padding:2px 0; }',
	'.lq .lq-kv > span:first-child { opacity:.7; }',
	'.lq .lq-kv > span:last-child { text-align:right; font-variant-numeric:tabular-nums; }',
	'.lq .lq-big { font-size:1.6em; font-weight:600; line-height:1.2; }',
	'.lq .lq-ok { color:var(--lq-ok); } .lq .lq-warn { color:var(--lq-warn); } .lq .lq-bad { color:var(--lq-bad); }',
	'.lq .lq-sep { border-top:1px solid var(--lq-grid); margin:6px 0; }',
	'.lq .lq-hint { opacity:.7; font-size:.9em; margin-top:6px; }',
	'.lq .lq-empty { opacity:.65; padding:1.5em 0; text-align:center; }',
	'.lq .lq-tablewrap { overflow-x:auto; }',
	'.lq .lq-num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }',
	'.lq tr.lq-sel td { background:rgba(128,128,128,.18); font-weight:600; }',
	'.lq .lq-toolbar { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin:.5em 0; }',
	'.lq .lq-detail { margin-top:1.2em; }',
	'.lq .lq-detail h3 { margin-bottom:.2em; }',
	'@media print {',
	'  header, footer, #mainmenu, .main-left, #tabmenu, ul.tabs, .tabs, .cbi-tabmenu, #indicators, #modal_overlay, .lq-noprint { display:none !important; }',
	'  html, body, #maincontent, .main, .main-right, .container { background:#fff !important; color:#000 !important; margin:0 !important; padding:0 !important; width:auto !important; max-width:none !important; }',
	'  .lq { --lq-bad:#b91c1c; --lq-ok:#15803d; --lq-warn:#b45309; --lq-line:#999; --lq-grid:#ccc; color:#000; -webkit-print-color-adjust:exact; print-color-adjust:exact; }',
	'  .lq .lq-card { border-color:#999; }',
	'  .lq .lq-detail { margin-top:0; }',
	'}'
].join('\n');

function isnum(v) {
	return typeof(v) == 'number' && isFinite(v);
}

function fmtBytes(b) {
	if (!isnum(b))
		return '–';

	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;

	while (b >= 1000 && i < units.length - 1) {
		b /= 1000;
		i++;
	}

	return (i == 0 ? Math.round(b) : (b >= 100 ? b.toFixed(0) : b >= 10 ? b.toFixed(1) : b.toFixed(2))) + ' ' + units[i];
}

function fmtRate(bps) {
	if (!isnum(bps))
		return '–';

	var units = [ 'bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s' ], i = 0;

	while (bps >= 1000 && i < units.length - 1) {
		bps /= 1000;
		i++;
	}

	return (i == 0 ? Math.round(bps) : (bps >= 100 ? bps.toFixed(0) : bps >= 10 ? bps.toFixed(1) : bps.toFixed(2))) + ' ' + units[i];
}

function fmtMbit(m) {
	return isnum(m) ? fmtRate(m * 1e6) : '–';
}

function fmtDur(s) {
	if (!isnum(s))
		return '–';

	s = Math.round(s);

	if (s < 1)
		return _('%d s').format(0);

	var d = Math.floor(s / 86400),
	    h = Math.floor((s % 86400) / 3600),
	    m = Math.floor((s % 3600) / 60),
	    x = s % 60;

	if (d > 0)
		return _('%d d').format(d) + (h ? ' ' + _('%d h').format(h) : '');

	if (h > 0)
		return _('%d h').format(h) + (m ? ' ' + _('%d min').format(m) : '');

	if (m > 0)
		return _('%d min').format(m) + (x ? ' ' + _('%d s').format(x) : '');

	return _('%d s').format(x);
}

function fmtPct(p, digits) {
	return isnum(p) ? p.toFixed(digits == null ? 2 : digits) + ' %' : '–';
}

function fmtMs(v) {
	return isnum(v) ? (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + ' ms' : '–';
}

function fmtDateTime(t) {
	return isnum(t) ? new Date(t * 1000).toLocaleString() : '–';
}

function arrows(down, up) {
	return '↓ ' + down + ' ↑ ' + up;
}

function kv(label, value, cls) {
	return E('div', { 'class': 'lq-kv' }, [
		E('span', {}, label),
		E('span', { 'class': cls || '' }, value)
	]);
}

function monthRange(m) {
	var p = String(m).split('-'), y = +p[0], mo = +p[1] - 1;

	return [ new Date(y, mo, 1), new Date(y, mo + 1, 1) ];
}

function monthName(m) {
	var r = monthRange(m);

	return r[0].toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}

function monthShort(m) {
	var r = monthRange(m);

	return r[0].toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
}

function causeLabel(c) {
	switch (c) {
	case 'peer_hangup': return _('Line hang-up');
	case 'peer_terminated': return _('Closed by the provider');
	case 'echo_timeout': return _('No reply to keepalive');
	case 'local_restart': return _('Restarted locally');
	case 'auth_failed': return _('Authentication failed');
	case 'no_pado': return _('No answer from the provider (PADO)');
	case 'other': return _('Other');
	}

	return c || '';
}

return view.extend({
	load: function() {
		return callReport(12).catch(function() { return null; });
	},

	render: function(rep) {
		var self = this;

		this.rep = rep;
		this.listEl = E('div', { 'class': 'lq-tablewrap lq-noprint' });
		this.detailEl = E('div', { 'class': 'lq-detail' });
		this.printBtn = E('button', {
			'class': 'cbi-button cbi-button-action lq-noprint',
			click: function(ev) {
				ev.preventDefault();
				window.print();
			}
		}, _('Print'));

		var root = E('div', { 'class': 'lq' }, [
			E('style', {}, CSS),
			E('h2', { 'class': 'lq-noprint' }, _('Line quality report')),
			E('div', { 'class': 'lq-hint lq-noprint' },
				_('Monthly summary of the measurements taken by this router. Select a month to get a detailed statement, for example to support a complaint to your provider, then print it.')),
			this.listEl,
			this.detailEl
		]);

		var months = (rep && rep.months) || [];

		/* drop the months before monitoring started (newest first; keep at least the current one) */
		var last = 0;
		months.forEach(function(m, i) { if (m.mon_s > 0) last = i; });
		months = months.slice(0, last + 1);

		if (rep)
			rep.months = months;

		this.selected = null;

		if (!months.length) {
			dom.content(this.listEl, E('div', { 'class': 'lq-empty' },
				rep ? _('No data collected yet.') : _('The report is not available. Is the linequality service running and up to date?')));
			return root;
		}

		/* the last complete month is the most useful default, once there is one */
		this.select(months.length > 1 ? months[1].month : months[0].month);

		return root;
	},

	select: function(month) {
		var self = this;

		this.selected = month;
		this.renderList();
		this.renderDetail();

		var r = monthRange(month), since = Math.floor(r[0].getTime() / 1000) - 120, until = Math.floor(r[1].getTime() / 1000);

		this.events = null;

		callEvents(1000, since).then(function(res) {
			if (self.selected != month)
				return;

			self.events = ((res && res.events) || []).filter(function(e) { return e.start < until; });
			self.renderDetail();
		}).catch(function() {});
	},

	renderList: function() {
		var self = this, months = (this.rep && this.rep.months) || [], plan = (this.rep && this.rep.plan) || null;

		dom.content(this.listEl, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Month')),
				E('th', { 'class': 'th lq-num' }, _('Availability')),
				E('th', { 'class': 'th lq-num' }, _('Downtime')),
				E('th', { 'class': 'th lq-num' }, _('Outages')),
				E('th', { 'class': 'th lq-num' }, _('Outages of 1 min or more')),
				E('th', { 'class': 'th lq-num' }, _('Longest outage')),
				E('th', { 'class': 'th lq-num' }, _('Loss')),
				E('th', { 'class': 'th lq-num' }, _('Average RTT')),
				E('th', { 'class': 'th lq-num' }, _('RTT p95')),
				E('th', { 'class': 'th lq-num' }, _('Average speed test')),
				E('th', { 'class': 'th lq-num' }, _('% of plan'))
			])
		].concat(months.map(function(m) {
			var st = m.speedtests || {}, sel = m.month == self.selected;

			return E('tr', { 'class': 'tr' + (sel ? ' lq-sel' : ''), style: 'cursor:pointer', click: function() { self.select(m.month); } }, [
				E('td', { 'class': 'td' }, E('a', {
					href: '#', click: function(ev) { ev.preventDefault(); ev.stopPropagation(); self.select(m.month); }
				}, monthShort(m.month))),
				E('td', { 'class': 'td lq-num' + (isnum(m.uptime_pct) && m.uptime_pct < 99.9 ? ' lq-warn' : '') }, fmtPct(m.uptime_pct)),
				E('td', { 'class': 'td lq-num' }, fmtDur(m.down_s)),
				E('td', { 'class': 'td lq-num' }, isnum(m.outages) ? String(m.outages) : '–'),
				E('td', { 'class': 'td lq-num' }, isnum(m.outages_1m) ? String(m.outages_1m) : '–'),
				E('td', { 'class': 'td lq-num' }, m.outages > 0 ? fmtDur(m.longest_s) : '–'),
				E('td', { 'class': 'td lq-num' }, fmtPct(m.loss_pct)),
				E('td', { 'class': 'td lq-num' }, fmtMs(m.rtt_avg)),
				E('td', { 'class': 'td lq-num' }, fmtMs(m.rtt_p95)),
				E('td', { 'class': 'td lq-num' }, st.n > 0 && st.ok > 0 ? arrows(fmtMbit(st.down_avg), fmtMbit(st.up_avg)) : '–'),
				E('td', { 'class': 'td lq-num' }, plan && (isnum(st.down_pct_avg) || isnum(st.up_pct_avg)) ?
					arrows(fmtPct(st.down_pct_avg, 0), fmtPct(st.up_pct_avg, 0)) : '–')
			]);
		}))));
	},

	causeFor: function(e, all) {
		var end = e.end != null ? e.end : Infinity, found = null;

		all.forEach(function(w) {
			if (found || w.type != 'wan_down' || !(w.detail || {}).cause)
				return;

			var wend = w.end != null ? w.end : Infinity;

			if (w.start <= end + 60 && wend >= e.start - 60)
				found = w.detail.cause;
		});

		return found;
	},

	renderDetail: function() {
		var self = this, months = (this.rep && this.rep.months) || [], plan = (this.rep && this.rep.plan) || null,
		    m = months.filter(function(x) { return x.month == self.selected; })[0];

		if (!m) {
			dom.content(this.detailEl, '');
			return;
		}

		var st = m.speedtests || {}, r = monthRange(m.month),
		    monthSecs = (r[1].getTime() - r[0].getTime()) / 1000,
		    coverage = isnum(m.mon_s) ? Math.min(100, 100 * m.mon_s / monthSecs) : null,
		    hasPlan = plan && (isnum(plan.down) || isnum(plan.up)),
		    cards = [];

		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h4', {}, _('Availability')),
			E('div', { 'class': 'lq-big ' + (isnum(m.uptime_pct) && m.uptime_pct < 99.9 ? 'lq-warn' : 'lq-ok') }, fmtPct(m.uptime_pct)),
			E('div', { 'class': 'lq-sep' }),
			kv(_('Total downtime'), fmtDur(m.down_s)),
			kv(_('Monitored time'), fmtDur(m.mon_s) + (isnum(coverage) ? ' (' + fmtPct(coverage, 1) + ')' : ''))
		]));

		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h4', {}, _('Outages')),
			kv(_('Number of outages'), isnum(m.outages) ? String(m.outages) : '–'),
			kv(_('Outages of 1 min or more'), isnum(m.outages_1m) ? String(m.outages_1m) : '–'),
			kv(_('Longest outage'), m.outages > 0 ? fmtDur(m.longest_s) : '–')
		]));

		var stRows = [ E('h4', {}, _('Speed tests')) ];

		if (hasPlan)
			stRows.push(kv(_('Contracted speed'), arrows(fmtMbit(plan.down), fmtMbit(plan.up))));

		if (st.n > 0)
			stRows.push(
				kv(_('Tests run'), st.n + (isnum(st.ok) && st.ok < st.n ? ' (' + _('%d failed').format(st.n - st.ok) + ')' : '')),
				kv(_('Average'), arrows(fmtMbit(st.down_avg), fmtMbit(st.up_avg))),
				kv(_('Minimum'), arrows(fmtMbit(st.down_min), fmtMbit(st.up_min)))
			);
		else
			stRows.push(E('div', { 'class': 'lq-hint' }, _('No speed tests this month.')));

		if (hasPlan && st.ok > 0)
			stRows.push(kv(_('Average vs contracted speed'), arrows(fmtPct(st.down_pct_avg, 0), fmtPct(st.up_pct_avg, 0)),
				(isnum(st.down_pct_avg) && st.down_pct_avg < 80) || (isnum(st.up_pct_avg) && st.up_pct_avg < 80) ? 'lq-warn' : ''));

		cards.push(E('div', { 'class': 'lq-card' }, stRows));

		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h4', {}, _('Latency and packet loss')),
			kv(_('Packet loss'), fmtPct(m.loss_pct)),
			kv(_('Average RTT'), fmtMs(m.rtt_avg)),
			kv(_('RTT p95'), fmtMs(m.rtt_p95)),
			kv(_('Jitter'), fmtMs(m.jitter_avg)),
			isnum(m.dns_avg_ms) ? kv(_('DNS avg / failed'), fmtMs(m.dns_avg_ms) + ' / ' + fmtPct(m.dns_fail_pct, 1)) : ''
		]));

		var hasErr = isnum(m.err) || isnum(m.drop) || isnum(m.crc);

		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h4', {}, _('Traffic and line errors')),
			kv(_('Traffic'), arrows(fmtBytes(m.rx), fmtBytes(m.tx))),
			kv(_('Peak speed'), arrows(fmtRate(m.rx_peak_bps), fmtRate(m.tx_peak_bps))),
			hasErr ? kv(_('Errors / drops / CRC'), (m.err || 0) + ' / ' + (m.drop || 0) + ' / ' + (m.crc || 0)) : '',
			isnum(m.cpu_avg) ? kv(_('Router CPU average'), fmtPct(m.cpu_avg, 0)) : ''
		]));

		var outageBlock = '';

		if (this.events) {
			var all = this.events,
			    list = all.filter(function(e) { return e.type == 'internet_down'; });

			if (list.length)
				outageBlock = E('div', {}, [
					E('h4', {}, _('Outage list')),
					E('div', { 'class': 'lq-tablewrap' }, E('table', { 'class': 'table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, _('Start')), E('th', { 'class': 'th' }, _('End')),
							E('th', { 'class': 'th' }, _('Duration')), E('th', { 'class': 'th' }, _('Cause'))
						])
					].concat(list.map(function(e) {
						var cause = self.causeFor(e, all);

						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, fmtDateTime(e.start)),
							E('td', { 'class': 'td' }, e.end == null ? _('ongoing') : fmtDateTime(e.end)),
							E('td', { 'class': 'td' }, fmtDur(e.duration)),
							E('td', { 'class': 'td' }, cause ? causeLabel(cause) : '–')
						]);
					}))))
				]);
		}

		dom.content(this.detailEl, [
			E('h3', {}, _('Statement for %s').format(monthName(m.month))),
			E('div', { 'class': 'lq-toolbar' }, [
				E('span', { 'class': 'lq-hint' }, _('Generated on %s').format(new Date().toLocaleString())),
				this.printBtn
			]),
			E('div', { 'class': 'lq-cards' }, cards),
			outageBlock,
			E('div', { 'class': 'lq-hint' },
				_('Measurements were taken from the customer router every second towards several independent hosts on the Internet. An outage is recorded when all of them stop answering for several consecutive seconds.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
