package Plack::Server::POE;

use warnings;
use strict;

use HTTP::Message::PSGI;
use HTTP::Status qw(status_message);
use Plack::Util;
use POE qw(
    Component::Server::TCP
    Filter::HTTP::Parser
    Filter::Stream
);

sub new {
    my $class = shift;
    my $opt   = ref $_[0] eq 'HASH' ? shift : { @_ };
    $opt->{port} ||= 8080,
    $opt->{host} ||= 'localhost',

    return bless $opt, $class;
}

sub run {
    my ($self, $app) = @_;
    my $filter = POE::Filter::HTTP::Parser->new( type => 'server' );
    POE::Component::Server::TCP->new(
        Port               => $self->{port},
        Address            => $self->{host},
        ClientInputFilter  => $filter,
        ClientOutputFilter => 'POE::Filter::Stream',
        ClientInput        => sub {
            my ($kernel, $heap, $req) = @_[KERNEL, HEAP, ARG0];
            my $client = $heap->{client};
            my $env = req_to_psgi($req,
                SERVER_NAME         => $self->{host},
                SERVER_PORT         => $self->{port},
                'psgi.nonblocking'  => Plack::Util::TRUE,
                'psgi.runonce'      => Plack::Util::FALSE,
            );

            my ($code, $headers, $body_iter) =
                @{ Plack::Util::run_app($app, $env) };

            my $protocol = $req->protocol || 'HTTP/0.9';
            my $message = status_message($code);
            $client->put("$protocol $code $message\r\n");

            while (@$headers) {
                my $k = shift(@$headers);
                my $v = shift(@$headers);
                $client->put("$k: $v\r\n");
            }
            $client->put("\r\n");
            Plack::Util::foreach($body_iter, sub { $client->put($_[0]) });

            $poe_kernel->yield('shutdown');
        },
    );
    POE::Kernel->run;
}

1;
