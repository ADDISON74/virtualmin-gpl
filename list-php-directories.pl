#!/usr/local/bin/perl
# List all directories in which a specific version of PHP has been activated

package virtual_server;
if (!$module_name) {
	$main::no_acl_check++;
	$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
	$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
	if ($0 =~ /^(.*\/)[^\/]+$/) {
		chdir($1);
		}
	chop($pwd = `pwd`);
	$0 = "$pwd/list-users.pl";
	require './virtual-server-lib.pl';
	$< == 0 || die "list-php-directories.pl must be run as root";
	}

# Parse command-line args
$owner = 1;
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		$domain = shift(@ARGV);
		}
	elsif ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	else {
		&usage();
		}
	}

$domain || &usage();
$d = &get_domain_by("dom", $domain);
$d || usage("Virtual server $domain does not exist");
@dirs = &list_domain_php_directories($d);

if ($multi) {
	# Show on separate lines
	foreach $dir (@dirs) {
		print $dir->{'dir'},"\n";
		print "  PHP version: $dir->{'version'}\n";
		print "  Execution mode: $dir->{'mode'}\n";
		print "  Web root directory: ",
		    ($dir->{'dir'} eq &public_html_dir($d) ? "Yes" : "No"),"\n";
		}
	}
elsif ($nameonly) {
	# Just directories
	foreach $dir (@dirs) {
                print $dir->{'dir'},"\n";
		}
	}
else {
	# Show in table
	$fmt = "%-70.70s %-7.7s\n";
	printf $fmt, "Directory", "Version";
	printf $fmt, ("-" x 70), ("-" x 7);
	foreach $dir (@dirs) {
		printf $fmt, $dir->{'dir'}, $dir->{'version'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists web directories with different PHP versions in a virtual server.\n";
print "\n";
print "usage: list-php-directories.pl   --domain domain.name\n";
print "                                 [--multiline | --name-only]\n";
exit(1);
}

