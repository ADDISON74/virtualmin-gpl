
$force_load_features = 1;	# so that the latest feature-* files are used
$done_virtual_server_lib_funcs = 0;
do 'virtual-server-lib.pl';

sub module_install
{
&foreign_require("cron", "cron-lib.pl");

# Remember the first version we installed, to avoid showing new features
# from before it
$config{'first_version'} ||= &get_base_module_version();

# Make sure the remote.cgi page is accessible in non-session mode
local %miniserv;
&get_miniserv_config(\%miniserv);
local @sa = split(/\s+/, $miniserv{'sessiononly'});
if (&indexof("/$module_name/remote.cgi", @sa) < 0) {
	# Need to add
	push(@sa, "/$module_name/remote.cgi");
	$miniserv{'sessiononly'} = join(" ", @sa);
	&put_miniserv_config(\%miniserv);
	}

# Setup the default templates
foreach my $tf (@all_template_files) {
	&ensure_template($tf);
	}

# Perform a module config check, to ensure that quota and interface settings
# are correct.
&set_all_null_print();
$cerr = &html_tags_to_text(&check_virtual_server_config());
#if ($cerr) {
#	print STDERR "Warning: Module Configuration problem detected: $cerr\n";
#	}

if ($virtualmin_pro) {
	# Convert all existing domains with PHP to use new per-version .inis,
	# if they don't exist yet
	foreach my $d (&list_domains()) {
		next if (!$d->{'web'} || !$d->{'dir'});
		local $mode = &get_domain_php_mode($d);
		next if ($mode eq "mod_php");
		if (!-r "$d->{'home'}/etc/php4/php.ini" &&
		    !-r "$d->{'home'}/etc/php5/php.ini") {
			&save_domain_php_mode($d, $mode);
			}
		}
	}

# Force update of all Webmin users, to set new ACL options
&modify_all_webmin();
if ($virtualmin_pro) {
	&modify_all_resellers();
	}

# Setup the licence cron job
&setup_licence_cron();

# Fix up Procmail default delivery
if ($config{'spam'} && $virtualmin_pro) {
	&setup_default_delivery();
	}

# Enable logging in Procmail, if we are using it
if ($config{'spam'} && $virtualmin_pro) {
	&enable_procmail_logging();

	# And setup cron job to periodically process mail logs
	# Disabled, as it is generating too much load on big sites
	#local $job = &find_virtualmin_cron_job($maillog_cron_cmd);
	#if (!$job) {
	#	# Create, and run for the first time
	#	$job = { 'mins' => int(rand()*60),
	#		 'hours' => '0',
	#		 'days' => '*',
	#		 'months' => '*',
	#		 'weekdays' => '*',
	#		 'user' => 'root',
	#		 'active' => 1,
	#		 'command' => $maillog_cron_cmd };
	#	&cron::create_cron_job($job);
	#	&cron::create_wrapper($maillog_cron_cmd, $module_name,
	#			      "maillog.pl");
	#	}
	}

# Setup Cron job to periodically re-sync links in domains' spamassassin config
# directories, and to clean up old /tmp/clamav-* files
if ($config{'spam'} && $virtualmin_pro) {
	local $job = &find_virtualmin_cron_job($spamconfig_cron_cmd);
	if (!$job) {
		# Create, and run for the first time
		$job = { 'mins' => int(rand()*60),
			 'hours' => '*',
			 'days' => '*',
			 'months' => '*',
			 'weekdays' => '*',
			 'user' => 'root',
			 'active' => 1,
			 'command' => $spamconfig_cron_cmd };
		&cron::create_cron_job($job);
		&cron::create_wrapper($spamconfig_cron_cmd, $module_name,
				      "spamconfig.pl");
		}

	# And run now, just in case spamassassin was upgraded recently
	foreach my $d (grep { $_->{'spam'} } &list_domains()) {
		&create_spam_config_links($d);
		}
	}

# Fix up old procmail scripts that don't call the clam wrapper
if ($config{'virus'} && $virtualmin_pro) {
	&fix_clam_wrapper();
	}

# Check if we have enough memory to preload
local $lowmem;
&foreign_require("proc", "proc-lib.pl");
if (defined(&proc::get_memory_info)) {
	local ($real) = &proc::get_memory_info();
	if ($real*1024 <= 256*1024*1024) {
		# Less that 256 M .. don't preload
		$lowmem = 1;
		}
	}
if (&running_in_zone() || defined(&running_in_vserver) &&
			  &running_in_vserver()) {
	# Assume that zones and vservers don't have a lot of memory
	$lowmem = 1;
	}

if ($virtualmin_pro) {
	# Decide whether to preload, and then do it
	if ($config{'preload_mode'} eq '') {
		$config{'preload_mode'} = $lowmem ? 0 : 2;
		}
	if ($gconfig{'no_virtualmin_preload'}) {
		$config{'preload_mode'} = 0;
		}
	&save_module_config();
	&update_miniserv_preloads($config{'preload_mode'});
	}

# Run in package eval mode, to avoid loading the same module twice
local %miniserv;
&get_miniserv_config(\%miniserv);
if ($virtualmin_pro) {
	$miniserv{'eval_package'} = 1;
	}
&put_miniserv_config(\%miniserv);
if (&check_pid_file($miniserv{'pidfile'})) {
	&restart_miniserv();
	}

# Setup lookup domain daemon
if ($virtualmin_pro) {
	&foreign_require("init", "init-lib.pl");
	&foreign_require("proc", "proc-lib.pl");
	local $pidfile = "$ENV{'WEBMIN_VAR'}/lookup-domain-daemon.pid";
	&init::enable_at_boot(
	      "lookup-domain",
	      "Daemon for quickly looking up Virtualmin ".
	      "servers from procmail",
	      "$module_root_directory/lookup-domain-daemon.pl",
	      "kill `cat $pidfile`",
	      undef);
	if (&check_pid_file($pidfile)) {
		&init::stop_action("lookup-domain");
		sleep(5);	# Let port free up
		}
	&init::start_action("lookup-domain");
	}

# Force a restart of Apache, to apply writelogs.pl changes
if ($config{'web'}) {
	&require_apache();
	&restart_apache();
	}

if ($virtualmin_pro && !$config{'done_fix_autoreplies'}) {
	# Create links for existing autoreply aliases
	&set_alias_programs();
	foreach my $d (&list_domains()) {
		if ($d->{'mail'}) {
			&create_autoreply_alias_links($d);
			}
		}
	$config{'done_fix_autoreplies'} = 1;
	&save_module_config();
	}

# If installing for the first time, enable backup of all features by default
local @doms = &list_domains();
if (!@doms && !defined($config{'backup_feature_all'})) {
	$config{'backup_feature_all'} = 1;
	&save_module_config();
	}

# Build quick domain-lookup maps
&build_domain_maps();

# If supported by OpenSSH, create a group of users to deny SSH for
if (&foreign_installed("sshd")) {
	# Add to SSHd config
	&foreign_require("sshd", "sshd-lib.pl");
	local $conf = &sshd::get_sshd_config();
	local @denyg = &sshd::find_value("DenyGroups", $conf);
	local $commas = $sshd::version{'type'} eq 'ssh' &&
			$sshd::version{'number'} >= 3.2;
	if ($commas) {
		@denyg = split(/,/, $denyg[0]);
		}
	if (&indexof($denied_ssh_group, @denyg) < 0) {
		push(@denyg, $denied_ssh_group);
		&sshd::save_directive("DenyGroups", $conf,
				       join($commas ? "," : " ", @denyg));
		&flush_file_lines($sshd::config{'sshd_config'});
		&sshd::restart_sshd();
		}

	# Create the actual group, if missing
	&require_useradmin();
	&obtain_lock_unix();
	local @allgroups = &list_all_groups();
	local ($group) = grep { $_->{'group'} eq $denied_ssh_group } @allgroups;
	if (!$group) {
		local (%gtaken, %ggtaken);
		&build_group_taken(\%gtaken, \%ggtaken, \@allgroups);
		$group = { 'group' => $denied_ssh_group,
			   'members' => '',
			   'gid' => &allocate_gid(\%gtaken) };
		&foreign_call($usermodule, "set_group_envs", $group,
							     'CREATE_GROUP');
		&foreign_call($usermodule, "making_changes");
		&foreign_call($usermodule, "create_group", $group);
		&foreign_call($usermodule, "made_changes");
		}
	&release_lock_unix();
	}
&build_denied_ssh_group();

if ($virtualmin_pro) {
	# Create the cron job for sending in script ratings
	local $job = &find_virtualmin_cron_job($ratings_cron_cmd);
	if (!$job) {
		# Create, and run for the first time
		$job = { 'mins' => int(rand()*60),
			 'hours' => int(rand()*24),
			 'days' => '*',
			 'months' => '*',
			 'weekdays' => '*',
			 'user' => 'root',
			 'active' => 1,
			 'command' => $ratings_cron_cmd };
		&cron::create_cron_job($job);
		&cron::create_wrapper($ratings_cron_cmd, $module_name,
				      "sendratings.pl");
		&execute_command($ratings_cron_cmd);
		}
	}

# Create the cron job for collecting system info
&setup_collectinfo_job();

# Decide if sub-domains should be allowed, by checking if any exist
if ($config{'allow_subdoms'} eq '') {
	local @subdoms = grep { $_->{'subdom'} } &list_domains();
	$config{'allow_subdoms'} = @subdoms ? 1 : 0;
	&save_module_config();
	}

# Create the cron job for killing orphan php*-cgi processes
if ($virtualmin_pro) {
	local $job = &find_virtualmin_cron_job($fcgiclear_cron_cmd);
	if (!$job) {
		# Create, and run for the first time
		$job = { 'mins' => '0',
			 'hours' => '*',
			 'days' => '*',
			 'months' => '*',
			 'weekdays' => '*',
			 'user' => 'root',
			 'active' => 1,
			 'command' => $fcgiclear_cron_cmd };
		&cron::create_cron_job($job);
		&cron::create_wrapper($fcgiclear_cron_cmd, $module_name,
				      "fcgiclear.pl");
		}
	}

# Add ftp user to the groups for all domains that have FTP enabled
foreach my $d (&list_domains()) {
	if ($d->{'ftp'}) {
		local $ftp_user = &get_proftpd_user($d);
		if ($ftp_user) {
			&add_user_to_domain_group($d, $ftp_user, undef);
			}
		}
	}

# Mark PHP wrappers as immutable
if (defined(&set_php_wrappers_writable) && &has_command("chattr")) {
	foreach my $d (&list_domains()) {
		if ($d->{'web'}) {
			&set_php_wrappers_writable($d);
			}
		}
	}

# Prevent an un-needed module config check
if (!$cerr) {
	$config{'last_check'} = time()+1;
	&lock_file($module_config_file);
	&save_module_config();
	&unlock_file($module_config_file);
	&write_file("$module_config_directory/last-config", \%config);
	}

# Make all domains' .acl files non-world-readable
foreach my $d (grep { !$_->{'parent'} && $_->{'webmin'} } &list_domains()) {
	local @aclfiles = glob("$config_directory/*/$d->{'user'}.acl");
	foreach my $f (@aclfiles) {
		&set_ownership_permissions(undef, undef, 0600, $f);
		}
	}

# Make some module config files containing passwords non-world-readable.
# This is to fix an old Webmin bug that could expose passwords in
# /etc/webmin/*/config files
foreach my $m ("mysql", "postgresql", "ldap-client", "ldap-server",
	       "ldap-useradmin", $module_name) {
	local $mdir = "$config_directory/$m";
	if (-d $mdir) {
		&set_ownership_permissions(undef, undef, 0711,
					   $mdir, "$mdir/config");
		}
	}

# Record the install time for this version
local %itimes;
&read_file($install_times_file, \%itimes);
local $basever = &get_base_module_version();
if (!$itimes{$basever}) {
	$itimes{$basever} = time();
	&write_file($install_times_file, \%itimes);
	}
}

