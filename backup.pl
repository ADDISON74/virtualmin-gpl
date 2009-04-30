#!/usr/local/bin/perl
# Do a scheduled virtual server backup

package virtual_server;
$main::no_acl_check++;
require './virtual-server-lib.pl';
$host = &get_system_hostname();
if (&foreign_check("mailboxes")) {
	&foreign_require("mailboxes", "mailboxes-lib.pl");
	$has_mailboxes++;
	}

# Get the schedule being used
$id = 1;
$backup_debug = 0;
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--id") {
		$id = shift(@ARGV);
		$id || &usage("Missing backup schedule ID");
		}
	elsif ($a eq "--debug") {
		$backup_debug = 1;
		}
	elsif ($a eq "--force-email") {
		$force_email = 1;
		}
	else {
		&usage();
		}
	}
($sched) = grep { $_->{'id'} == $id } &list_scheduled_backups();
$sched || &usage("No scheduled backup with ID $id exists");

# Work out what will be backed up
if ($sched->{'all'} == 1) {
	# All domains
	@doms = &list_domains();
	}
elsif ($sched->{'all'} == 2) {
	# All except some domains
	%exc = map { $_, 1 } split(/\s+/, $sched->{'doms'});
	@doms = grep { !$exc{$_->{'id'}} } &list_domains();
	if ($sched->{'parent'}) {
		@doms = grep { !$_->{'parent'} || !$ext{$_->{'parent'}} } @doms;
		}
	}
else {
	# Selected domains
	foreach $d (split(/\s+/, $sched->{'doms'})) {
		local $dinfo = &get_domain($d);
		if ($dinfo) {
			push(@doms, $dinfo);
			if (!$dinfo->{'parent'} && $sched->{'parent'}) {
				push(@doms, &get_domain_by("parent", $d));
				}
			}
		}
	@doms = grep { !$donedom{$_->{'id'}}++ } @doms;
	}

# Work out who the schedule is being run for
if ($sched->{'owner'}) {
	$asd = &get_domain($sched->{'owner'});
	$owner = $asd ? $asd->{'user'} : $sched->{'owner'};
	local %access = &get_module_acl($owner);
	$cbmode = &can_backup_domain();		# Uses %access override
	@doms = grep { &can_backup_domain($_) } @doms;
	}
else {
	# Master admin
	$cbmode = 1;
	}

# Work out features and options
if ($sched->{'feature_all'}) {
	@do_features = ( &get_available_backup_features(), &list_backup_plugins() );
	}
else {
	@do_features = split(/\s+/, $sched->{'features'});
	}
foreach $f (@do_features) {
	$options{$f} = { map { split(/=/, $_) }
			  split(/,/, $sched->{'opts_'.$f}) };
	}
@vbs = split(/\s+/, $sched->{'virtualmin'});

# Start capturing output
$first_print = \&first_save_print;
$second_print = \&second_save_print;
$indent_print = \&indent_save_print;
$outdent_print = \&outdent_save_print;

# Run any before command
if ($sched->{'before'}) {
	&$first_print("Running pre-backup command ..");
	$out .= &backquote_command("($sched->{'before'}) 2>&1 </dev/null");
	print $out;
	$output .= $out;
	if ($?) {
		&$second_print(".. failed!");
		$ok = 0;
		$size = 0;
		goto PREFAILED;
		}
	else {
		&$second_print(".. done");
		}
	}

# Execute the backup
if ($sched->{'strftime'}) {
	$dest = &backup_strftime($sched->{'dest'});
	}
else {
	$dest = $sched->{'dest'};
	}
$start_time = time();
$current_id = undef;
($ok, $size, $errdoms) = &backup_domains($dest, \@doms, \@do_features,
			       $sched->{'fmt'},
			       $sched->{'errors'},
			       \%options,
			       $sched->{'fmt'} == 2,
			       \@vbs,
			       $sched->{'mkdir'},
			       $sched->{'onebyone'},
			       $cbmode == 2,
			       \&backup_cbfunc,
			       $sched->{'increment'});

# If purging old backups, do that now
if ($ok && $sched->{'purge'}) {
	$current_id = undef;
	$pok = &purge_domain_backups(
		$sched->{'dest'}, $sched->{'purge'}, $start_time);
	$ok = 0 if (!$pok);
	}

# Run any after command
if ($sched->{'after'}) {
	&$first_print("Running post-backup command ..");
	$out = &backquote_command("($sched->{'after'}) 2>&1 </dev/null");
	print $out;
	$output .= $out;
	if ($?) {
		&$second_print(".. failed!");
		}
	else {
		&$second_print(".. done");
		}
	}
&write_backup_log(\@doms, $dest, $backup->{'incremental'}, $start_time,
		  $size, $ok, "sched", $output);

PREFAILED:

# Send an email to the recipient, if there are any
if ($sched->{'email'} && $has_mailboxes &&
    (!$ok || !$sched->{'email_err'} || $force_email)) {
	if ($ok) {
		$output .= &text('backup_done', &nice_size($size))." ";
		$subject = &text('backup_donesubject', $host);
		}
	else {
		$output .= $text{'backup_failed'}." ";
		$subject = &text('backup_failedsubject', $host);
		}
	$total_time = time() - $start_time;
	$output .= &text('backup_time', &nice_hour_mins_secs($total_time))."\n";
	$output .= "\n";
	$output .= &text('backup_fromvirt', &get_virtualmin_url())."\n";
	$mail = { 'headers' => [ [ 'From', &get_global_from_address() ],
				 [ 'Subject', $subject ],
				 [ 'To', $sched->{'email'} ] ],
		  'attach'  => [ { 'headers' => [ [ 'Content-type',
						    'text/plain' ] ],
				   'data' => &entities_to_ascii($output) } ]
		};
	&mailboxes::send_mail($mail);
	}

# Send email to domain owners too, if selected
%errdoms = map { $_->{'id'}, $_ } @$errdoms;
if ($sched->{'email_doms'} && $has_mailboxes &&
    (!$ok || !$sched->{'email_err'} || $force_email)) {
	@emails = &unique(map { $_->{'emailto'} } @doms);
	foreach $email (@emails) {
		# Find the domains for this email address, and their output
		@edoms = grep { $_->{'emailto'} eq $email } @doms;
		$eoutput = join("", map { $domain_output{$_->{'id'}} } @edoms);
		$eoutput .= "\n";
		$eoutput .= &text('backup_fromvirt',
				&get_virtualmin_url($edoms[0]))."\n";

		# Check if any of the domains failed
		@failededoms = grep { $errdoms{$_->{'id'}} } @edoms;
		if (@failededoms) {
			$subject = &text('backup_failedsubject', $host);
			}
		else {
			$subject = &text('backup_donesubject', $host);
			}

		$mail = {
		  'headers' =>
			[ [ 'From', &get_global_from_address($edoms[0]) ],
			  [ 'Subject', $subject ],
			  [ 'To', $email ] ],
		  'attach'  =>
			[ { 'headers' => [ [ 'Content-type', 'text/plain' ] ],
			    'data' => &entities_to_ascii($eoutput) } ]
			};
		if ($eoutput) {
			&mailboxes::send_mail($mail);
			}
		}
	}

# Override print functions to capture output
sub first_save_print
{
local @msg = map { &html_tags_to_text(&entities_to_ascii($_)) } @_;
$output .= $indent_text.join("", @msg)."\n";
$domain_output{$current_id} .= $indent_text.join("", @msg)."\n"
	if ($current_id);
print $indent_text.join("", @msg)."\n" if ($backup_debug);
}
sub second_save_print
{
local @msg = map { &html_tags_to_text(&entities_to_ascii($_)) } @_;
$output .= $indent_text.join("", @msg)."\n\n";
$domain_output{$current_id} .= $indent_text.join("", @msg)."\n\n"
	if ($current_id);
print $indent_text.join("", @msg)."\n" if ($backup_debug);
}
sub indent_save_print
{
$indent_text .= "    ";
}
sub outdent_save_print
{
$indent_text = substr($indent_text, 4);
}

# Called during the backup process for each domain
sub backup_cbfunc
{
local ($d, $step, $info) = @_;
if ($step == 0) {
	$current_id = $d->{'id'};
	}
elsif ($step == 2) {
	$current_id = undef;
	}
}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Runs one scheduled Virtualmin backup. Usually called automatically from Cron.\n";
print "\n";
print "usage: backup.pl [--id number]\n";
print "                 [--debug]\n";
print "                 [--force-email]\n";
exit(1);
}


