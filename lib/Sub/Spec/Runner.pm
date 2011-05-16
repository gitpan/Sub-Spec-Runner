package Sub::Spec::Runner;
BEGIN {
  $Sub::Spec::Runner::VERSION = '0.14';
}
# ABSTRACT: Run subroutines

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Moo;
use Sub::Spec::Utils; # temp, for _parse_schema
use YAML::Syck;


# {SUBNAME => {done=>BOOL, spec=>SPEC, fldeps=>FLATTENED_DEPS, ...}, ...}
has _sub_data  => (is => 'rw', default=>sub{{}});

# [SUBNAME, ...], the list of subroutine names in the order of execution
has _sub_list  => (is => 'rw', default=>sub{[]});

# for subroutines to share data
has _stash     => (is => 'rw', default=>sub{{}});

# index to _sub_list, the current running subroutine
has _i         => (is => 'rw');

# shorter way to insert custom code rather than subclassing
has _pre_run   => (is => 'rw');
has _post_run  => (is => 'rw');
has _pre_sub   => (is => 'rw');
has _post_sub  => (is => 'rw');



has common_args => (is => 'rw');


has load_modules => (is => 'rw', default=>sub{1});


has stop_on_sub_errors => (is => 'rw', default=>sub{1});


has order_before_run => (is => 'rw', default=>sub{1});


has undo => (is => 'rw');


has undo_data_dir => (is => 'rw', default => sub {
    my $dir = $ENV{HOME} or die "Can't set default undo_data_dir, no HOME set";
    $dir .= "/.subspec";
    unless (-d $dir) {
        mkdir $dir, 0700 or die "Can't mkdir $dir: $!";
    }
    $dir .= "/.undo";
    unless (-d $dir) {
        mkdir $dir, 0700 or die "Can't mkdir $dir: $!";
    }
    $dir;
});


has dry_run => (is => 'rw', default=>sub{0});



sub __parse_schema {
    Sub::Spec::Utils::_parse_schema(@_);
}

# flatten deps clauses by flattening 'all' clauses, effectively change this
# deps clause:
#
#  {
#   sub => 's1',
#   all => [
#     {sub => 's1'},
#     {deb => {d1=>0, d2=>'>= 0', d3=>'= 1'},
#     {and => [{sub => 's2'}, {sub=>'s3'}, {deb=>{d3=>0}}],
#   ],
#  },
#
# into:
#
#  {
#   sub => ['s1', 's2', 's3'], # also uniquify sub names
#   deb => [{d1],
#  }
#
# dies if 'any' or 'none' clauses are encountered.
sub __flatten_deps {
    my ($deps, $res) = @_;
    $res //= {};
    while (my ($k, $v) = each %$deps) {
        if ($k =~ /^(any|none)$/) {
            die "Can't handle '$_' deps clause";
        } elsif ($k eq 'all') {
            __flatten_deps($_, $res) for @$v;
        } else {
            $res->{$k} //= [];
            next if $k eq 'sub' && $v ~~ @{ $res->{$k} };
            push @{ $res->{$k} }, $v;
        }
    }
    $res;
}

# add main:: if unqualified
sub __normalize_subname {
    my ($subname) = @_;
    $subname =~ /(.*)::(.+)/ or return "main::$subname";
    (length($1) ? $1 : "main") . "::" . $2;
}


sub get_spec {
    my ($self, $subname) = @_;
    my ($module, $sub) = $subname =~ /(.+)::(.+)/;
    no strict 'refs';
    # assume module already loaded (by add())
    my $ms = \%{"$module\::SPEC"};
    $ms->{$sub};
}


our $current_runner;

sub add {
    require Sub::Spec::Clause::deps;

    my ($self, $subname, $args) = @_;
    $subname = __normalize_subname($subname);

    return if exists $self->_sub_data->{$subname};
    $log->tracef('-> add(%s)', $subname);
    $self->_sub_data->{$subname} = undef; # to avoid deep recursion on circular

    # load module
    my ($module, $sub);
    $subname =~ /(.+)::(.+)/;
    ($module, $sub) = ($1, $2);
    if ($self->load_modules) {
        my $modulep = $module;
        $modulep =~ s!::!/!g; $modulep .= ".pm";
        die "Cannot load module $module: $@\n"
            unless eval { require $modulep };
    }

    my $spec = $self->get_spec($subname);
    die "Can't find spec in \$$module\::SPEC{$sub}\n"
        unless $spec;

    my $fldeps = {};
    if ($spec->{deps}) {
        __flatten_deps($spec->{deps}, $fldeps);
        $log->tracef("fldeps for $subname = %s", $fldeps);
        $log->tracef("Checking dependencies ...");
        local $current_runner = $self;
        my $res = Sub::Spec::Clause::deps::check($spec->{deps});
        die "Unmet dependencies for sub $subname: $res\n" if $res;
    }

    my $subdata = {
        name      => $subname,
        spec      => $spec,
        fldeps    => $fldeps,
        args      => $args,
    };
    $self->_sub_data->{$subname} = $subdata;
    push @{ $self->_sub_list }, $subname;

    $log->trace("<- add()");
}


sub order_by_dependencies {
    $log->tracef("-> order_by_dependencies()");
    require Algorithm::Dependency::Ordered;
    require Algorithm::Dependency::Source::HoA;

    my ($self) = @_;
    my %deps;
    while (my ($sn, $sd) = each %{$self->{_sub_data}}) {
        $deps{$sn} //= [];
        my $sub_deps = $sd->{fldeps}{run_sub};
        push @{ $deps{$sn} }, @$sub_deps if $sub_deps;
    }

    my $ds  = Algorithm::Dependency::Source::HoA->new(\%deps);
    my $ado = Algorithm::Dependency::Ordered->new(
        source   => $ds,
        selected => []
    );
    unless ($ado) {
        $log->error("Failed to set up dependency algorithm");
        return 0;
    }

    my $subs = $ado->schedule_all;
    unless (ref($subs) eq 'ARRAY') {
        $log->error("schedule_all() failed");
        return 0;
    }

    if ($self->undo) {
        $log->trace("Reversing order of subroutines because ".
                        "we are running in undo mode");
        $subs = [reverse @$subs];
    }

    $self->_sub_list($subs);
    1;
}


sub todo_subs {
    my ($self) = @_;
    [ grep {!$self->_sub_data->{done}} @{$self->_sub_list} ];
}


sub done_subs {
    my ($self) = @_;
    [ grep {$self->_sub_data->{done}} @{$self->_sub_list} ];
}

sub _log_running_sub {
    my ($self, $subname) = @_;
    $log->infof("Running %s ...", $self->format_subname($subname));
}


sub run {
    my ($self) = @_;
    $log->tracef("-> run()");

    return [400, "No subroutines to run, please add() some first"]
        unless @{ $self->_sub_list };

    if (defined $self->undo) {
        $log->trace("Checking undo/reverse feature of subroutines ...");
        while (my ($sn, $sd) = each %{$self->{_sub_data}}) {
            my $f = $sd->{spec}{features};
            return [412, "Cannot run with undo: $sn doesn't support ".
                        "undo/reverse/pure"]
                unless $f && ($f->{undo} || $f->{reverse} || $f->{pure});
        }
    }

    if ($self->dry_run) {
        $log->trace("Checking dry_run feature of subroutines ...");
        while (my ($sn, $sd) = each %{$self->{_sub_data}}) {
            my $f = $sd->{spec}{features};
            return [412, "Cannot run with dry_run: $sn doesn't support ".
                        "dry_run"]
                unless $f && ($f->{dry_run} || $f->{pure});
        }
    }

    if ($self->order_before_run) {
        return [412, "Cannot resolve dependencies, please check for circulars"]
            unless $self->order_by_dependencies;
    }

    my $hook_res;

    eval { $hook_res = $self->pre_run };
    return [412, "pre_run() died: $@"] if $@;
    return [412, "pre_run() didn't return true"] unless $hook_res;

    my $num_success_runs = 0;
    my $num_failed_runs  = 0;
    my %success_subs;
    my %failed_subs;
    my $res;

    my $use_last_res_status;
  RUN:
    while (1) {
        $self->{_i} = -1;
        my $some_not_done;
        my $jumped;
        while (1) {
            $self->{_i}++ unless $jumped;
            $jumped = 0;
            last unless $self->{_i} < @{ $self->_sub_list };
            my $subname = $self->_sub_list->[ $self->{_i} ];
            my $sd      = $self->_sub_data->{$subname};
            next if $sd->{done};
            my $spec    = $sd->{spec};

            $some_not_done++;
            $self->_log_running_sub($subname);

            my $orig_i = $self->{_i};
            eval { $hook_res = $self->pre_sub($subname) };
            if ($@) {
                $res = [500, "pre_sub(%s) died: $@"];
                $use_last_res_status++;
                last RUN;
            }
            unless ($hook_res) {
                $res = [500, "pre_sub(%s) didn't return true"];
                $use_last_res_status++;
                last RUN;
            }
            next if $sd->{done}; # pre_sub might skip this sub
            $jumped = $orig_i != $self->{_i};

            if ($jumped) {
                last unless $self->{_i} < @{ $self->_sub_list };
            }

            $orig_i = $self->{_i};
            $res = $self->_run_sub($subname, $sd->{args});
            if ($spec->{result_naked}) { $res = [200, "OK (naked)", $res] }
            $sd->{res} = $res;
            if ($self->success_res($res)) {
                $num_success_runs++;
                $success_subs{$subname}++;
                delete ($failed_subs{$subname});
            } else {
                $num_failed_runs++;
                $failed_subs{$subname}++;
                delete ($success_subs{$subname});
                if ($self->stop_on_sub_errors) {
                    $use_last_res_status++;
                    last RUN;
                }
            }
            $self->done($subname, 1);
            $jumped = $orig_i != $self->{_i};

            if ($jumped) {
                last unless $self->{_i} < @{ $self->_sub_list };
            }

            $orig_i = $self->{_i};
            eval { $hook_res = $self->post_sub($subname) };
            if ($@) {
                $res = [500, "post_sub(%s) died: $@"];
                $use_last_res_status++;
                last RUN;
            }
            unless ($hook_res) {
                $res = [500, "post_sub(%s) didn't return true"];
                $use_last_res_status++;
                last RUN;
            }
            $jumped = $orig_i != $self->{_i};
        }
        last unless $some_not_done;
    }

    eval { $hook_res = $self->post_run };
    if ($@) {
        $res = [500, "post_run() died: $@"];
        $use_last_res_status = 1;
    }
    unless ($hook_res) {
        $res = [500, "post_run() didn't return true"];
        $use_last_res_status = 1;
    }

    my $num_subs         = scalar(@{$self->_sub_list});
    my $num_success_subs = scalar(keys %success_subs);
    my $num_failed_subs  = scalar(keys %failed_subs );
    unless ($use_last_res_status) {
        $res = [];
    }
    $res->[2] = {
        num_success_runs   => $num_success_runs,
        num_failed_runs    => $num_failed_runs,
        num_runs           => $num_success_runs+$num_failed_runs,
        num_success_subs   => $num_success_subs,
        num_failed_subs    => $num_failed_subs,
        num_subs           => $num_subs,
        num_run_subs       => $num_success_subs+$num_failed_subs,
        num_skipped_subs   => $num_subs - ($num_success_subs+$num_failed_subs),
    };
    unless ($use_last_res_status) {
        if ($num_success_subs) {
            if ($num_failed_subs) {
                $res->[0] = 200;
                $res->[1] = "Some failed";
            } else {
                $res->[0] = 200;
                $res->[1] = "All succeeded";
            }
        } else {
            $res->[0] = 500;
            $res->[1] = "All failed";
        }
    }
    $log->tracef("<- run(), res=%s", $res);
    $res;
}

sub _run_sub {
    my ($self, $subname, $args) = @_;
    $log->tracef("-> _run_sub(%s)", $subname);
    my $res;
    eval {
        my ($module, $sub) = $subname =~ /(.+)::(.+)/;
        my $fref = \&{"$module\::$sub"};
        unless ($fref) {
            $res = [500, "No sub \&$subname defined"];
            return; # exit eval
        }

        my $sd = $self->_sub_data->{$subname};
        my $spec = $sd->{spec};

        my %all_args;
        my $common_args = $self->common_args // {};
        for (keys %$common_args) {
            $all_args{$_} = $common_args->{$_} if !$sd->{spec}{args} ||
                $sd->{spec}{args}{$_};
        }
        $args //= {};
        for (keys %$args) {
            $all_args{$_} = $args->{$_} if !$sd->{spec}{args} ||
                $sd->{spec}{args}{$_};
        }
        my $args_for_undo = {%all_args};
        if (defined $self->undo) {
            if ($spec->{features}{pure}) {
                # do nothing
            } elsif ($spec->{features}{reverse}) {
                $all_args{-reverse} = $self->undo;
            } elsif ($spec->{features}{undo}) {
                $all_args{-undo_action} = $self->undo ? 'undo':'do';
                if ($self->undo) {
                    my $undo_data = $self->get_undo_data($subname, $args_for_undo);
                    if (!$undo_data) {
                        $res = [304, "skipped: nothing to undo"];
                        return;
                    }
                    $all_args{-undo_data} = $undo_data;
                }
            }
        }
        if (defined $self->dry_run) {
            $all_args{-dry_run} = $self->dry_run;
        }
        $log->tracef("-> %s(%s)", $subname, \%all_args);
        $all_args{-runner} = $self;

        $res = $fref->(%all_args);
        $log->tracef("<- %s(), res=%s", $subname, $res);

        if ($res->[0] != 304) {
            if (defined($self->undo) && !$self->undo
                    && $res->[3] && ref($res->[3]) eq 'HASH' &&
                        $res->[3]{undo_data}) {
                $self->save_undo_data(
                    $subname, $args_for_undo, $res->[3]{undo_data});
            } elsif ($self->undo && $res->[0] == 200) {
                $self->remove_undo_data(
                    $subname, $args_for_undo);
            }
        }
    };
    $res = [500, "sub died: $@"] if $@;
    $log->tracef("<- _run_sub(%s), res=%s", $subname, $res);
    $res;
}


sub format_subname {
    $_[1];
}


sub success_res {
    my ($self, $res) = @_;
    $res->[0] >= 200 && $res->[0] <= 399;
}


sub pre_run {
    my $self = shift;
    !$self->_pre_run || $self->_pre_run->($self, @_);
}


sub pre_sub {
    my $self = shift;
    !$self->_pre_sub || $self->_pre_sub->($self, @_);
}

sub _get_save_undo_data {
    my ($self, $which, $subname, $args, $undo_data) = @_;
    my $args_d = Dump($args);
    my $dir = $self->undo_data_dir;
    $subname =~ s/::/./g;
    my $path = "$dir/$subname.yaml";

    # XXX locking

    if ($which eq 'get') {
        return unless -f $path;
    }

    my $recs;
    my $i = 0;
    my $match_i;
    if (-f $path) {
        $recs = LoadFile($path);
        die "BUG: $path: not an array" unless ref($recs) eq 'ARRAY';
        my $i = 0;
        for my $i (0..@$recs-1) {
            my $rec = $recs->[$i];
            die "BUG: $path: record #$i: not a hash"
                unless ref($rec) eq 'HASH';
            if (!defined($match_i) && Dump($rec->{args}) eq $args_d) {
                $match_i = $i;
            }
            $i++;
        }
    }
    $recs //= [];

    if ($which eq 'get') {
        return unless defined($match_i);
        return [ map { @$_ } reverse @{ $recs->[$match_i]{undo_datas} } ];
    } elsif ($which eq 'save') {
        if (!defined($match_i)) {
            push @$recs, {args=>$args, undo_datas=>[]};
            $match_i = @$recs-1;
        }
        push @{$recs->[$match_i]{undo_datas}}, $undo_data;
        DumpFile($path, $recs);
    } elsif ($which eq 'remove') {
        return unless defined($match_i);
        splice(@$recs, $match_i, 1);
        if (@$recs) {
            DumpFile($path, $recs);
        } else {
            unlink $path;
        }
    }
}


sub get_undo_data {
    my ($self, $subname, $args) = @_;
    $self->_get_save_undo_data('get', $subname, $args);
}


sub save_undo_data {
    my ($self, $subname, $args, $undo_data) = @_;
    $self->_get_save_undo_data('save', $subname, $args, $undo_data);
}


sub remove_undo_data {
    my ($self, $subname, $args) = @_;
    $self->_get_save_undo_data('remove', $subname, $args);
}


sub post_sub {
    my $self = shift;
    !$self->_post_sub || $self->_post_sub->($self, @_);
}


sub post_run {
    my $self = shift;
    !$self->_post_run || $self->_post_run->($self, @_);
}


sub result {
    my ($self, $subname) = @_;
    $subname = __normalize_subname($subname);
    die "$subname is not in the list of added subroutines\n"
        unless $self->_sub_data->{$subname};
    $self->_sub_data->{$subname}{res};
}


sub done {
    my ($self, $subname0, $newval) = @_;

    my @subnames;
    if (ref($subname0) eq 'Regexp') {
        @subnames = grep {/$subname0/} @{$self->_sub_list};
    } else {
        push @subnames, __normalize_subname($subname0);
    }

    my $oldval;
    for my $subname (@subnames) {
        unless ($self->_sub_data->{$subname}) {
            die "$subname is not in the list of added subroutines\n";
        }

        $oldval = $self->_sub_data->{$subname}{done};
        if (defined($newval)) {
            $self->_sub_data->{$subname}{done} = $newval;
        }
    }
    $oldval;
}


sub skip {
    my ($self, $subname) = @_;
    $self->done($subname, 1);
}


sub skip_all {
    my ($self) = @_;
    $self->done(qr/.*/, 1);
}


sub repeat {
    my ($self, $subname) = @_;
    $self->done($subname, 0);
}


sub repeat_all {
    my ($self) = @_;
    $self->done(qr/.*/, 1);
}

# return subname and all others which directly/indirectly depends on it
sub _find_dependants {
    my ($self, $subname, $res) = @_;
    $res //= [$subname];
    my $sd = $self->_sub_data;
    for (keys %$sd) {
        next if $_ ~~ @$res;
        if ($subname ~~ @{ $sd->{$_}{fldeps}{run_sub} // [] }) {
            push @$res, $_;
            $self->_find_dependants($_, $res);
        }
    }
    $res;
}


sub branch_done {
    my ($self, $subname, $newval) = @_;
    $subname = __normalize_subname($subname);
    unless ($self->_sub_data->{$subname}) {
        die "$subname is not in the list of added subroutines";
        return;
    }
    my $sn = $self->_find_dependants($subname);
    for (@$sn) {
        $self->_sub_data->{$_}{done} = $newval;
    }
}


sub jump {
    my ($self, $subname) = @_;
    $subname = __normalize_subname($subname);
    unless ($self->_sub_data->{$subname}) {
        die "$subname is not in the list of added subroutines\n";
    }
    my $sl = $self->_sub_list;
    for my $i (0..@$sl-1) {
        if ($sl->[$i] eq $subname) {
            $self->_i($i);
            last;
        }
    }
}


sub stash {
    my ($self, $key, $newval) = @_;
    my $oldval = $self->_stash->{$key};
    if (defined($newval)) {
        $self->_stash->{$key} = $newval;
    }
    $oldval;
}

package Sub::Spec::Clause::deps;
BEGIN {
  $Sub::Spec::Clause::deps::VERSION = '0.14';
}
# XXX adding run_sub should be done locally, and also modifies the spec schema
# (when it's already defined). probably use a utility function add_dep_clause().

sub check_run_sub {
    my ($cval) = @_;
    $Sub::Spec::Runner::current_runner->add($cval);
    "";
}

1;


=pod

=head1 NAME

Sub::Spec::Runner - Run subroutines

=head1 VERSION

version 0.14

=head1 SYNOPSIS

In YourModule.pm:

 package YourModule;

 use 5.010;
 our %SPEC;

 $SPEC{a} = { deps => {run_sub=>'b'}, ... };
 sub a { my %args = @_; say "a"; [200, "OK"] }

 $SPEC{b} = { deps => {run_sub=>'c'}, ... };
 sub b { my %args = @_; say "b"; [200, "OK"] }

 $SPEC{c} = { deps => {all=>[{run_sub=>'d'}, {run_sub=>'e'}]}, ... };
 sub c { my %args = @_; say "c"; [200, "OK"] }

 $SPEC{d} = { deps => {run_sub=>'e'}, ... };
 sub d { my %args = @_; say "d"; [200, "OK"] }

 $SPEC{e} = { ... };
 sub e { my %args = @_; say "e"; [200, "OK"] }

In main module:

 use Sub::Spec::Runner;

 my $runner = Sub::Spec::Runner->new(load_modules=>0);
 $runner->add('YourModule::a');
 $runner->run;

Will output:

 e
 d
 c
 b
 a

=head1 DESCRIPTION

This class "runs" a set of subroutines. "Running" a subroutine basically means
loading the module and calling the subroutine, plus a few other stuffs. See
run() for more details.

This module uses L<Log::Any> for logging.

This module uses L<Moo> for object system.

=head1 ATTRIBUTES

=head2 common_args => HASHREF

Arguments to pass to each subroutine. Note that each argument will only be
passed if the 'args' clause in subroutine spec specifies that the sub accepts
that argument, or if subroutine doesn't have an 'args' clause. Example:

 package Foo;

 our %SPEC;
 $SPEC{sub0} = {};
 sub sub0 { ... }

 $SPEC{sub1} = {args=>{}};
 sub sub1 { ... }

 $SPEC{sub2} = {args=>{foo=>"str"}};
 sub sub2 { ... }

 $SPEC{sub3} = {args=>{bar=>"str"}};
 sub sub2 { ... }

 $SPEC{sub4} = {args=>{foo=>"str", bar=>"str"}};
 sub sub4 { ... }

 package main;
 use Sub::Spec::Runner;

 my $runner = Sub::Spec::Runner->new(common_args => {foo=>1, foo=>2});
 $runner->add("Foo::sub$_") for (1 2 3 4);
 $runner->run;

Then only sub0 and sub4 will receive the 'foo' and 'bar' args. sub1 won't
receive any arguments, sub2 will only receive 'foo', sub3 will only receive
'bar'.

=head2 load_modules => BOOL (default 1)

Whether to load (require()) modules when required (in add()). You can turn this
off if you are (or want to make) sure that all the subroutines to be run are
already loaded.

=head2 stop_on_sub_errors => BOOL (default 1)

When run()-ning subroutines, whether a non-success return value from a
subroutine stops the whole run. If turned off, run() will continue to the next
subroutine. Note that you can override what constitutes a success return value
by overriding success_res().

=head2 order_before_run => BOOL (default 1)

Before run() runs the subroutines, it will call order_by_dependencies() to
reorder the added subroutines according to dependency tree (the 'sub_run'
dependency clause). You can turn off this behavior by setting this attribute to
false.

=head2 undo => BOOL (default undef)

If set to 0 or 1, then these things will happen: 1) Prior to running, all added
subroutines will be checked and must have 'undo' or 'reverse' feature, or are
'pure' (see L<Sub::Spec::Clause::features> for more details on specifying
features). 2) '-undo_action' and '-undo_data' special argument will be given
with value 0/1 to each sub supporting undo (or '-reverse' 0/1 for subroutines
supporting reverse). No special argument will be given for pure subroutines.

Additionally, if 'undo' is set to 1, then order_by_dependencies() will reverse
the order of run. This will only be done if 'order_before_run' attribute is set
to true. Otherwise, you might have to do the reversing of order by yourself, if
so desired.

In summary: setting to 0 means run normally, but instruct subroutines to store
undo information to enable undo in the future. Setting to 1 means undo. Setting
to undef (the default) means disregard undo stuffs.

=head2 undo_data_dir => STRING (default ~/.subspec/.undo)

Location to put undo data. See save_undo_data() for more details.

=head2 dry_run => BOOL (default 0)

If set to 0 or 1, then these things will happen: 1) Prior to running, all added
subroutines will be checked and must have 'dry_run' feature, or are 'pure' (see
L<Sub::Spec::Clause::features> for more details on specifying features). 2)
'-dry_run' special argument will be given with value 0/1 to each sub supporting
dry run. No special argument will be given for pure subroutines.

=head1 METHODS

=head2 $runner->get_spec($subname) => SPEC

Get spec for sub named $subname. Will be called by add(). Can be overriden to
provide your own specs other than from %SPECS package variables.

=head2 $runner->add($subname[, $args])

Add subroutine to the set of subroutines to be run. Example:

 $runner->add('Package::subname');

Will first get the sub spec by loading the module and read the %SPEC package var
(this behavior can be changed by overriding get_spec()). Will not load modules
if 'load_modules' attribute is false. Will die if cannot get spec.

After that, it will check dependencies (the 'deps' spec clause) and die if some
dependencies are unmet. All subroutine names mentioned in 'run_sub' dependency
clause will also be add()-ed automatically.

=head2 $runner->order_by_dependencies()

Reorder set of subroutines by dependencies. Normally need not be called manually
since it will be caled by run() prior to running subroutines, but if you turn
off 'order_before_run' attribute, you'll need to call this method explicitly if
you want ordering.

Will return a true value on success, or false if dependencies cannot be resolved
(e.g. there is circular dependency).

=head2 $runner->todo_subs() => ARRAYREF

Return the current list of subroutine names not yet runned, in order. Previously
run subroutines can belong to this list again if repeat()-ed.

=head2 $runner->done_subs() => ARRAYREF

Return the current list of subroutine names already run, in order. Never-run
subroutines can belong to this list too if skip()-ed.

=head2 $runner->run() => [STATUSCODE, ERRMSG, RESULT]

Run (call) a set of subroutines previously added by add().

First it will check 'undo' attribute. If defined, then all added subroutines are
required to have undo/reverse/pure feature or otherwise run() will immediately
return with error 412.

Then it will check 'dry_run' attribute. If true, then all added subroutines are
required to have dry_run/pure feature or otherwise run() will immediately return
with error 412.

After that it will call order_by_dependencies() to reorder the subroutines
according to dependency order. This can be turned off via setting
'order_before_run' attribute to false.

After that, it will call pre_run(), which you can override. pre_run() must
return true, or run() will immediately return with 412 error.

Then it will call each subroutine successively. Each subroutine will be called
with arguments specified in 'common_args' attribute and args specified in add(),
with one extra special argument, '-runner' which is the runner object.

Before running a subroutine: pre_sub() will be called. It must return true, or
run() will immediately return with 500 error. If 'undo' attribute is set to
true, get_undo_data() will be called to get undo data (see get_undo_data() for
more details on customizing storage of undo data).

The subroutine being run can see the status/result of other subroutines by
calling $runner->done($subname), $runner->result($subname). It can share data by
using $runner->stash(). It can also repeat/skip some subroutines by calling
$runner->skip(), skip_all(), repeat(), repeat_all(), branch_done(). It can jump
to other subroutines using $runner->jump(). See the respective method
documentation for more details.

After running a subroutine: Runner will store the return value of each
subroutine. Exception from subroutine will be trapped by eval() and upon
exception return value of subroutine is assumed to be 500.

If subroutine runs successfully: if 'undo' attribute is defined and false
(meaning normal run but save undo information), save_undo_data() will be called
to save undo information (see save_undo_data() for more details on customizing
storage of undo data). If 'undo' attribute is true, remove_undo_data() will be
called to remove undo information.

After that, post_sub() will be called. It must return true, or run() will
immediately return with 500 error.

If 'stop_on_sub_errors' attribute is set to true (the default), then if the
subroutine returns a non-success result, run() will immediately exit with that
result. The meaning of subroutine's success can be changed by overriding
success_res() (by default, all 2xx and 3xx are considered success).

After all subroutines have been run (or skipped), run() will call post_run()
which must return true. Otherwise run() will immediately exit with 500 status.

After that, run() will return the summary in RESULT (number of subroutines run,
skipped, successful, etc). It will return status 200 if there are at least one
subroutine returning success, or 500 otherwise.

=head2 $runner->format_subname($subname) => STR

Can be used to format info log message: "Running XXX ..." when about to run a
subroutine inside run(). Default is "Running Package::bar ..." (just the
subname)

=head2 $runner->success_res($res) => BOOL

By default, all responses with 2xx and 3xx are assumed as a success. You can
override this.

=head2 $runner->pre_run() => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->pre_sub() => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->get_undo_data($subname, $args) => $undo_data

Get undo data. The default implementation loads from file (see save_undo_data()
for more details). You can override this method or just set 'undo_data_dir' to
the desired location.

=head2 $runner->save_undo_data($subname, $args, $undo_data)

Save undo data. The default implementation saves undo data in YAML file under
directory specified by 'undo_data_dir', one file per subname, the file being
named <subname>.yaml ("::" replaced with by "." because it is not valid in some
filesystems). You can override this method or just set 'undo_data_dir' to the
desired location.

=head2 $runner->remove_undo_data($subname, $args)

Remove undo data.

=head2 $runner->post_sub() => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->post_run() => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->result(SUBNAME) => RESULT

Return the result of run subroutine named SUBNAME. If subroutine is not run yet,
will return undef. Will die if subroutine is not in the list of added
subroutines.

=head2 $runner->done(SUBNAME[, VALUE]) => OLDVAL

If VALUE is set, set a subroutine to be done/not done. Otherwise will return the
current done status of SUBNAME. Will die if subroutine named SUBNAME is not in
the list of added subs.

SUBNAME can also be a regex, which means all subroutines matching the regex. The
last SUBNAME's current done status will be returned.

=head2 $runner->skip(SUBNAME)

Alias for done(SUBNAME, 1).

=head2 $runner->skip_all()

Alias for skip(qr/.*/, 1).

=head2 $runner->repeat(SUBNAME)

Alias for done(SUBNAME, 0).

=head2 $runner->repeat_all()

Alias for repeat(qr/.*/, 1).

=head2 $runner->branch_done(SUBNAME, VALUE)

Just like done(), except that will set SUBNAME *and all its dependants*.
Example: if a depends on b and b depends on c, then doing branch_done(c, 1) will
also set a & b as done.

SUBNAME must be a string and not regex.

=head2 $runner->jump($subname)

Jump to another subname. Can be called in pre_sub() or inside subroutine or
post_sub().

=head2 $runner->stash(NAME[, VALUE]) => OLDVAL

Get/set stash data. This is a generic place to share data between subroutines
being run.

=head1 FAQ

=head2 What is the point of this module?

L<Sub::Spec> allows us to add various useful metadata to subroutines, like
dependencies and specific features. Sub::Spec::Runner utilizes this information
to make calling subroutines a bit more like running programs/installing software
packages, e.g.:

=over 4

=item * checking requirements prior to calling a subroutine;

For example, you can specify that backup_db() requires the program
"/usr/bin/mysqldump".

=item * reordering list of subroutines to run according to interdependencies;

You can specify that a() and b() must be run before c(), d() must be run before
c(), and so on. The runner will automatically resolve dependencies by loading
required modules and reorder subroutine execution.

=item * running in dry-run mode;

See 'dry_run' attribute for more details.

=item * running in undo mode;

See 'undo' attribute for mor details.

=item * summary/statistics;

Including the number of subroutines run, number of successes/failures, etc.

=back

=head2 What are some of the applications for this module?

L<Sub::Spec::CmdLine> uses this module in a straightforward way.
Sub::Spec::CmdLine allows you to run subroutines from the command-line.

Our Spanel project uses this module to run "setuplets", which are hosting server
setup routines broken down to smaller bits. Each bit can be run individually (in
dry-run and/or undo mode) but dependencies will always be respected (e.g.
setuplets A requires running B, so running only A will always run B first).

=head1 SEE ALSO

L<Sub::Spec>

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__

