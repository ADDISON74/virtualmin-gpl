
@roundcube_tables = ( 'cache', 'contacts', 'identities', 'session',
		      'users', 'messages' );

# script_roundcube_desc()
sub script_roundcube_desc
{
return "RoundCube";
}

sub script_roundcube_uses
{
return ( "php" );
}

sub script_roundcube_longdesc
{
return "RoundCube Webmail is a browser-based multilingual IMAP client with an application-like user interface.";
}

# script_roundcube_versions()
sub script_roundcube_versions
{
return ( "0.2-stable" );
}

sub script_roundcube_category
{
return "Email";
}

sub script_roundcube_php_modules
{
return ("mysql");
}

sub script_roundcube_dbs
{
return ("mysql");
}

sub script_roundcube_php_vers
{
return ( 4, 5 );
}

# script_roundcube_params(&domain, version, &upgrade-info)
# Returns HTML for table rows for options for installing PHP-NUKE
sub script_roundcube_params
{
local ($d, $ver, $upgrade) = @_;
local $rv;
local $hdir = &public_html_dir($d, 1);
if ($upgrade) {
	# Options are fixed when upgrading
	local ($dbtype, $dbname) = split(/_/, $upgrade->{'opts'}->{'db'}, 2);
	$rv .= &ui_table_row("Database for RoundCube preferences", $dbname);
	local $dir = $upgrade->{'opts'}->{'dir'};
	$dir =~ s/^$d->{'home'}\///;
	$rv .= &ui_table_row("Install directory", $dir);
	}
else {
	# Show editable install options
	local @dbs = &domain_databases($d, [ "mysql" ]);
	$rv .= &ui_table_row("Database for RoundCube preferences",
		     &ui_database_select("db", undef, \@dbs, $d, "roundcube"));
	$rv .= &ui_table_row("Install sub-directory under <tt>$hdir</tt>",
			     &ui_opt_textbox("dir", "roundcube", 30,
					     "At top level"));
	}
return $rv;
}

# script_roundcube_parse(&domain, version, &in, &upgrade-info)
# Returns either a hash ref of parsed options, or an error string
sub script_roundcube_parse
{
local ($d, $ver, $in, $upgrade) = @_;
if ($upgrade) {
	# Options are always the same
	return $upgrade->{'opts'};
	}
else {
	local $hdir = &public_html_dir($d, 0);
	$in{'dir_def'} || $in{'dir'} =~ /\S/ && $in{'dir'} !~ /\.\./ ||
		return "Missing or invalid installation directory";
	local $dir = $in{'dir_def'} ? $hdir : "$hdir/$in{'dir'}";
	local ($newdb) = ($in->{'db'} =~ s/^\*//);
	return { 'db' => $in->{'db'},
		 'newdb' => $newdb,
		 'dir' => $dir,
		 'path' => $in{'dir_def'} ? "/" : "/$in{'dir'}", };
	}
}

# script_roundcube_check(&domain, version, &opts, &upgrade-info)
# Returns an error message if a required option is missing or invalid
sub script_roundcube_check
{
local ($d, $ver, $opts, $upgrade) = @_;
$opts->{'dir'} =~ /^\// || return "Missing or invalid install directory";
if (-r "$opts->{'dir'}/config/db.inc.php") {
	return "RoundCube appears to be already installed in the selected directory";
	}
local ($dbtype, $dbname) = split(/_/, $opts->{'db'}, 2);
local $clash = &find_database_table($dbtype, $dbname,
				    join("|", @roundcube_tables));
$clash && return "RoundCube appears to be already using the selected database (table $clash)";
return undef;
}

# script_roundcube_files(&domain, version, &opts, &upgrade-info)
# Returns a list of files needed by RoundCube, each of which is a hash ref
# containing a name, filename and URL
sub script_roundcube_files
{
local ($d, $ver, $opts, $upgrade) = @_;
local @files = ( { 'name' => "source",
	           'file' => "roundcube-$ver.tar.gz",
	           'url' => "http://easynews.dl.sourceforge.net/sourceforge/roundcubemail/roundcubemail-$ver.tar.gz" },
	    );
return @files;
}

sub script_roundcube_commands
{
return ("tar", "gunzip");
}

# script_roundcube_install(&domain, version, &opts, &files, &upgrade-info)
# Actually installs RoundCube, and returns either 1 and an informational
# message, or 0 and an error
sub script_roundcube_install
{
local ($d, $version, $opts, $files, $upgrade) = @_;
local ($out, $ex);

# Create and get DB
if ($opts->{'newdb'} && !$upgrade) {
	local $err = &create_script_database($d, $opts->{'db'});
	return (0, "Database creation failed : $err") if ($err);
	}
local ($dbtype, $dbname) = split(/_/, $opts->{'db'}, 2);
local $dbuser = $dbtype eq "mysql" ? &mysql_user($d) : &postgres_user($d);
local $dbpass = $dbtype eq "mysql" ? &mysql_pass($d) : &postgres_pass($d, 1);
local $dbphptype = $dbtype eq "mysql" ? "mysql" : "psql";
local $dbhost = &get_database_host($dbtype);
local $dberr = &check_script_db_connection($dbtype, $dbname, $dbuser, $dbpass);
return (0, "Database connection failed : $dberr") if ($dberr);

# Extract tar file to temp dir and copy to target
local $temp = &transname();
local $err = &extract_script_archive($files->{'source'}, $temp, $d,
                                     $opts->{'dir'}, "roundcubemail-$ver");
$err && return (0, "Failed to extract source : $err");

if (!$upgrade) {
	# Fix up the DB config file
	local $dbcfileorig = "$opts->{'dir'}/config/db.inc.php.dist";
	local $dbcfile = "$opts->{'dir'}/config/db.inc.php";
	&copy_source_dest($dbcfileorig, $dbcfile);
	local $lref = &read_file_lines($dbcfile);
	foreach my $l (@$lref) {
		if ($l =~ /^\$rcmail_config\['db_dsnw'\]\s+=/) {
			$l = "\$rcmail_config['db_dsnw'] = 'mysql://$dbuser:$dbpass\@$dbhost/$dbname';";
			}
		elsif ($l =~ /^\$rcmail_config\['db_backend'\]\s+=/) {
			$l = "\$rcmail_config['db_backend'] = 'db';";
			}
		}
	&flush_file_lines($dbcfile);

	# Fix up the main config file
	local $mcfileorig = "$opts->{'dir'}/config/main.inc.php.dist";
	local $mcfile = "$opts->{'dir'}/config/main.inc.php";
	&copy_source_dest($mcfileorig, $mcfile);
	local $lref = &read_file_lines($mcfile);
	local $vuf = &get_mail_virtusertable();
	foreach my $l (@$lref) {
		if ($l =~ /^\$rcmail_config\['enable_caching'\]\s+=/) {
			$l = "\$rcmail_config['enable_caching'] = FALSE;";
			}
		if ($l =~ /^\$rcmail_config\['default_host'\]\s+=/) {
			$l = "\$rcmail_config['default_host'] = 'localhost';";
			}
		if ($l =~ /^\$rcmail_config\['default_port'\]\s+=/) {
			$l = "\$rcmail_config['default_port'] = 143;";
			}
		if ($l =~ /^\$rcmail_config\['smtp_server'\]\s+=/) {
			$l = "\$rcmail_config['smtp_server'] = 'localhost';";
			}
		if ($l =~ /^\$rcmail_config\['smtp_port'\]\s+=/) {
			$l = "\$rcmail_config['smtp_port'] = 25;";
			}
		if ($l =~ /^\$rcmail_config\['smtp_user'\]\s+=/) {
			$l = "\$rcmail_config['smtp_user'] = '%u';";
			}
		if ($l =~ /^\$rcmail_config\['smtp_pass'\]\s+=/) {
			$l = "\$rcmail_config['smtp_pass'] = '%p';";
			}
		if ($l =~ /^\$rcmail_config\['mail_domain'\]\s+=/) {
			$l = "\$rcmail_config['mail_domain'] = '$d->{'dom'}';";
			}
		if ($l =~ /^\$rcmail_config\['virtuser_file'\]\s+=/ && $vuf) {
			$l = "\$rcmail_config['virtuser_file'] = '$vuf';";
			}
		}
	&flush_file_lines($mcfile);

	# Run SQL setup script
	&require_mysql();
	local $sqlfile;
	if ($mysql::mysql_version >= 5 && $ver < 0.2) {
		$sqlfile = "$opts->{'dir'}/SQL/mysql5.initial.sql";
		}
	else {
		$sqlfile = "$opts->{'dir'}/SQL/mysql.initial.sql";
		}
	local ($ex, $out) = &mysql::execute_sql_file($dbname, $sqlfile,
					       	     $dbuser, $dbpass);
	$ex && return (-1, "Failed to run database setup script : <tt>$out</tt>.");
	}

# Return a URL for the user
local $url = &script_path_url($d, $opts);
local $rp = $opts->{'dir'};
$rp =~ s/^$d->{'home'}\///;
return (1, "RoundCube installation complete. It can be accessed at <a target=_new href='$url'>$url</a>.", "Under $rp using $dbphptype database $dbname", $url);
}

# script_roundcube_uninstall(&domain, version, &opts)
# Un-installs a RoundCube installation, by deleting the directory and database.
# Returns 1 on success and a message, or 0 on failure and an error
sub script_roundcube_uninstall
{
local ($d, $version, $opts) = @_;

# Remove roundcube tables from the database
local ($dbtype, $dbname) = split(/_/, $opts->{'db'}, 2);
&require_mysql();
foreach my $t (&mysql::list_tables($dbname)) {
	if (&indexof($t, @roundcube_tables) >= 0) {
		&mysql::execute_sql_logged($dbname, "drop table $t");
		}
	}

# Remove the contents of the target directory
local $derr = &delete_script_install_directory($d, $opts);
return (0, $derr) if ($derr);

# Take out the DB
if ($opts->{'newdb'}) {
	&delete_script_database($d, $opts->{'db'});
	}

return (1, $dbname ? "RoundCube directory and tables deleted."
		   : "RoundCube directory deleted.");
}

# script_roundcube_check_latest(version)
# Checks if some version is the latest for this project, and if not returns
# a newer one. Otherwise returns undef.
sub script_roundcube_check_latest
{
local ($ver) = @_;
local @vers = &osdn_package_versions("roundcubemail", "roundcubemail-([a-z0-9\\.\\-]+)\\.tar\\.gz");
@vers = grep { !/beta/ && !/-dep$/ && !/alpha/ } @vers;
return "Failed to find versions" if (!@vers);
return $ver eq $vers[0] ? undef : $vers[0];
}

sub script_roundcube_site
{
return 'http://www.roundcube.net/';
}

1;

