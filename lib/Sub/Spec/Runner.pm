package Sub::Spec::Runner;
BEGIN {
  $Sub::Spec::Runner::VERSION = '0.18';
}
# ABSTRACT: Run subroutines

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use JSON;
use Moo;
use Sub::Spec::Utils; # temp, for _parse_schema
use YAML::Syck;

my $json = JSON->new->allow_nonref;


# [subname=>..., args=>..., key=>..., done=>1|0, spec=>SPEC,
# fldeps=>FLATTENED_DEPS, ...}, ...], the list of subroutines to run, with their
# data and status. key is either SUBNAME or SUBNAME|json(ARGS) (if
# allow_add_same_sub is true)
has _queue  => (is => 'rw', default=>sub{[]});

# index to _queue, the current running subroutine
has _i         => (is => 'rw');

# {key=>item}, i is item in _queue, this is a way to lookup queue by key
has _queue_idx  => (is => 'rw', default=>sub{{}});

# for subroutines to share data
has _stash     => (is => 'rw', default=>sub{{}});

# shorter way to insert custom code rather than subclassing
has _pre_run   => (is => 'rw');
has _post_run  => (is => 'rw');
has _pre_sub   => (is => 'rw');
has _post_sub  => (is => 'rw');



has common_args => (is => 'rw');


has load_modules => (is => 'rw', default=>sub{1});


has stop_on_sub_errors => (is => 'rw', default=>sub{1});


has allow_add_same_sub => (is => 'rw', default=>sub{0});


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


has last_res => (is => 'rw');



sub __parse_schema {
    Sub::Spec::Utils::_parse_schema(@_);
}

# flatten deps clauses by flattening 'all' clauses, effectively change this
# deps clause:
#
#  {
#   run_sub => 's1',
#   all => [
#     {run_sub => 's1'},
#     {deb => {d1=>0, d2=>'>= 0', d3=>'= 1'},
#     {and => [{run_sub => ['s2',{arg=>1}]}, {run_sub=>'s3'}, {deb=>{d3=>0}}],
#   ],
#  },
#
# into:
#
#  {
#   run_sub => ['s1', ['s2'=>{arg=>1}], 's3'],
#   deb => [{d1=>0, d2=>'>= 0', d3=>'= 1'}, {d3=>'0'}],
#  }
#
# clause values will be uniquified in the process (in the above example,
# run_sub=>'s1' was listed twice but flattened into one).
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
            __add_nodupe($res->{$k}, $v);
        }
    }
    $res;
}

sub __add_nodupe {
    my ($ary, $v) = @_;
    for (@$ary) {
        return if __cmp($_, $v);
    }
    push @$ary, $v;
}

# compare like ruby's == (deep)
sub __cmp {
    my ($a, $b) = @_;
    return 1 if !defined($a) && !defined($b);
    return 0 if  defined($a) xor defined($b);
    return $a eq $b if !ref($a) && !ref($b);
    return 0 if ref($a) xor ref($b);
    $json->encode($a) eq $json->encode($b);
}

sub __item_key {
    my ($subname, $args) = @_;
    return $subname . "|" . $json->encode($args);
}

sub _queue_key {
    my ($self, $subname, $args) = @_;
    if ($self->allow_add_same_sub) {
        return __item_key($subname, $args);
    } else {
        return $subname;
    }
}

sub _find_in_queue {
    my ($self, $subname, $args) = @_;

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
    my $key = $self->_queue_key($subname, $args);

    # to avoid deep recursion on circular
    return if exists $self->_queue_idx->{$key};
    $self->_queue_idx->{$key} = undef;

    $log->tracef('-> add(%s, %s)', $subname, $args);

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
        $log->tracef("fldeps = %s", $fldeps);
        #$log->tracef("Checking dependencies ...");
        local $current_runner = $self;
        my $res = Sub::Spec::Clause::deps::check($spec->{deps});
        die "Unmet dependencies for sub $subname: $res\n" if $res;
    }

    my $item = {
        key       => $key,
        subname   => $subname,
        args      => $args,
        spec      => $spec,
        fldeps    => $fldeps,
    };
    push @{ $self->_queue }, $item;
    $self->_queue_idx->{$key} = $item;
    $log->trace("<- add()");
}


sub empty {
    my ($self) = @_;
    $self->_queue([]);
    $self->_queue_idx({});
}


sub order_by_dependencies {
    $log->tracef("-> order_by_dependencies()");
    require Algorithm::Dependency::Ordered;
    require Algorithm::Dependency::Source::HoA;

    my ($self, $reverse) = @_;
    my %deps;
    for my $item (@{ $self->_queue }) {
        $deps{$item->{key}} //= [];
        my $run_sub_deps = $item->{fldeps}{run_sub};
        if ($run_sub_deps) {
            for my $d (@$run_sub_deps) {
                my $key;
                if (ref($d)) {
                    $key = $self->_queue_key($d->[0], $d->[1]);
                } else {
                    $key = $self->_queue_key($d, undef);
                }
                push @{ $deps{$item->{key}} }, $key;
            }
        }
    }

    #$log->tracef("deps for Algorithm::Dependency: %s", \%deps);
    my $ds  = Algorithm::Dependency::Source::HoA->new(\%deps);
    my $ado = Algorithm::Dependency::Ordered->new(
        source   => $ds,
        selected => []
    );
    unless ($ado) {
        $log->error("Failed to set up dependency algorithm");
        return 0;
    }

    my $keys = $ado->schedule_all;
    unless (ref($keys) eq 'ARRAY') {
        $log->error("schedule_all() failed");
        return 0;
    }

    if ($reverse) {
        $log->trace("Reversing order of subroutines ...");
        $keys = [reverse @$keys];
    }

    $log->tracef("result after ordering by dependency: %s", $keys);

    # rebuild _queue
    $self->_queue([]);
    for (@$keys) {
        push @{$self->_queue}, $self->_queue_idx->{$_};
    }

    1;
}


sub todo_items {
    my ($self) = @_;
    [ grep {!$_->{done}} @{$self->_queue} ];
}


sub done_items {
    my ($self) = @_;
    [ grep {$_->{done}} @{$self->_queue} ];
}

sub _log_running_sub {
    my ($self, $subname, $args) = @_;
    $log->infof("Running %s(%s) ...", $self->format_subname($subname), $args);
}


sub run {
    my ($self, %opts) = @_;
    $log->tracef("-> Runner's run(%s)", \%opts);

    return [412, "No items to run, please add() some first"]
        unless @{ $self->_queue };

    my %mem;
    if (defined $self->undo) {
        $log->trace("Checking undo/reverse feature of subroutines ...");
        %mem = ();
        for my $item (@{$self->_queue}) {
            my $subname = $item->{subname};
            next if $mem{$subname};
            my $f = $item->{spec}{features};
            return [412, "Cannot run with undo: $subname doesn't support ".
                        "undo/reverse/pure"]
                unless $f && ($f->{undo} || $f->{reverse} || $f->{pure});
        }
    }

    if ($self->dry_run) {
        $log->trace("Checking dry_run feature of subroutines ...");
        %mem = ();
        for my $item (@{$self->_queue}) {
            my $subname = $item->{subname};
            next if $mem{$subname};
            my $f = $item->{spec}{features};
            return [412, "Cannot run with dry_run: $subname doesn't support ".
                        "dry_run"]
                unless $f && ($f->{dry_run} || $f->{pure});
        }
    }

    if ($self->order_before_run) {
        my $reverse = 0+$self->order_before_run < 0;
        return [412, "Cannot resolve dependencies, please check for circulars"]
            unless $self->order_by_dependencies($reverse);
    }

    my $hook_res;

    eval { $hook_res = $self->pre_run };
    return [412, "pre_run() died: $@"] if $@;
    return [412, "pre_run() didn't return true"] unless $hook_res;

    my $num_success_runs = 0;
    my $num_failed_runs  = 0;
    my %success_subs;
    my %failed_subs;
    my %subs = map {$_->{subname}=>1} @{$self->_queue};
    my %success_items;
    my %failed_items;
    my $res;

  RUN:
    while (1) {
        $self->{_i} = -1;
        my $some_not_done;
        my $jumped;
        while (1) {
            $self->{_i}++ unless $jumped;
            $jumped = 0;
            last unless $self->{_i} < @{ $self->_queue };
            my $item    = $self->_queue->[ $self->{_i} ];
            next if $item->{done};
            my $subname = $item->{subname};
            my $spec    = $item->{spec};
            my $args    = $item->{args};

            $some_not_done++;
            $self->_log_running_sub($subname, $args);

            my $orig_i = $self->{_i};
            eval { $hook_res = $self->pre_sub($subname, $args) };
            if ($@) {
                $res = [500, "pre_sub() died: $@"];
                last RUN;
            }
            unless ($hook_res) {
                $res = [500, "pre_sub() didn't return true"];
                last RUN;
            }
            next if $item->{done}; # pre_sub might skip this sub
            $jumped = $orig_i != $self->{_i};

            if ($jumped) {
                last unless $self->{_i} < @{ $self->_queue };
            }

            $orig_i = $self->{_i};
            my $item_res = $self->_run_item($item);
            $self->last_res($item_res);
            $item->{res} = $item_res;
            if ($self->success_res($item_res)) {
                $num_success_runs++;
                $success_subs{$subname}++;
                $success_items{$self->{_i}}++;
                delete ($failed_subs{$subname});
                delete ($failed_items{$self->{_i}});
            } else {
                $num_failed_runs++;
                $failed_subs{$subname}++;
                $failed_items{$self->{_i}}++;
                delete ($success_subs{$subname});
                delete ($success_items{$self->{_i}});
                if ($self->stop_on_sub_errors) {
                    last RUN;
                }
            }
            $item->{done} = 1;
            $jumped = $orig_i != $self->{_i};

            if ($jumped) {
                last unless $self->{_i} < @{ $self->_queue };
            }

            $orig_i = $self->{_i};
            eval { $hook_res = $self->post_sub($subname, $args) };
            if ($@) {
                $res = [500, "post_sub() died: $@"];
                last RUN;
            }
            unless ($hook_res) {
                $res = [500, "post_sub() didn't return true"];
                last RUN;
            }
            $jumped = $orig_i != $self->{_i};
        }
        last unless $some_not_done;
    } # RUN:

    if (!$res) {
        eval { $hook_res = $self->post_run };
        if ($@) {
            $res = [500, "post_run() died: $@"];
        } elsif (!$hook_res) {
            $res = [500, "post_run() didn't return true"];
        }
    }

    my $num_items         = scalar(@{$self->_queue});
    my $num_subs          = scalar(keys %subs);
    my $num_success_subs  = scalar(keys %success_subs );
    my $num_failed_subs   = scalar(keys %failed_subs  );
    my $num_success_items = scalar(keys %success_items);
    my $num_failed_items  = scalar(keys %failed_items );

    $res->[2] = {
        num_success_runs   => $num_success_runs,
        num_failed_runs    => $num_failed_runs,
        num_runs           => $num_success_runs+$num_failed_runs,

        num_success_subs   => $num_success_subs,
        num_failed_subs    => $num_failed_subs,
        num_subs           => $num_subs,
        num_run_subs       => $num_success_subs+$num_failed_subs,
        num_skipped_subs   => $num_subs-($num_success_subs+$num_failed_subs),

        num_success_items  => $num_success_items,
        num_failed_items   => $num_failed_items,
        num_items          => $num_items,
        num_run_items      => $num_success_items+$num_failed_items,
        num_skipped_items  => $num_items-($num_success_items+$num_failed_items),
    };

    if (!$res->[0]) {
        if ($num_success_items + $num_failed_items == 0) {
            $res->[0] = 200;
            $res->[1] = "All skipped";
        } elsif ($num_success_items) {
            if ($num_failed_items) {
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

    if ($opts{use_last_res} && $self->last_res) {
        $log->tracef("Summary result not used because use_last_res option ".
                         "is true. Displaying it here: %s", $res);
        $res = $self->last_res;
    }

    $log->tracef("<- Runner's run(), res=%s", $res);
    $res;
}

sub _run_item {
    my ($self, $item) = @_;
    my $subname = $item->{subname};
    $log->tracef("-> _run_item(subname=%s, args=%s)", $subname, $item->{args});
    my $res;
    eval {
        my ($module, $sub) = $subname =~ /(.+)::(.+)/;
        my $fref = \&{"$module\::$sub"};
        unless ($fref) {
            $res = [500, "No sub \&$subname defined"];
            return; # exit eval
        }

        my $spec = $item->{spec};

        my %all_args;
        my $common_args = $self->common_args // {};
        for (keys %$common_args) {
            $all_args{$_} = $common_args->{$_} if !$spec->{args} ||
                $spec->{args}{$_};
        }
        for (keys %{$item->{args} // {}}) {
            $all_args{$_} = $item->{args}{$_};
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
                    my $undo_data = $self->get_undo_data(
                        $subname, $args_for_undo);
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
        $res = [200, "OK (naked)", $res] if $spec->{result_naked};
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
    $log->tracef("<- _run_item(%s), res=%s", $subname, $res);
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

sub _find_items {
    my $self = shift;
    #$log->tracef("=> _find_items(%s)", \@_);
    my $subname = shift;
    my $has_args;
    my $args;
    if (@_) {
        $has_args++;
        $args = shift;
    }

    $subname = __normalize_subname($subname) unless ref($subname);

    my @res;
    for my $item (@{$self->_queue}) {
        if (ref($subname) eq 'Regexp') {
            next unless $item->{subname} =~ /$subname/;
        } else {
            next unless $item->{subname} eq $subname;
        }
        if ($has_args) {
            next unless __cmp($item->{args}, $args);
        }
        push @res, $item;
    }
    @res;
}

sub _find_items_and_dependants {
    my ($self, $subname, $args, $res) = @_;
    $log->tracef("=> _find_items_and_dependants(%s)", \@_);
    if (!$res) {
        my @items = $self->_find_items($subname, $args);
        $res = \@items;
    }
    my %res_keys     = map {__item_key($_->{subname}, $_->{args})=>1} @$res;
    my %res_subnames = map {$_->{subname}=>1} @$res;
    #my %spec_mem;
    for my $qitem (@{$self->_queue}) {
        my $qkey = __item_key($qitem->{subname}, $qitem->{args});
        #next if $spec_mem{$qitem->{subname}}++;
        next if $res_keys{$qkey};  # qitem already in $res
        my $run_sub_deps = $qitem->{fldeps}{run_sub};
        next unless $run_sub_deps;
        for my $d (@$run_sub_deps) {
            #$log->tracef("dep: %s", $d);
            my $dkey;
            if (ref($d)) {
                $dkey = __item_key($d->[0], $d->[1]);
                next unless $res_keys{$dkey};
                push @$res, $qitem;
                $self->_find_items_and_dependants($d->[0], $d->[1], $res);
            } else {
                next unless $res_subnames{$d};
                push @$res, $qitem;
                $self->_find_items_and_dependants($d, undef, $res);
                $dkey = __item_key($d, undef);
            }
            $res_keys{$dkey}++;
            $res_subnames{$d}++;
        }
    }
    $res;
}


sub result {
    my ($self, $subname, $args) = @_;
    my @items = $self->_find_items($subname, $args);
    return unless @items;
    $items[0]->{res};
}


sub is_done {
    my ($self, $subname, $args) = @_;
    my @items = $self->_find_items($subname, $args);
    return unless @items;
    $items[0]->{done};
}


sub done {
    my ($self, $subname, $args, $newval) = @_;
    my @items = $self->_find_items($subname, $args);
    return unless @items;
    if (defined $newval) {
        for (@items) {
            $log->tracef("%s %s(%s)", $newval ? "Skipping":"Repeating",
                    $_->{subname}, $_->{args});
            $_->{done} = $newval;
        }
    }
    $items[-1]->{done};
}


sub skip {
    my ($self, $subname, $args) = @_;
    $self->done($subname, $args, 1);
}


sub skip_all {
    my ($self) = @_;
    $_->{done} = 1 for @{$self->_queue};
}


sub repeat {
    my ($self, $subname, $args) = @_;
    $self->done($subname, $args, 0);
}


sub repeat_all {
    my ($self) = @_;
    $_->{done} = 0 for @{$self->_queue};
}


sub done_branch {
    my ($self, $subname, $args, $newval) = @_;
    my $items = $self->_find_items_and_dependants($subname, $args);
    $log->debugf("items = %s", $items);
    return unless @$items;
    if (defined $newval) {
        for (@$items) {
            $log->tracef("%s %s(%s)", $newval ? "Skipping":"Repeating",
                    $_->{subname}, $_->{args});
            $_->{done} = $newval;
        }
    }
}


sub skip_branch {
    my ($self, $subname, $args) = @_;
    $self->done_branch($subname, $args, 1);
}


sub repeat_branch {
    my ($self, $subname, $args) = @_;
    $self->done_branch($subname, $args, 0);
}


sub jump {
    my ($self, $subname, $args) = @_;
    my @items = $self->_find_items($subname, $args);
    die "Can't jump($subname, args), item not found" unless @items;
    my $item = $items[0];
    for my $i (0..@{$self->_queue}-1) {
        if ($item->{key} eq $self->_queue->[$i]{key}) {
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
  $Sub::Spec::Clause::deps::VERSION = '0.18';
}
# XXX adding run_sub should be done locally, and also modifies the spec schema
# (when it's already defined). probably use a utility function add_dep_clause().

sub check_run_sub {
    my ($cval) = @_;
    my $runner = $Sub::Spec::Runner::current_runner;
    if (!ref($cval)) {
        $runner->add($cval);
    } elsif (ref($cval) eq 'ARRAY') {
        die "Deps clause usage: run_sub=>[SUBNAME,ARGS]" unless
            !ref($cval->[0]) &&
                (!defined($cval->[1]) || ref($cval->[1]) eq 'HASH');
        $runner->add($cval->[0], $cval->[1]);
    } else {
        die "Deps clause usage: run_sub=>SUBNAME, or run_sub=>[SUBNAME,ARGS]";
    }
    "";
}

1;


=pod

=head1 NAME

Sub::Spec::Runner - Run subroutines

=head1 VERSION

version 0.18

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

This module parses the 'run_sub' deps clause in L<Sub::Spec> spec. It allows
specifying dependency of a subroutine to another subroutine. It accept fully
qualified subroutine name as value, or a 2-element array containing the
subroutine name and its arguments. The depended subroutine will be add()-ed to
the runner. Example:

 run_sub => 'main::func2'

 run_sub => ['My::Other::func', {arg1=>1, arg2=>2}]

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

=head2 allow_add_same_sub => BOOL (default 0)

If this attribute is set to 0 (the default), then if you add() the same
subroutine more than once, even with different argument, then the subsequent add
will be ignored. For example:

 $runner->add('sub1', {arg1=>1}); # 'sub1' added
 $runner->add('sub1', {arg1=>2}); # not added

If this attribute is set to 1, then you can add() the same subroutine more than
once but with different arguments.

 $runner->add('sub1', {arg1=>1}); # 'sub1' added with args: {arg1=>1}
 $runner->add('sub1', {arg1=>2}); # 'sub1' added again with args: {arg1=>2}

=head2 order_before_run => BOOL (default 1)

Before run() runs the subroutines, it will call order_by_dependencies() to
reorder the added subroutines according to dependency tree (the 'sub_run'
dependency clause). You can turn off this behavior by setting this attribute to
false.

If this attribute is a true but negative value, then the order will be reversed.

=head2 undo => BOOL (default undef)

If set to 0 or 1, then these things will happen: 1) Prior to running, all added
subroutines will be checked and must have 'undo' or 'reverse' feature, or are
'pure' (see L<Sub::Spec::Clause::features> for more details on specifying
features). 2) '-undo_action' and '-undo_data' special argument will be given
with value 0/1 to each sub supporting undo (or '-reverse' 0/1 for subroutines
supporting reverse). No special argument will be given for pure subroutines.

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

=head2 last_res => RESULT

This attribute will be set by run() to be the result of each item after running
each item.

=head1 METHODS

=head2 $runner->get_spec($subname) => SPEC

Get spec for sub named $subname. Will be called by add(). Can be overriden to
provide your own specs other than from %SPECS package variables.

=head2 $runner->add($subname[, $args])

Add subroutine to the queue of subroutines to be run. Example:

 $runner->add('Package::subname');
 $runner->add('Package::anothersub', {arg=>1});

Will first load the module (unless load_modules attribute to false). Then
attempt to get the sub spec by reading the %SPEC package var (this behavior can
be changed by overriding get_spec()). Will die if cannot get spec.

After that, it will check dependencies (the 'deps' spec clause) and die if some
dependencies are unmet. All subroutine names mentioned in 'run_sub' dependency
clause will also be add()-ed automatically, recursively.

If the same subroutine is added twice, then it will only be queued once, unless
allow_add_same_sub attribute is true, in which case duplicate subroutine name
can be added as long as the arguments are different.

=head2 $runner->empty()

Empty all items in the queue. This is the opposite of what add() does.

=head2 $runner->order_by_dependencies()

Reorder set of subroutines by dependencies. Normally need not be called manually
since it will be caled by run() prior to running subroutines, but if you turn
off 'order_before_run' attribute, you'll need to call this method explicitly if
you want ordering.

Will return a true value on success, or false if dependencies cannot be resolved
(e.g. there is circular dependency).

=head2 $runner->todo_items() => ARRAYREF

Return the items in queue not yet run, in order. Previously run subroutines
can belong to this list again if repeat()-ed.

=head2 $runner->done_items() => ARRAYREF

Return the items in queue already run. Never-run subroutines can belong to this
list too if skip()-ed.

=head2 $runner->run(%opts) => [STATUSCODE, ERRMSG, RESULT]

Run (call) the queue of subroutines previously added by add().

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

Then it will call each item in the queue successively. Each subroutine will be
called with arguments specified in 'common_args' attribute and args specified in
add(), with one extra special argument, '-runner' which is the runner object.

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

Options for run(), %opts:

=over 4

=item * use_last_res => BOOL

Default is false. If set to true, then instead of returning statistics/summary
result, run() will return the last item's result.

=back

=head2 $runner->format_subname($subname) => STR

Can be used to format info log message: "Running XXX ..." when about to run a
subroutine inside run(). Default is "Running Package::bar ..." (just the
subname)

=head2 $runner->success_res($res) => BOOL

By default, all responses with 2xx and 3xx are assumed as a success. You can
override this.

=head2 $runner->pre_run() => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->pre_sub($subname, $args) => BOOL

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

=head2 $runner->post_sub($subname, $args) => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->post_run() => BOOL

See run() for more details. Can be overridden by subclass.

=head2 $runner->result($subname[, $args]) => RESULT

Return the result of run subroutine named SUBNAME. If subroutine is not run yet,
will return undef.

If there are multiple items matching $subname, only the first item's result will
be returned.

=head2 $runner->is_done($subname[, $args]) => BOOL

Check whether an item is already run/done.

=head2 $runner->done(SUBNAME[, ARGS[, VALUE]]) => OLDVAL

If VALUE is set, set a subroutine to be done/not done. Otherwise will return the
current done status of SUBNAME.

SUBNAME can also be a regex, which means all subroutines matching the regex. The
last SUBNAME's current done status will be returned.

=head2 $runner->skip(SUBNAME[, ARGS])

Alias for done(SUBNAME, ARGS, 1).

=head2 $runner->skip_all()

Skip all subroutines.

=head2 $runner->repeat(SUBNAME[, ARGS])

Alias for done(SUBNAME, ARGS, 0).

=head2 $runner->repeat_all()

Repeat all subroutines.

=head2 $runner->done_branch(SUBNAME, ARGS, VALUE)

Just like done(), except that will set SUBNAME *and all its dependants*.
Example: if a depends on b and b depends on c, then doing branch_done('c',
undef, 1) will also set a & b as done.

=head2 $runner->skip_branch(SUBNAME[, ARGS])

Alias for done_branch(SUBNAME, ARGS, 1).

=head2 $runner->repeat_branch(SUBNAME[, ARGS])

Alias for done_branch(SUBNAME, ARGS, 0).

=head2 $runner->jump($subname, $args)

Jump to another item. Can be called in pre_sub() or inside subroutine or
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

