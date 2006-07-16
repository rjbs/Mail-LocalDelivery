package Mail::LocalDelivery;

my $debuglevel=0;
use Carp;

use strict;
use File::Basename;
use Mail::Internet;
use Sys::Hostname; (my $HOSTNAME = hostname) =~ s/\..*//;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $ASSUME_MSGPREFIX);
use Fcntl ':flock';
@ISA = qw(Mail::Internet);


$ASSUME_MSGPREFIX = 0;

# stolen from linux sysexits.h, YMMV on other OSes.  sorry, but it was either this or forcing everyone to h2ph.
use constant EX_USAGE       => 64; # command line usage error
use constant EX_DATAERR     => 65; # data format error
use constant EX_NOINPUT     => 66; # cannot open input
use constant EX_NOUSER      => 67; # addressee unknown
use constant EX_NOHOST      => 68; # host name unknown
use constant EX_UNAVAILABLE => 69; # service unavailable
use constant EX_SOFTWARE    => 70; # internal software error
use constant EX_OSERR       => 71; # system error (e.g., can't fork)
use constant EX_OSFILE      => 72; # critical OS file missing
use constant EX_CANTCREAT   => 73; # can't create (user) output file
use constant EX_IOERR       => 74; # input/output error
use constant EX_TEMPFAIL    => 75; # temp failure; user is invited to retry
use constant EX_PROTOCOL    => 76; # remote error in protocol
use constant EX_NOPERM      => 77; # permission denied
use constant EX_CONFIG      => 78; # configuration error

use constant DEFERRED  => EX_TEMPFAIL;
use constant REJECTED  => 100;
use constant DELIVERED => 0;

$VERSION = '0.22';

=head1 NAME

Mail::LocalDelivery - Deliver mail to a local mailbox

=head1 SYNOPSIS

    use Mail::LocalDelivery;
    my $x = new Mail::LocalDelivery(\@some_text);
    $x->deliver(); # Append to /var/spool/mail/you
    $x->deliver("/home/simon/mail/test") # Deliver to Unix mailbox
    $x->deliver("/home/simon/mail/test/") # Deliver to maildir

=head1 DESCRIPTION

This module has been superseded by L<Email::LocalDelivery>, which provides
nearly all of the same features, and more, and better.  Use it instead.

=cut

sub _debug {
    my ($priority, $what) = @_; 
    return if $debuglevel < $priority;
    chomp $what; chomp $what;
    my ($subroutine) = (caller(1))[3]; $subroutine =~ s/(.*):://;
    my ($line)       = (caller(0))[2];
    warn "$line($subroutine): $what\n";
}

=head1 METHODS

=head2 C<new($data, %options)>

This creates a new object for delivery. The data can be in the form of
an array of lines, a C<Mail::Internet> object, a C<MIME::Entity> object
or a filehandle. 

As for options, if you don't want the "new/cur/tmp" structure of a classical
maildir, set the one_for_all option, and you'll still get
the unique filenames.

  new($data, one_for_all => 1);

If you want "%" signs in delivery addresses to be expanded according to
strftime(3), you can turn on the C<interpolate_strftime> option: 

  new ($data, interpolate_strftime => 1);

"interpolate_strftime" is not enabled by default for two
reasons: backward compatibility (though nobody I know has a
% in any mail folder name) and username interpolation: many
people like to save messages by their correspondent's
username, and that username may contain a % sign.  If you
are one of these people, you should

  $username =~ s/%/%%/g;

You can also supply an "emergency" option to determine where mail
goes in the worst case scenario.

=cut

sub new { 
    my $class = shift;
    my $stuff = shift;

    my %opts = @_;

    my $self;

    # What sort of stuff do we have?
    if (ref $stuff eq "Mail::Internet" or ref $stuff eq "MIME::Entity"){ 
        $self = $stuff;
    } elsif (ref $stuff eq "ARRAY" or ref $stuff eq "GLOB") { 
        $self = Mail::Internet->new($stuff);
    } else { 
        croak "Data was neither a mail object or a reference to something I understand";
    }
    $self->{opts} = \%opts;
    $self->{opts}->{interpolate_strftime} ||= 0;
    $self->{opts}->{one_for_all}          ||= 0;

    my $default_unixbox = (grep { -d $_ } qw(/var/spool/mail/ /var/mail/))[0] 
                        . getpwuid($>);
    my $default_maildir = ((getpwuid($>))[7]) . "/Maildir/";

    my $default_mbox = 
        $ENV{MAIL} 
        || (-e $default_unixbox && $default_unixbox)
        || (-d $default_maildir . "cur" && $default_maildir);

    $self->{default_mbox} = $default_mbox;
    $self->{opts}->{emergency} ||= $default_mbox;

    return bless $self, $class;
}

=head2 C<deliver($where, ...)>

You can choose to deliver the mail into a mailbox by calling
the C<deliver> method; with no argument, this will look in:

=over 3

=item 1

C<$ENV{MAIL}>

=item 2 

F</var/spool/mail/you>

=item 3

F</var/mail/you>

=item 4

F<~/Maildir/>

=back

Unix mailboxes are opened append-write, then locked F<LOCK_EX>, the mail
written and then the mailbox unlocked and closed.  If Mail::LocalDelivery sees
that you have a maildir style system, where the argument is a directory, it'll
deliver in maildir style. If the path you specify does not exist,
Mail::LocalDelivery will assume mbox, unless it ends in /, which means maildir.

If multiple maildirs are given, Mail::LocalDelivery will use hardlinks to
deliver to them, so that multiple hardlinks point to the same underlying file.
(If the maildirs turn out to be on multiple filesystems, you get multiple
files.)

If your arguments contain "/", C<deliver> will create arbitarily deep
subdirectories accordingly.  Untaint your input by saying

  $username =~ s,/,-,g;

C<deliver> will return the filename(s) that it saved to.

  my  @pathnames = deliver({noexit=>1}, file1, file2, ... );
  my ($pathname) = deliver({noexit=>1}, file1);

If for any reason C<deliver> is unable to write the message (eg. you're over
quota), Mail::LocalDelivery will attempt delivery to the C<emergency> mailbox.
If C<deliver> was called with multiple destinations, the C<emergency> action
will only be taken if the message couldn't be delivered to any of the desired
destinations.  By default the C<emergency> mailbox is set to the system
mailbox.  If we were unable to save to the emergency mailbox,
C<Mail::LocalDelivery> will return an empty list.

=cut

sub _nifty_interpolate { # perform ~user and %Y%m%d strftime interpolation
    my $self = shift;
    my @out = @_;
    my @localtime = localtime;
    if ($self->{opts}->{interpolate_strftime} and grep { /%/ } @out) {
        require POSIX;
        import POSIX qw(strftime);
        @out = map { strftime($_, @localtime) } @out;
    }
    @out = map {
      s{^~/}     {((getpwuid($>))[7])."/"}e;
      s{^~(\w+)/}{((getpwnam($1))[7])."/"}e;
      $_
    } @out;
    return @out;
}

# ----------------------------------------------------------
sub deliver {
# ----------------------------------------------------------
    my $self = shift;

    my @files = $self->_nifty_interpolate(@_);
    if (not @files) { @files = ($self->{default_mbox}) }

    my @actually_saved_to_files = ();

    _debug(2,"delivering to @files");

    # from man procmailrc:
    #         If  it  is  a  directory,  the mail will be delivered to a newly
    #         created, guaranteed to be unique file named $MSGPRE- FIX* in the
    #         specified directory.  If the mailbox name ends in "/.", then this
    #         directory  is  presumed  to  be  an  MH folder;  i.e.,  procmail
    #         will use the next number it finds available.  If the mailbox name
    #         ends  in  "/",  then  this directory  is presumed to be a maildir
    #         folder; i.e., proc- mail will deliver the message to a file in a
    #         subdirectory named  "tmp"  and  rename  it  to be inside a
    #         subdirectory named "new".  If the mailbox is  specified  to  be
    #         an  MH folder  or maildir folder, procmail will create the neces-
    #         sary directories if they don't exist,  rather  than  treat the
    #         mailbox as a non-existent filename.  When procmail is delivering
    #         to directories, you can specify multiple direc- tories  to
    #         deliver  to  (procmail  will  do  so utilising hardlinks).
    #
    # for now we will support maildir and mbox delivery.
    # MH delivery and MSGPREFIX delivery remain todo.

    my %deliver_types = (mbox      => [],
                        maildir   => [],
                        mh        => [],
                        msgprefix => [],
                        );

    for my $file (@files) {
        my $mailbox_type = $self->_mailbox_type($file);
        push @{$deliver_types{$mailbox_type}}, $file;
        _debug(3, "$file is of type $mailbox_type");
    }

    foreach my $deliver_type (sort keys %deliver_types) {
        next if not @{$deliver_types{$deliver_type}};
        my $deliver_handler = "deliver_to_$deliver_type";
        _debug(3, "calling deliver handler $deliver_handler(@{$deliver_types{$deliver_type}})");

        # Don't try to deliver to things for which we have no delivery method.
        next unless $self->can($deliver_handler);

        push @actually_saved_to_files, $self->$deliver_handler(@{$deliver_types{$deliver_type}});
    }

    if (@actually_saved_to_files == 0) {

        # in this section you will often see
        #    $!=DEFERRED; die("unable to write to @files or to $emergency");
        # we say this instead of
        #    exit DEFERRED;
        # because we want to be able to trap the die message inside an eval {}
        # for testing purposes.

        my $emergency = $self->{opts}->{emergency};
        if (not defined $emergency) {
            return ();
        } else {
            if (grep ($emergency eq $_, @files)) { # already tried that mailbox
                return ();
            } else {
                my $deliver_type = $self->_mailbox_type($emergency);
                my $deliver_handler = "deliver_to_$deliver_type";
                @actually_saved_to_files = $self->$deliver_handler($emergency);
                return if not @actually_saved_to_files;
            }
        }
    }
    return @actually_saved_to_files;
}

# ----------------------------------------------------------
sub _mailbox_type {
# ----------------------------------------------------------
    my $self = shift;
    my $file = shift;

    return 'maildir' if $file =~ /\/$/;
    return 'mh'      if $file =~ /\/\.$/;

    if (-d $file) {
        return 'maildir' if (-d "$file/tmp" and -d "$file/new");
        if (exists($self->{opts}->{ASSUME_MSGPREFIX})) {
            return 'msgprefix' if $self->{opts}->{ASSUME_MSGPREFIX};
            return "maildir";
        }
        return 'msgprefix' if $ASSUME_MSGPREFIX;
        return 'maildir';
    }
    return 'mbox';
}

# ----------------------------------------------------------
sub _deliver_to_mbox {
# ----------------------------------------------------------
    my $self = shift;
    my @saved_to = ();
    foreach my $file (@_) {
        # auto-create the parent dir.
        if (my $mkdir_error = _mkdir_p(dirname($file))) {
          _debug(0, $mkdir_error);
          next;
        }
        my $error = $self->_write_message(
          $file,
          {
            need_lock => 1,
            need_from => 1,
            extra_newline => 1
          }
        );
        if (not $error) { push @saved_to, $file; }
        else            { _debug(1, $error); }
    }
    return @saved_to;
}

# ----------------------------------------------------------
sub _write_message {
# ----------------------------------------------------------
    my $self       = shift;
    my $file       = shift;
    my $write_opts = shift || {};

    $write_opts->{need_from} = 1 if not defined $write_opts->{need_from};
    $write_opts->{need_lock} = 1 if not defined $write_opts->{need_lock};
    $write_opts->{extra_newline} = 0 if not defined $write_opts->{extra_newline};

    _debug(3, "writing to $file; options @{[%$write_opts]}");

    unless (open(FH, ">>$file")) { return "Couldn't open $file: $!"; }

    if ($write_opts->{need_lock}) {
      my $lock_error = _audit_get_lock(\*FH, $file);
      return $lock_error if $lock_error;
    }

    seek FH, 0, 2;

    if (not $write_opts->{need_from} and $self->head->header->[0] =~ /^From\s/)
    {
        _debug(3,"mbox From line found, stripping because we're maildir");
        $self->head->delete("From ");
        $self->unescape_from();
    }

    if ($write_opts->{'need_from'} and $self->head->header->[0] !~ /^From\s/) {
        _debug(3,"No mbox From line, making one up.");
        if (exists $ENV{UFLINE}) {
            _debug(3,"Looks qmail, but preline not run, prepending UFLINE, RPLINE, DTLINE");
            print FH $ENV{UFLINE};
            print FH $ENV{RPLINE};
            print FH $ENV{DTLINE};
        } else {
            my $from = (
              $self->get('Return-path') ||
              $self->get('Sender')      ||
              $self->get('Reply-To')    ||
              'root@localhost'
            );
            chomp $from;
            # comment <email@address> -> email@address
            $from = $1 if $from =~ /<(.*?)>/;

            # email@address (comment) -> email@address
            $from =~ s/\s*\(.*\)\s*//;

            # if any whitespace remains, get rid of it.
            $from =~ s/\s+//g;

            # strip timezone.
            (my $fromtime = localtime) =~ s/(:\d\d) \S+ (\d{4})$/$1 $2/;

            print FH "From $from  $fromtime\n";
        }
    }

    _debug(4, "printing self as mbox string.");
    print FH $self->as_string;
    # extra \n added because mutt seems to like a "\n\nFrom " in mbox files
    print FH "\n" if $write_opts->{extra_newline};

    if ($write_opts->{need_lock}) {
        flock(FH, LOCK_UN) or return "Couldn't unlock $file";
    }

    close FH or return "Couldn't close $file after writing: $!";
    _debug(4, "returning success.");
    return 0; # success
}

# ----------------------------------------------------------
# NOT IMPLEMENTED
# ----------------------------------------------------------

sub _deliver_to_mh        { my $self = shift; my @saved_to=(); } 
sub _deliver_to_msgprefix { my $self = shift; my @saved_to=(); }

# variables for _deliver_to_maildir

my $maildir_time    = 0;
my $maildir_counter = 0;

# ----------------------------------------------------------
sub _deliver_to_maildir {
# ----------------------------------------------------------
    my $self = shift;
    my @saved_to = ();

    _debug(3, "will write to @_");

    # since mutt won't add a lines tag to maildir messages, we'll add it here
    unless (length $self->get("Lines")) {
        my $num_lines = @{$self->body};
        $self->head->add("Lines", $num_lines);
        _debug(4,"Adding Lines: $num_lines header");
    }

    if ($maildir_time != time) { $maildir_time = time; $maildir_counter = 0 } else { $maildir_counter++ }

    # write the tmp file.
    # hardlink to all the new files.
    # unlink the temp file.

    # 
    # write the tmp file in the first writable maildir directory.
    # 

    my $tmp_path;
    foreach my $file (my @maildirs = @_) {

        $file =~ s/\/$//;
        my $tmpdir = $self->{opts}->{"one_for_all"} ? $file : "$file/tmp";

        my $msg_file;
        do {
            $msg_file = join ".", ($maildir_time, $$ . "_$maildir_counter", $HOSTNAME); $maildir_counter++;
        } while ( -e "$tmpdir/$msg_file" );

        $tmp_path = "$tmpdir/$msg_file";
        _debug(3,"writing to $tmp_path");

        # auto-create the maildir.
        if (my $mkdir_error = _mkdir_p(
                                      $self->{opts}->{"one_for_all"}
                                      ? ($file)
                                      : map { "$file/$_" } qw(tmp new cur))) { _debug(0, $mkdir_error); next; }

        my $error = $self->_write_message($tmp_path, {need_from=>0, need_lock=>0});
        if (not $error) { last; }  # only write to the first writeable maildir
        else            { _debug(1, $error);
                          unlink $tmp_path;
                          $tmp_path = undef;
                          next;
                      }
    }

    if (not $tmp_path) { return 0 } # unable to write to any of the specified maildirs.

    # 
    # it is now in tmp/.  hardlink to all the new/ destinations.
    # 

    foreach my $file (my @maildirs = @_) {
        $file =~ s/\/$//;

        my $msg_file;
        my $newdir = $self->{opts}->{"one_for_all"} ? $file : "$file/new";
        $maildir_counter = 0;
        do {
            $msg_file = join ".", ($maildir_time=time, $$ . "_$maildir_counter", $HOSTNAME); $maildir_counter++;
        } while ( -e "$newdir/$msg_file" );

        # auto-create the maildir.
        if (my $mkdir_error = _mkdir_p(
                                      $self->{opts}->{"one_for_all"}
                                      ? ($file)
                                      : map { "$file/$_" } qw(tmp new cur))) { _debug(0, $mkdir_error); next; }

        my $new_path = "$newdir/$msg_file";
        _debug(3,"maildir: hardlinking to $new_path");

        if    (link $tmp_path, $new_path) { push @saved_to, $new_path; }
        else {
            require Errno; import Errno qw(EXDEV);
            if ($! == &EXDEV) { # Invalid cross-device link, see /usr/**/include/*/errno.h
                _debug(0,"Couldn't link $tmp_path to $new_path: $!");
                _debug(0,"attempting direct maildir delivery to $new_path...");
                push @saved_to, $self->_deliver_to_maildir($file);
                next;
            }
            else { _debug(0,"Couldn't link $tmp_path to $new_path: $!"); }
        }
    }

    # unlink the temp file
    unlink $tmp_path or _debug(1,"Couldn't unlink $tmp_path: $!");
    return @saved_to;
}
# ----------------------------------------------------------
# utility functions
# ----------------------------------------------------------

sub _audit_get_lock {
    my $FH   = shift;
    my $file = shift;
    _debug(4, "  attempting to lock  file $file");
    for (1..10) {
        if (flock($FH, LOCK_EX)) { _debug(4, "  successfully locked file $file"); return; }
        else                     { sleep $_ and next; }
    }
    _debug(1,my $errstr="Couldn't get exclusive lock on $file");
    return $errstr;
}

sub _mkdir_p { # mkdir -p (also create parents if necessary)
    return if not @_;
    return if not length $_[0];
    foreach (@_) {
        next if -d $_;
        while (/\/$/) { chop }
        _debug(4, "$_ doesn't exist, creating.");
        if (my $error = _mkdir_p(dirname($_))) { return $error }
        mkdir ($_, 0777) or return "unable to mkdir $_: $!";
    }
    return;
}

sub _myALRM { die "alarm\n" }

1;
__END__

=head1 CAVEATS

If your mailbox file in /var/spool/mail/ doesn't already exist, you may need to
use your standard system MDA to create it.  After it's been created,
Mail::LocalDelivery should be able to append to it.  Mail::LocalDelivery may
not be able to create /var/spool/mail because programs run from .forward don't
inherit the special permissions needed to create files in that directory.

=head1 SEE ALSO

L<Mail::Internet>, L<Mail::SMTP>, L<Mail::Audit>

=head1 AUTHORS


This code was originally written by Simon Cozens, extended by Meng Weng Wong,
maintained by Jose Castro, then passed along for maintenance to the Perl Email
Project.

Its current maintainer is Ricardo Signes, sponsored by Listbox.com.

=head1 LICENSE

The usual: this program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
