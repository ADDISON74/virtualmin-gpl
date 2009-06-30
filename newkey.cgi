#!/usr/local/bin/perl
# newkey.cgi
# Install a new SSL cert and key

require './virtual-server-lib.pl';
&ReadParseMime();
$d = &get_domain($in{'dom'});
&can_edit_domain($d) && &can_edit_ssl() || &error($text{'edit_ecannot'});

# Validate inputs
&error_setup($text{'newkey_err'});
$cert = $in{'cert'} || $in{'certupload'};
$newkey = $in{'newkey'} || $in{'newkeyupload'};
$cert =~ s/\r//g;
$newkey =~ s/\r//g;
$err = &validate_cert_format($cert, "cert");
$err && &error(&text('newkey_ecert2', $err));
$err = &validate_cert_format($newkey, "key");
$err && &error(&text('newkey_enewkey2', $err));

# Check if a passphrase is needed
$passok = &check_passphrase($newkey, $in{'pass_def'} ? undef : $in{'pass'});
$passok || &error($text{'newkey_epass'});

# Check that the cert and key match
$certerr = &check_cert_key_match($cert, $newkey);
$certerr && &error(&text('newkey_ematch', $certerr));

&ui_print_header(&domain_in($d), $text{'newkey_title'}, "");

# Make sure Apache is setup to use the right key files
&obtain_lock_ssl($d);
&require_apache();
$conf = &apache::get_config();
($virt, $vconf) = &get_apache_virtual($d->{'dom'},
                                      $d->{'web_sslport'});

$d->{'ssl_cert'} ||= &default_certificate_file($d, 'cert');
$d->{'ssl_key'} ||= &default_certificate_file($d, 'key');
&apache::save_directive("SSLCertificateFile", [ $d->{'ssl_cert'} ],
			$vconf, $conf);
&apache::save_directive("SSLCertificateKeyFile", [ $d->{'ssl_key'} ],
			$vconf, $conf);
&flush_file_lines($virt->{'file'});
&release_lock_ssl($d);
&register_post_action(\&restart_apache, 1);

# If a passphrase is needed, add it to the top-level Apache config. This is
# done by creating a small script that outputs the passphrase
$d->{'ssl_pass'} = $passok == 2 ? $in{'pass'} : undef;
&save_domain_passphrase($d);

# Save the cert and private keys
&$first_print($text{'newkey_saving'});
&lock_file($d->{'ssl_cert'});
&unlink_file($d->{'ssl_cert'});
&open_tempfile_as_domain_user($d, CERT, ">$d->{'ssl_cert'}");
&print_tempfile(CERT, $cert);
&close_tempfile_as_domain_user($d, CERT);
&set_certificate_permissions($d, $d->{'ssl_cert'});
&unlock_file($d->{'ssl_cert'});

&lock_file($d->{'ssl_key'});
&unlink_file($d->{'ssl_key'});
&open_tempfile_as_domain_user($d, CERT, ">$d->{'ssl_key'}");
&print_tempfile(CERT, $newkey);
&close_tempfile_as_domain_user($d, CERT);
&set_certificate_permissions($d, $d->{'ssl_key'});
&unlock_file($d->{'ssl_key'});
&$second_print($text{'setup_done'});

# Remove the new private key we just installed
if ($d->{'ssl_newkey'}) {
	$newkeyfile = &read_file_contents($d->{'ssl_newkey'});
	if ($newkeyfile eq $newkey) {
		&unlink_logged($d->{'ssl_newkey'});
		delete($d->{'ssl_newkey'});
		delete($d->{'ssl_csr'});
		&save_domain($d);
		}
	}

# Copy SSL directives to domains using same cert
foreach $od (&get_domain_by("ssl_same", $d->{'id'})) {
	$od->{'ssl_cert'} = $d->{'ssl_cert'};
	$od->{'ssl_key'} = $d->{'ssl_key'};
	$od->{'ssl_newkey'} = $d->{'ssl_newkey'};
	$od->{'ssl_csr'} = $d->{'ssl_csr'};
	$od->{'ssl_pass'} = $d->{'ssl_pass'};
	&save_domain_passphrase($od);
	}

# Re-start Apache
&run_post_actions();
&webmin_log("newkey", "domain", $d->{'dom'}, $d);

&ui_print_footer("cert_form.cgi?dom=$in{'dom'}", $text{'cert_return'},
	 	 &domain_footer_link($d),
		 "", $text{'index_return'});

