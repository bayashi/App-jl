package App::jl;
use strict;
use warnings;
use JSON qw//;
use Sub::Data::Recursive;
use B;
use Getopt::Long qw/GetOptionsFromArray/;

our $VERSION = '0.16';

my $MAX_RECURSIVE_CALL = 255;

my $MAYBE_UNIXTIME = join '|', (
    'create',
    'update',
    'expire',
    '.._(?:at|on)',
    '.ed$',
    'date',
    'time',
    'since',
    'when',
);

my $LOG_LEVEL_STRINGS = join '|', (
    'debug',
    'trace',
    'info',
    'notice',
    'warn',
    'error',
    'crit(?:ical)?',
    'fatal',
    'emerg(?:ency)?',
);

my $L_BRACKET = '[  \\( \\{ \\<  ]';
my $R_BRACKET = '[  \\) \\} \\>  ]';

my $UNIXTIMESTAMP_KEY = '';

my $GMTIME;

my $INVOKER = 'Sub::Data::Recursive';

sub new {
    my $class = shift;
    my @argv  = @_;

    my $opt = $class->_parse_opt(@argv);

    my $self = bless {
        _opt  => $opt,
        _json => JSON->new->utf8->pretty(!$opt->{no_pretty})->canonical(1),
        __current_orig_line => undef,
    }, $class;

    $self->_lazyload_modules;

    return $self;
}

sub opt {
    my ($self, $key) = @_;

    return $self->{_opt}{$key};
}

sub run {
    my ($self) = @_;

    local $| = !!$self->opt('unbuffered');

    my $out = !!$self->opt('stderr') ? *STDERR : *STDOUT;

    while ($self->{__current_orig_line} = <STDIN>) {
        if (my $line = $self->_run_line) {
            print $out $line;
        }
        $self->{__current_orig_line} = undef;
    }
}

sub _run_line {
    my ($self) = @_;

    if ($self->{__current_orig_line} =~ m!^[\s\t\r\n]+$!) {
        return;
    }

    if ($self->{__current_orig_line} !~ m!^\s*[\[\{]!) {
        return $self->opt('sweep') ? undef : $self->{__current_orig_line};
    }

    if (my $rs = $self->opt('grep')) {
        if (!$self->_match_grep($rs)) {
            return; # no match
        }
    }

    if (my $rs = $self->opt('ignore')) {
        if ($self->_match_grep($rs)) {
            return; # ignore if even one match
        }
    }

    return $self->_process;
}

sub _match_grep {
    my ($self, $rs) = @_;

    for my $r (@{$rs}) {
        return 1 if $self->{__current_orig_line} =~ m!$r!;
    }
}

sub _lazyload_modules {
    my ($self) = @_;

    if ($self->opt('xxxx') || $self->opt('timestamp_key')) {
        require 'POSIX.pm'; ## no critic
        POSIX->import;
    }

    if ($self->opt('yaml')) {
        require 'YAML/Syck.pm'; ## no critic
        YAML::Syck->import;
        $YAML::Syck::SortKeys = 1;
    }
}

sub _process {
    my ($self) = @_;

    my $decoded = eval {
        $self->{_json}->decode($self->{__current_orig_line});
    };
    if ($@) {
        return $self->{__current_orig_line};
    }
    else {
        $self->_recursive_process($decoded);
        return $self->_encode($decoded);
    }
}

sub _encode {
    my ($self, $decoded) = @_;

    if ($self->opt('yaml')) {
        return YAML::Syck::Dump($decoded);
    }
    else {
        return $self->{_json}->encode($decoded);
    }
}

sub _recursive_process {
    my ($self, $decoded) = @_;

    $self->_recursive_pre_process($decoded);

    $self->{_recursive_call} = $MAX_RECURSIVE_CALL;
    $self->_recursive_decode_json($decoded);

    $self->_recursive_post_process($decoded);
}

sub _recursive_pre_process {
    my ($self, $decoded) = @_;

    $INVOKER->invoke(\&_trim => $decoded);

    $self->_invoker(\&_split_lf => $decoded) if $self->opt('x');
}

sub _recursive_post_process {
    my ($self, $decoded) = @_;

    if ($self->opt('x')) {
        $self->_invoker(\&_split_lf => $decoded);
    }

    if ($self->opt('xx')) {
        $self->_invoker(\&_split_comma => $decoded);
    }

    if ($self->opt('xxx')) {
        $self->_invoker(\&_split_label => $decoded);
    }

    if ($self->opt('xxxx') || $self->opt('timestamp_key')) {
        if ($self->opt('xxxxx')) {
            $INVOKER->invoke(\&_forcely_convert_timestamp => $decoded);
        }
        else {
            $self->_invoker(\&_convert_timestamp => $decoded);
        }
    }

    $INVOKER->invoke(\&_trim => $decoded);
}

my $LAST_VALUE;

sub _invoker {
    my ($self, $code_ref, $hash) = @_;

    $LAST_VALUE = '';
    $INVOKER->massive_invoke($code_ref => $hash);
}

sub _skippable_value {
    my ($context, $last_value) = @_;

    return $context && $context eq 'HASH'
            && $last_value && $last_value =~ m!user[\-\_\s]*agent!i;
}

sub _split_lf {
    my $line    = $_[0];
    my $context = $_[1];

    if (_skippable_value($context, $LAST_VALUE)) {
        $LAST_VALUE = $line;
        return $line;
    }

    $LAST_VALUE = $line;

    if ($line =~ m![\t\r\n]!) {
        chomp $line;
        my @elements = split /[\t\r\n]+/, $line;
        $_[0] = \@elements if scalar @elements > 1;
    }
}

sub _split_comma {
    my $line    = $_[0];
    my $context = $_[1];

    if (_skippable_value($context, $LAST_VALUE)) {
        $LAST_VALUE = $line;
        return $line;
    }

    $LAST_VALUE = $line;

    return $line if $line !~ m!, ! || $line =~ m!\\!;

    chomp $line;

    my @elements = split /,\s+/, $line;

    $_[0] = \@elements if scalar @elements > 1;
}

sub _split_label {
    my $line    = $_[0];
    my $context = $_[1];

    if (_skippable_value($context, $LAST_VALUE)) {
        $LAST_VALUE = $line;
        return $line;
    }

    $LAST_VALUE = $line;

    return $line if $line =~ m!\\!;

    chomp $line;

    # remove spaces between braces
    $line =~ s!( $R_BRACKET ) [\s\t]+ ( $R_BRACKET )!$1$2!xg;

    # replace square brackets label
    $line =~ s!( \[ [\s\t]* .+ [\s\t]* \] )!$1\n!ixg;

    # replace log level labels
    $line =~ s!( $L_BRACKET ) [\s\t]* ( $LOG_LEVEL_STRINGS ) [\s\t]* ( $R_BRACKET )!$1$2$3\n!ixg;

    my @elements = split /\n/, $line;

    $_[0] = \@elements if scalar @elements > 1;
}

sub _convert_timestamp {
    my $line    = $_[0];
    my $context = $_[1];

    return $line if !$context || $context ne 'HASH';

    if (
        ($UNIXTIMESTAMP_KEY && $LAST_VALUE eq $UNIXTIMESTAMP_KEY && $line =~ m!(\d+(\.\d+)?)!)
            || ($LAST_VALUE =~ m!(?:$MAYBE_UNIXTIME)!i && $line =~ m!(\d+(\.\d+)?)!)
    ) {
        if (my $date = _ts2date($1, $2)) {
            $_[0] = $date;
        }
    }

    $LAST_VALUE = $line;
}

sub _forcely_convert_timestamp {
    my $line    = $_[0];

    if ($line =~ m!(\d+(\.\d+)?)!) {
        if (my $date = _ts2date($1, $2)) {
            $_[0] = $date;
        }
    }
}

sub _ts2date {
    my $unix_timestamp = shift;
    my $msec           = shift || '';

    # 946684800 = 2000-01-01T00:00:00Z
    if ($unix_timestamp >= 946684800 && $unix_timestamp <= ((2**32 - 1) * 1000)) {
        if ($unix_timestamp > 2**32 -1) {
            ($msec) = ($unix_timestamp =~ m!(\d\d\d)$!);
            $msec = ".$msec";
            $unix_timestamp = int($unix_timestamp / 1000);
        }
        my @t = $GMTIME ? gmtime($unix_timestamp) : localtime($unix_timestamp);
        return POSIX::strftime('%Y-%m-%d %H:%M:%S', @t) . $msec;
    }
}

sub _trim {
    my $line = $_[0];

    my $trim = 0;

    if ($line =~ m!^[\s\t\r\n]+!) {
        $line =~ s!^[\s\t\r\n]+!!;
        $trim = 1;
    }

    if ($line =~ m![\s\t\r\n]+$!) {
        $line =~ s![\s\t\r\n]+$!!;
        $trim = 1;
    }

    if ($trim) {
        $_[0] = $line;
    }
}

sub _recursive_decode_json {
    my ($self, $hash) = @_;

    Sub::Data::Recursive->invoke(sub {
        if ($self->{_recursive_call} > 0) {
            my $orig = $_[0];
            return if $orig =~ m!^\[\d+\]$!;
            if (!_is_number($_[0])) {
                my $decoded = eval {
                    $self->{_json}->decode($orig);
                };
                if (!$@) {
                    $_[0] = $decoded;
                    $self->{_recursive_call}--;
                    $self->_recursive_decode_json($_[0]); # recursive calling
                }
            }
        }
    } => $hash);
}

# copied from Data::Recursive::Encode
sub _is_number {
    my $value = shift;
    return 0 unless defined $value;

    my $b_obj = B::svref_2object(\$value);
    my $flags = $b_obj->FLAGS;
    return $flags & ( B::SVp_IOK | B::SVp_NOK ) && !( $flags & B::SVp_POK ) ? 1 : 0;
}

sub _parse_opt {
    my ($class, @argv) = @_;

    my $opt = {};

    GetOptionsFromArray(
        \@argv,
        'no-pretty' => \$opt->{no_pretty},
        'x'         => \$opt->{x},
        'xx'        => \$opt->{xx},
        'xxx'       => \$opt->{xxx},
        'xxxx'      => \$opt->{xxxx},
        'X|xxxxx'   => \$opt->{xxxxx},
        'timestamp-key=s' => \$opt->{timestamp_key},
        'gmtime'    => \$opt->{gmtime},
        'g|grep=s@' => \$opt->{grep},
        'ignore=s@' => \$opt->{ignore},
        'yaml|yml'  => \$opt->{yaml},
        'unbuffered' => \$opt->{unbuffered},
        'stderr'    => \$opt->{stderr},
        'sweep'     => \$opt->{sweep},
        'h|help'    => sub {
            $class->_show_usage(1);
        },
        'v|version' => sub {
            print "$0 $VERSION\n";
            exit 1;
        },
    ) or $class->_show_usage(2);

    $opt->{xxxx} ||= $opt->{xxxxx};
    $opt->{xxx}  ||= $opt->{xxxx};
    $opt->{xx}   ||= $opt->{xxx};
    $opt->{x}    ||= $opt->{xx};

    $UNIXTIMESTAMP_KEY = $opt->{timestamp_key};

    $GMTIME = $opt->{gmtime};

    return $opt;
}

sub _show_usage {
    my ($class, $exitval) = @_;

    require Pod::Usage;
    Pod::Usage::pod2usage(-exitval => $exitval);
}

1;

__END__

=encoding UTF-8

=head1 NAME

App::jl - Show the "JSON in JSON" Log Nicely


=head1 SYNOPSIS

See L<jl> for CLI to view logs.

    use App::jl;
    
    App::jl->new(@ARGV)->run;


=head1 DESCRIPTION

App::jl is recursive JSON in JSON decoder. It makes JSON log nice.

For example,

    $ echo '{"foo":"{\"bar\":\"{\\\"baz\\\":123}\"}"}' | jl
    {
       "foo" : {
          "bar" : {
             "baz" : 123
          }
       }
    }


=head1 METHODS

=head2 new

constructor

=head2 opt

getter of optional values

=head2 run

The main routine


=head1 REPOSITORY

=begin html

<a href="https://github.com/bayashi/App-jl/blob/main/lib/App/jl.pm"><img src="https://img.shields.io/badge/Version-0.16-green?style=flat"></a> <a href="https://github.com/bayashi/App-jl/blob/main/LICENSE"><img src="https://img.shields.io/badge/LICENSE-Artistic-GREEN.png"></a> <a href="http://travis-ci.org/bayashi/App-jl"><img src="https://secure.travis-ci.org/bayashi/App-jl.png?_t=1566766313"/></a> <a href="https://coveralls.io/r/bayashi/App-jl"><img src="https://coveralls.io/repos/bayashi/App-jl/badge.png?_t=1566766313&branch=main"/></a>

=end html

App::jl is hosted on github: L<http://github.com/bayashi/App-jl>

I appreciate any feedback :D


=head1 AUTHOR

Dai Okabayashi E<lt>bayashi@cpan.orgE<gt>


=head1 SEE ALSO

L<jl>


=head1 LICENSE

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=cut
