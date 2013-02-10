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
my %log_channels = ();
my ($server, $run, $daemon, $say, $connected, $disconnecting, $newnick);

BEGIN {
    die "Usage: ircbot [-r] [-d] [-s text]\n"
        unless GetOptions(
        'r|run' => \$run,
        'd|daemon' => \$daemon,
        's|say=s'  => \$say,
        );

    if ($run or $daemon) {
        die "$0 lockfile already in place, quiting!" if -f '/var/lock/ircbot';

        if ($daemon) {
            $run = 1;
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

    } elsif (!$say) {
        die "You must either run the bot, run it as a daemon or send text to the running bot.\n";
        exit 1;
    }
}

if ($run) {
    $SIG{'TERM'} = "stop_bot";
    $SIG{'INT'} = "stop_bot";
    $SIG{'HUP'} = "receive_command";

    while (!$disconnecting) {
        while (not defined $server) {
            $server = IO::Socket::INET->new(PeerAddr => $serveraddr, PeerPort => '6667', Proto => 'tcp', Timeout => 300);
        }
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

        if ($daemon or my $pid = fork()) {
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
            while (<STDIN>) {
                print $server $_;
            }
            exit;
        }

        undef $server;
    }

} elsif ($say) {
    open FILE, "/var/lock/ircbot" or die "Couldn't open lockfile: $!";
    chomp (my $pid = <FILE>);
    close FILE;
    my $path = "/tmp/ircbot." . $pid;
    POSIX::mkfifo($path, 0700) or die "Couldn't create fifo: $!";
    kill HUP => $pid;
    open FIFO, ">", $path or die "Couldn't open fifo: $!";
    print FIFO $say;
    close FIFO;
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

sub receive_command {
    my $path = "/tmp/ircbot." . $$;
    open FIFO, $path or return;
    chomp (my $text = <FIFO>);
    close FIFO;
    unlink $path;

    if ($text eq "reload") {
        my $refresher = Module::Refresh->new();
        $refresher->refresh_module('Ircparser.pm');
    } elsif ($text =~ /^([^ ]+) (!.+)$/) {
        irc_public($server, "bot!bot\@bot", $1, $1, $2);
    } elsif ($text =~ /^(#?[a-z]+) (.+)$/) {
        print $server "PRIVMSG $1 :$2\n";
    } else {
        print $server $text . "\n";
    }
}

sub logger {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	for (split /\n/, shift) {
		printf "%04d-%02d-%02d %02d:%02d:%02d - %s\n", $year+1900, $mon+1, $mday, $hour, $min, $sec, $_;
	}
}

END {
    if ($run) {
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
}
