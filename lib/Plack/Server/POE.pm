package Plack::Server::POE;

require v5.8.8;

our $VERSION = '0.4';

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
    $opt->{host} ||= '0.0.0.0',

    return bless $opt, $class;
}

sub on_client_input {
    my ($self, $heap, $req) = @_;
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
        SERVER_PROTOCOL     => $protocol,
        'psgi.streaming'    => Plack::Util::TRUE,
        'psgi.nonblocking'  => Plack::Util::TRUE,
        'psgi.runonce'      => Plack::Util::FALSE,
    );

    my $connection = $req->header('Connection') || '';
    my $keep_alive = $version eq '1.1' && $connection ne 'close';

    my $write = sub { $client->put($_[0]) };
    my $close = sub {
        delete $heap->{client_flush};
        $poe_kernel->yield('shutdown') unless $keep_alive;
        return;
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
            if (Plack::Util::is_real_fh($body)) {
                my ($wheel, $buffer);
                my $flusher = sub {
                    return unless $buffer;
                    $w->($buffer);
                    $buffer = '';
                    $wheel->resume_input() if $wheel;
                };
                $heap->{client_flush} = $flusher;
                POE::Session->create(
                    inline_states => {
                        _start => sub {
                            $wheel = POE::Wheel::ReadWrite->new(
                                Handle     => $body,
                                Filter     => POE::Filter::Stream->new,
                                InputEvent => 'got_input',
                                ErrorEvent => 'got_error',
                            );
                        },
                        got_error => sub {
                            my ($op, $errno, $errstr, $id) = @_[ARG0..ARG3];
                            if ($op eq 'read') {
                                delete $_[HEAP]->{wheels}->{$id};
                                $wheel = undef;
                                $body->close();
                                $c->();
                            }
                        },
                        got_input => sub {
                            my $data = $_[ARG0];
                            my $already_flushed = !$buffer;
                            $buffer .= $data;
                            if ($already_flushed) {
                                $flusher->();
                            }
                            else  {
                                my $len = do { use bytes; length($buffer) };
                                $wheel->pause_input if $len > 1024;
                            }
                        }
                    }
                );
            }
            else {
                Plack::Util::foreach($body, $w);
                $c->();
            }
            return;
        }

        my $writer; $writer = Plack::Util::inline_object(
            write   => $w,
            close   => $c,
            poll_cb => sub {
                my $get = shift;
                ($heap->{client_flush} = sub {
                    $get->($writer);
                })->();
            },
        );
        return $writer;
    };

    my $response = Plack::Util::run_app($self->{app}, $env);

    if (ref $response eq 'CODE') {
        $response->($start_response);
    }
    else {
        $start_response->($response);
    }
}

sub register_service {
    my ($self, $app) = @_;
    $self->{app} = $app;

    my $filter = POE::Filter::HTTP::Parser->new( type => 'server' );
    print STDERR "Listening on $self->{host}:$self->{port}\n";
    POE::Component::Server::TCP->new(
        Port               => $self->{port},
        Address            => $self->{host},
        ClientInput        => sub {
            $self->on_client_input(@_[HEAP, ARG0]);
        },
        ClientInputFilter  => $filter,
        ClientOutputFilter => 'POE::Filter::Stream',
        ClientFlushed      => sub {
            my $cb = $_[HEAP]->{client_flush};
            $cb && $cb->();
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
