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
	&unlink_file($chain);
	&open_tempfile(CERT, ">$chain");
	&print_tempfile(CERT, $in{'upload'});
	&close_tempfile(CERT);
	&set_ownership_permissions($d->{'uid'}, $d->{'ugid'}, 0755, $chain);
	&unlock_file($chain);
	}

# Apply it
&set_all_null_print();
&save_chained_certificate_file($d, $chain);
&run_post_actions();
&domain_redirect($d);

