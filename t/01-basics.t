#!perl

use 5.010;
use strict;
use warnings;
use Log::Any '$log';
use Test::More 0.96;

use Capture::Tiny qw(capture);
use Sub::Spec::Runner;

package Foo;
use 5.010;
our %SPEC;

$SPEC{a} = {deps=>{run_sub=>"Foo::b"}, args=>{alt=>"bool"}};
sub a {
    my %args=@_;
    print "A".($args{alt} ? "x" : "");
    [200, "OK", "apple"];
}
$SPEC{b} = {deps=>{all=>[{run_sub=>"Foo::c"},{run_sub=>"Foo::d"}]}};
sub b {
    my %args=@_;
    print "B".($args{alt} ? "x" : "");
    [200, "OK", "banana"];
}
$SPEC{c} = {deps=>{all=>[{run_sub=>"Foo::d"}, {run_sub=>"Foo::e"}]},
            args=>{alt=>"bool"}};
sub c {
    my %args=@_;
    print "C".($args{alt} ? "x" : "");
    [200, "OK", "cherry"];
}
$SPEC{d} = {deps=>{run_sub=>"Foo::e"}, args=>{}}; # won't supplied with args
sub d {
    my %args=@_;
    print "D".($args{alt} ? "x" : "");
    [200, "OK", "date"];
}
$SPEC{e} = {};
sub e {
    print "E";
    [304, "OK", "eggplant"];
}

$SPEC{read_ctx} = {deps=>{run_sub=>"Foo::a"}};
sub read_ctx {
    my %args=@_;
    my $ctx=$args{-ctx};
    my $res_a = $ctx->sub_res("Foo::a");
    #use Data::Dump qw(dump); open F, ">>/tmp/ctx"; print F dump($ctx); close F;
    if ($ctx->sub_res("Foo::a")->[2] eq 'avocado' &&
            $ctx->sub_res("Foo::b")->[2] eq 'blueberry') {
        return [200, "OK"];
    } else {
        return [500, "Failed"];
    }
}

# for testing stop_on_sub_errors
$SPEC{i} = {deps=>{run_sub=>"Foo::j"}};
sub i {
    print "I";
    [304, "OK"];
}
$SPEC{j} = {};
sub j {
    print "J";
    [450, "Failed"];
}

$SPEC{circ1} = {deps=>{run_sub=>"Foo::circ2"}};
sub circ1 {
    [200, "OK"];
}
$SPEC{circ2} = {deps=>{run_sub=>"Foo::circ1"}};
sub circ2 {
    [200, "OK"];
}

$SPEC{z} = {deps=>{run_sub=>"nonexisting"}};
sub z {
    [200, "OK"];
}

$SPEC{unmet} = {deps=>{code=>sub{0}}};
sub unmet {
    [200, "OK"];
}

package Bar;
sub a { [200, "OK"] }
sub b { [200, "OK"] }

package main;

our %SPEC;
$SPEC{x} = {};
sub x {}

test_run(
    name          => 'normalize subname (add(x) becomes add(main::x))',
    subs          => ['x'],
    test_before_run => sub {
        my ($runner) = @_;
        $runner->_sub_list->[0] eq 'main::x';
    }
);
test_run(
    name          => 'normalize subname (add(::x) becomes add(main::x))',
    subs          => ['::x'],
    test_before_run => sub {
        my ($runner) = @_;
        $runner->_sub_list->[0] eq 'main::x';
    }
);

test_run(
    name          => 'no subs',
    subs          => [],
    status        => 400,
);
test_run(
    name          => 'single sub',
    subs          => ['Foo::a'],
    status        => 200,
    num_runs      => 5, num_success_runs => 5, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 5, num_failed_subs  => 0,
    num_run_subs  => 5, num_skipped_subs => 0,
    output_re     => qr/^EDCBA$/,
    test_after_run => sub {
        my ($runner) = @_;
        is_deeply($runner->_find_dependants('Foo::c'),
                  ['Foo::c', 'Foo::b', 'Foo::a'],
                  "_find_dependants 1");
        my $a = $runner->stash("a");
        ok(!$a, "stash default to undef");
        $a = $runner->stash("a", 1);
        ok(!$a, "stash returns old value");
        $a = $runner->stash("a");
        is($a, 1, "stash can set value");
    },
);

test_run(
    name          => 'single sub (no dependency)',
    subs          => ['Foo::e'],
    status        => 200,
    num_runs      => 1, num_success_runs => 1, num_failed_runs  => 0,
    num_subs      => 1, num_success_subs => 1, num_failed_subs  => 0,
    num_run_subs  => 1, num_skipped_subs => 0,
    output_re     => qr/^E$/,
);

test_run(
    name          => 'multiple subs',
    subs          => ['Foo::d', 'Foo::c'],
    status        => 200,
    num_runs      => 3, num_success_runs => 3, num_failed_runs  => 0,
    num_subs      => 3, num_success_subs => 3, num_failed_subs  => 0,
    num_run_subs  => 3, num_skipped_subs => 0,
    output_re     => qr/^EDC$/,
);

test_run(
    name          => 'args',
    subs          => ['Foo::a'],
    args          => {alt=>1},
    status        => 200,
    num_runs      => 5, num_success_runs => 5, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 5, num_failed_subs  => 0,
    num_run_subs  => 5, num_skipped_subs => 0,
    output_re     => qr/^EDCxBxAx$/,
);

test_run(
    name          => 'unmet dependencies',
    subs          => ['Foo::unmet'],
    add_dies      => 1,
);
test_run(
    name          => 'cant resolve deps (circular)',
    subs          => ['Foo::circ1'],
    status        => 412,
);
test_run(
    name          => 'cant resolve deps (missing dep)',
    subs          => ['Foo::z'],
    add_dies      => 1,
);

test_run(
    name          => 'stop_on_sub_errors on',
    subs          => ['Foo::i'],
    status        => 450,
    num_runs      => 1, num_success_runs => 0, num_failed_runs  => 1,
    num_subs      => 2, num_success_subs => 0, num_failed_subs  => 1,
    num_run_subs  => 1, num_skipped_subs => 1,
    output_re     => qr/J/,
);
test_run(
    name          => 'stop_on_sub_errors off',
    subs          => ['Foo::i'],
    stop_on_sub_errors => 0,
    status        => 200,
    num_runs      => 2, num_success_runs => 1, num_failed_runs  => 1,
    num_subs      => 2, num_success_subs => 1, num_failed_subs  => 1,
    num_run_subs  => 2, num_skipped_subs => 0,
    output_re     => qr/JI/,
);
test_run(
    name          => 'stop_on_sub_errors off (all failed)',
    subs          => ['Foo::j'],
    stop_on_sub_errors => 0,
    status        => 500,
    num_runs      => 1, num_success_runs => 0, num_failed_runs  => 1,
    num_subs      => 1, num_success_subs => 0, num_failed_subs  => 1,
    num_run_subs  => 1, num_skipped_subs => 0,
    output_re     => qr/J/,
);

test_run(
    name          => 'pre_run returns false',
    runner_args   => {_pre_run=>sub {0}},
    subs          => ['Foo::a'],
    status        => 412,
);
test_run(
    name          => 'exception in pre_run trapped',
    runner_args   => {_pre_run=>sub {die}},
    subs          => ['Foo::a'],
    status        => 412,
);

test_run(
    name          => 'post_run returns false',
    runner_args   => {_post_run=>sub {0}},
    subs          => ['Foo::a'],
    status        => 500,
    num_runs      => 5, num_success_runs => 5, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 5, num_failed_subs  => 0,
    num_run_subs  => 5, num_skipped_subs => 0,
    #output_re     => qr/EDCBA/,
);
test_run(
    name          => 'exception in post_run trapped',
    runner_args   => {_post_run=>sub {die}},
    subs          => ['Foo::a'],
    status        => 500,
    num_runs      => 5, num_success_runs => 5, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 5, num_failed_subs  => 0,
    num_run_subs  => 5, num_skipped_subs => 0,
    #output_re     => qr/EDCBA/,
);

test_run(
    name          => 'pre_sub',
    runner_args   => {_pre_sub=>sub {
                          my($self, $subname) = @_;
                          $subname eq 'Foo::c' ? 0:1;
                      }},
    subs          => ['Foo::a'],
    status        => 500,
    num_runs      => 2, num_success_runs => 2, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 2, num_failed_subs  => 0,
    num_run_subs  => 2, num_skipped_subs => 3,
);
test_run(
    name          => 'exception in pre_sub trapped',
    runner_args   => {_pre_sub=>sub {
                          my($self, $subname) = @_;
                          if ($subname eq 'Foo::c') { die }
                          1;
                      }},
    subs          => ['Foo::a'],
    status        => 500,
    num_runs      => 2, num_success_runs => 2, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 2, num_failed_subs  => 0,
    num_run_subs  => 2, num_skipped_subs => 3,
);

test_run(
    name          => 'post_sub',
    runner_args   => {_post_sub=>sub {
                          my($self, $subname) = @_;
                          $subname eq 'Foo::c' ? 0:1;
                      }},
    subs          => ['Foo::a'],
    status        => 500,
    num_runs      => 3, num_success_runs => 3, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 3, num_failed_subs  => 0,
    num_run_subs  => 3, num_skipped_subs => 2,
);
test_run(
    name          => 'exception in post_sub trapped',
    runner_args   => {_post_sub=>sub {
                          my($self, $subname) = @_;
                          if ($subname eq 'Foo::c') { die }
                          1;
                      }},
    subs          => ['Foo::a'],
    status        => 500,
    num_runs      => 3, num_success_runs => 3, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 3, num_failed_subs  => 0,
    num_run_subs  => 3, num_skipped_subs => 2,
);

test_run(
    name          => 'skip in pre_sub',
    runner_args   => {_pre_sub=>sub {
                          my($self, $subname) = @_;
                          if ($subname eq 'Foo::c') {
                              $self->skip('Foo::a');
                              $self->skip(qr/[cb]/);
                          }
                          1;
                      }},
    subs          => ['Foo::a'],
    status        => 200,
    num_runs      => 2, num_success_runs => 2, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 2, num_failed_subs  => 0,
    num_run_subs  => 2, num_skipped_subs => 3,
);
test_run(
    name          => 'skip in post_sub',
    runner_args   => {_post_sub=>sub {
                          my($self, $subname) = @_;
                          if ($subname eq 'Foo::c') {
                              $self->skip('Foo::a');
                              $self->skip(qr/[cb]/);
                          }
                          1;
                      }},
    subs          => ['Foo::a'],
    status        => 200,
    num_runs      => 3, num_success_runs => 3, num_failed_runs  => 0,
    num_subs      => 5, num_success_subs => 3, num_failed_subs  => 0,
    num_run_subs  => 3, num_skipped_subs => 2,
);
# XXX test skip inside sub?
test_run(
    name          => 'skip(unknown) -> dies',
    runner_args   => {_post_sub=>sub {
                          my($self, $subname) = @_;
                          $self->skip('Foo::a');
                          1;
                      }},
    subs          => ['Foo::e'],
    status        => 500,
);

test_run(
    name          => 'jump',
    runner_args   => {_post_sub=>sub {
                          my($self, $subname) = @_;
                          if ($subname eq 'Foo::c') {
                              $self->jump('Foo::a');
                          }
                          1;
                      }},
    subs          => ['Foo::a'],
    status        => 200,
    output_re     => qr/^EDCAB$/,
);
test_run(
    name          => 'jump(unknown) -> dies',
    runner_args   => {_post_sub=>sub {
                          my($self, $subname) = @_;
                          $self->jump('xxx');
                          1;
                      }},
    subs          => ['Foo::e'],
    status        => 500,
);

test_run(
    name          => 'branch_done',
    runner_args   => {_pre_sub=>sub {
                          my($self, $subname) = @_;
                          if ($subname eq 'Foo::c') {
                              $self->branch_done('Foo::c', 1);
                          }
                          1;
                      }},
    subs          => ['Foo::a'],
    status        => 200,
    output_re     => qr/^ED$/,
);

test_run(
    name          => 'result',
    subs          => ['Foo::d'],
    status        => 200,
    test_after_run => sub {
        my ($runner) = @_;
        is_deeply($runner->result('Foo::e'), [304, "OK", "eggplant"],
                  "result(e)");
        is_deeply($runner->result('Foo::d'), [200, "OK", "date"],
                  "result(d)");
        eval { $runner->result('Foo::xxx') };
        ok($@, "result(unknown) -> dies");
    },
);

# XXX test load_modules=1?

done_testing();

sub test_run {
    my (%args) = @_;

    subtest $args{name} => sub {

        my $runner = Sub::Spec::Runner->new(
            %{$args{runner_args} // {}});
        $runner->load_modules(0);
        $runner->args($args{args}) if $args{args};
        $runner->stop_on_sub_errors($args{stop_on_sub_errors})
            if defined($args{stop_on_sub_errors});

        eval {
            $runner->add($_) for @{ $args{subs} };
        };
        my $eval_err = $@;
        if ($args{add_dies}) {
            ok($eval_err, "add dies");
        }

        if ($args{test_before_run}) {
            ok($args{test_before_run}->($runner),
               "test_before_run");
        }

        my $res;
        if ($args{status}) {
            if (defined($args{output_re})) {
                my ($stdout, $stderr) = capture {
                    $res = $runner->run();
                };
                like($stdout // "", $args{output_re}, "output_re")
                    or diag("output is $stdout");
            } else {
                $res = $runner->run();
            }

            if ($args{status}) {
                is($res->[0], $args{status}, "return status = $args{status}") or
                    do { diag explain $res; last };
            }
        }

        for (qw(
                   num_success_runs
                   num_failed_runs
                   num_runs
                   num_success_subs
                   num_failed_subs
                   num_subs
                   num_run_subs
                   num_skipped_subs
           )) {
            if (defined $args{$_}) {
                is($res->[2]{$_}, $args{$_}, $_);
            }
        }

        if ($args{test_res}) {
            ok($args{test_res}->($res), "test_res");
        }

        if ($args{test_after_run}) {
            $args{test_after_run}->($runner);
        }
    };
}

