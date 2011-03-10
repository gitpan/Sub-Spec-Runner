package Sub::Spec::Runner::State;
BEGIN {
  $Sub::Spec::Runner::State::VERSION = '0.12';
}
# ABSTRACT: Save undo data

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Moo;

use File::Path qw(make_path);
use YAML::Syck qw(LoadFile DumpFile);

has root_dir => (is => 'rw', default=>sub{"$ENV{HOME}/.subspec/.undo"});

# By default undo data is saved in ~/.subspec/undo/<DOTTED_SUBNAME>.yaml or
# <DOTTED_SUBNAME>/, e.g. ~/.subspec/.undo/perl.yaml


# get([\%opts], key)
sub get {
    my $self = shift;
    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    $self->{subname} = $opts->{subname} // (caller(1))[3];

    $self->_load;
    $self->{data}{$_[0]};
}

# set([\%opts], key=>val, key2=>val, ...)
sub set {
    my $self = shift;
    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    $self->{subname} = $opts->{subname} // (caller(1))[3];

    use autodie;

    $self->_load;
    while (my ($key, $val) = splice @_, 0, 2) {
        $self->{data}{$key} = $val;
        $log->tracef("Setting key: %s => %s", $key, $val);
    }
    $log->tracef("Writing file %s (%d keys) ...",
                 $self->{path_file}, scalar(keys %{$self->{data}}));
    DumpFile($self->{path_file}, $self->{data});
}

# delete([\%opts], key, key2, ...)
sub delete {
    my $self = shift;
    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    $self->{subname} = $opts->{subname} // (caller(1))[3];

    use autodie;

    $self->_load;
    delete $self->{data}{$_} for @_;
    if (scalar keys %{$self->{data}}) {
        $log->tracef("Writing file %s (%d keys) ...",
                     $self->{path_file}, scalar(keys %{$self->{data}}));
        DumpFile($self->{path_file}, $self->{data});
    } else {
        $log->tracef("Deleting file %s (no more keys) ...",
                     $self->{path_file});
        unlink $self->{path_file} if -f $self->{path_file};
    }
}

sub _load {
    my ($self) = @_;

    use autodie;

    $self->_prepare_storage();
    unless (-f $self->{path_file}) {
        $self->{data} = {};
        return;
    }
    my $mtime = (-M $self->{path_file});
    if (!$self->{data} ||
            !$self->{path_file_mtime} ||
                $self->{path_file_mtime} != $mtime) {
        $log->trace("Reading file $self->{path_file} ...");
        $self->{data} = LoadFile($self->{path_file});
        $self->{path_file_mtime} = $mtime;
    }
}

sub _prepare_storage {
    my ($self, $opts) = @_;

    my $file = $self->{subname};
    $file =~ s/^Spanel::Setup:://;
    $file =~ s/::/./g;

    use autodie;

    make_path($self->{root_dir}, {mode=>0700}) unless (-d $self->{root_dir});
    $self->{path_file} = "$self->{root_dir}/$file.yaml";
    $self->{path_dir}  = "$self->{root_dir}/$file";
}

1;

__END__
=pod

=head1 NAME

Sub::Spec::Runner::State - Save undo data

=head1 VERSION

version 0.12

=for Pod::Coverage get set delete

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

