use strict;
use warnings;

use utf8;
use Test::More tests => 8;
use File::Temp;
use Path::Class::Dir;
use Test::File;
use Test::Exception;
use Encode;

my $tmp_dir = File::Temp->newdir();
my $scratch = Path::Class::Dir->new($tmp_dir);

use_ok('RoomAssets::App::Sync');


subtest 'sanitize_file_name' => sub {
	plan tests => 31;

	my $target_dir = $scratch->subdir('sanitize_file_name');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
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
		# Further cleanups
		'__'                    => '_',
		'___'                   => '_',
		't_'                    => 't',
		't____'                 => 't',
		'_t____'                => 't',
		'_t_t_'                 => 't_t',
		'__t__t__'              => 't_t',
		# Combinations
		'../../foo bar/baz.txt' => '.._.._foo_bar_baz.txt',
		'My talk: My Subject'   => 'My_talk_My_Subject',
		'My talk, my subject'   => 'My_talk_my_subject',
		'_My__talk (subject)_'  => 'My_talk_subject',
	);
	for my $input (keys %test_cases) {
		is($app->sanitize_file_name($input), $test_cases{$input}, 'sanitized as expected');
	}
};


subtest 'update_or_create_resources' => sub {
	plan tests => 1;

	my $target_dir = $scratch->subdir('update_or_create_resources');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
		events      => ['our-conference'],
		rooms       => ['Auditorium A'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$app->update_or_create_resources($target_dir, (
		'resources/hello.txt',
	));
	file_exists_ok($target_dir->file('hello.txt'), 'file downloaded');
};


subtest 'sync_event' => sub {
	plan tests => 5;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
		events      => ['our-conference'],
		rooms       => ['Auditorium A'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$app->sync_event('our-conference');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A'
	), 'Auditorium A directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5-42001'
	), 'Talk directory created');
	file_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5-42001',
					'hello.txt'
	), 'Talk resource created');

	$app = RoomAssets::App::Sync->new({
		events      => ['our-conference'],
		rooms       => ['Auditorium A', 'Auditorium B'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$app->sync_event('our-conference');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_The_title_of_the_other_talk_-_JFDS30-42002'
	), 'Talk directory created');

	$target_dir->rmtree();
};


subtest 'sync_event with non-English language' => sub {
	plan tests => 5;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
		events      => ['our-other-conference'],
		rooms       => [encode('UTF-8', 'Hörsaal A')],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$app->sync_event('our-other-conference');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A'
	), 'Hörsaal A directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6-42003'
	), 'Talk directory created');
	file_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6-42003',
					'hallo.txt'
	), 'Talk resource created');

	$app = RoomAssets::App::Sync->new({
		events      => ['our-other-conference'],
		rooms       => [encode('UTF-8', 'Hörsaal A'), encode('UTF-8', 'Hörsaal B')],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
		locale      => 'de-DE',
	});

	$app->sync_event('our-other-conference');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B',
			'2022-08-19_Freitag',
				'2022-08-19_Freitag_1030_-_Der_Titel_des_anderen_Vortrages_-_JFDS31-42004'
	), 'Talk directory created');

	$target_dir->rmtree()
};


subtest 'room_name' => sub {
	plan tests => 3;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
		events      => ['our-other-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	my $name = $app->room_name({
		name => {
			en => 'Room 1',
		},
	});
	is($name, 'Room 1', 'room name extracted');

	throws_ok(sub {
		$app->room_name({
			name => {
				en          => 'Room 1',
				'de-formal' => 'Raum 1',
			},
		});
	}, qr{More than one room name}, '--language parameter required');

	$app = RoomAssets::App::Sync->new({
		events      => ['our-other-conference'],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});
	$name = $app->room_name({
		name => {
			en          => 'Room 1',
			'de-formal' => 'Raum 1',
		},
	});
	is($name, 'Raum 1', 'room name extracted');

	$target_dir->rmtree()
};


subtest 'sync_event with all defined rooms' => sub {
	plan tests => 5;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
		events      => ['our-other-conference'],
		language    => 'de-formal',
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$app->sync_event('our-other-conference');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A'
	), 'Hörsaal A directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6-42003'
	), 'Talk directory created');
	file_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6-42003',
					'hallo.txt'
	), 'Talk resource created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_Der_Titel_des_anderen_Vortrages_-_JFDS31-42004'
	), 'Talk directory created');

	$target_dir->rmtree()
};


subtest 'run with multiple events' => sub {
	plan tests => 8;

	my $target_dir = $scratch->subdir('sync_event');
	$target_dir->mkpath();
	my $app = RoomAssets::App::Sync->new({
		events      => ['our-conference', 'our-other-conference'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});
	$app->run();

	dir_exists_ok($target_dir->subdir(
		'Auditorium_A'
	), 'Auditorium A directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_The_talk_title_-_39DAS5-42001'
	), 'Talk directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Auditorium_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_The_title_of_the_other_talk_-_JFDS30-42002'
	), 'Talk directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A'
	), 'Hörsaal A directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_A',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1000_-_Der_Vortragstitel_-_39DAS6-42003'
	), 'Talk directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B'
	), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir(
		'Hörsaal_B',
			'2022-08-19_Friday',
				'2022-08-19_Friday_1030_-_Der_Titel_des_anderen_Vortrages_-_JFDS31-42004'
	), 'Talk directory created');

	$target_dir->rmtree()
};
