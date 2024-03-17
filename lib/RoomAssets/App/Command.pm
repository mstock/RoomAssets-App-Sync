package RoomAssets::App::Command;

# ABSTRACT: Base class for commands

use 5.010001;
use strict;
use warnings;

use Carp;
use Moose;
use Log::Any::Adapter;

extends qw(MooseX::App::Cmd::Command);
with 'MooseX::Getopt::Dashes';

no warnings qw(experimental::signatures);
use feature qw(signatures);


has 'log_level' => (
	traits        => ['Getopt'],
	cmd_aliases   => ['l'],
	is            => 'ro',
	isa           => 'Str',
	default       => 'error',
	documentation => 'Log level to use. One of trace, debug, info, warning, error, '
		. 'critical, alert or emergency.',
);


sub BUILD ($self, $params) {
	Log::Any::Adapter->set('Stderr', log_level => $self->log_level());
}


__PACKAGE__->meta()->make_immutable();
