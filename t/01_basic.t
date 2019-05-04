use strict;
use warnings;
use Test::More;
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

NO_PRETTY: {
    note( App::jl->new('--no-pretty')->process($JSON) );
}

DEPTH: {
    note( App::jl->new('--depth', '1')->process($JSON) );
}

ok 1;

done_testing;
