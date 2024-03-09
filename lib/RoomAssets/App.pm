package RoomAssets::App;

# ABSTRACT: Application to work with presentation assets required in a conference room

use Moose;

extends qw(MooseX::App::Cmd);


__PACKAGE__->meta()->make_immutable();
