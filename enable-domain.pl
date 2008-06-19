#!/usr/local/bin/perl

=head1 enable-domain.pl

Re-enable one virtual server

This program reverses the disable process done by disable-domain.pl , or in
the Virtualmin web interface. It will restore the server to the state it was
in before being disabled.

=cut

package virtual_server;
if (!$module_name) {
	$main::no_acl_check++;
	$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
	$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
	if ($0 =~ /^(.*\/)[^\/]+$/) {
		chdir($1);
		}
	chop($pwd = `pwd`);
	$0 = "$pwd/enable-domain.pl";
	require './virtual-server-lib.pl';
	$< == 0 || die "enable-domain.pl must be run as root";
	}
@OLDARGV = @ARGV;

$first_print = \&first_text_print;
$second_print = \&second_text_print;

# Parse command-line args
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		$domain = lc(shift(@ARGV));
		}
	else {
		&usage("Unknown option $a");
		}
	}

# Find the domain
$domain || usage();
$d = &get_domain_by("dom", $domain);
$d || &usage("Virtual server $domain does not exist");
!$d->{'disabled'} && &usage("Virtual server $domain is not disabled");

# Work out what can be enabled
@enable = &get_enable_features($d);

# Go ahead and do it
print "Enabling virtual server $domain ..\n\n";
%enable = map { $_, 1 } @enable;

# Run the before command
&set_domain_envs($d, "ENABLE_DOMAIN");
$merr = &making_changes();
&reset_domain_envs($d);
&usage(&text('enable_emaking', "<tt>$merr</tt>")) if (defined($merr));

# Enable all disabled features
my $f;
foreach $f (@features) {
	if ($d->{$f} && $enable{$f}) {
		local $efunc = "enable_$f";
		&try_function($f, $efunc, $d);
		}
	}
foreach $f (@feature_plugins) {
	if ($d->{$f} && $enable{$f}) {
		&plugin_call($f, "feature_enable", $d);
		}
	}

# Save new domain details
&$first_print($text{'save_domain'});
delete($d->{'disabled'});
delete($d->{'disabled_reason'});
delete($d->{'disabled_why'});
&save_domain($d);
&$second_print($text{'setup_done'});

# Run the after command
&run_post_actions();
&set_domain_envs($d, "ENABLE_DOMAIN");
&made_changes();
&reset_domain_envs($d);

&virtualmin_api_log(\@OLDARGV);
print "All done!\n";

sub usage
{
print $_[0],"\n" if ($_[0]);
print "Enables all disabled features in the specified virtual server.\n";
print "\n";
print "usage: enable-domain.pl  --domain domain.name\n";
exit(1);
}


