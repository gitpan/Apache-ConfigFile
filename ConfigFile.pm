
# Copyright (c) 1999-2001, Nathan Wiger <nate@wiger.org>
# Try "perldoc Apache/ConfigFile.pm" for documentation

package Apache::ConfigFile;

=head1 NAME

Apache::ConfigFile - Parse an Apache style httpd.conf config file

=head1 SYNOPSIS

    # 
    # Parse the standard Apache httpd.conf
    #
    use Apache::ConfigFile;
    my $ac = Apache::ConfigFile->read("/etc/apache/httpd.conf");

    # You can get at individual configuration commands using
    # the cmd_config() method:

    my $hostname = $ac->cmd_config('ServerName');
    my $doc_root = $ac->cmd_config('DocumentRoot');

    # Multiple values are returned as a list, meaning that you
    # can directly assign them to an array or even a hash:

    my @perlmods = $ac->cmd_config('PerlModule');
    my %ftypes   = $ac->cmd_config('FileTypeSuffix');

    # Then, you can reset the context of the calls using the
    # cmd_context() method so that you are accessing the 
    # appropriate values. For example, if you had a context 
    # block like
    #
    #   <VirtualHost "10.1.1.2">
    #       ServerName "www.mydomain.com"
    #       DocumentRoot "/www/mydomain.com/htdocs"
    #   </VirtualHost>
    #
    # You would get to this definition via:

    my $vh = $ac->cmd_context(VirtualHost => '10.1.1.2');
    my $vhost_server_name = $vh->cmd_config('ServerName');
    my $vhost_doc_root    = $vh->cmd_config('DocumentRoot');

    # If you had multiple VirtualHost declarations for a
    # given IP (as would be the case if you're using 
    # NameVirtualHosts), you could cycle through them with:

    for my $vh ($ac->cmd_context(VirtualHost => '10.1.1.3')) {
        my $vhost_server_name = $vh->cmd_config('ServerName');
        my $vhost_doc_root    = $vh->cmd_config('DocumentRoot');
    } 

    # In fact, even better you can "search" for one by specifying
    # an additional set of criteria to cmd_config(). To just get
    # the VirtualHost "docs.mydomain.com", for example, try:
 
    my $docs_svr = $ac->cmd_context(VirtualHost => '10.1.1.3',
                                    ServerName  => 'docs.mydomain.com');
    my $docs_base_dir = $docs_svr->cmd_config('DocumentRoot');

    # In addition, this module will automatically autoload
    # directive-based functions, meaning you can get to
    # commonly-used commands by name:

    my $host = $ac->server_name;
    my $root = $ac->server_root;
    my $html = $ac->document_root;

    # You also get the mod_perl dir_config() command to get
    # at PerlSetVar declarations by name. So, the block:
    #
    #   <Location /myapp>
    #       SetHandler perl-script
    #       PerlHandler Apache::MyApp
    #       PerlSetVar MyAppRoot "/usr/myapp"
    #       PerlSetVar MyAppRefresh "30m"
    #   </Location>
    #
    # Would be accessed as:

    my $loc = $ac->cmd_context(Location => '/myapp');
    my $app_root = $loc->dir_config('MyAppRoot');
    my $app_refr = $loc->dir_config('MyAppRefresh');

    # Finally, you get two other utility methods. The first
    # will return the current data structure verbatim, and
    # the second one will return a dump which you can print
    # out or parse or whatever:

    my %config = $self->data;
    warn "DEBUG: ", $self->dump, "\n";

=cut

use Carp;
use strict;
use vars qw($VERSION $AUTOLOAD);

# This is a modified VERSION that turns RCS "1.3" into "0.03"
$VERSION = do { my($r)=(q$Revision: 1.14 $=~/[\d\.]+/g); $r--; sprintf("%d.%02d", split '\.', $r)};

# Default options
my @OPT = qw(
    ignore_case   0
    fix_booleans  0
    expand_vars   0
    raise_error   0
);

sub _error {
    my $self = shift;
    if ($self->{raise_error}) {
        croak(@_);
    } else { 
        carp(@_);
    }
}

sub _fixcase {
    # handles ignore_case (case insensitive)
    my $self = shift;
    my $key  = shift;
    $self->{ignore_case} ? lc($key) : $key;
}

# This is our "new" method
*new = \&read;
sub read {
    my $self = shift;
    my $class = ref $self || $self;

    # handle different arg forms - singular and multi
    my %opt;
    if (@_ == 1) {
        %opt = @OPT;
        $opt{file} = shift;
    } else {
        # hash of stuff
        %opt = (@OPT, @_);
    }

    # just in case
    $opt{file} ||= "/usr/local/apache/conf/httpd.conf";

    my $s = bless \%opt, $class;

    # Now read the config file
    $s->reread;
    return $s;
}

my $server_root = '';
sub _include {
    # This recursively expands any "include" lines
    my $self = shift;
    my $file = shift;

    # add the server root unless it's a /full/path/name
    $file = "$server_root/$file" if $file !~ m!^/! && $server_root;

    open(CONF, "<$file")
        || $self->_error("Cannot read '$file': $! (did you define ServerRoot first?)");
    chomp(my @conf = <CONF>);
    close(CONF);

    # Check for any include lines - must do this inline!
    for (my $i=0; $i < @conf; $i++) {
        if ($conf[$i] =~ /^(?:ServerRoot)\s+"?([^"]+)"?/i) {
            $server_root = $1;
        } elsif ($conf[$i] =~ /^(?:Include|AccessConfig|ResourceConfig)\s+"?([^"]+)"?/i) {
            my @f = $self->_include($1);
            splice @conf, $i, 1, @f;    # stick it inline
        }
    }
    return @conf;    
}

sub reread {
    my $self = shift;
    my $file = shift() || $self->{file} || $self->_error("Undefined config file");

    # Need to pre-parse in order to look for any "Include" lines
    # We then use splice to put together a "master config" of all
    # the lines that make up our config file, in order
    my @conf = $self->_include($file);

    # Create a hash and a parse level "pointer"
    my $conf = {};
    my $cmd_context = $conf;
    my @parselevel = ();
    my $line = 0;

    foreach (@conf) {
        $line++;

        # Strip newlines/comments
        s/\s*#.*//;

        # If nothing's left, continue
        next unless $_;

        # This substitutes in re-used variable on the right side of the file
        # We have to handle the ignore_case flag hence the expression
        # This doesn't quite work 100% - only vars defined at the top level
        # are visible for re-substitution
        if ($self->{expand_vars}) { 
            local($^W) = 0 ;
            s#\$\{?(\w+)\}?#my $k =  $self->_fixcase($1);$conf->{$k}#eg;
        }

        # This may be a <stuff> junk </stuff>, in which case we need
        # to nest our data struct!
        if (m#^\s*</(\S+)\s*>\s*$#) {
            # match </close> - walk up
            $cmd_context = pop @parselevel;
            $self->_error("$file line $line: Mismatched closing tag '$1'") unless $cmd_context;
            next;
        } elsif (m#^\s*<(\S+)\s*(["']*)(.*)\2>\s*$#) {
            # create new sublevel in parsing
            my $k = $self->_fixcase($1);
            push @parselevel, $cmd_context;

            # this is complicated - we have to maintain an array
            # of substratum because of VirtualHost directives.
            # as such we have to create another element of an
            # array which is a hashref on the fly. whew!
            #$cmd_context = $cmd_context->{$k}->{$3} = {}; # doesn't support VirtualHost

            if ($cmd_context->{$k}{$3} && ref $cmd_context->{$k}{$3} eq 'ARRAY') {
                my $len = scalar @{$cmd_context->{$k}{$3}};
                $cmd_context = $cmd_context->{$k}{$3}[$len] = {};
            } else {
                $cmd_context->{$k}{$3} = [];
                $cmd_context = $cmd_context->{$k}{$3}[0] = {};
            }
            next;
        }

        # Split up the key and the value. The @val regexp code dynamically
        # differentiates between "space strings" and array, values.
        my($key, $r) = m!^\s*\s*(\w+)\s*(?=\s+)(.*)!;             # split up key
        my(@val)     = $r =~ m!\s+(?:"([^"]*)"|([^\s,]+))\n?!g;   # split up val
        @val = grep { defined } @val;                             # lose undef values

        # Check for "on/off" or "true/false" or "yes/no"
        if ($self->{fix_booleans}) {
            $val[0] = 1 if ($val[0] =~ m/^(?:true|on|yes)$/i);
            $val[0] = 0 if ($val[0] =~ m/^(?:false|off|no)$/i);
        }

        # Make the key lowercase unless we're ignore_case
        $key = $self->_fixcase($key);

        # Now, use eval to correctly assign variables automagically
        # This implicitly takes care of syntax errors in the value
        #eval { $cmd_context->{$key} = (@val > 1) ? [ @val ] : $val[0] };
        #eval { push @{$cmd_context->{$key}}, [ @val ] };
        #eval { $cmd_context->{$key} = [ @val ] };
        # Must push or else can't handle repeating keys
        # It's up to the user to know how they should parse this if it matters
        eval { push @{$cmd_context->{$key}}, @val };

        $self->_error("$file line $line: Bad config assignment: $@") if $@;
    }

    # Now setup our pointers in our data structure
    $self->{config_data} = $conf;
    $self->{cmd_context} = $self->{config_data};

    # they can ask for either a %hash or $hashref
    return wantarray ? %{$conf} : $conf;
}

sub cmd_context {
    my $self = shift;
    my $dir  = $self->_fixcase(shift) || return undef;
    my $spec = $self->_fixcase(shift) || '';    # can be empty (like <Limit>)

    # if no pattern reset to top level
    return $self->{cmd_context} = $self->{config_data} unless $spec;

    # and see if we have additional specifications, which will
    # indicate patterns to search for in deeper levels; for ex:
    #
    #    $ac->cmd_context(VirtualHost => '10.1.1.2', ServerName => 'bob.com');
    # 
    # would return the <VirtualHost> block with the ServerName bob.com
    # or, they could just plain specify the index of the one they want:
    #
    #    $ac->cmd_context(VirtualHost => '10.1.1.2', 2);
    #    $ac->cmd_context(VirtualHost => '10.1.1.2');   # same as ,0
    #
    # maybe this exposes too much internal rep, but oh well...

    # redo our "pointer"
    unless (ref $self->{cmd_context}{$dir} eq 'HASH'
            && exists $self->{cmd_context}{$dir}{$spec}) {
        #$self->_error("Could not find a config context matching that specification");
        return undef;
    }
    my $ptr = $self->{cmd_context}{$dir}{$spec};
    my @ptr = ();

    # maybe it's a nested hash/array/hash structure?
    if (ref $ptr eq 'ARRAY') {
        if (@_ == 1) {
            #$ptr = $ptr->[shift()];
            @ptr = ($ptr->[$_[0]]);
        } elsif (@_ == 2) {
            my $ok = 0;
            my $k = $self->_fixcase(shift());
            my $v = shift;
            for my $p (@{$ptr}) {
                if (exists $p->{$k} && $p->{$k}[0] eq $v) {
                    #$ptr = $p;
                    push @ptr, $p;
                    $ok++;
                    last unless wantarray;
                }
            }
            #$self->_error("Could not find a config context matching that specification") unless $ok;
            return undef unless $ok;
        } elsif (@_) {
            $self->_error("Sorry, only one additional search param is supported to cmd_context");
        } else {
            #$ptr = $ptr->[0];
            @ptr = @{$ptr};
        }
    } else {
        @ptr = ($ptr);
    }

    # Old way was to change the pointer inline, but this makes
    # the data structures hard to nagivate across nesting
    #return $self->{cmd_context} = $ptr;

    # Now we peel off a new object that's a copy of our old
    # one (with the new {cmd_context}) making nav easier
    # This is time-intensive so only do so if wantarray
    my @ret = ();
    @ptr = ($ptr[0]) unless wantarray;
    for my $ptr (@ptr) {
        my $copy = { %{$self} };
        $copy->{cmd_context} = $ptr;
        push @ret, bless($copy, __PACKAGE__);
    }
    return wantarray ? @ret : $ret[0];
}

sub cmd_config {
    my $self = shift;
    my $dir  = $self->_fixcase(shift);

    # if we have any extra args, just set stuff verbatim
    if (@_) {
        carp "Setting arguments via ".__PACKAGE__."->cmd_config is experimental";
        push @{$self->{cmd_context}{$dir}}, [ @_ ];
    }

    # point to the value that was requested
    # return the entire current data struct when no args
    my $ptr = {};
    if ($dir) {
        $ptr = $self->{cmd_context}{$dir};
    } else {
        $ptr = $self->{cmd_context};
    }

    # return the value in the appropriate format
    return undef unless $ptr;

    if (ref $ptr eq 'HASH') {
        # If it is a hash, then this means it is a nested data
        # structure so returning it directly makes no sense.
        # Instead, we return a list of the keys so the user
        # can always count on getting a list back
        my @keys = keys %{$ptr};
        return wantarray ? @keys : $keys[0];
    } elsif (ref $ptr eq 'ARRAY') {
        return wantarray ? @{$ptr}
                         : ${$ptr}[0];
    } else {
        return $ptr;
    }
    return undef;
}

sub dir_config {
    # special for mod_perl!
    my $self = shift;
    my $dir  = $self->_fixcase(shift) || return undef;
    my %var = $self->perl_set_var;    # must autoload to handle ignore_case flag
    while(my($k,$v) = each %var) {
        # the value should always be a "scalar" by mod_perl rules
        return $v if $dir eq $self->_fixcase($k);
    }
    return undef;
}

*readconf = \&data;  # legacy support (dammit!)
sub data {
    # just return the data portion
    my $self = shift;
    return wantarray ? %{$self->{cmd_context}} : $self->{cmd_context};
}

sub dump {
    # easy
    my $self = shift;
    require Data::Dumper;
    $Data::Dumper::Varname = 'config';
    return Data::Dumper::Dumper($self->{cmd_context});
}

sub AUTOLOAD {
    # access the appropriate thing-a-ma-jigger
    my $self = shift;
    my($dir) = $AUTOLOAD =~ /.*::(.*)/;
    return if $dir eq 'DESTROY';    # eek!

    $dir =~ s/_(\w)/\u$1/g;         # lose underscores
    $dir = ucfirst $dir;

    return $self->cmd_config($dir);
}

# This recursively expands a data structure, as would someday
# be needed for the ->write() routine.
sub _expand ($$$);
sub _expand ($$$) {
    my $data;
    my $db = shift;

    my $indent = shift() + 1;
    my $tabs = "\t" x $indent;

    my $last = shift;   # what the last state was

    if (ref $db eq 'HASH') {
       for my $k (sort keys %{$db}) {
           my $v = $db->{$k};
           my $ref = ref $v;
           if ($ref eq 'HASH') {
               $v = "{" . _expand($v, $indent, $ref) . "\n$tabs}";
           } elsif ($ref eq 'ARRAY') {
               $v = "[" . _expand($v, $indent, $ref) . "\n$tabs]";
           } elsif ($ref) {
               croak("Unhandleable '$ref' reference in Apache::ConfigFile data structure?");
           } else {
               #$v =~ s/\</\&lt\;/g;
               #$v =~ s/\>/\&gt\;/g;
           }
           $data .= "\n$tabs$k => $v,";
       } 
    } elsif (ref $db eq 'ARRAY') {
       for (my $i=0; $i < @$db; $i++) {
           my $v = $db->[$i];
           my $ref = ref $v;
           if ($ref eq 'HASH') {
               $v = "{" . _expand($v, $indent, $ref) . "\n$tabs}";
           } elsif ($ref eq 'ARRAY') {
               $v = "[" . _expand($v, $indent, $ref) . "\n$tabs]";
           } elsif ($ref) {
               croak("Unhandleable reference '$ref' in Apache::ConfigFile data structure?");
           } else {
               #$v =~ s/\</\&lt\;/g;
               #$v =~ s/\>/\&gt\;/g;
           }
           #$data .= "\n$tabs$i =&gt; $v,";
           $data .= "\n$tabs$v,";
       }
    } else {
       $data .= "\n$tabs$db";
    }
    return $data;
}

sub write {
    croak "Sorry, ".__PACKAGE__."->write is not finished.\nWould you like to finish it?";

    my $self = shift;
    my $file = shift() || $self->{file} || $self->_error("Undefined config file");
    #open(CONF, ">$write") || $self->_error("Cannot write config file '$file': $!");

    # We start at the top level and expand it appropriately...
    my $ptr = $self->{config_data};
    my $str = _expand($ptr, 0, ref $ptr);

    #close(CONF);
}

1;	# removing this == bad

__END__

=head1 DESCRIPTION

This module parses the Apache httpd.conf, or any compatible config
file, and provides methods for you to access the values from the
config file. The above examples show basic usage of this module,
which boils down to reading a given config file and then using
the C<cmd_config()> and C<cmd_context()> functions to access its
information.

By default, the config file is parsed more or less "verbatim",
meaning that directives are case-sensitive, variables are I<not>
interpolated, and so forth. These features can be changed by
options given to the C<read()> function (see below).

The C<read()> function is the constructor, which reads in a
configuration file and returns an object with methods that can
be used to access directives from the file. The simplest usage
is something like this:

    use Apache::ConfigFile;
    my $ac = Apache::ConfigFile->read("/path/to/httpd.conf");

Which would parse the Apache C<httpd.conf> file and give you back
an C<$ac> object with the following methods:

=over

=item cmd_config()

Used to access individual configuration commands

=item cmd_context()

Used to change the context of the commands you're accessing

=item dir_config()

Used to access values set via the C<PerlSetVar> command (for C<mod_perl>)

=back

For more examples of standard Apache usage, you should read the
L</"SYNOPSIS"> above or skip down to the L</"FUNCTIONS">.

In addition to reading an Apache config file, this module provides
some options that allow the Apache syntax to be extended. This is
useful if you're writing your own application and want to use a
config file resembling Apache's.

    use Apache::ConfigFile;
    my $ac = Apache::ConfigFile->read(
                    file => "/path/to/httpd.conf",
                    ignore_case  => 1,
                    expand_vars  => 1,
                    fix_booleans => 1
             );

These options would allow us to write a custom config file looking
like this:

    BaseDir    "/export"
    ImageDir   "$BaseDir/images"
    BuildDir   "$BaseDir/images"

    <Release "sw7">
        OfficialName "Software Update 7"
        BuildPath "$BuildDir/sw7/REL"         
        Platforms Solaris Linux IRIX HP-UX
        Supported Yes
    </Release>

Then, you would be able to access it as follows:

    use Apache::ConfigFile;
    my $swcfg = Apache::ConfigFile->read("releases.conf");

    # Note that case does not matter
    my $rel = $swcfg->cmd_context(release => 'sw7');
    my $ofn = $rel->cmd_config('bUiLdPaTh');
    
    # This is autoloading + fix_booleans
    unless ($rel->supported) {
        die "Sorry, that release is not supported";
    } 

There are several things to note. First, all our C<cmd_> functions
are now case-insensitive, since we turned on the C<ignore_case>
flag (which is off by default). Second, notice a couple things
about our C<unless> statement. Since we specified C<fix_booleans>,
the words "Yes", "True", and "On" will be converted to C<1> (true),
and "No", "False", and "Off" will become C<0> (false). As such,
we can use these directives in boolean statements throughout our
code.

In addition, since this module provides autoloading so that all
config commands are turned into functions, you can access values
directly, as shown by the statement C<< $rel->supported >>. This
statement is equivalent to the longer C<< $rel->cmd_config('supported') >>.

Finally, if you just wish to manually navigate the data structure
(which is a huge hash of hashes of arrays) without using the
accessor functions, you can return the thing verbatim:

    my %conf = $ac->data;
    print "Release is $conf{'release'}\n";

However, note that the internal representation is subject to change,
so using the accessor functions is recommended.

=head1 FUNCTIONS

=head2 read(filename)

=head2 read(file => filename, opt => val, opt => val)

The C<read()> function reads the configuration file specified and
returns an object with methods to access its directives. C<read()>
has two calling forms. In the simplest version, you just specify
a filename, and a new C<Apache::ConfigFile> object is returned.
Or, if you want to specify options, you specify each one as a
key/value pair. For example:

   # keep default options
   my $ac = Apache::ConfigFile->read("httpd.conf");

   # override the case sensitivity and boolean translation
   my $ac = Apache::ConfigFile->read(file => "httpd.conf",
                                     ignore_case  => 1,
                                     fix_booleans => 1);

The list of valid options is:

=over

=item file

Path to configuration file. If not provided then
C</usr/local/apache/conf/httpd.conf> is used by default.

=item ignore_case

If set to 1, then all directives will be case-insensitive
and stored in lowercase. Defaults to 0.

=item fix_booleans

If set to 1, then the words "Yes", "True", and "On" will be
converted to C<1> (true), and "No", "False", and "Off" will
become C<0> (false). This allows you to easily use these
types of directives in if statements. Defaults to 0.

=item expand_vars

If set to 1, then you can reuse variables that you have
defined elsewhere in the config file by prefixing them
with a C<$>. For example:

    BaseDir   "/export"
    HomeDir   "$BaseDir/home"

Currently, you can only reuse variables defined at the very
top-level. Variables defined within context blocks of any
kind cannot be reused.

=item raise_error

If set to 1, any type of error becomes fatal. Defaults to 0.

=back

=head2 cmd_config(directive)

This is the meat-and-potatoes of the module; the method that
lets you access configuration directives from your file.
Examples:

    my $server_name = $ac->cmd_config('ServerName');
    my $doc_root = $ac->cmd_config('DocumentRoot');

This is a straightforward function. You just give it the name
of the directive you wish to access and you get its value
back. Multiple values are returned as a list, meaning that you
can directly assign them to an array or even a hash (if the
data structure is guaranteed to be consistent enough):

    my @perlmods = $ac->cmd_config('PerlModule');
    my %ftypes   = $ac->cmd_config('FileTypeSuffix');

=head2 cmd_context(context => specification)

You use this command to change the current context of what you
are looking at. When you start, you are looking at the very
top-level of the config file. However, you may want to look
at a specific virtual host or directory. You can do so with
this command.

    my $vhost = $ac->cmd_context(VirtualHost => '10.1.1.2');
    my $server_name = $vhost->cmd_config('ServerName');
    my $doc_root    = $vhost->cmd_config('DocumentRoot');

You'll notice that the C<cmd_context()> call returns an
object will all the same methods, but the data structure
now starts from that point down. The context has been altered
so that you are looking at the C<VirtualHost 10.1.1.2>. As such,
any commands that you do will affect that part of the configuration.

In some cases, you may have multiple definitions for a certain
context level. One example is C<VirtualHost> blocks if you're
using C<NameVirtualHosts>. You have two options. First, you
could cycle through all of them in sequence:

    for my $vhost ($ac->cmd_context(VirtualHost => '10.1.1.2')) {
        # ... do stuff ...
    }

Or, if you know which one you want specifically, you can specify
one additional "search" parameter. For example, if you want the
C<superfoo> server, you could say:

    my $sf = $ac->cmd_context(VirtualHost => '10.1.1.2',
                              ServerName  => 'superfoo');

And this would look for a context block that looked something
like this:

    <VirtualHost "10.1.1.2">
        ServerName "superfoo"
        # ... more config options ...
    </VirtualHost>

You can access nested configurations as well. If you had a
configuration like this:

    <Location "/upload">
        SetHandler perl-script
        PerlHandler Apache::MyUploadModule
        PerlSetVar MyUploadModuleMaxsize "5M"
        PerlSetVar MyUploadModuleTimeout "300s"
        <Limit>
            require user "bob"
            require user "jim"
        </Limit>
    </Location>

And you wanted to find out what the valid users were who could
access this page, you would navigate it like so:

    my $loc = $ac->cmd_context(Location => '/upload');
    my $lim = $loc->cmd_context('Limit');
    my @users = $lim->cmd_config('require');

Or, more succintly:

    my @users = $ac->cmd_context(Location => '/upload')
                   ->cmd_context('Limit')->cmd_config('require');

Since C<cmd_context()> returns an object pointing to the next
context, you can chain calls together to get to a deeply nested
level.

=head2 dir_config()

This routine is provided for C<mod_perl> compatibility. It allows
you to access configuration commands specified via the C<PerlSetVar>
directive. So, assuming the above example, you could access the
settings for C<MyUploadModule> like so:

    my $upload = $ac->cmd_context(Location => '/upload');

    my $maxsize = $upload->dir_config('MyUploadModuleMaxsize');
    my $timeout = $upload->dir_config('MyUploadModuleTimeout');

The idea is to provide an interface which walks and talks roughly
like Apache actually would.

=head2 data()

This returns the entire data structure under the current context
verabatim. So, you could get all the values for a C<VirtualHost>
with:

    my $vh = $ac->cmd_context(VirtualHost => '10.1.1.4');
    my %vhost = $vh->data;

If you specified C<ignore_case>, then all the keys will be
lowercase; otherwise, they will be in whatever case they are in
the config file.

=head2 dump()

This returns a dump of the current data structure in string form.
So for debugging purposes you can dump the config with something
like this:

    warn "DUMP: ", $ac->dump, "\n";

=head2 reread()

You can use this function to reread the configuration file. For
example, maybe you want your application to reread its config
if it receives a C<SIGHUP>:

    $SIG{HUP} = \&handler;
    sub handler {
        my $sig = shift;
        if ($sig eq 'HUP') {
            # reread our config file on kill -HUP
            $config->reread;
        }
    }

The above would handle a C<SIGHUP> by rereading the config file.

=head2 write([file])

This writes the configuration out to disk. If no file is specified,
then the one passed to C<read()> is used. This method is currently
under development and does not work. Patches welcome.

=head2 autoloaded calls

In addition to the above, you can also access values by calling 
a function named for the config command directly:

    my $server_name = $ac->cmd_config('ServerName');

Is the same as:

    my $server_name = $ac->server_name;

Underscores in the function name are taken as a place to put
an uppercase letter. So these are all equivalent:

    my $doc_root = $ac->cmd_config('DocumentRoot');
    my $doc_root = $ac->DocumentRoot;   # looks silly
    my $doc_root = $ac->document_root;

Note, though, that the following would B<not> work unless you had
set the C<ignore_case> option:

    my $doc_root = $ac->documentroot;   # won't work

This is because it will look for the directive C<Documentroot>,
which probably doesn't exist.

=head1 NOTES

Currently C<LogFormat> and any other directive with embedded quotes,
even if escaped, are not handled correctly. I know there is a fix for
it but I have a mental block and can't figure it out. Help wanted.

This module does B<not> mimic the behavior of a live Apache config.
In particular, there is no configuration "inheritance". This means
that subdirectories and virtual hosts do not inherit their defaults
from the upper levels of the configuration. This may or may not
change in a future version.

This module has only been tested and used on UNIX platforms. Patches
to fix problems with other OSes are welcome.

There are currently no tests written for this module. Sorry, short
on time. Inventive (or even non-inventive!) tests welcome.

=head1 VERSION

$Id: ConfigFile.pm,v 1.14 2001/09/06 23:57:54 nwiger Exp $

=head1 AUTHOR

Copyright (c) 1999-2001, Nathan Wiger <nate@wiger.org>. All Rights
Reserved.

This module is free software; you may copy this under the terms of
the GNU General Public License, or the Artistic License, copies of
which should have accompanied your Perl kit.

=cut

