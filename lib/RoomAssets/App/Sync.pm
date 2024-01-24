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
	required      => 1,
	documentation => 'Names of rooms to sync.',
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
}


sub sync_event ($self, $event) {
	my $submissions = $self->fetch_submissions($event);
	my $schedule    = $self->fetch_schedule($event);

	my %rooms = map {
		($_->{id} => $_->{name}->{en})
	} grep {
		my $room_name = $_->{name}->{en};
		any { $room_name eq $_ } @{ $self->rooms() }
	}  @{$schedule->{rooms}};
	my %submissions = map {
		($_->{code} => $_)
	} @{ $submissions->{results} };
	TALK: for my $talk (@{ $schedule->{talks} }) {
		my $room = $rooms{$talk->{room}};
		unless (defined $room) {
			next TALK;
		}
		my $start = DateTime::Format::ISO8601->parse_datetime($talk->{start});
		my $assets_target = $self->target_dir()
			->subdir($self->sanitize_file_name($room))
			->subdir($start->strftime('%Y-%m-%d'))
			->subdir($start->strftime('%Y-%m-%d_%H%M') . '_-_' . $self->sanitize_file_name($talk->{title}));
		$assets_target->mkpath();

		my $submission = $submissions{$talk->{code}};
		unless (defined $submission) {
			croak 'No submission for ' . $talk->{code} . ' found'
		}

		my @assets = map { $_->{resource} } @{ $submission->{resources} };
		$self->update_or_create_resources($assets_target, @assets);
	}
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
	$name =~ s{^.{1,2}$}{_};
	# Get rid of characters the nextcloudcmd client considers invalid and that
	# might cause issues on Windows, too
	$name =~ s{(?:/|\s|:|,|\?|\*|'|"|\||<|>|\\)+}{_}g;
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
