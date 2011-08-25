# Functions for talking to an FTP server

# ftp_upload(host, file, srcfile, [&error], [&callback], [user, pass], [port],
# 	     [attempts])
# Download data from a local file to an FTP site
sub ftp_upload
{
local($buf, @n);
local $cbfunc = $_[4];
local $tries = $_[8] || 1;
local $ok = 0;

for(my $i=0; $i<$tries; $i++) {
	$main::download_timed_out = undef;
	local $SIG{ALRM} = \&download_timeout;
	alarm(60);
	if ($_[3]) { ${$_[3]} = undef; }
	if ($i > 0) { sleep(10); }	# Delay before next try

	# connect to host and login
	&open_socket($_[0], $_[7] || 21, "SOCK", $_[3]) || next;
	alarm(0);
	if ($main::download_timed_out) {
		if ($_[3]) { ${$_[3]} = $main::download_timed_out; next; }
		else { &error($main::download_timed_out); }
		}
	&ftp_command("", 2, $_[3]) || return 0;
	if ($_[5]) {
		# Login as supplied user
		local @urv = &ftp_command("USER $_[5]", [ 2, 3 ], $_[3]);
		@urv || return 0;
		if (int($urv[1]/100) == 3) {
			&ftp_command("PASS $_[6]", 2, $_[3]) || next;
			}
		}
	else {
		# Login as anonymous
		local @urv = &ftp_command("USER anonymous", [ 2, 3 ], $_[3]);
		@urv || return 0;
		if (int($urv[1]/100) == 3) {
			&ftp_command("PASS root\@".&get_system_hostname(), 2,
				     $_[3]) || next;
			}
		}
	&$cbfunc(1, 0) if ($cbfunc);

	# Switch to binary mode
	&ftp_command("TYPE I", 2, $_[3]) || next;

	# get the file size and tell the callback
	local @st = stat($_[2]);
	if ($cbfunc) {
		&$cbfunc(2, $st[7]);
		}

	# send the file
	local $pasv = &ftp_command("PASV", 2, $_[3]);
	defined($pasv) || return 0;
	$pasv =~ /\(([0-9,]+)\)/;
	@n = split(/,/ , $1);
	&open_socket("$n[0].$n[1].$n[2].$n[3]", $n[4]*256 + $n[5], "CON", $_[3]) || next;
	&ftp_command("STOR $_[1]", 1, $_[3]) || next;

	# transfer data
	local $got;
	open(PFILE, $_[2]);
	while(read(PFILE, $buf, 1024) > 0) {
		local $ok = print CON $buf;
		if ($ok <= 0) {
			# Write failed!
			local $msg = "FTP write failed : $!";
			if ($_[3]) { ${$_[3]} = $msg; next; }
			else { &error($got); }
			}
		$got += length($buf);
		&$cbfunc(3, $got) if ($cbfunc);
		}
	close(PFILE);
	close(CON);
	if ($got != $st[7]) {
		local $msg = "Upload incomplete - file size is $st[7], but sent $got";
		if ($_[3]) { ${$_[3]} = $msg; next; }
		else { &error($msg); }
		}
	&$cbfunc(4) if ($cbfunc);

	# finish off..
	&ftp_command("", 2, $_[3]) || next;
	&ftp_command("QUIT", 2, $_[3]) || next;
	close(SOCK);
	$ok = 1;
	last;
	}
return $ok;
}

# ftp_onecommand(host, command, [&error], [user, pass], [port])
# Executes one command on an FTP server, after logging in, and returns its
# exit status.
sub ftp_onecommand
{
local($buf, @n);

$main::download_timed_out = undef;
local $SIG{ALRM} = \&download_timeout;
alarm(60);

# connect to host and login
&open_socket($_[0], $_[5] || 21, "SOCK", $_[2]) || return 0;
alarm(0);
if ($main::download_timed_out) {
	if ($_[2]) { ${$_[2]} = $main::download_timed_out; return 0; }
	else { &error($main::download_timed_out); }
	}
&ftp_command("", 2, $_[2]) || return 0;
if ($_[3]) {
	# Login as supplied user
	local @urv = &ftp_command("USER $_[3]", [ 2, 3 ], $_[2]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS $_[4]", 2, $_[2]) || return 0;
		}
	}
else {
	# Login as anonymous
	local @urv = &ftp_command("USER anonymous", [ 2, 3 ], $_[2]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS root\@".&get_system_hostname(), 2,
			     $_[2]) || return 0;
		}
	}

# Run the command
local @rv = &ftp_command($_[1], 2, $_[2]);
@rv || return 0;

# finish off..
&ftp_command("QUIT", 2, $_[3]) || return 0;
close(SOCK);

return $rv[1];
}

# ftp_listdir(host, dir, [&error], [user, pass], [port], [longmode])
# Returns a reference to a list of filenames in a directory, or if longmode
# is set returns full file details in stat format (with the 13th index being
# the filename)
sub ftp_listdir
{
local($buf, @n);

$main::download_timed_out = undef;
local $SIG{ALRM} = \&download_timeout;
alarm(60);

# connect to host and login
&open_socket($_[0], $_[5] || 21, "SOCK", $_[2]) || return 0;
alarm(0);
if ($main::download_timed_out) {
	if ($_[2]) { ${$_[2]} = $main::download_timed_out; return 0; }
	else { &error($main::download_timed_out); }
	}
&ftp_command("", 2, $_[2]) || return 0;
if ($_[3]) {
	# Login as supplied user
	local @urv = &ftp_command("USER $_[3]", [ 2, 3 ], $_[2]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS $_[4]", 2, $_[2]) || return 0;
		}
	}
else {
	# Login as anonymous
	local @urv = &ftp_command("USER anonymous", [ 2, 3 ], $_[2]);
	@urv || return 0;
	if (int($urv[1]/100) == 3) {
		&ftp_command("PASS root\@".&get_system_hostname(), 2,
			     $_[2]) || return 0;
		}
	}

# request the listing
local $pasv = &ftp_command("PASV", 2, $_[2]);
defined($pasv) || return 0;
$pasv =~ /\(([0-9,]+)\)/;
@n = split(/,/ , $1);
&open_socket("$n[0].$n[1].$n[2].$n[3]", $n[4]*256 + $n[5], "CON", $_[2]) || return 0;

local @list;
local $_;
if ($_[6]) {
	# Ask for full listing
	&ftp_command("LIST $_[1]/", 1, $_[2]) || return 0;
	while(<CON>) {
		s/\r|\n//g;
		local @st = &parse_lsl_line($_);
		push(@list, \@st) if (scalar(@st));
		}
	close(CON);
	}
else {
	# Just filenames
	&ftp_command("NLST $_[1]/", 1, $_[2]) || return 0;
	while(<CON>) {
		s/\r|\n//g;
		push(@list, $_);
		}
	close(CON);
	}

# finish off..
&ftp_command("", 2, $_[3]) || return 0;
&ftp_command("QUIT", 2, $_[3]) || return 0;
close(SOCK);

return \@list;
}

# parse_lsl_line(text)
# Given a line from ls -l output, parse it into a stat() format array. Not all
# fields are set, as not all are available. Returns an empty array if the line
# doesn't look like ls -l output.
sub parse_lsl_line
{
local @w = split(/\s+/, $_[0]);
local @now = localtime(time());
local @st;
return ( ) if ($w[0] !~ /^[rwxdst\-]{10}\+?$/);
$st[3] = $w[1];			# Links
$st[4] = $w[2];			# UID
$st[5] = $w[3];			# GID
$st[7] = $w[4];			# Size
if ($w[7] =~ /^(\d+):(\d+)$/) {
	# Time is month day hour:minute
	local @tm = ( 0, $2, $1, $w[6], &month_to_number($w[5]), $now[5] );
	return ( ) if ($tm[4] eq '' || $tm[3] < 1 || $tm[3] > 31);
	local $ut = timelocal(@tm);
	if ($ut > time()+(24*60*60)) {
		# Must have been last year!
		$tm[5]--;
		$ut = timelocal(@tm);
		}
	$st[8] = $st[9] = $st[10] = $ut;
	$st[13] = join(" ", @w[8..$#w]);
	}
elsif ($w[5] =~ /^(\d{4})\-(\d+)\-(\d+)$/) {
	# Time is year-month-day hour:minute
	local @tm = ( 0, 0, 0, $3, $2-1, $1-1900 );
	if ($w[6] =~ /^(\d+):(\d+)$/) {
		$tm[1] = $2;
		$tm[2] = $1;
		$st[8] = $st[9] = $st[10] = timelocal(@tm);
		}
	else {
		return ( );
		}
	$st[13] = join(" ", @w[7..$#w]);
	}
elsif ($w[7] =~ /^\d+$/ && $w[7] > 1000 && $w[7] < 10000) {
	# Time is month day year
	local @tm = ( 0, 0, 0, $w[6],
		      &month_to_number($w[5]), $w[7]-1900 );
	return ( ) if ($tm[4] eq '' || $tm[3] < 1 || $tm[3] > 31);
	$st[8] = $st[9] = $st[10] = timelocal(@tm);
	$st[13] = join(" ", @w[8..$#w]);
	}
else {
	# Unknown format??
	return ( );
	}
$st[2] = 0;			# Permissions
$w[0] =~ s/\+$//;		# Remove trailing +
local @p = reverse(split(//, $w[0]));
for(my $i=0; $i<9; $i++) {
	if ($p[$i] ne '-') {
		$st[2] += (1<<$i);
		}
	}
return @st;
}

# ftp_deletefile(host, file, &error, [user, pass], [port])
# Delete some file or directory from an FTP server. This is done recursively
# if needed. Returns the size of any deleted sub-directories.
sub ftp_deletefile
{
local ($host, $file, $err, $user, $pass, $port) = @_;
local $sz = 0;

# Check if we can chdir to it
local $cwderr;
local $isdir = &ftp_onecommand($host, "CWD $file", \$cwderr,
			       $user, $pass, $port);
if ($isdir) {
	# Yes .. so delete recursively first
	local $files = &ftp_listdir($host, $file, $err, $user, $pass, $port, 1);
	$files = [ grep { $_->[13] ne "." && $_->[13] ne ".." } @$files ];
	if (!$err || !$$err) {
		foreach my $f (@$files) {
			$sz += $f->[7];
			$sz += &ftp_deletefile($host, "$file/$f->[13]", $err,
					       $user, $pass, $port);
			last if ($err && $$err);
			}
		&ftp_onecommand($host, "RMD $file", $err, $user, $pass, $port);
		}
	}
else {
	# Just delete the file
	&ftp_onecommand($host, "DELE $file", $err, $user, $pass, $port);
	}
return $sz;
}

1;

