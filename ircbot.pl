#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use POSIX ();
use IO::Socket;
use Getopt::Long;
Getopt::Long::Configure('bundling');
use Module::Refresh;
use FindBin;
use lib "$FindBin::Bin/";
use Ircparser;

my $nickname = '';
my $serveraddr = '';
my @channels = ('');
my $cmd_password = '';
my %log_channels = ();
my ($server, $daemon, $connected, $disconnecting, $newnick);

$SIG{'TERM'} = "stop_bot";
$SIG{'INT'} = "stop_bot";
$SIG{'HUP'} = "reload_bot";



BEGIN {
    die "Usage: ircbot [-d]\n"
        unless GetOptions(
            'd|daemon' => \$daemon,
        );

    die "$0 lockfile already in place, quiting!" if -f '/var/lock/ircbot';

    if ($daemon) {
        exit if (fork);
        POSIX::setsid();
        exit if (fork);
        chdir "/";
        umask 0;

        open(STDIN, "+>/dev/null");
        open LOG, ">>/var/log/ircbot/main"
            or die "Could not open log file: $!";
        *STDERR = *LOG;
        *STDOUT = *LOG;
        select(LOG);
        $| = 1;
        print LOG "---------- Opening Log ----------\n";
    }

    open LOCK, '>/var/lock/ircbot'
        or die "Could not create lockfile: $!";
    print LOCK $$;
    close LOCK
        or die "Could not close lockfile: $!";
}

while (!$disconnecting) {
    while (not defined $server) {
        $server = IO::Socket::INET->new(PeerAddr => $serveraddr, PeerPort => '6667', Proto => 'tcp', Timeout => 300);
    }
    logger("Connecting to " . $serveraddr);
    print $server "USER $nickname $nickname $nickname $nickname\n";
    print $server "NICK $nickname\n";

    while (<$server>) {
        s/[\r\n]*$//;
        logger($_);
        if (/004/) {
            logger("Connected to " . $serveraddr);
            $connected = 1;
            last;
        } elsif (/433|436|437/) {
            $newnick = defined $newnick ? $newnick . "_" : $nickname . "_";
            print $server "NICK $newnick\n";
        }
    }

    for (@channels) {
        print $server "JOIN $_\n";
    }

    my $pid;
    if ($pid = fork()) {
        while (<$server>) {
            s/[\r\n]*$//;
            if (/^PING (.*)$/i) {
                print $server "PONG $1\n";
            } else {
                logger($_);
                if (/:([^ !]+)!.*PRIVMSG ([^ ]+) :?(.*)/) {
                    if (!$log_channels{$2}) {
                        open $log_channels{$2}, ">>/var/log/ircbot/$2.log" ;
                        select((select($log_channels{$2}), $|=1)[0]);
                    }
                    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
                    printf {$log_channels{$2}} "%04d-%02d-%02d %02d:%02d:%02d <%s> %s\n", $year+1900, $mon+1, $mday, $hour, $min, $sec, $1, $3;
                }
                handle_input($server, $_);
            }
        }
    } else {
        if ($daemon) {
            my $listen = IO::Socket::INET->new(LocalPort => 54321, Proto => 'tcp', Reuse => 1, Listen => 10)
                or die "Couldn't be a tcp server on port 54321: $!\n";
            while(my $client = $listen->accept()) {
                if (<$client> =~ /^pw $cmd_password$/) {
                    while (<$client>) {
                        logger($_);
                        receive_command($_);
                    }
                }
            }
        } else {
            while (<STDIN>) {
                logger($_);
                receive_command($_);
            }
        }
        exit;
    }

    logger("Lost connection to " . $serveraddr);
    $connected = 0;
    undef $server;
    kill 9, $pid;
}

sub receive_command {
    my ($text) = @_;
    if ($text =~ /^([^ ]+) (!.+)$/) {
        irc_public($server, "bot!bot\@bot", $1, $1, $2);
    } elsif ($text =~ /^(#?[a-z]+) (.+)$/) {
        print $server "PRIVMSG $1 :$2\n";
    } else {
        print $server $text . "\n";
    }
}

sub stop_bot {
    if ($connected and !$disconnecting) {
        logger("Disconnecting from server");
        $disconnecting = 1;
        print $server "QUIT\n";
    } else {
        logger("Exiting");
        exit;
    }
}

sub reload_bot {
    my $refresher = Module::Refresh->new();
    $refresher->refresh_module('Ircparser.pm');
    logger("Reloaded parser");
}

sub logger {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    for (split /\n/, shift) {
        printf "%04d-%02d-%02d %02d:%02d:%02d - %s\n", $year+1900, $mon+1, $mday, $hour, $min, $sec, $_;
    }
}

END {
    if ($daemon) {
        for (@channels) {
            close $log_channels{$_};
        }
        print LOG "---------- Closing Log ----------\n";
        close LOG
            or die "Could not close log file: $!";
    }
    unlink '/var/lock/ircbot'
        or die "Could not delete lockfile: $!";
}
