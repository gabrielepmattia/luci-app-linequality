'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';

var callStatus = rpc.declare({
	object: 'linequality',
	method: 'status',
	expect: { '': {} }
});

var callSeries = rpc.declare({
	object: 'linequality',
	method: 'series',
	params: [ 'range' ],
	expect: { '': {} }
});

var callEvents = rpc.declare({
	object: 'linequality',
	method: 'events',
	params: [ 'limit', 'since' ],
	expect: { '': {} }
});

var callSpeedtests = rpc.declare({
	object: 'linequality',
	method: 'speedtests',
	params: [ 'limit' ],
	expect: { '': {} }
});

var callSpeedtestRun = rpc.declare({
	object: 'linequality',
	method: 'speedtest_run',
	expect: { '': {} }
});

var RANGES = [ '1h', '24h', '7d', '30d', '1y' ];
var RANGE_SECONDS = { '1h': 3600, '24h': 86400, '7d': 7 * 86400, '30d': 30 * 86400, '1y': 365 * 86400 };
var SVGNS = 'http://www.w3.org/2000/svg';

var CSS = [
	'.lq { --lq-c1:#2563eb; --lq-c2:#d97706; --lq-c3:#0d9488; --lq-c4:#9333ea; --lq-c5:#db2777; --lq-c6:#65a30d;',
	'  --lq-bad:#dc2626; --lq-ok:#16a34a; --lq-warn:#d97706; --lq-grid:rgba(128,128,128,.28); --lq-line:rgba(128,128,128,.4); }',
	'@media (prefers-color-scheme: dark) { :root:not([data-darkmode="false"]) .lq {',
	'  --lq-c1:#60a5fa; --lq-c2:#fbbf24; --lq-c3:#2dd4bf; --lq-c4:#c084fc; --lq-c5:#f472b6; --lq-c6:#a3e635;',
	'  --lq-bad:#f87171; --lq-ok:#4ade80; --lq-warn:#fbbf24; } }',
	':root[data-darkmode="true"] .lq {',
	'  --lq-c1:#60a5fa; --lq-c2:#fbbf24; --lq-c3:#2dd4bf; --lq-c4:#c084fc; --lq-c5:#f472b6; --lq-c6:#a3e635;',
	'  --lq-bad:#f87171; --lq-ok:#4ade80; --lq-warn:#fbbf24; }',
	'.lq .lq-cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(250px,1fr)); gap:12px; margin-bottom:1em; }',
	'.lq .lq-card { border:1px solid var(--lq-line); border-radius:6px; padding:10px 14px; min-width:0; }',
	'.lq .lq-card h3 { margin:0 0 .5em 0; padding:0; font-size:.95em; opacity:.75; font-weight:600; text-transform:none; border:0; }',
	'.lq .lq-kv { display:flex; justify-content:space-between; gap:12px; padding:2px 0; }',
	'.lq .lq-kv > span:first-child { opacity:.7; }',
	'.lq .lq-kv > span:last-child { text-align:right; font-variant-numeric:tabular-nums; }',
	'.lq .lq-big { font-size:1.6em; font-weight:600; line-height:1.2; }',
	'.lq .lq-dot { display:inline-block; width:.7em; height:.7em; border-radius:50%; margin-right:.4em; background:currentColor; }',
	'.lq .lq-ok { color:var(--lq-ok); } .lq .lq-warn { color:var(--lq-warn); } .lq .lq-bad { color:var(--lq-bad); }',
	'.lq .lq-sep { border-top:1px solid var(--lq-grid); margin:6px 0; }',
	'.lq .lq-hint { opacity:.7; font-size:.9em; margin-top:6px; }',
	'.lq .lq-sub { opacity:.7; font-size:.85em; }',
	'.lq table.lq-mini { width:100%; border-collapse:collapse; }',
	'.lq table.lq-mini th { text-align:right; font-weight:600; opacity:.7; font-size:.85em; padding:1px 0 1px 8px; }',
	'.lq table.lq-mini td { text-align:right; padding:2px 0 2px 8px; font-variant-numeric:tabular-nums; }',
	'.lq table.lq-mini th:first-child, .lq table.lq-mini td:first-child { text-align:left; padding-left:0; }',
	'.lq .lq-sw { display:inline-block; width:.9em; height:.25em; border-radius:2px; margin-right:.4em; vertical-align:middle; }',
	'.lq .lq-toolbar { display:flex; flex-wrap:wrap; gap:6px; align-items:center; margin:.5em 0; }',
	'.lq .lq-toolbar .cbi-button.lq-active { font-weight:700; text-decoration:underline; }',
	'.lq .lq-legend { display:flex; flex-wrap:wrap; gap:4px 16px; font-size:.85em; margin:2px 0 4px 0; }',
	'.lq .lq-chartbox { position:relative; margin-bottom:1.2em; }',
	'.lq .lq-chartbox h4 { margin:.4em 0 .2em 0; font-size:1em; }',
	'.lq svg.lq-svg { width:100%; height:auto; display:block; color:inherit; touch-action:pan-y; }',
	'.lq svg.lq-svg text { fill:currentColor; font-size:11px; opacity:.75; }',
	'.lq .lq-tip { position:absolute; top:28px; pointer-events:none; z-index:5; padding:6px 9px; border-radius:5px; font-size:.85em;',
	'  background:var(--background-color-high, #fff); color:var(--text-color-high, #222); border:1px solid var(--lq-line);',
	'  box-shadow:0 2px 8px rgba(0,0,0,.25); white-space:nowrap; display:none; }',
	'.lq .lq-tip b { display:block; margin-bottom:2px; }',
	'.lq .lq-empty { opacity:.65; padding:1.5em 0; text-align:center; }',
	'.lq tr.lq-ongoing td { font-weight:700; color:var(--lq-bad); }',
	'.lq .lq-tablewrap { overflow-x:auto; }',
	'.lq .lq-num { text-align:right; font-variant-numeric:tabular-nums; }'
].join('\n');

/* ---------- formatting helpers ---------- */

function isnum(v) {
	return typeof(v) == 'number' && isFinite(v);
}

function dash(v, fn) {
	return isnum(v) ? fn(v) : '–';
}

function fmtBytes(b) {
	if (!isnum(b))
		return '–';

	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;

	while (b >= 1000 && i < units.length - 1) {
		b /= 1000;
		i++;
	}

	return (i == 0 ? Math.round(b) : (b >= 100 ? b.toFixed(0) : b >= 10 ? b.toFixed(1) : b.toFixed(2))) + ' ' + units[i];
}

function fmtRate(bps) {
	if (!isnum(bps))
		return '–';

	var units = [ 'bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s' ], i = 0;

	while (bps >= 1000 && i < units.length - 1) {
		bps /= 1000;
		i++;
	}

	return (i == 0 ? Math.round(bps) : (bps >= 100 ? bps.toFixed(0) : bps >= 10 ? bps.toFixed(1) : bps.toFixed(2))) + ' ' + units[i];
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
	return isnum(p) ? p.toFixed(digits == null ? 2 : digits) + ' %' : '–';
}

function fmtMs(v) {
	return isnum(v) ? (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + ' ms' : '–';
}

function fmtDateTime(t) {
	return isnum(t) ? new Date(t * 1000).toLocaleString() : '–';
}

function fmtDate(t) {
	return isnum(t) ? new Date(t * 1000).toLocaleDateString() : '–';
}

function fmtTick(t, range) {
	var d = new Date(t * 1000);

	if (range == '1y')
		return d.toLocaleDateString(undefined, { month: 'short', year: '2-digit' });

	if (range == '7d' || range == '30d')
		return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });

	return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

/* round axis for data up to v: a 1/2/5 step giving 3-5 intervals */
function niceScale(v) {
	if (!(v > 0))
		v = 1;

	var raw = v / 4,
	    p = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)),
	    n = raw / p,
	    step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p;

	return { step: step, max: step * Math.ceil(v / step), digits: step >= 1 ? 0 : Math.ceil(-Math.log(step) / Math.LN10) };
}

function svgEl(name, attrs, children) {
	var el = document.createElementNS(SVGNS, name), k;

	for (k in (attrs || {}))
		if (attrs[k] != null)
			el.setAttribute(k, attrs[k]);

	(children || []).forEach(function(c) {
		el.appendChild(typeof(c) == 'string' ? document.createTextNode(c) : c);
	});

	return el;
}

function kv(label, value, cls) {
	return E('div', { 'class': 'lq-kv' }, [
		E('span', {}, label),
		E('span', { 'class': cls || '' }, value)
	]);
}

function arrows(down, up) {
	return '↓ ' + down + ' ↑ ' + up;
}

/* ---------- data helpers ---------- */

function referenceLabels(labels) {
	var ref = labels.filter(function(l) { return l != 'gateway'; });

	return ref.length ? ref : labels;
}

function rowLabels(rows) {
	var seen = {}, out = [];

	rows.forEach(function(r) {
		Object.keys(r.p || {}).forEach(function(l) {
			if (!seen[l]) {
				seen[l] = true;
				out.push(l);
			}
		});
	});

	return out;
}

function rowLoss(r, ref) {
	var sent = 0, recv = 0;

	ref.forEach(function(l) {
		var p = (r.p || {})[l];

		if (p) {
			sent += p[0] || 0;
			recv += p[1] || 0;
		}
	});

	return sent > 0 ? 100 * (1 - recv / sent) : null;
}

function rowRtt(r, label) {
	var p = (r.p || {})[label];

	return (p && p[1] > 0 && isnum(p[2])) ? p[2] / p[1] : null;
}

function rowRate(r, bytes) {
	var secs = r.mon_s > 0 ? r.mon_s : 0;

	return (secs > 0 && isnum(bytes)) ? bytes * 8 / secs : null;
}

/* ---------- chart ---------- */

/*
 * cfg: rows, step, range, now, yMax (data maximum), lines[{label,color,vals,width,opacity,dash}],
 *      bars[{i,frac}], shades[i], marks[i], tip(i) -> { title, items:[{color,label,value}] }
 */
function drawChart(cfg) {
	var W = 900, H = 230, ml = 56, mr = 12, mt = 10, mb = 24,
	    pw = W - ml - mr, ph = H - mt - mb,
	    rows = cfg.rows, step = cfg.step,
	    /* always show the whole range, so missing data reads as a gap */
	    t1 = Math.max(rows[rows.length - 1].t + step, cfg.now || 0),
	    t0 = Math.min(rows[0].t, t1 - (RANGE_SECONDS[cfg.range] || 0)),
	    span = t1 - t0,
	    yscale = niceScale(cfg.yMax),
	    ymax = yscale.max,
	    X = function(t) { return ml + (t - t0) / span * pw; },
	    Y = function(v) { return mt + ph - Math.min(v, ymax) / ymax * ph; },
	    svg = svgEl('svg', { 'class': 'lq-svg', viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.title }),
	    tip = E('div', { 'class': 'lq-tip' }),
	    box = E('div', { 'class': 'lq-chartbox' }),
	    i, k;

	/* shaded outage periods */
	(cfg.shades || []).forEach(function(idx) {
		svg.appendChild(svgEl('rect', {
			x: X(rows[idx].t), y: mt, width: Math.max(2, pw * step / span), height: ph,
			fill: 'var(--lq-bad)', opacity: .18
		}));
	});

	/* grid and y axis */
	for (k = 0; k * yscale.step <= ymax + 1e-9; k++) {
		var yv = k * yscale.step, yy = Y(yv);

		svg.appendChild(svgEl('line', { x1: ml, x2: W - mr, y1: yy, y2: yy, stroke: k == 0 ? 'currentColor' : 'var(--lq-grid)', 'stroke-opacity': k == 0 ? .5 : 1, 'stroke-width': 1 }));
		svg.appendChild(svgEl('text', { x: ml - 6, y: yy + 4, 'text-anchor': 'end' }, [ yv.toFixed(yscale.digits) ]));
	}

	/* x axis ticks */
	var nt = 6;
	for (k = 0; k < nt; k++) {
		var tt = t0 + span * (k + .5) / nt, xx = X(tt);

		svg.appendChild(svgEl('line', { x1: xx, x2: xx, y1: mt + ph, y2: mt + ph + 4, stroke: 'currentColor', 'stroke-opacity': .5 }));
		svg.appendChild(svgEl('text', { x: xx, y: H - 6, 'text-anchor': 'middle' }, [ fmtTick(tt, cfg.range) ]));
	}

	/* bars along the bottom (loss) */
	var bw = Math.max(1, pw * step / span - 1);
	(cfg.bars || []).forEach(function(b) {
		var h = Math.max(2, b.frac * ph * .25);

		svg.appendChild(svgEl('rect', {
			x: X(rows[b.i].t), y: mt + ph - h, width: bw, height: h,
			fill: 'var(--lq-bad)', opacity: .75, rx: 1
		}));
	});

	/* lines, broken at gaps */
	(cfg.lines || []).forEach(function(ln) {
		var d = '', prev = null, pts = [];

		ln.vals.forEach(function(v, idx) {
			if (!isnum(v)) {
				prev = null;
				return;
			}

			var x = X(rows[idx].t + step / 2), y = Y(v);

			if (prev == null || rows[idx].t - rows[prev].t > step * 2)
				d += 'M' + x.toFixed(1) + ' ' + y.toFixed(1);
			else
				d += 'L' + x.toFixed(1) + ' ' + y.toFixed(1);

			prev = idx;
			pts.push([ x, y ]);
		});

		if (d)
			svg.appendChild(svgEl('path', {
				d: d, fill: 'none', stroke: ln.color, 'stroke-width': ln.width || 2,
				'stroke-opacity': ln.opacity || 1, 'stroke-linejoin': 'round', 'stroke-linecap': 'round',
				'stroke-dasharray': ln.dash || null
			}));

		/* isolated points would be invisible as lines */
		if (pts.length == 1)
			svg.appendChild(svgEl('circle', { cx: pts[0][0], cy: pts[0][1], r: 3, fill: ln.color }));
	});

	/* markers (speed tests) */
	(cfg.marks || []).forEach(function(idx) {
		var x = X(rows[idx].t + step / 2);

		svg.appendChild(svgEl('path', {
			d: 'M' + (x - 5) + ' ' + (mt + 1) + 'L' + (x + 5) + ' ' + (mt + 1) + 'L' + x + ' ' + (mt + 10) + 'Z',
			fill: 'currentColor', opacity: .8
		}));
	});

	/* hover layer */
	var cross = svgEl('line', { y1: mt, y2: mt + ph, stroke: 'currentColor', 'stroke-opacity': .6, 'stroke-width': 1, visibility: 'hidden' }),
	    dots = svgEl('g', {}),
	    hit = svgEl('rect', { x: ml, y: 0, width: pw, height: H, fill: 'transparent' });

	svg.appendChild(cross);
	svg.appendChild(dots);
	svg.appendChild(hit);

	function hide() {
		cross.setAttribute('visibility', 'hidden');
		tip.style.display = 'none';
		while (dots.firstChild)
			dots.removeChild(dots.firstChild);
	}

	function show(ev) {
		var rect = svg.getBoundingClientRect();

		if (!rect.width)
			return;

		var px = (ev.clientX - rect.left) / rect.width * W,
		    t = t0 + (px - ml) / pw * span,
		    best = 0, bd = Infinity;

		for (i = 0; i < rows.length; i++) {
			var dd = Math.abs(rows[i].t + step / 2 - t);

			if (dd < bd) {
				bd = dd;
				best = i;
			}
		}

		/* no read-out over the empty part of the range */
		if (bd > step * 1.5)
			return hide();

		var x = X(rows[best].t + step / 2), info = cfg.tip(best);

		cross.setAttribute('x1', x);
		cross.setAttribute('x2', x);
		cross.setAttribute('visibility', 'visible');

		while (dots.firstChild)
			dots.removeChild(dots.firstChild);

		(cfg.lines || []).forEach(function(ln) {
			if (ln.nodot || !isnum(ln.vals[best]))
				return;

			dots.appendChild(svgEl('circle', {
				cx: x, cy: Y(ln.vals[best]), r: 4, fill: ln.color,
				stroke: 'var(--background-color-high, #fff)', 'stroke-width': 2
			}));
		});

		dom.content(tip, [
			E('b', {}, info.title),
			info.items.map(function(it) {
				return E('div', {}, [
					E('span', { 'class': 'lq-sw', style: 'background:' + it.color }),
					it.label + ': ' + it.value
				]);
			})
		]);

		tip.style.display = 'block';

		var frac = x / W, bw2 = box.clientWidth;
		if (frac > .55)
			tip.style.left = Math.max(0, frac * bw2 - tip.offsetWidth - 12) + 'px';
		else
			tip.style.left = Math.min(bw2 - tip.offsetWidth, frac * bw2 + 12) + 'px';
	}

	hit.addEventListener('pointermove', show);
	hit.addEventListener('pointerdown', show);
	hit.addEventListener('pointerleave', hide);

	var legend = E('div', { 'class': 'lq-legend' }, (cfg.legend || []).map(function(it) {
		return E('span', {}, [ E('span', { 'class': 'lq-sw', style: 'background:' + it.color + (it.faint ? ';opacity:.45' : '') }), it.label ]);
	}));

	dom.content(box, [ E('h4', {}, cfg.title), legend, svg, tip ]);

	return box;
}

/* ---------- view ---------- */

return view.extend({
	load: function() {
		return Promise.all([
			callStatus().catch(function() { return null; }),
			callSeries('24h').catch(function() { return null; }),
			callEvents(200, 0).catch(function() { return null; }),
			callSpeedtests(50).catch(function() { return null; }),
			callSeries('1y').catch(function() { return null; })
		]);
	},

	colorFor: function(label) {
		this.colors = this.colors || {};

		if (!(label in this.colors))
			this.colors[label] = 'var(--lq-c' + ((Object.keys(this.colors).length % 6) + 1) + ')';

		return this.colors[label];
	},

	render: function(data) {
		var self = this;

		this.range = '24h';
		this.stat = data[0];
		this.ser = data[1];
		this.ev = data[2];
		this.st = data[3];
		this.daily = data[4];
		this.stRequested = false;

		this.cardsEl = E('div', { 'class': 'lq-cards' });
		this.chartsEl = E('div');
		this.eventsEl = E('div', { 'class': 'lq-tablewrap' });
		this.testsEl = E('div', { 'class': 'lq-tablewrap' });
		this.dailyEl = E('div', { 'class': 'lq-tablewrap' });
		this.toolbar = E('div', { 'class': 'lq-toolbar' });

		var root = E('div', { 'class': 'lq' }, [
			E('style', {}, CSS),
			E('h2', {}, _('Line quality')),
			this.cardsEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('History')),
				this.toolbar,
				this.chartsEl
			]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Outages and disconnections')), this.eventsEl ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Speed tests')), this.testsEl ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Daily summary, last 30 days')), this.dailyEl ])
		]);

		this.renderToolbar();
		this.updateCards();
		this.updateCharts();
		this.updateEvents();
		this.updateTests();
		this.updateDaily();

		poll.add(function() {
			return callStatus().then(function(s) {
				self.stat = s;
				self.updateCards();
			}).catch(function() {});
		}, 5);

		poll.add(function() {
			return self.refreshSlow();
		}, 60);

		return root;
	},

	refreshSlow: function() {
		var self = this;

		return Promise.all([
			callSeries(this.range).catch(function() { return null; }),
			callEvents(200, 0).catch(function() { return null; }),
			callSpeedtests(50).catch(function() { return null; }),
			callSeries('1y').catch(function() { return null; })
		]).then(function(r) {
			self.ser = r[0] || self.ser;
			self.ev = r[1] || self.ev;
			self.st = r[2] || self.st;
			self.daily = r[3] || self.daily;
			self.updateCharts();
			self.updateEvents();
			self.updateTests();
			self.updateDaily();
		});
	},

	renderToolbar: function() {
		var self = this;

		dom.content(this.toolbar, [
			E('span', {}, _('Range') + ':')
		].concat(RANGES.map(function(r) {
			return E('button', {
				'class': 'cbi-button' + (r == self.range ? ' cbi-button-action lq-active' : ''),
				click: function(ev) {
					ev.preventDefault();
					self.range = r;
					self.renderToolbar();
					callSeries(r).then(function(s) {
						if (self.range == r) {
							self.ser = s;
							self.updateCharts();
						}
					});
				}
			}, r);
		})));
	},

	/* ----- cards ----- */

	updateCards: function() {
		var s = this.stat, self = this;

		if (!s || !s.interface) {
			dom.content(this.cardsEl, E('div', { 'class': 'lq-card' }, [
				E('h3', {}, _('Line quality')),
				E('div', { 'class': 'lq-empty' }, _('No data from the collector. Is the linequality service running?'))
			]));
			return;
		}

		var iface = s.interface, live = s.live || {}, sum = s.summary || {},
		    targets = live.targets || [],
		    ref = referenceLabels(targets.map(function(t) { return t.label; })),
		    refT = targets.filter(function(t) { return ref.indexOf(t.label) >= 0; }),
		    openInternet = (s.open_events || []).some(function(e) { return e.type == 'internet_down'; }),
		    worstLoss = refT.reduce(function(m, t) { return isnum(t.loss_pct) ? Math.max(m, t.loss_pct) : m; }, 0),
		    state, stateCls;

		if (!iface.up || openInternet) {
			state = _('Offline');
			stateCls = 'lq-bad';
		}
		else if (worstLoss >= 2) {
			state = _('Degraded');
			stateCls = 'lq-warn';
		}
		else {
			state = _('Online');
			stateCls = 'lq-ok';
		}

		var cards = [];

		/* line state */
		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h3', {}, _('Line state')),
			E('div', { 'class': 'lq-big ' + stateCls }, [ E('span', { 'class': 'lq-dot' }), state ]),
			E('div', { 'class': 'lq-sep' }),
			kv(_('Interface'), (iface.name || '–') + (iface.l3_device ? ' (' + iface.l3_device + ')' : '')),
			kv(_('Connection uptime'), iface.up ? fmtDur(iface.uptime) : '–'),
			kv(_('Public IP'), iface.ipv4 || '–'),
			kv(_('Gateway'), iface.gateway || '–'),
			iface.carrier === false || iface.carrier === 0 ? kv(_('Link'), _('No carrier'), 'lq-bad') : ''
		]));

		/* uptime */
		var upRows = [ E('h3', {}, _('Availability')) ];
		[ [ '24h', _('Last 24 hours') ], [ '7d', _('Last 7 days') ], [ '30d', _('Last 30 days') ] ].forEach(function(p) {
			var x = sum[p[0]] || {};

			upRows.push(E('div', { 'class': 'lq-kv' }, [
				E('span', {}, p[1]),
				E('span', {}, [
					E('b', {}, fmtPct(x.uptime_pct)),
					E('span', { 'class': 'lq-sub' }, ' · ' + fmtDur(x.down_s) + ' · ' + _('%d disconnects').format(x.disconnects || 0))
				])
			]));
		});
		cards.push(E('div', { 'class': 'lq-card' }, upRows));

		/* traffic */
		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h3', {}, _('Traffic')),
			kv(_('Today'), arrows(fmtBytes((sum.today || {}).rx), fmtBytes((sum.today || {}).tx))),
			kv(_('This month'), arrows(fmtBytes((sum.month || {}).rx), fmtBytes((sum.month || {}).tx)))
		]));

		/* speed */
		var d24 = sum['24h'] || {};
		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h3', {}, _('Speed')),
			kv(_('Live'), arrows(fmtRate(live.rx_bps), fmtRate(live.tx_bps))),
			kv(_('Average, 24 h'), arrows(fmtRate(d24.rx_avg_bps), fmtRate(d24.tx_avg_bps))),
			kv(_('Peak, 24 h'), arrows(fmtRate(d24.rx_peak_bps), fmtRate(d24.tx_peak_bps)))
		]));

		/* targets */
		cards.push(E('div', { 'class': 'lq-card' }, [
			E('h3', {}, _('Latency, last 5 minutes')),
			targets.length ? E('table', { 'class': 'lq-mini' }, [
				E('tr', {}, [ E('th', {}, _('Target')), E('th', {}, _('RTT')), E('th', {}, _('Loss')), E('th', {}, _('Jitter')) ])
			].concat(targets.map(function(t) {
				return E('tr', {}, [
					E('td', {}, [
						E('span', { 'class': 'lq-sw', style: 'background:' + self.colorFor(t.label) }),
						t.label == 'gateway' ? _('Gateway') : t.label
					]),
					E('td', {}, fmtMs(t.rtt_avg)),
					E('td', { 'class': isnum(t.loss_pct) && t.loss_pct >= 2 ? 'lq-bad' : '' }, fmtPct(t.loss_pct, 1)),
					E('td', {}, fmtMs(t.jitter))
				]);
			}))) : E('div', { 'class': 'lq-empty' }, _('No data yet'))
		]));

		cards.push(this.speedtestCard());

		dom.content(this.cardsEl, cards);
	},

	speedtestCard: function() {
		var self = this, st = (this.stat || {}).speedtest || {}, last = st.last,
		    body = [ E('h3', {}, _('Last speed test')) ];

		if (last && last.ok) {
			var delta = (isnum(last.loaded_rtt) && isnum(last.idle_rtt)) ? last.loaded_rtt - last.idle_rtt : null;

			body.push(
				E('div', { 'class': 'lq-big' }, arrows(fmtMbit(last.down), fmtMbit(last.up))),
				E('div', { 'class': 'lq-sep' }),
				kv(_('Ping'), fmtMs(last.ping)),
				kv(_('Jitter'), fmtMs(last.jitter)),
				kv(_('Bufferbloat'), delta == null ? '–' : '+' + fmtMs(Math.max(0, delta)),
					delta != null && delta > 100 ? 'lq-bad' : delta != null && delta > 30 ? 'lq-warn' : ''),
				kv(_('Server'), last.server || '–'),
				kv(_('When'), fmtDateTime(last.t))
			);
		}
		else if (last) {
			body.push(
				E('div', { 'class': 'lq-bad' }, _('The last speed test failed') + (last.error ? ': ' + last.error : '')),
				kv(_('When'), fmtDateTime(last.t))
			);
		}
		else
			body.push(E('div', { 'class': 'lq-empty' }, _('No speed test yet')));

		if (st.available === false) {
			body.push(E('div', { 'class': 'lq-hint' },
				_('Speed tests need the librespeed-cli package. Install it (opkg install librespeed-cli, or apk add librespeed-cli) to enable them.')));
		}
		else if (st.available) {
			var running = !!st.running || this.stRequested;

			body.push(E('div', { 'class': 'lq-sep' }));
			var btn = E('button', {
				'class': 'cbi-button cbi-button-action',
				click: function(ev) {
					ev.preventDefault();
					self.runSpeedtest();
				}
			}, running ? _('Speed test running\u2026') : _('Run speed test'));

			btn.disabled = running;
			body.push(btn);

			if (st.running && isnum(st.started_at) && isnum(this.stat.now))
				body.push(E('div', { 'class': 'lq-hint' }, _('Running for %s').format(fmtDur(this.stat.now - st.started_at))));
		}

		return E('div', { 'class': 'lq-card' }, body);
	},

	runSpeedtest: function() {
		var self = this;

		this.stRequested = true;
		this.updateCards();

		return callSpeedtestRun().then(function(res) {
			if (res && res.error) {
				self.stRequested = false;

				ui.addNotification(null, E('p', {},
					res.error == 'running' ? _('A speed test is already running.') :
					res.error == 'not_available' ? _('Speed tests are not available: librespeed-cli is not installed.') :
					_('Unable to start the speed test: %s').format(res.error)), 'danger');
			}

			return callStatus();
		}).then(function(s) {
			self.stRequested = false;
			if (s) self.stat = s;
			self.updateCards();
		}).catch(function(e) {
			self.stRequested = false;
			ui.addNotification(null, E('p', {}, _('Unable to start the speed test: %s').format(e.message || e)), 'danger');
			self.updateCards();
		});
	},

	/* ----- charts ----- */

	updateCharts: function() {
		var s = this.ser, self = this;

		if (!s || !s.rows || !s.rows.length) {
			dom.content(this.chartsEl, E('div', { 'class': 'lq-empty' }, _('No data collected yet for this range.')));
			return;
		}

		var rows = s.rows, step = s.step || 60,
		    labels = rowLabels(rows), ref = referenceLabels(labels);

		/* latency */
		var lines = labels.map(function(l) {
			return {
				label: l == 'gateway' ? _('Gateway') : l, key: l, color: self.colorFor(l), width: 2,
				vals: rows.map(function(r) { return rowRtt(r, l); })
			};
		});
		var maxRtt = 0;
		lines.forEach(function(ln) { ln.vals.forEach(function(v) { if (isnum(v) && v > maxRtt) maxRtt = v; }); });

		var losses = rows.map(function(r) { return rowLoss(r, ref); }),
		    bars = [], shades = [];

		rows.forEach(function(r, i) {
			if (isnum(losses[i]) && losses[i] > 0)
				bars.push({ i: i, frac: losses[i] / 100 });

			if (r.down_s > 0)
				shades.push(i);
		});

		var latLegend = lines.map(function(ln) { return { color: ln.color, label: ln.label }; });
		latLegend.push({ color: 'var(--lq-bad)', label: _('Packet loss') });
		if (shades.length)
			latLegend.push({ color: 'var(--lq-bad)', label: _('Outage'), faint: true });

		var latency = drawChart({
			title: _('Latency'), rows: rows, step: step, range: this.range,
			now: this.stat && this.stat.now, yMax: maxRtt * 1.1,
			lines: lines, bars: bars, shades: shades, legend: latLegend,
			tip: function(i) {
				var items = lines.map(function(ln) {
					return { color: ln.color, label: ln.label, value: fmtMs(ln.vals[i]) };
				});

				items.push({ color: 'var(--lq-bad)', label: _('Loss'), value: fmtPct(losses[i], 1) });

				if (rows[i].down_s > 0)
					items.push({ color: 'var(--lq-bad)', label: _('Outage'), value: fmtDur(rows[i].down_s) });

				return { title: fmtDateTime(rows[i].t), items: items };
			}
		});

		/* throughput */
		var rx = rows.map(function(r) { return rowRate(r, r.rx); }),
		    tx = rows.map(function(r) { return rowRate(r, r.tx); }),
		    maxBps = 0, marks = [];

		rows.forEach(function(r, i) {
			[ r.rx_peak, rx[i], r.tx_peak, tx[i] ].forEach(function(v) { if (isnum(v) && v > maxBps) maxBps = v; });

			if (r.st)
				marks.push(i);
		});

		var unit = maxBps >= 1e9 ? 1e9 : maxBps >= 1e6 ? 1e6 : 1e3,
		    unitName = unit == 1e9 ? 'Gbit/s' : unit == 1e6 ? 'Mbit/s' : 'kbit/s',
		    sc = function(v) { return isnum(v) ? v / unit : null; },
		    c1 = 'var(--lq-c1)', c2 = 'var(--lq-c2)',
		    tLegend = [
			{ color: c1, label: _('Download') }, { color: c2, label: _('Upload') },
			{ color: c1, label: _('Download peak'), faint: true }, { color: c2, label: _('Upload peak'), faint: true }
		    ];

		if (marks.length)
			tLegend.push({ color: 'currentColor', label: _('Speed test'), faint: true });

		var throughput = drawChart({
			title: _('Throughput') + ' (' + unitName + ')', rows: rows, step: step, range: this.range,
			now: this.stat && this.stat.now, yMax: maxBps / unit * 1.05,
			lines: [
				{ color: c1, opacity: .4, width: 1, nodot: true, vals: rows.map(function(r) { return sc(r.rx_peak); }) },
				{ color: c2, opacity: .4, width: 1, nodot: true, vals: rows.map(function(r) { return sc(r.tx_peak); }) },
				{ color: c1, width: 2, vals: rx.map(sc) },
				{ color: c2, width: 2, vals: tx.map(sc) }
			],
			marks: marks, legend: tLegend,
			tip: function(i) {
				var r = rows[i], items = [
					{ color: c1, label: _('Download'), value: fmtRate(rx[i]) },
					{ color: c2, label: _('Upload'), value: fmtRate(tx[i]) },
					{ color: c1, label: _('Download peak'), value: fmtRate(r.rx_peak) },
					{ color: c2, label: _('Upload peak'), value: fmtRate(r.tx_peak) },
					{ color: c1, label: _('Volume'), value: arrows(fmtBytes(r.rx), fmtBytes(r.tx)) }
				];

				if (r.st)
					items.push({ color: 'currentColor', label: _('Speed test'), value: _('yes') });

				return { title: fmtDateTime(r.t), items: items };
			}
		});

		dom.content(this.chartsEl, [ latency, throughput ]);
	},

	/* ----- tables ----- */

	eventLabel: function(type) {
		switch (type) {
		case 'internet_down': return _('Internet outage');
		case 'wan_down': return _('WAN disconnected');
		case 'link_down': return _('Link down');
		case 'monitor_gap': return _('Monitoring gap');
		}

		return type;
	},

	eventDetail: function(e) {
		var d = e.detail || {}, out = [];

		if (e.type == 'internet_down') {
			if (d.gateway_ok === true)
				out.push(_('gateway reachable'));
			else if (d.gateway_ok === false)
				out.push(_('gateway unreachable'));

			if (d.wan_up === true)
				out.push(_('WAN up'));
			else if (d.wan_up === false)
				out.push(_('WAN down'));
		}

		if (d.old_ip || d.new_ip)
			out.push(_('IP changed') + ': ' + (d.old_ip || '?') + ' → ' + (d.new_ip || '?'));

		if (e.type == 'monitor_gap')
			out.push(d.clean ? _('clean shutdown') : _('unclean shutdown'));

		return out.join(', ');
	},

	updateEvents: function() {
		var self = this, list = (this.ev || {}).events || [];

		if (!list.length) {
			dom.content(this.eventsEl, E('div', { 'class': 'lq-empty' }, _('No outages recorded.')));
			return;
		}

		dom.content(this.eventsEl, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Type')), E('th', { 'class': 'th' }, _('Start')), E('th', { 'class': 'th' }, _('End')),
				E('th', { 'class': 'th' }, _('Duration')), E('th', { 'class': 'th' }, _('Details'))
			])
		].concat(list.map(function(e) {
			var open = e.end == null,
			    dur = open ? (self.stat && isnum(self.stat.now) ? self.stat.now - e.start : null) : e.duration;

			return E('tr', { 'class': 'tr' + (open ? ' lq-ongoing' : '') }, [
				E('td', { 'class': 'td' }, self.eventLabel(e.type)),
				E('td', { 'class': 'td' }, fmtDateTime(e.start)),
				E('td', { 'class': 'td' }, open ? _('ongoing') : fmtDateTime(e.end)),
				E('td', { 'class': 'td' }, fmtDur(dur)),
				E('td', { 'class': 'td' }, self.eventDetail(e))
			]);
		}))));
	},

	updateTests: function() {
		var list = (this.st || {}).results || [];

		if (!list.length) {
			dom.content(this.testsEl, E('div', { 'class': 'lq-empty' }, _('No speed test yet')));
			return;
		}

		dom.content(this.testsEl, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Date')), E('th', { 'class': 'th' }, _('Trigger')),
				E('th', { 'class': 'th lq-num' }, _('Download')), E('th', { 'class': 'th lq-num' }, _('Upload')),
				E('th', { 'class': 'th lq-num' }, _('Ping')), E('th', { 'class': 'th lq-num' }, _('Jitter')),
				E('th', { 'class': 'th lq-num' }, _('Bufferbloat')), E('th', { 'class': 'th' }, _('Server'))
			])
		].concat(list.map(function(r) {
			var delta = (isnum(r.loaded_rtt) && isnum(r.idle_rtt)) ? r.loaded_rtt - r.idle_rtt : null;

			if (!r.ok)
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, fmtDateTime(r.t)),
					E('td', { 'class': 'td' }, r.trigger == 'schedule' ? _('Scheduled') : _('Manual')),
					E('td', { 'class': 'td lq-bad', colspan: 6 }, _('Failed') + (r.error ? ': ' + r.error : ''))
				]);

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, fmtDateTime(r.t)),
				E('td', { 'class': 'td' }, r.trigger == 'schedule' ? _('Scheduled') : _('Manual')),
				E('td', { 'class': 'td lq-num' }, fmtMbit(r.down)),
				E('td', { 'class': 'td lq-num' }, fmtMbit(r.up)),
				E('td', { 'class': 'td lq-num' }, fmtMs(r.ping)),
				E('td', { 'class': 'td lq-num' }, fmtMs(r.jitter)),
				E('td', { 'class': 'td lq-num' }, delta == null ? '–' : '+' + fmtMs(Math.max(0, delta))),
				E('td', { 'class': 'td' }, r.server || '–')
			]);
		}))));
	},

	updateDaily: function() {
		var rows = ((this.daily || {}).rows || []).slice(-30).reverse();

		if (!rows.length) {
			dom.content(this.dailyEl, E('div', { 'class': 'lq-empty' }, _('No data collected yet for this range.')));
			return;
		}

		var ref = referenceLabels(rowLabels(rows));

		dom.content(this.dailyEl, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Date')),
				E('th', { 'class': 'th lq-num' }, _('Downloaded')), E('th', { 'class': 'th lq-num' }, _('Uploaded')),
				E('th', { 'class': 'th lq-num' }, _('Average speed')), E('th', { 'class': 'th lq-num' }, _('Peak speed')),
				E('th', { 'class': 'th lq-num' }, _('Uptime')), E('th', { 'class': 'th lq-num' }, _('Loss')),
				E('th', { 'class': 'th lq-num' }, _('Average RTT'))
			])
		].concat(rows.map(function(r) {
			var up = r.mon_s > 0 ? 100 * (1 - (r.down_s || 0) / r.mon_s) : null,
			    sent = 0, recv = 0, sum = 0;

			ref.forEach(function(l) {
				var p = (r.p || {})[l];

				if (p) {
					sent += p[0] || 0;
					recv += p[1] || 0;
					sum += p[2] || 0;
				}
			});

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, r.d || fmtDate(r.t)),
				E('td', { 'class': 'td lq-num' }, fmtBytes(r.rx)),
				E('td', { 'class': 'td lq-num' }, fmtBytes(r.tx)),
				E('td', { 'class': 'td lq-num' }, arrows(fmtRate(rowRate(r, r.rx)), fmtRate(rowRate(r, r.tx)))),
				E('td', { 'class': 'td lq-num' }, arrows(fmtRate(r.rx_peak), fmtRate(r.tx_peak))),
				E('td', { 'class': 'td lq-num ' + (isnum(up) && up < 99.9 ? 'lq-warn' : '') }, fmtPct(up)),
				E('td', { 'class': 'td lq-num' }, sent > 0 ? fmtPct(100 * (1 - recv / sent)) : '–'),
				E('td', { 'class': 'td lq-num' }, recv > 0 ? fmtMs(sum / recv) : '–')
			]);
		}))));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
