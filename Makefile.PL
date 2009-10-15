use inc::Module::Install;

name 'Plack-Server-POE';
all_from 'lib/Plack/Server/POE.pm';
readme_from 'lib/Plack/Server/POE.pm';
requires 'POE';
requires 'POE::Component::Server::TCP';
requires 'POE::Filter::HTTP::Parser';
requires 'Plack';
requires 'HTTP::Message::PSGI';
requires 'HTTP::Status';
build_requires 'Test::More';
use_test_base;
auto_include_deps;
auto_install;
WriteAll;
