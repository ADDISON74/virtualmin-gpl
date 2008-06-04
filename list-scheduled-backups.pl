#!/usr/local/bin/perl
# Outputs a list of all scheduled backups, or just those owned by some domain

package virtual_server;
if (!$module_name) {
	$main::no_acl_check++;
	$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
	$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
	if ($0 =~ /^(.*\/)[^\/]+$/) {
		chdir($1);
		}
	chop($pwd = `pwd`);
	$0 = "$pwd/list-scheduled-backups.pl";
	require './virtual-server-lib.pl';
	$< == 0 || die "list-scheduled-backups.pl must be run as root";
	}

# Parse command-line args
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		$domain = shift(@ARGV);
		}
	elsif ($a eq "--reseller") {
		$reseller = shift(@ARGV);
		}
	elsif ($a eq "--user") {
		$user = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	else {
		&usage();
		}
	}

# Get them all, then limit by domain
@scheds = &list_scheduled_backups();
if ($domain) {
	# By top-level domain
	$d = &get_domain_by("dom", $domain);
	$d || &usage("No domain named $domain exists");
	$d->{'parent'} && &usage("--domain must be followed by a top-level domain name");
	@scheds = grep { $_->{'owner'} eq $d->{'id'} } @scheds;
	}
elsif ($user) {
	# By domain owner
	$d = &get_domain_by_user($user);
	$d || &usage("No domain owned by $user exists");
	@scheds = grep { $_->{'owner'} eq $d->{'id'} } @scheds;
	}
elsif ($reseller) {
	# By reseller owner
	@scheds = grep { $_->{'owner'} eq $reseller } @scheds;
	}

if ($multi) {
	# Show all details
	foreach my $s (@scheds) {
		print "$s->{'id'}:\n";
		print "    Domains: ",&make_nice_dnames($s),"\n";
		print "    Include sub-servers: ",
			$s->{'parent'} ? "Yes" : "No","\n";
		if ($s->{'virtualmin'}) {
			print "    Virtualmin configs: $s->{'virtualmin'}\n";
			}
		print "    Destination: $s->{'dest'}\n";
		print "    Features: ",
			$s->{'feature_all'} ? "All" : $s->{'features'},"\n";
		print "    Incremental: ",$s->{'increment'} ? "Yes" : "No","\n";
		print "    Enabled: ",$s->{'enabled'} ? "Yes" : "No","\n";
		if ($s->{'special'}) {
			print "    Cron schedule: $s->{'special'}\n";
			}
		elsif ($s->{'mins'}) {
			print "    Cron schedule: ",
				join(" ", $s->{'mins'}, $s->{'hours'},
					  $s->{'days'}, $s->{'months'},
					  $s->{'weekdays'}),"\n";
			}
		if ($s->{'email'}) {
			print "    Send email to: $s->{'email'}\n";
			}
		print "    Send email: ",
			$s->{'email_err'} ? "Only on failure" : "Always","\n";
		print "    Notify domain owners: ",
			$s->{'email_doms'} ? "Yes" : "No","\n";
		}
	}
else {
	# Just show one per line
	$fmt = "%-22.22s %-40.40s %-15.15s\n";
	printf $fmt, "Domains", "Destination", "Schedule";
	printf $fmt, ("-" x 22), ("-" x 40), ("-" x 15);
	foreach my $s (@scheds) {
		printf $fmt, &make_nice_dnames($s),
			     &html_tags_to_text(
				&nice_backup_url($s->{'dest'}, 1)),
			     !$s->{'enabled'} ? "Disabled" :
			     $s->{'special'} ? $s->{'special'} :
				join(" ", $s->{'mins'}, $s->{'hours'},
                                          $s->{'days'}, $s->{'months'},
                                          $s->{'weekdays'});
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists some or all scheduled Virtualmin backups.\n";
print "\n";
print "usage: list-scheduled-backups.pl [--domain domain.name |\n";
print "                                  --user name |\n";
print "                                  --reseller name]\n";
print "                                 [--multiline]\n";
exit(1);
}

sub make_nice_dnames
{
local ($s) = @_;
local @dnames = ( );
foreach my $did (split(/\s+/, $s->{'doms'})) {
	$d = &get_domain($did);
	push(@dnames, $d->{'dom'}) if ($d);
	}
my $dnames = join(" ", @dnames);
return $s->{'all'} == 1 ? "All" :
       $s->{'all'} == 2 ? "Except ".$dnames :
       $dnames ? $dnames : "None";
}

