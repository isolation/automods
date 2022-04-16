package M::LaunchLibrary;
use strict;
use warnings;
use 5.010;
use API::Std qw(cmd_add cmd_del hook_add hook_del conf_get err timer_add timer_del);
use API::IRC qw(privmsg notice);
use API::Log qw(slog dbug);
use Encode;
use JSON;
use Time::Piece;
use URI;

my $RATE = "300";
my $announced = {};
my $ll_next_launch = { 'name' => 'Some Launch', 'net' => 'Some Time', 'pad' => 'Some Where' };

sub _init {
    $Auto::DB->do('
        CREATE TABLE IF NOT EXISTS launchlib (
          nick TEXT COLLATE NOCASE
        )'
    ) or return;

    cmd_add('LL', 0, 0, \%M::LaunchLibrary::HELP_LL, \&M::LaunchLibrary::cmd_ll) or return;
    cmd_add('LAUNCHALERT', 0, 0, \%M::LaunchLibrary::HELP_LAUNCHALERT, \&M::LaunchLibrary::cmd_launchalert) or return;

    timer_add('launchlibinit', 1, 1, \&M::LaunchLibrary::launchlib_init);

    return 1;
}

sub _void {
    timer_del('launchlibcron');
    cmd_del('LL') or return;
    cmd_del('LAUNCHALERT') or return;
    return 1;
}

our %HELP_LL = (
    en => "Show the next launch in ready status. \2SYNTAX:\2 LL",
);

our %HELP_LAUNCHALERT = (
    en => "Subscribe yourself to launch alerts. \2SYNTAX:\2 LAUNCHALERT (ON|OFF)",
);

sub cmd_ll {
    my ($src, @argv) = @_;
    my $msg = "Next launch: " . $ll_next_launch->{name} . " \x{03}14from\x{03} " . 
        $ll_next_launch->{pad} . " \x{03}14at\x{03} " . $ll_next_launch->{net} . 
        " \x{03}14(currently " . gmtime()->datetime . "Z)\x{03}";
    privmsg($src->{svr}, $src->{chan}, $msg);
    return 1;
}

sub cmd_launchalert {
    my ($src, @argv) = @_;
    my $switch = shift @argv;
    if (!defined $switch) {
        my $sth = $Auto::DB->prepare('SELECT COUNT(*) FROM launchlib WHERE nick = ?') or return;
        $sth->execute($src->{nick});
        if ($sth->fetch->[0]) {
            privmsg($src->{svr}, $src->{chan}, "go for launch");
        }
        else {
            privmsg($src->{svr}, $src->{chan}, "alerting not enabled");
        }
        return 1;
    }
    elsif ($switch =~ /^on$/i) {
        my $sth = $Auto::DB->prepare('INSERT OR REPLACE INTO launchlib (nick) VALUES (?)') or return;
        $sth->execute($src->{nick});
        privmsg($src->{svr}, $src->{chan}, "go for launch");
    }
    elsif ($switch =~ /^off$/i) {
        my $sth = $Auto::DB->prepare('DELETE FROM launchlib WHERE nick = ?') or return;
        $sth->execute($src->{nick});
        privmsg($src->{svr}, $src->{chan}, "no longer alerting for launches");
    }
    else {
        notice($src->{svr}, $src->{nick}, "what?");
    }
    return 1;
}

sub launchlib_init {
    slog("launchlib initializing");
    timer_add('launchlibcron', 2, $RATE, \&M::LaunchLibrary::do_cron);
}

sub do_cron {
    dbug("[LaunchLib] launchlib cron running");
    my $uri = URI->new("https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=1&status=1");
    $Auto::http->request(
        timeout => 10,
        url => $uri,
        on_response => sub {
            my $result = shift;
            if (!$result->is_success) {
                slog("ll api req failed");
                return 0;
            }
            check_launches($result->decoded_content);
        },
        on_error => sub {
            my $error = shift;
            slog("ll api error: " . $error);
            return 0;
        }
    );
    return 1;
}

sub check_launches {
    my ($res) = @_;

    my $json = JSON->new->allow_nonref;
    my $data = $json->decode($res);
    my $launch = $data->{results}[0];

    $ll_next_launch->{name} = $launch->{name};
    $ll_next_launch->{net} = $launch->{net};
    $ll_next_launch->{pad} = $launch->{pad}->{location}->{name};

    my $launch_time = Time::Piece->strptime($launch->{net}, "%Y-%m-%dT%H:%M:%SZ");
    if ($launch_time - gmtime() < 900 && $launch->{status}->{id} == 1) {
        dbug("[LaunchLib] " . $launch_time . " - " . gmtime . " < 900");
        unless ($announced->{$launch->{id} . $launch->{net}}) {
            $announced->{$launch->{id} . $launch->{net}} = 1;
            my $out = "\x{1f680}Launch soon\x{231b}: ";
            $out .= $launch->{name};
            $out .= " at ";
            $out .= $launch->{net};
            $out .= " from ";
            $out .= $launch->{pad}->{location}->{name};
            $Auto::http->request(
                timeout => 10,
                url => $launch->{url},
                on_response => sub {
                    my $result = shift;
                    if (!$result->is_success) {
                        slog("ll api level two failed");
                        do_output($out, 0, 0);
                        return 1;
                    }
                    do_output($out, 1, $result->decoded_content);
                },
                on_error => sub {
                    my $error = shift;
                    slog("ll api error level two: " . $error);
                    do_output($out, 0, 0);
                    return 1;
                }
            );
        }
    }
    return 1;
}

sub do_output {
    my ($msg_start, $success, $res) = @_;
    slog("entered a do_output run");

    my $out = $msg_start;

    if ($success) {
        my $json = JSON->new->allow_nonref;
        my $launch = $json->decode($res);

        my @vids;
        foreach (@{$launch->{vidURLs}}) {
            push(@vids, $_->{url});
        }
        if (@vids) {
            $out .= " || Streams: ";
            $out .= join(' | ', @vids);

            my @nicks;
            my $sth = $Auto::DB->prepare('SELECT nick FROM launchlib') or return;
            $sth->execute;
            while (my $row = $sth->fetchrow_hashref) {
                dbug("[LaunchLib] this row: " . $row->{nick});
                push(@nicks, $row->{nick});
            }
            if (@nicks) {
                $out .= " || Beep: " . join(' ', @nicks);
            }
        }
        else {
            $out .= " || There are no streams for this launch.";
        }
    }
    else {
        $out .= " || No known streams for this launch."
    }

    # privmsg output line goes here

    return 1;
}

sub get_xchat_color {
    my @rcolors = ("03", "04", "05", "06", "07", "08", "09", "10", "11");
    my $sum = 0;
    $sum += ord $_ for (split "", $_[0]);
    return $rcolors[$sum % 9];
}

API::Std::mod_init('LaunchLibrary', 'isolation', '2.2', '3.0.0a11');
