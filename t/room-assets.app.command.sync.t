use strict;
use warnings;

use utf8;
use Test::More tests => 12;
use File::Temp;
use Path::Class::Dir;
use Test::File;
use Test::Exception;
use Encode;
use Test::MockObject;

my $tmp_dir = File::Temp->newdir();
my $scratch = Path::Class::Dir->new($tmp_dir);
my $app_mock = Test::MockObject->new();
$app_mock->set_isa('MooseX::App::Cmd');
my $log_level = 'critical';

use_ok('RoomAssets::App::Command::sync');


subtest 'sanitize_file_name' => sub {
	plan tests => 38;

	my $target_dir = $scratch->subdir('sanitize_file_name');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app        => $app_mock,
		log_level  => $log_level,
		events     => ['our-conference'],
		rooms      => ['Auditorium A'],
		target_dir => $target_dir,
	});
	my %test_cases = (
		# Simple ones
		'.'                     => '_',
		'..'                    => '_',
		'/'                     => '_',
		'//'                    => '_',
		'foo bar'               => 'foo_bar',
		"\t"                    => '_',
		"   \t  "               => '_',
		':'                     => '_',
		','                     => '_',
		'?'                     => '_',
		'*'                     => '_',
		'\''                    => '_',
		'"'                     => '_',
		'|'                     => '_',
		'<'                     => '_',
		'>'                     => '_',
		'\\'                    => '_',
		'('                     => '_',
		')'                     => '_',
		'_'                     => '_',
		'!'                     => '_',
		'&'                     => '_',
		# Further cleanups
		'__'                    => '_',
		'___'                   => '_',
		't_'                    => 't',
		't____'                 => 't',
		'_t____'                => 't',
		'_t_t_'                 => 't_t',
		'__t__t__'              => 't_t',
		'-t'                    => 't',
		'--t'                   => 't',
		'-'                     => '_',
		't-t'                   => 't-t',
		'-..'                   => '_',
		# Combinations
		'../../foo bar/baz.txt' => '.._.._foo_bar_baz.txt',
		'My talk: My Subject'   => 'My_talk_My_Subject',
		'My talk, my subject'   => 'My_talk_my_subject',
		'_My__talk (subject)_'  => 'My_talk_subject',
	);
	for my $input (keys %test_cases) {
		is($command->sanitize_file_name($input), $test_cases{$input}, 'sanitized as expected');
	}
};


subtest 'update_or_create_resources' => sub {
	plan tests => 1;

	my $target_dir = $scratch->subdir('update_or_create_resources');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		rooms       => ['Auditorium A'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$command->update_or_create_resources($target_dir, {
		resources => [{
			resource => 'resources/hello.txt',
		}],
	});
	file_exists_ok($target_dir->file('hello.txt'), 'file downloaded');
};


subtest 'sync_event' => sub {
	plan tests => 7;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		rooms       => ['Auditorium A'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $status = $command->sync_event('our-conference');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A'
	), 'Auditorium A directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5'
	), 'Talk directory created');
	file_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5',
					'hello.txt'
	), 'Talk resource created');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 1,
		new_talks_count         => 1,
		updated_resources_count => 0,
	}, 'statistics correct');

	$command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		rooms       => ['Auditorium A', 'Auditorium B'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$status = $command->sync_event('our-conference');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_The_title_of_the_other_talk_-_JFDS30'
	), 'Talk directory created');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 0,
		new_talks_count         => 1,
		updated_resources_count => 0,
	}, 'statistics correct');

	$target_dir->rmtree();
};


subtest 'sync_event with a talk having more than one slot' => sub {
	plan tests => 11;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['multislot'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $status = $command->sync_event('multislot');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A'
	), 'Auditorium A directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B'
	), 'Auditorium B directory created');
	my $slot_1_dir = $target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5'
	);
	dir_exists_ok($slot_1_dir, 'Talk slot 1 directory created');
	file_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5',
					'hello.txt'
	), 'Talk slot 1 resource created');
	my $slot_2_dir = $target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_The_talk_title_-_39DAS5'
	);
	dir_exists_ok($slot_2_dir, 'Talk slot 2 directory created');
	file_exists_ok($target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_The_talk_title_-_39DAS5',
					'hello.txt'
	), 'Talk slot 2 resource created');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 2,
		new_talks_count         => 2,
		updated_resources_count => 0,
	}, 'statistics correct');

	$status = $command->sync_event('multislot');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 0,
		new_talks_count         => 0,
		updated_resources_count => 0,
	}, 'statistics correct');

	$slot_2_dir->rmtree();
	$status = $command->sync_event('multislot');
	dir_exists_ok($slot_1_dir, 'Talk slot 1 directory created');
	dir_exists_ok($slot_2_dir, 'Talk slot 1 directory created');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 1,
		new_talks_count         => 1,
		updated_resources_count => 0,
	}, 'statistics correct');

	$target_dir->rmtree();
};


subtest 'sync_event with non-English language' => sub {
	plan tests => 8;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-other-conference'],
		rooms       => [encode('UTF-8', 'Hörsaal A')],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $status = $command->sync_event('our-other-conference');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A'
	), 'Hörsaal A directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6'
	), 'Talk directory created');
	file_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6',
					'hallo.txt'
	), 'Talk resource created');
	file_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6',
					'Hallöchen_Welt_.txt'
	), 'Talk resource created');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 2,
		new_talks_count         => 1,
		updated_resources_count => 0,
	}, 'statistics correct');

	$target_dir->rmtree();
	$command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-other-conference'],
		rooms       => [encode('UTF-8', 'Hörsaal A'), encode('UTF-8', 'Hörsaal B')],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
		locale      => 'de-DE',
	});

	$status = $command->sync_event('our-other-conference');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B',
			'2022-08-19_Freitag',
				'2022-08-19_Freitag_1030_-_Der_Titel_des_anderen_Vortrages_-_JFDS31'
	), 'Talk directory created');
	is_deeply($status, {
		failed_resources_count  => 3,
		moved_talks_count       => 0,
		new_resources_count     => 2,
		new_talks_count         => 2,
		updated_resources_count => 0,
	}, 'statistics correct');

	$target_dir->rmtree();
};


subtest 'room_name' => sub {
	plan tests => 3;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-other-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $name = $command->room_name({
		name => {
			en => 'Room 1',
		},
	});
	is($name, 'Room 1', 'room name extracted');

	throws_ok(sub {
		$command->room_name({
			name => {
				en          => 'Room 1',
				'de-formal' => 'Raum 1',
			},
		});
	}, qr{More than one room name}, '--language parameter required');

	$command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-other-conference'],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});
	$name = $command->room_name({
		name => {
			en          => 'Room 1',
			'de-formal' => 'Raum 1',
		},
	});
	is($name, 'Raum 1', 'room name extracted');

	$target_dir->rmtree();
};


subtest 'sync_event with all defined rooms' => sub {
	plan tests => 7;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-other-conference'],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $status = $command->sync_event('our-other-conference');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A'
	), 'Hörsaal A directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6'
	), 'Talk directory created');
	file_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6',
					'hallo.txt'
	), 'Talk resource created');
	file_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6',
					'Hallöchen_Welt_.txt'
	), 'Talk resource created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_Der_Titel_des_anderen_Vortrages_-_JFDS31'
	), 'Talk directory created');
	is_deeply($status, {
		failed_resources_count  => 3,
		moved_talks_count       => 0,
		new_resources_count     => 2,
		new_talks_count         => 2,
		updated_resources_count => 0,
	}, 'statistics correct');

	$target_dir->rmtree();
};


subtest 'run with multiple events' => sub {
	plan tests => 9;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference', 'our-other-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});
	my $exit_code = $command->perform_sync();

	is($exit_code, 1, 'something has changed');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A'
	), 'Auditorium A directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5'
	), 'Talk directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_The_title_of_the_other_talk_-_JFDS30'
	), 'Talk directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A'
	), 'Hörsaal A directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6'
	), 'Talk directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_Der_Titel_des_anderen_Vortrages_-_JFDS31'
	), 'Talk directory created');

	$target_dir->rmtree();
};


subtest 'move existing sessions on changes' => sub {
	plan tests => 7;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $status = $command->sync_event('our-conference');
	file_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5',
					'hello.txt'
	), 'Talk resource created');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 0,
		new_resources_count     => 1,
		new_talks_count         => 2,
		updated_resources_count => 0,
	}, 'statistics correct');

	$command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
		locale      => 'de-DE',  # Use different locale now
	});

	$status = $command->sync_event('our-conference');
	my $hello_txt = $target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Freitag',
				'2022-08-19_Freitag_1000_-_The_talk_title_-_39DAS5',
					'hello.txt'
	);
	file_exists_ok($hello_txt, 'Talk directory and resource moved');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 2,
		new_resources_count     => 0,
		new_talks_count         => 0,
		updated_resources_count => 0,
	}, 'statistics correct');

	$command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-updated-conference'],  # Moved and changed some talks
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
		locale      => 'de-DE',
	});
	utime 0, 0, $hello_txt;  # Force file update on next sync

	$status = $command->sync_event('our-updated-conference');
	file_exists_ok($target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Freitag',
				'2022-08-19_Freitag_1100_-_The_new_talk_title_-_39DAS5',
					'hello.txt'
	), 'Talk directory and resource moved');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Freitag',
				'2022-08-19_Freitag_1130_-_The_new_title_of_the_other_talk_-_JFDS30'
	), 'Talk directory moved');
	is_deeply($status, {
		failed_resources_count  => 0,
		moved_talks_count       => 2,
		new_resources_count     => 0,
		new_talks_count         => 0,
		updated_resources_count => 1,
	}, 'statistics correct');

	$target_dir->rmtree();
};


subtest 'cleanup of empty rooms and days' => sub {
	plan tests => 5;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $hidden_file = $target_dir->file('.hidden-file');
	$hidden_file->touch();
	my $hidden_dir = $target_dir->subdir('.hidden-dir');
	$hidden_dir->mkpath();
	my $hidden_dir_child = $hidden_dir->file('child');
	$hidden_dir_child->touch();
	my $doomed_room = $target_dir->subdir('Doomed_Room');
	$doomed_room->mkpath();
	my $doomed_day = $doomed_room->subdir('Doomed_Day');
	$doomed_day->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$command->cleanup();
	file_not_exists_ok($doomed_room, 'Empty room removed');
	file_not_exists_ok($doomed_day, 'Empty day removed');
	file_exists_ok($hidden_file, 'Hidden file kept');
	dir_exists_ok($hidden_dir, 'Hidden dir kept');
	file_exists_ok($hidden_dir_child, 'Hidden dir child file kept');
};


subtest 'existing sessions detection' => sub {
	plan tests => 1;

	my $target_dir = $scratch->subdir('find_existing_sessions');
	$target_dir->mkpath();
	my $hidden_file = $target_dir->file('.hidden-file');
	$hidden_file->touch();
	my $hidden_dir = $target_dir->subdir('.hidden-dir');
	$hidden_dir->mkpath();
	my $hidden_dir_child = $hidden_dir->file('child');
	$hidden_dir_child->touch();
	my $room = $target_dir->subdir('Room');
	$room->mkpath();
	my $day = $room->subdir('Day');
	$day->mkpath();
	my $session_code = 'JFDS30';
	my $session_dir = $day->subdir('1130_-_The_talk_-_' . $session_code);
	$session_dir->mkpath();
	my $command = RoomAssets::App::Command::sync->new({
		app         => $app_mock,
		log_level   => $log_level,
		events      => ['our-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $sessions = $command->find_existing_sessions();
	is_deeply($sessions, {
		$session_code => {
			code        => $session_code,
			directories => [
				$session_dir,
			],
		},
	}, 'expected sessions found');
};
