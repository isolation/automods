# Module: GithubHook. See below for documentation.
# (c) 2014 isolation
# Released under the same license as Auto itself.
# This module depends upon a separate PHP script to
#   listen for github webhooks and update the db.
package M::GithubHook;
use 5.010;
use warnings;
use strict;
use API::Std qw(cmd_add cmd_del timer_add timer_del);
use API::IRC qw(privmsg);
use API::Log qw(slog);
use WWW::Shorten 'GitHub';

# used for caching chan_allowed() information
my %allow_hash;

sub _init {
    $Auto::DB->do('
        CREATE TABLE IF NOT EXISTS githubhook (
            after TEXT
            , ref TEXT
            , id TEXT
            , message TEXT
            , author_name TEXT
            , author_email TEXT
            , url TEXT
            , dist TEXT
            , repo_url TEXT
        )
    ');

    # stores channels we're allowed to talk in
    $Auto::DB->do('
        CREATE TABLE IF NOT EXISTS githubhook_talk (
            net TEXT COLLATE NOCASE
            , chan TEXT COLLATE NOCASE
        )
    ');

    # stores shortened urls we've created
    $Auto::DB->do('
        CREATE TABLE IF NOT EXISTS githubhook_urls (
            long_url TEXT
            , short_url TEXT
        )
    ');

    cmd_add('GITHUB', 2, 'cmd.github', \%M::GithubHook::HELP_GITHUB, \&M::GithubHook::cmd_github) or return;
    # default is to check the db for new commits every 10 seconds
    timer_add('githubhookcron', 2, 10, \&do_dbcheck);
    return 1;
}

sub _void {
    cmd_del('GITHUB');
    timer_del('githubhookcron');
    return 1;
}

our %HELP_GITHUB = (
    en => "No arg: show github announcement status. With arg: toggle status. \2SYNTAX:\2 GITHUB [ON|OFF]"
);

# called every 10 seconds (default) by timer
sub do_dbcheck {
    my $sth = $Auto::DB->prepare('
        SELECT
        ref
        , author_name
        , message
        , url
        , repo_url
        , id
        FROM githubhook
    ');
    $sth->execute;
    my @commits;
    while (my $row = $sth->fetchrow_hashref) {
        # handle some weird commit messages
        $row->{'message'} =~ s/\n\n/: /g;
        # use repo_url to get the repo owner and name
        $row->{'repo_url'} =~ s{^https://github\.com/}{};
        my ($repo_own, $repo_name) = split('/', $row->{'repo_url'});
        # use ref to get the current branch
        $row->{'ref'} =~ s{^refs/heads/}{};
        # turn id into short id
        $row->{'id'} = substr($row->{'id'}, 0, 7);
        # either find or create shortened url
        my $url = do_gitio($row->{'url'});
        # each commit's final message form is pushed into @commits
        push(@commits,
            "\x{03}" . colorfy($repo_own) . $repo_own . "\x{03}" .
            "/" .
            "\x{03}" . colorfy($repo_name) . $repo_name . "\x{03}" .
            " (in " . $row->{'ref'} . ") " .
            "\x{03}12" . $row->{'id'} . "\x{03}" . 
            " " . $row->{'author_name'} . ": " .
            $row->{'message'} .
            " " . $url);
    }

    # bail out if we've made it this far without any commits
    # TODO: maybe make less code be in the function that gets called
    #   every 10 seconds
    return unless defined $commits[0];

    # announce commit(s)
    foreach my $net (keys %Auto::SOCKET) {
        foreach my $chan (keys %{ $State::IRC::chanusers{$net} }) {
            if (chan_allowed($net, $chan)) {
                foreach my $commit (@commits) {
                    privmsg($net, $chan, $commit);
                }
            }
        }
    }
    
    # wipe commit db after displaying them
    $sth = $Auto::DB->prepare('
        DELETE FROM githubhook
    ');
    $sth->execute;

    return 1;
}

# called to either find or create a shortened link
sub do_gitio {
    my ($long_url) = @_;

    # if try_urldb finds an existing short_url for current
    #   long_url, just return that
    my $short_url = try_urldb($long_url);
    return $short_url if $short_url;

    # makeashorterlink() from WWW::Shortener::GitHub
    $short_url = makeashorterlink($long_url);

    # save this shortened link
    my $sth = $Auto::DB->prepare('
        INSERT INTO githubhook_urls (long_url, short_url) VALUES (?, ?)
    ');
    $sth->execute($long_url, $short_url);

    return $short_url;
}

# checks db for existing short link
sub try_urldb {
    my ($long_url) = @_;
    my $sth = $Auto::DB->prepare('
        SELECT short_url
        FROM githubhook_urls
        WHERE long_url = ?
    ');
    $sth->execute($long_url);
    if (my $row = $sth->fetchrow_hashref) {
        return $row->{'short_url'};
    }
    return 0;
}

# returns true/false allowed to speak in a net/chan combo
sub chan_allowed {
    my ($net, $chan) = @_;

    return 1 if ($allow_hash{$net}{$chan});

    my $sth = $Auto::DB->prepare('
        SELECT *
        FROM githubhook_talk
        WHERE net = ? AND chan = ?
    ') or return 0;
    $sth->execute($net, $chan) or return 0;
    if ($sth->fetchrow_hashref) {
        $allow_hash{$net}{$chan} = 1;
        return 1;
    }
    return 0;
}

sub cmd_github {
    my ($src, @argv) = @_;
    # no args, check current status
    if (!defined($argv[0])) {
        if (chan_allowed($src->{svr}, $src->{chan})) {
            privmsg($src->{svr}, $src->{chan}, "githubhook is \00303enabled\003 for ".$src->{chan});
        }
        else {
            privmsg($src->{svr}, $src->{chan}, "githubhook is \00304disabled\003 for ".$src->{chan});
        }
    }
    # modify on/off if needed
    else {
        if (($argv[0] eq 'on') && (!chan_allowed($src->{svr}, $src->{chan}))) {
            my $sth = $Auto::DB->prepare('INSERT INTO githubhook_talk (net, chan) VALUES (?, ?)');
            $sth->execute($src->{svr}, $src->{chan});
            $allow_hash{$src->{svr}}{$src->{chan}} = 1;
            privmsg($src->{svr}, $src->{chan}, "githubhook is now \00303enabled\003 for ".$src->{chan});
        }
        elsif (($argv[0] eq 'on') && (chan_allowed($src->{svr}, $src->{chan}))) {
            privmsg($src->{svr}, $src->{chan}, "githubhook is already on.");
        }
        elsif (($argv[0] eq 'off') && (chan_allowed($src->{svr}, $src->{chan}))) {
            my $sth = $Auto::DB->prepare('DELETE FROM githubhook_talk WHERE net = ? AND chan = ?');
            $sth->execute($src->{svr}, $src->{chan});
            delete $allow_hash{$src->{svr}}{$src->{chan}};
            privmsg($src->{svr}, $src->{chan}, "githubhook is now \00304disabled\003 for ".$src->{chan});
        }
        elsif (($argv[0] eq 'off') && (!chan_allowed($src->{svr}, $src->{chan}))) {
            privmsg($src->{svr}, $src->{chan}, "githubhook is already off.");
        }
    }
}

sub colorfy {
    my @rcolors = ("19", "20", "22", "24", "25", "26", "27", "28", "29");
    my $sum = 0;
    $sum += ord $_ for (split "", $_[0]);
    return $rcolors[$sum % 9];
}

API::Std::mod_init('GithubHook', 'Ootig', '1.0', '3.0.0a11');

__END__
