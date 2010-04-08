# Functions for migrating a cpanel backup

# migration_cpanel_validate(file, domain, [user], [&parent], [prefix], [pass])
# Make sure the given file is a cPanel backup, and contains the domain
sub migration_cpanel_validate
{
local ($file, $dom, $user, $parent, $prefix, $pass) = @_;
local ($ok, $root) = &extract_cpanel_dir($file);
$ok || return ("Not a cPanel tar.gz file : $root");
local $daily = "$root/backup/cpbackup/daily";
local ($homedir) = glob("$root/*/homedir");
local $datastore = "$root/.cpanel-datastore";
-d $daily || -d $homedir || -d $datastore ||
	return ("Not a cPanel daily or home directory backup file");

# Try to work out the domain
if (!$dom) {
	local @domfiles = glob("$root/*/vf/*");
	if (!@domfiles) {
		@domfiles = glob("$root/vf/*");
		}
	local @doms = map { /\/vf\/([^\/]+)$/; $1 } @domfiles;
	if (@doms > 1) {
		# Hack to work out primary domain
		local $ds = "$homedir/.cpanel-datastore";
		$ds = $datastore if (!-d $ds);
		opendir(DATASTORE, $ds);
		foreach my $gdi (readdir(DATASTORE)) {
			if ($gdi =~ /^apache_GETDOMAINIP_(\S+)$/) {
				$gdi{$1} = 1;
				}
			}
		closedir(DATASTORE);
		if (scalar(keys %gdi)) {
			# Can limit by domain IP to find the master
			@doms = grep { $gdi{$_} } @doms;
			}
		else {
			# Look at the cp/username file
			local ($cpfile) = glob("$root/*/cp/*");
			if ($cpfile && -r $cpfile) {
				local %cp;
				&read_env_file($cpfile, \%cp);
				@doms = ( $cp{'DNS'} );
				}
			}
		}
	if (@doms == 1) {
		$dom = $doms[0];
		}
	elsif (@doms > 1) {
		return ("More than one domain name was found in the cPanel backup : ".join(" ", @doms));
		}
	else {
		return ("Could not work on domain name from cPanel backup");
		}
	}

if (-d $daily) {
	# Older style backup - check for user and Apache domain file
	if (!$user) {
		local ($tgz) = glob("$daily/*.tar.gz");
		$tgz =~ /\/([^\/]+)\.tar\.gz$/ ||
		    return ("Could not work out username from cPanel backup");
		$user = $1;
		}
	-r "$daily/$user.tar.gz" ||
		return ("Could not find directory for $user in backup");
	local $httpd = &extract_cpanel_file("$daily/files/_etc_httpd_conf_httpd.conf.gz");
	local ($vconf, $virt) = &get_apache_virtual($dom, undef, $httpd);
	$vconf ||
	    return ("Could not find Apache virtual server $dom in backup");
	}
elsif (-d $homedir) {
	# Newer style backup - check for aliases file
	($vfdom) = glob("$root/*/vf/$dom");
	-r $vfdom ||
	    return ("Could not find mail aliases file for $dom in backup");
	if (!$user && $homedir =~ /\/backup-([^\/]+)_([^\/]+)\//) {
		$user = $2;
		}
	if (!$user) {
		opendir(ROOT, $root);
		local @rootfiles = grep { !/^\./ } readdir(ROOT);
		closedir(ROOT);
		$user = $rootfiles[0];
		}
	$user || return ("Could not work out username from cPanel backup");
	}
else {
	# Home-only backup
	$user || return ("Username must be supplied for this type of cPanel backup");
	}

# Password is needed for cPanel migrations
if (!$parent && !$pass) {
	return ("A password must be supplied for cPanel migrations");
	}

return (undef, $dom, $user, $pass);
}

# migration_cpanel_migrate(file, domain, username, create-webmin, template-id,
#			   ip-address, virtmode, pass, [&parent], [prefix],
#			   virt-already, [email], [netmask])
# Actually extract the given cPanel backup, and return the list of domains
# created.
sub migration_cpanel_migrate
{
local ($file, $dom, $user, $webmin, $template, $ip, $virt, $pass, $parent,
       $prefix, $virtalready, $email, $netmask) = @_;
local ($ok, $root) = &extract_cpanel_dir($file);
$ok || &error("Failed to extract backup : $root");
local $daily = "$root/backup/cpbackup/daily";
local $datastore = "$root/.cpanel-datastore";
local $tmpl = &get_template($template);
local $tar = &get_tar_command();

# Check for prefix clash
$prefix ||= &compute_prefix($dom, undef, $parent, 1);
local $pclash = &get_domain_by("prefix", $prefix);
$pclash && &error("A virtual server using the prefix $prefix already exists");

# Get shells for users
local ($nologin_shell, $ftp_shell, undef, $def_shell) =
	&get_common_available_shells();
$nologin_shell ||= $def_shell;
$ftp_shell ||= $def_shell;

# Work out the username again if it wasn't supplied
if (!$user) {
	local ($homedir) = glob("$root/*/homedir");
	if (-d $daily) {
		local ($tgz) = glob("$daily/*.tar.gz");
		$tgz =~ /\/([^\/]+)\.tar\.gz$/;
		$user = $1;
		}
	elsif (-d $homedir) {
		$homedir =~ /\/backup-([^\/]+)_([^\/]+)\//;
		$user = $2;
		}
	$user || &error("Could not work out username automatically");
	}
local $group = $user;
local $ugroup = $group;

# First work out what features we have ..
&$first_print("Checking for cPanel features ..");
local @got = ( "dir", $parent ? () : ("unix"), "web" );
push(@got, "webmin") if ($webmin && !$parent);
local $userdir;
local $homesrc;
if (-d $daily) {
	local $named = &extract_cpanel_file("$daily/files/_etc_named.conf.gz");
	local $zone;
	if ($named) {
		# Check for DNS zone
		$zone = &get_bind_zone($dom, undef, $named);
		push(@got, "dns") if ($zone);
		}
	local $localdomains = &extract_cpanel_file("$daily/files/_etc_localdomains.gz");
	if ($localdomains) {
		# Check for mail domain
		local $lref = &read_file_lines($localdomains);
		foreach my $l (@$lref) {
			push(@got, "mail") if ($l eq $dom);
			}
		}
	$userdir = &extract_cpanel_dir("$daily/$user.tar.gz")."/$user";
	$homesrc = "$userdir/homedir";
	}
elsif (-d $datastore) {
	# For a home-based only backup, assume we have web, mail and DNS
	push(@got, "dns", "mail");
	$userdir = $homesrc = $root;
	}
else {
	# For a homedir only backup, assume we have web, mail and DNS
	push(@got, "dns", "mail");
	if (-d "$root/$user") {
		# Sub-directory is named after user
		$userdir = "$root/$user";
		}
	else {
		# Sub-directory has date-based name
		($userdir) = glob("$root/*");
		}
	$homesrc = "$userdir/homedir";
	$datastore = "$homesrc/.cpanel-datastore";
	if (-d "$homesrc/.cpanel/datastore") {
		$datastore = "$homesrc/.cpanel/datastore";
		}
	}

# Work out if the original domain was a sub-server in cPanel
local $waschild = 0;
local $wasuser = $dom;
$wasuser =~ s/\..*$//;
local $aliasdom;
if (-r "$datastore/apache_LISTMULTIPARKED_0") {
	# Sub-servers are in this config file. We can also work out the original
	# 'username' for the sub-directory.
	local $subs = &read_file_contents(
		"$datastore/apache_LISTMULTIPARKED_0");
	if ($subs =~ /(\/[a-z0-9\.\-_\/]+)[^a-z0-9\.\-]+\Q$dom\E[^a-z0-9\.\-]+([a-z0-9\.\-]+)?/i) {
		$waschild = 1;
		my $wasdir = $1;
		$aliasdom = $2;
		if ($wasdir =~ /public_html\/(.*)$/) {
			$wasuser = $1;
			}
		$aliasdom = undef if ($aliasdom !~ /\./);	# Data error
		}
	}
elsif (-d "$homesrc/tmp/webalizer") {
	# Sub-servers had separate webalizer config
	$waschild = -d "$homesrc/tmp/webalizer/$dom" ? 1 : 0;
	}
else {
	# Can't be sure, so guess
	$waschild = $parent ? 1 : 0;
	}

# Check for Webalizer and AWstats
local $webalizer = $waschild ? "$homesrc/tmp/webalizer/$dom"
			     : "$homesrc/tmp/webalizer";
if (-d $webalizer) {
	push(@got, "webalizer");
	}
if (-r "$homesrc/tmp/awstats/awstats.$dom.conf") {
	push(@got, "virtualmin-awstats");
	}

if (-s "$userdir/mysql.sql" && !$waschild) {
	# Check for mysql
	local $mycount = 0;
	local $mydir = "$userdir/mysql";
	opendir(MYDIR, $mydir);
	while($myf = readdir(MYDIR)) {
		if ($myf =~ /^(\Q$user\E_\S*).sql$/ ||
		    $myf eq "$user.sql") {
			$mycount++;
			}
		}
	closedir(MYDIR);
	push(@got, "mysql") if ($mycount);
	}
if ($virt) {
	# Enable ProFTPd, if we have a private IP
	push(@got, "ftp");
	}
if ($virt && -s "$userdir/sslcerts/www.$dom.crt" &&
	     -s "$userdir/sslkeys/www.$dom.key") {
	# Enable SSL, if we have a private IP and if the key was found
	push(@got, "ssl");
	}

# Look for mailing lists
local ($ml, @lists);
opendir(MM, "$userdir/mm");
foreach $ml (readdir(MM)) {
	if ($ml =~ /^(\S+)_\Q$dom\E$/) {
		push(@lists, $1);
		}
	}
closedir(MM);
if (@lists && &plugin_defined("virtualmin-mailman", "create_list")) {
	push(@got, "virtualmin-mailman");
	}

# Tell the user what we have got
@got = &show_check_migration_features(@got);
local %got = map { $_, 1 } @got;

# Work out user and group IDs
local ($gid, $ugid, $uid, $duser);
if ($parent) {
	# UID and GID come from parent
	$gid = $parent->{'gid'};
	$ugid = $parent->{'ugid'};
	$uid = $parent->{'uid'};
	$duser = $parent->{'user'};
	$group = $parent->{'group'};
	$ugroup = $parent->{'ugroup'};
	}
else {
	# IDs are allocated by setup_unix
	$uid = $gid = $ugid = undef;
	$duser = $user;
	}

local $quota;
if (-r "$userdir/quota") {
	# Get the quota (from home directory backup)
	open(QUOTA, "$userdir/quota");
	$quota = <QUOTA>;
	close(QUOTA);
	$quota = int($quota) * 1024;	# cpanel quotas are in MB
	}
elsif (-r "$datastore/quota_-v") {
	# Get the quota (from v10 backup)
	local $_;
	open(QUOTA, "$datastore/quota_-v");
	while(<QUOTA>) {
		if (/^\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)/) {
			$quota = $2;
			}
		}
	close(QUOTA);
	}

# Create the virtual server object
local %dom;
$prefix ||= &compute_prefix($dom, $group, $parent, 1);
local $plan = $parent ? &get_plan($parent->{'plan'}) : &get_default_plan();
%dom = ( 'id', &domain_id(),
	 'dom', $dom,
         'user', $duser,
         'group', $group,
         'ugroup', $ugroup,
         'uid', $uid,
         'gid', $gid,
         'ugid', $ugid,
         'owner', "Migrated cPanel server $dom",
         'email', $email ? $email : $parent ? $parent->{'email'} : undef,
         'name', !$virt,
         'ip', $ip,
         'netmask', $netmask,
	 'dns_ip', $virt || $config{'all_namevirtual'} ? undef
						       : &get_dns_ip(),
         'virt', $virt,
         'virtalready', $virtalready,
	 $parent ? ( 'pass', $parent->{'pass'} )
		 : ( 'pass', $pass ),
	 'source', 'migrate.cgi',
	 'template', $template,
	 'plan', $plan->{'id'},
	 'parent', $parent ? $parent->{'id'} : undef,
	 'reseller', $parent ? $parent->{'reseller'} : undef,
	 'prefix', $prefix,
	 'no_tmpl_aliases', 1,
	 'no_mysql_db', $got{'mysql'} ? 1 : 0,
	 'nocreationmail', 1,
	 'nocopyskel', 1,
	 'parent', $parent ? $parent->{'id'} : undef,
        );
if (!$parent) {
	&set_limits_from_plan(\%dom, $plan);
	$dom{'quota'} = $quota;
	$dom{'uquota'} = $quota;
	&set_capabilities_from_plan(\%dom, $plan);
	}
$dom{'db'} = &database_name(\%dom);
foreach my $f (@features, &list_feature_plugins()) {
	$dom{$f} = $got{$f} ? 1 : 0;
	}
&set_featurelimits_from_plan(\%dom, $plan);

# Work out the master admin MySQL password
if (open(MYSQL, "$userdir/mysql.sql")) {
	while(<MYSQL>) {
		s/\r|\n//g;
		if (/^GRANT USAGE ON \*\.\* TO '(\S+)'\@'(\S+)' IDENTIFIED BY PASSWORD '(\S+)';/ && $1 eq $user) {
			$dom{'mysql_enc_pass'} = $3;
			}
		}
	close(MYSQL);
	}

local $orighome;
if (-d $daily) {
	# Work out home directory (use cpanel home by default)
	local $httpd = &extract_cpanel_file("$daily/files/_etc_httpd_conf_httpd.conf.gz");
	local ($srcvconf, $srcvirt) = &get_apache_virtual($dom, undef, $httpd);
	$orighome = &apache::find_directive("DocumentRoot", $srcvirt);
	$orighome =~ s/\/public_html$//;
	}
else {
	# Try to stick with cpanel home standard (/home/$user)
	if (!$waschild) {
		$orighome = "/home/$user";
		}
	}
if ($orighome && &is_under_directory($home_base, $orighome)) {
	# Use same home directory as cPanel
	$dom{'home'} = $orighome;
	}
else {
	# Use Virtualmin's home
	$dom{'home'} = &server_home_directory(\%dom, $parent);
	}

# Set cgi directories to cpanel standard
$dom{'cgi_bin_dir'} = "public_html/cgi-bin";
$dom{'cgi_bin_path'} = "$dom{'home'}/$dom{'cgi_bin_dir'}";
$dom{'cgi_bin_correct'} = 1;	# So that setup_web doesn't fix it

&complete_domain(\%dom);

# Check for various clashes
&$first_print("Checking for clashes and dependencies ..");
$derr = &virtual_server_depends(\%dom);
if ($derr) {
	&$second_print($derr);
	return ( );
	}
$cerr = &virtual_server_clashes(\%dom);
if ($cerr) {
	&$second_print($cerr);
	return ( );
	}
&$second_print(".. all OK");

# Create the initial server
&$first_print("Creating initial virtual server $dom ..");
&$indent_print();
local $err = &create_virtual_server(\%dom, $parent,
				    $parent ? $parent->{'user'} : undef);
&$outdent_print();
if ($err) {
	&$second_print($err);
	return ( );
	}
else {
	&$second_print(".. done");
	}
local @rvdoms = ( \%dom );

# Extra homedir.tar if needed
local $hometar = "$userdir/homedir.tar";
if (-r $hometar) {
	&$first_print("Extracting home directory TAR file ..");
	local $out;
	if (!-d $homesrc) {
		&make_dir($homesrc, 0755);
		}
	&execute_command("cd ".quotemeta($homesrc)." && ".
			 "$tar xf ".quotemeta($hometar), undef, \$out, \$out);
	if ($?) {
		&$second_print(".. TAR failed : <tt>$out</tt>");
		}
	else {
		&$second_print(".. done");
		}
	}

# Migrate Apache configuration
if ($got{'web'} && -d $daily) {
	&$first_print("Copying Apache directives ..");
	if ($srcvconf) {
		# Copy any directives not set by Virtualmin
		local $conf = &apache::get_config();
		local ($vconf, $virt) = &get_apache_virtual($dom, undef);
		local %dirs;
		foreach my $a (@$virt) {
			next if ($a->{'type'});
			$dirs{$a->{'name'}}++;
			}
		$dirs{'ScriptAlias'} = 0;	# Always copy this
		$dirs{'ServerAlias'} = 0;	# and this
		$dirs{'BytesLog'} = 1;		# Not supported
		$dirs{'User'} = 1;		# Don't copy user-related
		$dirs{'Group'} = 1;		# settings, as Virtualmin will
		$dirs{'SuexecUserGroup'} = 1;	# have already set them
		local %vals;
		foreach my $a (@$srcvirt) {
			next if ($a->{'type'} || $dirs{$a->{'name'}});
			if ($dom{'home'} ne $orighome) {
				$a->{'value'} =~ s/$orighome/$dom{'home'}/g;
				}
			push(@{$vals{$a->{'name'}}}, $a->{'value'});
			}
		foreach my $an (keys %vals) {
			&apache::save_directive($an, $vals{$an}, $virt, $conf);
			}
		&$second_print(".. done");
		&register_post_action(\&restart_apache) if (!$got{'ssl'});
		}
	else {
		&$second_print(".. could not find Apache configuration");
		}
	}
elsif ($got{'web'}) {
	# Just adjust cgi-bin directory to match cPanel
	local $conf = &apache::get_config();
	local ($virt, $vconf) = &get_apache_virtual($dom, undef);
	if ($virt) {
		&apache::save_directive("ScriptAlias",
			[ "/cgi-bin $dom{'home'}/public_html/cgi-bin" ],
			$vconf, $conf);
		&flush_file_lines($virt->{'file'});
		&register_post_action(\&restart_apache) if (!$got{'ssl'});
		}
	&save_domain(\%dom);
	&add_script_language_directives(\%dom, $tmpl, $dom{'web_port'});
	}
$dom{'cgi_bin_correct'} = 0;	# So that it is computed from now on

if ($got{'ssl'}) {
	# Copy and use the SSL certs that came with the domain
	&$first_print("Copying SSL certificate and key ..");
	&execute_command("cp ".quotemeta("$userdir/sslcerts/www.$dom.crt")." ".
		     quotemeta($dom{'ssl_cert'}));
	&execute_command("cp ".quotemeta("$userdir/sslcerts/www.$dom.key")." ".
		     quotemeta($dom{'ssl_key'}));
	&register_post_action(\&restart_apache, 1);
	&$second_print(".. done");
	}

# Migrate DNS domain
if ($got{'dns'} && -d $daily) {
	&$first_print("Copying and fixing DNS records ..");
	&require_bind();
	local $named = &extract_cpanel_dir("$daily/dirs/_var_named.tar.gz");
	local $zsrcfile = &bind8::find_value("file", $zone->{'members'});
	local $newzone = &get_bind_zone($dom);
	local $zdstfile = &bind8::find_value("file", $newzone->{'members'});
	if (-r "$named/$zsrcfile") {
		&execute_command("cp ".quotemeta("$named/$zsrcfile")." ".
			     quotemeta(&bind8::make_chroot($zdstfile)));
		local @recs = &bind8::read_zone_file($zdstfile, $dom);
		foreach my $r (@recs) {
			my $change = 0;
			if (($r->{'name'} eq $dom."." ||
			     $r->{'name'} eq "www.".$dom."." ||
			     $r->{'name'} eq "ftp.".$dom."." ||
			     $r->{'name'} eq "mail.".$dom.".") &&
			    $r->{'type'} eq 'A') {
				# Fix IP in domain record
				$r->{'values'} = [ $dom{'ip'} ];
				$change++;
				}
			elsif ($r->{'name'} eq $dom."." && $r->{'type'} eq 'NS') {
				# Set NS record to this server
				local $master = $bconfig{'default_prins'} ||
						&get_system_hostname();
				$master .= "." if ($master !~ /\.$/);
				$r->{'values'} = [ $master ];
				$change++;
				}
			if ($change) {
				&bind8::modify_record($zdstfile, $r, $r->{'name'},
						      $r->{'ttl'}, $r->{'class'},
						      $r->{'type'},
						      join(" ", @{$r->{'values'}}),
						      $r->{'comment'});
				}
			}
		&$second_print(".. done");
		&register_post_action(\&restart_bind);
		}
	else {
		&$second_print(".. could not find records file in backup!");
		}
	}

local $out;
local $ht = &public_html_dir(\%dom);
if ($waschild) {
	# Migrate web directory
	local $qht = quotemeta($ht);
	local $qhtsrc = "$homesrc/public_html/$wasuser";
	&$first_print("Copying web pages to $ht ..");
	&execute_command("cd $qhtsrc && ".
			 "($tar cf - . | (cd $qht && $tar xf -))",
			 undef, \$out, \$out);
	}
else {
	# Migrate home directory contents (except logs and mail)
	&$first_print("Copying home directory to $dom{'home'} ..");
	local $qhome = quotemeta($dom{'home'});
	local $xtemp = &transname();
	&open_tempfile(XTEMP, ">$xtemp");
	&print_tempfile(XTEMP, "logs\n");
	&print_tempfile(XTEMP, "./logs\n");
	&print_tempfile(XTEMP, "mail\n");
	&print_tempfile(XTEMP, "./mail\n");
	&close_tempfile(XTEMP);
	&execute_command("cd $homesrc && ".
			 "($tar cfX - $xtemp . | (cd $qhome && $tar xf -))",
			 undef, \$out, \$out);
	}
if ($?) {
	&$second_print(".. copy failed : <tt>$out</tt>");
	}
else {
	&$second_print(".. done");
	}

# Fix up home ownership and permissions
&$first_print("Fixing home directory permissions ..");
if (defined(&set_php_wrappers_writable)) {
	&set_php_wrappers_writable(\%dom, 1);
	}
&set_home_ownership(\%dom);
&system_logged("chmod '$uconfig{'homedir_perms'}' ".
	       quotemeta($dom{'home'}));
foreach my $sd (&virtual_server_directories(\%dom)) {
	&system_logged("chmod $sd->[1] ".
		       quotemeta("$dom{'home'}/$sd->[0]"));
	}
if (defined(&set_php_wrappers_writable)) {
	&set_php_wrappers_writable(\%dom, 0);
	}
&$second_print(".. done");

# Lock the user DB and build list of used IDs
&obtain_lock_unix(\%dom);
&obtain_lock_mail(\%dom);
local (%taken, %utaken);
&build_taken(\%taken, \%utaken);

&foreign_require("mailboxes", "mailboxes-lib.pl");
local %usermap;
if ($got{'mail'}) {
	# Migrate mail users
	&$first_print("Re-creating mail users ..");
	local $mcount = 0;
	local (%pass, %quota);
	local $_;
	open(SHADOW, "$homesrc/etc/$dom/shadow");
	while(<SHADOW>) {
		s/\r|\n//g;
		local ($suser, $spass) = split(/:/, $_);
		$pass{$suser} = $spass;
		}
	close(SHADOW);
	local $_;
	local $bsize = &quota_bsize("home");
	open(QUOTA, "$homesrc/etc/$dom/quota");
	while(<QUOTA>) {
		s/\r|\n//g;
		local ($quser, $qquota) = split(/:/, $_);
		$quota{$quser} = $bsize ? int($qquota/$bsize) : 0;
		}
	close(QUOTA);
	local $_;
	open(PASSWD, "$homesrc/etc/$dom/passwd");
	while(<PASSWD>) {
		# Create the user
		s/\r|\n//g;
		local ($muser, $mdummy, $muid, $mgid, $mreal, $mdir, $mshell) =
			split(/:/, $_);
		next if (!$muser);
		next if ($muser =~ /_logs$/);		# Special logs user
		next if ($muser eq $user && !$parent);	# Domain owner
		local $uinfo = &create_initial_user(\%dom);
		$uinfo->{'user'} = &userdom_name(lc($muser), \%dom);
		$uinfo->{'pass'} = $pass{$muser};
		$uinfo->{'uid'} = &allocate_uid(\%taken);
		$uinfo->{'gid'} = $dom{'gid'};
		$uinfo->{'real'} = $mreal;
		$uinfo->{'home'} = "$dom{'home'}/$config{'homes_dir'}/".
				   lc($muser);
		$uinfo->{'shell'} = $nologin_shell->{'shell'};
		$uinfo->{'email'} = lc($muser)."\@$dom";
		$uinfo->{'qquota'} = $quota{$muser};
		$uinfo->{'quota'} = $quota{$muser};
		$uinfo->{'mquota'} = $quota{$muser};
		&create_user($uinfo, \%dom);
		&create_user_home($uinfo, \%dom, 1);
		$taken{$uinfo->{'uid'}}++;
		local ($crfile, $crtype) = &create_mail_file($uinfo);

		# Move his mail files
		local $mailsrc = "$homesrc/mail/$dom/$muser";
		local $sfdir = $mailboxes::config{'mail_usermin'};
		local $sftype = $sfdir eq 'Maildir' ? 1 : 0;
		local $sfpath = "$uinfo->{'home'}/$sfdir";
		if (!-d $sfpath && !$sftype) {
			# Create ~/mail if needed
			&make_dir($sfpath, 0755);
			&set_ownership_permissions(
			     $uinfo->{'uid'}, $uinfo->{'gid'}, undef, $sfpath);
			}
		if (-d "$mailsrc/cur") {
			# Mail directory is in Maildir format, and sub-folders
			# are in Maildir++
			local $srcfolder = { 'type' => 1,
					     'file' => $mailsrc };
			local $dstfolder = { 'file' => $crfile,
					     'type' => $crtype };
			&mailboxes::mailbox_move_folder($srcfolder, $dstfolder);
			&set_mailfolder_owner($dstfolder, $uinfo);
			opendir(DIR, $mailsrc);
			while(my $mf = readdir(DIR)) {
				next if ($mf eq "." || $mf eq ".." ||
					 $mf !~ /^\./);
				local $srcfolder = { 'type' => 1,
					'file' => "$mailsrc/$mf" };
				# Remove . if destination is not Maildir++
				$mf =~ s/^\.// if (!$sftype);
				local $dstfolder = { 'type' => $sftype,
						     'file' => "$sfpath/$mf" };
				&mailboxes::mailbox_move_folder($srcfolder,
								$dstfolder);
				&set_mailfolder_owner($dstfolder, $uinfo);
				}
			closedir(DIR);
			}
		else {
			# Assume that mail files are mbox formatted
			opendir(DIR, $mailsrc);
			local $mf;
			while($mf = readdir(DIR)) {
				next if ($mf =~ /^\./);
				local $srcfolder = { 'type' => 0,
						     'file' => "$mailsrc/$mf" };
				local $dstfolder;
				if ($mf eq "inbox") {
					$dstfolder = { 'file' => $crfile,
						       'type' => $crtype };
					}
				else {
					# Copying an extra folder - use
					# Maildir++ name if dest folders are
					# under ~/Maildir
					$mf = ".$mf" if ($sftype);
					$dstfolder = { 'type' => $sftype,
						'file' => "$sfpath/$mf" };
					}
				&mailboxes::mailbox_move_folder($srcfolder,
								$dstfolder);
				&set_mailfolder_owner($dstfolder, $uinfo);
				}
			closedir(DIR);
			}
		$mcount++;
		$usermap{$muser} = $uinfo;
		}
	close(PASSWD);
	&$second_print(".. done (migrated $mcount mail users)");
	}

# Move server owner's inbox file
local $owner = &get_domain_owner(\%dom);
if ($owner && !$parent) {
	&$first_print("Moving server owner's mailbox ..");
	local ($mfile, $mtype) = &user_mail_file($owner);
	local $srcfolder;
	if (-d "$homesrc/mail/cur") {
		# Maildir format
		$srcfolder = { 'type' => 1, 'file' => "$homesrc/mail" };
		}
	elsif (-r "$homesrc/mail/inbox") {
		# mbox format
		$srcfolder = { 'type' => 0,
			       'file' => "$homesrc/mail/inbox" };
		}
	if ($srcfolder) {
		local $dstfolder = { 'type' => $mtype, 'file' => $mfile };
		&mailboxes::mailbox_move_folder($srcfolder, $dstfolder);
		&set_mailfolder_owner($dstfolder, $owner);
		&$second_print(".. done");
		}
	else {
		&$second_print(".. none exists");
		}
	}

# Build map from email addresses to users
local %useremail;
foreach my $uinfo (&list_domain_users(\%dom)) {
	if ($uinfo->{'email'}) {
		$useremail{$uinfo->{'email'}} = $uinfo;
		}
	}

if ($got{'mail'}) {
	# Copy mail aliases
	local $acount = 0;
	local $domfwd;
	&$first_print("Copying email aliases ..");
	&set_alias_programs();
	local %gotvirt = map { $_->{'from'}, $_ } &list_virtusers();
	local $_;
	open(VAD, "$userdir/vad/$dom");
	while(<VAD>) {
		s/\r|\n//g;
		s/^\s*#.*$//;
		if (/^(\S+):\s*(\S+)$/) {
			# A domain forward exists ..
			local $virt = { 'from' => "\@$dom",
					'to' => [ "%1\@$2" ] };
			local $clash = $gotvirt{$virt->{'from'}};
			&delete_virtuser($clash) if ($clash);
			&create_virtuser($virt);
			$acount++;
			$domfwd++;
			}
		}
	close(VAD);
	open(VA, "$userdir/va/$dom");
	while(<VA>) {
		s/\r|\n//g;
		s/^\s*#.*$//;
		if (/^(\S+):\s*(.*)$/) {
			local ($name, $v) = ($1, $2);
			local @values;
			if ($v !~ /,/ && $v !~ /"/) {
				# A single destination, not quoted!
				@values = ( $v );
				}
			else {
				# Comma-separated alias destinations
				while($v =~ /^\s*,?\s*"(\|)([^"]+)"(.*)$/ ||
				      $v =~ /^\s*,?\s*()"([^"]+)"(.*)$/ ||
				      $v =~ /^\s*,?\s*(\|)"([^"]+)"(.*)$/ ||
				      $v =~ /^\s*,?\s*()([^,\s]+)(.*)$/) {
					push(@values, $1.$2);
					$v = $3;
					}
				}
			local $mailman = 0;
			foreach my $v (@values) {
				if ($v =~ /:fail:\s+(.*)/) {
					# Fix bounce alias
					$v = "BOUNCE $1";
					}
				local ($atype, $aname) = &alias_type($v, $name);
				if ($atype == 4 && $aname =~ /autorespond\s+(\S+)\@(\S+)\s+(\S+)/) {
					# Turn into Virtualmin auto-responder
					$v = "| $module_config_directory/autoreply.pl $3/$name $1";
					&set_ownership_permissions(
						undef, undef, 0755,
						$3, "$3/$name");
					}
				elsif ($atype == 4 && $aname =~ /mailman/) {
					$mailman++;
					}
				}
			# Don't create aliases for mailman lists
			next if ($mailman || $name =~ /^owner-/);

			# Already done a domain forward
			next if ($name =~ /^\*/ && $domfwd);

			if ($useremail{$name}) {
				# This is an alias from a user. Preserve
				# delivery to his mailbox though, as this is
				# what cPanel seems to do.
				local $uinfo = $useremail{$name};
				local $olduinfo = { %$uinfo };
				local $touser = $uinfo->{'user'};
				if ($config{'mail_system'} == 0 &&
				    $escuser =~ /\@/) {
					$touser = &replace_atsign($touser);
					}
				$touser = "\\".$touser;
				$uinfo->{'to'} = [ $touser, @values ];
				&modify_user($uinfo, $olduinfo, \%dom);
				}
			else {
				# Just create an alias
				if ($name !~ /\@/) {
					$name .= "\@".$dom;
					}
				local $virt = { 'from' => $name =~ /^\*/ ?
						  "\@".$dom : $name,
						'to' => \@values };
				local $clash = $gotvirt{$virt->{'from'}};
				&delete_virtuser($clash) if ($clash);
				&create_virtuser($virt);
				$acount++;
				}
			}
		}
	close(VA);
	&$second_print(".. done (migrated $acount aliases)");
	}

# Create mailing lists
if ($got{'virtualmin-mailman'}) {
	local $lcount = 0;
	&$first_print("Re-creating mailing lists ..");
	foreach $ml (@lists) {
		local $err = &plugin_call("virtualmin-mailman", "create_list",
			     $ml, $dom, "Migrated cPanel mailing list",
			     undef, $dom{'emailto'}, $dom{'pass'});
		if ($err) {
			&$second_print("Failed to create $ml : $err");
			}
		else {
			&execute_command("cp ".quotemeta("$userdir/mm/${ml}_${dom}/")."*.pck ".quotemeta("$virtualmin_mailman::mailman_var/lists/$ml"));
			$lcount++;
			}
		}
	&$second_print(".. done (created $lcount lists)");
	}

# Copy cron jobs for user (direct to his cron file)
if (-r "$userdir/cron/$user" && !$waschild) {
	&foreign_require("cron", "cron-lib.pl");
	&$first_print("Copying Cron jobs ..");
	$cron::cron_temp_file = &transname();
	if ($parent) {
		# Append migrated cron to parent user's
		&cron::copy_cron_temp({ 'user' => $parent->{'user'} });
		&execute_command("cat $userdir/cron/$user >>$cron::cron_temp_file");
		&cron::copy_crontab($parent->{'user'});
		}
	else {
		# Just over-write cron
		&execute_command("cp $userdir/cron/$user $cron::cron_temp_file");
		&cron::copy_crontab($user);
		}
	&$second_print(".. done");
	}

if ($got{'mysql'}) {
	# Re-create all MySQL databases
	local $mycount = 0;
	&$first_print("Re-creating and loading MySQL databases ..");
	&disable_quotas(\%dom);
	local $mydir = "$userdir/mysql";
	opendir(MYDIR, $mydir);
	while($myf = readdir(MYDIR)) {
		if ($myf =~ /^(\Q$user\E_\S*).sql$/ ||
		    $myf =~ /^(\Q$user\E).sql$/) {
			local $db = $1;
			&$indent_print();
			&create_mysql_database(\%dom, $db);
			&save_domain(\%dom, 1);
			local ($ex, $out) = &mysql::execute_sql_file($db, "$mydir/$myf");
			if ($ex) {
				&$first_print("Error loading $db : $out");
				}
			&$outdent_print();
			$mycount++;
			}
		}
	closedir(MYDIR);
	&enable_quotas(\%dom);
	&$second_print(".. done (created $mycount databases)");

	# Re-create MySQL users
	if ($got{'mysql'}) {
		local $myucount = 0;
		&$first_print("Re-creating MySQL users ..");
		local %myusers;
		local $_;
		local (%donemysqluser, %donemysqlpriv);
		open(MYSQL, "$userdir/mysql.sql");
		while(<MYSQL>) {
			s/\r|\n//g;
			if (/^GRANT USAGE ON \*\.\* TO '(\S+)'\@'(\S+)' IDENTIFIED BY PASSWORD '(\S+)';/) {
				# Creating a MySQL user
				local ($myuser, $mypass) = ($1, $3);
				next if ($myuser eq $user);	# domain owner
				next if ($donemysqluser{$myuser}++);
				local $myuinfo = &create_initial_user(\%dom);
				$myuinfo->{'user'} = $myuser;
				$myuinfo->{'pass'} = "x";	# not needed
				$myuinfo->{'mysql_pass'} = $mypass;
				$myuinfo->{'gid'} = $dom{'gid'};
				$myuinfo->{'real'} = "MySQL user";
				$myuinfo->{'home'} = "$dom{'home'}/$config{'homes_dir'}/$myuser";
				$myuinfo->{'shell'} = $nologin_shell->{'shell'};
				delete($myuinfo->{'email'});
				$myusers{$myuser} = $myuinfo;
				}
			elsif (/GRANT ALL PRIVILEGES ON `(\S+)`\.\* TO '(\S+)'\@'(\S+)';/ || /GRANT SELECT.*\sON `(\S+)`\.\* TO '(\S+)'\@'(\S+)';/) {
				# Granting access to a MySQL database
				local ($mydb, $myuser) = ($1, $2);
				next if ($myuser eq $user);	# domain owner
				next if ($donemysqlpriv{$mydb,$myuser}++);
				$mydb =~ s/\\(.)/$1/g;
				if ($myusers{$myuser}) {
					push(@{$myusers{$myuser}->{'dbs'}},
					     { 'type' => 'mysql', 'name' => $mydb });
					}
				}
			}
		close(MYSQL);
		foreach my $myuinfo (values %myusers) {
			local $already = $usermap{$myuinfo->{'user'}};
			if ($already) {
				# User already exists, so just give him the dbs
				local $olduinfo = { %$already };
				$already->{'dbs'} = $myuinfo->{'dbs'};
				&modify_user($already, $old, \%dom);
				}
			else {
				$myuinfo->{'uid'} = &allocate_uid(\%taken);
				&create_user($myuinfo, \%dom);
				&create_user_home($myuinfo, \%dom, 1);
				&create_mail_file($myuinfo);
				$taken{$myuinfo->{'uid'}}++;
				$usermap{$myuinfo->{'user'}} = $myuinfo;
				}
			$myucount++;
			}
		&$second_print(".. done (created $myucount MySQL users)");
		}
	}

# Fix up FTP configuration
if ($got{'ftp'}) {
	&$first_print("Modifying FTP server configuration ..");
	&require_proftpd();
	local $conf = &proftpd::get_config();
	local ($fvirt, $fconf, $anon, $aconf) = &get_proftpd_virtual($ip);
	if ($anon) {
		local $lref = &read_file_lines($anon->{'file'});
		$lref->[$anon->{'line'}] = "<Anonymous $dom{'home'}/public_ftp>";
		&flush_file_lines($anon->{'file'});
		&$second_print(".. done");
		&register_post_action(\&restart_proftpd);
		}
	else {
		&$second_print(".. could not find FTP server configuration");
		}
	}

# Migrate or update FTP users
if (-r "$userdir/proftpdpasswd" && !$waschild) {
	local $fcount = 0;
	&$first_print("Re-creating FTP users ..");
	local $_;
	open(FTP, "$userdir/proftpdpasswd");
	while(<FTP>) {
		s/\r|\n//g;
		s/^\s*#.*$//;
		local ($fuser, $fpass, $fuid, $fgid, $fdummy, $fhome, $fshell) = split(/:/, $_);
		next if (!$fuser);
		next if ($fuser eq "ftp" || $fuser eq $user ||
			 $fuser eq $user."_logs");	# skip cpanel users
		local $fullfuser = &userdom_name(lc($fuser), \%dom);
		if ($fhome eq "/dev/null" ||
		    !&is_under_directory($dom{'home'}, $fhome)) {
			$fhome = "$dom{'home'}/$config{'homes_dir'}/$fuser";
			}
		local $already = $usermap{$fuser} ||
				 $usermap{$fullfuser};
		if ($already) {
			# Turn on FTP for existing user
			local $olduinfo = { %$already };
			$already->{'shell'} = $ftp_shell->{'shell'};
			&modify_user($already, $olduinfo, \%dom);
			}
		else {
			# Create new FTP-only user
			local $fuinfo = &create_initial_user(\%dom, 0,
							     $fhome eq $ht);
			$fuinfo->{'user'} = $fullfuser;
			$fuinfo->{'pass'} = $fpass;
			if ($fuinfo->{'webowner'}) {
				$fuinfo->{'uid'} = $dom{'uid'};
				}
			else {
				$fuinfo->{'uid'} = &allocate_uid(\%taken);
				}
			$fuinfo->{'gid'} = $dom{'gid'};
			$fuinfo->{'real'} = "FTP user";
			$fuinfo->{'home'} = $fhome;
			$fuinfo->{'shell'} = $ftp_shell->{'shell'};
			delete($fuinfo->{'email'});
			$usermap{$fuser} = $fuinfo;
			&create_user($fuinfo, \%dom);
			if (!$user->{'nocreatehome'}) {
				&create_user_home($fuinfo, \%dom, 1);
				}
			if (!$user->{'nomailfile'}) {
				&create_mail_file($fuinfo);
				}
			$taken{$fuinfo->{'uid'}}++;
			$fcount++;
			}
		}
	close(FTP);
	&$second_print(".. done (created $fcount FTP users)");
	}
&release_lock_unix(\%dom);
&release_lock_mail(\%dom);

# Migrate any parked domains as alias domains
local @parked;
if (!$waschild) {
	local $_;
	open(PARKED, "$userdir/pds");
	while(<PARKED>) {
		s/\r|\n//g;
		local ($pdom) = split(/\s+/, $_);
		push(@parked, $pdom) if ($pdom);
		}
	close(PARKED);
	}

# Create alias domain for sub-domain
if ($aliasdom) {
	push(@parked, $aliasdom);
	}

# Actually create alias doms
foreach my $pdom (&unique(@parked)) {
	if ($pdom eq $aliasdom) {
		&$first_print("Creating alias domain $pdom ..");
		}
	else {
		&$first_print("Creating parked domain $pdom ..");
		}
	&$indent_print();
	local %alias = ( 'id', &domain_id(),
			 'dom', $pdom,
			 'user', $dom{'user'},
			 'group', $dom{'group'},
			 'prefix', $dom{'prefix'},
			 'ugroup', $dom{'ugroup'},
			 'pass', $dom{'pass'},
			 'alias', $dom{'id'},
			 'uid', $dom{'uid'},
			 'gid', $dom{'gid'},
			 'ugid', $dom{'ugid'},
			 'owner', $pdom eq $aliasdom ?
					"Migrated cPanel alias for $dom{'dom'}":
					"Parked domain for $dom{'dom'}",
			 'email', $dom{'email'},
			 'name', 1,
			 'ip', $dom{'ip'},
			 'virt', 0,
			 'source', $dom{'source'},
			 'parent', $dom{'id'},
			 'template', $dom{'template'},
			 'reseller', $dom{'reseller'},
			 'nocreationmail', 1,
			 'nocopyskel', 1,
			);
	foreach my $f (@alias_features) {
		$alias{$f} = $dom{$f};
		}
	local $parentdom = $dom{'parent'} ? &get_domain($dom{'parent'})
					  : \%dom;
	$alias{'home'} = &server_home_directory(\%alias, $parentdom);
	&complete_domain(\%alias);
	&create_virtual_server(\%alias, $parentdom,
			       $parentdom->{'user'});
	&$outdent_print();
	&$second_print($text{'setup_done'});
	push(@rvdoms, \%alias);
	}

# Read addons domain mapping file
local %addons;
local $lref = &read_file_lines("$userdir/addons");
foreach my $l (@$lref) {
	my ($a, $t) = split(/=/, $l);
	if ($a && $t) {
		$t =~ s/_/\./;
		$addons{$a} = $t;
		}
	}

# Create sub-domains, from vf directory
opendir(VF, "$userdir/vf");
foreach my $vf (readdir(VF)) {
	local ($clash) = grep { $_->{'dom'} eq $vf } @rvdoms;
	next if ($vf eq "." || $vf eq ".." || $clash);
	next if ($addons{$vf});
	&$first_print("Creating sub-domain $vf ..");
	if ($vf !~ /^(\S+)\.\Q$dom\E$/) {
		&$second_print(".. skipping, as not a sub-domain of $dom");
		next;
		}
	local $subprefix = $1;
	&$indent_print();
	local %subd = ( 'id', &domain_id(),
			'dom', $vf,
			'user', $dom{'user'},
			'group', $dom{'group'},
			'prefix', $dom{'prefix'},
			'ugroup', $dom{'ugroup'},
			'pass', $dom{'pass'},
			'subdom', $dom{'id'},
		        'subprefix', $subprefix,
			'uid', $dom{'uid'},
			'gid', $dom{'gid'},
			'ugid', $dom{'ugid'},
			'owner', "Migrated cPanel sub-domain",
			'email', $dom{'email'},
			'name', 1,
			'ip', $dom{'ip'},
			'virt', 0,
			'source', $dom{'source'},
			'parent', $dom{'id'},
			'template', $dom{'template'},
			'reseller', $dom{'reseller'},
			'nocreationmail', 1,
			'nocopyskel', 1,
			'no_tmpl_aliases', 1,
			);
	foreach my $f (@subdom_features) {
		if ($f eq 'mail') {
			$subd{$f} = $dom{$f} && -r "$userdir/va/$vf";
			}
		elsif ($f eq 'ssl') {
			# Off for sub-domains, for now
			$subd{$f} = 0;
			}
		else {
			$subd{$f} = $dom{$f};
			}
		}
	local $parentdom = $dom{'parent'} ? &get_domain($dom{'parent'})
					  : \%dom;
	$subd{'home'} = &server_home_directory(\%subd, $parentdom);
	&complete_domain(\%subd);

	# Set cgi directories to cpanel standard
	$subd{'cgi_bin_dir'} =
		"../../$dom{'public_html_dir'}/$subprefix/cgi-bin";
	$subd{'cgi_bin_path'} =
		"$dom{'public_html_path'}/$subprefix/cgi-bin";

	&create_virtual_server(\%subd, $parentdom, $parentdom->{'user'});

	# Cpanel sub-domains always seem to forward mail to the parent
	if ($subd{'mail'}) {
		local $virt = { 'from' => "\@$vf",
				'to' => [ "%1\@$dom" ] };
		&create_virtuser($virt);
		}

	&$outdent_print();
	&$second_print($text{'setup_done'});
	push(@rvdoms, \%subd);
	}
closedir(VF);

# Create addon domains
opendir(VF, "$userdir/vf");
foreach my $vf (readdir(VF)) {
	local ($clash) = grep { $_->{'dom'} eq $vf } @rvdoms;
	next if ($vf eq "." || $vf eq ".." || $clash);
	next if (!$addons{$vf});
	&$first_print("Creating addon domain $vf ..");
	local $target = &get_domain_by("dom", $addons{$vf});
	if (!$target) {
		&$second_print(".. skipping, as target $addons{$vf} does not exist");
		next;
		}
	&$indent_print();
	local %alias = ( 'id', &domain_id(),
			 'dom', $vf,
			 'user', $dom{'user'},
			 'group', $dom{'group'},
			 'prefix', $dom{'prefix'},
			 'ugroup', $dom{'ugroup'},
			 'pass', $dom{'pass'},
			 'alias', $target->{'id'},
			 'uid', $dom{'uid'},
			 'gid', $dom{'gid'},
			 'ugid', $dom{'ugid'},
			 'owner', "Migrated cPanel alias for $target->{'dom'}",
			 'email', $dom{'email'},
			 'name', 1,
			 'ip', $target->{'ip'},
			 'virt', 0,
			 'source', $dom{'source'},
			 'parent', $dom{'id'},
			 'template', $target->{'template'},
			 'reseller', $target->{'reseller'},
			 'nocreationmail', 1,
			 'nocopyskel', 1,
			);
	foreach my $f (@alias_features) {
		$alias{$f} = $target->{$f};
		}
	local $parentdom = $dom{'parent'} ? &get_domain($dom{'parent'})
					  : \%dom;
	$alias{'home'} = &server_home_directory(\%alias, $parentdom);
	&complete_domain(\%alias);
	&create_virtual_server(\%alias, $parentdom,
			       $parentdom->{'user'});
	&$outdent_print();
	&$second_print($text{'setup_done'});
	push(@rvdoms, \%alias);

	# Create parked domain aliases
	&$first_print("Copying email aliases for addon domain $f ..");
	local $acount = 0;
	local %gotvirt = map { $_->{'from'}, $_ } &list_virtusers();
	open(VA, "$userdir/va/$vf");
	while(<VA>) {
		s/\r|\n//g;
		s/^\s*#.*$//;
		if (/^(\S+):\s*(.*)$/) {
			local ($name, $v) = ($1, $2);
			local @values;
			if ($v !~ /,/ && $v !~ /"/) {
				# A single destination, not quoted!
				@values = ( $v );
				}
			else {
				# Comma-separated alias destinations
				while($v =~ /^\s*,?\s*"(\|)([^"]+)"(.*)$/ ||
				      $v =~ /^\s*,?\s*()"([^"]+)"(.*)$/ ||
				      $v =~ /^\s*,?\s*(\|)"([^"]+)"(.*)$/ ||
				      $v =~ /^\s*,?\s*()([^,\s]+)(.*)$/) {
					push(@values, $1.$2);
					$v = $3;
					}
				}
			local $mailman = 0;
			foreach my $v (@values) {
				if ($v =~ /:fail:\s+(.*)/) {
					# Fix bounce alias
					$v = "BOUNCE $1";
					}
				local ($atype, $aname) = &alias_type($v, $name);
				if ($atype == 4 && $aname =~ /autorespond\s+(\S+)\@(\S+)\s+(\S+)/) {
					# Turn into Virtualmin auto-responder
					$v = "| $module_config_directory/autoreply.pl $3/$name $1";
					&set_ownership_permissions(
						undef, undef, 0755,
						$3, "$3/$name");
					}
				elsif ($atype == 4 && $aname =~ /mailman/) {
					$mailman++;
					}
				}
			# Don't create aliases for mailman lists
			next if ($mailman || $name =~ /^owner-/);

			# Already done a domain forward
			next if ($name =~ /^\*/);

			# Just create an alias
			if ($name !~ /\@/) {
				$name .= "\@".$dom;
				}
			local $virt = { 'from' => $name =~ /^\*/ ? "\@".$vf
								 : $name,
					'to' => \@values };
			local $clash = $gotvirt{$virt->{'from'}};
			&delete_virtuser($clash) if ($clash);
			&create_virtuser($virt);
			$acount++;
			}
		}
	close(VA);
	&$second_print(".. done (migrated $acount aliases)");
	}


if ($got{'webalizer'}) {
	# Copy existing Weblizer stats to ~/public_html/stats
	&$first_print("Copying Weblizer data files ..");
	&execute_command("cp ".
		quotemeta($webalizer)."/*.{png,gif,html,current,hist} ".
		quotemeta(&webalizer_stats_dir(\%dom)));
	&execute_command("chown -R $dom{'uid'}:$dom{'ugid'} ".
			 quotemeta(&webalizer_stats_dir(\%dom)));
        &$second_print($text{'setup_done'});
	}

if ($got{'virtualmin-awstats'}) {
	# Copy AWstats data files to ~/awstats
	&$first_print("Copying AWstats data files ..");
	&execute_command("cp ".quotemeta("$homesrc/tmp/awstats")."/*.$dom.txt ".
			       quotemeta("$dom{'home'}/awstats"));
	&execute_command("chown -R $dom{'uid'}:$dom{'ugid'} ".
			 quotemeta("$dom{'home'}/awstats"));
        &$second_print($text{'setup_done'});
	}

if ($parent) {
	# Re-save parent user, to update Webmin ACLs
	&refresh_webmin_user($parent);
	}

&sync_alias_virtuals(\%dom);
return @rvdoms;
}

# extract_cpanel_dir(file)
# Extracts a tar.gz file, and returns a status code and either the directory
# under which it was extracted, or an error message
sub extract_cpanel_dir
{
local ($file) = @_;
return undef if (!-r $file);
if ($main::cpanel_dir_cache{$file} && -d $main::cpanel_dir_cache{$file}) {
	# Use cached extract from this session
	return (1, $main::cpanel_dir_cache{$file});
	}
local $temp = &transname();
mkdir($temp, 0700);
local $err = &extract_compressed_file($file, $temp);
if ($err) {
	return (0, $err);
	}
$main::cpanel_dir_cache{$file} = $temp;
return (1, $temp);
}

# extract_cpanel_file(file)
# Extracts a .gz file, and returns the filename that is was extracted to
sub extract_cpanel_file
{
return undef if (!-r $_[0]);
local $temp = &transname();
local $qf = quotemeta($_[0]);
local $out = `gunzip -c $qf >$temp`;
return $? ? undef : $temp;
}

1;

