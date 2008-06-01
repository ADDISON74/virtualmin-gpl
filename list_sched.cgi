#!/usr/local/bin/perl
# Show a list of all scheduled backups

require './virtual-server-lib.pl';
&ReadParse();
&can_backup_sched() || &error($text{'sched_ecannot'});
&can_backup_domain() || &error($text{'backup_ecannot'});
&ui_print_header(undef, $text{'sched_title'}, "", "sched");

@scheds = &list_scheduled_backups();
@scheds = grep { &can_backup_sched($_) } @scheds;

# Work out what to show
$hasinc = &has_incremental_tar();
@table = ( );
$hasowner = 0;
if (&can_backup_domain() == 1) {
	# For master admin, show it if any schedule has a non-master owner
	($hasowner) = grep { $_->{'owner'} } @scheds;
	}
elsif (&can_backup_domain() == 3) {
	# For resellers, always show owner column
	$hasowner = 1;
	}

# Build table of backups
foreach $s (@scheds) {
	my @row;
	push(@row, { 'type' => 'checkbox', 'name' => 'd',
	     'value' => $s->{'id'}, 'disabled' => $s->{'id'}==1 });
	push(@row, "<a href='backup_form.cgi?sched=$s->{'id'}'>".
		   &nice_backup_url($s->{'dest'}, 1)."</a>");
	if ($s->{'all'} == 1) {
		push(@row, "<i>$text{'sched_all'}</i>");
		}
	elsif ($s->{'doms'}) {
		local @dnames;
		foreach my $did (split(/\s+/, $s->{'doms'})) {
			local $d = &get_domain($did);
			push(@dnames, &show_domain_name($d)) if ($d);
			}
		local $msg = @dnames > 4 ? join(", ", @dnames).", ..."
					 : join(", ", @dnames);
		push(@row, $s->{'all'} == 2 ? &text('sched_except', $msg)
					    : $msg);
		}
	elsif ($s->{'virtualmin'}) {
		push(@row, $text{'sched_virtualmin'});
		}
	else {
		push(@row, $text{'sched_nothing'});
		}
	push(@row, $s->{'enabled'} ?
		&text('sched_yes', &cron::when_text($s)) :
		$text{'no'});
	# Incremental level
	if ($hasinc) {
		push(@row, $s->{'increment'} ? $text{'sched_inc'}
					     : $text{'sched_full'});
		}
	# Creator of the backup
	if ($hasowner) {
		if ($s->{'owner'}) {
			$od = &get_domain($s->{'owner'});
			push(@row, $od ? $od->{'user'} : $s->{'owner'});
			}
		else {
			push(@row, "");
			}
		}
	# Action links
	@links = ( );
	push(@links, "<a href='backup_form.cgi?oneoff=$s->{'id'}'>".
		     "$text{'sched_now'}</a>");
	push(@links, "<a href='restore_form.cgi?sched=$s->{'id'}'>".
		     "$text{'sched_restore'}</a>") if (&can_restore_domain());

	push(@row, &ui_links_row(\@links));
	push(@table, \@row);
	}

# Output the form and table
print &ui_form_columns_table(
	"delete_scheds.cgi",
	[ [ undef, $text{'sched_delete'} ] ],
	1,
	[ [ "backup_form.cgi?new=1", $text{'sched_add'} ] ],
	undef,
	[ "", $text{'sched_dest'}, $text{'sched_doms'},
	  $text{'sched_enabled'},
	  $hasinc ? ( $text{'sched_level'} ) : ( ),
	  $hasowner ? ( $text{'sched_owner'} ) : ( ),
	  $text{'sched_actions'} ],
	100, \@table, [ '', 'string', 'string' ],
	0, undef,
	$text{'sched_none'});

&ui_print_footer("", $text{'index_return'});

