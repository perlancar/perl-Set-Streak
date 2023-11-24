package Set::Streak;

use 5.010001;
use strict;
use warnings;

use Exporter 'import';

# AUTHORITY
# DATE
# DIST
# VERSION

our @EXPORT_OK = qw(gen_longest_streaks_table);

our %SPEC;

my $re = qr/\A(\d+)\.(.*)\z/;

$SPEC{gen_longest_streaks_table} = {
    v => 1.1,
    summary => 'Generate ranking table of longest streaks',
    description => <<'MARKDOWN',

This routine can be used to generate a ranking table of longest streaks,
represented by sets. You supply a list (arrayref) of `sets`, each set
representing a period. The routine will rank the items that appear the longest
in consecutive sets (periods).

For example, let's generate a table for longest daily CPAN releases for November
2023 up until today (assume today is the Nov 5th), the input will be:

    [
      [qw/PERLANCAR DART JJATRIA NERDVANA LEEJO CUKEBOT RSCHUPP JOYREX TANIGUCHI OODLER OLIVER JV/],     # period 1 (first): list of CPAN authors releasing something on Nov 1, 2023
      [qw/SKIM PERLANCAR BURAK BDFOY SUKRIA AJNN YANGAK CCELSO SREZIC/],                                 # period 2: list of CPAN authors releasing something on Nov 2, 2023
      [qw/JGNI DTUCKWELL SREZIC WOUTER LSKATZ SVW RAWLEYFOW DJERIUS PERLANCAR CRORAA EINHVERFR ASPOSE/], # period 3: list of CPAN authors releasing something on Nov 3, 2023
      [qw/JGNI LEONT LANCEW NKH MDOOTSON SREZIC PERLANCAR DROLSKY JOYREX JRM DAMI PRBRENAN DCHURCH/],    # period 4: list of CPAN authors releasing something on Nov 4, 2023
      [qw/JGNI JRM TEAM LICHTKIND JJATRIA JDEGUEST PERLANCAR SVW DRCLAW PLAIN SUKRIA RSCHUPP/],          # period 5 (current): list of CPAN authors releasing something on Nov 5, 2023
    ]

The result of the routine will be like:

    [
      { item => "PERLANCAR", len => 5, start => 1, status => "ongoing" },
      { item => "SREZIC", len => 3, start => 2, status => "might-break" },
      { item => "JGNI", len => 3, start => 3, status => "ongoing" },
      { item => "JRM", len => 2, start => 4, status => "ongoing" },
      { item => "CUKEBOT", len => 1, start => 1, status => "broken" },
      { item => "DART", len => 1, start => 1, status => "broken" },
      { item => "JJATRIA", len => 1, start => 1, status => "broken" },
      ...
    ]

Sorting is done by `len` (descending) first, then by `start` (ascending), then
by `item` (ascending).

MARKDOWN
    args => {
        sets => {
            schema => 'aoaos*',
            req => 1,
        },
        exclude_broken => {
            summary => 'Whether to exclude broken streaks',
            schema => 'bool*',
            description => <<'MARKDOWN',

Streak status is either: `ongoing` (item still appear in current period),
`might-break` (does not yet appear in current period, but current period is
assumed to have not ended yet, later update might still see item appearing), or
`broken` (no longer appear after its beginning period sometime in the past
periods).

If you set this option to true, streaks that have the status of `broken` are not
returned.

MARKDOWN
        },

        # the advanced options are used for caching streaks data structure and
        # reusing it later for faster update
        raw => {
            summary => 'Instead of streaks table, return the raw streaks hash',
            schema => 'true*',
            tags => ['category:advanced'],
        },
        streaks => {
            summary => 'Initialize streaks hash with this',
            schema => 'hash*',
            tags => ['category:advanced'],
        },
        start_period => {
            schema => 'posint*',
            tags => ['category:advanced'],
        },
    },
    args_rels => {
        req_all => [qw/streaks start_period/],
    },
    result_naked => 1,
};
sub gen_longest_streaks_table {
    my %args = @_;

    my $sets = $args{sets};
    my $prev_period = 0;

    my %streaks; # list of all streaks, key="<starting period>.<item name>", value=[length, broken in which period]

  INIT_STREAKS:
    if ($args{streaks}) {
        %streaks = %{ $args{streaks} };
        for my $key (keys %streaks) {
            my $streak = $streaks{$key};
            my ($start, $item) = $key =~ $re or die;
            my $p = $start + $streak->[0] - 1;
            $prev_period = $p if $prev_period < $p;
        }
    }

  INIT_START_PERIOD:
    my $period;
    if ($args{start_period}) {
        if ($prev_period > 0) {
            return [412, "Start period must be $prev_period or ".($prev_period+1)]
                unless $args{start_period} == $prev_period || $args{start_period} == $prev_period+1;
        } else {
            return [412, "Start period must be 1"]
                unless $args{start_period} == 1;
        }
        $period = $args{start_period} - 1;
    } else {
        $period = $prev_period;
    }

  INIT_CURRENT_ITEMS:
    my %current_items; # items with streaks currently going, key=item, val=starting period
    for my $key (keys %streaks) {
        my $streak = $streaks{$key};
        my ($start, $item) = $key =~ $re or die;
        $current_items{$item} = $start if !defined($streak->[1]) ||
            $streak->[1] == $prev_period;
    }

  FIND_STREAKS: {
        for my $set (@$sets) {
            $period++;
            my %items_this_period; $items_this_period{$_}++ for @$set;
            my %new_items_this_period;

            # find new streaks: items that just appear in this period
          FIND_NEW: {
                for my $item (@$set) {
                    next if $current_items{$item};
                    $current_items{$item} = $period;
                    $streaks{ $period . "." . $item } = [1, undef];
                    $new_items_this_period{$item} = 1;
                }
            } # FIND_NEW

            # find broken streaks: items that no longer appear in this period
          FIND_BROKEN: {
                for my $item (keys %current_items) {
                    my $key = $current_items{$item} . "." . $item;
                    if ($items_this_period{$item}) {
                        if ($period > $prev_period) {
                            unless ($new_items_this_period{$item}) {
                                # streak keeps going
                                $streaks{$key}[0]++;
                            }
                        } else {
                            $streaks{$key}[1] = undef;
                        }
                    } else {
                        # streak broken (but for current period, it might not
                        # just yet, the item might still appear later before the
                        # end of the current period. you just need to check if
                        # period number recorded is the current period
                        $streaks{$key}[1] //= $period;
                        delete $current_items{$item};
                    }
                }
            } # FIND_BROKEN
        } # for $set
    } # FIND_STREAKS

    my $cur_period = @$sets;
  FILTER_STREAKS: {
        last unless $args{exclude_broken};
        for my $key (keys %streaks) {
            my $streak = $streaks{$key};
            next unless defined $streak->[1];
            next if $streak->[1] == $cur_period;
            delete $streaks{$key};
        }
    } # FILTER_STREAKS

  RETURN_RAW:
    if ($args{raw}) {
        return \%streaks;
    }

    my @res;
  RANK_STREAKS: {
        require List::Rank;
        my @rankres = List::Rank::sortrankby(
            sub {
                my $streak_a = $streaks{$a};
                my $streak_b = $streaks{$b};
                my ($start_a, $item_a) = $a =~ $re or die;
                my ($start_b, $item_b) = $b =~ $re or die;
                ($streak_b->[0] <=> $streak_a->[0]) || # longer streaks first
                    ($start_a <=> $start_b) ||         # earlier streaks first
                    ($item_a cmp $item_b);             # asciibetically
            },
            keys %streaks
        );

        while (my ($key, $rank) = splice @rankres, 0, 2) {
            my ($start, $item) = $key =~ $re or die;
            my $streak = $streaks{$key};
            my $status = !defined($streak->[1]) ? "ongoing" :
                ($streak->[1] < $cur_period) ? "broken" : "might-break";
            push @res, {
                item => $item,
                start => $start,
                len => $streak->[0],
                status => $status,
            };
        }
    } # RANK_STREAKS

    \@res;
}

1;
# ABSTRACT: Routines related to streaks (longest item appearance in consecutive sets)

=head1 SEE ALSO

=cut
