#!/usr/local/bin/perl
# Save CA certificate

require './virtual-server-lib.pl';
&ReadParseMime();
&error_setup($text{'chain_err'});
$d = &get_domain($in{'dom'});
&can_edit_domain($d) && &can_edit_ssl() || &error($text{'edit_ecannot'});

# Validate and store inputs
$oldchain = &get_chained_certificate_file($d);
if ($in{'mode'} == 0) {
	# No file
	$chain = undef;
	}
elsif ($in{'mode'} == 1) {
	# File on server
	if (&can_chained_cert_path()) {
		# Use new path, which must exist
		-r $in{'file'} || &error($text{'chain_efile'});
		$data = &read_file_contents($in{'file'});
		$err = &check_certificate_data($data);
		$err && &error(&text('chain_ecert', $err));
		$chain = $in{'file'};
		}
	else {
		# Stick with current
		$oldchain || &error($text{'chain_emode1'});
		$chain = $oldchain;
		}
	}
elsif ($in{'mode'} == 2) {
	# New uploaded file
	$in{'upload'} || &error($text{'chain_eupload'});
	$err = &check_certificate_data($in{'upload'});
	$err && &error(&text('chain_ecert', $err));
	$chain = &default_certificate_file($d, 'ca');
	&lock_file($chain);
	&unlink_file_as_domain_user($d, $chain);
	&open_tempfile_as_domain_user($d, CERT, ">$chain");
	&print_tempfile(CERT, $in{'upload'});
	&close_tempfile_as_domain_user($d, CERT);
	&set_permissions_as_domain_user($d, 0755, $chain);
	&unlock_file($chain);
	}
elsif ($in{'mode'} == 3) {
	# New pasted text
	$in{'paste'} =~ s/\r//g;
	$in{'paste'} || &error($text{'chain_epaste'});
	$err = &check_certificate_data($in{'paste'});
	$err && &error(&text('chain_ecert', $err));
	$chain = &default_certificate_file($d, 'ca');
	&lock_file($chain);
	&unlink_file_as_domain_user($d, $chain);
	&open_tempfile_as_domain_user($d, CERT, ">$chain");
	&print_tempfile(CERT, $in{'paste'});
	&close_tempfile_as_domain_user($d, CERT);
	&set_permissions_as_domain_user($d, 0755, $chain);
	&unlock_file($chain);
	}

# Apply it, including domains that share a cert
&set_all_null_print();
&save_chained_certificate_file($d, $chain);
$d->{'ssl_chain'} = $chain;
&save_domain($d);
foreach $od (&get_domain_by("ssl_same", $d->{'id'})) {
	$od->{'ssl_chain'} = $chain;
	&save_chained_certificate_file($od, $chain);
	&save_domain($od);
	}

&run_post_actions();
&domain_redirect($d);

