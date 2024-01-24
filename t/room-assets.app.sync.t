use strict;
use warnings;

use Test::More tests => 4;
use File::Temp;
use Path::Class::Dir;
use Test::File;

my $tmp_dir = File::Temp->newdir();
my $scratch = Path::Class::Dir->new($tmp_dir);

use_ok('RoomAssets::App::Sync');


subtest 'sanitize_file_name' => sub {
	plan tests => 20;

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
		# Combinations
		'../../foo bar/baz.txt' => '.._.._foo_bar_baz.txt',
		'My talk: My Subject'   => 'My_talk_My_Subject',
		'My talk, my subject'   => 'My_talk_my_subject',
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
	dir_exists_ok($target_dir->subdir('Auditorium_A'), 'Auditorium A directory created');
	dir_exists_ok($target_dir->subdir('Auditorium_A', '2022-08-19', '2022-08-19_1000_-_The_talk_title'), 'Talk directory created');
	file_exists_ok(
		$target_dir->subdir('Auditorium_A', '2022-08-19', '2022-08-19_1000_-_The_talk_title', 'hello.txt'),
		'Talk resource created'
	);

	$app = RoomAssets::App::Sync->new({
		events      => ['our-conference'],
		rooms       => ['Auditorium A', 'Auditorium B'],
		target_dir  => $target_dir,
		pretalx_url => 'file:t/testdata',
	});

	$app->sync_event('our-conference');
	dir_exists_ok($target_dir->subdir('Auditorium_B'), 'Auditorium B directory created');
	dir_exists_ok($target_dir->subdir('Auditorium_B', '2022-08-19', '2022-08-19_1030_-_The_title_of_the_other_talk'), 'Talk directory created');
};
