package RoomAssets::App::Sync;

# ABSTRACT: Synchronize room assets from Pretalx to Nextcloud

use 5.010001;
use strict;
use warnings;

use Carp;
use Moose;
use MooseX::Types::Path::Class;
with 'MooseX::Getopt::Dashes';

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


sub run ($self) {
	unless (-d $self->target_dir()) {
		croak 'Target dirctory ' . $self->target_dir() . ' does not exist';
	}

	if (defined $self->nextcloud_folder_url()) {
		$self->sync_nextcloud();
	}

	for my $event (@{$self->events()}) {
		$self->sync_event($event);
	}

	if (defined $self->nextcloud_folder_url()) {
		$self->sync_nextcloud();
	}

	return 0;
}


sub sync_event ($self, $event) {
	my $submissions = $self->fetch_submissions($event);
	my $schedule    = $self->fetch_schedule($event);

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
	my %submissions = map {
		($_->{code} => $_)
	} @{ $submissions->{results} };
	TALK: for my $talk (@{ $schedule->{talks} }) {
		my $room = $rooms{$talk->{room}};
		unless (defined $room && defined $talk->{code}) {
			next TALK;
		}
		my $start = DateTime::Format::ISO8601->parse_datetime($talk->{start});
		if (defined $self->locale()) {
			$start->set_locale($self->locale());
		}
		my $assets_target = $self->target_dir()
			->subdir($self->sanitize_file_name($room))
			->subdir($start->strftime($self->day_strftime_pattern()))
			->subdir($start->strftime($self->session_strftime_pattern())
				. '_-_' . $self->sanitize_file_name($talk->{title})
			);
		$assets_target->mkpath();

		my $submission = $submissions{$talk->{code}};
		unless (defined $submission) {
			croak 'No submission for ' . $talk->{code} . ' found'
		}

		my @assets = map { $_->{resource} } @{ $submission->{resources} };
		$self->update_or_create_resources($assets_target, @assets);
	}
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


sub update_or_create_resources ($self, $target_dir, @assets) {
	for my $asset (@assets) {
		my ($filename) = reverse split(/\//, $asset);
		$filename = $self->sanitize_file_name($filename);
		my $target_file = $target_dir->file($filename);

		my $asset_uri = index($asset, 'http') == 0
			? URI->new($asset)
			: do {
				my $uri = URI->new($self->pretalx_url());
				$uri->path_segments($uri->path_segments(), split(/\//, $asset));
				$uri;
			};

		my $result = $self->_ua()->mirror($asset_uri, $target_file);
		unless ($result->is_success() || $result->code() eq 304) {
			confess 'Failed to download asset ' . $asset . ': ' . $result->status_line();
		}
	}
}


sub sanitize_file_name ($self, $name) {
	# Prevent . and .. as filenames
	$name =~ s{^\.{1,2}$}{_};
	# Get rid of characters the nextcloudcmd client considers invalid and that
	# might cause issues on Windows, too, or which are generally not so 'nice'
	# in file names
	$name =~ s{(?:/|\s|:|,|\?|\*|'|"|\||<|>|\(|\)|\\)+}{_}g;
	# Further cleanup to get slightly nicer names after the above replacements
	$name =~ s{_+}{_}g;       # Collapse multiple consecutive _
	$name =~ s{(?<=.)_+$}{};  # Remove trailing _, avoid empty result
	$name =~ s{^_+(?=.)}{};   # Remove leading _, avoid empty result
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


__PACKAGE__->meta()->make_immutable();
