# Module: AdvTitle. See below for documentation.
# Copyright (C) 2014 isolation
# This program is free software. It is released under the same
#   license as Auto itself.
package M::AdvTitle;
use strict;
use warnings;
use 5.010;
use API::Std qw(hook_add hook_del cmd_add cmd_del conf_get);
use API::IRC qw(privmsg);
use POSIX; # sec_to_time() uses strftime
use HTML::Entities;
use Net::Twitter::Lite::WithAPIv1_1;
use WebService::GData::YouTube;

# %allow_hash holds a cache of results from chan_allowed()
#   to reduce db operations
my (%allow_hash, $TW_CON_KEY, $TW_CON_SEC, $TW_ACC_TOK, $TW_ACC_SEC);

sub _init {
    $Auto::DB->do('CREATE TABLE IF NOT EXISTS advtitle (
          net TEXT COLLATE NOCASE
        , chan TEXT COLLATE NOCASE)') or return;

    cmd_add('ADVTITLE', 2, 'cmd.advtitle', \%M::AdvTitle::HELP_ADVTITLE, \&M::AdvTitle::cmd_toggle) or return;
    hook_add('on_cprivmsg', 'advtitle.urlscan', \&M::AdvTitle::director) or return;

    $TW_CON_KEY = (conf_get('advtitle:tw_consumer'))[0][0];
    $TW_CON_SEC = (conf_get('advtitle:tw_consumer_secret'))[0][0];
    $TW_ACC_TOK = (conf_get('advtitle:tw_access_token'))[0][0];
    $TW_ACC_SEC = (conf_get('advtitle:tw_access_token_secret'))[0][0];

    return 1;
}

sub _void {
    cmd_del('ADVTITLE') or return;
    hook_del('on_cprivmsg', 'advtitle.urlscan') or return;

    return 1;
}

our %HELP_ADVTITLE = (
    en => "This command toggles the display of link titles in a channel. \2Syntax:\2 ADVTITLE {on|off}",
);

sub director {
    my ($src, $chan, @msg) = @_;
    $src->{chan} = $chan;
    if (chan_allowed($src)) {
        foreach my $word (@msg) {
            if ($word =~ m{https?://(www\.)?youtu(\.be|be\.com)/}) {
                if ($word =~ m{youtu\.be/(.*)$}) {
                    youtube_call($src, $1);
                }
                else {
                    $word =~ m{(?:v=)([^&]+)};
                    youtube_call($src, $1);
                }
                return 1;
            }
            if ($word =~ m{https?://twitter\.com/(\#!/)?\w+/status/(\d+)}) {
                twitter_call($src, $2);
                return 1;
            }
        } # end foreach
    } # end if
    return 1;
}

# called when youtube link deteced
sub youtube_call {
    my ($src, $yt_id) = @_;
    # uses api v2 with no authentication
    my $yt = new WebService::GData::YouTube();
    my $video;
    eval { $video = $yt->get_video_by_id($yt_id); };
    # silently fail if necessary
    if ($@) { return; }
    privmsg($src->{svr}, $src->{chan}, "\x{03}01,00You\x{03}00,04Tube\x{03} - " .
        $video->title . " [" . sec_to_time($video->duration) . "]");
    return 1;
}

# called when twitter status link detected
sub twitter_call {
    my ($src, $t_id) = @_;
    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key        => $TW_CON_KEY,
        consumer_secret     => $TW_CON_SEC,
        access_token        => $TW_ACC_TOK,
        access_token_secret => $TW_ACC_SEC,
        ssl                 => 1,
    );
    my $status;
    eval { $status = $nt->show_status($t_id); };
    # silently fail if necessary
    if ($@) { return; }
    my $message = $status->{'text'};
    decode_entities($message);
    # these two loops replace t.co links with their real targets
    for (@{$status->{'entities'}->{'urls'}}) {
        $message =~ s{$_->{'url'}}{$_->{'expanded_url'}};
    }
    for (@{$status->{'entities'}->{'media'}}) {
        $message =~ s{$_->{'url'}}{https://$_->{'display_url'}};
    }
    privmsg($src->{svr}, $src->{chan}, "\x{03}02<" . $status->{'user'}->{'screen_name'} .
        ">\x{03} " . $message);
    return 1;
}

# converts seconds to (H:)?M:S format
sub sec_to_time {
    my ($sec) = @_;
    my $pattern;
    if ($sec < 60) {
        $pattern = "0:%S";
    }
    elsif ($sec < 3600) {
        $pattern = "%M:%S";
    }
    else {
        $pattern = "%H:%M:%S";
    }
    return strftime $pattern, gmtime $sec;
}


# controls the database of channels we're allowed to show links in
sub cmd_toggle {
    my ($src, @argv) = @_;

    # no args, check current status
    if (!defined($argv[0])) {
        if (chan_allowed($src)) {
            privmsg($src->{svr}, $src->{chan}, "AdvTitle is \00303enabled\003 for ".$src->{chan});
        }
        else {
            privmsg($src->{svr}, $src->{chan}, "AdvTitle is \00304disabled\003 for ".$src->{chan});
        }
    }
    # modify on/off if needed
    else {
        if (($argv[0] eq 'on') && (!chan_allowed($src))) {
            my $sth = $Auto::DB->prepare('INSERT INTO advtitle (net, chan) VALUES (?, ?)');
            $sth->execute($src->{svr}, $src->{chan});
            $allow_hash{$src->{svr}}{$src->{chan}} = 1;
            privmsg($src->{svr}, $src->{chan}, "AdvTitle is now \00303enabled\003 for ".$src->{chan});
        }
        elsif (($argv[0] eq 'on') && (chan_allowed($src))) {
            privmsg($src->{svr}, $src->{chan}, "AdvTitle is already on.");
        }
        elsif (($argv[0] eq 'off') && (chan_allowed($src))) {
            my $sth = $Auto::DB->prepare('DELETE FROM advtitle WHERE net = ? AND chan = ?');
            $sth->execute($src->{svr}, $src->{chan});
            privmsg($src->{svr}, $src->{chan}, "AdvTitle is now \00304disabled\003 for ".$src->{chan});
            delete $allow_hash{$src->{svr}}{$src->{chan}};
        }
        elsif (($argv[0] eq 'off') && (!chan_allowed($src))) {
            privmsg($src->{svr}, $src->{chan}, "AdvTitle is already off.");
        }
    }
}

# checks if we're allowed to post link titles
sub chan_allowed {
    my ($src) = @_;

    return 1 if ($allow_hash{$src->{svr}}{$src->{chan}});

    my $sth = $Auto::DB->prepare('SELECT * FROM advtitle WHERE net = ? AND chan = ?') or return 0;
    $sth->execute($src->{svr}, $src->{chan}) or return 0;
    if ($sth->fetchrow_hashref) {
        $allow_hash{$src->{svr}}{$src->{chan}} = 1;
        return 1;
    }
    return 0;
}

API::Std::mod_init('AdvTitle', 'isolation', '1.0', '3.0.0a11');

__END__

=head1 NAME

AdvTitle - A module for showing link titles.

=head1 VERSION

 1.0

=head1 SYNOPSIS

 <isolation> .advtitle
 <automato> AdvTitle is disabled for #auto-debug
 <isolation> .advtitle on
 <automato> AdvTitle is now enabled for #auto-debug

 <isolation> https://www.youtube.com/watch?v=ZHVL3z6PXe4
 <automato> YouTube - Bodega Cats [03:59]

 <isolation> https://twitter.com/DiGiornoPizza/status/435507334937198593
 <automato> <DiGiornoPizza> omg mean girls is on that is so fetch

=head1 DESCRIPTION

This module creates the ADVTITLE command, which controls
whether or not the bot announces titles in a channel. When
enabled, it will show the title of YouTube links and
the contents of Twitter links. So I guess it's not really
showing titles. TODO: change name or change module

You must set your Twitter OAuth keys in the bot's config
file for it to function.

Config layout:

 advtitle {
     tw_consumer "consumer_key_here";
     tw_consumer_secret "consumer_secret_here";
     tw_access_token "access_token_here";
     tw_access_token_secret "access_token_secret_here";
 }

=head1 AUTHOR

This module was written by isolation.

=head1 LICENSE AND COPYRIGHT

This module is Copyright 2014 isolation.

This module is released under the same licensing terms as Auto itself.

=cut

