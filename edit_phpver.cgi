#!/usr/local/bin/perl
# Save per-directory PHP versions for a server

require './virtual-server-lib.pl';
&ReadParse();
$d = &get_domain($in{'dom'});
&can_edit_domain($d) || &error($text{'edit_ecannot'});
&can_edit_phpver($d) || &error($text{'phpver_ecannot'});
@avail = &list_available_php_versions($d);
@avail > 1 || &error($text{'phpver_eavail'});

&ui_print_header(&domain_in($d), $text{'phpver_title'}, "", "phpver");
@hiddens = ( [ "dom", $in{'dom'} ] );

# Build data for existing directories
@dirs = &list_domain_php_directories($d);
$pub = &public_html_dir($d);
$i = 0;
@table = ( );
$anydelete = 0;
foreach $dir (@dirs) {
	$ispub = $dir->{'dir'} eq $pub;
	$sel = &ui_select("ver_$i", $dir->{'version'},
			  [ map { [ $_->[0] ] } @avail ]);
	push(@hiddens, [ "dir_$i", $dir->{'dir'} ]);
	if ($ispub) {
		# Can only change version for public html
		push(@table, [
			{ 'type' => 'checkbox', 'name' => 'd',
			  'value' => $dir->{'dir'}, 'disabled' => 1 },
			"<i>$text{'phpver_pub'}</i>",
			$sel
			]);
		}
	elsif (substr($dir->{'dir'}, 0, length($pub)) eq $pub) {
		# Show directory relative to public_html
		push(@table, [
			{ 'type' => 'checkbox', 'name' => 'd',
			  'value' => $dir->{'dir'} },
			"<tt>".substr($dir->{'dir'}, length($pub)+1)."</tt>",
			$sel
			]);
		$anydelete++;
		}
	else {
		# Show full path
		push(@table, [
			{ 'type' => 'checkbox', 'name' => 'd',
			  'value' => $dir->{'dir'} },
			"<tt>$dir->{'dir'}</tt>",
			$sel
			]);
		$anydelete++;
		}
	$i++;
	}

# Add row for new dir
push(@table, [ { 'type' => 'checkbox', 'name' => 'd',
		 'value' => 1, 'disabled' => 1 },
	       &ui_textbox("newdir", undef, 30),
	       &ui_select("newver", $dir->{'version'},
			  [ map { [ $_->[0] ] } @avail ]),
	     ]);

# Generate the table
print &ui_form_columns_table(
	"save_phpver.cgi",
	[ @dirs > 1 ? ( [ "delete", $text{'phpver_delete'} ], undef ) : ( ),
	  [ "save", $text{'phpver_save'} ] ],
	$anydelete,
	undef,
	\@hiddens,
	[ "", $text{'phpver_dir'}, $text{'phpver_ver'} ],
	undef,
	\@table,
	undef,
	1);

&ui_print_footer(&domain_footer_link($d),
		 "", $text{'index_return'});


