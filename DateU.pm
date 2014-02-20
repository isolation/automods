# Module: DateU
# Copyright (C) 2014 isolation
# This program is free software. It is released under the same
#   licensing terms as Auto itself.
package M::DateU;
use strict;
use warnings;
use API::Std qw(cmd_add cmd_del);
use API::IRC qw(privmsg);

# Initialization subroutine.
sub _init {
    cmd_add('DATEU', 0, 0, \%M::DateU::HELP_DATEU, \&M::DateU::cmd_dateu) or return;
    return 1;
}

# Void subroutine.
sub _void {
    cmd_del('DATEU') or return;
    return 1;
}

our %HELP_DATEU = (
    en => "Prints the current UTC time in human time and epoch time."
);

# dateu command
sub cmd_dateu {
	my ($src, @args) = @_;
	privmsg($src->{svr}, $src->{chan}, gmtime . " || " . time);	
}

# Start initialization.
API::Std::mod_init('DateU', 'isolation', '1.01', '3.0.0a11');

__END__

=head1 NAME

DateU - Show UTC time

=head1 VERSION

 1.01

=head1 SYNOPSIS

 <isolation> .dateu
 <automato> Thu Feb 20 03:51:49 2014 || 1392868309

=head1 DESCRIPTION

This module creates the DATEU comand, which shows you the
current time in UTC. Also shows the current epoch time.

=head1 AUTHOR

This module was written by isolation.

=head1 LICENSE AND COPYRIGHT

This module is Copyright 2014 isolation.

This module is released under the same licensing terms as Auto itself.

=cut

