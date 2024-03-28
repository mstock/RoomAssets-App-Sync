package RoomAssets::App::Command::sync;

# ABSTRACT: Synchronize room assets from Pretalx to Nextcloud

use 5.010001;
use strict;
use warnings;

use Carp;
use Moose;
use MooseX::Types::Path::Class;

extends qw(RoomAssets::App::Command);

no warnings qw(experimental::signatures);
use feature qw(signatures);

use LWP::UserAgent;
use JSON;
use URI;
use DateTime::Format::ISO8601;
use List::Util qw(any);
use Encode;
use File::Temp;
use IPC::System::Simple qw(systemx);
use Data::Dumper;
use File::Spec::Unix;
use Log::Any qw($log);


has 'pretalx_url' => (
	is            => 'ro',
	isa           => 'Str',
	default       => 'https://pretalx.com',
	documentation => 'Base URL of the Pretalx instance to use.',
);


has 'events' => (
	traits        => ['Getopt'],
	cmd_flag      => 'event',
	is            => 'ro',
	isa           => 'ArrayRef[Str]',
	required      => 1,
	documentation => 'Names of events to retrieve submissions from.',
);


has 'rooms' => (
	traits        => ['Getopt'],
	cmd_flag      => 'room',
	is            => 'ro',
	isa           => 'ArrayRef[Str]',
	documentation => 'Names of selected rooms to sync. If not given, all rooms '
		. 'will be synced.',
);


has 'language' => (
	traits        => ['Getopt'],
	is            => 'ro',
	isa           => 'Str',
	documentation => 'Conference language the room names are in. Required if '
		. 'more than one event language is configured in Pretalx.',
);


has 'locale' => (
	is            => 'ro',
	isa           => 'Str',
	documentation => 'Locale to use when formatting and localizing dates. '
		. 'Defaults to en-US.'
);


has 'day_strftime_pattern' => (
	is            => 'ro',
	isa           => 'Str',
	lazy          => 1,
	default       => '%Y-%m-%d_%A',
	documentation => 'Strftime pattern to use when creating the name for the '
		. 'day directory.'
);


has 'session_strftime_pattern' => (
	is            => 'ro',
	isa           => 'Str',
	lazy          => 1,
	default       => sub ($self) {
		return $self->day_strftime_pattern() . '_%H%M';
	},
	documentation => 'Strftime pattern to use in prefix when creating the name '
		. 'for the session directory.'
);


has 'target_dir' => (
	is            => 'ro',
	isa           => 'Path::Class::Dir',
	required      => 1,
	coerce        => 1,
	documentation => 'Target directory for assets and sync.',
);


has 'print_statistics' => (
	is            => 'ro',
	isa           => 'Bool',
	default       => 0,
	documentation => 'Flag to indicated if some statistics should be printed '
		. 'after the sync run',
);


has 'nextcloud_user' => (
	is            => 'ro',
	isa           => 'Str',
	documentation => 'User for Nextcloud.',
);


has 'nextcloud_password' => (
	is            => 'ro',
	isa           => 'Str',
	documentation => 'Password for Nextcloud.',
);


has 'nextcloud_folder_url' => (
	is            => 'ro',
	isa           => 'Str',
	documentation => 'URL of the folder in Nextcloud that sould be synced.'
		. ' Something like https://files.osmfoundation.org/remote.php/webdav/Room-Assets.',
);


has 'nextcloud_silent' => (
	is            => 'ro',
	isa           => 'Bool',
	documentation => 'Run Nextcloud sync with -silent flag to avoid verbose output.',
);


has '_ua' => (
	is      => 'ro',
	isa     => 'LWP::UserAgent',
	lazy    => 1,
	default => sub {
		return LWP::UserAgent->new();
	},
);


sub execute ($self, $opt, $args) {
	my $exit_code = eval {
		$self->perform_sync();
	};
	if ($@) {
		print {*STDERR} $@;
		return 128;
	}
	else {
		return $exit_code;
	}
}


sub perform_sync ($self) {
	unless (-d $self->target_dir()) {
		croak 'Target dirctory ' . $self->target_dir() . ' does not exist';
	}

	if (defined $self->nextcloud_folder_url()) {
		$self->sync_nextcloud();
	}

	my $aggregated_statuses = {};
	for my $event (@{$self->events()}) {
		$aggregated_statuses = $self->aggregate_statuses(
			$aggregated_statuses, $self->sync_event($event)
		);
	}
	$self->cleanup();

	if ($self->print_statistics()) {
		say {*STDERR} 'Sync statistics:';
		print JSON->new()->utf8()->pretty->canonical()->encode($aggregated_statuses);
	}

	if (defined $self->nextcloud_folder_url()) {
		$self->sync_nextcloud();
	}

	my @change_indicators = qw(
		new_talks_count
		new_resources_count
		updated_resources_count
		moved_talks_count
	);
	my $status = 0;
	for my $change_indicator (@change_indicators) {
		$status ||= $aggregated_statuses->{$change_indicator} > 0;
	}
	return $status;
}


sub sync_event ($self, $event) {
	my $submissions = {
		map {
			($_->{code} => $_)
		} @{ $self->fetch_submissions($event)->{results} }
	};
	my $schedule = $self->fetch_schedule($event);
	my $existing_sessions = $self->find_existing_sessions();

	my @selected_rooms = defined $self->rooms()
		? grep {
			my $room_name = $self->room_name($_);
			any { $room_name eq $_ } map { decode('UTF-8', $_) } @{ $self->rooms() }
		} @{$schedule->{rooms}}
		: @{$schedule->{rooms}};
	my %rooms = map {
		($_->{id} => $self->room_name($_))
	} @selected_rooms;
	unless (scalar keys %rooms) {
		croak 'No (matching) rooms found';
	}

	my $aggregated_statuses= {};
	TALK: for my $talk (@{ $schedule->{talks} }) {
		my $room = $rooms{$talk->{room}};
		unless (defined $room && defined $talk->{code}) {
			next TALK;
		}
		my $status = $self->sync_talk(
			$room, $submissions, $talk, $existing_sessions
		);
		$aggregated_statuses = $self->aggregate_statuses(
			$aggregated_statuses, $status
		);
	}

	return $aggregated_statuses;
}


sub sync_talk ($self, $room, $submissions, $talk, $existing_sessions) {
	my $status = {
		new_talks_count   => 0,
		moved_talks_count => 0,
	};
	my $start = DateTime::Format::ISO8601->parse_datetime($talk->{start});
	if (defined $self->locale()) {
		$start->set_locale($self->locale());
	}
	my $identifier = $self->sanitize_file_name($talk->{code});
	my $assets_target = $self->target_dir()
		->subdir($self->sanitize_file_name($room))
		->subdir(encode('UTF-8', $start->strftime($self->day_strftime_pattern())))
		->subdir(encode('UTF-8', $start->strftime($self->session_strftime_pattern()))
			. '_-_' . $self->sanitize_file_name($talk->{title})
			. '_-_' . encode('UTF-8', $identifier)
		);
	if (! -d $assets_target) {
		if (
			defined $existing_sessions->{$identifier}
				&& scalar @{ $existing_sessions->{$identifier}->{directories} } > 0
		) {
			$assets_target->parent()->mkpath();
			my $existing_directory = shift @{ $existing_sessions->{$identifier}
				->{directories} };
			rename $existing_directory, $assets_target
				or die 'Failed to rename ' . $existing_directory
					. ' to ' . $assets_target . ': ' . $!;
			$status->{moved_talks_count}++;
		}
		else {
			$assets_target->mkpath();
			$status->{new_talks_count}++;
		}
	}
	else {
		if (
			defined $existing_sessions->{$identifier}
				&& scalar @{ $existing_sessions->{$identifier}->{directories} } > 0
		) {
			$existing_sessions->{$identifier}->{directories} = [
				grep {
					$_ ne $assets_target->absolute()->resolve()
				} @{ $existing_sessions->{$identifier}->{directories} }
			];
		}
	}

	my $submission = $submissions->{$talk->{code}};
	unless (defined $submission) {
		croak 'No submission for ' . $talk->{code} . ' found'
	}

	return {
		%{ $status },
		%{ $self->update_or_create_resources($assets_target, $submission) },
	};
}


sub room_name ($self, $room) {
	my %room_names = %{ $room->{name} };
	my $room_name;
	if (defined $self->language()) {
		$room_name = $room_names{$self->language()};
		unless (defined $room_name) {
			croak 'No room name in language "' . $self->language() . '" for room '
				. $self->dump($room) . ' found';
		}
	}
	elsif (scalar keys %room_names == 1) {
		($room_name) = values %room_names;
	}
	else {
		croak 'More than one room name for room ' . $self->dump($room)
			. ' found, must pass --language parameter';
	}

	return $room_name;
}


sub dump ($self, $structure) {
	return Data::Dumper->new( [ $structure] )->Indent(0)->Sortkeys(1)
		->Quotekeys(0)->Terse(1)->Useqq(1)->Dump()
}


sub update_or_create_resources ($self, $target_dir, $submission) {
	my $status = {
		new_resources_count     => 0,
		updated_resources_count => 0,
		failed_resources_count  => 0,
	};
	ASSET: for my $asset (map { $_->{resource} } @{ $submission->{resources} }) {
		my $asset_uri = index($asset, 'http') == 0
			? URI->new($asset)
			: do {
				my $uri = URI->new($self->pretalx_url());
				$uri->path(
					File::Spec::Unix->canonpath(
						File::Spec::Unix->catfile($uri->path(), $asset)
					)
				);
				$uri;
			};
		my $filename = decode('UTF-8', ($asset_uri->path_segments())[-1]);
		if ($filename eq '') {
			$log->errorf('Failed to extract usable file name from asset URL %s',
				$asset_uri);
			$status->{failed_resources_count}++;
			next ASSET;
		}
		$filename = $self->sanitize_file_name($filename);
		my $target_file = $target_dir->file($filename);
		my $is_new = -f $target_file ? 0 : 1;

		my $result = $self->_ua()->mirror($asset_uri, $target_file);
		unless ($result->is_success() || $result->code() eq 304) {
			$log->errorf('Failed to download asset %s from submission "%s" '
				. '(code: %s): %s', $asset, encode('UTF-8', $submission->{title}),
				$submission->{code}, $result->status_line());
			$status->{failed_resources_count}++;
		}
		if ($result->is_success()) {
			$status->{$is_new ? 'new_resources_count' : 'updated_resources_count'}++;
		}
	}

	return $status;
}


sub sanitize_file_name ($self, $name) {
	# Get rid of characters the nextcloudcmd client considers invalid and that
	# might cause issues on Windows, too, or which are generally not so 'nice'
	# in file names
	$name =~ s{(?:/|\s|:|,|\?|\*|'|"|\||<|>|\(|\)|\\|!|&)+}{_}g;
	# Further cleanup to get slightly nicer names after the above replacements
	$name =~ s{^-+(?=.)}{};   # Remove leading -, avoid empty result
	$name =~ s{^-$}{_};       # Replace - with _ if that's the full name
	$name =~ s{_+}{_}g;       # Collapse multiple consecutive _
	$name =~ s{(?<=.)_+$}{};  # Remove trailing _, avoid empty result
	$name =~ s{^_+(?=.)}{};   # Remove leading _, avoid empty result
	# Prevent . and .. as filenames
	$name =~ s{^\.{1,2}$}{_};

	return encode('UTF-8', $name);
}


sub fetch_submissions ($self, $event) {
	my $uri = URI->new($self->pretalx_url);
	$uri->path_segments($uri->path_segments(), 'api', 'events', $event, 'submissions');
	$uri->query_form({
		limit => 10000,
	});
	return $self->fetch_resource($uri);
}


sub fetch_schedule ($self, $event) {
	my $uri = URI->new($self->pretalx_url);
	$uri->path_segments($uri->path_segments(), $event, 'schedule', 'widget', 'v2.json');
	return $self->fetch_resource($uri);
}


sub fetch_resource ($self, $url) {
	my $result = $self->_ua()->get($url);
	unless ($result->is_success()) {
		croak 'Failed to retrieve submissions: ' . $result->status_line();
	}
	return decode_json($result->content());
}


sub find_existing_sessions ($self) {
	my $sessions;
	if (-d $self->target_dir()) {
		for my $room (sort $self->target_dir()->children()) {
			for my $day (sort $room->children()) {
				SESSION: for my $session (sort $day->children()) {
					my ($code) = $session->basename() =~ m{([A-Z0-9]{6,6})$};
					unless (defined $code) {
						next SESSION;
					}
					$sessions->{$code} //= {
						code        => $code,
						directories => [],
					};
					push @{ $sessions->{$code}->{directories} },
						$session->absolute()->resolve();
				}
			}
		}
	}

	return $sessions;
}


sub cleanup ($self) {
	for my $room ($self->target_dir()->children()) {
		for my $day ($room->children()) {
			$self->remove_if_empty($day);
		}
		$self->remove_if_empty($room);
	}
}


sub remove_if_empty ($self, $directory) {
	unless ($directory->children()) {
		rmdir $directory or die 'Failed to remove ' . $directory. ': ' . $!;
	}
}


sub sync_nextcloud ($self) {
	my @cmd = ('nextcloudcmd',
		'--user', $self->nextcloud_user(),
		'--password', $self->nextcloud_password(),
		($self->nextcloud_silent() ? ('--silent') : ()),
		$self->target_dir(),
		$self->nextcloud_folder_url(),
	);
	systemx(@cmd);
}


sub aggregate_statuses ($self, $aggregate, $new) {
	my $aggregated_statuses = { %{ $aggregate } };
	for my $key (keys %{ $new }) {
		if ($key =~ m{_count$}) {
			# Sum up counts
			$aggregated_statuses->{$key} //= 0;
			$aggregated_statuses->{$key} += $new->{$key};
		}
	}

	return $aggregated_statuses;
}


__PACKAGE__->meta()->make_immutable();
