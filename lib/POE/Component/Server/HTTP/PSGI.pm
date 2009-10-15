package POE::Component::Server::HTTP::PSGI;

use warnings;
use strict;

use HTTP::Status qw(status_message);
use Plack::Util;
use HTTP::Response;
use URI::Escape;
use IO::String;
use POE qw(
    Component::Server::TCP
    Filter::HTTP::Parser
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
    my $getRequests = POE::Filter::HTTP::Parser->new( type => 'server' );
    POE::Component::Server::TCP->new(
        Port         => $self->{port},
        Address      => $self->{host},
        ClientFilter => $filter,
        ClientInput  => sub {
            my $req   = $_[ARG0];
            my $uri   = $req->uri;
            my $path  = $uri->path;
            my $query = $uri->query;
            my %env   = (
                REQUEST_METHOD      => $req->method,
                SCRIPT_NAME         => '',
                PATH_INFO           => uri_unescape($path),
                REQUEST_URI         => "$path?$query",
                QUERY_STRING        => $query,
                SERVER_NAME         => $self->{host},
                SERVER_PORT         => $self->{port},
                SERVER_PROTOCOL     => $req->protocol,
                'psgi.version'      => [1,0],
                'psgi.url_scheme'   => $uri->scheme,
                'psgi.multithread'  => Plack::Util::FALSE,
                'psgi.multiprocess' => Plack::Util::FALSE,
                'psgi.nonblocking'  => Plack::Util::TRUE,
                'psgi.input'        => IO::String->new( $req->content ),
                'psgi.errors'       => \*STDERR,
            );
            my $reqh = $req->headers;
            foreach my $name ($reqh->header_field_names) {
                $env{uc "http_$name"} = $reqh->header($name);
            }

            my $body;
            my ($status, $headers, $body_iter) = 
                @{ Plack::Util::run_app($app, \%env) };

            Plack::Util::foreach($body_iter, sub { $body .= $_[0] });

            my $res = HTTP::Response->new(
                $status,
                status_message($status),
                $headers,
                $body,
            );
            $_[HEAP]->{client}->put($res);
        },
    );
    POE::Kernel->run;
}
