use strict;
use warnings;
use Test::More;
use Capture::Tiny qw/capture/;
use JSON qw/encode_json/;

use App::jl;

my $JSON = encode_json({
    foo => encode_json({
        bar => encode_json({
            baz => encode_json({
                hoge => 123,
            }),
        }),
    }),
});

note $JSON;

BASIC: {
    note( App::jl->new->process($JSON) );
}

SORT_KEYS: {
    note( App::jl->new->process(encode_json({ z => 1, b => 1, a => 1 })) );
}

JA: {
    note( App::jl->new->process(encode_json({ aiko => '詩' })) );
}

NO_PRETTY: {
    note( App::jl->new('--no-pretty')->process($JSON) );
}

DEPTH: {
    note( App::jl->new('--depth', '1')->process($JSON) );
}

TEST_RUN_WITH_NOT_JSON: {
    my $str = 'Not JSON String';
    open my $IN, '<', \$str;
    local *STDIN = *$IN;
    my ($stdout, $stderr) = capture {
        App::jl->new->run;
    };
    close $IN;
    is $stdout, $str;
}

X: {
    my $src_json = encode_json({ foo => 'bar' });
    my $json_in_log = encode_json({ message => qq|[05/09/2019 23:51:51]\t[warn]\r$src_json\n| });
    note( App::jl->new('-x')->process($json_in_log) );
}

done_testing;
