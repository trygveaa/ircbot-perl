package Ircparser;

use strict;
use warnings;
use utf8;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(handle_input irc_public);

use Switch;
use WWW::Curl::Easy;
use HTTP::Message;
use HTML::Entities;
use Encode;

my $allowed_ops = '';
my $autoop_channels = '';
my @atmytv_feeds = ('');
my $vaskeri_url = '';
my $vaskeri_userpwd = '';

sub handle_input {
    my ($server, $_) = @_;

    if (/^:(([^ !]+)![~^]?([^ @]+)@([^ ]+)) ([A-Z]+) (.*)$/) {
        my ($ircmask, $nick, $username, $hostname, $cmd, $args) = ($1, $2, $3, $4, $5, $6);
        switch ($cmd) {
            case "PRIVMSG" {
                $args =~ /^((#)?[^ ]+) :?(.*)$/;
                my ($channel, $is_channel, $msg) = ($1, $2, $3);
                if ($is_channel) {
                    irc_public($server, $ircmask, $nick, $channel, $msg);
                } else {
                    irc_private($server, $ircmask, $nick, $channel, $msg);
                }
            }
            case "JOIN" {
                (my $channel = $args) =~ s/^://;
                if ($channel =~ /^($autoop_channels)$/ && $ircmask =~ /[^!]+!($allowed_ops)$/) {
                    print $server "MODE $channel +o $nick\n";
                }
            }
        }

    } elsif (/^:([^ ]+) ([^ ]+) ([^ ]+) (.*)$/) {
        my ($server, $cmd, $mynick, $args) = ($1, $2, $3, $4);
    }
}

sub irc_public {
    my ($server, $ircmask, $nick, $channel, $msg) = @_;
    eval {
        if ($msg =~ /^!([^ ]+)\s*(.*)$/) {
            my $command = $1;
            my $args = $2;

            switch ($command) {
                case "op" {
                    if ($ircmask =~ /[^!]+!($allowed_ops)$/) {
                        print $server "MODE $channel +o $nick\n";
                    } else {
                        print $server "NOTICE $channel :$nick: You are not allowed.\n";
                    }
                }
                case "rot13" {
                    $args =~ tr[a-zA-Z][n-za-mN-ZA-M];
                    print $server "NOTICE $channel :$nick: $args\n";
                }
                case "random" {
                    if ($args =~ /^([0-9]+) ([0-9]+)$/) {
                        print $server "NOTICE $channel :>> Random number: " . (rand($2-$1) + $1) . "\n";
                    } else {
                        print $server "NOTICE $channel :>> Invalid arguments. Usage: !random from to\n";
                    }
                }
                }
                case /today|tomorrow/ {
                    my $curl = new WWW::Curl::Easy;
                    my ($response_body, $retcode);

                    for (@atmytv_feeds) {
                        my $url = $_;
                        $url =~ s/REPLACE/$command/;
                        $curl->setopt(CURLOPT_URL, $url);
                        open (my $fileb, ">>", \$response_body);
                        $curl->setopt(CURLOPT_WRITEDATA, $fileb);
                        $retcode = $curl->perform;
                    }

                    if ($retcode == 0) {
                        my @series = split(/\n/m, $response_body);
                        @series = grep(/show_name/, @series);
                        for (@series) {
                            s/.*<show_name><!\[CDATA\[(.*)\]\]><\/show_name>.*/$1/;
                        }
                        my $list = join(", ", sort keys %{{ map { $_ => 1 } @series }});
                        if ($list) {
                            print $server "NOTICE $channel :>> " . ucfirst($command) . "s series: $list\n";
                        } elsif ($ircmask ne "bot!bot\@bot") {
                            print $server "NOTICE $channel :>> There are no series ${command}.\n";
                        }
                    } else {
                        print $server "NOTICE $channel :>> Couldn't get series list.\n";
                    }
                }
                case "vaskeri" {
                    my $curl = new WWW::Curl::Easy;
                    $curl->setopt(CURLOPT_URL, $vaskeri_url);
                    $curl->setopt(CURLOPT_USERPWD, $vaskeri_userpwd);
                    my $response_body;
                    open (my $fileb, ">>", \$response_body);
                    $curl->setopt(CURLOPT_WRITEDATA, $fileb);

                    if ($curl->perform == 0) {
                        if ($args) {
                            $response_body =~ s/<\/?br?>/ /ig;
                            $response_body =~ /(Maskin $args) *([^<]*)/;
                            print $server "NOTICE $channel :>> $1: $2\n";
                        } else {
                            my $free = 0;
                            $free++ while ($response_body =~ /Maskin.*Ledig til/g);
                            print $server "NOTICE $channel :>> Det er $free ledige maskiner.\n";
                        }
                    }
                }
            }
        } elsif ($msg =~ /(https?:\/\/[^ ]+)/) {
            my $url = $1;
            $url =~ s/([^-_.~A-Za-z0-9+\/\\:()&%\$@\?=#])/sprintf("%%%02X", ord($1))/seg;
            my $curl = new WWW::Curl::Easy;
            $curl->setopt(CURLOPT_URL, $url);
            $curl->setopt(CURLOPT_FOLLOWLOCATION, 1);
            $curl->setopt(CURLOPT_TIMEOUT, 5);
            $curl->setopt(CURLOPT_USERAGENT, "Mozilla/5.0 (X11; U; Linux x86_64; en-US; rv:1.9.2.23) Gecko/20110921 Firefox/3.6.23");

            my $response_body;
            open (my $fileb, ">", \$response_body);
            $curl->setopt(CURLOPT_WRITEDATA, $fileb);
            my $retcode = $curl->perform;

            if ($retcode == 0) {
                my @header = ("Content-Type", $curl->getinfo(CURLINFO_CONTENT_TYPE));
                my $mess = HTTP::Message->new(\@header, $response_body);

                if ($mess->decoded_content =~ /\<title\>(.*)\<\/title\>/is) {
                    (my $title = $1) =~ tr/\r\n/ /;
                    $title =~ s/\s+/ /g;
                    $title =~ s/^\s*(.*?)\s*$/$1/g;
                    print $server "NOTICE $channel :>> " . encode("utf8", decode_entities($title)) . "\n";
                }
            }
        }
        1;
    } or do {
        chomp($@);
        print $server "NOTICE $channel :>> Caught exception: $@\n";
    };
}

sub irc_private {
    my ($server, $ircmask, $nick, $channel, $msg) = @_;
    irc_public($server, $ircmask, $nick, $nick, $msg);
}

sub logger {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	for (split /\n/, shift) {
		printf "%04d-%02d-%02d %02d:%02d:%02d - %s\n", $year+1900, $mon+1, $mday, $hour, $min, $sec, $_;
	}
}
