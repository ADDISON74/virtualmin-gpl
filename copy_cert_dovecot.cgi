#!/usr/local/bin/perl
# Copy this domain's cert to Dovecot

require './virtual-server-lib.pl';
&ReadParse();
$d = &get_domain($in{'dom'});
&can_edit_domain($d) && &can_edit_ssl() && &can_webmin_cert() ||
	&error($text{'copycert_ecannot'});
$d->{'ssl_pass'} && &error($text{'copycert_epass'});

&ui_print_header(&domain_in($d), $text{'copycert_title'}, "");

# Get the Dovecot config and cert files
&foreign_require("dovecot");
&lock_file($dovecot::config{'dovecot_config'});
$conf = &dovecot::get_config();
$cfile = &dovecot::find_value("ssl_cert_file", $conf, 2);
$kfile = &dovecot::find_value("ssl_key_file", $conf, 2);
$cfile ||= "/etc/dovecot.cert.pem";
$kfile ||= "/etc/dovecot.key.pem";

# Copy cert into those files
&$first_print($text{'copycert_dsaving'});
$cdata = &cert_pem_data($d);
$kdata = &cert_key_data($d);
$cdata || &error($text{'copycert_ecert'});
$kdata || &error($text{'copycert_ekey'});
&open_lock_tempfile(CERT, ">$cfile");
&print_tempfile(CERT, $cdata,"\n");
&close_tempfile(CERT);
&open_lock_tempfile(KEY, ">$kfile");
&print_tempfile(KEY, $kdata,"\n");
&close_tempfile(KEY);
&set_ownership_permissions(undef, undef, 0700, $cfile);
&set_ownership_permissions(undef, undef, 0700, $kfile);

# Update config with correct files
&dovecot::save_directive($conf, "ssl_cert_file", $cfile);
&dovecot::save_directive($conf, "ssl_key_file", $kfile);
&$second_print(&text('copycert_dsaved', "<tt>$cfile</tt>", "<tt>$kfile</tt>"));

# Make sure SSL is enabled
&$first_print($text{'copycert_denabling'});
&dovecot::save_directive($conf, "ssl_disable", "no");
$protos = &dovecot::find_value("protocols", $conf);
@protos = split(/\s+/, $protos);
%protos = map { $_, 1 } @protos;
push(@protos, "imaps") if (!$protos{'imaps'} && $protos{'imap'});
push(@protos, "pop3s") if (!$protos{'pop3s'} && $protos{'pop3'});
&dovecot::save_directive($conf, "protocols", join(" ", @protos));
&flush_file_lines();
&unlock_file($dovecot::config{'dovecot_config'});
&$second_print($text{'setup_done'});

# Apply Dovecot config
&dovecot::apply_configuration();

&webmin_log("copycert", "dovecot");

&ui_print_footer(&domain_footer_link($d),
		 "", $text{'index_return'});

