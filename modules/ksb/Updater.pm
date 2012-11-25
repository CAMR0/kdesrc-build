package ksb::Updater;

# Base class for classes that handle updating the source code for a given Module.
# It should not be used directly.

use strict;
use warnings;
use v5.10;

use ksb::Util;

sub new
{
    my ($class, $module) = @_;

    return bless { module => $module }, $class;
}

sub name
{
    croak_internal('This package should not be used directly.');
}

sub module
{
    my $self = shift;
    return $self->{module};
}

1;