'use strict';
'require view';
'require form';
'require tools.widgets as widgets';

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
				if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(parts[i]))
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

		return m.render();
	}
});
