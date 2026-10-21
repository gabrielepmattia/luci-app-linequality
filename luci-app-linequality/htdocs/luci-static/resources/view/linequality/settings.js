'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require tools.widgets as widgets';

var callNotifyTest = rpc.declare({
	object: 'linequality',
	method: 'notify_test',
	expect: { '': {} }
});

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('linequality', _('Line quality'),
			_('Configure the WAN line quality monitor: which interface and hosts to probe, where to store the history and when to run speed tests.'));

		s = m.section(form.NamedSection, 'main', 'linequality');
		s.addremove = false;
		s.anonymous = true;

		s.tab('general', _('General'));
		s.tab('probes', _('Probes'));
		s.tab('storage', _('Storage'));
		s.tab('speedtest', _('Speed test'));
		s.tab('notify', _('Notifications'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'),
			_('Run the line quality collector.'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('general', widgets.NetworkSelect, 'interface', _('WAN interface'),
			_('The logical interface whose connection is monitored (traffic counters, connection state and public address).'));
		o.nocreate = true;
		o.default = 'wan';
		o.rmempty = false;

		o = s.taboption('probes', form.DynamicList, 'target', _('Probe targets'),
			_('IP addresses pinged once per second to measure latency, jitter and packet loss. The special value "gateway" is resolved automatically to the provider-side address of the connection. Internet outages are detected when all targets other than the gateway stop answering.'));
		o.datatype = 'or(ipaddr,"gateway")';
		o.placeholder = '1.1.1.1';
		o.rmempty = false;

		o = s.taboption('probes', form.Value, 'down_after', _('Outage threshold'),
			_('Number of consecutive seconds with every probe lost before an internet outage is recorded.'));
		o.datatype = 'range(1,60)';
		o.placeholder = '3';
		o.default = '3';

		o = s.taboption('probes', form.Value, 'loss_threshold', _('Packet loss threshold'),
			_('Packet loss, in percent over 60 seconds on the reference targets, above which a degraded-line event is recorded.'));
		o.datatype = 'range(1,100)';
		o.placeholder = '5';
		o.default = '5';

		o = s.taboption('probes', widgets.NetworkSelect, 'interface6', _('IPv6 interface'),
			_('The logical interface that holds the delegated IPv6 prefix, used to record prefix changes. Leave empty to use the WAN interface name followed by 6 if it exists.'));
		o.nocreate = true;
		o.optional = true;

		o = s.taboption('probes', form.Flag, 'dns_enabled', _('Measure DNS response time'),
			_('Periodically look up a few host names and record how long the resolver takes to answer.'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('probes', form.Value, 'dns_server', _('DNS server'),
			_('Resolver whose response time is measured. Leave empty to use the router\'s own resolver (127.0.0.1).'));
		o.datatype = 'ipaddr';
		o.placeholder = '127.0.0.1';
		o.optional = true;
		o.depends('dns_enabled', '1');

		o = s.taboption('probes', form.DynamicList, 'dns_name', _('DNS names'),
			_('Host names looked up in turn on the DNS server. If empty: openwrt.org, wikipedia.org and example.com.'));
		o.datatype = 'hostname';
		o.placeholder = 'example.com';
		o.optional = true;
		o.depends('dns_enabled', '1');

		o = s.taboption('probes', form.Value, 'dns_interval', _('DNS interval'),
			_('Seconds between two DNS lookups.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '30';
		o.default = '30';
		o.depends('dns_enabled', '1');

		o = s.taboption('storage', form.Value, 'data_dir', _('Data directory'),
			_('Where the history is stored. The default is persistent flash storage; samples are written only once per hour to limit flash wear.'));
		o.placeholder = '/etc/linequality';
		o.default = '/etc/linequality';

		o = s.taboption('storage', form.Value, 'hourly_retention_days', _('Hourly data retention'),
			_('Days of hourly samples to keep.'));
		o.datatype = 'uinteger';
		o.placeholder = '90';
		o.default = '90';

		o = s.taboption('storage', form.Value, 'daily_retention_days', _('Daily data retention'),
			_('Days of daily summaries to keep.'));
		o.datatype = 'uinteger';
		o.placeholder = '1095';
		o.default = '1095';

		o = s.taboption('speedtest', form.Value, 'speedtest_schedule', _('Schedule'),
			_('Local times of day for automatic speed tests, separated by spaces, for example "03:30 15:30". Leave empty to disable scheduled tests. Requires the librespeed-cli package.'));
		o.placeholder = '03:30';
		o.validate = function(section_id, value) {
			if (value == null || value.trim() === '')
				return true;

			var parts = value.trim().split(/\s+/);

			for (var i = 0; i < parts.length; i++)
				if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(parts[i]))
					return _('Expected times in HH:MM format, separated by spaces');

			return true;
		};

		o = s.taboption('speedtest', form.Value, 'speedtest_duration', _('Test duration'),
			_('Seconds spent on each of the download and upload phases. Note that on a multi-gigabit line each test can transfer several GB of data.'));
		o.datatype = 'range(3,60)';
		o.placeholder = '10';
		o.default = '10';

		o = s.taboption('speedtest', form.Value, 'speedtest_concurrent', _('Parallel connections'),
			_('Number of simultaneous connections used by the test.'));
		o.datatype = 'range(1,16)';
		o.placeholder = '3';
		o.default = '3';

		o = s.taboption('speedtest', form.Value, 'speedtest_server', _('Server ID'),
			_('Optional LibreSpeed server ID. Leave empty to pick the closest server automatically.'));
		o.datatype = 'uinteger';
		o.optional = true;

		o = s.taboption('speedtest', form.Value, 'plan_down', _('Contracted download speed (Mbit/s)'),
			_('The download speed of your subscription. Speed tests are compared with it. Leave empty if unknown.'));
		o.datatype = 'ufloat';
		o.placeholder = '1000';
		o.optional = true;

		o = s.taboption('speedtest', form.Value, 'plan_up', _('Contracted upload speed (Mbit/s)'),
			_('The upload speed of your subscription. Speed tests are compared with it. Leave empty if unknown.'));
		o.datatype = 'ufloat';
		o.placeholder = '300';
		o.optional = true;

		o = s.taboption('notify', form.Value, 'notify_url', _('Notification URL'),
			_('Where to send notifications: an ntfy topic URL (for example https://ntfy.sh/my-topic) or a webhook URL. Leave empty to disable notifications. Requires curl.'));
		o.datatype = 'string';
		o.placeholder = 'https://ntfy.sh/my-topic';
		o.optional = true;
		o.validate = function(section_id, value) {
			if (value == null || value === '' || /^https?:\/\/\S+$/.test(value))
				return true;

			return _('Expected an http:// or https:// URL');
		};

		o = s.taboption('notify', form.ListValue, 'notify_type', _('Notification type'));
		o.value('ntfy', 'ntfy');
		o.value('webhook', _('Webhook (JSON)'));
		o.default = 'ntfy';

		o = s.taboption('notify', form.Value, 'notify_token', _('Access token'),
			_('Optional. Sent as a bearer token in the Authorization header.'));
		o.password = true;
		o.optional = true;

		o = s.taboption('notify', form.ListValue, 'notify_language', _('Message language'));
		o.value('en', 'English');
		o.value('it', 'Italiano');
		o.default = 'en';

		o = s.taboption('notify', form.Value, 'notify_min_outage', _('Minimum outage'),
			_('Seconds. Only outages at least this long are notified, when the connection is restored.'));
		o.datatype = 'uinteger';
		o.placeholder = '60';
		o.default = '60';

		o = s.taboption('notify', form.Flag, 'notify_loss', _('Notify packet loss'),
			_('Also notify when the line was degraded by packet loss.'));
		o.default = o.disabled;

		o = s.taboption('notify', form.Value, 'notify_speed_pct', _('Slow speed test alert'),
			_('Notify when a speed test is below this percentage of the contracted speed. 0 disables the alert. Requires the contracted speed.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '0';
		o.default = '0';

		o = s.taboption('notify', form.Flag, 'notify_gap', _('Notify monitoring gaps'),
			_('Notify at startup when the router or the service was down for a while.'));
		o.default = o.enabled;

		o = s.taboption('notify', form.DummyValue, '_test', _('Test'));
		o.cfgvalue = function() {
			return E('div', {}, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					click: ui.createHandlerFn(this, function(ev) {
						ev.preventDefault();

						return callNotifyTest().then(function(res) {
							if (res && res.error == 'disabled')
								ui.addNotification(null, E('p', {}, _('Notifications are disabled: set a notification URL, save and apply the settings first.')), 'danger');
							else if (res && res.error == 'not_available')
								ui.addNotification(null, E('p', {}, _('Notifications are not available: curl is not installed.')), 'danger');
							else if (res && res.error)
								ui.addNotification(null, E('p', {}, _('Unable to send the test notification: %s').format(res.error)), 'danger');
							else
								ui.addNotification(null, E('p', {}, _('Test notification queued. It should arrive within a minute.')), 'info');
						}).catch(function(e) {
							ui.addNotification(null, E('p', {}, _('Unable to send the test notification: %s').format(e.message || e)), 'danger');
						});
					})
				}, _('Send test notification')),
				E('div', { 'class': 'cbi-value-description' },
					_('Save and apply the settings first: the test uses the saved configuration.'))
			]);
		};

		return m.render();
	}
});
