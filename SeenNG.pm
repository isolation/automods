# Module: SeenNG. See below for documentation.
# ############################
#   THIS HAS A HOOK THAT
#      NEEDS A MODIFIED AUTO
# ############################
# Copyright (C) 2014 isolation
# This program is free software. It is released under the same
#   licensing terms as Auto itself.
package M::SeenNG;
use 5.010;
use strict;
use warnings;
use API::Std qw(hook_add hook_del cmd_add cmd_del conf_get);
use API::IRC qw(notice privmsg act);
use API::Log qw(slog dbug);
use Time::Duration qw(ago duration);
my ($ALTS_DIR, $ALTS_URL);

sub _init {
    $ALTS_DIR = (conf_get('seenng:alts_dir'))[0][0];
    $ALTS_URL = (conf_get('seenng:alts_url'))[0][0];

    $Auto::DB->do(
        'CREATE TABLE IF NOT EXISTS seenng(
        net     TEXT NOT NULL COLLATE NOCASE,
        nick    TEXT NOT NULL COLLATE NOCASE,
        user    TEXT NOT NULL COLLATE NOCASE,
        host    TEXT NOT NULL COLLATE NOCASE,
        account TEXT COLLATE NOCASE,
        time    INTEGER NOT NULL,
        event   TEXT NOT NULL,
        chan    TEXT COLLATE NOCASE,
        message TEXT,
        meta    TEXT,
        PRIMARY KEY(net, nick)
        )'
    ) or return;

    $Auto::DB->do(
        'CREATE TABLE IF NOT EXISTS seenng_log(
        net     TEXT NOT NULL COLLATE NOCASE,
        nick    TEXT NOT NULL COLLATE NOCASE,
        user    TEXT NOT NULL COLLATE NOCASE,
        host    TEXT NOT NULL COLLATE NOCASE,
        account TEXT COLLATE NOCASE,
        time    INTEGER NOT NULL,
        event   TEXT NOT NULL,
        chan    TEXT COLLATE NOCASE,
        message TEXT,
        meta    TEXT
        )'
    ) or return;

    $Auto::DB->do(
        'CREATE TEMPORARY TABLE IF NOT EXISTS seenng_temp(
        net     TEXT NOT NULL COLLATE NOCASE,
        nick    TEXT NOT NULL COLLATE NOCASE,
        user    TEXT NOT NULL COLLATE NOCASE,
        host    TEXT NOT NULL COLLATE NOCASE,
        account TEXT COLLATE NOCASE,
        time    INTEGER NOT NULL,
        event   TEXT NOT NULL,
        chan    TEXT COLLATE NOCASE,
        message TEXT,
        meta    TEXT,
        PRIMARY KEY(net, nick, chan)
        )'
    ) or return;

    hook_add('on_cprivmsg', 'seen.cprivmsg', \&M::SeenNG::on_cprivmsg)
        or return;
    hook_add('on_kick', 'seen.kick', \&M::SeenNG::on_kick) or return;
    # this hook only exists on patched autos
    hook_add('on_inick', 'seen.inick', \&M::SeenNG::on_inick) or return;
    hook_add('on_rcjoin', 'seen.rcjoin', \&M::SeenNG::on_join) or return;
    hook_add('on_part', 'seen.part', \&M::SeenNG::on_part) or return;
    hook_add('on_notice', 'seen.notice', \&M::SeenNG::on_notice) or return;
    hook_add('on_topic', 'seen.topic', \&M::SeenNG::on_topic) or return;
    hook_add('on_cmode', 'seen.cmode', \&M::SeenNG::on_cmode) or return;
    hook_add('on_iquit', 'seen.iquit', \&M::SeenNG::on_iquit) or return;
    hook_add('on_rehash', 'seen.rehash', \&M::SeenNG::on_rehash) or return;

    cmd_add('SEEN', 2, 0, \%M::SeenNG::HELP_SEEN, \&M::SeenNG::cmd_seen)
        or return;
    cmd_add('SEENNICK', 2, 0, \%M::SeenNG::HELP_SEENNICK,
        \&M::SeenNG::cmd_seennick) or return;
    cmd_add('LASTSPOKE', 2, 0, \%M::SeenNG::HELP_LASTSPOKE,
        \&M::SeenNG::cmd_lastspoke) or return;
    cmd_add('SEENSTATS', 2, 0, \%M::SeenNG::HELP_SEENSTATS,
        \&M::SeenNG::cmd_seenstats) or return;
    cmd_add('NETSTATS', 2, 0, \%M::SeenNG::HELP_NETSTATS,
        \&M::SeenNG::cmd_netstats) or return;
    cmd_add('CHANSTATS', 2, 0, \%M::SeenNG::HELP_CHANSTATS,
        \&M::SeenNG::cmd_chanstats) or return;
    cmd_add('ALTS', 2, 0, \%M::SeenNG::HELP_ALTS, \&M::SeenNG::cmd_alts)
        or return;

    return 1;
}

sub _void {
    hook_del('on_cprivmsg', 'seen.cprivmsg') or return;
    hook_del('on_kick', 'seen.kick') or return;
    hook_del('on_inick', 'seen.inick') or return;
    hook_del('on_rcjoin', 'seen.rcjoin') or return;
    hook_del('on_part', 'seen.part') or return;
    hook_del('on_notice', 'seen.notice') or return;
    hook_del('on_topic', 'seen.topic') or return;
    hook_del('on_cmode', 'seen.cmode') or return;
    hook_del('on_iquit', 'seen.iquit') or return;
    hook_del('on_rehash', 'seen.rehash') or return;

    cmd_del('SEEN') or return;
    cmd_del('SEENNICK') or return;
    cmd_del('LASTSPOKE') or return;
    cmd_del('SEENSTATS') or return;
    cmd_del('NETSTATS') or return;
    cmd_del('CHANSTATS') or return;
    cmd_del('ALTS') or return;

    $Auto::DB->do('DROP TABLE seenng_temp') or return;

    return 1;
}

our %HELP_SEEN = (
    en => "This is a seen command. It takes nicks or masks.",
);

our %HELP_SEENNICK = (
    en => "This is a seen command. It only takes nicks.",
);

our %HELP_LASTSPOKE = (
    en => "This command says the last time a nick spoke in a channel.",
);

our %HELP_SEENSTATS = (
    en => "Shows statistics about the seen database.",
);

our %HELP_NETSTATS = (
    en => "Shows statistics about the current network's seen entries.",
);

our %HELP_CHANSTATS = (
    en => "Shows statistics about the current channel's seen entries.",
);

our %HELP_ALTS = (
    en => "Lists a nick's possible alternate nicks.",
);

sub on_cprivmsg {
    my ($src, $chan, @msg) = @_;
    my $time = time();
    
    if ($msg[0] =~ s/^\001//) {
        if ($msg[0] eq "ACTION") {
            shift(@msg);
            $msg[$#msg] = s/\001$//;
            memdb_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host},
                $time, "act", $chan, join(' ', @msg), undef);
        }
        return 1;
    }

    memdb_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, $time,
        "msg", $chan, join(' ', @msg), undef);
}

sub on_kick {
    my ($src, $chan, $kickee, $reason) = @_;
    my $time = time();

    # kickee
    db_add($src->{svr}, $kickee, $State::IRC::userinfo{$src->{svr}}{lc $kickee}{user},
        $State::IRC::userinfo{$src->{svr}}{lc $kickee}{host}, $time, "kicked",
        $chan, $reason, $src->{nick});
    # kicker
    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, $time,
        "kicking", $chan, $reason, $kickee);
    # remove from temp db
    memdb_del(0, $src->{svr}, $kickee, $chan);
}

sub on_inick {
    my ($src, $chans, $nnick) = @_;
    my $time = time();

    # nick -> newnick
    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, $time,
        "nick", $src->{chan}, $nnick, undef);
    # rnck (backwards tracking)
    db_add($src->{svr}, $nnick, $src->{user}, $src->{host}, $time, "rnck",
        $src->{chan}, $src->{nick}, undef);
    # handle lastseen's stuff
    memdb_del(1, $src->{svr}, $src->{nick}, undef);
    foreach (keys %{$chans}) {
        memdb_add($src->{svr}, $nnick, $src->{user}, $src->{host}, $time,
            "nicknew", $_, $src->{nick}, undef);
    }
}

sub on_join {
    my ($src, $chan) = @_;
    my $time = time();

    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, $time,
        "join", $chan, undef, undef);
    memdb_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, $time,
        "join", $chan, undef, undef);
}

sub on_part {
    my ($src, $chan, $msg) = @_;

    my $reason = ($msg ? $msg : "");
    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, time(),
        "part", $chan, $reason, undef);
    memdb_del(0, $src->{svr}, $src->{nick}, $chan);
}

sub on_notice {
    my ($src, $target, @msg) = @_;

    return if $target !~ /^#/;

    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, time(),
        "notice", $target, join(' ', @msg), undef);
}

sub on_topic {
    my ($src, @ntopic) = @_;
    # ntopic is not logged as it is not displayed in seen output
    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, time(),
        "topic", $src->{chan}, undef, undef);
}

sub on_cmode {
    my ($src, $chan, $mstring) = @_;
    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, time(),
        "mode", $chan, $mstring, undef);
}

sub on_iquit {
    my ($src, $chans, $reason) = @_;
    db_add($src->{svr}, $src->{nick}, $src->{user}, $src->{host}, time(),
        "quit", join(', ', keys %{$chans}), $reason, undef);
    memdb_del(1, $src->{svr}, $src->{nick}, undef);
}

# empty but leaving this here anyway
sub on_rehash {
    $ALTS_DIR = (conf_get('seenng:alts_dir'))[0][0];
    $ALTS_URL = (conf_get('seenng:alts_url'))[0][0];
}

sub memdb_add {
    my ($net, $nick, $user, $host, $time, $event, $chan, $msg, $meta) = @_;

    # TODO: tie this into UAM
    # TODO: write UAM
    my $account = undef;

    my $sth = $Auto::DB->prepare(
        'REPLACE
        INTO seenng_temp
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $sth->execute($net, $nick, $user, $host, $account, $time, $event, $chan,
        $msg, $meta);
}

sub db_add {
    my ($net, $nick, $user, $host, $time, $event, $chan, $msg, $meta) = @_;

    # TODO: tie this into UAM
    my $account = undef;

    my $sth = $Auto::DB->prepare(
        'REPLACE
        INTO seenng
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $sth->execute($net, $nick, $user, $host, $account, $time, $event, $chan,
        $msg, $meta);

    $sth = $Auto::DB->prepare(
        'INSERT
        INTO seenng_log
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $sth->execute($net, $nick, $user, $host, $account, $time, $event, $chan,
        $msg, $meta);
}

sub memdb_del {
    my ($all, $net, $nick, $chan) = @_;

    if ($all) {
        my $sth = $Auto::DB->prepare(
            'DELETE
            FROM seenng_temp
            WHERE net = ? AND nick = ?'
        ) or return;
        $sth->execute($net, $nick);
    } else {
        my $sth = $Auto::DB->prepare(
            'DELETE
            FROM seenng_temp
            WHERE net = ? AND nick = ? AND chan = ?'
        ) or return;
        $sth->execute($net, $nick, $chan);
    }
    return 1;
}

sub in_memdb {
    my ($net, $nick, $chan) = @_;
    my $sth = $Auto::DB->prepare(
        'SELECT *
        FROM seenng_temp
        WHERE net = ? AND nick = ? AND chan = ?'
    ) or return;
    $sth->execute($net, $nick, $chan);
    return ($sth->fetch() ? 1 : 0);
}

sub in_db {
    my ($net, $nick) = @_;
    my $sth = $Auto::DB->prepare(
        'SELECT *
        FROM seenng
        WHERE net = ? AND nick = ?'
    ) or return;
    $sth->execute($net, $nick);
    return ($sth->fetch() ? 1 : 0);
}

# handler for seen command
sub cmd_seen {
    my ($src, @argv) = @_;
    seen_logic(0, $src, @argv);
}

# handler for seennick command
sub cmd_seennick {
    my ($src, @argv) = @_;
    seen_logic(1, $src, @argv);
}

sub seen_logic {
    my ($nickonly, $src, @argv) = @_;

    if (!defined($argv[0])) {
        notice($src->{svr}, $src->{nick}, "Not enough parameters.");
        return;
    }

    # person asked about their own nick
    if (lc $argv[0] eq lc $src->{nick}) {
        privmsg($src->{svr}, $src->{chan}, "I last saw " . $src->{nick} .
            " performing a seen request in " . $src->{chan} .
            " 0 seconds ago.");
        return;
    # person asked about the bot's nick
    } elsif (lc $argv[0] eq lc $State::IRC::botinfo{$src->{svr}}{nick}) {
        privmsg($src->{svr}, $src->{chan}, "I last saw " .
            $State::IRC::botinfo{$src->{svr}}{nick} .
            " answering a seen request in " . $src->{chan} .
            " 0 seconds ago.");
        return;
    # if there's a * ? or ! then send it to the complex handler
    } elsif ($argv[0] =~ /[\*\?!]/) {
        complex_seen_logic($src, @argv);
        return;
    # person asked for nick that's in the channel
    } elsif (defined $State::IRC::chanusers{$src->{svr}}{$src->{chan}}{lc($argv[0])}) {
        privmsg($src->{svr}, $src->{chan}, $src->{nick} . ", $argv[0] is right here!");
        return;
    # nick not found in database
    } elsif (!in_db($src->{svr}, $argv[0])) {
        privmsg($src->{svr}, $src->{chan}, "I don't remember seeing " .
            $argv[0]);
        return;
    # nick is in database:
    } else {
        my $premsg;
        # get information about requested nick
        my $sth = $Auto::DB->prepare(
            'SELECT net, nick, user, host, time, event, chan, message, meta
            FROM seenng
            WHERE net = ? AND nick = ?'
        ) or return;
        $sth->execute($src->{svr}, $argv[0]);
        my $data = $sth->fetchrow_hashref;
        # if they didn't specify nick-only (seennick command),
        #   then check for any newer entries from very similar
        #   username + host combinations
        unless ($nickonly) {
            my $masked_host = $data->{host};
            # change host from network-asdf.example.com to %.example.com
            $masked_host =~ s/^[^\.]*\./%\./;
            $sth = $Auto::DB->prepare(
                'SELECT nick
                FROM seenng
                WHERE net = ? AND user = ? AND host LIKE ?
                ORDER BY time DESC'
            ) or return;
            $sth->execute($src->{svr}, $data->{user}, $masked_host);
            my @results;
            # build up an array with the results (if any)
            while (my $row = $sth->fetchrow_hashref) {
                push(@results, $row->{nick});
            }
            # skip this block if the newest result is the one originally asked for
            unless ($results[0] =~ /$argv[0]/i) {
                my $arraylen = @results;
                # change formatting based on how many results we get
                if ($arraylen >= 5) {
                    $premsg = "I found " . $arraylen . " matches to your query." .
                        " Here are the 5 most recent (sorted): " .
                        join(' ', @results[0..4]) . ". ";
                } else {
                    $premsg = "I found " . $arraylen . " matches to your query (sorted): " .
                        join(' ', @results) . ". ";
                }
                # get information for the newest result from earlier
                $sth = $Auto::DB->prepare(
                    'SELECT net, nick, user, host, time, event, chan, message, meta
                    FROM seenng
                    WHERE net = ? AND nick = ?'
                ) or return;
                $sth->execute($src->{svr}, $results[0]);
                # change $data to point to the most recent result
                $data = $sth->fetchrow_hashref;
            }
        }
        msg_formatter($src, $premsg, $data);
    }
}

# handle stuff with all kinds of freaky symbols and things
sub complex_seen_logic {
    my ($src, @argv) = @_;

    # escape \ to \\
    $argv[0] =~ s/\\/\\\\/g;
    # convert irc to sql for wildcards
    $argv[0] =~ s/_/\\_/g;
    $argv[0] =~ s/\*/%/g;
    $argv[0] =~ s/\?/_/g;

    # only a nick
    if ($argv[0] !~ /!/) {
        # get a count of how many things match
        my $sth = $Auto::DB->prepare(
            'SELECT COUNT(*) as count
            FROM seenng
            WHERE net = ? AND nick LIKE ?'
        ) or return;
        $sth->execute($src->{svr}, $argv[0]);
        my $data = $sth->fetchrow_hashref;
        # no results
        if ($data->{count} == 0) {
            privmsg($src->{svr}, $src->{chan}, "No matches were found.");
            return;
        # too many results
        } elsif ($data->{count} > 100) {
            privmsg($src->{svr}, $src->{chan}, "I found " . $data->{count} .
                " matches to your query; please refine it to see any output.");
            return;
        # 1-100 results
        } else {
            # request the actual data this time
            $sth = $Auto::DB->prepare(
                'SELECT nick
                FROM seenng
                WHERE net = ? AND nick LIKE ?
                ORDER BY time DESC'
            ) or return;
            $sth->execute($src->{svr}, $argv[0]);
            my @results;
            while (my $row = $sth->fetchrow_hashref) {
                push(@results, $row->{nick});
            }
            # grab the detailed info of the most recent result
            $sth = $Auto::DB->prepare(
                'SELECT net, nick, user, host, time, event, chan, message, meta
                FROM seenng
                WHERE net = ? AND nick = ?'
            ) or return;
            $sth->execute($src->{svr}, $results[0]);
            # $data2 is the most recent result and will be the one
            #   sent to msg_formatter()
            my $data2 = $sth->fetchrow_hashref;
            my $midmsg = "";
            my $result_list = "";
            if ($data->{count} > 5) {
                $midmsg = ". Here are the 5 most recent";
                $result_list = join(' ', @results[0..4]);
            } else {
                $result_list = join(' ', @results);
            }
            my $premsg = "I found " . $data->{count} . " matches to your" .
                " query" . $midmsg . " (sorted): " . $result_list . ". ";
            msg_formatter($src, $premsg, $data2);
            return;
        }
        return;
    # nick, user, and host
    } else {
        # split request on the ! (nick, userhost)
        my @temparray = split('!', $argv[0]);
        my $nick = shift(@temparray);
        # split (userhost) on the @
        my ($user, $host) = split('@', $temparray[0]);
        my $sth = $Auto::DB->prepare(
            'SELECT COUNT(*) AS count
            FROM seenng
            WHERE net = ? AND nick LIKE ? AND user LIKE ? AND host LIKE ?'
        ) or return;
        $sth->execute($src->{svr}, $nick, $user, $host);
        my $data = $sth->fetchrow_hashref;
        if ($data->{count} == 0) {
            privmsg($src->{svr}, $src->{chan}, "No matches were found.");
            return;
        } elsif ($data->{count} > 100) {
            privmsg($src->{svr}, $src->{chan}, "I found " . $data->{count} .
                " matches to your query; please refine it to see any output.");
            return;
        } else {
            $sth = $Auto::DB->prepare(
                'SELECT nick
                FROM seenng
                WHERE net = ? AND nick LIKE ? AND user LIKE ? AND host LIKE ?
                ORDER BY time DESC'
            ) or return;
            $sth->execute($src->{svr}, $nick, $user, $host);
            my @results;
            while (my $row = $sth->fetchrow_hashref) {
                push(@results, $row->{nick});
            }
            $sth = $Auto::DB->prepare(
                'SELECT net, nick, user, host, time, event, chan, message, meta
                FROM seenng
                WHERE net = ? AND nick = ?'
            ) or return;
            $sth->execute($src->{svr}, $results[0]);
            my $data2 = $sth->fetchrow_hashref;
            my $midmsg = "";
            my $result_list = "";
            if ($data->{count} > 5) {
                $midmsg = ". Here are the 5 most recent";
                $result_list = join(' ', @results[0..4]);
            } else {
                $result_list = join(' ', @results);
            }
            my $premsg = "I found " . $data->{count} . " matches to your query" .
                $midmsg . " (sorted): " .  $result_list . ". ";
            msg_formatter($src, $premsg, $data2);
            return;
        }
    }
}

sub cmd_lastspoke {
    my ($src, @argv) = @_;

    # missing argument
    if (!defined($argv[0])) {
        notice($src->{svr}, $src->{nick}, "Not enough parameters");
        return;
    }

    # user not in channel
    if (!defined($State::IRC::chanusers{$src->{svr}}{$src->{chan}}{lc($argv[0])})) {
        return;
    # asking about their own nick
    } elsif (lc $argv[0] eq lc $src->{nick}) {
        privmsg($src->{svr}, $src->{chan}, $src->{nick} .
            " last uttered a word very recently.");
        return;
    # asking about the bot
    } elsif (lc $argv[0] eq lc $State::IRC::botinfo{$src->{svr}}{nick}) {
        privmsg($src->{svr}, $src->{chan}, $State::IRC::botinfo{$src->{svr}}{nick} .
            " last uttered a word 0 seconds ago.");
        return;
    # they're in the channel but haven't done anything since the script loaded
    } elsif (!in_memdb($src->{svr}, $argv[0], $src->{chan})) {
        act($src->{svr}, $src->{chan}, "stares at database");
        return;
    } else {
        my $sth = $Auto::DB->prepare(
            'SELECT time, event, message
            FROM seenng_temp
            WHERE net = ? AND nick = ? AND chan = ?'
        );
        $sth->execute($src->{svr}, $argv[0], $src->{chan});
        my $res = $sth->fetchrow_hashref;
        my $age = ago(time() - $res->{time});
        given($res->{event}) {
            when (/msg/) {
                privmsg($src->{svr}, $src->{chan}, $argv[0] .
                    " last uttered a word " . $age);
                return;
            } when (/act/) {
                privmsg($src->{svr}, $src->{chan}, $argv[0] .
                    " last did something " . $age);
                return;
            } when (/join/) {
                privmsg($src->{svr}, $src->{chan}, $argv[0] .
                    " hasn't said anything since joining " . $age);
                return;
            } when (/nicknew/) {
                privmsg($src->{svr}, $src->{chan}, $argv[0] .
                    " changed nicks from " . $res->{message} . " " .
                    $age . ", but hasn't said anything since.");
                return;
            } default {
                act($src->{svr}, $src->{chan}, "stares at database (p2)");
                return;
            }
        }
    }
}

# info needed by all 3 *stats commands
sub stats_total_entries {
    my $sth = $Auto::DB->prepare('
        SELECT COUNT(*) AS count
        FROM seenng
    ');
    $sth->execute;
    return $sth->fetchrow_hashref->{'count'};
}

sub cmd_seenstats {
    my ($src, @argv) = @_;

    # find oldest entry
    my $sth = $Auto::DB->prepare('
        SELECT min(time) AS mintime, nick
        FROM seenng
    ');
    $sth->execute();
    my $oldest_data = $sth->fetchrow_hashref;
    my $oldest_ago = ago(time - $oldest_data->{mintime});
    my $oldest_nick = $oldest_data->{nick};

    # get total number of db entries
    my $total_entries = stats_total_entries();

    # get total number of distinct user@host combos
    $sth = $Auto::DB->prepare('
        SELECT COUNT(*) AS uniquehosts
        FROM (
            SELECT DISTINCT user, host
            FROM seenng
        )
    ');
    $sth->execute();
    my $unique_hosts = $sth->fetchrow_hashref->{uniquehosts};

    # send off the input
    privmsg($src->{svr}, $src->{chan}, "Currently I am tracking " .
        $total_entries . " nicks, which comprise " . $unique_hosts .
        " unique hosts. The oldest record is " . $oldest_nick .
        "'s, which is from " . $oldest_ago . ".");
    return 1;
}

sub cmd_netstats {
    my ($src, @argv) = @_;

    # find oldest entry
    my $sth = $Auto::DB->prepare('
        SELECT min(time) AS mintime
        FROM seenng
        WHERE net = ?
    ');
    $sth->execute($src->{svr});
    my $oldest_data = $sth->fetchrow_hashref;
    my $oldest_ago = duration(time - $oldest_data->{mintime});

    # get total number of db entries
    my $total_entries = stats_total_entries();

    # get number of db entries from network
    $sth = $Auto::DB->prepare('
        SELECT COUNT(*) AS count
        FROM seenng
        WHERE net = ?
    ');
    $sth->execute($src->{svr});
    my $network_entries = $sth->fetchrow_hashref->{count};

    # get total number of distinct user@host combos
    $sth = $Auto::DB->prepare('
        SELECT COUNT(*) AS uniquehosts
        FROM (
            SELECT DISTINCT user, host
            FROM seenng
            WHERE net = ?
        )
    ');
    $sth->execute($src->{svr});
    my $unique_hosts = $sth->fetchrow_hashref->{uniquehosts};

    my $percent = 100 * ($network_entries / $total_entries);
    my $rounded = sprintf("%.0f", $percent);

    # send off the input
    privmsg($src->{svr}, $src->{chan}, $src->{svr} . " is the source of " .
        "$rounded% ($network_entries/$total_entries) of the seen database " .
        "entries. On " . $src->{svr} . ", there were a total of " .
        $unique_hosts . " unique uhosts seen in the past $oldest_ago.");
    return 1;
}

sub cmd_chanstats {
    my ($src, @argv) = @_;

    # find oldest entry
    my $sth = $Auto::DB->prepare('
        SELECT min(time) AS mintime
        FROM seenng
        WHERE net = ? AND chan = ?
    ');
    $sth->execute($src->{svr}, $src->{chan});
    my $oldest_data = $sth->fetchrow_hashref;
    my $oldest_ago = duration(time - $oldest_data->{mintime});

    # get total number of db entries
    my $total_entries = stats_total_entries();

    # get number of db entries from channel
    $sth = $Auto::DB->prepare('
        SELECT COUNT(*) AS count
        FROM seenng
        WHERE net = ? AND chan = ?
    ');
    $sth->execute($src->{svr}, $src->{chan});
    my $channel_entries = $sth->fetchrow_hashref->{count};

    # get total number of distinct user@host combos
    $sth = $Auto::DB->prepare('
        SELECT COUNT(*) AS uniquehosts
        FROM (
            SELECT DISTINCT user, host
            FROM seenng
            WHERE net = ? AND chan = ?
        )
    ');
    $sth->execute($src->{svr}, $src->{chan});
    my $unique_hosts = $sth->fetchrow_hashref->{uniquehosts};

    my $percent = 100 * ($channel_entries / $total_entries);
    my $rounded = sprintf("%.0f", $percent);

    # send off the input
    privmsg($src->{svr}, $src->{chan}, $src->{chan} . " is the source of " .
        "$rounded% ($channel_entries/$total_entries) of the seen database " .
        "entries. In " . $src->{chan} . ", there were a total of " .
        $unique_hosts . " unique uhosts seen in the past $oldest_ago.");
    return 1;
}

sub cmd_alts {
    my ($src, @argv) = @_;
    my @results;

    # if no arg, run on person using command
    if (!defined $argv[0]) {
        $argv[0] = $src->{'nick'};
    }

    my $sth = $Auto::DB->prepare('
        SELECT user, host
	FROM seenng
	WHERE net = ? AND nick = ?
    ');
    $sth->execute($src->{svr}, $argv[0]);
    my $data = $sth->fetchrow_hashref;

    my $wchost = $data->{'host'};
    $wchost =~ s/^[^\.]*\./%\./;

    $sth = $Auto::DB->prepare('
        SELECT nick
	FROM seenng
	WHERE net = ? AND user LIKE ? AND host LIKE ?
	ORDER BY time ASC
    ');
    $sth->execute($src->{svr}, $data->{'user'}, $wchost);
    while (my $row = $sth->fetchrow_hashref) {
        push(@results, $row->{'nick'});
    }

    $sth->execute($src->{svr}, '%', $data->{'host'});
    while (my $row = $sth->fetchrow_hashref) {
        push(@results, $row->{'nick'} . "*");
    }

    my (%seen, @r);
    # pulled this straight from the old, bad seen script
    foreach my $a (@results) {
        (my $b = $a) =~ s/\*$//;
	unless ($seen{$b}) {
            push(@r, $a);
	    $seen{$a} = 1;
	}
    }

    my $rescount = @r;
    if ($rescount > 30) {
        my $resultsout = join("\n", @r);
	my $len_string = 8;
	my @chars = ('a'..'z','A'..'Z','0'..'9','_');
	my $random_string;
	foreach (1..$len_string) {
            $random_string .= $chars[rand @chars];
        }
	open (RESFILE, ">$ALTS_DIR$random_string.txt");
	print RESFILE "### " . $random_string . ".txt " . gmtime . "\n";
	print RESFILE "### " . $src->{nick} . " query: " . $argv[0] . "\n";
	print RESFILE $resultsout;
	close (RESFILE);
	privmsg($src->{svr}, $src->{chan}, $ALTS_URL . $random_string . ".txt (" .
            $rescount . " results)");
        return 1;
    }
    elsif ($rescount > 0) {
        my $resultsout = join(', ', @r);
	privmsg($src->{svr}, $src->{chan}, "alts (" . $rescount . "): " . $resultsout);
        return 1;
    }
    return 1;
}



sub msg_formatter {
    my ($src, $premsg, $data) = @_;
    my $ago = ago(time() - $data->{time});
    my $message = $premsg . $data->{nick} . " (" . $data->{user} . "@" . $data->{host} .
        ") was last seen";
    my $endmsg;
    if ($State::IRC::chanusers{$data->{net}}{$data->{chan}}{lc($data->{nick})}) {
        $endmsg = ". " . $data->{nick} . " is still on " . $data->{chan} . ".";
    }
    given ($data->{event}) {
        when (/join/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " joining " .  $data->{chan} . " " . $ago . $endmsg);
        } when (/mode/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " on " .  $data->{chan} . " setting modes \"" . $data->{message} .
                "\" " . $ago . $endmsg);
        } when (/kick$/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " being kicked from " . $data->{chan} . " by " . $data->{meta} .
                $ago . " with the reason (" . $data->{message} . ").");
        } when (/kicking/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " kicking " . $data->{meta} . " from " . $data->{chan} .
                " " . $ago . " with the reason (" . $data->{message} . ").");
        } when (/nick/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " changing nicks to " . $data->{message} . " " . $ago . ".");
        } when (/quit/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " quitting from " . $data->{chan} . " " . $ago . " stating (" .
                $data->{message} . ").");
        } when (/part/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " parting " . $data->{chan} . " " . $ago . " stating (" .
                $data->{message} . ").");
        } when (/notice/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " noticing " . $data->{chan} . " with \"" . $data->{message} .
                "\" " . $ago . ".");
        } when (/topic/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " setting the topic of " . $data->{chan} .
                " to something hilarious " . $ago . "." . $endmsg);
        } when (/rnck/) {
            privmsg($src->{svr}, $src->{chan}, $message .
                " changing nicks from " . $data->{message} . " " . $ago . ".");
        } default {
            act($src->{svr}, $src->{chan}, "stares at database (p3)");
        }
    }
}

API::Std::mod_init('SeenNG', 'isolation', '0.9', '3.0.0a11');

__END__
