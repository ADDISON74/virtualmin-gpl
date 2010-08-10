
sub require_bind
{
return if ($require_bind++);
&foreign_require("bind8", "bind8-lib.pl");
%bconfig = &foreign_config("bind8");
}

# check_depends_dns(&domain)
# For a sub-domain that is being added to a parent DNS domain, make sure the
# parent zone actually exists
sub check_depends_dns
{
if ($_[0]->{'subdom'}) {
	local $tmpl = &get_template($_[0]->{'template'});
	local $parent = &get_domain($_[0]->{'subdom'});
	if ($tmpl->{'dns_sub'} && !$parent->{'dns'}) {
		return $text{'setup_edepdnssub'};
		}
	}
return undef;
}

# setup_dns(&domain)
# Set up a zone for a domain
sub setup_dns
{
&require_bind();
local $tmpl = &get_template($_[0]->{'template'});
if (!$_[0]->{'subdom'} && !&under_parent_domain($_[0]) ||
    $tmpl->{'dns_sub'} ne 'yes') {
	# Creating a new real zone
	&$first_print($text{'setup_bind'});
	&obtain_lock_dns($_[0], 1);
	local $conf = &bind8::get_config();
	local $base = $bconfig{'master_dir'} ? $bconfig{'master_dir'} :
					       &bind8::base_directory($conf);
	local $file = &bind8::automatic_filename($_[0]->{'dom'}, 0, $base);
	local $dir = {
		 'name' => 'zone',
		 'values' => [ $_[0]->{'dom'} ],
		 'type' => 1,
		 'members' => [ { 'name' => 'type',
				  'values' => [ 'master' ] },
				{ 'name' => 'file',
				  'values' => [ $file ] } ]
		};
	if ($tmpl->{'namedconf'} &&
	    $tmpl->{'namedconf'} ne 'none') {
		push(@{$dir->{'members'}},
		     &text_to_named_conf($tmpl->{'namedconf'}));
		}

	# Also notify slave servers, unless already added
	local @slaves = &bind8::list_slave_servers();
	local @extra_slaves = split(/\s+/, $tmpl->{'dns_ns'});
	if (@slaves && !$tmpl->{'namedconf_no_also_notify'}) {
		local ($also) = grep { $_->{'name'} eq 'also-notify' }
				     @{$dir->{'members'}};
		if (!$also) {
			$also = { 'name' => 'also-notify',
				  'type' => 1,
				  'members' => [ ] };
			foreach my $s (@slaves) {
				push(@{$also->{'members'}},
				     { 'name' => &to_ipaddress($s->{'host'}) });
				}
			foreach my $s (@extra_slaves) {
				push(@{$also->{'members'}},
                                     { 'name' => &to_ipaddress($s) });
				}
			push(@{$dir->{'members'}}, $also);
			push(@{$dir->{'members'}}, 
				{ 'name' => 'notify',
				  'values' => [ 'yes' ] });
			}
		}

	# Allow only localhost and slaves to transfer
	local @trans = ( { 'name' => '127.0.0.1' },
			 { 'name' => 'localnets' }, );
	foreach my $s (@slaves) {
		push(@trans, { 'name' => &to_ipaddress($s->{'host'}) });
		}
	foreach my $s (@extra_slaves) {
		push(@trans, { 'name' => &to_ipaddress($s) });
		}
	local ($trans) = grep { $_->{'name'} eq 'allow-transfer' }
			      @{$dir->{'members'}};
	if (!$trans && !$tmpl->{'namedconf_no_allow_transfer'}) {
		$trans = { 'name' => 'allow-transfer',
			   'type' => 1,
			   'members' => \@trans };
		push(@{$dir->{'members'}}, $trans);
		}

	local $pconf;
	local $indent = 0;
	if ($tmpl->{'dns_view'}) {
		# Adding inside a view. This may use named.conf, or an include
		# file references inside the view, if any
		$pconf = &bind8::get_config_parent();
		local $view = &get_bind_view($conf, $tmpl->{'dns_view'});
		if ($view) {
			local $addfile = &bind8::add_to_file();
			local $addfileok;
			if ($bind8::config{'zones_file'} &&
			    $view->{'file'} ne $bind8::config{'zones_file'}) {
				# BIND module config asks for a file .. make
				# sure it is included in the view
				foreach my $vm (@{$view->{'members'}}) {
					if ($vm->{'file'} eq $addfile) {
						# Add file is OK
						$addfileok = 1;
						}
					}
				}

			if (!$addfileok) {
				# Add to named.conf
				$pconf = $view;
				$indent = 1;
				$dir->{'file'} = $view->{'file'};
				}
			else {
				# Add to the file
				$dir->{'file'} = $addfile;
				$pconf = &bind8::get_config_parent($addfile);
				}
			$_[0]->{'dns_view'} = $tmpl->{'dns_view'};
			}
		else {
			&error(&text('setup_ednsview', $tmpl->{'dns_view'}));
			}
		}
	else {
		# Adding at top level .. but perhaps in a different file
		$dir->{'file'} = &bind8::add_to_file();
		$pconf = &bind8::get_config_parent($dir->{'file'});
		}
	&bind8::save_directive($pconf, undef, [ $dir ], $indent);
	&flush_file_lines();
	unlink($bind8::zone_names_cache);
	undef(@bind8::list_zone_names_cache);
	undef(@bind8::get_config_cache);

	# Create the records file
	local $rootfile = &bind8::make_chroot($file);
	local $ip = $_[0]->{'dns_ip'} || $_[0]->{'ip'};
	if (!-r $rootfile) {
		if ($_[0]->{'alias'}) {
			&create_alias_records($file, $_[0], $ip);
			}
		else {
			&create_standard_records($file, $_[0], $ip);
			}
		&bind8::set_ownership($rootfile);
		}
	&$second_print($text{'setup_done'});

	# If DNSSEC was requested, set it up
	if ($tmpl->{'dnssec'} eq 'yes') {
		&$first_print($text{'setup_dnssec'});
		local $zone = &get_bind_zone($_[0]->{'dom'});
		if (!defined(&bind8::supports_dnssec) ||
		    !&bind8::supports_dnssec()) {
			# Not supported
			&$second_print($text{'setup_enodnssec'});
			}
		else {
			local ($ok, $size) = &bind8::compute_dnssec_key_size(
				$tmpl->{'dnssec_alg'}, 1);
			local $err;
			if (!$ok) {
				# Key size failed
				&$second_print(
					&text('setup_ednssecsize', $size));
				}
			elsif ($err = &bind8::create_dnssec_key(
					$zone, $tmpl->{'dnssec_alg'}, $size,
					$tmpl->{'dnssec_single'})) {
				# Key generation failed
				&$second_print(
					&text('setup_ednsseckey', $err));
				}
			elsif ($err = &bind8::sign_dnssec_zone($zone)) {
				# Zone signing failed
				&$second_print(
					&text('setup_ednssecsign', $err));
				}
			else {
				# All done!
				&$second_print($text{'setup_done'});
				}
			}
		}

	# Create on slave servers
	local $myip = $bconfig{'this_ip'} ||
		      &to_ipaddress(&get_system_hostname());
	if (@slaves && !$_[0]->{'noslaves'}) {
		local $slaves = join(" ", map { $_->{'nsname'} ||
						$_->{'host'} } @slaves);
		&create_zone_on_slaves($_[0], $slaves);
		}

	&release_lock_dns($_[0], 1);
	}
else {
	# Creating a sub-domain - add to parent's DNS zone
	local $parent = &get_domain($_[0]->{'subdom'}) ||
			&get_domain($_[0]->{'parent'});
	&$first_print(&text('setup_bindsub', $parent->{'dom'}));
	&obtain_lock_dns($parent);
	local $z = &get_bind_zone($parent->{'dom'});
	if (!$z) {
		&error(&text('setup_ednssub', $parent->{'dom'}));
		}
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local @recs = &bind8::read_zone_file($fn, $parent->{'dom'});
	$_[0]->{'dns_submode'} = 1;	# So we know how this was done
	local ($already) = grep { $_->{'name'} eq $_[0]->{'dom'}."." }
				grep { $_->{'type'} eq 'A' } @recs;
	if ($already) {
		# A record with the same name as the sub-domain exists .. we
		# don't want to delete this later
		$_[0]->{'dns_subalready'} = 1;
		}
	local $ip = $_[0]->{'dns_ip'} || $_[0]->{'ip'};
	if ($_[0]->{'alias'}) {
		&create_standard_records($fn, $_[0], $ip);
		}
	else {
		&create_standard_records($fn, $_[0], $ip);
		}
	&post_records_change($parent, \@recs);

	&release_lock_dns($parent);
	&$second_print($text{'setup_done'});
	}
&register_post_action(\&restart_bind);
}

sub slave_error_handler
{
$slave_error = $_[0];
}

# delete_dns(&domain)
# Delete a domain from the BIND config
sub delete_dns
{
&require_bind();
if (!$_[0]->{'dns_submode'}) {
	&$first_print($text{'delete_bind'});
	&obtain_lock_dns($_[0], 1);
	local $z = &get_bind_zone($_[0]->{'dom'});
	if ($z) {
		# Delete any dnssec key
		if (defined(&bind8::supports_dnssec) &&
		    &bind8::supports_dnssec()) {
			&bind8::delete_dnssec_key($z);
			}

		# Delete the records file
		local $file = &bind8::find("file", $z->{'members'});
		if ($file) {
			local $zonefile =
			    &bind8::make_chroot($file->{'values'}->[0]);
			&unlink_file($zonefile);
			local $logfile = $zonefile.".log";
			if (!-r $logfile) { $logfile = $zonefile.".jnl"; }
			if (-r $logfile) {
				&unlink_logged($logfile);
				}
			}

		# Delete from named.conf
		local $rootfile = &bind8::make_chroot($z->{'file'});
		local $lref = &read_file_lines($rootfile);
		splice(@$lref, $z->{'line'}, $z->{'eline'} - $z->{'line'} + 1);
		&flush_file_lines($rootfile);

		# Clear zone names caches
		unlink($bind8::zone_names_cache);
		undef(@bind8::list_zone_names_cache);
		undef(@bind8::get_config_cache);
		&$second_print($text{'setup_done'});
		}
	else {
		&$second_print($text{'save_nobind'});
		}

	&delete_zone_on_slaves($_[0]);
	&release_lock_dns($_[0], 1);
	}
else {
	# Delete records from parent zone
	local $parent = &get_domain($_[0]->{'subdom'}) ||
			&get_domain($_[0]->{'parent'});
	&$first_print(&text('delete_bindsub', $parent->{'dom'}));
	&obtain_lock_dns($parent);
	local $z = &get_bind_zone($parent->{'dom'});
	if (!$z) {
		&$second_print($text{'save_nobind'});
		return;
		}
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local @recs = &bind8::read_zone_file($fn, $parent->{'dom'});
	local $withdot = $_[0]->{'dom'}.".";
	foreach $r (reverse(@recs)) {
		# Don't delete if outside sub-domain
		next if ($r->{'name'} !~ /\Q$withdot\E$/);
		# Don't delete if the same as an existing record
		next if ($r->{'name'} eq $withdot && $r->{'type'} eq 'A' &&
			 $_[0]->{'dns_subalready'});
		&bind8::delete_record($fn, $r);
		}
	&post_records_change($parent, \@recs);
	&release_lock_dns($parent);
	&$second_print($text{'setup_done'});
	$_[0]->{'dns_submode'} = 0;
	}
&register_post_action(\&restart_bind);
}

# create_zone_on_slaves(&domain, space-separate-slave-list)
# Create a zone on all specified slaves, and updates the dns_slave key.
# May print messages.
sub create_zone_on_slaves
{
local ($d, $slaves) = @_;
&require_bind();
local $myip = $bconfig{'this_ip'} ||
	      &to_ipaddress(&get_system_hostname());
&$first_print(&text('setup_bindslave', $slaves));
local @slaveerrs = &bind8::create_on_slaves(
	$d->{'dom'}, $myip, undef, $slaves,
	$d->{'dns_view'} || $tmpl->{'dns_view'});
if (@slaveerrs) {
	&$second_print($text{'setup_eslaves'});
	foreach my $sr (@slaveerrs) {
		&$second_print(
		  ($sr->[0]->{'nsname'} || $sr->[0]->{'host'}).
		  " : ".$sr->[1]);
		}
	}
else {
	&$second_print($text{'setup_done'});
	}

# Add to list of slaves where it succeeded
local @newslaves;
foreach my $s (split(/\s+/, $slaves)) {
	local ($err) = grep { $_->[0]->{'host'} eq $s } @slaveerrs;
	if (!$err) {
		push(@newslaves, $s);
		}
	}
local @oldslaves = split(/\s+/, $d->{'dns_slave'});
$d->{'dns_slave'} = join(" ", &unique(@oldslaves, @newslaves));

&register_post_action(\&restart_bind);
}

# delete_zone_on_slaves(&domain, [space-separate-slave-list])
# Delete a zone on all slave servers, from the dns_slave key. May print messages
sub delete_zone_on_slaves
{
local ($d, $slaveslist) = @_;
local @delslaves = $slaveslist ? split(/\s+/, $slaveslist)
			       : split(/\s+/, $d->{'dns_slave'});
&require_bind();
if (@delslaves) {
	# Delete from slave servers
	&$first_print(&text('delete_bindslave', join(" ", @delslaves)));
	local $tmpl = &get_template($d->{'template'});
	local @slaveerrs = &bind8::delete_on_slaves(
			$d->{'dom'}, \@delslaves,
			$d->{'dns_view'} || $tmpl->{'dns_view'});
	if (@slaveerrs) {
		&$second_print($text{'delete_bindeslave'});
		foreach my $sr (@slaveerrs) {
			&$second_print(
			  ($sr->[0]->{'nsname'} || $sr->[0]->{'host'}).
			  " : ".$sr->[1]);
			}
		}
	else {
		&$second_print($text{'setup_done'});
		}

	# Update domain data
	my @newslaves;
	if ($slaveslist) {
		foreach my $s (split(/\s+/, $d->{'dns_slave'})) {
			if (&indexof($s, @delslaves) < 0) {
				push(@newslaves, $s);
				}
			}
		}
	if (@newslaves) {
		$d->{'dns_slave'} = join(" ", @newslaves);
		}
	else {
		delete($d->{'dns_slave'});
		}
	}

&register_post_action(\&restart_bind);
}

# modify_dns(&domain, &olddomain)
# If the IP for this server has changed, update all records containing the old
# IP to the new.
sub modify_dns
{
if (!$_[0]->{'subdom'} && $_[1]->{'subdom'} && $_[0]->{'dns_submode'} ||
    !&under_parent_domain($_[0]) && $_[0]->{'dns_submode'}) {
	# Converting from a sub-domain to top-level .. just delete and re-create
	&delete_dns($_[1]);
	delete($_[0]->{'dns_submode'});
	&setup_dns($_[0]);
	return 1;
	}

&require_bind();
local $tmpl = &get_template($_[0]->{'template'});
local $z;
local ($oldzonename, $newzonename, $lockon, $lockconf);
if ($_[0]->{'dns_submode'}) {
	# Get parent domain
	local $parent = &get_domain($_[0]->{'subdom'}) ||
			&get_domain($_[0]->{'parent'});
	&obtain_lock_dns($parent);
	$lockon = $parent;
	$z = &get_bind_zone($parent->{'dom'});
	$oldzonename = $newzonename = $parent->{'dom'};
	}
else {
	# Get this domain
	&obtain_lock_dns($_[0], 1);
	$lockon = $_[0];
	$lockconf = 1;
	$z = &get_bind_zone($_[1]->{'dom'});
	$newzonename = $_[1]->{'dom'};
	$oldzonename = $_[1]->{'dom'};
	}
if (!$z) {
	# Not found!
	&release_lock_dns($lockon, $lockconf);
	return 0;
	}
local $oldip = $_[1]->{'dns_ip'} || $_[1]->{'ip'};
local $newip = $_[0]->{'dns_ip'} || $_[0]->{'ip'};
local $rv = 0;
if ($_[0]->{'dom'} ne $_[1]->{'dom'}) {
	# Domain name has changed
	local $nfn;
	local $file = &bind8::find("file", $z->{'members'});
	if (!$_[0]->{'dns_submode'}) {
		# Domain name has changed .. rename zone file
		&$first_print($text{'save_dns2'});
		local $fn = $file->{'values'}->[0];
		$nfn = $fn;
		$nfn =~ s/$_[1]->{'dom'}/$_[0]->{'dom'}/;
		if ($fn ne $nfn) {
			&rename_logged(&bind8::make_chroot($fn),
				       &bind8::make_chroot($nfn))
			}
		$file->{'values'}->[0] = $nfn;
		$file->{'value'} = $nfn;

		# Change zone in .conf file
		$z->{'values'}->[0] = $_[0]->{'dom'};
		$z->{'value'} = $_[0]->{'dom'};
		&bind8::save_directive(&bind8::get_config_parent(),
				       [ $z ], [ $z ], 0);
		&flush_file_lines();
		}
	else {
		&$first_print($text{'save_dns6'});
		$nfn = $file->{'values'}->[0];
		}

	# Modify any records containing the old name
	&lock_file(&bind8::make_chroot($nfn));
        local @recs = &bind8::read_zone_file($nfn, $oldzonename);
        foreach my $r (@recs) {
                if ($r->{'name'} =~ /$_[1]->{'dom'}/i) {
                        $r->{'name'} =~ s/$_[1]->{'dom'}/$_[0]->{'dom'}/;
			if ($r->{'type'} eq 'SPF') {
				# Fix SPF TXT record
				$r->{'values'}->[0] =~
					s/$_[1]->{'dom'}/$_[0]->{'dom'}/;
				}
			if ($r->{'type'} eq 'MX') {
				# Fix mail server in MX record
				$r->{'values'}->[1] =~
					s/$_[1]->{'dom'}/$_[0]->{'dom'}/;
				}
                        &bind8::modify_record($nfn, $r, $r->{'name'},
                                              $r->{'ttl'}, $r->{'class'},
                                              $r->{'type'},
					      &join_record_values($r),
                                              $r->{'comment'});
                        }
                }

        # Update SOA record
	&post_records_change($_[0], \@recs);
	&unlock_file(&bind8::make_chroot($nfn));
	$rv++;

	# Clear zone names caches
	unlink($bind8::zone_names_cache);
	undef(@bind8::list_zone_names_cache);
	&$second_print($text{'setup_done'});

	if (!$_[0]->{'dns_submode'}) {
		local @slaves = split(/\s+/, $_[0]->{'dns_slave'});
		if (@slaves) {
			# Rename on slave servers too
			&$first_print(&text('save_dns3', $_[0]->{'dns_slave'}));
			local @slaveerrs = &bind8::rename_on_slaves(
				$_[1]->{'dom'}, $_[0]->{'dom'}, \@slaves);
			if (@slaveerrs) {
				&$second_print($text{'save_bindeslave'});
				foreach $sr (@slaveerrs) {
					&$second_print(
					  ($sr->[0]->{'nsname'} ||
					   $sr->[0]->{'host'})." : ".$sr->[1]);
					}
				}
			else {
				&$second_print($text{'setup_done'});
				}
			}
		}
	}

if ($oldip ne $newip) {
	# IP address has changed .. need to update any records that use
	# the old IP
	&$first_print($text{'save_dns'});
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local $zonefile = &bind8::make_chroot($fn);
	local @recs = &bind8::read_zone_file($fn, $newzonename);
	&modify_records_ip_address(\@recs, $fn, $oldip, $newip);

	# Update SOA record
	&post_records_change($_[0], \@recs);
	$rv++;
	&$second_print($text{'setup_done'});
	}

if ($_[0]->{'mail'} && !$_[1]->{'mail'} && !$tmpl->{'dns_replace'}) {
	# Email was enabled .. add MX records
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local $zonefile = &bind8::make_chroot($fn);
	local @recs = &bind8::read_zone_file($fn, $newzonename);
	local ($mx) = grep { $_->{'type'} eq 'MX' &&
			     $_->{'name'} eq $_[0]->{'dom'}."." ||
			     $_->{'type'} eq 'A' &&
			     $_->{'name'} eq "mail.".$_[0]->{'dom'}."." } @recs;
	if (!$mx) {
		&$first_print($text{'save_dns4'});
		local $ip = $_[0]->{'dns_ip'} || $_[0]->{'ip'};
		&create_mx_records($fn, $_[0], $ip);
		&post_records_change($_[0], \@recs);
		&$second_print($text{'setup_done'});
		$rv++;
		}
	}
elsif (!$_[0]->{'mail'} && $_[1]->{'mail'} && !$tmpl->{'dns_replace'}) {
	# Email was disabled .. remove MX records, but only those that
	# point to this system or secondaries.
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local $zonefile = &bind8::make_chroot($fn);
	local @recs = &bind8::read_zone_file($fn, $newzonename);
	local $ip = $_[0]->{'dns_ip'} || $_[0]->{'ip'};
	local %ids = map { $_, 1 }
		split(/\s+/, $_[0]->{'mx_servers'});
	local @slaves = grep { $ids{$_->{'id'}} } &list_mx_servers();
	local @slaveips = map { &to_ipaddress($_->{'mxname'} || $_->{'host'}) }
			      @slaves;
	foreach my $r (@recs) {
		if ($r->{'type'} eq 'A' &&
		    $r->{'name'} eq "mail.".$_[0]->{'dom'}."." &&
		    $r->{'values'}->[0] eq $ip) {
			# mail.domain A record, pointing to our IP
			push(@mx, $r);
			}
		elsif ($r->{'type'} eq 'MX' &&
		       $r->{'name'} eq $_[0]->{'dom'}.".") {
			# MX record for domain .. does it point to our IP?
			local $mxip = &to_ipaddress($r->{'values'}->[1]);
			if ($mxip eq $ip || &indexof($mxip, @slaveips) >= 0) {
				push(@mx, $r);
				}
			}
		}
	if (@mx) {
		&$first_print($text{'save_dns5'});
		foreach my $r (reverse(@mx)) {
			&bind8::delete_record($fn, $r);
			}
		&post_records_change($_[0], \@recs);
		&$second_print($text{'setup_done'});
		$rv++;
		}
	}

if ($_[0]->{'mx_servers'} ne $_[1]->{'mx_servers'} && $_[0]->{'mail'} &&
    !$config{'secmx_nodns'}) {
	# Secondary MX servers have been changed - add or remove MX records
	&$first_print($text{'save_dns7'});
	local @newmxs = split(/\s+/, $_[0]->{'mx_servers'});
	local @oldmxs = split(/\s+/, $_[1]->{'mx_servers'});
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local $zonefile = &bind8::make_chroot($fn);
	local @recs = &bind8::read_zone_file($fn, $newzonename);
	&foreign_require("servers", "servers-lib.pl");
	local %servers = map { $_->{'id'}, $_ }
			     (&servers::list_servers(), &list_mx_servers());
	local $withdot = $_[0]->{'dom'}.".";

	# Add missing MX records
	foreach my $id (@newmxs) {
		if (&indexof($id, @oldmxs) < 0) {
			# A new MX .. add a record for it, if there isn't one
			local $s = $servers{$id};
			local $mxhost = $s->{'mxname'} || $s->{'host'};
			local $already = 0;
			foreach my $r (@recs) {
				if ($r->{'type'} eq 'MX' &&
				    $r->{'name'} eq $withdot &&
				    $r->{'values'}->[1] eq $mxhost.".") {
					$already = 1;
					}
				}
			if (!$already) {
				&bind8::create_record($fn, $withdot, undef,
					      "IN", "MX", "10 $mxhost.");
				}
			}
		}

	# Remove those that are no longer needed
	local @mxs;
	foreach my $id (@oldmxs) {
		if (&indexof($id, @newmxs) < 0) {
			# An old MX .. remove it
			local $s = $servers{$id};
			local $mxhost = $s->{'mxname'} || $s->{'host'};
			foreach my $r (@recs) {
				if ($r->{'type'} eq 'MX' &&
				    $r->{'name'} eq $withdot &&
				    $r->{'values'}->[1] eq $mxhost.".") {
					push(@mxs, $r);
					}
				}
			}
		}
	foreach my $r (reverse(@mxs)) {
		&bind8::delete_record($fn, $r);
		}

	&post_records_change($_[0], \@recs);
	&$second_print($text{'setup_done'});
	$rv++;
	}

if ($_[0]->{'virt6'} && !$_[1]->{'virt6'}) {
	# IPv6 enabled
	&$first_print($text{'save_dnsip6on'});
	&add_ip6_records($_[0]);
	local @recs = &get_domain_dns_records($_[0]);
	&post_records_change($_[0], \@recs);
	&$second_print($text{'setup_done'});
	$rv++;
	}
elsif (!$_[0]->{'virt6'} && $_[1]->{'virt6'}) {
	# IPv6 disabled
	&$first_print($text{'save_dnsip6off'});
	&remove_ip6_records($_[0]);
	local @recs = &get_domain_dns_records($_[0]);
	&post_records_change($_[0], \@recs);
	&$second_print($text{'setup_done'});
	$rv++;
	}
elsif ($_[0]->{'virt6'} && $_[1]->{'virt6'} &&
       $_[0]->{'ip6'} ne $_[1]->{'ip6'}) {
	# IPv6 address changed
	&$first_print($text{'save_dnsip6'});
	local $fn = &get_domain_dns_file($_[0]);
	local @recs = &get_domain_dns_records($_[0]);
	&modify_records_ip_address(\@recs, $fn, $_[1]->{'ip6'}, $_[0]->{'ip6'});
	&post_records_change($_[0], \@recs);
	$rv++;
	&$second_print($text{'setup_done'});
	}

# Release locks
&release_lock_dns($lockon, $lockconf);

&register_post_action(\&restart_bind) if ($rv);
return $rv;
}

# join_record_values(&record)
# Given the values for a record, joins them into a space-separated string
# with quoting if needed
sub join_record_values
{
local ($r) = @_;
if ($r->{'type'} eq 'SOA') {
	# Multiliple lines, with brackets
	local $v = $r->{'values'};
	return "$v->[0] $v->[1] (\n\t\t\t$v->[2]\n\t\t\t$v->[3]\n".
	       "\t\t\t$v->[4]\n\t\t\t$v->[5]\n\t\t\t$v->[6] )";
	}
else {
	# All one one line
	local @rv;
	foreach my $v (@{$r->{'values'}}) {
		push(@rv, $v =~ /\s/ ? "\"$v\"" : $v);
		}
	return join(" ", @rv);
	}
}

# create_mx_records(file, &domain, ip)
# Adds MX records to a DNS domain
sub create_mx_records
{
local ($file, $d, $ip) = @_;
local $withdot = $d->{'dom'}.".";
&bind8::create_record($file, "mail.$withdot", undef,
		      "IN", "A", $ip);
&bind8::create_record($file, $withdot, undef,
		      "IN", "MX", "5 mail.$withdot");

# Add MX records for slaves, if enabled
if (!$config{'secmx_nodns'}) {
	local %ids = map { $_, 1 }
		split(/\s+/, $d->{'mx_servers'});
	local @servers = grep { $ids{$_->{'id'}} } &list_mx_servers();
	local $n = 10;
	foreach my $s (@servers) {
		local $mxhost = $s->{'mxname'} || $s->{'host'};
		&bind8::create_record($file, $withdot, undef,
			      "IN", "MX", "$n $mxhost.");
		$n += 5;
		}
	}
}

# create_standard_records(file, &domain, ip)
# Adds to a records file the needed records for some domain
sub create_standard_records
{
local ($file, $d, $ip) = @_;
local $rootfile = &bind8::make_chroot($file);
local $tmpl = &get_template($d->{'template'});
local $serial = $bconfig{'soa_style'} ?
	&bind8::date_serial().sprintf("%2.2d", $bconfig{'soa_start'}) :
	time();
local %zd;
&bind8::get_zone_defaults(\%zd);
if (!$tmpl->{'dns_replace'} || $d->{'dns_submode'}) {
	# Create records that are appropriate for this domain, as long as the
	# user hasn't selected a completely custom template, or records are
	# being added to an existing domain
	if (!$d->{'dns_submode'}) {
		# Only add SOA and NS if this is a new file, not a sub-domain
		# in an existing file
		&open_tempfile(RECS, ">$rootfile");
		if ($bconfig{'master_ttl'}) {
			# Add a default TTL
			if ($tmpl->{'dns_ttl'} eq '') {
				&print_tempfile(RECS,
				    "\$ttl $zd{'minimum'}$zd{'minunit'}\n");
				}
			elsif ($tmpl->{'dns_ttl'} ne 'none') {
				&print_tempfile(RECS,
				    "\$ttl $tmpl->{'dns_ttl'}\n");
				}
			}
		&close_tempfile(RECS);
		local $tmaster = $tmpl->{'dns_master'} eq 'none' ? undef :
					$tmpl->{'dns_master'};
		local $master = $tmaster ||
				$bconfig{'default_prins'} ||
				&get_system_hostname();
		$master .= "." if ($master !~ /\.$/);
		local $email = $bconfig{'tmpl_email'} ||
			       "root\@$master";
		$email = &bind8::email_to_dotted($email);
		local $soa = "$master $email (\n".
			     "\t\t\t$serial\n".
			     "\t\t\t$zd{'refresh'}$zd{'refunit'}\n".
			     "\t\t\t$zd{'retry'}$zd{'retunit'}\n".
			     "\t\t\t$zd{'expiry'}$zd{'expunit'}\n".
			     "\t\t\t$zd{'minimum'}$zd{'minunit'} )";
		&bind8::create_record($file, "@", undef, "IN",
				      "SOA", $soa);

		# Get nameservers from reseller, if any
		my @reselns;
		if ($d->{'reseller'}) {
			my $resel = &get_reseller($d->{'reseller'});
			if ($resel->{'acl'}->{'defns'}) {
				@reselns = split(/\s+/,
					$resel->{'acl'}->{'defns'});
				}
			}

		if (@reselns) {
			# NS records come from reseller
			foreach my $ns (@reselns) {
				$ns .= "." if ($ns !~ /\.$/);
				&bind8::create_record($file, "@", undef, "IN",
						      "NS", $ns);
				}
			}
		else {
			# Add NS records for master and auto-configured slaves
			if ($tmpl->{'dns_prins'}) {
				&bind8::create_record($file, "@", undef, "IN",
						      "NS", $master);
				}
			local $slave;
			local @slaves = &bind8::list_slave_servers();
			foreach $slave (@slaves) {
				local @bn = $slave->{'nsname'} ?
						( $slave->{'nsname'} ) :
						gethostbyname($slave->{'host'});
				if ($bn[0]) {
					local $full = "$bn[0].";
					&bind8::create_record(
						$file, "@", undef, "IN",
						"NS", "$bn[0].");
					}
				}

			# Add NS records from template
			foreach my $ns (split(/\s+/, $tmpl->{'dns_ns'})) {
				$ns .= "." if ($ns !~ /\.$/);
				&bind8::create_record($file, "@", undef, "IN",
						      "NS", $ns);
				}
			}
		}
	
	# Work out which records are already in the file
	local $rd = $d;
	if ($d->{'dns_submode'}) {
		$rd = &get_domain($d->{'subdom'}) ||
		      &get_domain($d->{'parent'});
		}
	local %already = map { $_->{'name'}, $_ }
			     grep { $_->{'type'} eq 'A' }
				  &bind8::read_zone_file($file, $rd->{'dom'});

	# Work out which records to add
	local $withdot = $d->{'dom'}.".";
	local @addrecs = split(/\s+/, $tmpl->{'dns_records'});
	if (!@addrecs || $addrecs[0] eq 'none') {
		@addrecs = @automatic_dns_records;
		}
	local %addrecs = map { $_ eq "@" ? $withdot : $_.".".$withdot, 1 }
			     @addrecs;

	# Add standard records we don't have yet
	foreach my $n ($withdot, "www.$withdot", "ftp.$withdot", "m.$withdot") {
		if (!$already{$n} && $addrecs{$n}) {
			&bind8::create_record($file, $n, undef,
					      "IN", "A", $ip);
			}
		}

	# Add the localhost record - yes, I know it's lame, but some
	# registrars require it!
	local $n = "localhost.$withdot";
	if (!$already{$n} && $addrecs{$n}) {
		&bind8::create_record($file, $n, undef,
				      "IN", "A", "127.0.0.1");
		}

	# If requested, add webmail and admin records
	if ($d->{'web'} && &has_webmail_rewrite()) {
		&add_webmail_dns_records($d, $tmpl, $file, \%already);
		}

	# For mail domains, add MX to this server
	if ($d->{'mail'}) {
		&create_mx_records($file, $d, $ip);
		}

	# Add SPF record for domain, if defined and if it's not a sub-domain
	if ($tmpl->{'dns_spf'} ne "none" &&
	    !$d->{'dns_submode'}) {
		local $str = &bind8::join_spf(&default_domain_spf($d));
		&bind8::create_record($file, $withdot, undef,
				      "IN", "TXT", "\"$str\"");
		}
	}

if ($tmpl->{'dns'} && (!$d->{'dns_submode'} || !$tmpl->{'dns_replace'})) {
	# Add or use the user-defined records template, if defined and if this
	# isn't a sub-domain being added to an existing file OR if we are just
	# adding records
	&open_tempfile(RECS, ">>$rootfile");
	local %subs = %$d;
	$subs{'serial'} = $serial;
	$subs{'dnsemail'} = $d->{'emailto'};
	$subs{'dnsemail'} =~ s/\@/./g;
	local $recs = &substitute_domain_template(
		join("\n", split(/\t+/, $tmpl->{'dns'}))."\n", \%subs);
	&print_tempfile(RECS, $recs);
	&close_tempfile(RECS);
	}

if ($d->{'virt6'}) {
	# Create IPv6 records for IPv4
	&add_ip6_records($d, $file);
	}
}

# create_alias_records(file, &domain, ip)
# For a domain that is an alias, copy records from its target
sub create_alias_records
{
local ($file, $d, $ip) = @_;
local $tmpl = &get_template($d->{'template'});
local $aliasd = &get_domain($d->{'alias'});
local $aliasfile = &get_domain_dns_file($aliasd);
$file || &error("No zone file for alias target $aliasd->{'dom'} found");
local @recs = &bind8::read_zone_file($aliasfile, $aliasd->{'dom'});
@recs || &error("No records for alias target $aliasd->{'dom'} found");
local $olddom = $aliasd->{'dom'};
local $dom = $d->{'dom'};
local $oldip = $aliasd->{'ip'};
local @sublist = grep { $_->{'id'} ne $aliasd->{'id'} } &list_domains();
RECORD: foreach my $r (@recs) {
	if ($d->{'dns_submode'} && ($r->{'type'} eq 'NS' || 
				    $r->{'type'} eq 'SOA')) {
		# Skip SOA and NS records for sub-domains in the same file
		next;
		}
	if ($r->{'type'} eq 'NSEC' || $r->{'type'} eq 'NSEC3' ||
	    $r->{'type'} eq 'RRSIG' || $r->{'type'} eq 'DNSKEY') {
		# Skip DNSSEC records, as they get re-generated
		next;
		}
	if (!$r->{'type'}) {
		# Skip special directives, like $ttl
		next;
		}
	foreach my $sd (@sublist) {
		if ($r->{'name'} eq $sd->{'dom'}."." ||
		    $r->{'name'} =~ /\.\Q$sd->{'dom'}\E\.$/) {
			# Skip records in sub-domains of the source
			next RECORD;
			}
		}
	$r->{'name'} =~ s/\Q$olddom\E\.$/$dom\./i;
	foreach my $v (@{$r->{'values'}}) {
		$v =~ s/\Q$olddom\E/$dom/i;
		$v =~ s/\Q$oldip\E$/$ip/i;
		}
	&bind8::create_record($file, $r->{'name'}, $r->{'ttl'},
			      'IN', $r->{'type'}, &join_record_values($r));
	}
}

# add_webmail_dns_records(&domain, [&tmpl], [file], [&already-got])
# Adds the webmail and admin DNS records, if requested in the template
sub add_webmail_dns_records
{
local ($d, $tmpl, $file, $already) = @_;
$tmpl ||= &get_template($d->{'template'});
$file ||= &get_domain_dns_file($d);
return 0 if (!$file);
local $count = 0;
local $ip = $d->{'dns_ip'} || $d->{'ip'};
foreach my $r ('webmail', 'admin') {
	local $n = "$r.$d->{'dom'}.";
	if ($tmpl->{'web_'.$r} && (!$already || !$already->{$n})) {
		&bind8::create_record($file, $n, undef,
				      "IN", "A", $ip);
		$count++;
		}
	}
if ($count) {
	local @recs = &bind8::read_zone_file($file, $d->{'dom'});
	&post_records_change($_[0], \@recs);
	&register_post_action(\&restart_bind);
	}
return $count;
}

# remove_webmail_dns_records(&domain)
# Remove the webmail and admin DNS records
sub remove_webmail_dns_records
{
local ($d) = @_;
local $file = &get_domain_dns_file($d);
return 0 if (!$file);
local @recs = &bind8::read_zone_file($file, $d->{'dom'});
local $count = 0;
foreach my $r (reverse('webmail', 'admin')) {
	local $n = "$r.$d->{'dom'}.";
	local ($rec) = grep { $_->{'name'} eq $n } @recs;
	if ($rec) {
		&bind8::delete_record($file, $rec);
		$count++;
		}
	}
if ($count) {
	&post_records_change($_[0], \@recs);
	&register_post_action(\&restart_bind);
	}
return $count;
}

# add_ip6_records(&domain, [file])
# For each A record for the domain whose value is it's IPv4 address, add an
# AAAA record with the v6 address.
sub add_ip6_records
{
local ($d, $file) = @_;
&require_bind();
$file ||= &get_domain_dns_file($d);
return 0 if (!$file);

# Work out which AAAA records we already have
local @recs = &bind8::read_zone_file($file, $d->{'dom'});
local %already;
foreach my $r (@recs) {
	if ($r->{'type'} eq 'AAAA' && $r->{'values'}->[0] eq $d->{'ip6'}) {
		$already{$r->{'name'}}++;
		}
	}

# Clone A records
my $count = 0;
my $withdot = $d->{'dom'}.".";
foreach my $r (@recs) {
	if ($r->{'type'} eq 'A' && $r->{'values'}->[0] eq $d->{'ip'} &&
	    !$already{$r->{'name'}} &&
	    ($r->{'name'} eq $withdot || $r->{'name'} =~ /\.\Q$withdot\E$/)) {
		&bind8::create_record($file, $r->{'name'}, $r->{'ttl'},
				      'IN', 'AAAA', $d->{'ip6'});
		$count++;
		}
	}

return $count;
}

# remove_ip6_records(&domain)
# Delete all AAAA records whose value is the domain's IP6 address
sub remove_ip6_records
{
local ($d) = @_;
&require_bind();
local $file = &get_domain_dns_file($d);
local @recs = &bind8::read_zone_file($file, $d->{'dom'});
my $withdot = $d->{'dom'}.".";
foreach my $r (reverse(@recs)) {
	if ($r->{'type'} eq 'AAAA' && $r->{'values'}->[0] eq $d->{'ip6'} &&
	    ($r->{'name'} eq $withdot || $r->{'name'} =~ /\.\Q$withdot\E$/)) {
		&bind8::delete_record($file, $r);
		}
	}
}

# save_domain_matchall_record(&domain, star)
# Add or remove a *.domain.com wildcard DNS record, pointing to the main
# IP address. Used in conjuction with save_domain_web_star.
sub save_domain_matchall_record
{
local ($d, $star) = @_;
local $file = &get_domain_dns_file($d);
return 0 if (!$file);
local @recs = &bind8::read_zone_file($file, $d->{'dom'});
local $withstar = "*.".$d->{'dom'}.".";
local ($r) = grep { $_->{'name'} eq $withstar } @recs;
local $any = 0;
if ($star && !$r) {
	# Need to add
	my $ip = $d->{'dns_ip'} || $d->{'ip'};
	&bind8::create_record($file, $withstar, undef, "IN", "A", $ip);
	$any++;
	}
elsif (!$star && $r) {
	# Need to remove
	&bind8::delete_record($file, $r);
	$any++;
	}
if ($any) {
	&post_records_change($d, \@recs);
	&register_post_action(\&restart_bind);
	}
return $any;
}

# validate_dns(&domain)
# Check for the DNS domain and records file
sub validate_dns
{
local ($d) = @_;
local $z;
if ($d->{'dns_submode'}) {
	# Records are in parent domain's file
	local $parent = &get_domain($d->{'subdom'}) ||
			&get_domain($d->{'parent'});
	$z = &get_bind_zone($parent->{'dom'});
	}
else {
	# Domain has its own records file
	$z = &get_bind_zone($d->{'dom'});
	}

# Make sure the zone and file exists
return &text('validate_edns', "<tt>$d->{'dom'}</tt>") if (!$z);
local $file = &bind8::find("file", $z->{'members'});
return &text('validate_ednsfile', "<tt>$d->{'dom'}</tt>") if (!$file);
local $zonefile = &bind8::make_chroot(
			&bind8::absolute_path($file->{'values'}->[0]));
return &text('validate_ednsfile2', "<tt>$zonefile</tt>") if (!-r $zonefile);

# Check for critical records, and that www.$dom and $dom resolve to the
# expected IP address (if we have a website)
local $bind8::config{'short_names'} = 0;
local @recs = &bind8::read_zone_file($file->{'values'}->[0], $d->{'dom'});
local %got;
local $ip = $d->{'dns_ip'} || $d->{'ip'};
foreach my $r (@recs) {
	$got{uc($r->{'type'})}++;
	}
$got{'SOA'} || return &text('validate_ednssoa', "<tt>$zonefile</tt>");
$got{'A'} || return &text('validate_ednsa', "<tt>$zonefile</tt>");
if ($d->{'web'}) {
	foreach my $n ($d->{'dom'}.'.', 'www.'.$d->{'dom'}.'.') {
		my @nips = map { $_->{'values'}->[0] }
		       grep { $_->{'type'} eq 'A' && $_->{'name'} eq $n } @recs;
		if (@nips && &indexof($ip, @nips) < 0) {
			return &text('validate_ednsip', "<tt>$n</tt>",
			    "<tt>".join(' or ', @nips)."</tt>", "<tt>$ip</tt>");
			}
		}
	}

# If possible, run named-checkzone
if (defined(&bind8::supports_check_zone) && &bind8::supports_check_zone()) {
	local @errs = &bind8::check_zone_records($z);
	if (@errs) {
		return &text('validate_ednscheck',
			join("<br>", map { &html_escape($_) } @errs));
		}
	}
return undef;
}

# disable_dns(&domain)
# Re-names this domain in named.conf with the .disabled suffix
sub disable_dns
{
&$first_print($text{'disable_bind'});
if ($_[0]->{'dns_submode'}) {
	# Disable is not done for sub-domains
	&$second_print($text{'disable_bindnosub'});
	return;
	}
&obtain_lock_dns($_[0], 1);
&require_bind();
local $z = &get_bind_zone($_[0]->{'dom'});
if ($z) {
	local $rootfile = &bind8::make_chroot($z->{'file'});
	$z->{'values'}->[0] = $_[0]->{'dom'}.".disabled";
	&bind8::save_directive(&bind8::get_config_parent(), [ $z ], [ $z ], 0);
	&flush_file_lines();

	# Rename all records in the domain with the new .disabled name
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local $bind8::config{'short_names'} = 1;
	local @recs = &bind8::read_zone_file($fn, $_[0]->{'dom'});
	foreach my $r (@recs) {
		if ($r->{'name'} =~ /\.\Q$_[0]->{'dom'}\E\.$/ ||
		    $r->{'name'} eq "$_[0]->{'dom'}.") {
			# Need to rename
                        &bind8::modify_record($fn, $r,
					      $r->{'name'}."disabled.",
                                              $r->{'ttl'}, $r->{'class'},
                                              $r->{'type'},
					      &join_record_values($r),
                                              $r->{'comment'});
			}
		}

	# Clear zone names caches
	undef(@bind8::list_zone_names_cache);
	&$second_print($text{'setup_done'});
	&register_post_action(\&restart_bind);

	# If on any slaves, delete there too
	$_[0]->{'old_dns_slave'} = $_[0]->{'dns_slave'};
	&delete_zone_on_slaves($_[0]);
	}
else {
	&$second_print($text{'save_nobind'});
	}
&release_lock_dns($_[0], 1);
}

# enable_dns(&domain)
# Re-names this domain in named.conf to remove the .disabled suffix
sub enable_dns
{
&$first_print($text{'enable_bind'});
if ($_[0]->{'dns_submode'}) {
	# Disable is not done for sub-domains
	&$second_print($text{'enable_bindnosub'});
	return;
	}
&obtain_lock_dns($_[0], 1);
&require_bind();
local $z = &get_bind_zone($_[0]->{'dom'});
if ($z) {
	local $rootfile = &bind8::make_chroot($z->{'file'});
	$z->{'values'}->[0] = $_[0]->{'dom'};
	&bind8::save_directive(&bind8::get_config_parent(), [ $z ], [ $z ], 0);
	&flush_file_lines();

	# Fix all records in the domain with the .disabled name
	local $file = &bind8::find("file", $z->{'members'});
	local $fn = $file->{'values'}->[0];
	local $bind8::config{'short_names'} = 1;
	local @recs = &bind8::read_zone_file($fn, $_[0]->{'dom'});
	foreach my $r (@recs) {
		if ($r->{'name'} =~ /\.\Q$_[0]->{'dom'}\E\.disabled\.$/ ||
		    $r->{'name'} eq "$_[0]->{'dom'}.disabled.") {
			# Need to rename
			$r->{'name'} =~ s/\.disabled\.$/\./;
                        &bind8::modify_record($fn, $r,
					      $r->{'name'},
                                              $r->{'ttl'}, $r->{'class'},
                                              $r->{'type'},
					      &join_record_values($r),
                                              $r->{'comment'});
			}
		}

	# Clear zone names caches
	undef(@bind8::list_zone_names_cache);
	&$second_print($text{'setup_done'});
	&register_post_action(\&restart_bind);

	# If it used to be on any slaves, enable too
	$_[0]->{'dns_slave'} = $_[0]->{'old_dns_slave'};
	&create_zone_on_slaves($_[0], $_[0]->{'dns_slave'});
	delete($_[0]->{'old_dns_slave'});
	}
else {
	&$second_print($text{'save_nobind'});
	}
&release_lock_dns($_[0], 1);
}

# get_bind_zone(name, [&config], [file])
# Returns the zone structure for the named domain, possibly with .disabled
sub get_bind_zone
{
&require_bind();
local $conf = $_[1] ? $_[1] :
	      $_[2] ? [ &bind8::read_config_file($_[2]) ] :
		      &bind8::get_config();
local @zones = &bind8::find("zone", $conf);
local ($v, $z);
foreach $v (&bind8::find("view", $conf)) {
	push(@zones, &bind8::find("zone", $v->{'members'}));
	}
local ($z) = grep { lc($_->{'value'}) eq lc($_[0]) ||
		    lc($_->{'value'}) eq lc("$_[0].disabled") } @zones;
return $z;
}

# restart_bind(&domain)
# Signal BIND to re-load its configuration
sub restart_bind
{
&$first_print($text{'setup_bindpid'});
local $bindlock = "$module_config_directory/bind-restart";
&lock_file($bindlock);
local $pid = &get_bind_pid();
if ($pid) {
	if ($bconfig{'restart_cmd'}) {
		&system_logged("$bconfig{'restart_cmd'} >/dev/null 2>&1 </dev/null");
		}
	else {
		&kill_logged('HUP', $pid);
		}
	&$second_print($text{'setup_done'});
	$rv = 1;
	}
else {
	&$second_print($text{'setup_notrun'});
	$rv = 0;
	}
if (&bind8::list_slave_servers()) {
	# Re-start on slaves too
	&$first_print(&text('setup_bindslavepids'));
	local @slaveerrs = &bind8::restart_on_slaves();
	if (@slaveerrs) {
		&$second_print($text{'setup_bindeslave'});
		foreach $sr (@slaveerrs) {
			&$second_print($sr->[0]->{'host'}." : ".$sr->[1]);
			}
		}
	else {
		&$second_print($text{'setup_done'});
		}
	}
&unlock_file($bindlock);
return $rv;
}

# check_dns_clash(&domain, [changing])
# Returns 1 if a domain already exists in BIND
sub check_dns_clash
{
if (!$_[1] || $_[1] eq 'dom') {
	local ($czone) = &get_bind_zone($_[0]->{'dom'});
	return $czone ? 1 : 0;
	}
return 0;
}

# get_bind_pid()
# Returns the BIND PID, if it is running
sub get_bind_pid
{
&require_bind();
local $pidfile = &bind8::get_pid_file();
return &check_pid_file(&bind8::make_chroot($pidfile, 1));
}

# backup_dns(&domain, file)
# Save all the virtual server's DNS records as a separate file
sub backup_dns
{
&require_bind();
return 1 if ($_[0]->{'dns_submode'});	# backed up in parent
&$first_print($text{'backup_dnscp'});
local $z = &get_bind_zone($_[0]->{'dom'});
if ($z) {
	local $file = &bind8::find("file", $z->{'members'});
	local $filename = &bind8::make_chroot(
		&bind8::absolute_path($file->{'values'}->[0]));
	if (-r $filename) {
		&copy_source_dest($filename, $_[1]);
		&$second_print($text{'setup_done'});
		return 1;
		}
	else {
		&$second_print(&text('backup_dnsnozonefile',
				     "<tt>$filename</tt>"));
		return 0;
		}
	}
else {
	&$second_print($text{'backup_dnsnozone'});
	return 0;
	}
}

# restore_dns(&domain, file, &options)
# Update the virtual server's DNS records from the backup file, except the SOA
sub restore_dns
{
&require_bind();
return 1 if ($_[0]->{'dns_submode'});	# restored in parent
&$first_print($text{'restore_dnscp'});
&obtain_lock_dns($_[0], 1);
local $z = &get_bind_zone($_[0]->{'dom'});
if ($z) {
	local $file = &bind8::find("file", $z->{'members'});
	local $filename = &bind8::make_chroot(
			&bind8::absolute_path($file->{'values'}->[0]));
	local $fn = $file->{'values'}->[0];
	local @thisrecs;

	if ($_[2]->{'wholefile'}) {
		# Copy whole file
		&copy_source_dest($_[1], $filename);
		&bind8::set_ownership($filename);
		}
	else {
		# Only copy section after SOA
		@thisrecs = &bind8::read_zone_file($fn, $_[0]->{'dom'});
		local $srclref = &read_file_lines($_[1], 1);
		local $dstlref = &read_file_lines($filename);
		local ($srcstart, $srcend) = &except_soa($_[0], $_[1]);
		local ($dststart, $dstend) = &except_soa($_[0], $filename);
		splice(@$dstlref, $dststart, $dstend - $dststart + 1,
		       @$srclref[$srcstart .. $srcend]);
		&flush_file_lines($filename);
		}

	# Need to bump SOA
	local @recs = &bind8::read_zone_file($fn, $_[0]->{'dom'});
	&post_records_change($_[0], \@recs);

	# Need to update IP addresses
	local $r;
	local ($baserec) = grep { $_->{'type'} eq "A" &&
				  ($_->{'name'} eq $_[0]->{'dom'}."." ||
				   $_->{'name'} eq '@') } @recs;
	local $ip = $_[0]->{'dns_ip'} || $_[0]->{'ip'};
	local $baseip = $baserec ? $baserec->{'values'}->[0] : undef;
	&modify_records_ip_address(\@recs, $fn, $baseip, $ip);

	# Replace NS records with those from new system
	if (!$_[2]->{'wholefile'}) {
		local @thisns = grep { $_->{'type'} eq 'NS' } @thisrecs;
		local @ns = grep { $_->{'type'} eq 'NS' } @recs;
		foreach my $r (@thisns) {
			# Create NS records that were in new system's file
			&bind8::create_record($fn, $r->{'name'}, $r->{'ttl'},
					      $r->{'class'}, $r->{'type'},
					      &join_record_values($r),
					      $r->{'comment'});
			}
		foreach my $r (reverse(@ns)) {
			# Remove old NS records that we copied over
			&bind8::delete_record($fn, $r);
			}
		}

	&$second_print($text{'setup_done'});

	&register_post_action(\&restart_bind);
	return 1;
	}
else {
	&$second_print($text{'backup_dnsnozone'});
	return 0;
	}
&release_lock_dns($_[0], 1);
}

# modify_records_ip_address(&records, filename, oldip, newip)
# Update the IP address in all DNS records
sub modify_records_ip_address
{
local ($recs, $fn, $oldip, $newip) = @_;
local $count = 0;
foreach my $r (@$recs) {
	my $changed = 0;
	if (($r->{'type'} eq "A" || $r->{'type'} eq "AAAA") &&
	    $r->{'values'}->[0] eq $oldip) {
		# Address record - just replace IP
		$r->{'values'}->[0] = $newip;
		$changed = 1;
		}
	elsif ($r->{'type'} eq "SPF" && $r->{'values'}->[0] =~ /$oldip/) {
		# SPF record - replace ocurrances of IP
		$r->{'values'}->[0] =~ s/$oldip/$newip/g;
		$changed = 1;
		}
	if ($changed) {
		&bind8::modify_record($fn, $r, $r->{'name'},
				      $r->{'ttl'},$r->{'class'},
				      $r->{'type'},
				      &join_record_values($r),
				      $r->{'comment'});
		$count++;
		}
	}
return $count;
}

# except_soa(&domain, file)
# Returns the start and end lines of a records file for the entries
# after the SOA.
sub except_soa
{
local $bind8::config{'chroot'} = "/";	# make sure path is absolute
local $bind8::config{'auto_chroot'} = undef;
undef($bind8::get_chroot_cache);
local @recs = &bind8::read_zone_file($_[1], $_[0]->{'dom'});
local ($r, $start, $end);
foreach $r (@recs) {
	if ($r->{'type'} ne "SOA" && !$r->{'generate'} && !$r->{'defttl'} &&
	    !defined($start)) {
		$start = $r->{'line'};
		}
	$end = $r->{'eline'};
	}
undef($bind8::get_chroot_cache);	# Reset cache back
return ($start, $end);
}

# get_bind_view([&conf], view)
# Returns the view object for the view to add domains to
sub get_bind_view
{
&require_bind();
local $conf = $_[0] || &bind8::get_config();
local @views = &bind8::find("view", $conf);
local ($view) = grep { $_->{'values'}->[0] eq $_[1] } @views;
return $view;
}

# show_restore_dns(&options)
# Returns HTML for DNS restore option inputs
sub show_restore_dns
{
local ($opts, $d) = @_;
return &ui_checkbox("dns_wholefile", 1, $text{'restore_dnswholefile'},
		    $opts->{'wholefile'});
}

# parse_restore_dns(&in)
# Parses the inputs for DNS restore options
sub parse_restore_dns
{
local ($in, $d) = @_;
return { 'wholefile' => $in->{'dns_wholefile'} };
}

# sysinfo_dns()
# Returns the BIND version
sub sysinfo_dns
{
&require_bind();
if (!$bind8::bind_version) {
	local $out = `$bind8::config{'named_path'} -v 2>&1`;
	if ($out =~ /(bind|named)\s+([0-9\.]+)/i) {
		$bind8::bind_version = $2;
		}
	}
return ( [ $text{'sysinfo_bind'}, $bind8::bind_version ] );
}

# links_dns(&domain)
# Returns a link to the BIND module
sub links_dns
{
local ($d) = @_;
if (!$d->{'dns_submode'}) {
	return ( { 'mod' => 'bind8',
		   'desc' => $text{'links_dns'},
		   'page' => "edit_master.cgi?zone=".&urlize($d->{'dom'}),
		   'cat' => 'services',
		 } );
	}
return ( );
}

sub startstop_dns
{
local ($typestatus) = @_;
local $bpid = defined($typestatus{'bind8'}) ?
		$typestatus{'bind8'} == 1 : &get_bind_pid();
local @links = ( { 'link' => '/bind8/',
		   'desc' => $text{'index_bmanage'},
		   'manage' => 1 } );
if ($bpid && kill(0, $bpid)) {
	return ( { 'status' => 1,
		   'name' => $text{'index_bname'},
		   'desc' => $text{'index_bstop'},
		   'restartdesc' => $text{'index_brestart'},
		   'longdesc' => $text{'index_bstopdesc'},
		   'links' => \@links } );
	}
else {
	return ( { 'status' => 0,
		   'name' => $text{'index_bname'},
		   'desc' => $text{'index_bstart'},
		   'longdesc' => $text{'index_bstartdesc'},
		   'links' => \@links } );
	}
}

sub start_service_dns
{
&require_bind();
return &bind8::start_bind();
}

sub stop_service_dns
{
&require_bind();
return &bind8::stop_bind();
}

# show_template_dns(&tmpl)
# Outputs HTML for editing BIND related template options
sub show_template_dns
{
local ($tmpl) = @_;
&require_bind();
local $conf = &bind8::get_config();
local @views = &bind8::find("view", $conf);

# DNS records
local $ndi = &none_def_input("dns", $tmpl->{'dns'}, $text{'tmpl_dnsbelow'}, 1,
     0, undef, [ "dns", "bind_replace", "dnsns", "dns_ttl_def", "dns_ttl",
		 "dnsprins", @views ? ( "newdns_view" ) : ( ) ]);
print &ui_table_row(&hlink($text{'tmpl_dns'}, "template_dns"),
	$ndi."<br>\n".
	&ui_textarea("dns", $tmpl->{'dns'} eq "none" ? "" :
				join("\n", split(/\t/, $tmpl->{'dns'})),
		     10, 60)."<br>\n".
	&ui_radio("bind_replace", int($tmpl->{'dns_replace'}),
		  [ [ 0, $text{'tmpl_replace0'} ],
		    [ 1, $text{'tmpl_replace1'} ] ]));

# Address records to add
my @add_records = split(/\s+/, $tmpl->{'dns_records'});
if (!@add_records || $add_records[0] eq 'none') {
	@add_records = @automatic_dns_records;
	}
my @grid = map { &ui_checkbox("dns_records", $_, $text{'tmpl_dns_record_'.$_},
			      &indexof($_, @add_records) >= 0) }
	       @automatic_dns_records;
print &ui_table_row(&hlink($text{'tmpl_dnsrecords'}, "template_dns_records"),
	&ui_grid_table(\@grid, scalar(@grid)));

# Default TTL
local $tmode = $tmpl->{'dns_ttl'} eq 'none' ? 0 :
	       $tmpl->{'dns_ttl'} eq 'skip' ? 1 : 2;
print &ui_table_row(&hlink($text{'tmpl_dnsttl'}, "template_dns_ttl"),
	&ui_radio("dns_ttl_def", $tmpl->{'dns_ttl'} eq '' ? 0 :
				 $tmpl->{'dns_ttl'} eq 'none' ? 1 : 2,
	  [ [ 0, $text{'tmpl_dnsttl0'} ],
	    [ 1, $text{'tmpl_dnsttl1'} ],
	    [ 2, $text{'tmpl_dnsttl2'}." ".
	      &ui_textbox("dns_ttl", $tmode == 2 ? $tmpl->{'dns_ttl'} : "", 15)
	    ] ]));

# Manual NS records
print &ui_table_row(&hlink($text{'tmpl_dnsns'}, "template_dns_ns"),
	&ui_textarea("dnsns", join("\n", split(/\s+/, $tmpl->{'dns_ns'})),
		     3, 50)."<br>\n".
	&ui_checkbox("dnsprins", 1, $text{'tmpl_dnsprins'},
		     $tmpl->{'dns_prins'}));

# Option for view to add to, for BIND 9
if (@views) {
	print &ui_table_row($text{'newdns_view'},
		&ui_select("view", $tmpl->{'dns_view'},
			[ [ "", $text{'newdns_noview'} ],
			  map { [ $_->{'values'}->[0] ] } @views ]));
	}

# Add sub-domains to parent domain DNS
print &ui_table_row(&hlink($text{'tmpl_dns_sub'},
                           "template_dns_sub"),
	&none_def_input("dns_sub", $tmpl->{'dns_sub'},
		        $text{'yes'}, 0, 0, $text{'no'}));

print &ui_table_hr();

# Master NS hostnames
print &ui_table_row(&hlink($text{'tmpl_dnsmaster'},
                           "template_dns_master"),
	&none_def_input("dns_master", $tmpl->{'dns_master'},
			$text{'tmpl_dnsmnames'}, 0, 0,
			$text{'tmpl_dnsmauto'}."<br>", [ "dns_master" ])." ".
	&ui_textbox("dns_master", $tmpl->{'dns_master'} eq 'none' ? '' :
					$tmpl->{'dns_master'}, 40));

print &ui_table_hr();

# Option for SPF record
print &ui_table_row(&hlink($text{'tmpl_spf'},
                           "template_dns_spf_mode"),
	&none_def_input("dns_spf", $tmpl->{'dns_spf'},
		        $text{'tmpl_spfyes'}, 0, 0, $text{'no'},
			[ "dns_spfhosts", "dns_spfall", "dns_spfincludes" ]));

# Extra SPF hosts
print &ui_table_row(&hlink($text{'tmpl_spfhosts'},
			   "template_dns_spfhosts"),
	&ui_textbox("dns_spfhosts", $tmpl->{'dns_spfhosts'}, 40));

# Extra SPF includes
print &ui_table_row(&hlink($text{'tmpl_spfincludes'},
			   "template_dns_spfincludes"),
	&ui_textbox("dns_spfincludes", $tmpl->{'dns_spfincludes'}, 40));

# SPF ~all mode
print &ui_table_row(&hlink($text{'tmpl_spfall'},
			   "template_dns_spfall"),
	&ui_yesno_radio("dns_spfall", $tmpl->{'dns_spfall'} ? 1 : 0));

print &ui_table_hr();

# Extra named.conf directives
print &ui_table_row(&hlink($text{'tmpl_namedconf'}, "namedconf"),
    &none_def_input("namedconf", $tmpl->{'namedconf'},
		    $text{'tmpl_namedconfbelow'}, 0, 0, undef,
		    [ "namedconf", "namedconf_also_notify",
		      "namedconf_allow_transfer" ])."<br>".
    &ui_textarea("namedconf",
		 $tmpl->{'namedconf'} eq 'none' ? '' :
			join("\n", split(/\t/, $tmpl->{'namedconf'})),
		 5, 60));

# Add also-notify and allow-transfer
print &ui_table_row(&hlink($text{'tmpl_dnsalso'}, "template_dns_also"),
	&ui_checkbox("namedconf_also_notify", 1, 'also-notify',
		     !$tmpl->{'namedconf_no_also_notify'})." ".
	&ui_checkbox("namedconf_allow_transfer", 1, 'allow-transfer',
		     !$tmpl->{'namedconf_no_allow_transfer'}));

# DNSSEC for new domains
if (defined(&bind8::supports_dnssec) && &bind8::supports_dnssec()) {
	print &ui_table_hr();

	# Setup for new domains?
	print &ui_table_row(&hlink($text{'tmpl_dnssec'}, "dnssec"),
		&none_def_input("dnssec", $tmpl->{'dnssec'}, $text{'yes'}, 0, 0,
			$text{'no'}, [ "dnssec_alg", "dnssec_single" ]));

	# Encryption algorithm
	print &ui_table_row(&hlink($text{'tmpl_dnssec_alg'}, "dnssec_alg"),
		&ui_select("dnssec_alg", $tmpl->{'dnssec_alg'} || "RSASHA1",
			   [ &bind8::list_dnssec_algorithms() ]));

	# One key or two?
	print &ui_table_row(&hlink($text{'tmpl_dnssec_single'},"dnssec_single"),
		&ui_radio("dnssec_single", $tmpl->{'dnssec_single'} ? 1 : 0,
			  [ [ 0, $bind8::text{'zonedef_two'} ],
			    [ 1, $bind8::text{'zonedef_one'} ] ]));
	}
}

# parse_template_dns(&tmpl)
# Updates BIND related template options from %in
sub parse_template_dns
{
local ($tmpl) = @_;

# Save DNS settings
$tmpl->{'dns'} = &parse_none_def("dns");
if ($in{"dns_mode"} == 2) {
	$tmpl->{'default'} || $tmpl->{'dns'} ||
		&error($text{'tmpl_edns'});
	$tmpl->{'dns_replace'} = $in{'bind_replace'};
	$tmpl->{'dns_view'} = $in{'view'};

	&require_bind();
	local $fakeip = "1.2.3.4";
	local $fakedom = "foo.com";
	local $recs = &substitute_virtualmin_template(
			join("\n", split(/\t+/, $in{'dns'}))."\n",
			{ 'ip' => $fakeip,
			  'dom' => $fakedom,
		 	  'web' => 1, });
	local $temp = &transname();
	&open_tempfile(TEMP, ">$temp");
	&print_tempfile(TEMP, $recs);
	&close_tempfile(TEMP);
	local $bind8::config{'short_names'} = 0;  # force canonicalization
	local $bind8::config{'chroot'} = '/';	  # turn off chroot for temp path
	local $bind8::config{'auto_chroot'} = undef;
	undef($bind8::get_chroot_cache);
	local @recs = &bind8::read_zone_file($temp, $fakedom);
	unlink($temp);
	foreach $r (@recs) {
		$soa++ if ($r->{'name'} eq $fakedom."." &&
			   $r->{'type'} eq "SOA");
		$ns++ if ($r->{'name'} eq $fakedom."." &&
			  $r->{'type'} eq "NS");
		$dom++ if ($r->{'name'} eq $fakedom."." &&
			   ($r->{'type'} eq "A" || $r->{'type'} eq "MX"));
		$www++ if ($r->{'name'} eq "www.".$fakedom."." &&
			   $r->{'type'} eq "A" ||
			   $r->{'type'} eq "CNAME");
		}
	undef($bind8::get_chroot_cache);	# reset cache back

	if ($in{'bind_replace'}) {
		# Make sure an SOA and NS records exist
		$soa == 1 || &error($text{'newdns_esoa'});
		$ns || &error($text{'newdns_ens'});
		$dom || &error($text{'newdns_edom'});
		$www || &error($text{'newdns_ewww'});
		}
	else {
		# Make sure SOA doesn't exist
		$soa && &error($text{'newdns_esoa2'});
		}

	# Save default TTL
	if ($in{'dns_ttl_def'} == 0) {
		$tmpl->{'dns_ttl'} = '';
		}
	elsif ($in{'dns_ttl_def'} == 1) {
		$tmpl->{'dns_ttl'} = 'none';
		}
	else {
		$in{'dns_ttl'} =~ /^\d+(h|d|m|y|w|)$/i ||
			&error($text{'tmpl_ednsttl'});
		$tmpl->{'dns_ttl'} = $in{'dns_ttl'};
		}

	# Save automatic A records
	$tmpl->{'dns_records'} = join(" ", split(/\0/, $in{'dns_records'}));

	# Save additional nameservers
	$in{'dnsns'} =~ s/\r//g;
	local @ns = split(/\n+/, $in{'dnsns'});
	foreach my $n (@ns) {
		&check_ipaddress($n) && &error(&text('newdns_ensip', $n));
		gethostbyname($n) || &error(&text('newdns_enshost', $n));
		}
	$tmpl->{'dns_ns'} = join(" ", @ns);
	$tmpl->{'dns_prins'} = $in{'dnsprins'};
	}

# Save NS hostname
$in{'dns_master_mode'} != 2 ||
   ($in{'dns_master'} =~ /^[a-z0-9\.\-\_]+$/i && $in{'dns_master'} =~ /\./ &&
    !&check_ipaddress($in{'dns_master'})) ||
	&error($text{'tmpl_ednsmaster'});
$tmpl->{'dns_master'} = $in{'dns_master_mode'} == 0 ? "none" :
		        $in{'dns_master_mode'} == 1 ? undef : $in{'dns_master'};

# Save SPF
$tmpl->{'dns_spf'} = $in{'dns_spf_mode'} == 0 ? "none" :
		     $in{'dns_spf_mode'} == 1 ? undef : "yes";
$tmpl->{'dns_spfhosts'} = $in{'dns_spfhosts'};
$tmpl->{'dns_spfincludes'} = $in{'dns_spfincludes'};
$tmpl->{'dns_spfall'} = $in{'dns_spfall'};

# Save sub-domain DNS mode
$tmpl->{'dns_sub'} = $in{'dns_sub_mode'} == 0 ? "none" :
		     $in{'dns_sub_mode'} == 1 ? undef : "yes";

# Save named.conf
$tmpl->{'namedconf'} = &parse_none_def("namedconf");
if ($in{'namedconf_mode'} == 2) {
	# Make sure the directives are valid
	local @recs = &text_to_named_conf($tmpl->{'namedconf'});
	if ($tmpl->{'namedconf'} =~ /\S/ && !@recs) {
		&error($text{'newdns_enamedconf'});
		}
	$tmpl->{'namedconf'} ||= " ";	# So it can be empty

	# Save other auto-add directives
	$tmpl->{'namedconf_no_also_notify'} =
		!$in{'namedconf_also_notify'};
	$tmpl->{'namedconf_no_allow_transfer'} =
		!$in{'namedconf_allow_transfer'};
	}

# Save DNSSEC
if (defined($in{'dnssec_mode'})) {
	$tmpl->{'dnssec'} = $in{'dnssec_mode'} == 0 ? "none" :
			    $in{'dnssec_mode'} == 1 ? undef : "yes";
	$tmpl->{'dnssec_alg'} = $in{'dnssec_alg'};
	$tmpl->{'dnssec_single'} = $in{'dnssec_single'};
	}
}

# get_domain_spf(&domain)
# Returns the SPF object for a domain from its DNS records, or undef.
sub get_domain_spf
{
local ($d) = @_;
local @recs = &get_domain_dns_records($d);
foreach my $r (@recs) {
	if ($r->{'type'} eq 'SPF' &&
	    $r->{'name'} eq $d->{'dom'}.'.') {
		return &bind8::parse_spf(@{$r->{'values'}});
		}
	}
return undef;
}

# save_domain_spf(&domain, &spf)
# Updates/creates/deletes a domain's SPF record.
sub save_domain_spf
{
local ($d, $spf) = @_;
local @recs = &get_domain_dns_records($d);
if (!@recs) {
	# Domain not found!
	return;
	}
local ($r) = grep { $_->{'type'} eq 'SPF' &&
		    $_->{'name'} eq $d->{'dom'}.'.' } @recs;
local $str = $spf ? &bind8::join_spf($spf) : undef;
local $bump = 1;
if ($r && $spf) {
	# Update record
	&bind8::modify_record($r->{'file'}, $r, $r->{'name'}, $r->{'ttl'},
			      $r->{'class'}, $r->{'type'}, "\"$str\"",
			      $r->{'comment'});
	}
elsif ($r && !$spf) {
	# Remove record
	&bind8::delete_record($r->{'file'}, $r);
	}
elsif (!$r && $spf) {
	# Add record
	&bind8::create_record($recs[0]->{'file'}, $d->{'dom'}.'.', undef,
			      "IN", "TXT", "\"$str\"");
	}
else {
	# Nothing to do
	$bump = 0;
	}
if ($bump) {
	&post_records_change($d, \@recs);
	&register_post_action(\&restart_bind);
	}
}

# get_domain_dns_records(&domain)
# Returns an array of DNS records for a domain, or empty if the file couldn't
# be found.
sub get_domain_dns_records
{
local ($d) = @_;
local $fn = &get_domain_dns_file($d);
return ( ) if (!$fn);
return &bind8::read_zone_file($fn, $d->{'dom'});
}

# get_domain_dns_file(&domain)
# Returns the chroot-relative path to a domain's DNS records
sub get_domain_dns_file
{
local ($d) = @_;
&require_bind();
local $z;
if ($d->{'dns_submode'}) {
	# Records are in super-domain
	local $parent = &get_domain($d->{'subdom'}) ||
			&get_domain($d->{'parent'});
	$z = &get_bind_zone($parent->{'dom'});
	}
else {
	# In this domain
	$z = &get_bind_zone($d->{'dom'});
	}
return undef if (!$z);
local $file = &bind8::find("file", $z->{'members'});
return undef if (!$file);
return $file->{'values'}->[0];
}

# default_domain_spf(&domain)
# Returns a default SPF object for a domain, based on its template
sub default_domain_spf
{
local ($d) = @_;
local $tmpl = &get_template($d->{'template'});
local $defip = &get_default_ip();
local $spf = { 'a' => 1, 'mx' => 1,
	       'a:' => [ $d->{'dom'} ],
	       'ip4:' => [ $defip ] };
local $hosts = &substitute_domain_template($tmpl->{'dns_spfhosts'}, $d);
foreach my $h (split(/\s+/, $hosts)) {
	if (&check_ipaddress($h) ||
	    $h =~ /^(\S+)\// && &check_ipaddress($1)) {
		push(@{$spf->{'ip4:'}}, $h);
		}
	else {
		push(@{$spf->{'a:'}}, $h);
		}
	}
local $includes = &substitute_domain_template($tmpl->{'dns_spfincludes'}, $d);
foreach my $i (split(/\s+/, $includes)) {
	push(@{$spf->{'include:'}}, $i);
	}
if ($d->{'dns_ip'}) {
	push(@{$spf->{'ip4:'}}, $d->{'dns_ip'});
	}
if ($d->{'ip'} ne $defip) {
	push(@{$spf->{'ip4:'}}, $d->{'ip'});
	}
$spf->{'all'} = $tmpl->{'dns_spfall'} ? 2 : 1;
return $spf;
}

# text_to_named_conf(text)
# Converts a text string which contains zero or more BIND directives into an
# array of directive objects.
sub text_to_named_conf
{
local ($str) = @_;
local $temp = &transname();
&open_tempfile(TEMP, ">$temp");
&print_tempfile(TEMP, $str);
&close_tempfile(TEMP);
&require_bind();
local $bind8::config{'chroot'} = undef;		# turn off chroot temporarily
local $bind8::config{'auto_chroot'} = undef;
undef($bind8::get_chroot_cache);
local @rv = grep { $_->{'name'} ne 'dummy' }
	    &bind8::read_config_file($temp, 0);
undef($bind8::get_chroot_cache);		# reset cache back
return @rv;
}

# post_records_change(&domain, &recs)
# Called after some records in a domain are changed, to bump to SOA
# and possibly re-sign
sub post_records_change
{
local ($d, $recs) = @_;
&require_bind();
local $z = &get_bind_zone($d->{'dom'});
return "Failed to find zone for $d->{'dom'}" if (!$z);
local $file = &bind8::find("file", $z->{'members'});
return "Failed to find records file for $d->{'dom'}" if (!$file);
&bind8::bump_soa_record($file, $recs);
if (defined(&bind8::supports_dnssec) &&
    &bind8::supports_dnssec()) {
	# Re-sign too
	eval {
		local $main::error_must_die = 1;
		&bind8::sign_dnssec_zone_if_key($z, $recs, 0);
		};
	if ($@) {
		return "DNSSEC signing failed : $@";
		}
	}
return undef;
}

# under_parent_domain(&domain, [&parent])
# Returns 1 if some domain's DNS zone is under a given parent's DNS zone
sub under_parent_domain
{
local ($d, $parent) = @_;
if (!$parent && $d->{'parent'}) {
	$parent = &get_domain($d->{'parent'});
	}
if ($parent && $d->{'dom'} =~ /\.\Q$parent->{'dom'}\E$/i && $parent->{'dns'}) {
	return 1;
	}
return 0;
}

# obtain_lock_dns(&domain, [named-conf-too])
# Lock a domain's zone file and named.conf file
sub obtain_lock_dns
{
local ($d, $conftoo) = @_;
return if (!$config{'dns'});
&obtain_lock_anything($d);

# Lock records file
if ($d) {
	if ($main::got_lock_dns_zone{$d->{'id'}} == 0) {
		&require_bind();
		local $conf = &bind8::get_config();
		local $z = &get_bind_zone($d->{'dom'}, $conf);
		local $fn;
		if ($z) {
			local $file = &bind8::find("file", $z->{'members'});
			$fn = $file->{'values'}->[0];
			}
		else {
			local $base = $bconfig{'master_dir'} ||
				      &bind8::base_directory($conf);
			$fn = &bind8::automatic_filename($d->{'dom'}, 0, $base);
			}
		local $rootfn = &bind8::make_chroot($fn);
		&lock_file($rootfn);
		$main::got_lock_dns_file{$d->{'id'}} = $rootfn;
		}
	$main::got_lock_dns_zone{$d->{'id'}}++;
	}

# Lock named.conf for this domain, if needed. We assume that all domains are
# in the same .conf file, even though that may not be true.
if ($conftoo) {
	if ($main::got_lock_dns == 0) {
		&require_bind();
		undef(@bind8::get_config_cache);
		undef(%bind8::get_config_parent_cache);
		&lock_file(&bind8::make_chroot($bind8::config{'zones_file'} ||
					       $bind8::config{'named_conf'}));
		}
	$main::got_lock_dns++;
	}
}

# release_lock_dns(&domain, [named-conf-too])
# Unlock the zone's records file and possibly named.conf entry
sub release_lock_dns
{
local ($d, $conftoo) = @_;
return if (!$config{'dns'});

# Unlock records file
if ($d) {
	if ($main::got_lock_dns_zone{$d->{'id'}} == 1) {
		local $rootfn = $main::got_lock_dns_file{$d->{'id'}};
		&unlock_file($rootfn) if ($rootfn);
		}
	$main::got_lock_dns_zone{$d->{'id'}}--
		if ($main::got_lock_dns_zone{$d->{'id'}});
	}

# Unlock named.conf
if ($conftoo) {
	if ($main::got_lock_dns == 1) {
		&require_bind();
		&unlock_file(&bind8::make_chroot($bind8::config{'zones_file'} ||
					         $bind8::config{'named_conf'}));
		}
	$main::got_lock_dns-- if ($main::got_lock_dns);
	}

&release_lock_anything($d);
}

$done_feature_script{'dns'} = 1;

1;

