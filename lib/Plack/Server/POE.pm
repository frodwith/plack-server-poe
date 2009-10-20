package Plack::Server::POE;

require v5.8.8;

our $VERSION = '0.2';

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

sub register_service {
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

            unless ($req->isa('HTTP::Request')) {
                $client->put($req->as_string);
                $poe_kernel->yield('shutdown');
                return;
            }

            my $version  = $req->header('X-HTTP-Version') || '0.9';
            my $protocol = "HTTP/$version";

            my $env = req_to_psgi($req,
                SERVER_NAME         => $self->{host},
                SERVER_PORT         => $self->{port},
                'psgi.streaming'    => Plack::Util::TRUE,
                'psgi.nonblocking'  => Plack::Util::TRUE,
                'psgi.runonce'      => Plack::Util::FALSE,
            );

            my $connection = $req->header('Connection') || '';
            my $keep_alive = $version eq '1.1' && $connection ne 'close';

            my $write = sub { $client->put($_[0]) };
            my $close = sub { 
                $poe_kernel->yield('shutdown') unless $keep_alive;
            };

            my $write_chunked = sub {
                my $chunk = shift;
                my $len = sprintf "%X", do { use bytes; length($chunk) };
                $write->("$len\r\n$chunk\r\n");
            };

            my $close_chunked = sub {
                $write->("0\r\n\r\n");
                $close->();
            };

            my $start_response = sub {
                my ($code, $headers, $body) = @{+shift};
                my ($explicit_length, $chunked);
                my $message = status_message($code);
                $write->("$protocol $code $message\r\n");

                while (@$headers) {
                    my $k = shift(@$headers);
                    my $v = shift(@$headers);
                    if ($k eq 'Connection' && $v eq 'close') {
                        $keep_alive = 0;
                    }
                    elsif ($k eq 'Content-Length') {
                        $explicit_length = 1;
                    }
                    $write->("$k: $v\r\n");
                }

                my $no_body_allowed = ($req->method =~ /^head$/i)
                    || ($code < 200)
                    || ($code == 204)
                    || ($code == 304);

                if ($no_body_allowed) {
                    $write->("\r\n");
                    return;
                }

                $chunked = ($keep_alive && !$explicit_length);
                $write->("Transfer-Encoding: chunked\r\n") if $chunked;

                $write->("\r\n");

                my $w = $chunked ? $write_chunked : $write;
                my $c = $chunked ? $close_chunked : $close;

                if ($body) {
                    Plack::Util::foreach($body, $w);
                    $c->();
                    return;
                }

                return Plack::Util::inline_object(write => $w, close => $c);
            };

            my $response = Plack::Util::run_app($app, $env);

            if (ref $response eq 'CODE') {
                $response->($start_response);
            }
            else {
                $start_response->($response);
            }
        },
    );
}

sub run {
    my ($self, $app) = @_;
    $self->register_service($app);
    POE::Kernel->run;
}

1;

__END__

=head1 NAME

Plack::Server::POE - Plack Server implementation for POE

=head1 SYNOPSIS

    use Plack::Server::POE;

    my $server = Plack::Server::POE->new(
        host => $host,
        port => $port,
    );
    $server->run($app);

=head1 AUTHOR

Paul Driver, C<< <frodwith at cpan.org> >>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.

=head1 SEE ALSO

L<Plack>

=cut
