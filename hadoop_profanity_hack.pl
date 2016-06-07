#!/usr/bin/perl
#line 2 "/home/pmarup/perl5/bin/par.pl"
eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

package __par_pl;

# --- This script must not use any modules at compile time ---
# use strict;

#line 158

my ($par_temp, $progname, @tmpfile);
END { if ($ENV{PAR_CLEAN}) {
    require File::Temp;
    require File::Basename;
    require File::Spec;
    my $topdir = File::Basename::dirname($par_temp);
    outs(qq{Removing files in "$par_temp"});
    File::Find::finddepth(sub { ( -d ) ? rmdir : unlink }, $par_temp);
    rmdir $par_temp;
    # Don't remove topdir because this causes a race with other apps
    # that are trying to start.

    if (-d $par_temp && $^O ne 'MSWin32') {
        # Something went wrong unlinking the temporary directory.  This
        # typically happens on platforms that disallow unlinking shared
        # libraries and executables that are in use. Unlink with a background
        # shell command so the files are no longer in use by this process.
        # Don't do anything on Windows because our parent process will
        # take care of cleaning things up.

        my $tmp = new File::Temp(
            TEMPLATE => 'tmpXXXXX',
            DIR => File::Basename::dirname($topdir),
            SUFFIX => '.cmd',
            UNLINK => 0,
        );

        print $tmp "#!/bin/sh
x=1; while [ \$x -lt 10 ]; do
   rm -rf '$par_temp'
   if [ \! -d '$par_temp' ]; then
       break
   fi
   sleep 1
   x=`expr \$x + 1`
done
rm '" . $tmp->filename . "'
";
            chmod 0700,$tmp->filename;
        my $cmd = $tmp->filename . ' >/dev/null 2>&1 &';
        close $tmp;
        system($cmd);
        outs(qq(Spawned background process to perform cleanup: )
             . $tmp->filename);
    }
} }

BEGIN {
    Internals::PAR::BOOT() if defined &Internals::PAR::BOOT;

    eval {

_par_init_env();

if (exists $ENV{PAR_ARGV_0} and $ENV{PAR_ARGV_0} ) {
    @ARGV = map $ENV{"PAR_ARGV_$_"}, (1 .. $ENV{PAR_ARGC} - 1);
    $0 = $ENV{PAR_ARGV_0};
}
else {
    for (keys %ENV) {
        delete $ENV{$_} if /^PAR_ARGV_/;
    }
}

my $quiet = !$ENV{PAR_DEBUG};

# fix $progname if invoked from PATH
my %Config = (
    path_sep    => ($^O =~ /^MSWin/ ? ';' : ':'),
    _exe        => ($^O =~ /^(?:MSWin|OS2|cygwin)/ ? '.exe' : ''),
    _delim      => ($^O =~ /^MSWin|OS2/ ? '\\' : '/'),
);

_set_progname();
_set_par_temp();

# Magic string checking and extracting bundled modules {{{
my ($start_pos, $data_pos);
{
    local $SIG{__WARN__} = sub {};

    # Check file type, get start of data section {{{
    open _FH, '<', $progname or last;
    binmode(_FH);

    # Search for the "\nPAR.pm\n signature backward from the end of the file
    my $buf;
    my $size = -s $progname;
    my $offset = 512;
    my $idx = -1;
    while (1)
    {
        $offset = $size if $offset > $size;
        seek _FH, -$offset, 2 or die qq[seek failed on "$progname": $!];
        my $nread = read _FH, $buf, $offset;
        die qq[read failed on "$progname": $!] unless $nread == $offset;
        $idx = rindex($buf, "\nPAR.pm\n");
        last if $idx >= 0 || $offset == $size || $offset > 128 * 1024;
        $offset *= 2;
    }
    last unless $idx >= 0;

    # Seek 4 bytes backward from the signature to get the offset of the 
    # first embedded FILE, then seek to it
    $offset -= $idx - 4;
    seek _FH, -$offset, 2;
    read _FH, $buf, 4;
    seek _FH, -$offset - unpack("N", $buf), 2;
    read _FH, $buf, 4;

    $data_pos = (tell _FH) - 4;
    # }}}

    # Extracting each file into memory {{{
    my %require_list;
    while ($buf eq "FILE") {
        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        my $fullname = $buf;
        outs(qq(Unpacking file "$fullname"...));
        my $crc = ( $fullname =~ s|^([a-f\d]{8})/|| ) ? $1 : undef;
        my ($basename, $ext) = ($buf =~ m|(?:.*/)?(.*)(\..*)|);

        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        if (defined($ext) and $ext !~ /\.(?:pm|pl|ix|al)$/i) {
            my ($out, $filename) = _tempfile($ext, $crc);
            if ($out) {
                binmode($out);
                print $out $buf;
                close $out;
                chmod 0755, $filename;
            }
            $PAR::Heavy::FullCache{$fullname} = $filename;
            $PAR::Heavy::FullCache{$filename} = $fullname;
        }
        elsif ( $fullname =~ m|^/?shlib/| and defined $ENV{PAR_TEMP} ) {
            # should be moved to _tempfile()
            my $filename = "$ENV{PAR_TEMP}/$basename$ext";
            outs("SHLIB: $filename\n");
            open my $out, '>', $filename or die $!;
            binmode($out);
            print $out $buf;
            close $out;
        }
        else {
            $require_list{$fullname} =
            $PAR::Heavy::ModuleCache{$fullname} = {
                buf => $buf,
                crc => $crc,
                name => $fullname,
            };
        }
        read _FH, $buf, 4;
    }
    # }}}

    local @INC = (sub {
        my ($self, $module) = @_;

        return if ref $module or !$module;

        my $filename = delete $require_list{$module} || do {
            my $key;
            foreach (keys %require_list) {
                next unless /\Q$module\E$/;
                $key = $_; last;
            }
            delete $require_list{$key} if defined($key);
        } or return;

        $INC{$module} = "/loader/$filename/$module";

        if ($ENV{PAR_CLEAN} and defined(&IO::File::new)) {
            my $fh = IO::File->new_tmpfile or die $!;
            binmode($fh);
            print $fh $filename->{buf};
            seek($fh, 0, 0);
            return $fh;
        }
        else {
            my ($out, $name) = _tempfile('.pm', $filename->{crc});
            if ($out) {
                binmode($out);
                print $out $filename->{buf};
                close $out;
            }
            open my $fh, '<', $name or die $!;
            binmode($fh);
            return $fh;
        }

        die "Bootstrapping failed: cannot find $module!\n";
    }, @INC);

    # Now load all bundled files {{{

    # initialize shared object processing
    require XSLoader;
    require PAR::Heavy;
    require Carp::Heavy;
    require Exporter::Heavy;
    PAR::Heavy::_init_dynaloader();

    # now let's try getting helper modules from within
    require IO::File;

    # load rest of the group in
    while (my $filename = (sort keys %require_list)[0]) {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        unless ($INC{$filename} or $filename =~ /BSDPAN/) {
            # require modules, do other executable files
            if ($filename =~ /\.pmc?$/i) {
                require $filename;
            }
            else {
                # Skip ActiveState's sitecustomize.pl file:
                do $filename unless $filename =~ /sitecustomize\.pl$/;
            }
        }
        delete $require_list{$filename};
    }

    # }}}

    # increase the chunk size for Archive::Zip so that it will find the EOCD
    # even if more stuff has been appended to the .par
    $Archive::Zip::ChunkSize = 128*1024;

    last unless $buf eq "PK\003\004";
    $start_pos = (tell _FH) - 4;
}
# }}}

# Argument processing {{{
my @par_args;
my ($out, $bundle, $logfh, $cache_name);

delete $ENV{PAR_APP_REUSE}; # sanitize (REUSE may be a security problem)

$quiet = 0 unless $ENV{PAR_DEBUG};
# Don't swallow arguments for compiled executables without --par-options
if (!$start_pos or ($ARGV[0] eq '--par-options' && shift)) {
    my %dist_cmd = qw(
        p   blib_to_par
        i   install_par
        u   uninstall_par
        s   sign_par
        v   verify_par
    );

    # if the app is invoked as "appname --par-options --reuse PROGRAM @PROG_ARGV",
    # use the app to run the given perl code instead of anything from the
    # app itself (but still set up the normal app environment and @INC)
    if (@ARGV and $ARGV[0] eq '--reuse') {
        shift @ARGV;
        $ENV{PAR_APP_REUSE} = shift @ARGV;
    }
    else { # normal parl behaviour

        my @add_to_inc;
        while (@ARGV) {
            $ARGV[0] =~ /^-([AIMOBLbqpiusTv])(.*)/ or last;

            if ($1 eq 'I') {
                push @add_to_inc, $2;
            }
            elsif ($1 eq 'M') {
                eval "use $2";
            }
            elsif ($1 eq 'A') {
                unshift @par_args, $2;
            }
            elsif ($1 eq 'O') {
                $out = $2;
            }
            elsif ($1 eq 'b') {
                $bundle = 'site';
            }
            elsif ($1 eq 'B') {
                $bundle = 'all';
            }
            elsif ($1 eq 'q') {
                $quiet = 1;
            }
            elsif ($1 eq 'L') {
                open $logfh, ">>", $2 or die "XXX: Cannot open log: $!";
            }
            elsif ($1 eq 'T') {
                $cache_name = $2;
            }

            shift(@ARGV);

            if (my $cmd = $dist_cmd{$1}) {
                delete $ENV{'PAR_TEMP'};
                init_inc();
                require PAR::Dist;
                &{"PAR::Dist::$cmd"}() unless @ARGV;
                &{"PAR::Dist::$cmd"}($_) for @ARGV;
                exit;
            }
        }

        unshift @INC, @add_to_inc;
    }
}

# XXX -- add --par-debug support!

# }}}

# Output mode (-O) handling {{{
if ($out) {
    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require IO::File;
        require Archive::Zip;
    }

    my $par = shift(@ARGV);
    my $zip;


    if (defined $par) {
        open my $fh, '<', $par or die "Cannot find '$par': $!";
        binmode($fh);
        bless($fh, 'IO::File');

        $zip = Archive::Zip->new;
        ( $zip->readFromFileHandle($fh, $par) == Archive::Zip::AZ_OK() )
            or die "Read '$par' error: $!";
    }


    my %env = do {
        if ($zip and my $meta = $zip->contents('META.yml')) {
            $meta =~ s/.*^par:$//ms;
            $meta =~ s/^\S.*//ms;
            $meta =~ /^  ([^:]+): (.+)$/mg;
        }
    };

    # Open input and output files {{{
    local $/ = \4;

    if (defined $par) {
        open PAR, '<', $par or die "$!: $par";
        binmode(PAR);
        die "$par is not a PAR file" unless <PAR> eq "PK\003\004";
    }

    CreatePath($out) ;
    
    my $fh = IO::File->new(
        $out,
        IO::File::O_CREAT() | IO::File::O_WRONLY() | IO::File::O_TRUNC(),
        0777,
    ) or die $!;
    binmode($fh);

    $/ = (defined $data_pos) ? \$data_pos : undef;
    seek _FH, 0, 0;
    my $loader = scalar <_FH>;
    if (!$ENV{PAR_VERBATIM} and $loader =~ /^(?:#!|\@rem)/) {
        require PAR::Filter::PodStrip;
        PAR::Filter::PodStrip->new->apply(\$loader, $0)
    }
    foreach my $key (sort keys %env) {
        my $val = $env{$key} or next;
        $val = eval $val if $val =~ /^['"]/;
        my $magic = "__ENV_PAR_" . uc($key) . "__";
        my $set = "PAR_" . uc($key) . "=$val";
        $loader =~ s{$magic( +)}{
            $magic . $set . (' ' x (length($1) - length($set)))
        }eg;
    }
    $fh->print($loader);
    $/ = undef;
    # }}}

    # Write bundled modules {{{
    if ($bundle) {
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        init_inc();

        require_modules();

        my @inc = sort {
            length($b) <=> length($a)
        } grep {
            !/BSDPAN/
        } grep {
            ($bundle ne 'site') or
            ($_ ne $Config::Config{archlibexp} and
             $_ ne $Config::Config{privlibexp});
        } @INC;

        # File exists test added to fix RT #41790:
        # Funny, non-existing entry in _<....auto/Compress/Raw/Zlib/autosplit.ix.
        # This is a band-aid fix with no deeper grasp of the issue.
        # Somebody please go through the pain of understanding what's happening,
        # I failed. -- Steffen
        my %files;
        /^_<(.+)$/ and -e $1 and $files{$1}++ for keys %::;
        $files{$_}++ for values %INC;

        my $lib_ext = $Config::Config{lib_ext};
        my %written;

        foreach (sort keys %files) {
            my ($name, $file);

            foreach my $dir (@inc) {
                if ($name = $PAR::Heavy::FullCache{$_}) {
                    $file = $_;
                    last;
                }
                elsif (/^(\Q$dir\E\/(.*[^Cc]))\Z/i) {
                    ($file, $name) = ($1, $2);
                    last;
                }
                elsif (m!^/loader/[^/]+/(.*[^Cc])\Z!) {
                    if (my $ref = $PAR::Heavy::ModuleCache{$1}) {
                        ($file, $name) = ($ref, $1);
                        last;
                    }
                    elsif (-f "$dir/$1") {
                        ($file, $name) = ("$dir/$1", $1);
                        last;
                    }
                }
            }

            next unless defined $name and not $written{$name}++;
            next if !ref($file) and $file =~ /\.\Q$lib_ext\E$/;
            outs( join "",
                qq(Packing "), ref $file ? $file->{name} : $file,
                qq("...)
            );

            my $content;
            if (ref($file)) {
                $content = $file->{buf};
            }
            else {
                open FILE, '<', $file or die "Can't open $file: $!";
                binmode(FILE);
                $content = <FILE>;
                close FILE;

                PAR::Filter::PodStrip->new->apply(\$content, $file)
                    if !$ENV{PAR_VERBATIM} and $name =~ /\.(?:pm|ix|al)$/i;

                PAR::Filter::PatchContent->new->apply(\$content, $file, $name);
            }

            outs(qq(Written as "$name"));
            $fh->print("FILE");
            $fh->print(pack('N', length($name) + 9));
            $fh->print(sprintf(
                "%08x/%s", Archive::Zip::computeCRC32($content), $name
            ));
            $fh->print(pack('N', length($content)));
            $fh->print($content);
        }
    }
    # }}}

    # Now write out the PAR and magic strings {{{
    $zip->writeToFileHandle($fh) if $zip;

    $cache_name = substr $cache_name, 0, 40;
    if (!$cache_name and my $mtime = (stat($out))[9]) {
        my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
            || eval { require Digest::SHA1; Digest::SHA1->new }
            || eval { require Digest::MD5; Digest::MD5->new };

        # Workaround for bug in Digest::SHA 5.38 and 5.39
        my $sha_version = eval { $Digest::SHA::VERSION } || 0;
        if ($sha_version eq '5.38' or $sha_version eq '5.39') {
            $ctx->addfile($out, "b") if ($ctx);
        }
        else {
            if ($ctx and open(my $fh, "<$out")) {
                binmode($fh);
                $ctx->addfile($fh);
                close($fh);
            }
        }

        $cache_name = $ctx ? $ctx->hexdigest : $mtime;
    }
    $cache_name .= "\0" x (41 - length $cache_name);
    $cache_name .= "CACHE";
    $fh->print($cache_name);
    $fh->print(pack('N', $fh->tell - length($loader)));
    $fh->print("\nPAR.pm\n");
    $fh->close;
    chmod 0755, $out;
    # }}}

    exit;
}
# }}}

# Prepare $progname into PAR file cache {{{
{
    last unless defined $start_pos;

    _fix_progname();

    # Now load the PAR file and put it into PAR::LibCache {{{
    require PAR;
    PAR::Heavy::_init_dynaloader();


    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require File::Find;
        require Archive::Zip;
    }
    my $zip = Archive::Zip->new;
    my $fh = IO::File->new;
    $fh->fdopen(fileno(_FH), 'r') or die "$!: $@";
    $zip->readFromFileHandle($fh, $progname) == Archive::Zip::AZ_OK() or die "$!: $@";

    push @PAR::LibCache, $zip;
    $PAR::LibCache{$progname} = $zip;

    $quiet = !$ENV{PAR_DEBUG};
    outs(qq(\$ENV{PAR_TEMP} = "$ENV{PAR_TEMP}"));

    if (defined $ENV{PAR_TEMP}) { # should be set at this point!
        foreach my $member ( $zip->members ) {
            next if $member->isDirectory;
            my $member_name = $member->fileName;
            next unless $member_name =~ m{
                ^
                /?shlib/
                (?:$Config::Config{version}/)?
                (?:$Config::Config{archname}/)?
                ([^/]+)
                $
            }x;
            my $extract_name = $1;
            my $dest_name = File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
            if (-f $dest_name && -s _ == $member->uncompressedSize()) {
                outs(qq(Skipping "$member_name" since it already exists at "$dest_name"));
            } else {
                outs(qq(Extracting "$member_name" to "$dest_name"));
                $member->extractToFileNamed($dest_name);
                chmod(0555, $dest_name) if $^O eq "hpux";
            }
        }
    }
    # }}}
}
# }}}

# If there's no main.pl to run, show usage {{{
unless ($PAR::LibCache{$progname}) {
    die << "." unless @ARGV;
Usage: $0 [ -Alib.par ] [ -Idir ] [ -Mmodule ] [ src.par ] [ program.pl ]
       $0 [ -B|-b ] [-Ooutfile] src.par
.
    $ENV{PAR_PROGNAME} = $progname = $0 = shift(@ARGV);
}
# }}}

sub CreatePath {
    my ($name) = @_;
    
    require File::Basename;
    my ($basename, $path, $ext) = File::Basename::fileparse($name, ('\..*'));
    
    require File::Path;
    
    File::Path::mkpath($path) unless(-e $path); # mkpath dies with error
}

sub require_modules {
    #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';

    require lib;
    require DynaLoader;
    require integer;
    require strict;
    require warnings;
    require vars;
    require Carp;
    require Carp::Heavy;
    require Errno;
    require Exporter::Heavy;
    require Exporter;
    require Fcntl;
    require File::Temp;
    require File::Spec;
    require XSLoader;
    require Config;
    require IO::Handle;
    require IO::File;
    require Compress::Zlib;
    require Archive::Zip;
    require PAR;
    require PAR::Heavy;
    require PAR::Dist;
    require PAR::Filter::PodStrip;
    require PAR::Filter::PatchContent;
    require attributes;
    eval { require Cwd };
    eval { require Win32 };
    eval { require Scalar::Util };
    eval { require Archive::Unzip::Burst };
    eval { require Tie::Hash::NamedCapture };
    eval { require PerlIO; require PerlIO::scalar };
}

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::SetupTemp as set_par_temp_env!
sub _set_par_temp {
    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $par_temp = $1;
        return;
    }

    foreach my $path (
        (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
        qw( C:\\TEMP /tmp . )
    ) {
        next unless defined $path and -d $path and -w $path;
        my $username;
        my $pwuid;
        # does not work everywhere:
        eval {($pwuid) = getpwuid($>) if defined $>;};

        if ( defined(&Win32::LoginName) ) {
            $username = &Win32::LoginName;
        }
        elsif (defined $pwuid) {
            $username = $pwuid;
        }
        else {
            $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
        }
        $username =~ s/\W/_/g;

        my $stmpdir = "$path$Config{_delim}par-".unpack("H*", $username);
        mkdir $stmpdir, 0755;
        if (!$ENV{PAR_CLEAN} and my $mtime = (stat($progname))[9]) {
            open (my $fh, "<". $progname);
            seek $fh, -18, 2;
            sysread $fh, my $buf, 6;
            if ($buf eq "\0CACHE") {
                seek $fh, -58, 2;
                sysread $fh, $buf, 41;
                $buf =~ s/\0//g;
                $stmpdir .= "$Config{_delim}cache-" . $buf;
            }
            else {
                my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
                    || eval { require Digest::SHA1; Digest::SHA1->new }
                    || eval { require Digest::MD5; Digest::MD5->new };

                # Workaround for bug in Digest::SHA 5.38 and 5.39
                my $sha_version = eval { $Digest::SHA::VERSION } || 0;
                if ($sha_version eq '5.38' or $sha_version eq '5.39') {
                    $ctx->addfile($progname, "b") if ($ctx);
                }
                else {
                    if ($ctx and open(my $fh, "<$progname")) {
                        binmode($fh);
                        $ctx->addfile($fh);
                        close($fh);
                    }
                }

                $stmpdir .= "$Config{_delim}cache-" . ( $ctx ? $ctx->hexdigest : $mtime );
            }
            close($fh);
        }
        else {
            $ENV{PAR_CLEAN} = 1;
            $stmpdir .= "$Config{_delim}temp-$$";
        }

        $ENV{PAR_TEMP} = $stmpdir;
        mkdir $stmpdir, 0755;
        last;
    }

    $par_temp = $1 if $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

sub _tempfile {
    my ($ext, $crc) = @_;
    my ($fh, $filename);

    $filename = "$par_temp/$crc$ext";

    if ($ENV{PAR_CLEAN}) {
        unlink $filename if -e $filename;
        push @tmpfile, $filename;
    }
    else {
        return (undef, $filename) if (-r $filename);
    }

    open $fh, '>', $filename or die $!;
    binmode($fh);
    return($fh, $filename);
}

# same code lives in PAR::SetupProgname::set_progname
sub _set_progname {
    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $progname = $1;
    }

    $progname ||= $0;

    if ($ENV{PAR_TEMP} and index($progname, $ENV{PAR_TEMP}) >= 0) {
        $progname = substr($progname, rindex($progname, $Config{_delim}) + 1);
    }

    if (!$ENV{PAR_PROGNAME} or index($progname, $Config{_delim}) >= 0) {
        if (open my $fh, '<', $progname) {
            return if -s $fh;
        }
        if (-s "$progname$Config{_exe}") {
            $progname .= $Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        $dir =~ s/\Q$Config{_delim}\E$//;
        (($progname = "$dir$Config{_delim}$progname$Config{_exe}"), last)
            if -s "$dir$Config{_delim}$progname$Config{_exe}";
        (($progname = "$dir$Config{_delim}$progname"), last)
            if -s "$dir$Config{_delim}$progname";
    }
}

sub _fix_progname {
    $0 = $progname ||= $ENV{PAR_PROGNAME};
    if (index($progname, $Config{_delim}) < 0) {
        $progname = ".$Config{_delim}$progname";
    }

    # XXX - hack to make PWD work
    my $pwd = (defined &Cwd::getcwd) ? Cwd::getcwd()
                : ((defined &Win32::GetCwd) ? Win32::GetCwd() : `pwd`);
    chomp($pwd);
    $progname =~ s/^(?=\.\.?\Q$Config{_delim}\E)/$pwd$Config{_delim}/;

    $ENV{PAR_PROGNAME} = $progname;
}

sub _par_init_env {
    if ( $ENV{PAR_INITIALIZED}++ == 1 ) {
        return;
    } else {
        $ENV{PAR_INITIALIZED} = 2;
    }

    for (qw( SPAWNED TEMP CLEAN DEBUG CACHE PROGNAME ARGC ARGV_0 ) ) {
        delete $ENV{'PAR_'.$_};
    }
    for (qw/ TMPDIR TEMP CLEAN DEBUG /) {
        $ENV{'PAR_'.$_} = $ENV{'PAR_GLOBAL_'.$_} if exists $ENV{'PAR_GLOBAL_'.$_};
    }

    my $par_clean = "__ENV_PAR_CLEAN__               ";

    if ($ENV{PAR_TEMP}) {
        delete $ENV{PAR_CLEAN};
    }
    elsif (!exists $ENV{PAR_GLOBAL_CLEAN}) {
        my $value = substr($par_clean, 12 + length("CLEAN"));
        $ENV{PAR_CLEAN} = $1 if $value =~ /^PAR_CLEAN=(\S+)/;
    }
}

sub outs {
    return if $quiet;
    if ($logfh) {
        print $logfh "@_\n";
    }
    else {
        print "@_\n";
    }
}

sub init_inc {
    require Config;
    push @INC, grep defined, map $Config::Config{$_}, qw(
        archlibexp privlibexp sitearchexp sitelibexp
        vendorarchexp vendorlibexp
    );
}

########################################################################
# The main package for script execution

package main;

require PAR;
unshift @INC, \&PAR::find_par;
PAR->import(@par_args);

die qq(par.pl: Can't open perl script "$progname": No such file or directory\n)
    unless -e $progname;

do $progname;
CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
die $@ if $@;

};

$::__ERROR = $@ if $@;
}

CORE::exit($1) if ($::__ERROR =~/^_TK_EXIT_\((\d+)\)/);
die $::__ERROR if $::__ERROR;

1;

#line 1030

__END__
FILE   cf69f5c6/Archive/Zip.pm  G�#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip.pm"
package Archive::Zip;

use 5.006;
use strict;
use Carp                ();
use Cwd                 ();
use IO::File            ();
use IO::Seekable        ();
use Compress::Raw::Zlib ();
use File::Spec          ();
use File::Temp          ();
use FileHandle          ();

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';

    require Exporter;
    @ISA = qw( Exporter );
}

use vars qw( $ChunkSize $ErrorHandler );

BEGIN {
    # This is the size we'll try to read, write, and (de)compress.
    # You could set it to something different if you had lots of memory
    # and needed more speed.
    $ChunkSize ||= 32768;

    $ErrorHandler = \&Carp::carp;
}

# BEGIN block is necessary here so that other modules can use the constants.
use vars qw( @EXPORT_OK %EXPORT_TAGS );

BEGIN {
    @EXPORT_OK   = ('computeCRC32');
    %EXPORT_TAGS = (
        CONSTANTS => [
            qw(
              FA_MSDOS
              FA_UNIX
              GPBF_ENCRYPTED_MASK
              GPBF_DEFLATING_COMPRESSION_MASK
              GPBF_HAS_DATA_DESCRIPTOR_MASK
              COMPRESSION_STORED
              COMPRESSION_DEFLATED
              COMPRESSION_LEVEL_NONE
              COMPRESSION_LEVEL_DEFAULT
              COMPRESSION_LEVEL_FASTEST
              COMPRESSION_LEVEL_BEST_COMPRESSION
              IFA_TEXT_FILE_MASK
              IFA_TEXT_FILE
              IFA_BINARY_FILE
              )
        ],

        MISC_CONSTANTS => [
            qw(
              FA_AMIGA
              FA_VAX_VMS
              FA_VM_CMS
              FA_ATARI_ST
              FA_OS2_HPFS
              FA_MACINTOSH
              FA_Z_SYSTEM
              FA_CPM
              FA_TOPS20
              FA_WINDOWS_NTFS
              FA_QDOS
              FA_ACORN
              FA_VFAT
              FA_MVS
              FA_BEOS
              FA_TANDEM
              FA_THEOS
              GPBF_IMPLODING_8K_SLIDING_DICTIONARY_MASK
              GPBF_IMPLODING_3_SHANNON_FANO_TREES_MASK
              GPBF_IS_COMPRESSED_PATCHED_DATA_MASK
              COMPRESSION_SHRUNK
              DEFLATING_COMPRESSION_NORMAL
              DEFLATING_COMPRESSION_MAXIMUM
              DEFLATING_COMPRESSION_FAST
              DEFLATING_COMPRESSION_SUPER_FAST
              COMPRESSION_REDUCED_1
              COMPRESSION_REDUCED_2
              COMPRESSION_REDUCED_3
              COMPRESSION_REDUCED_4
              COMPRESSION_IMPLODED
              COMPRESSION_TOKENIZED
              COMPRESSION_DEFLATED_ENHANCED
              COMPRESSION_PKWARE_DATA_COMPRESSION_LIBRARY_IMPLODED
              )
        ],

        ERROR_CODES => [
            qw(
              AZ_OK
              AZ_STREAM_END
              AZ_ERROR
              AZ_FORMAT_ERROR
              AZ_IO_ERROR
              )
        ],

        # For Internal Use Only
        PKZIP_CONSTANTS => [
            qw(
              SIGNATURE_FORMAT
              SIGNATURE_LENGTH

              LOCAL_FILE_HEADER_SIGNATURE
              LOCAL_FILE_HEADER_FORMAT
              LOCAL_FILE_HEADER_LENGTH

              DATA_DESCRIPTOR_SIGNATURE
              DATA_DESCRIPTOR_FORMAT
              DATA_DESCRIPTOR_LENGTH

              DATA_DESCRIPTOR_FORMAT_NO_SIG
              DATA_DESCRIPTOR_LENGTH_NO_SIG

              CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE
              CENTRAL_DIRECTORY_FILE_HEADER_FORMAT
              CENTRAL_DIRECTORY_FILE_HEADER_LENGTH

              ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_SIGNATURE
              ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_FORMAT
              ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_LENGTH

              ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE
              ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_FORMAT
              ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_LENGTH

              END_OF_CENTRAL_DIRECTORY_SIGNATURE
              END_OF_CENTRAL_DIRECTORY_FORMAT
              END_OF_CENTRAL_DIRECTORY_LENGTH

              END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING
              )
        ],

        # For Internal Use Only
        UTILITY_METHODS => [
            qw(
              _error
              _printError
              _ioError
              _formatError
              _subclassResponsibility
              _binmode
              _isSeekable
              _newFileHandle
              _readSignature
              _asZipDirName
              )
        ],
    );

    # Add all the constant names and error code names to @EXPORT_OK
    Exporter::export_ok_tags(
        qw(
          CONSTANTS
          ERROR_CODES
          PKZIP_CONSTANTS
          UTILITY_METHODS
          MISC_CONSTANTS
          ));

}

# Error codes
use constant AZ_OK           => 0;
use constant AZ_STREAM_END   => 1;
use constant AZ_ERROR        => 2;
use constant AZ_FORMAT_ERROR => 3;
use constant AZ_IO_ERROR     => 4;

# File types
# Values of Archive::Zip::Member->fileAttributeFormat()

use constant FA_MSDOS        => 0;
use constant FA_AMIGA        => 1;
use constant FA_VAX_VMS      => 2;
use constant FA_UNIX         => 3;
use constant FA_VM_CMS       => 4;
use constant FA_ATARI_ST     => 5;
use constant FA_OS2_HPFS     => 6;
use constant FA_MACINTOSH    => 7;
use constant FA_Z_SYSTEM     => 8;
use constant FA_CPM          => 9;
use constant FA_TOPS20       => 10;
use constant FA_WINDOWS_NTFS => 11;
use constant FA_QDOS         => 12;
use constant FA_ACORN        => 13;
use constant FA_VFAT         => 14;
use constant FA_MVS          => 15;
use constant FA_BEOS         => 16;
use constant FA_TANDEM       => 17;
use constant FA_THEOS        => 18;

# general-purpose bit flag masks
# Found in Archive::Zip::Member->bitFlag()

use constant GPBF_ENCRYPTED_MASK             => 1 << 0;
use constant GPBF_DEFLATING_COMPRESSION_MASK => 3 << 1;
use constant GPBF_HAS_DATA_DESCRIPTOR_MASK   => 1 << 3;

# deflating compression types, if compressionMethod == COMPRESSION_DEFLATED
# ( Archive::Zip::Member->bitFlag() & GPBF_DEFLATING_COMPRESSION_MASK )

use constant DEFLATING_COMPRESSION_NORMAL     => 0 << 1;
use constant DEFLATING_COMPRESSION_MAXIMUM    => 1 << 1;
use constant DEFLATING_COMPRESSION_FAST       => 2 << 1;
use constant DEFLATING_COMPRESSION_SUPER_FAST => 3 << 1;

# compression method

# these two are the only ones supported in this module
use constant COMPRESSION_STORED        => 0;   # file is stored (no compression)
use constant COMPRESSION_DEFLATED      => 8;   # file is Deflated
use constant COMPRESSION_LEVEL_NONE    => 0;
use constant COMPRESSION_LEVEL_DEFAULT => -1;
use constant COMPRESSION_LEVEL_FASTEST => 1;
use constant COMPRESSION_LEVEL_BEST_COMPRESSION => 9;

# internal file attribute bits
# Found in Archive::Zip::Member::internalFileAttributes()

use constant IFA_TEXT_FILE_MASK => 1;
use constant IFA_TEXT_FILE      => 1;
use constant IFA_BINARY_FILE    => 0;

# PKZIP file format miscellaneous constants (for internal use only)
use constant SIGNATURE_FORMAT => "V";
use constant SIGNATURE_LENGTH => 4;

# these lengths are without the signature.
use constant LOCAL_FILE_HEADER_SIGNATURE => 0x04034b50;
use constant LOCAL_FILE_HEADER_FORMAT    => "v3 V4 v2";
use constant LOCAL_FILE_HEADER_LENGTH    => 26;

# PKZIP docs don't mention the signature, but Info-Zip writes it.
use constant DATA_DESCRIPTOR_SIGNATURE => 0x08074b50;
use constant DATA_DESCRIPTOR_FORMAT    => "V3";
use constant DATA_DESCRIPTOR_LENGTH    => 12;

# but the signature is apparently optional.
use constant DATA_DESCRIPTOR_FORMAT_NO_SIG => "V2";
use constant DATA_DESCRIPTOR_LENGTH_NO_SIG => 8;

use constant CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE => 0x02014b50;
use constant CENTRAL_DIRECTORY_FILE_HEADER_FORMAT    => "C2 v3 V4 v5 V2";
use constant CENTRAL_DIRECTORY_FILE_HEADER_LENGTH    => 42;

# zip64 support
use constant ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_SIGNATURE => 0x06064b50;
use constant ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_FORMAT => 0;
use constant ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_LENGTH => 0;

use constant ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE => 0x07064b50;
use constant ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_FORMAT => 0;
use constant ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_LENGTH => 0;


use constant END_OF_CENTRAL_DIRECTORY_SIGNATURE => 0x06054b50;
use constant END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING =>
  pack("V", END_OF_CENTRAL_DIRECTORY_SIGNATURE);
use constant END_OF_CENTRAL_DIRECTORY_FORMAT => "v4 V2 v";
use constant END_OF_CENTRAL_DIRECTORY_LENGTH => 18;

use constant GPBF_IMPLODING_8K_SLIDING_DICTIONARY_MASK => 1 << 1;
use constant GPBF_IMPLODING_3_SHANNON_FANO_TREES_MASK  => 1 << 2;
use constant GPBF_IS_COMPRESSED_PATCHED_DATA_MASK      => 1 << 5;

# the rest of these are not supported in this module
use constant COMPRESSION_SHRUNK    => 1;    # file is Shrunk
use constant COMPRESSION_REDUCED_1 => 2;    # file is Reduced CF=1
use constant COMPRESSION_REDUCED_2 => 3;    # file is Reduced CF=2
use constant COMPRESSION_REDUCED_3 => 4;    # file is Reduced CF=3
use constant COMPRESSION_REDUCED_4 => 5;    # file is Reduced CF=4
use constant COMPRESSION_IMPLODED  => 6;    # file is Imploded
use constant COMPRESSION_TOKENIZED => 7;    # reserved for Tokenizing compr.
use constant COMPRESSION_DEFLATED_ENHANCED => 9;   # reserved for enh. Deflating
use constant COMPRESSION_PKWARE_DATA_COMPRESSION_LIBRARY_IMPLODED => 10;

# Load the various required classes
require Archive::Zip::Archive;
require Archive::Zip::Member;
require Archive::Zip::FileMember;
require Archive::Zip::DirectoryMember;
require Archive::Zip::ZipFileMember;
require Archive::Zip::NewFileMember;
require Archive::Zip::StringMember;

# Convenience functions

sub _ISA ($$) {

    # Can't rely on Scalar::Util, so use the next best way
    local $@;
    !!eval { ref $_[0] and $_[0]->isa($_[1]) };
}

sub _CAN ($$) {
    local $@;
    !!eval { ref $_[0] and $_[0]->can($_[1]) };
}

#####################################################################
# Methods

sub new {
    my $class = shift;
    return Archive::Zip::Archive->new(@_);
}

sub computeCRC32 {
    my ($data, $crc);

    if (ref($_[0]) eq 'HASH') {
        $data = $_[0]->{string};
        $crc  = $_[0]->{checksum};
    } else {
        $data = shift;
        $data = shift if ref($data);
        $crc  = shift;
    }

    return Compress::Raw::Zlib::crc32($data, $crc);
}

# Report or change chunk size used for reading and writing.
# Also sets Zlib's default buffer size (eventually).
sub setChunkSize {
    shift if ref($_[0]) eq 'Archive::Zip::Archive';
    my $chunkSize = (ref($_[0]) eq 'HASH') ? shift->{chunkSize} : shift;
    my $oldChunkSize = $Archive::Zip::ChunkSize;
    $Archive::Zip::ChunkSize = $chunkSize if ($chunkSize);
    return $oldChunkSize;
}

sub chunkSize {
    return $Archive::Zip::ChunkSize;
}

sub setErrorHandler {
    my $errorHandler = (ref($_[0]) eq 'HASH') ? shift->{subroutine} : shift;
    $errorHandler = \&Carp::carp unless defined($errorHandler);
    my $oldErrorHandler = $Archive::Zip::ErrorHandler;
    $Archive::Zip::ErrorHandler = $errorHandler;
    return $oldErrorHandler;
}

######################################################################
# Private utility functions (not methods).

sub _printError {
    my $string = join(' ', @_, "\n");
    my $oldCarpLevel = $Carp::CarpLevel;
    $Carp::CarpLevel += 2;
    &{$ErrorHandler}($string);
    $Carp::CarpLevel = $oldCarpLevel;
}

# This is called on format errors.
sub _formatError {
    shift if ref($_[0]);
    _printError('format error:', @_);
    return AZ_FORMAT_ERROR;
}

# This is called on IO errors.
sub _ioError {
    shift if ref($_[0]);
    _printError('IO error:', @_, ':', $!);
    return AZ_IO_ERROR;
}

# This is called on generic errors.
sub _error {
    shift if ref($_[0]);
    _printError('error:', @_);
    return AZ_ERROR;
}

# Called when a subclass should have implemented
# something but didn't
sub _subclassResponsibility {
    Carp::croak("subclass Responsibility\n");
}

# Try to set the given file handle or object into binary mode.
sub _binmode {
    my $fh = shift;
    return _CAN($fh, 'binmode') ? $fh->binmode() : binmode($fh);
}

# Attempt to guess whether file handle is seekable.
# Because of problems with Windows, this only returns true when
# the file handle is a real file.
sub _isSeekable {
    my $fh = shift;
    return 0 unless ref $fh;
    _ISA($fh, "IO::Scalar")    # IO::Scalar objects are brokenly-seekable
      and return 0;
    _ISA($fh, "IO::String")
      and return 1;
    if (_ISA($fh, "IO::Seekable")) {

        # Unfortunately, some things like FileHandle objects
        # return true for Seekable, but AREN'T!!!!!
        _ISA($fh, "FileHandle")
          and return 0;
        return 1;
    }

    # open my $fh, "+<", \$data;
    ref $fh eq "GLOB" && eval { seek $fh, 0, 1 } and return 1;
    _CAN($fh, "stat")
      and return -f $fh;
    return (_CAN($fh, "seek") and _CAN($fh, "tell")) ? 1 : 0;
}

# Print to the filehandle, while making sure the pesky Perl special global
# variables don't interfere.
sub _print {
    my ($self, $fh, @data) = @_;

    local $\;

    return $fh->print(@data);
}

# Return an opened IO::Handle
# my ( $status, fh ) = _newFileHandle( 'fileName', 'w' );
# Can take a filename, file handle, or ref to GLOB
# Or, if given something that is a ref but not an IO::Handle,
# passes back the same thing.
sub _newFileHandle {
    my $fd     = shift;
    my $status = 1;
    my $handle;

    if (ref($fd)) {
        if (_ISA($fd, 'IO::Scalar') or _ISA($fd, 'IO::String')) {
            $handle = $fd;
        } elsif (_ISA($fd, 'IO::Handle') or ref($fd) eq 'GLOB') {
            $handle = IO::File->new;
            $status = $handle->fdopen($fd, @_);
        } else {
            $handle = $fd;
        }
    } else {
        $handle = IO::File->new;
        $status = $handle->open($fd, @_);
    }

    return ($status, $handle);
}

# Returns next signature from given file handle, leaves
# file handle positioned afterwards.
# In list context, returns ($status, $signature)
# ( $status, $signature) = _readSignature( $fh, $fileName );

sub _readSignature {
    my $fh                = shift;
    my $fileName          = shift;
    my $expectedSignature = shift;    # optional

    my $signatureData;
    my $bytesRead = $fh->read($signatureData, SIGNATURE_LENGTH);
    if ($bytesRead != SIGNATURE_LENGTH) {
        return _ioError("reading header signature");
    }
    my $signature = unpack(SIGNATURE_FORMAT, $signatureData);
    my $status = AZ_OK;

    # compare with expected signature, if any, or any known signature.
    if (
        (defined($expectedSignature) && $signature != $expectedSignature)
        || (   !defined($expectedSignature)
            && $signature != CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE
            && $signature != LOCAL_FILE_HEADER_SIGNATURE
            && $signature != END_OF_CENTRAL_DIRECTORY_SIGNATURE
            && $signature != DATA_DESCRIPTOR_SIGNATURE
            && $signature != ZIP64_END_OF_CENTRAL_DIRECTORY_RECORD_SIGNATURE
            && $signature != ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE
        )
      ) {
        my $errmsg = sprintf("bad signature: 0x%08x", $signature);
        if (_isSeekable($fh)) {
            $errmsg .= sprintf(" at offset %d", $fh->tell() - SIGNATURE_LENGTH);
        }

        $status = _formatError("$errmsg in file $fileName");
    }

    return ($status, $signature);
}

# Utility method to make and open a temp file.
# Will create $temp_dir if it does not exist.
# Returns file handle and name:
#
# my ($fh, $name) = Archive::Zip::tempFile();
# my ($fh, $name) = Archive::Zip::tempFile('mytempdir');
#

sub tempFile {
    my $dir = (ref($_[0]) eq 'HASH') ? shift->{tempDir} : shift;
    my ($fh, $filename) = File::Temp::tempfile(
        SUFFIX => '.zip',
        UNLINK => 1,
        $dir ? (DIR => $dir) : ());
    return (undef, undef) unless $fh;
    my ($status, $newfh) = _newFileHandle($fh, 'w+');
    return ($newfh, $filename);
}

# Return the normalized directory name as used in a zip file (path
# separators become slashes, etc.).
# Will translate internal slashes in path components (i.e. on Macs) to
# underscores.  Discards volume names.
# When $forceDir is set, returns paths with trailing slashes (or arrays
# with trailing blank members).
#
# If third argument is a reference, returns volume information there.
#
# input         output
# .             ('.')   '.'
# ./a           ('a')   a
# ./a/b         ('a','b')   a/b
# ./a/b/        ('a','b')   a/b
# a/b/          ('a','b')   a/b
# /a/b/         ('','a','b')    a/b
# c:\a\b\c.doc  ('','a','b','c.doc')    a/b/c.doc      # on Windows
# "i/o maps:whatever"   ('i_o maps', 'whatever')  "i_o maps/whatever"   # on Macs
sub _asZipDirName {
    my $name      = shift;
    my $forceDir  = shift;
    my $volReturn = shift;
    my ($volume, $directories, $file) =
      File::Spec->splitpath(File::Spec->canonpath($name), $forceDir);
    $$volReturn = $volume if (ref($volReturn));
    my @dirs = map { $_ =~ s{/}{_}g; $_ } File::Spec->splitdir($directories);
    if (@dirs > 0) { pop(@dirs) unless $dirs[-1] }    # remove empty component
    push(@dirs, defined($file) ? $file : '');

    #return wantarray ? @dirs : join ( '/', @dirs );

    my $normalised_path = join '/', @dirs;

    # Leading directory separators should not be stored in zip archives.
    # Example:
    #   C:\a\b\c\      a/b/c
    #   C:\a\b\c.txt   a/b/c.txt
    #   /a/b/c/        a/b/c
    #   /a/b/c.txt     a/b/c.txt
    $normalised_path =~ s{^/}{};    # remove leading separator

    return $normalised_path;
}

# Return an absolute local name for a zip name.
# Assume a directory if zip name has trailing slash.
# Takes an optional volume name in FS format (like 'a:').
#
sub _asLocalName {
    my $name   = shift;    # zip format
    my $volume = shift;
    $volume = '' unless defined($volume);    # local FS format

    my @paths = split(/\//, $name);
    my $filename = pop(@paths);
    $filename = '' unless defined($filename);
    my $localDirs = @paths ? File::Spec->catdir(@paths) : '';
    my $localName = File::Spec->catpath($volume, $localDirs, $filename);
    unless ($volume) {
        $localName = File::Spec->rel2abs($localName, Cwd::getcwd());
    }
    return $localName;
}

1;

__END__

#line 2164
FILE   0c349df2/Archive/Zip/Archive.pm  x�#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/Archive.pm"
package Archive::Zip::Archive;

# Represents a generic ZIP archive

use strict;
use File::Path;
use File::Find ();
use File::Spec ();
use File::Copy ();
use File::Basename;
use Cwd;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw( Archive::Zip );

    if ($^O eq 'MSWin32') {
        require Win32;
        require Encode;
        Encode->import(qw{ encode_utf8 decode_utf8 });
    }
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

our $UNICODE;

# Note that this returns undef on read errors, else new zip object.

sub new {
    my $class = shift;
    my $self  = bless(
        {
            'diskNumber'                            => 0,
            'diskNumberWithStartOfCentralDirectory' => 0,
            'numberOfCentralDirectoriesOnThisDisk' =>
              0,    # should be # of members
            'numberOfCentralDirectories' => 0,    # should be # of members
            'centralDirectorySize'       => 0,    # must re-compute on write
            'centralDirectoryOffsetWRTStartingDiskNumber' =>
              0,                                  # must re-compute
            'writeEOCDOffset'             => 0,
            'writeCentralDirectoryOffset' => 0,
            'zipfileComment'              => '',
            'eocdOffset'                  => 0,
            'fileName'                    => ''
        },
        $class
    );
    $self->{'members'} = [];
    my $fileName = (ref($_[0]) eq 'HASH') ? shift->{filename} : shift;
    if ($fileName) {
        my $status = $self->read($fileName);
        return $status == AZ_OK ? $self : undef;
    }
    return $self;
}

sub storeSymbolicLink {
    my $self = shift;
    $self->{'storeSymbolicLink'} = shift;
}

sub members {
    @{shift->{'members'}};
}

sub numberOfMembers {
    scalar(shift->members());
}

sub memberNames {
    my $self = shift;
    return map { $_->fileName() } $self->members();
}

# return ref to member with given name or undef
sub memberNamed {
    my $self = shift;
    my $fileName = (ref($_[0]) eq 'HASH') ? shift->{zipName} : shift;
    foreach my $member ($self->members()) {
        return $member if $member->fileName() eq $fileName;
    }
    return undef;
}

sub membersMatching {
    my $self = shift;
    my $pattern = (ref($_[0]) eq 'HASH') ? shift->{regex} : shift;
    return grep { $_->fileName() =~ /$pattern/ } $self->members();
}

sub diskNumber {
    shift->{'diskNumber'};
}

sub diskNumberWithStartOfCentralDirectory {
    shift->{'diskNumberWithStartOfCentralDirectory'};
}

sub numberOfCentralDirectoriesOnThisDisk {
    shift->{'numberOfCentralDirectoriesOnThisDisk'};
}

sub numberOfCentralDirectories {
    shift->{'numberOfCentralDirectories'};
}

sub centralDirectorySize {
    shift->{'centralDirectorySize'};
}

sub centralDirectoryOffsetWRTStartingDiskNumber {
    shift->{'centralDirectoryOffsetWRTStartingDiskNumber'};
}

sub zipfileComment {
    my $self    = shift;
    my $comment = $self->{'zipfileComment'};
    if (@_) {
        my $new_comment = (ref($_[0]) eq 'HASH') ? shift->{comment} : shift;
        $self->{'zipfileComment'} = pack('C0a*', $new_comment);  # avoid Unicode
    }
    return $comment;
}

sub eocdOffset {
    shift->{'eocdOffset'};
}

# Return the name of the file last read.
sub fileName {
    shift->{'fileName'};
}

sub removeMember {
    my $self = shift;
    my $member = (ref($_[0]) eq 'HASH') ? shift->{memberOrZipName} : shift;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    my @newMembers = grep { $_ != $member } $self->members();
    $self->{'members'} = \@newMembers;
    return $member;
}

sub replaceMember {
    my $self = shift;

    my ($oldMember, $newMember);
    if (ref($_[0]) eq 'HASH') {
        $oldMember = $_[0]->{memberOrZipName};
        $newMember = $_[0]->{newMember};
    } else {
        ($oldMember, $newMember) = @_;
    }

    $oldMember = $self->memberNamed($oldMember) unless ref($oldMember);
    return undef unless $oldMember;
    return undef unless $newMember;
    my @newMembers =
      map { ($_ == $oldMember) ? $newMember : $_ } $self->members();
    $self->{'members'} = \@newMembers;
    return $oldMember;
}

sub extractMember {
    my $self = shift;

    my ($member, $name);
    if (ref($_[0]) eq 'HASH') {
        $member = $_[0]->{memberOrZipName};
        $name   = $_[0]->{name};
    } else {
        ($member, $name) = @_;
    }

    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    my ($volumeName, $dirName, $fileName);
    if (defined($name)) {
        ($volumeName, $dirName, $fileName) = File::Spec->splitpath($name);
        $dirName = File::Spec->catpath($volumeName, $dirName, '');
    } else {
        $name = $member->fileName();
        ($dirName = $name) =~ s{[^/]*$}{};
        $dirName = Archive::Zip::_asLocalName($dirName);
        $name    = Archive::Zip::_asLocalName($name);
    }
    if ($dirName && !-d $dirName) {
        mkpath($dirName);
        return _ioError("can't create dir $dirName") if (!-d $dirName);
    }
    my $rc = $member->extractToFileNamed($name, @_);

    # TODO refactor this fix into extractToFileNamed()
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub extractMemberWithoutPaths {
    my $self = shift;

    my ($member, $name);
    if (ref($_[0]) eq 'HASH') {
        $member = $_[0]->{memberOrZipName};
        $name   = $_[0]->{name};
    } else {
        ($member, $name) = @_;
    }

    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    return AZ_OK if $member->isDirectory();
    unless ($name) {
        $name = $member->fileName();
        $name =~ s{.*/}{};    # strip off directories, if any
        $name = Archive::Zip::_asLocalName($name);
    }
    my $rc = $member->extractToFileNamed($name, @_);
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub addMember {
    my $self = shift;
    my $newMember = (ref($_[0]) eq 'HASH') ? shift->{member} : shift;
    push(@{$self->{'members'}}, $newMember) if $newMember;
    return $newMember;
}

sub addFile {
    my $self = shift;

    my ($fileName, $newName, $compressionLevel);
    if (ref($_[0]) eq 'HASH') {
        $fileName         = $_[0]->{filename};
        $newName          = $_[0]->{zipName};
        $compressionLevel = $_[0]->{compressionLevel};
    } else {
        ($fileName, $newName, $compressionLevel) = @_;
    }

    if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
        $fileName = Win32::GetANSIPathName($fileName);
    }

    my $newMember = Archive::Zip::Member->newFromFile($fileName, $newName);
    $newMember->desiredCompressionLevel($compressionLevel);
    if ($self->{'storeSymbolicLink'} && -l $fileName) {
        my $newMember =
          Archive::Zip::Member->newFromString(readlink $fileName, $newName);

  # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
        $newMember->{'fileName'} =
          encode_utf8(Win32::GetLongPathName($fileName));
    }
    return $newMember;
}

sub addString {
    my $self = shift;

    my ($stringOrStringRef, $name, $compressionLevel);
    if (ref($_[0]) eq 'HASH') {
        $stringOrStringRef = $_[0]->{string};
        $name              = $_[0]->{zipName};
        $compressionLevel  = $_[0]->{compressionLevel};
    } else {
        ($stringOrStringRef, $name, $compressionLevel) = @_;
    }

    my $newMember =
      Archive::Zip::Member->newFromString($stringOrStringRef, $name);
    $newMember->desiredCompressionLevel($compressionLevel);
    return $self->addMember($newMember);
}

sub addDirectory {
    my $self = shift;

    my ($name, $newName);
    if (ref($_[0]) eq 'HASH') {
        $name    = $_[0]->{directoryName};
        $newName = $_[0]->{zipName};
    } else {
        ($name, $newName) = @_;
    }

    if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
        $name = Win32::GetANSIPathName($name);
    }

    my $newMember = Archive::Zip::Member->newDirectoryNamed($name, $newName);
    if ($self->{'storeSymbolicLink'} && -l $name) {
        my $link = readlink $name;
        ($newName =~ s{/$}{}) if $newName;    # Strip trailing /
        my $newMember = Archive::Zip::Member->newFromString($link, $newName);

  # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
        $newMember->{'fileName'} = encode_utf8(Win32::GetLongPathName($name));
    }
    return $newMember;
}

# add either a file or a directory.

sub addFileOrDirectory {
    my $self = shift;

    my ($name, $newName, $compressionLevel);
    if (ref($_[0]) eq 'HASH') {
        $name             = $_[0]->{name};
        $newName          = $_[0]->{zipName};
        $compressionLevel = $_[0]->{compressionLevel};
    } else {
        ($name, $newName, $compressionLevel) = @_;
    }

    if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
        $name = Win32::GetANSIPathName($name);
    }

    $name =~ s{/$}{};
    if ($newName) {
        $newName =~ s{/$}{};
    } else {
        $newName = $name;
    }
    if (-f $name) {
        return $self->addFile($name, $newName, $compressionLevel);
    } elsif (-d $name) {
        return $self->addDirectory($name, $newName);
    } else {
        return _error("$name is neither a file nor a directory");
    }
}

sub contents {
    my $self = shift;

    my ($member, $newContents);
    if (ref($_[0]) eq 'HASH') {
        $member      = $_[0]->{memberOrZipName};
        $newContents = $_[0]->{contents};
    } else {
        ($member, $newContents) = @_;
    }

    return _error('No member name given') unless $member;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    return $member->contents($newContents);
}

sub writeToFileNamed {
    my $self = shift;
    my $fileName =
      (ref($_[0]) eq 'HASH') ? shift->{filename} : shift;    # local FS format
    foreach my $member ($self->members()) {
        if ($member->_usesFileNamed($fileName)) {
            return _error("$fileName is needed by member "
                  . $member->fileName()
                  . "; consider using overwrite() or overwriteAs() instead.");
        }
    }
    my ($status, $fh) = _newFileHandle($fileName, 'w');
    return _ioError("Can't open $fileName for write") unless $status;
    my $retval = $self->writeToFileHandle($fh, 1);
    $fh->close();
    $fh = undef;

    return $retval;
}

# It is possible to write data to the FH before calling this,
# perhaps to make a self-extracting archive.
sub writeToFileHandle {
    my $self = shift;

    my ($fh, $fhIsSeekable);
    if (ref($_[0]) eq 'HASH') {
        $fh = $_[0]->{fileHandle};
        $fhIsSeekable =
          exists($_[0]->{seek}) ? $_[0]->{seek} : _isSeekable($fh);
    } else {
        $fh = shift;
        $fhIsSeekable = @_ ? shift : _isSeekable($fh);
    }

    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();
    _binmode($fh);

    # Find out where the current position is.
    my $offset = $fhIsSeekable ? $fh->tell() : 0;
    $offset = 0 if $offset < 0;

    foreach my $member ($self->members()) {
        my $retval = $member->_writeToFileHandle($fh, $fhIsSeekable, $offset);
        $member->endRead();
        return $retval if $retval != AZ_OK;
        $offset += $member->_localHeaderSize() + $member->_writeOffset();
        $offset +=
          $member->hasDataDescriptor()
          ? DATA_DESCRIPTOR_LENGTH + SIGNATURE_LENGTH
          : 0;

        # changed this so it reflects the last successful position
        $self->{'writeCentralDirectoryOffset'} = $offset;
    }
    return $self->writeCentralDirectory($fh);
}

# Write zip back to the original file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwrite {
    my $self = shift;
    return $self->overwriteAs($self->{'fileName'});
}

# Write zip to the specified file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwriteAs {
    my $self = shift;
    my $zipName = (ref($_[0]) eq 'HASH') ? $_[0]->{filename} : shift;
    return _error("no filename in overwriteAs()") unless defined($zipName);

    my ($fh, $tempName) = Archive::Zip::tempFile();
    return _error("Can't open temp file", $!) unless $fh;

    (my $backupName = $zipName) =~ s{(\.[^.]*)?$}{.zbk};

    my $status = $self->writeToFileHandle($fh);
    $fh->close();
    $fh = undef;

    if ($status != AZ_OK) {
        unlink($tempName);
        _printError("Can't write to $tempName");
        return $status;
    }

    my $err;

    # rename the zip
    if (-f $zipName && !rename($zipName, $backupName)) {
        $err = $!;
        unlink($tempName);
        return _error("Can't rename $zipName as $backupName", $err);
    }

    # move the temp to the original name (possibly copying)
    unless (File::Copy::move($tempName, $zipName)
        || File::Copy::copy($tempName, $zipName)) {
        $err = $!;
        rename($backupName, $zipName);
        unlink($tempName);
        return _error("Can't move $tempName to $zipName", $err);
    }

    # unlink the backup
    if (-f $backupName && !unlink($backupName)) {
        $err = $!;
        return _error("Can't unlink $backupName", $err);
    }

    return AZ_OK;
}

# Used only during writing
sub _writeCentralDirectoryOffset {
    shift->{'writeCentralDirectoryOffset'};
}

sub _writeEOCDOffset {
    shift->{'writeEOCDOffset'};
}

# Expects to have _writeEOCDOffset() set
sub _writeEndOfCentralDirectory {
    my ($self, $fh) = @_;

    $self->_print($fh, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING)
      or return _ioError('writing EOCD Signature');
    my $zipfileCommentLength = length($self->zipfileComment());

    my $header = pack(
        END_OF_CENTRAL_DIRECTORY_FORMAT,
        0,                          # {'diskNumber'},
        0,                          # {'diskNumberWithStartOfCentralDirectory'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectoriesOnThisDisk'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectories'},
        $self->_writeEOCDOffset() - $self->_writeCentralDirectoryOffset(),
        $self->_writeCentralDirectoryOffset(),
        $zipfileCommentLength
    );
    $self->_print($fh, $header)
      or return _ioError('writing EOCD header');
    if ($zipfileCommentLength) {
        $self->_print($fh, $self->zipfileComment())
          or return _ioError('writing zipfile comment');
    }
    return AZ_OK;
}

# $offset can be specified to truncate a zip file.
sub writeCentralDirectory {
    my $self = shift;

    my ($fh, $offset);
    if (ref($_[0]) eq 'HASH') {
        $fh     = $_[0]->{fileHandle};
        $offset = $_[0]->{offset};
    } else {
        ($fh, $offset) = @_;
    }

    if (defined($offset)) {
        $self->{'writeCentralDirectoryOffset'} = $offset;
        $fh->seek($offset, IO::Seekable::SEEK_SET)
          or return _ioError('seeking to write central directory');
    } else {
        $offset = $self->_writeCentralDirectoryOffset();
    }

    foreach my $member ($self->members()) {
        my $status = $member->_writeCentralDirectoryFileHeader($fh);
        return $status if $status != AZ_OK;
        $offset += $member->_centralDirectoryHeaderSize();
        $self->{'writeEOCDOffset'} = $offset;
    }
    return $self->_writeEndOfCentralDirectory($fh);
}

sub read {
    my $self = shift;
    my $fileName = (ref($_[0]) eq 'HASH') ? shift->{filename} : shift;
    return _error('No filename given') unless $fileName;
    my ($status, $fh) = _newFileHandle($fileName, 'r');
    return _ioError("opening $fileName for read") unless $status;

    $status = $self->readFromFileHandle($fh, $fileName);
    return $status if $status != AZ_OK;

    $fh->close();
    $self->{'fileName'} = $fileName;
    return AZ_OK;
}

sub readFromFileHandle {
    my $self = shift;

    my ($fh, $fileName);
    if (ref($_[0]) eq 'HASH') {
        $fh       = $_[0]->{fileHandle};
        $fileName = $_[0]->{filename};
    } else {
        ($fh, $fileName) = @_;
    }

    $fileName = $fh unless defined($fileName);
    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();

    _binmode($fh);
    $self->{'fileName'} = "$fh";

    # TODO: how to support non-seekable zips?
    return _error('file not seekable')
      unless _isSeekable($fh);

    $fh->seek(0, 0);    # rewind the file

    my $status = $self->_findEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    my $eocdPosition = $fh->tell();

    $status = $self->_readEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    $fh->seek($eocdPosition - $self->centralDirectorySize(),
        IO::Seekable::SEEK_SET)
      or return _ioError("Can't seek $fileName");

    # Try to detect garbage at beginning of archives
    # This should be 0
    $self->{'eocdOffset'} = $eocdPosition - $self->centralDirectorySize() # here
      - $self->centralDirectoryOffsetWRTStartingDiskNumber();

    for (; ;) {
        my $newMember =
          Archive::Zip::Member->_newFromZipFile($fh, $fileName,
            $self->eocdOffset());
        my $signature;
        ($status, $signature) = _readSignature($fh, $fileName);
        return $status if $status != AZ_OK;
        last if $signature == END_OF_CENTRAL_DIRECTORY_SIGNATURE;
        $status = $newMember->_readCentralDirectoryFileHeader();
        return $status if $status != AZ_OK;
        $status = $newMember->endRead();
        return $status if $status != AZ_OK;
        $newMember->_becomeDirectoryIfNecessary();
        push(@{$self->{'members'}}, $newMember);
    }

    return AZ_OK;
}

# Read EOCD, starting from position before signature.
# Return AZ_OK on success.
sub _readEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;

    # Skip past signature
    $fh->seek(SIGNATURE_LENGTH, IO::Seekable::SEEK_CUR)
      or return _ioError("Can't seek past EOCD signature");

    my $header = '';
    my $bytesRead = $fh->read($header, END_OF_CENTRAL_DIRECTORY_LENGTH);
    if ($bytesRead != END_OF_CENTRAL_DIRECTORY_LENGTH) {
        return _ioError("reading end of central directory");
    }

    my $zipfileCommentLength;
    (
        $self->{'diskNumber'},
        $self->{'diskNumberWithStartOfCentralDirectory'},
        $self->{'numberOfCentralDirectoriesOnThisDisk'},
        $self->{'numberOfCentralDirectories'},
        $self->{'centralDirectorySize'},
        $self->{'centralDirectoryOffsetWRTStartingDiskNumber'},
        $zipfileCommentLength
    ) = unpack(END_OF_CENTRAL_DIRECTORY_FORMAT, $header);

    if ($self->{'diskNumber'} == 0xFFFF ||
           $self->{'diskNumberWithStartOfCentralDirectory'} == 0xFFFF ||
           $self->{'numberOfCentralDirectoriesOnThisDisk'} == 0xFFFF ||
           $self->{'numberOfCentralDirectories'} == 0xFFFF ||
           $self->{'centralDirectorySize'} == 0xFFFFFFFF ||
           $self->{'centralDirectoryOffsetWRTStartingDiskNumber'} == 0xFFFFFFFF) {
        return _formatError("zip64 not supported" . Dumper($self));
    }
use Data::Dumper;
    if ($zipfileCommentLength) {
        my $zipfileComment = '';
        $bytesRead = $fh->read($zipfileComment, $zipfileCommentLength);
        if ($bytesRead != $zipfileCommentLength) {
            return _ioError("reading zipfile comment");
        }
        $self->{'zipfileComment'} = $zipfileComment;
    }

    return AZ_OK;
}

# Seek in my file to the end, then read backwards until we find the
# signature of the central directory record. Leave the file positioned right
# before the signature. Returns AZ_OK if success.
sub _findEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;
    my $data = '';
    $fh->seek(0, IO::Seekable::SEEK_END)
      or return _ioError("seeking to end");

    my $fileLength = $fh->tell();
    if ($fileLength < END_OF_CENTRAL_DIRECTORY_LENGTH + 4) {
        return _formatError("file is too short");
    }

    my $seekOffset = 0;
    my $pos        = -1;
    for (; ;) {
        $seekOffset += 512;
        $seekOffset = $fileLength if ($seekOffset > $fileLength);
        $fh->seek(-$seekOffset, IO::Seekable::SEEK_END)
          or return _ioError("seek failed");
        my $bytesRead = $fh->read($data, $seekOffset);
        if ($bytesRead != $seekOffset) {
            return _ioError("read failed");
        }
        $pos = rindex($data, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING);
        last
          if ( $pos >= 0
            or $seekOffset == $fileLength
            or $seekOffset >= $Archive::Zip::ChunkSize);
    }

    if ($pos >= 0) {
        $fh->seek($pos - $seekOffset, IO::Seekable::SEEK_CUR)
          or return _ioError("seeking to EOCD");
        return AZ_OK;
    } else {
        return _formatError("can't find EOCD signature");
    }
}

# Used to avoid taint problems when chdir'ing.
# Not intended to increase security in any way; just intended to shut up the -T
# complaints.  If your Cwd module is giving you unreliable returns from cwd()
# you have bigger problems than this.
sub _untaintDir {
    my $dir = shift;
    $dir =~ m/\A(.+)\z/s;
    return $1;
}

sub addTree {
    my $self = shift;

    my ($root, $dest, $pred, $compressionLevel);
    if (ref($_[0]) eq 'HASH') {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pred             = $_[0]->{select};
        $compressionLevel = $_[0]->{compressionLevel};
    } else {
        ($root, $dest, $pred, $compressionLevel) = @_;
    }

    return _error("root arg missing in call to addTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r }
      unless defined($pred);

    my @files;
    my $startDir = _untaintDir(cwd());

    return _error('undef returned by _untaintDir on cwd ', cwd())
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
            push(@files, Win32::GetANSIPathName($File::Find::name)) if (&$pred);
            $dir = Win32::GetANSIPathName($dir);
        } else {
            push(@files, $File::Find::name) if (&$pred);
        }
        chdir($dir);
    };

    if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
        $root = Win32::GetANSIPathName($root);
    }
    File::Find::find($wanted, $root);

    my $rootZipName = _asZipDirName($root, 1);    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    $dest = _asZipDirName($dest, 1);              # with trailing slash

    foreach my $fileName (@files) {
        my $isDir;
        if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
            $isDir = -d Win32::GetANSIPathName($fileName);
        } else {
            $isDir = -d $fileName;
        }

        # normalize, remove leading ./
        my $archiveName = _asZipDirName($fileName, $isDir);
        if ($archiveName eq $rootZipName) { $archiveName = $dest }
        else                              { $archiveName =~ s{$pattern}{$dest} }
        next if $archiveName =~ m{^\.?/?$};    # skip current dir
        my $member =
            $isDir
          ? $self->addDirectory($fileName, $archiveName)
          : $self->addFile($fileName, $archiveName);
        $member->desiredCompressionLevel($compressionLevel);

        return _error("add $fileName failed in addTree()") if !$member;
    }
    return AZ_OK;
}

sub addTreeMatching {
    my $self = shift;

    my ($root, $dest, $pattern, $pred, $compressionLevel);
    if (ref($_[0]) eq 'HASH') {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pattern          = $_[0]->{pattern};
        $pred             = $_[0]->{select};
        $compressionLevel = $_[0]->{compressionLevel};
    } else {
        ($root, $dest, $pattern, $pred, $compressionLevel) = @_;
    }

    return _error("root arg missing in call to addTreeMatching()")
      unless defined($root);
    $dest = '' unless defined($dest);
    return _error("pattern missing in call to addTreeMatching()")
      unless defined($pattern);
    my $matcher =
      $pred ? sub { m{$pattern} && &$pred } : sub { m{$pattern} && -r };
    return $self->addTree($root, $dest, $matcher, $compressionLevel);
}

# $zip->extractTree( $root, $dest [, $volume] );
#
# $root and $dest are Unix-style.
# $volume is in local FS format.
#
sub extractTree {
    my $self = shift;

    my ($root, $dest, $volume);
    if (ref($_[0]) eq 'HASH') {
        $root   = $_[0]->{root};
        $dest   = $_[0]->{zipName};
        $volume = $_[0]->{volume};
    } else {
        ($root, $dest, $volume) = @_;
    }

    $root = '' unless defined($root);
    if (defined $dest) {
        if ($dest !~ m{/$}) {
            $dest .= '/';
        }
    } else {
        $dest = './';
    }

    my $pattern = "^\Q$root";
    my @members = $self->membersMatching($pattern);

    foreach my $member (@members) {
        my $fileName = $member->fileName();    # in Unix format
        $fileName =~ s{$pattern}{$dest};       # in Unix format
                                               # convert to platform format:
        $fileName = Archive::Zip::_asLocalName($fileName, $volume);
        my $status = $member->extractToFileNamed($fileName);
        return $status if $status != AZ_OK;
    }
    return AZ_OK;
}

# $zip->updateMember( $memberOrName, $fileName );
# Returns (possibly updated) member, if any; undef on errors.

sub updateMember {
    my $self = shift;

    my ($oldMember, $fileName);
    if (ref($_[0]) eq 'HASH') {
        $oldMember = $_[0]->{memberOrZipName};
        $fileName  = $_[0]->{name};
    } else {
        ($oldMember, $fileName) = @_;
    }

    if (!defined($fileName)) {
        _error("updateMember(): missing fileName argument");
        return undef;
    }

    my @newStat = stat($fileName);
    if (!@newStat) {
        _ioError("Can't stat $fileName");
        return undef;
    }

    my $isDir = -d _;

    my $memberName;

    if (ref($oldMember)) {
        $memberName = $oldMember->fileName();
    } else {
        $oldMember = $self->memberNamed($memberName = $oldMember)
          || $self->memberNamed($memberName =
              _asZipDirName($oldMember, $isDir));
    }

    unless (defined($oldMember)
        && $oldMember->lastModTime() == $newStat[9]
        && $oldMember->isDirectory() == $isDir
        && ($isDir || ($oldMember->uncompressedSize() == $newStat[7]))) {

        # create the new member
        my $newMember =
            $isDir
          ? Archive::Zip::Member->newDirectoryNamed($fileName, $memberName)
          : Archive::Zip::Member->newFromFile($fileName, $memberName);

        unless (defined($newMember)) {
            _error("creation of member $fileName failed in updateMember()");
            return undef;
        }

        # replace old member or append new one
        if (defined($oldMember)) {
            $self->replaceMember($oldMember, $newMember);
        } else {
            $self->addMember($newMember);
        }

        return $newMember;
    }

    return $oldMember;
}

# $zip->updateTree( $root, [ $dest, [ $pred [, $mirror]]] );
#
# This takes the same arguments as addTree, but first checks to see
# whether the file or directory already exists in the zip file.
#
# If the fourth argument $mirror is true, then delete all my members
# if corresponding files were not found.

sub updateTree {
    my $self = shift;

    my ($root, $dest, $pred, $mirror, $compressionLevel);
    if (ref($_[0]) eq 'HASH') {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pred             = $_[0]->{select};
        $mirror           = $_[0]->{mirror};
        $compressionLevel = $_[0]->{compressionLevel};
    } else {
        ($root, $dest, $pred, $mirror, $compressionLevel) = @_;
    }

    return _error("root arg missing in call to updateTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r }
      unless defined($pred);

    $dest = _asZipDirName($dest, 1);
    my $rootZipName = _asZipDirName($root, 1);    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    my @files;
    my $startDir = _untaintDir(cwd());

    return _error('undef returned by _untaintDir on cwd ', cwd())
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push(@files, $File::Find::name) if (&$pred);
        chdir($dir);
    };

    File::Find::find($wanted, $root);

    # Now @files has all the files that I could potentially be adding to
    # the zip. Only add the ones that are necessary.
    # For each file (updated or not), add its member name to @done.
    my %done;
    foreach my $fileName (@files) {
        my @newStat = stat($fileName);
        my $isDir   = -d _;

        # normalize, remove leading ./
        my $memberName = _asZipDirName($fileName, $isDir);
        if ($memberName eq $rootZipName) { $memberName = $dest }
        else                             { $memberName =~ s{$pattern}{$dest} }
        next if $memberName =~ m{^\.?/?$};    # skip current dir

        $done{$memberName} = 1;
        my $changedMember = $self->updateMember($memberName, $fileName);
        $changedMember->desiredCompressionLevel($compressionLevel);
        return _error("updateTree failed to update $fileName")
          unless ref($changedMember);
    }

    # @done now has the archive names corresponding to all the found files.
    # If we're mirroring, delete all those members that aren't in @done.
    if ($mirror) {
        foreach my $member ($self->members()) {
            $self->removeMember($member)
              unless $done{$member->fileName()};
        }
    }

    return AZ_OK;
}

1;
FILE   'd87ee44c/Archive/Zip/DirectoryMember.pm  #line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/DirectoryMember.pm"
package Archive::Zip::DirectoryMember;

use strict;
use File::Path;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw( Archive::Zip::Member );
}

use Archive::Zip qw(
  :ERROR_CODES
  :UTILITY_METHODS
);

sub _newNamed {
    my $class    = shift;
    my $fileName = shift;    # FS name
    my $newName  = shift;    # Zip name
    $newName = _asZipDirName($fileName) unless $newName;
    my $self = $class->new(@_);
    $self->{'externalFileName'} = $fileName;
    $self->fileName($newName);

    if (-e $fileName) {

        # -e does NOT do a full stat, so we need to do one now
        if (-d _ ) {
            my @stat = stat(_);
            $self->unixFileAttributes($stat[2]);
            my $mod_t = $stat[9];
            if ($^O eq 'MSWin32' and !$mod_t) {
                $mod_t = time();
            }
            $self->setLastModFileDateTimeFromUnix($mod_t);

        } else {    # hmm.. trying to add a non-directory?
            _error($fileName, ' exists but is not a directory');
            return undef;
        }
    } else {
        $self->unixFileAttributes($self->DEFAULT_DIRECTORY_PERMISSIONS);
        $self->setLastModFileDateTimeFromUnix(time());
    }
    return $self;
}

sub externalFileName {
    shift->{'externalFileName'};
}

sub isDirectory {
    return 1;
}

sub extractToFileNamed {
    my $self    = shift;
    my $name    = shift;                                 # local FS name
    my $attribs = $self->unixFileAttributes() & 07777;
    mkpath($name, 0, $attribs);                          # croaks on error
    utime($self->lastModTime(), $self->lastModTime(), $name);
    return AZ_OK;
}

sub fileName {
    my $self    = shift;
    my $newName = shift;
    $newName =~ s{/?$}{/} if defined($newName);
    return $self->SUPER::fileName($newName);
}

# So people don't get too confused. This way it looks like the problem
# is in their code...
sub contents {
    return wantarray ? (undef, AZ_OK) : undef;
}

1;
FILE   "dc4e9663/Archive/Zip/FileMember.pm  {#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/FileMember.pm"
package Archive::Zip::FileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw ( Archive::Zip::Member );
}

use Archive::Zip qw(
  :UTILITY_METHODS
);

sub externalFileName {
    shift->{'externalFileName'};
}

# Return true if I depend on the named file
sub _usesFileNamed {
    my $self     = shift;
    my $fileName = shift;
    my $xfn      = $self->externalFileName();
    return undef if ref($xfn);
    return $xfn eq $fileName;
}

sub fh {
    my $self = shift;
    $self->_openFile()
      if !defined($self->{'fh'}) || !$self->{'fh'}->opened();
    return $self->{'fh'};
}

# opens my file handle from my file name
sub _openFile {
    my $self = shift;
    my ($status, $fh) = _newFileHandle($self->externalFileName(), 'r');
    if (!$status) {
        _ioError("Can't open", $self->externalFileName());
        return undef;
    }
    $self->{'fh'} = $fh;
    _binmode($fh);
    return $fh;
}

# Make sure I close my file handle
sub endRead {
    my $self = shift;
    undef $self->{'fh'};    # _closeFile();
    return $self->SUPER::endRead(@_);
}

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;
    delete($self->{'externalFileName'});
    delete($self->{'fh'});
    return $self->SUPER::_become($newClass);
}

1;
FILE   c31fbf9f/Archive/Zip/Member.pm  ��#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/Member.pm"
package Archive::Zip::Member;

# A generic member of an archive

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw( Archive::Zip );

    if ($^O eq 'MSWin32') {
        require Win32;
        require Encode;
        Encode->import(qw{ decode_utf8 });
    }
}

use Archive::Zip qw(
  :CONSTANTS
  :MISC_CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

use Time::Local ();
use Compress::Raw::Zlib qw( Z_OK Z_STREAM_END MAX_WBITS );
use File::Path;
use File::Basename;

# Unix perms for default creation of files/dirs.
use constant DEFAULT_DIRECTORY_PERMISSIONS => 040755;
use constant DEFAULT_FILE_PERMISSIONS      => 0100666;
use constant DIRECTORY_ATTRIB              => 040000;
use constant FILE_ATTRIB                   => 0100000;

# Returns self if successful, else undef
# Assumes that fh is positioned at beginning of central directory file header.
# Leaves fh positioned immediately after file header or EOCD signature.
sub _newFromZipFile {
    my $class = shift;
    my $self  = Archive::Zip::ZipFileMember->_newFromZipFile(@_);
    return $self;
}

sub newFromString {
    my $class = shift;

    my ($stringOrStringRef, $fileName);
    if (ref($_[0]) eq 'HASH') {
        $stringOrStringRef = $_[0]->{string};
        $fileName          = $_[0]->{zipName};
    } else {
        ($stringOrStringRef, $fileName) = @_;
    }

    my $self =
      Archive::Zip::StringMember->_newFromString($stringOrStringRef, $fileName);
    return $self;
}

sub newFromFile {
    my $class = shift;

    my ($fileName, $zipName);
    if (ref($_[0]) eq 'HASH') {
        $fileName = $_[0]->{fileName};
        $zipName  = $_[0]->{zipName};
    } else {
        ($fileName, $zipName) = @_;
    }

    my $self =
      Archive::Zip::NewFileMember->_newFromFileNamed($fileName, $zipName);
    return $self;
}

sub newDirectoryNamed {
    my $class = shift;

    my ($directoryName, $newName);
    if (ref($_[0]) eq 'HASH') {
        $directoryName = $_[0]->{directoryName};
        $newName       = $_[0]->{zipName};
    } else {
        ($directoryName, $newName) = @_;
    }

    my $self =
      Archive::Zip::DirectoryMember->_newNamed($directoryName, $newName);
    return $self;
}

sub new {
    my $class = shift;
    my $self  = {
        'lastModFileDateTime'      => 0,
        'fileAttributeFormat'      => FA_UNIX,
        'versionMadeBy'            => 20,
        'versionNeededToExtract'   => 20,
        'bitFlag'                  => ($Archive::Zip::UNICODE ? 0x0800 : 0),
        'compressionMethod'        => COMPRESSION_STORED,
        'desiredCompressionMethod' => COMPRESSION_STORED,
        'desiredCompressionLevel'  => COMPRESSION_LEVEL_NONE,
        'internalFileAttributes'   => 0,
        'externalFileAttributes'   => 0,                        # set later
        'fileName'                 => '',
        'cdExtraField'             => '',
        'localExtraField'          => '',
        'fileComment'              => '',
        'crc32'                    => 0,
        'compressedSize'           => 0,
        'uncompressedSize'         => 0,
        'isSymbolicLink'           => 0,
        'password' => undef,    # password for encrypted data
        'crc32c'   => -1,       # crc for decrypted data
        @_
    };
    bless($self, $class);
    $self->unixFileAttributes($self->DEFAULT_FILE_PERMISSIONS);
    return $self;
}

sub _becomeDirectoryIfNecessary {
    my $self = shift;
    $self->_become('Archive::Zip::DirectoryMember')
      if $self->isDirectory();
    return $self;
}

# Morph into given class (do whatever cleanup I need to do)
sub _become {
    return bless($_[0], $_[1]);
}

sub versionMadeBy {
    shift->{'versionMadeBy'};
}

sub fileAttributeFormat {
    my $self = shift;

    if (@_) {
        $self->{fileAttributeFormat} =
          (ref($_[0]) eq 'HASH') ? $_[0]->{format} : $_[0];
    } else {
        return $self->{fileAttributeFormat};
    }
}

sub versionNeededToExtract {
    shift->{'versionNeededToExtract'};
}

sub bitFlag {
    my $self = shift;

# Set General Purpose Bit Flags according to the desiredCompressionLevel setting
    if (   $self->desiredCompressionLevel == 1
        || $self->desiredCompressionLevel == 2) {
        $self->{'bitFlag'} |= DEFLATING_COMPRESSION_FAST;
    } elsif ($self->desiredCompressionLevel == 3
        || $self->desiredCompressionLevel == 4
        || $self->desiredCompressionLevel == 5
        || $self->desiredCompressionLevel == 6
        || $self->desiredCompressionLevel == 7) {
        $self->{'bitFlag'} |= DEFLATING_COMPRESSION_NORMAL;
    } elsif ($self->desiredCompressionLevel == 8
        || $self->desiredCompressionLevel == 9) {
        $self->{'bitFlag'} |= DEFLATING_COMPRESSION_MAXIMUM;
    }

    if ($Archive::Zip::UNICODE) {
        $self->{'bitFlag'} |= 0x0800;
    }
    $self->{'bitFlag'};
}

sub password {
    my $self = shift;
    $self->{'password'} = shift if @_;
    $self->{'password'};
}

sub compressionMethod {
    shift->{'compressionMethod'};
}

sub desiredCompressionMethod {
    my $self = shift;
    my $newDesiredCompressionMethod =
      (ref($_[0]) eq 'HASH') ? shift->{compressionMethod} : shift;
    my $oldDesiredCompressionMethod = $self->{'desiredCompressionMethod'};
    if (defined($newDesiredCompressionMethod)) {
        $self->{'desiredCompressionMethod'} = $newDesiredCompressionMethod;
        if ($newDesiredCompressionMethod == COMPRESSION_STORED) {
            $self->{'desiredCompressionLevel'} = 0;
            $self->{'bitFlag'} &= ~GPBF_HAS_DATA_DESCRIPTOR_MASK
                if $self->uncompressedSize() == 0;
        } elsif ($oldDesiredCompressionMethod == COMPRESSION_STORED) {
            $self->{'desiredCompressionLevel'} = COMPRESSION_LEVEL_DEFAULT;
        }
    }
    return $oldDesiredCompressionMethod;
}

sub desiredCompressionLevel {
    my $self = shift;
    my $newDesiredCompressionLevel =
      (ref($_[0]) eq 'HASH') ? shift->{compressionLevel} : shift;
    my $oldDesiredCompressionLevel = $self->{'desiredCompressionLevel'};
    if (defined($newDesiredCompressionLevel)) {
        $self->{'desiredCompressionLevel'}  = $newDesiredCompressionLevel;
        $self->{'desiredCompressionMethod'} = (
            $newDesiredCompressionLevel
            ? COMPRESSION_DEFLATED
            : COMPRESSION_STORED
        );
    }
    return $oldDesiredCompressionLevel;
}

sub fileName {
    my $self    = shift;
    my $newName = shift;
    if (defined $newName) {
        $newName =~ s{[\\/]+}{/}g;    # deal with dos/windoze problems
        $self->{'fileName'} = $newName;
    }
    return $self->{'fileName'};
}

sub lastModFileDateTime {
    my $modTime = shift->{'lastModFileDateTime'};
    $modTime =~ m/^(\d+)$/;           # untaint
    return $1;
}

sub lastModTime {
    my $self = shift;
    return _dosToUnixTime($self->lastModFileDateTime());
}

sub setLastModFileDateTimeFromUnix {
    my $self   = shift;
    my $time_t = shift;
    $self->{'lastModFileDateTime'} = _unixToDosTime($time_t);
}

sub internalFileAttributes {
    shift->{'internalFileAttributes'};
}

sub externalFileAttributes {
    shift->{'externalFileAttributes'};
}

# Convert UNIX permissions into proper value for zip file
# Usable as a function or a method
sub _mapPermissionsFromUnix {
    my $self    = shift;
    my $mode    = shift;
    my $attribs = $mode << 16;

    # Microsoft Windows Explorer needs this bit set for directories
    if ($mode & DIRECTORY_ATTRIB) {
        $attribs |= 16;
    }

    return $attribs;

    # TODO: map more MS-DOS perms
}

# Convert ZIP permissions into Unix ones
#
# This was taken from Info-ZIP group's portable UnZip
# zipfile-extraction program, version 5.50.
# http://www.info-zip.org/pub/infozip/
#
# See the mapattr() function in unix/unix.c
# See the attribute format constants in unzpriv.h
#
# XXX Note that there's one situation that is not implemented
# yet that depends on the "extra field."
sub _mapPermissionsToUnix {
    my $self = shift;

    my $format  = $self->{'fileAttributeFormat'};
    my $attribs = $self->{'externalFileAttributes'};

    my $mode = 0;

    if ($format == FA_AMIGA) {
        $attribs = $attribs >> 17 & 7;                         # Amiga RWE bits
        $mode    = $attribs << 6 | $attribs << 3 | $attribs;
        return $mode;
    }

    if ($format == FA_THEOS) {
        $attribs &= 0xF1FFFFFF;
        if (($attribs & 0xF0000000) != 0x40000000) {
            $attribs &= 0x01FFFFFF;    # not a dir, mask all ftype bits
        } else {
            $attribs &= 0x41FFFFFF;    # leave directory bit as set
        }
    }

    if (   $format == FA_UNIX
        || $format == FA_VAX_VMS
        || $format == FA_ACORN
        || $format == FA_ATARI_ST
        || $format == FA_BEOS
        || $format == FA_QDOS
        || $format == FA_TANDEM) {
        $mode = $attribs >> 16;
        return $mode if $mode != 0 or not $self->localExtraField;

        # warn("local extra field is: ", $self->localExtraField, "\n");

        # XXX This condition is not implemented
        # I'm just including the comments from the info-zip section for now.

        # Some (non-Info-ZIP) implementations of Zip for Unix and
        # VMS (and probably others ??) leave 0 in the upper 16-bit
        # part of the external_file_attributes field. Instead, they
        # store file permission attributes in some extra field.
        # As a work-around, we search for the presence of one of
        # these extra fields and fall back to the MSDOS compatible
        # part of external_file_attributes if one of the known
        # e.f. types has been detected.
        # Later, we might implement extraction of the permission
        # bits from the VMS extra field. But for now, the work-around
        # should be sufficient to provide "readable" extracted files.
        # (For ASI Unix e.f., an experimental remap from the e.f.
        # mode value IS already provided!)
    }

    # PKWARE's PKZip for Unix marks entries as FA_MSDOS, but stores the
    # Unix attributes in the upper 16 bits of the external attributes
    # field, just like Info-ZIP's Zip for Unix.  We try to use that
    # value, after a check for consistency with the MSDOS attribute
    # bits (see below).
    if ($format == FA_MSDOS) {
        $mode = $attribs >> 16;
    }

    # FA_MSDOS, FA_OS2_HPFS, FA_WINDOWS_NTFS, FA_MACINTOSH, FA_TOPS20
    $attribs = !($attribs & 1) << 1 | ($attribs & 0x10) >> 4;

    # keep previous $mode setting when its "owner"
    # part appears to be consistent with DOS attribute flags!
    return $mode if ($mode & 0700) == (0400 | $attribs << 6);
    $mode = 0444 | $attribs << 6 | $attribs << 3 | $attribs;
    return $mode;
}

sub unixFileAttributes {
    my $self     = shift;
    my $oldPerms = $self->_mapPermissionsToUnix;

    my $perms;
    if (@_) {
        $perms = (ref($_[0]) eq 'HASH') ? $_[0]->{attributes} : $_[0];

        if ($self->isDirectory) {
            $perms &= ~FILE_ATTRIB;
            $perms |= DIRECTORY_ATTRIB;
        } else {
            $perms &= ~DIRECTORY_ATTRIB;
            $perms |= FILE_ATTRIB;
        }
        $self->{externalFileAttributes} =
          $self->_mapPermissionsFromUnix($perms);
    }

    return $oldPerms;
}

sub localExtraField {
    my $self = shift;

    if (@_) {
        $self->{localExtraField} =
          (ref($_[0]) eq 'HASH') ? $_[0]->{field} : $_[0];
    } else {
        return $self->{localExtraField};
    }
}

sub cdExtraField {
    my $self = shift;

    if (@_) {
        $self->{cdExtraField} = (ref($_[0]) eq 'HASH') ? $_[0]->{field} : $_[0];
    } else {
        return $self->{cdExtraField};
    }
}

sub extraFields {
    my $self = shift;
    return $self->localExtraField() . $self->cdExtraField();
}

sub fileComment {
    my $self = shift;

    if (@_) {
        $self->{fileComment} =
          (ref($_[0]) eq 'HASH')
          ? pack('C0a*', $_[0]->{comment})
          : pack('C0a*', $_[0]);
    } else {
        return $self->{fileComment};
    }
}

sub hasDataDescriptor {
    my $self = shift;
    if (@_) {
        my $shouldHave = shift;
        if ($shouldHave) {
            $self->{'bitFlag'} |= GPBF_HAS_DATA_DESCRIPTOR_MASK;
        } else {
            $self->{'bitFlag'} &= ~GPBF_HAS_DATA_DESCRIPTOR_MASK;
        }
    }
    return $self->{'bitFlag'} & GPBF_HAS_DATA_DESCRIPTOR_MASK;
}

sub crc32 {
    shift->{'crc32'};
}

sub crc32String {
    sprintf("%08x", shift->{'crc32'});
}

sub compressedSize {
    shift->{'compressedSize'};
}

sub uncompressedSize {
    shift->{'uncompressedSize'};
}

sub isEncrypted {
    shift->{'bitFlag'} & GPBF_ENCRYPTED_MASK;
}

sub isTextFile {
    my $self = shift;
    my $bit  = $self->internalFileAttributes() & IFA_TEXT_FILE_MASK;
    if (@_) {
        my $flag = (ref($_[0]) eq 'HASH') ? shift->{flag} : shift;
        $self->{'internalFileAttributes'} &= ~IFA_TEXT_FILE_MASK;
        $self->{'internalFileAttributes'} |=
          ($flag ? IFA_TEXT_FILE : IFA_BINARY_FILE);
    }
    return $bit == IFA_TEXT_FILE;
}

sub isBinaryFile {
    my $self = shift;
    my $bit  = $self->internalFileAttributes() & IFA_TEXT_FILE_MASK;
    if (@_) {
        my $flag = shift;
        $self->{'internalFileAttributes'} &= ~IFA_TEXT_FILE_MASK;
        $self->{'internalFileAttributes'} |=
          ($flag ? IFA_BINARY_FILE : IFA_TEXT_FILE);
    }
    return $bit == IFA_BINARY_FILE;
}

sub extractToFileNamed {
    my $self = shift;

    # local FS name
    my $name = (ref($_[0]) eq 'HASH') ? $_[0]->{name} : $_[0];
    $self->{'isSymbolicLink'} = 0;

    # Check if the file / directory is a symbolic link or not
    if ($self->{'externalFileAttributes'} == 0xA1FF0000) {
        $self->{'isSymbolicLink'} = 1;
        $self->{'newName'}        = $name;
        my ($status, $fh) = _newFileHandle($name, 'r');
        my $retval = $self->extractToFileHandle($fh);
        $fh->close();
    } else {

        #return _writeSymbolicLink($self, $name) if $self->isSymbolicLink();

        my ($status, $fh);
        if ($^O eq 'MSWin32' && $Archive::Zip::UNICODE) {
            $name = decode_utf8(Win32::GetFullPathName($name));
            mkpath_win32($name);
            Win32::CreateFile($name);
            ($status, $fh) = _newFileHandle(Win32::GetANSIPathName($name), 'w');
        } else {
            mkpath(dirname($name));    # croaks on error
            ($status, $fh) = _newFileHandle($name, 'w');
        }
        return _ioError("Can't open file $name for write") unless $status;
        my $retval = $self->extractToFileHandle($fh);
        $fh->close();
        chmod($self->unixFileAttributes(), $name)
          or return _error("Can't chmod() ${name}: $!");
        utime($self->lastModTime(), $self->lastModTime(), $name);
        return $retval;
    }
}

sub mkpath_win32 {
    my $path = shift;
    use File::Spec;

    my ($volume, @path) = File::Spec->splitdir($path);
    $path = File::Spec->catfile($volume, shift @path);
    pop @path;
    while (@path) {
        $path = File::Spec->catfile($path, shift @path);
        Win32::CreateDirectory($path);
    }
}

sub _writeSymbolicLink {
    my $self      = shift;
    my $name      = shift;
    my $chunkSize = $Archive::Zip::ChunkSize;

    #my ( $outRef, undef ) = $self->readChunk($chunkSize);
    my $fh;
    my $retval = $self->extractToFileHandle($fh);
    my ($outRef, undef) = $self->readChunk(100);
}

sub isSymbolicLink {
    my $self = shift;
    if ($self->{'externalFileAttributes'} == 0xA1FF0000) {
        $self->{'isSymbolicLink'} = 1;
    } else {
        return 0;
    }
    1;
}

sub isDirectory {
    return 0;
}

sub externalFileName {
    return undef;
}

# The following are used when copying data
sub _writeOffset {
    shift->{'writeOffset'};
}

sub _readOffset {
    shift->{'readOffset'};
}

sub writeLocalHeaderRelativeOffset {
    shift->{'writeLocalHeaderRelativeOffset'};
}

sub wasWritten { shift->{'wasWritten'} }

sub _dataEnded {
    shift->{'dataEnded'};
}

sub _readDataRemaining {
    shift->{'readDataRemaining'};
}

sub _inflater {
    shift->{'inflater'};
}

sub _deflater {
    shift->{'deflater'};
}

# Return the total size of my local header
sub _localHeaderSize {
    my $self = shift;
    {
        use bytes;
        return SIGNATURE_LENGTH +
          LOCAL_FILE_HEADER_LENGTH +
          length($self->fileName()) +
          length($self->localExtraField());
    }
}

# Return the total size of my CD header
sub _centralDirectoryHeaderSize {
    my $self = shift;
    {
        use bytes;
        return SIGNATURE_LENGTH +
          CENTRAL_DIRECTORY_FILE_HEADER_LENGTH +
          length($self->fileName()) +
          length($self->cdExtraField()) +
          length($self->fileComment());
    }
}

# DOS date/time format
# 0-4 (5) Second divided by 2
# 5-10 (6) Minute (0-59)
# 11-15 (5) Hour (0-23 on a 24-hour clock)
# 16-20 (5) Day of the month (1-31)
# 21-24 (4) Month (1 = January, 2 = February, etc.)
# 25-31 (7) Year offset from 1980 (add 1980 to get actual year)

# Convert DOS date/time format to unix time_t format
# NOT AN OBJECT METHOD!
sub _dosToUnixTime {
    my $dt = shift;
    return time() unless defined($dt);

    my $year = (($dt >> 25) & 0x7f) + 80;
    my $mon  = (($dt >> 21) & 0x0f) - 1;
    my $mday = (($dt >> 16) & 0x1f);

    my $hour = (($dt >> 11) & 0x1f);
    my $min  = (($dt >> 5) & 0x3f);
    my $sec  = (($dt << 1) & 0x3e);

    # catch errors
    my $time_t =
      eval { Time::Local::timelocal($sec, $min, $hour, $mday, $mon, $year); };
    return time() if ($@);
    return $time_t;
}

# Note, this is not exactly UTC 1980, it's 1980 + 12 hours and 1
# minute so that nothing timezoney can muck us up.
my $safe_epoch = 315576060;

# convert a unix time to DOS date/time
# NOT AN OBJECT METHOD!
sub _unixToDosTime {
    my $time_t = shift;
    unless ($time_t) {
        _error("Tried to add member with zero or undef value for time");
        $time_t = $safe_epoch;
    }
    if ($time_t < $safe_epoch) {
        _ioError("Unsupported date before 1980 encountered, moving to 1980");
        $time_t = $safe_epoch;
    }
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($time_t);
    my $dt = 0;
    $dt += ($sec >> 1);
    $dt += ($min << 5);
    $dt += ($hour << 11);
    $dt += ($mday << 16);
    $dt += (($mon + 1) << 21);
    $dt += (($year - 80) << 25);
    return $dt;
}

sub head {
    my ($self, $mode) = (@_, 0);

    use bytes;
    return pack LOCAL_FILE_HEADER_FORMAT,
      $self->versionNeededToExtract(),
      $self->{'bitFlag'},
      $self->desiredCompressionMethod(),
      $self->lastModFileDateTime(), 
      $self->hasDataDescriptor() 
        ? (0,0,0) # crc, compr & uncompr all zero if data descriptor present
        : (
            $self->crc32(), 
            $mode
              ? $self->_writeOffset()       # compressed size
              : $self->compressedSize(),    # may need to be re-written later
            $self->uncompressedSize(),
          ),
      length($self->fileName()),
      length($self->localExtraField());
}

# Write my local header to a file handle.
# Stores the offset to the start of the header in my
# writeLocalHeaderRelativeOffset member.
# Returns AZ_OK on success.
sub _writeLocalFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $signatureData = pack(SIGNATURE_FORMAT, LOCAL_FILE_HEADER_SIGNATURE);
    $self->_print($fh, $signatureData)
      or return _ioError("writing local header signature");

    my $header = $self->head(1);

    $self->_print($fh, $header) or return _ioError("writing local header");

    # Check for a valid filename or a filename equal to a literal `0'
    if ($self->fileName() || $self->fileName eq '0') {
        $self->_print($fh, $self->fileName())
          or return _ioError("writing local header filename");
    }
    if ($self->localExtraField()) {
        $self->_print($fh, $self->localExtraField())
          or return _ioError("writing local extra field");
    }

    return AZ_OK;
}

sub _writeCentralDirectoryFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $sigData =
      pack(SIGNATURE_FORMAT, CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE);
    $self->_print($fh, $sigData)
      or return _ioError("writing central directory header signature");

    my ($fileNameLength, $extraFieldLength, $fileCommentLength);
    {
        use bytes;
        $fileNameLength    = length($self->fileName());
        $extraFieldLength  = length($self->cdExtraField());
        $fileCommentLength = length($self->fileComment());
    }

    my $header = pack(
        CENTRAL_DIRECTORY_FILE_HEADER_FORMAT,
        $self->versionMadeBy(),
        $self->fileAttributeFormat(),
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),            # these three fields should have been updated
        $self->_writeOffset(),     # by writing the data stream out
        $self->uncompressedSize(), #
        $fileNameLength,
        $extraFieldLength,
        $fileCommentLength,
        0,                         # {'diskNumberStart'},
        $self->internalFileAttributes(),
        $self->externalFileAttributes(),
        $self->writeLocalHeaderRelativeOffset());

    $self->_print($fh, $header)
      or return _ioError("writing central directory header");
    if ($fileNameLength) {
        $self->_print($fh, $self->fileName())
          or return _ioError("writing central directory header signature");
    }
    if ($extraFieldLength) {
        $self->_print($fh, $self->cdExtraField())
          or return _ioError("writing central directory extra field");
    }
    if ($fileCommentLength) {
        $self->_print($fh, $self->fileComment())
          or return _ioError("writing central directory file comment");
    }

    return AZ_OK;
}

# This writes a data descriptor to the given file handle.
# Assumes that crc32, writeOffset, and uncompressedSize are
# set correctly (they should be after a write).
# Further, the local file header should have the
# GPBF_HAS_DATA_DESCRIPTOR_MASK bit set.
sub _writeDataDescriptor {
    my $self   = shift;
    my $fh     = shift;
    my $header = pack(
        SIGNATURE_FORMAT . DATA_DESCRIPTOR_FORMAT,
        DATA_DESCRIPTOR_SIGNATURE,
        $self->crc32(),
        $self->_writeOffset(),    # compressed size
        $self->uncompressedSize());

    $self->_print($fh, $header)
      or return _ioError("writing data descriptor");
    return AZ_OK;
}

# Re-writes the local file header with new crc32 and compressedSize fields.
# To be called after writing the data stream.
# Assumes that filename and extraField sizes didn't change since last written.
sub _refreshLocalFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $here = $fh->tell();
    $fh->seek($self->writeLocalHeaderRelativeOffset() + SIGNATURE_LENGTH,
        IO::Seekable::SEEK_SET)
      or return _ioError("seeking to rewrite local header");

    my $header = $self->head(1);

    $self->_print($fh, $header)
      or return _ioError("re-writing local header");
    $fh->seek($here, IO::Seekable::SEEK_SET)
      or return _ioError("seeking after rewrite of local header");

    return AZ_OK;
}

sub readChunk {
    my $self = shift;
    my $chunkSize = (ref($_[0]) eq 'HASH') ? $_[0]->{chunkSize} : $_[0];

    if ($self->readIsDone()) {
        $self->endRead();
        my $dummy = '';
        return (\$dummy, AZ_STREAM_END);
    }

    $chunkSize = $Archive::Zip::ChunkSize if not defined($chunkSize);
    $chunkSize = $self->_readDataRemaining()
      if $chunkSize > $self->_readDataRemaining();

    my $buffer = '';
    my $outputRef;
    my ($bytesRead, $status) = $self->_readRawChunk(\$buffer, $chunkSize);
    return (\$buffer, $status) unless $status == AZ_OK;

    $buffer && $self->isEncrypted and $buffer = $self->_decode($buffer);
    $self->{'readDataRemaining'} -= $bytesRead;
    $self->{'readOffset'} += $bytesRead;

    if ($self->compressionMethod() == COMPRESSION_STORED) {
        $self->{'crc32'} = $self->computeCRC32($buffer, $self->{'crc32'});
    }

    ($outputRef, $status) = &{$self->{'chunkHandler'}}($self, \$buffer);
    $self->{'writeOffset'} += length($$outputRef);

    $self->endRead()
      if $self->readIsDone();

    return ($outputRef, $status);
}

# Read the next raw chunk of my data. Subclasses MUST implement.
#   my ( $bytesRead, $status) = $self->_readRawChunk( \$buffer, $chunkSize );
sub _readRawChunk {
    my $self = shift;
    return $self->_subclassResponsibility();
}

# A place holder to catch rewindData errors if someone ignores
# the error code.
sub _noChunk {
    my $self = shift;
    return (\undef, _error("trying to copy chunk when init failed"));
}

# Basically a no-op so that I can have a consistent interface.
# ( $outputRef, $status) = $self->_copyChunk( \$buffer );
sub _copyChunk {
    my ($self, $dataRef) = @_;
    return ($dataRef, AZ_OK);
}

# ( $outputRef, $status) = $self->_deflateChunk( \$buffer );
sub _deflateChunk {
    my ($self, $buffer) = @_;
    my ($status) = $self->_deflater()->deflate($buffer, my $out);

    if ($self->_readDataRemaining() == 0) {
        my $extraOutput;
        ($status) = $self->_deflater()->flush($extraOutput);
        $out .= $extraOutput;
        $self->endRead();
        return (\$out, AZ_STREAM_END);
    } elsif ($status == Z_OK) {
        return (\$out, AZ_OK);
    } else {
        $self->endRead();
        my $retval = _error('deflate error', $status);
        my $dummy = '';
        return (\$dummy, $retval);
    }
}

# ( $outputRef, $status) = $self->_inflateChunk( \$buffer );
sub _inflateChunk {
    my ($self, $buffer) = @_;
    my ($status) = $self->_inflater()->inflate($buffer, my $out);
    my $retval;
    $self->endRead() unless $status == Z_OK;
    if ($status == Z_OK || $status == Z_STREAM_END) {
        $retval = ($status == Z_STREAM_END) ? AZ_STREAM_END : AZ_OK;
        return (\$out, $retval);
    } else {
        $retval = _error('inflate error', $status);
        my $dummy = '';
        return (\$dummy, $retval);
    }
}

sub rewindData {
    my $self = shift;
    my $status;

    # set to trap init errors
    $self->{'chunkHandler'} = $self->can('_noChunk');

    # Work around WinZip bug with 0-length DEFLATED files
    $self->desiredCompressionMethod(COMPRESSION_STORED)
      if $self->uncompressedSize() == 0;

    # assume that we're going to read the whole file, and compute the CRC anew.
    $self->{'crc32'} = 0
      if ($self->compressionMethod() == COMPRESSION_STORED);

    # These are the only combinations of methods we deal with right now.
    if (    $self->compressionMethod() == COMPRESSION_STORED
        and $self->desiredCompressionMethod() == COMPRESSION_DEFLATED) {
        ($self->{'deflater'}, $status) = Compress::Raw::Zlib::Deflate->new(
            '-Level'      => $self->desiredCompressionLevel(),
            '-WindowBits' => -MAX_WBITS(),                     # necessary magic
            '-Bufsize'    => $Archive::Zip::ChunkSize,
            @_
        );    # pass additional options
        return _error('deflateInit error:', $status)
          unless $status == Z_OK;
        $self->{'chunkHandler'} = $self->can('_deflateChunk');
    } elsif ($self->compressionMethod() == COMPRESSION_DEFLATED
        and $self->desiredCompressionMethod() == COMPRESSION_STORED) {
        ($self->{'inflater'}, $status) = Compress::Raw::Zlib::Inflate->new(
            '-WindowBits' => -MAX_WBITS(),               # necessary magic
            '-Bufsize'    => $Archive::Zip::ChunkSize,
            @_
        );    # pass additional options
        return _error('inflateInit error:', $status)
          unless $status == Z_OK;
        $self->{'chunkHandler'} = $self->can('_inflateChunk');
    } elsif ($self->compressionMethod() == $self->desiredCompressionMethod()) {
        $self->{'chunkHandler'} = $self->can('_copyChunk');
    } else {
        return _error(
            sprintf(
                "Unsupported compression combination: read %d, write %d",
                $self->compressionMethod(),
                $self->desiredCompressionMethod()));
    }

    $self->{'readDataRemaining'} =
      ($self->compressionMethod() == COMPRESSION_STORED)
      ? $self->uncompressedSize()
      : $self->compressedSize();
    $self->{'dataEnded'}  = 0;
    $self->{'readOffset'} = 0;

    return AZ_OK;
}

sub endRead {
    my $self = shift;
    delete $self->{'inflater'};
    delete $self->{'deflater'};
    $self->{'dataEnded'}         = 1;
    $self->{'readDataRemaining'} = 0;
    return AZ_OK;
}

sub readIsDone {
    my $self = shift;
    return ($self->_dataEnded() or !$self->_readDataRemaining());
}

sub contents {
    my $self        = shift;
    my $newContents = shift;

    if (defined($newContents)) {

        # change our type and call the subclass contents method.
        $self->_become('Archive::Zip::StringMember');
        return $self->contents(pack('C0a*', $newContents)); # in case of Unicode
    } else {
        my $oldCompression =
          $self->desiredCompressionMethod(COMPRESSION_STORED);
        my $status = $self->rewindData(@_);
        if ($status != AZ_OK) {
            $self->endRead();
            return $status;
        }
        my $retval = '';
        while ($status == AZ_OK) {
            my $ref;
            ($ref, $status) = $self->readChunk($self->_readDataRemaining());

            # did we get it in one chunk?
            if (length($$ref) == $self->uncompressedSize()) {
                $retval = $$ref;
            } else {
                $retval .= $$ref
            }
        }
        $self->desiredCompressionMethod($oldCompression);
        $self->endRead();
        $status = AZ_OK if $status == AZ_STREAM_END;
        $retval = undef unless $status == AZ_OK;
        return wantarray ? ($retval, $status) : $retval;
    }
}

sub extractToFileHandle {
    my $self = shift;
    my $fh = (ref($_[0]) eq 'HASH') ? shift->{fileHandle} : shift;
    _binmode($fh);
    my $oldCompression = $self->desiredCompressionMethod(COMPRESSION_STORED);
    my $status         = $self->rewindData(@_);
    $status = $self->_writeData($fh) if $status == AZ_OK;
    $self->desiredCompressionMethod($oldCompression);
    $self->endRead();
    return $status;
}

# write local header and data stream to file handle
sub _writeToFileHandle {
    my $self         = shift;
    my $fh           = shift;
    my $fhIsSeekable = shift;
    my $offset       = shift;

    return _error("no member name given for $self")
      if $self->fileName() eq '';

    $self->{'writeLocalHeaderRelativeOffset'} = $offset;
    $self->{'wasWritten'}                     = 0;

    # Determine if I need to write a data descriptor
    # I need to do this if I can't refresh the header
    # and I don't know compressed size or crc32 fields.
    my $headerFieldsUnknown = (
        ($self->uncompressedSize() > 0)
          and ($self->compressionMethod() == COMPRESSION_STORED
            or $self->desiredCompressionMethod() == COMPRESSION_DEFLATED));

    my $shouldWriteDataDescriptor =
      ($headerFieldsUnknown and not $fhIsSeekable);

    $self->hasDataDescriptor(1)
      if ($shouldWriteDataDescriptor);

    $self->{'writeOffset'} = 0;

    my $status = $self->rewindData();
    ($status = $self->_writeLocalFileHeader($fh))
      if $status == AZ_OK;
    ($status = $self->_writeData($fh))
      if $status == AZ_OK;
    if ($status == AZ_OK) {
        $self->{'wasWritten'} = 1;
        if ($self->hasDataDescriptor()) {
            $status = $self->_writeDataDescriptor($fh);
        } elsif ($headerFieldsUnknown) {
            $status = $self->_refreshLocalFileHeader($fh);
        }
    }

    return $status;
}

# Copy my (possibly compressed) data to given file handle.
# Returns C<AZ_OK> on success
sub _writeData {
    my $self    = shift;
    my $writeFh = shift;

# If symbolic link, just create one if the operating system is Linux, Unix, BSD or VMS
# TODO: Add checks for other operating systems
    if ($self->{'isSymbolicLink'} == 1 && $^O eq 'linux') {
        my $chunkSize = $Archive::Zip::ChunkSize;
        my ($outRef, $status) = $self->readChunk($chunkSize);
        symlink $$outRef, $self->{'newName'};
    } else {
        return AZ_OK if ($self->uncompressedSize() == 0);
        my $status;
        my $chunkSize = $Archive::Zip::ChunkSize;
        while ($self->_readDataRemaining() > 0) {
            my $outRef;
            ($outRef, $status) = $self->readChunk($chunkSize);
            return $status if ($status != AZ_OK and $status != AZ_STREAM_END);

            if (length($$outRef) > 0) {
                $self->_print($writeFh, $$outRef)
                  or return _ioError("write error during copy");
            }

            last if $status == AZ_STREAM_END;
        }
    }
    return AZ_OK;
}

# Return true if I depend on the named file
sub _usesFileNamed {
    return 0;
}

# ##############################################################################
#
# Decrypt section
#
# H.Merijn Brand (Tux) 2011-06-28
#
# ##############################################################################

# This code is derived from the crypt source of unzip-6.0 dated 05 Jan 2007
# Its license states:
#
# --8<---
# Copyright (c) 1990-2007 Info-ZIP.  All rights reserved.

# See the accompanying file LICENSE, version 2005-Feb-10 or later
# (the contents of which are also included in (un)zip.h) for terms of use.
# If, for some reason, all these files are missing, the Info-ZIP license
# also may be found at:  ftp://ftp.info-zip.org/pub/infozip/license.html
#
# crypt.c (full version) by Info-ZIP.      Last revised:  [see crypt.h]

# The main encryption/decryption source code for Info-Zip software was
# originally written in Europe.  To the best of our knowledge, it can
# be freely distributed in both source and object forms from any country,
# including the USA under License Exception TSU of the U.S. Export
# Administration Regulations (section 740.13(e)) of 6 June 2002.

# NOTE on copyright history:
# Previous versions of this source package (up to version 2.8) were
# not copyrighted and put in the public domain.  If you cannot comply
# with the Info-Zip LICENSE, you may want to look for one of those
# public domain versions.
#
# This encryption code is a direct transcription of the algorithm from
# Roger Schlafly, described by Phil Katz in the file appnote.txt.  This
# file (appnote.txt) is distributed with the PKZIP program (even in the
# version without encryption capabilities).
# -->8---

# As of January 2000, US export regulations were amended to allow export
# of free encryption source code from the US.  As of June 2002, these
# regulations were further relaxed to allow export of encryption binaries
# associated with free encryption source code.  The Zip 2.31, UnZip 5.52
# and Wiz 5.02 archives now include full crypto source code.  As of the
# Zip 2.31 release, all official binaries include encryption support; the
# former "zcr" archives ceased to exist.
# (Note that restrictions may still exist in other countries, of course.)

# For now, we just support the decrypt stuff
# All below methods are supposed to be private

# use Data::Peek;

my @keys;
my @crct = do {
    my $xor = 0xedb88320;
    my @crc = (0) x 1024;

    # generate a crc for every 8-bit value
    foreach my $n (0 .. 255) {
        my $c = $n;
        $c = $c & 1 ? $xor ^ ($c >> 1) : $c >> 1 for 1 .. 8;
        $crc[$n] = _revbe($c);
    }

    # generate crc for each value followed by one, two, and three zeros */
    foreach my $n (0 .. 255) {
        my $c = ($crc[($crc[$n] >> 24) ^ 0] ^ ($crc[$n] << 8)) & 0xffffffff;
        $crc[$_ * 256 + $n] = $c for 1 .. 3;
    }
    map { _revbe($crc[$_]) } 0 .. 1023;
};

sub _crc32 {
    my ($c, $b) = @_;
    return ($crct[($c ^ $b) & 0xff] ^ ($c >> 8));
}    # _crc32

sub _revbe {
    my $w = shift;
    return (($w >> 24) +
          (($w >> 8) & 0xff00) +
          (($w & 0xff00) << 8) +
          (($w & 0xff) << 24));
}    # _revbe

sub _update_keys {
    use integer;
    my $c = shift;    # signed int
    $keys[0] = _crc32($keys[0], $c);
    $keys[1] = (($keys[1] + ($keys[0] & 0xff)) * 0x08088405 + 1) & 0xffffffff;
    my $keyshift = $keys[1] >> 24;
    $keys[2] = _crc32($keys[2], $keyshift);
}    # _update_keys

sub _zdecode ($) {
    my $c = shift;
    my $t = ($keys[2] & 0xffff) | 2;
    _update_keys($c ^= ((($t * ($t ^ 1)) >> 8) & 0xff));
    return $c;
}    # _zdecode

sub _decode {
    my $self = shift;
    my $buff = shift;

    $self->isEncrypted or return $buff;

    my $pass = $self->password;
    defined $pass or return "";

    @keys = (0x12345678, 0x23456789, 0x34567890);
    _update_keys($_) for unpack "C*", $pass;

    # DDumper { uk => [ @keys ] };

    my $head = substr $buff, 0, 12, "";
    my @head = map { _zdecode($_) } unpack "C*", $head;
    my $x =
      $self->{externalFileAttributes}
      ? ($self->{lastModFileDateTime} >> 8) & 0xff
      : $self->{crc32} >> 24;
    $head[-1] == $x or return "";    # Password fail

    # Worth checking ...
    $self->{crc32c} = (unpack LOCAL_FILE_HEADER_FORMAT, pack "C*", @head)[3];

    # DHexDump ($buff);
    $buff = pack "C*" => map { _zdecode($_) } unpack "C*" => $buff;

    # DHexDump ($buff);
    return $buff;
}    # _decode

1;
FILE   %75149ec8/Archive/Zip/NewFileMember.pm  �#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/NewFileMember.pm"
package Archive::Zip::NewFileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw ( Archive::Zip::FileMember );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :UTILITY_METHODS
);

# Given a file name, set up for eventual writing.
sub _newFromFileNamed {
    my $class    = shift;
    my $fileName = shift;    # local FS format
    my $newName  = shift;
    $newName = _asZipDirName($fileName) unless defined($newName);
    return undef unless (stat($fileName) && -r _ && !-d _ );
    my $self = $class->new(@_);
    $self->{'fileName'}          = $newName;
    $self->{'externalFileName'}  = $fileName;
    $self->{'compressionMethod'} = COMPRESSION_STORED;
    my @stat = stat(_);
    $self->{'compressedSize'} = $self->{'uncompressedSize'} = $stat[7];
    $self->desiredCompressionMethod(
        ($self->compressedSize() > 0)
        ? COMPRESSION_DEFLATED
        : COMPRESSION_STORED
    );
    $self->unixFileAttributes($stat[2]);
    $self->setLastModFileDateTimeFromUnix($stat[9]);
    $self->isTextFile(-T _ );
    return $self;
}

sub rewindData {
    my $self = shift;

    my $status = $self->SUPER::rewindData(@_);
    return $status unless $status == AZ_OK;

    return AZ_IO_ERROR unless $self->fh();
    $self->fh()->clearerr();
    $self->fh()->seek(0, IO::Seekable::SEEK_SET)
      or return _ioError("rewinding", $self->externalFileName());
    return AZ_OK;
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ($self, $dataRef, $chunkSize) = @_;
    return (0, AZ_OK) unless $chunkSize;
    my $bytesRead = $self->fh()->read($$dataRef, $chunkSize)
      or return (0, _ioError("reading data"));
    return ($bytesRead, AZ_OK);
}

# If I already exist, extraction is a no-op.
sub extractToFileNamed {
    my $self = shift;
    my $name = shift;    # local FS name
    if (File::Spec->rel2abs($name) eq
        File::Spec->rel2abs($self->externalFileName()) and -r $name) {
        return AZ_OK;
    } else {
        return $self->SUPER::extractToFileNamed($name, @_);
    }
}

1;
FILE   $c4d1dd6c/Archive/Zip/StringMember.pm  �#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/StringMember.pm"
package Archive::Zip::StringMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw( Archive::Zip::Member );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
);

# Create a new string member. Default is COMPRESSION_STORED.
# Can take a ref to a string as well.
sub _newFromString {
    my $class  = shift;
    my $string = shift;
    my $name   = shift;
    my $self   = $class->new(@_);
    $self->contents($string);
    $self->fileName($name) if defined($name);

    # Set the file date to now
    $self->setLastModFileDateTimeFromUnix(time());
    $self->unixFileAttributes($self->DEFAULT_FILE_PERMISSIONS);
    return $self;
}

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;
    delete($self->{'contents'});
    return $self->SUPER::_become($newClass);
}

# Get or set my contents. Note that we do not call the superclass
# version of this, because it calls us.
sub contents {
    my $self   = shift;
    my $string = shift;
    if (defined($string)) {
        $self->{'contents'} =
          pack('C0a*', (ref($string) eq 'SCALAR') ? $$string : $string);
        $self->{'uncompressedSize'} = $self->{'compressedSize'} =
          length($self->{'contents'});
        $self->{'compressionMethod'} = COMPRESSION_STORED;
    }
    return $self->{'contents'};
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ($self, $dataRef, $chunkSize) = @_;
    $$dataRef = substr($self->contents(), $self->_readOffset(), $chunkSize);
    return (length($$dataRef), AZ_OK);
}

1;
FILE   %ab693487/Archive/Zip/ZipFileMember.pm  6#line 1 "/home/pmarup/perl5/lib/perl5/Archive/Zip/ZipFileMember.pm"
package Archive::Zip::ZipFileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.50';
    @ISA     = qw ( Archive::Zip::FileMember );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

# Create a new Archive::Zip::ZipFileMember
# given a filename and optional open file handle
#
sub _newFromZipFile {
    my $class              = shift;
    my $fh                 = shift;
    my $externalFileName   = shift;
    my $possibleEocdOffset = shift;    # normally 0

    my $self = $class->new(
        'crc32'                     => 0,
        'diskNumberStart'           => 0,
        'localHeaderRelativeOffset' => 0,
        'dataOffset' => 0,    # localHeaderRelativeOffset + header length
        @_
    );
    $self->{'externalFileName'}   = $externalFileName;
    $self->{'fh'}                 = $fh;
    $self->{'possibleEocdOffset'} = $possibleEocdOffset;
    return $self;
}

sub isDirectory {
    my $self = shift;
    return (substr($self->fileName, -1, 1) eq '/'
          and $self->uncompressedSize == 0);
}

# Seek to the beginning of the local header, just past the signature.
# Verify that the local header signature is in fact correct.
# Update the localHeaderRelativeOffset if necessary by adding the possibleEocdOffset.
# Returns status.

sub _seekToLocalHeader {
    my $self          = shift;
    my $where         = shift;    # optional
    my $previousWhere = shift;    # optional

    $where = $self->localHeaderRelativeOffset() unless defined($where);

    # avoid loop on certain corrupt files (from Julian Field)
    return _formatError("corrupt zip file")
      if defined($previousWhere) && $where == $previousWhere;

    my $status;
    my $signature;

    $status = $self->fh()->seek($where, IO::Seekable::SEEK_SET);
    return _ioError("seeking to local header") unless $status;

    ($status, $signature) =
      _readSignature($self->fh(), $self->externalFileName(),
        LOCAL_FILE_HEADER_SIGNATURE);
    return $status if $status == AZ_IO_ERROR;

    # retry with EOCD offset if any was given.
    if ($status == AZ_FORMAT_ERROR && $self->{'possibleEocdOffset'}) {
        $status = $self->_seekToLocalHeader(
            $self->localHeaderRelativeOffset() + $self->{'possibleEocdOffset'},
            $where
        );
        if ($status == AZ_OK) {
            $self->{'localHeaderRelativeOffset'} +=
              $self->{'possibleEocdOffset'};
            $self->{'possibleEocdOffset'} = 0;
        }
    }

    return $status;
}

# Because I'm going to delete the file handle, read the local file
# header if the file handle is seekable. If it is not, I assume that
# I've already read the local header.
# Return ( $status, $self )

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;

    my $status = AZ_OK;

    if (_isSeekable($self->fh())) {
        my $here = $self->fh()->tell();
        $status = $self->_seekToLocalHeader();
        $status = $self->_readLocalFileHeader() if $status == AZ_OK;
        $self->fh()->seek($here, IO::Seekable::SEEK_SET);
        return $status unless $status == AZ_OK;
    }

    delete($self->{'eocdCrc32'});
    delete($self->{'diskNumberStart'});
    delete($self->{'localHeaderRelativeOffset'});
    delete($self->{'dataOffset'});

    return $self->SUPER::_become($newClass);
}

sub diskNumberStart {
    shift->{'diskNumberStart'};
}

sub localHeaderRelativeOffset {
    shift->{'localHeaderRelativeOffset'};
}

sub dataOffset {
    shift->{'dataOffset'};
}

# Skip local file header, updating only extra field stuff.
# Assumes that fh is positioned before signature.
sub _skipLocalFileHeader {
    my $self = shift;
    my $header;
    my $bytesRead = $self->fh()->read($header, LOCAL_FILE_HEADER_LENGTH);
    if ($bytesRead != LOCAL_FILE_HEADER_LENGTH) {
        return _ioError("reading local file header");
    }
    my $fileNameLength;
    my $extraFieldLength;
    my $bitFlag;
    (
        undef,    # $self->{'versionNeededToExtract'},
        $bitFlag,
        undef,    # $self->{'compressionMethod'},
        undef,    # $self->{'lastModFileDateTime'},
        undef,    # $crc32,
        undef,    # $compressedSize,
        undef,    # $uncompressedSize,
        $fileNameLength,
        $extraFieldLength
    ) = unpack(LOCAL_FILE_HEADER_FORMAT, $header);

    if ($fileNameLength) {
        $self->fh()->seek($fileNameLength, IO::Seekable::SEEK_CUR)
          or return _ioError("skipping local file name");
    }

    if ($extraFieldLength) {
        $bytesRead =
          $self->fh()->read($self->{'localExtraField'}, $extraFieldLength);
        if ($bytesRead != $extraFieldLength) {
            return _ioError("reading local extra field");
        }
    }

    $self->{'dataOffset'} = $self->fh()->tell();

    if ($bitFlag & GPBF_HAS_DATA_DESCRIPTOR_MASK) {

        # Read the crc32, compressedSize, and uncompressedSize from the
        # extended data descriptor, which directly follows the compressed data.
        #
        # Skip over the compressed file data (assumes that EOCD compressedSize
        # was correct)
        $self->fh()->seek($self->{'compressedSize'}, IO::Seekable::SEEK_CUR)
          or return _ioError("seeking to extended local header");

        # these values should be set correctly from before.
        my $oldCrc32            = $self->{'eocdCrc32'};
        my $oldCompressedSize   = $self->{'compressedSize'};
        my $oldUncompressedSize = $self->{'uncompressedSize'};

        my $status = $self->_readDataDescriptor();
        return $status unless $status == AZ_OK;

        # The buffer withe encrypted data is prefixed with a new
        # encrypted 12 byte header. The size only changes when
        # the buffer is also compressed
        $self->isEncrypted && $oldUncompressedSize > $self->{uncompressedSize}
          and $oldUncompressedSize -= DATA_DESCRIPTOR_LENGTH;

        return _formatError(
            "CRC or size mismatch while skipping data descriptor")
          if ( $oldCrc32 != $self->{'crc32'}
            || $oldUncompressedSize != $self->{'uncompressedSize'});

        $self->{'crc32'} = 0 
            if $self->compressionMethod() == COMPRESSION_STORED ; 
    }

    return AZ_OK;
}

# Read from a local file header into myself. Returns AZ_OK if successful.
# Assumes that fh is positioned after signature.
# Note that crc32, compressedSize, and uncompressedSize will be 0 if
# GPBF_HAS_DATA_DESCRIPTOR_MASK is set in the bitFlag.

sub _readLocalFileHeader {
    my $self = shift;
    my $header;
    my $bytesRead = $self->fh()->read($header, LOCAL_FILE_HEADER_LENGTH);
    if ($bytesRead != LOCAL_FILE_HEADER_LENGTH) {
        return _ioError("reading local file header");
    }
    my $fileNameLength;
    my $crc32;
    my $compressedSize;
    my $uncompressedSize;
    my $extraFieldLength;
    (
        $self->{'versionNeededToExtract'}, $self->{'bitFlag'},
        $self->{'compressionMethod'},      $self->{'lastModFileDateTime'},
        $crc32,                            $compressedSize,
        $uncompressedSize,                 $fileNameLength,
        $extraFieldLength
    ) = unpack(LOCAL_FILE_HEADER_FORMAT, $header);

    if ($fileNameLength) {
        my $fileName;
        $bytesRead = $self->fh()->read($fileName, $fileNameLength);
        if ($bytesRead != $fileNameLength) {
            return _ioError("reading local file name");
        }
        $self->fileName($fileName);
    }

    if ($extraFieldLength) {
        $bytesRead =
          $self->fh()->read($self->{'localExtraField'}, $extraFieldLength);
        if ($bytesRead != $extraFieldLength) {
            return _ioError("reading local extra field");
        }
    }

    $self->{'dataOffset'} = $self->fh()->tell();

    if ($self->hasDataDescriptor()) {

        # Read the crc32, compressedSize, and uncompressedSize from the
        # extended data descriptor.
        # Skip over the compressed file data (assumes that EOCD compressedSize
        # was correct)
        $self->fh()->seek($self->{'compressedSize'}, IO::Seekable::SEEK_CUR)
          or return _ioError("seeking to extended local header");

        my $status = $self->_readDataDescriptor();
        return $status unless $status == AZ_OK;
    } else {
        return _formatError(
            "CRC or size mismatch after reading data descriptor")
          if ( $self->{'crc32'} != $crc32
            || $self->{'uncompressedSize'} != $uncompressedSize);
    }

    return AZ_OK;
}

# This will read the data descriptor, which is after the end of compressed file
# data in members that have GPBF_HAS_DATA_DESCRIPTOR_MASK set in their bitFlag.
# The only reliable way to find these is to rely on the EOCD compressedSize.
# Assumes that file is positioned immediately after the compressed data.
# Returns status; sets crc32, compressedSize, and uncompressedSize.
sub _readDataDescriptor {
    my $self = shift;
    my $signatureData;
    my $header;
    my $crc32;
    my $compressedSize;
    my $uncompressedSize;

    my $bytesRead = $self->fh()->read($signatureData, SIGNATURE_LENGTH);
    return _ioError("reading header signature")
      if $bytesRead != SIGNATURE_LENGTH;
    my $signature = unpack(SIGNATURE_FORMAT, $signatureData);

    # unfortunately, the signature appears to be optional.
    if ($signature == DATA_DESCRIPTOR_SIGNATURE
        && ($signature != $self->{'crc32'})) {
        $bytesRead = $self->fh()->read($header, DATA_DESCRIPTOR_LENGTH);
        return _ioError("reading data descriptor")
          if $bytesRead != DATA_DESCRIPTOR_LENGTH;

        ($crc32, $compressedSize, $uncompressedSize) =
          unpack(DATA_DESCRIPTOR_FORMAT, $header);
    } else {
        $bytesRead = $self->fh()->read($header, DATA_DESCRIPTOR_LENGTH_NO_SIG);
        return _ioError("reading data descriptor")
          if $bytesRead != DATA_DESCRIPTOR_LENGTH_NO_SIG;

        $crc32 = $signature;
        ($compressedSize, $uncompressedSize) =
          unpack(DATA_DESCRIPTOR_FORMAT_NO_SIG, $header);
    }

    $self->{'eocdCrc32'} = $self->{'crc32'}
      unless defined($self->{'eocdCrc32'});
    $self->{'crc32'}            = $crc32;
    $self->{'compressedSize'}   = $compressedSize;
    $self->{'uncompressedSize'} = $uncompressedSize;

    return AZ_OK;
}

# Read a Central Directory header. Return AZ_OK on success.
# Assumes that fh is positioned right after the signature.

sub _readCentralDirectoryFileHeader {
    my $self      = shift;
    my $fh        = $self->fh();
    my $header    = '';
    my $bytesRead = $fh->read($header, CENTRAL_DIRECTORY_FILE_HEADER_LENGTH);
    if ($bytesRead != CENTRAL_DIRECTORY_FILE_HEADER_LENGTH) {
        return _ioError("reading central dir header");
    }
    my ($fileNameLength, $extraFieldLength, $fileCommentLength);
    (
        $self->{'versionMadeBy'},
        $self->{'fileAttributeFormat'},
        $self->{'versionNeededToExtract'},
        $self->{'bitFlag'},
        $self->{'compressionMethod'},
        $self->{'lastModFileDateTime'},
        $self->{'crc32'},
        $self->{'compressedSize'},
        $self->{'uncompressedSize'},
        $fileNameLength,
        $extraFieldLength,
        $fileCommentLength,
        $self->{'diskNumberStart'},
        $self->{'internalFileAttributes'},
        $self->{'externalFileAttributes'},
        $self->{'localHeaderRelativeOffset'}
    ) = unpack(CENTRAL_DIRECTORY_FILE_HEADER_FORMAT, $header);

    $self->{'eocdCrc32'} = $self->{'crc32'};

    if ($fileNameLength) {
        $bytesRead = $fh->read($self->{'fileName'}, $fileNameLength);
        if ($bytesRead != $fileNameLength) {
            _ioError("reading central dir filename");
        }
    }
    if ($extraFieldLength) {
        $bytesRead = $fh->read($self->{'cdExtraField'}, $extraFieldLength);
        if ($bytesRead != $extraFieldLength) {
            return _ioError("reading central dir extra field");
        }
    }
    if ($fileCommentLength) {
        $bytesRead = $fh->read($self->{'fileComment'}, $fileCommentLength);
        if ($bytesRead != $fileCommentLength) {
            return _ioError("reading central dir file comment");
        }
    }

    # NK 10/21/04: added to avoid problems with manipulated headers
    if (    $self->{'uncompressedSize'} != $self->{'compressedSize'}
        and $self->{'compressionMethod'} == COMPRESSION_STORED) {
        $self->{'uncompressedSize'} = $self->{'compressedSize'};
    }

    $self->desiredCompressionMethod($self->compressionMethod());

    return AZ_OK;
}

sub rewindData {
    my $self = shift;

    my $status = $self->SUPER::rewindData(@_);
    return $status unless $status == AZ_OK;

    return AZ_IO_ERROR unless $self->fh();

    $self->fh()->clearerr();

    # Seek to local file header.
    # The only reason that I'm doing this this way is that the extraField
    # length seems to be different between the CD header and the LF header.
    $status = $self->_seekToLocalHeader();
    return $status unless $status == AZ_OK;

    # skip local file header
    $status = $self->_skipLocalFileHeader();
    return $status unless $status == AZ_OK;

    # Seek to beginning of file data
    $self->fh()->seek($self->dataOffset(), IO::Seekable::SEEK_SET)
      or return _ioError("seeking to beginning of file data");

    return AZ_OK;
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ($self, $dataRef, $chunkSize) = @_;
    return (0, AZ_OK) unless $chunkSize;
    my $bytesRead = $self->fh()->read($$dataRef, $chunkSize)
      or return (0, _ioError("reading data"));
    return ($bytesRead, AZ_OK);
}

1;
FILE   a1983624/PAR.pm  p�#line 1 "/home/pmarup/perl5/lib/perl5/PAR.pm"
package PAR;
$PAR::VERSION = '1.010';

use 5.006;
use strict;
use warnings;
use Config '%Config';
use Carp qw/croak/;

# If the 'prefork' module is available, we
# register various run-time loaded modules with it.
# That way, there is more shared memory in a forking
# environment.
BEGIN {
    if (eval 'require prefork') {
        prefork->import($_) for qw/
            Archive::Zip
            File::Glob
            File::Spec
            File::Temp
            LWP::Simple
            PAR::Heavy
        /;
        # not including Archive::Unzip::Burst which only makes sense
        # in the context of a PAR::Packer'ed executable anyway.
    }
}

use PAR::SetupProgname;
use PAR::SetupTemp;

#line 311

use vars qw(@PAR_INC);              # explicitly stated PAR library files (preferred)
use vars qw(@PAR_INC_LAST);         # explicitly stated PAR library files (fallback)
use vars qw(%PAR_INC);              # sets {$par}{$file} for require'd modules
use vars qw(@LibCache %LibCache);   # I really miss pseudohash.
use vars qw($LastAccessedPAR $LastTempFile);
use vars qw(@RepositoryObjects);    # If we have PAR::Repository::Client support, we
                                    # put the ::Client objects in here.
use vars qw(@PriorityRepositoryObjects); # repositories which are preferred over local stuff
use vars qw(@UpgradeRepositoryObjects);  # If we have PAR::Repository::Client's in upgrade mode
                                         # put the ::Client objects in here *as well*.
use vars qw(%FileCache);            # The Zip-file file-name-cache
                                    # Layout:
                                    # $FileCache{$ZipObj}{$FileName} = $Member
use vars qw(%ArchivesExtracted);    # Associates archive-zip-object => full extraction path

my $ver  = $Config{version};
my $arch = $Config{archname};
my $progname = $ENV{PAR_PROGNAME} || $0;
my $is_insensitive_fs = (
    -s $progname
        and (-s lc($progname) || -1) == (-s uc($progname) || -1)
        and (-s lc($progname) || -1) == -s $progname
);

# lexical for import(), and _import_foo() functions to control unpar()
my %unpar_options;

# called on "use PAR"
sub import {
    my $class = shift;

    PAR::SetupProgname::set_progname();
    PAR::SetupTemp::set_par_temp_env();

    $progname = $ENV{PAR_PROGNAME} ||= $0;
    $is_insensitive_fs = (-s $progname and (-s lc($progname) || -1) == (-s uc($progname) || -1));

    my @args = @_;
    
    # Insert PAR hook in @INC.
    unshift @INC, \&find_par   unless grep { $_ eq \&find_par }      @INC;
    push @INC, \&find_par_last unless grep { $_ eq \&find_par_last } @INC;

    # process args to use PAR 'foo.par', { opts }, ...;
    foreach my $par (@args) {
        if (ref($par) eq 'HASH') {
            # we have been passed a hash reference
            _import_hash_ref($par);
        }
        elsif ($par =~ /[?*{}\[\]]/) {
           # implement globbing for PAR archives
           require File::Glob;
           foreach my $matched (File::Glob::glob($par)) {
               push @PAR_INC, unpar($matched, undef, undef, 1);
           }
        }
        else {
            # ordinary string argument => file
            push @PAR_INC, unpar($par, undef, undef, 1);
        }
    }

    return if $PAR::__import;
    local $PAR::__import = 1;

    require PAR::Heavy;
    PAR::Heavy::_init_dynaloader();

    # The following code is executed for the case where the
    # running program is itself a PAR archive.
    # ==> run script/main.pl
    if (unpar($progname)) {
        # XXX - handle META.yml here!
        push @PAR_INC, unpar($progname, undef, undef, 1);

        _extract_inc($progname);
        if ($LibCache{$progname}) {
          # XXX bad: this us just a good guess
          require File::Spec;
          $ArchivesExtracted{$progname} = File::Spec->catdir($ENV{PAR_TEMP}, 'inc');
        }

        my $zip = $LibCache{$progname};
        my $member = _first_member( $zip,
            "script/main.pl",
            "main.pl",
        );

        if ($progname and !$member) {
            require File::Spec;
            my @path = File::Spec->splitdir($progname);
            my $filename = pop @path;
            $member = _first_member( $zip,
                "script/".$filename,
                "script/".$filename.".pl",
                $filename,
                $filename.".pl",
            )
        }

        # finally take $ARGV[0] as the hint for file to run
        if (defined $ARGV[0] and !$member) {
            $member = _first_member( $zip,
                "script/$ARGV[0]",
                "script/$ARGV[0].pl",
                $ARGV[0],
                "$ARGV[0].pl",
            ) or die qq(PAR.pm: Can't open perl script "$ARGV[0]": No such file or directory);
            shift @ARGV;
        }


        if (!$member) {
            die "Usage: $0 script_file_name.\n";
        }

        _run_member($member);
    }
}


# import() helper for the "use PAR {...};" syntax.
sub _import_hash_ref {
    my $opt = shift;

    # hash slice assignment -- pass all of the options into unpar
    local @unpar_options{keys(%$opt)} = values(%$opt);

    # check for incompatible options:
    if ( exists $opt->{repository} and exists $opt->{file} ) {
        croak("Invalid PAR loading options. Cannot have a 'repository' and 'file' option at the same time.");
    }
    elsif (
        exists $opt->{file}
        and (exists $opt->{install} or exists $opt->{upgrade})
    ) {
        my $e = exists($opt->{install}) ? 'install' : 'upgrade';
        croak("Invalid PAR loading options. Cannot combine 'file' and '$e' options.");
    }
    elsif ( not exists $opt->{repository} and not exists $opt->{file} ) {
        croak("Invalid PAR loading options. Need at least one of 'file' or 'repository' options.");
    }

    # load from file
    if (exists $opt->{file}) {
        croak("Cannot load undefined PAR archive")
          if not defined $opt->{file};

        # for files, we default to loading from PAR archive first
        my $fallback = $opt->{fallback};
        $fallback = 0 if not defined $fallback;
        
        if (not $fallback) {
            # load from this PAR arch preferably
            push @PAR_INC, unpar($opt->{file}, undef, undef, 1);
        }
        else {
            # load from this PAR arch as fallback
            push @PAR_INC_LAST, unpar($opt->{file}, undef, undef, 1);
        }
        
    }
    else {
        # Deal with repositories elsewhere
        my $client = _import_repository($opt);
        return() if not $client;

        if (defined $opt->{run}) {
            # run was specified
            # run the specified script from the repository
            $client->run_script( $opt->{run} );
            return 1;
        }
        
        return 1;
    }

    # run was specified
    # run the specified script from inside the PAR file.
    if (defined $opt->{run}) {
        my $script = $opt->{run};
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        
        # XXX - handle META.yml here!
        _extract_inc($opt->{file});
        
        my $zip = $LibCache{$opt->{file}};
        my $member = _first_member( $zip,
            (($script !~ /^script\//) ? ("script/$script", "script/$script.pl") : ()),
            $script,
            "$script.pl",
        );
        
        if (not defined $member) {
            croak("Cannot run script '$script' from PAR file '$opt->{file}'. Script couldn't be found in PAR file.");
        }
        
        _run_member_from_par($member);
    }

    return();
}


# This sub is invoked by _import_hash_ref if a {repository}
# option is found
# Returns the repository client object on success.
sub _import_repository {
    my $opt = shift;
    my $url = $opt->{repository};

    eval "require PAR::Repository::Client; 1;";
    if ($@ or not eval PAR::Repository::Client->VERSION >= 0.04) {
        croak "In order to use the 'use PAR { repository => 'url' };' syntax, you need to install the PAR::Repository::Client module (version 0.04 or later) from CPAN. This module does not seem to be installed as indicated by the following error message: $@";
    }
    
    if ($opt->{upgrade} and not eval PAR::Repository::Client->VERSION >= 0.22) {
        croak "In order to use the 'upgrade' option, you need to install the PAR::Repository::Client module (version 0.22 or later) from CPAN";
    }

    if ($opt->{dependencies} and not eval PAR::Repository::Client->VERSION >= 0.23) {
        croak "In order to use the 'dependencies' option, you need to install the PAR::Repository::Client module (version 0.23 or later) from CPAN";
    }

    my $obj;

    # Support existing clients passed in as objects.
    if (ref($url) and UNIVERSAL::isa($url, 'PAR::Repository::Client')) {
        $obj = $url;
    }
    else {
        $obj = PAR::Repository::Client->new(
            uri                 => $url,
            auto_install        => $opt->{install},
            auto_upgrade        => $opt->{upgrade},
            static_dependencies => $opt->{dependencies},
        );
    }

    if (exists($opt->{fallback}) and not $opt->{fallback}) {
        unshift @PriorityRepositoryObjects, $obj; # repository beats local stuff
    } else {
        push @RepositoryObjects, $obj; # local stuff beats repository
    }
    # these are tracked separately so we can check for upgrades early
    push @UpgradeRepositoryObjects, $obj if $opt->{upgrade};

    return $obj;
}

# Given an Archive::Zip obj and a list of files/paths,
# this function returns the Archive::Zip::Member for the
# first of the files found in the ZIP. If none is found,
# returns the empty list.
sub _first_member {
    my $zip = shift;
    foreach my $name (@_) {
        my $member = _cached_member_named($zip, $name);
        return $member if $member;
    }
    return;
}

# Given an Archive::Zip object, this finds the first 
# Archive::Zip member whose file name matches the
# regular expression
sub _first_member_matching {
    my $zip = shift;
    my $regex = shift;

    my $cache = $FileCache{$zip};
    $cache = $FileCache{$zip} = _make_file_cache($zip) if not $cache;

    foreach my $name (keys %$cache) {
      if ($name =~ $regex) {
        return $cache->{$name};
      }
    }

    return();
}


sub _run_member_from_par {
    my $member = shift;
    my $clear_stack = shift;
    my ($fh, $is_new, $filename) = _tempfile($member->crc32String . ".pl");

    if ($is_new) {
        my $file = $member->fileName;
        print $fh "package main;\n";
        print $fh "#line 1 \"$file\"\n";
        $member->extractToFileHandle($fh);
        seek ($fh, 0, 0);
    }

    $ENV{PAR_0} = $filename; # for Pod::Usage
    { do $filename;
      CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
      die $@ if $@;
      exit;
    }
}

sub _run_member {
    my $member = shift;
    my $clear_stack = shift;
    my ($fh, $is_new, $filename) = _tempfile($member->crc32String . ".pl");

    if ($is_new) {
        my $file = $member->fileName;
        print $fh "package main;\n";
        if (defined &Internals::PAR::CLEARSTACK and $clear_stack) {
            print $fh "Internals::PAR::CLEARSTACK();\n";
        }
        print $fh "#line 1 \"$file\"\n";
        $member->extractToFileHandle($fh);
        seek ($fh, 0, 0);
    }

    unshift @INC, sub { shift @INC; return $fh };

    $ENV{PAR_0} = $filename; # for Pod::Usage
    { do 'main';
      CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
      die $@ if $@;
      exit;
    }
}

sub _run_external_file {
    my $filename = shift;
    my $clear_stack = shift;
    require 5.008;
    open my $ffh, '<', $filename
      or die "Can't open perl script \"$filename\": $!";

    my $clearstack = '';
    if (defined &Internals::PAR::CLEARSTACK and $clear_stack) {
        $clear_stack = "Internals::PAR::CLEARSTACK();\n";
    }
    my $string = "package main;\n$clearstack#line 1 \"$filename\"\n"
                 . do { local $/ = undef; <$ffh> };
    close $ffh;

    open my $fh, '<', \$string
      or die "Can't open file handle to string: $!";

    unshift @INC, sub { shift @INC; return $fh };

    $ENV{PAR_0} = $filename; # for Pod::Usage
    { do 'main';
      CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
      die $@ if $@;
      exit;
    }
}

# extract the contents of a .par (or .exe) or any
# Archive::Zip handle to the PAR_TEMP/inc directory.
# returns that directory.
sub _extract_inc {
    my $file_or_azip_handle = shift;
    my $dlext = defined($Config{dlext}) ? $Config::Config{dlext} : '';
    my $is_handle = ref($file_or_azip_handle) && $file_or_azip_handle->isa('Archive::Zip::Archive');

    require File::Spec;
    my $inc = File::Spec->catdir($PAR::SetupTemp::PARTemp, "inc");
    my $canary = File::Spec->catfile($PAR::SetupTemp::PARTemp, $PAR::SetupTemp::Canary);

    if (!-d $inc || !-e $canary) {
        for (1 .. 10) { mkdir("$inc.lock", 0755) and last; sleep 1 }
        
        undef $@;
        if (!$is_handle) {
          # First try to unzip the *fast* way.
          eval {
            require Archive::Unzip::Burst;
            Archive::Unzip::Burst::unzip($file_or_azip_handle, $inc)
              and die "Could not unzip '$file_or_azip_handle' into '$inc'. Error: $!";
              die;
          };

          # This means the fast module is there, but didn't work.
          if ($@ =~ /^Could not unzip/) {
            die $@;
          }
        }

        # either failed to load Archive::Unzip::Burst or got an A::Zip handle
        # fallback to slow way.
        if ($is_handle || $@) {
          my $zip;
          if (!$is_handle) {
            open my $fh, '<', $file_or_azip_handle
              or die "Cannot find '$file_or_azip_handle': $!";
            binmode($fh);
            bless($fh, 'IO::File');

            $zip = Archive::Zip->new;
            ( $zip->readFromFileHandle($fh, $file_or_azip_handle) == Archive::Zip::AZ_OK() )
                or die "Read '$file_or_azip_handle' error: $!";
          }
          else {
            $zip = $file_or_azip_handle;
          }

          mkdir($inc) if not -d $inc;

          for ( $zip->memberNames() ) {
              s{^/}{};
              my $outfile =  File::Spec->catfile($inc, $_);
              next if -e $outfile and not -w _;
              $zip->extractMember($_, $outfile);
              # Unfortunately Archive::Zip doesn't have an option
              # NOT to restore member timestamps when extracting, hence set 
              # it to "now" (making it younger than the canary file).
              utime(undef, undef, $outfile);
          }
        }
        
        # touch (and back-date) canary file
        open my $fh, ">", $canary; 
        close $fh;
        my $dateback = time() - $PAR::SetupTemp::CanaryDateBack;
        utime($dateback, $dateback, $canary);

        rmdir("$inc.lock");

        $ArchivesExtracted{$is_handle ? $file_or_azip_handle->fileName() : $file_or_azip_handle} = $inc;
    }

    # add the freshly extracted directories to @INC,
    # but make sure there's no duplicates
    my %inc_exists = map { ($_, 1) } @INC;
    unshift @INC, grep !exists($inc_exists{$_}),
                  grep -d,
                  map File::Spec->catdir($inc, @$_),
                  [ 'lib' ], [ 'arch' ], [ $arch ],
                  [ $ver ], [ $ver, $arch ], [];

    return $inc;
}


# This is the hook placed in @INC for loading PAR's
# before any other stuff in @INC
sub find_par {
    my @args = @_;

    # if there are repositories in upgrade mode, check them
    # first. If so, this is expensive, of course!
    if (@UpgradeRepositoryObjects) {
        my $module = $args[1];
        $module =~ s/\.pm$//;
        $module =~ s/\//::/g;
        foreach my $client (@UpgradeRepositoryObjects) {
            my $local_file = $client->upgrade_module($module);

            # break the require if upgrade_module has been required already
            # to avoid infinite recursion
            if (exists $INC{$args[1]}) {
                # Oh dear. Check for the possible return values of the INC sub hooks in
                # perldoc -f require before trying to understand this.
                # Then, realize that if you pass undef for the file handle, perl (5.8.9)
                # does NOT use the subroutine. Thus the hacky GLOB ref.
                my $line = 1;
                no warnings;
                return (\*I_AM_NOT_HERE, sub {$line ? ($_="1;",$line=0,return(1)) : ($_="",return(0))});
            }

            # Note: This is likely not necessary as the module has been installed
            # into the system by upgrade_module if it was available at all.
            # If it was already loaded, this will not be reached (see return right above).
            # If it could not be loaded from the system and neither found in the repository,
            # we simply want to have the normal error message, too!
            #
            #if ($local_file) {
            #    # XXX load with fallback - is that right?
            #    return _find_par_internals([$PAR_INC_LAST[-1]], @args);
            #}
        }
    }
    my $rv = _find_par_internals(\@PAR_INC, @args);

    return $rv if defined $rv or not @PriorityRepositoryObjects;

    # the repositories that are preferred over locally installed modules
    my $module = $args[1];
    $module =~ s/\.pm$//;
    $module =~ s/\//::/g;
    foreach my $client (@PriorityRepositoryObjects) {
        my $local_file = $client->get_module($module, 0); # 1 == fallback
        if ($local_file) {
            # Not loaded as fallback (cf. PRIORITY) thus look at PAR_INC
            # instead of PAR_INC_LAST
            return _find_par_internals([$PAR_INC[-1]], @args);
        }
    }
    return();
}

# This is the hook placed in @INC for loading PAR's
# AFTER any other stuff in @INC
# It also deals with loading from repositories as a
# fallback-fallback ;)
sub find_par_last {
    my @args = @_;
    # Try the local PAR files first
    my $rv = _find_par_internals(\@PAR_INC_LAST, @args);
    return $rv if defined $rv;

    # No repositories => return
    return $rv if not @RepositoryObjects;

    my $module = $args[1];
    $module =~ s/\.pm$//;
    $module =~ s/\//::/g;
    foreach my $client (@RepositoryObjects) {
        my $local_file = $client->get_module($module, 1); # 1 == fallback
        if ($local_file) {
            # Loaded as fallback thus look at PAR_INC_LAST
            return _find_par_internals([$PAR_INC_LAST[-1]], @args);
        }
    }
    return $rv;
}


# This routine implements loading modules from PARs
# both for loading PARs preferably or as fallback.
# To distinguish the cases, the first parameter should
# be a reference to the corresponding @PAR_INC* array.
sub _find_par_internals {
    my ($INC_ARY, $self, $file, $member_only) = @_;

    my $scheme;
    foreach (@$INC_ARY ? @$INC_ARY : @INC) {
        my $path = $_;
        if ($] < 5.008001) {
            # reassemble from "perl -Ischeme://path" autosplitting
            $path = "$scheme:$path" if !@$INC_ARY
                and $path and $path =~ m!//!
                and $scheme and $scheme =~ /^\w+$/;
            $scheme = $path;
        }
        my $rv = unpar($path, $file, $member_only, 1) or next;
        $PAR_INC{$path}{$file} = 1;
        $INC{$file} = $LastTempFile if (lc($file) =~ /^(?!tk).*\.pm$/);
        return $rv;
    }

    return;
}

sub reload_libs {
    my @par_files = @_;
    @par_files = sort keys %LibCache unless @par_files;

    foreach my $par (@par_files) {
        my $inc_ref = $PAR_INC{$par} or next;
        delete $LibCache{$par};
        delete $FileCache{$par};
        foreach my $file (sort keys %$inc_ref) {
            delete $INC{$file};
            require $file;
        }
    }
}

#sub find_zip_member {
#    my $file = pop;
#
#    foreach my $zip (@LibCache) {
#        my $member = _first_member($zip, $file) or next;
#        return $member;
#    }
#
#    return;
#}

sub read_file {
    my $file = pop;

    foreach my $zip (@LibCache) {
        my $member = _first_member($zip, $file) or next;
        return scalar $member->contents;
    }

    return;
}

sub par_handle {
    my $par = pop;
    return $LibCache{$par};
}

my %escapes;
sub unpar {
    my ($par, $file, $member_only, $allow_other_ext) = @_;
	return if not defined $par;
    my $zip = $LibCache{$par};
    my @rv = $par;

    # a guard against (currently unimplemented) recursion
    return if $PAR::__unpar;
    local $PAR::__unpar = 1;

    unless ($zip) {
        # URL use case ==> download
        if ($par =~ m!^\w+://!) {
            require File::Spec;
            require LWP::Simple;

            # reflector support
            $par .= "pm=$file" if $par =~ /[?&;]/;

            # prepare cache directory
            $ENV{PAR_CACHE} ||= '_par';
            mkdir $ENV{PAR_CACHE}, 0777;
            if (!-d $ENV{PAR_CACHE}) {
                $ENV{PAR_CACHE} = File::Spec->catdir(File::Spec->tmpdir, 'par');
                mkdir $ENV{PAR_CACHE}, 0777;
                return unless -d $ENV{PAR_CACHE};
            }

            # Munge URL into local file name
            # FIXME: This might result in unbelievably long file names!
            # I have run into the file/path length limitations of linux
            # with similar code in PAR::Repository::Client.
            # I suspect this is even worse on Win32.
            # -- Steffen
            my $file = $par;
            if (!%escapes) {
                $escapes{chr($_)} = sprintf("%%%02X", $_) for 0..255;
            }
            {
                use bytes;
                $file =~ s/([^\w\.])/$escapes{$1}/g;
            }

            $file = File::Spec->catfile( $ENV{PAR_CACHE}, $file);
            LWP::Simple::mirror( $par, $file );
            return unless -e $file and -f _;
            $par = $file;
        }
        # Got the .par as a string. (reference to scalar, of course)
        elsif (ref($par) eq 'SCALAR') {
            my ($fh) = _tempfile();
            print $fh $$par;
            $par = $fh;
        }
        # If the par is not a valid .par file name and we're being strict
        # about this, then also check whether "$par.par" exists
        elsif (!(($allow_other_ext or $par =~ /\.par\z/i) and -f $par)) {
            $par .= ".par";
            return unless -f $par;
        }

        require Archive::Zip;
        $zip = Archive::Zip->new;

        my @file;
        if (!ref $par) {
            @file = $par;

            open my $fh, '<', $par;
            binmode($fh);

            $par = $fh;
            bless($par, 'IO::File');
        }

        Archive::Zip::setErrorHandler(sub {});
        my $rv = $zip->readFromFileHandle($par, @file);
        Archive::Zip::setErrorHandler(undef);
        return unless $rv == Archive::Zip::AZ_OK();

        push @LibCache, $zip;
        $LibCache{$_[0]} = $zip;
        $FileCache{$_[0]} = _make_file_cache($zip);

        # only recursive case -- appears to be unused and unimplemented
        foreach my $member ( _cached_members_matching($zip, 
            "^par/(?:$Config{version}/)?(?:$Config{archname}/)?"
        ) ) {
            next if $member->isDirectory;
            my $content = $member->contents();
            next unless $content =~ /^PK\003\004/;
            push @rv, unpar(\$content, undef, undef, 1);
        }
        
        # extract all shlib dlls from the .par to $ENV{PAR_TEMP}
        # Intended to fix problem with Alien::wxWidgets/Wx...
        # NOTE auto/foo/foo.so|dll will get handled by the dynaloader
        # hook, so no need to pull it out here.
        # Allow this to be disabled so caller can do their own caching
        # via import({no_shlib_unpack => 1, file => foo.par})
        if(not $unpar_options{no_shlib_unpack} and defined $ENV{PAR_TEMP}) {
            my @members = _cached_members_matching( $zip,
              qr#^shlib/$Config{archname}/.*\.\Q$Config{dlext}\E(?:\.|$)#
            );
            foreach my $member (@members) {
                next if $member->isDirectory;
                my $member_name = $member->fileName;
                next unless $member_name =~ m{
                        \/([^/]+)$
                    }x
                    or $member_name =~ m{
                        ^([^/]+)$
                    };
                my $extract_name = $1;
                my $dest_name =
                    File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
                # but don't extract it if we've already got one
                $member->extractToFileNamed($dest_name)
                    unless(-e $dest_name);
            }
        }

        # Now push this path into usual library search paths
        my $separator = $Config{path_sep};
        my $tempdir = $ENV{PAR_TEMP};
        foreach my $key (qw(
            LD_LIBRARY_PATH
            LIB_PATH
            LIBRARY_PATH
            PATH
            DYLD_LIBRARY_PATH
        )) {
           if (defined $ENV{$key} and $ENV{$key} ne '') {
               # Check whether it's already in the path. If so, don't
               # append the PAR temp dir in order not to overflow the
               # maximum length for ENV vars.
               $ENV{$key} .= $separator . $tempdir
                 unless grep { $_ eq $tempdir } split $separator, $ENV{$key};
           }
           else {
               $ENV{$key} = $tempdir;
           }
       }
    
    }

    $LastAccessedPAR = $zip;

    return @rv unless defined $file;

    my $member = _first_member($zip,
        "lib/$file",
        "arch/$file",
        "$arch/$file",
        "$ver/$file",
        "$ver/$arch/$file",
        $file,
    ) or return;

    return $member if $member_only;

    my ($fh, $is_new);
    ($fh, $is_new, $LastTempFile) = _tempfile($member->crc32String . ".pm");
    die "Bad Things Happened..." unless $fh;

    if ($is_new) {
        $member->extractToFileHandle($fh);
        seek ($fh, 0, 0);
    }

    return $fh;
}

sub _tempfile {
    my ($fh, $filename);
    if ($ENV{PAR_CLEAN} or !@_) {
        require File::Temp;

        if (defined &File::Temp::tempfile) {
            # under Win32, the file is created with O_TEMPORARY,
            # and will be deleted by the C runtime; having File::Temp
            # delete it has the only effect of giving ugly warnings
            ($fh, $filename) = File::Temp::tempfile(
                DIR     => $PAR::SetupTemp::PARTemp,
                UNLINK  => ($^O ne 'MSWin32' and $^O !~ /hpux/),
            ) or die "Cannot create temporary file: $!";
            binmode($fh);
            return ($fh, 1, $filename);
        }
    }

    require File::Spec;

    # untainting tempfile path
    local $_ = File::Spec->catfile( $PAR::SetupTemp::PARTemp, $_[0] );
    /^(.+)$/ and $filename = $1;

    if (-r $filename) {
        open $fh, '<', $filename or die $!;
        binmode($fh);
        return ($fh, 0, $filename);
    }

    open $fh, '+>', $filename or die $!;
    binmode($fh);
    return ($fh, 1, $filename);
}

# Given an Archive::Zip object, this generates a hash of
#   file_name_in_zip => file object
# and returns a reference to that.
# If we broke the encapsulation of A::Zip::Member and
# accessed $member->{fileName} directly, that would be
# *significantly* faster.
sub _make_file_cache {
    my $zip = shift;
    if (not ref($zip)) {
        croak("_make_file_cache needs an Archive::Zip object as argument.");
    }
    my $cache = {};
    foreach my $member ($zip->members) {
        $cache->{$member->fileName()} = $member;
    }
    return $cache;
}

# given an Archive::Zip object, this finds the cached hash
# of Archive::Zip member names => members,
# and returns all member objects whose file names match
# a regexp
# Without file caching, it just uses $zip->membersMatching
sub _cached_members_matching {
    my $zip = shift;
    my $regex = shift;

    my $cache = $FileCache{$zip};
    $cache = $FileCache{$zip} = _make_file_cache($zip) if not $cache;

    return map {$cache->{$_}}
        grep { $_ =~ $regex }
        keys %$cache;
}

# access named zip file member through cache. Fall
# back to using Archive::Zip (slow)
sub _cached_member_named {
    my $zip = shift;
    my $name = shift;

    my $cache = $FileCache{$zip};
    $cache = $FileCache{$zip} = _make_file_cache($zip) if not $cache;
    return $cache->{$name};
}


# Attempt to clean up the temporary directory if
# --> We're running in clean mode
# --> It's defined
# --> It's an existing directory
# --> It's empty
END {
  if (exists $ENV{PAR_CLEAN} and $ENV{PAR_CLEAN}
      and exists $ENV{PAR_TEMP} and defined $ENV{PAR_TEMP} and -d $ENV{PAR_TEMP}
  ) {
    local($!); # paranoid: ignore potential errors without clobbering a global variable!
    rmdir($ENV{PAR_TEMP});
  }
}

1;

__END__

#line 1253
FILE   662c4a5b/PAR/Dist.pm  yy#line 1 "/home/pmarup/perl5/lib/perl5/PAR/Dist.pm"
package PAR::Dist;
use 5.006;
use strict;
require Exporter;
use vars qw/$VERSION @ISA @EXPORT @EXPORT_OK $DEBUG/;

$VERSION    = '0.49'; # Change version in POD, too!
@ISA        = 'Exporter';
@EXPORT     = qw/
  blib_to_par
  install_par
  uninstall_par
  sign_par
  verify_par
  merge_par
  remove_man
  get_meta
  generate_blib_stub
/;

@EXPORT_OK = qw/
  parse_dist_name
  contains_binaries
/;

$DEBUG = 0;

use Carp qw/carp croak/;
use File::Spec;

#line 142

sub blib_to_par {
    @_ = (path => @_) if @_ == 1;

    my %args = @_;
    require Config;


    # don't use 'my $foo ... if ...' it creates a static variable!
    my $quiet = $args{quiet} || 0;
    my $dist;
    my $path    = $args{path};
    $dist       = File::Spec->rel2abs($args{dist}) if $args{dist};
    my $name    = $args{name};
    my $version = $args{version};
    my $suffix  = $args{suffix} || "$Config::Config{archname}-$Config::Config{version}.par";
    my $cwd;

    if (defined $path) {
        require Cwd;
        $cwd = Cwd::cwd();
        chdir $path;
    }

    _build_blib() unless -d "blib";

    my @files;
    open MANIFEST, ">", File::Spec->catfile("blib", "MANIFEST") or die $!;
    open META, ">", File::Spec->catfile("blib", "META.yml") or die $!;
    
    require File::Find;
    File::Find::find( sub {
        next unless $File::Find::name;
        (-r && !-d) and push ( @files, substr($File::Find::name, 5) );
    } , 'blib' );

    print MANIFEST join(
        "\n",
        '    <!-- accessible as jar:file:///NAME.par!/MANIFEST in compliant browsers -->',
        (sort @files),
        q(    # <html><body onload="var X=document.body.innerHTML.split(/\n/);var Y='<iframe src=&quot;META.yml&quot; style=&quot;float:right;height:40%;width:40%&quot;></iframe><ul>';for(var x in X){if(!X[x].match(/^\s*#/)&&X[x].length)Y+='<li><a href=&quot;'+X[x]+'&quot;>'+X[x]+'</a>'}document.body.innerHTML=Y">)
    );
    close MANIFEST;

    # if MYMETA.yml exists, that takes precedence over META.yml
    my $meta_file_name = "META.yml";
    my $mymeta_file_name = "MYMETA.yml";
    $meta_file_name = -s $mymeta_file_name ? $mymeta_file_name : $meta_file_name;
    if (open(OLD_META, $meta_file_name)) {
        while (<OLD_META>) {
            if (/^distribution_type:/) {
                print META "distribution_type: par\n";
            }
            else {
                print META $_;
            }

            if (/^name:\s+(.*)/) {
                $name ||= $1;
                $name =~ s/::/-/g;
            }
            elsif (/^version:\s+.*Module::Build::Version/) {
                while (<OLD_META>) {
                    /^\s+original:\s+(.*)/ or next;
                    $version ||= $1;
                    last;
                }
            }
            elsif (/^version:\s+(.*)/) {
                $version ||= $1;
            }
        }
        close OLD_META;
        close META;
    }
    
    if ((!$name or !$version) and open(MAKEFILE, "Makefile")) {
        while (<MAKEFILE>) {
            if (/^DISTNAME\s+=\s+(.*)$/) {
                $name ||= $1;
            }
            elsif (/^VERSION\s+=\s+(.*)$/) {
                $version ||= $1;
            }
        }
    }

    if (not defined($name) or not defined($version)) {
        # could not determine name or version. Error.
        my $what;
        if (not defined $name) {
            $what = 'name';
            $what .= ' and version' if not defined $version;
        }
        elsif (not defined $version) {
            $what = 'version';
        }
        
        carp("I was unable to determine the $what of the PAR distribution. Please create a Makefile or META.yml file from which we can infer the information or just specify the missing information as an option to blib_to_par.");
        return();
    }
    
    $name =~ s/\s+$//;
    $version =~ s/\s+$//;

    my $file = "$name-$version-$suffix";
    unlink $file if -f $file;

    print META << "YAML" if fileno(META);
name: $name
version: $version
build_requires: {}
conflicts: {}
dist_name: $file
distribution_type: par
dynamic_config: 0
generated_by: 'PAR::Dist version $PAR::Dist::VERSION'
license: unknown
YAML
    close META;

    mkdir('blib', 0777);
    chdir('blib');
    require Cwd;
    my $zipoutfile = File::Spec->catfile(File::Spec->updir, $file);
    _zip(dist => $zipoutfile);
    chdir(File::Spec->updir);

    unlink File::Spec->catfile("blib", "MANIFEST");
    unlink File::Spec->catfile("blib", "META.yml");

    $dist ||= File::Spec->catfile($cwd, $file) if $cwd;

    if ($dist and $file ne $dist) {
        if ( File::Copy::copy($file, $dist) ) {
          unlink $file;
        } else {
          die "Cannot copy $file: $!";
        }

        $file = $dist;
    }

    my $pathname = File::Spec->rel2abs($file);
    if ($^O eq 'MSWin32') {
        $pathname =~ s!\\!/!g;
        $pathname =~ s!:!|!g;
    };
    print << "." if !$quiet;
Successfully created binary distribution '$file'.
Its contents are accessible in compliant browsers as:
    jar:file://$pathname!/MANIFEST
.

    chdir $cwd if $cwd;
    return $file;
}

sub _build_blib {
    if (-e 'Build') {
        _system_wrapper($^X, "Build");
    }
    elsif (-e 'Makefile') {
        _system_wrapper($Config::Config{make});
    }
    elsif (-e 'Build.PL') {
        _system_wrapper($^X, "Build.PL");
        _system_wrapper($^X, "Build");
    }
    elsif (-e 'Makefile.PL') {
        _system_wrapper($^X, "Makefile.PL");
        _system_wrapper($Config::Config{make});
    }
}

#line 401

sub install_par {
    my %args = &_args;
    _install_or_uninstall(%args, action => 'install');
}

#line 422

sub uninstall_par {
    my %args = &_args;
    _install_or_uninstall(%args, action => 'uninstall');
}

sub _install_or_uninstall {
    my %args = &_args;
    my $name = $args{name};
    my $action = $args{action};

    my %ENV_copy = %ENV;
    $ENV{PERL_INSTALL_ROOT} = $args{prefix} if defined $args{prefix};

    require Cwd;
    my $old_dir = Cwd::cwd();
    
    my ($dist, $tmpdir) = _unzip_to_tmpdir( dist => $args{dist}, subdir => 'blib' );

    if ( open (META, File::Spec->catfile('blib', 'META.yml')) ) {
        while (<META>) {
            next unless /^name:\s+(.*)/;
            $name = $1;
            $name =~ s/\s+$//;
            last;
        }
        close META;
    }
    return if not defined $name or $name eq '';

    if (-d 'script') {
        require ExtUtils::MY;
        foreach my $file (glob("script/*")) {
            next unless -T $file;
            ExtUtils::MY->fixin($file);
            chmod(0555, $file);
        }
    }

    $name =~ s{::|-}{/}g;
    require ExtUtils::Install;

    if ($action eq 'install') {
        my $target = _installation_target( File::Spec->curdir, $name, \%args );
        my $custom_targets = $args{custom_targets} || {};
        $target->{$_} = $custom_targets->{$_} foreach keys %{$custom_targets};
        
        my $uninstall_shadows = $args{uninstall_shadows};
        my $verbose = $args{verbose};
        ExtUtils::Install::install($target, $verbose, 0, $uninstall_shadows);
    }
    elsif ($action eq 'uninstall') {
        require Config;
        my $verbose = $args{verbose};
        ExtUtils::Install::uninstall(
            $args{packlist_read}||"$Config::Config{installsitearch}/auto/$name/.packlist",
            $verbose
        );
    }

    %ENV = %ENV_copy;

    chdir($old_dir);
    File::Path::rmtree([$tmpdir]);

    return 1;
}

# Returns the default installation target as used by
# ExtUtils::Install::install(). First parameter should be the base
# directory containing the blib/ we're installing from.
# Second parameter should be the name of the distribution for the packlist
# paths. Third parameter may be a hash reference with user defined keys for
# the target hash. In fact, any contents that do not start with 'inst_' are
# skipped.
sub _installation_target {
    require Config;
    my $dir = shift;
    my $name = shift;
    my $user = shift || {};

    # accepted sources (and user overrides)
    my %sources = (
      inst_lib => File::Spec->catdir($dir,"blib","lib"),
      inst_archlib => File::Spec->catdir($dir,"blib","arch"),
      inst_bin => File::Spec->catdir($dir,'blib','bin'),
      inst_script => File::Spec->catdir($dir,'blib','script'),
      inst_man1dir => File::Spec->catdir($dir,'blib','man1'),
      inst_man3dir => File::Spec->catdir($dir,'blib','man3'),
      packlist_read => 'read',
      packlist_write => 'write',
    );


    my $par_has_archlib = _directory_not_empty( $sources{inst_archlib} );

    # default targets
    my $target = {
       read => $Config::Config{sitearchexp}."/auto/$name/.packlist",
       write => $Config::Config{installsitearch}."/auto/$name/.packlist",
       $sources{inst_lib} =>
            ($par_has_archlib
             ? $Config::Config{installsitearch}
             : $Config::Config{installsitelib}),
       $sources{inst_archlib}   => $Config::Config{installsitearch},
       $sources{inst_bin}       => $Config::Config{installbin} ,
       $sources{inst_script}    => $Config::Config{installscript},
       $sources{inst_man1dir}   => $Config::Config{installman1dir},
       $sources{inst_man3dir}   => $Config::Config{installman3dir},
    };
    
    # Included for future support for ${flavour}perl external lib installation
#    if ($Config::Config{flavour_perl}) {
#        my $ext = File::Spec->catdir($dir, 'blib', 'ext');
#        # from => to
#        $sources{inst_external_lib}    = File::Spec->catdir($ext, 'lib');
#        $sources{inst_external_bin}    = File::Spec->catdir($ext, 'bin');
#        $sources{inst_external_include} = File::Spec->catdir($ext, 'include');
#        $sources{inst_external_src}    = File::Spec->catdir($ext, 'src');
#        $target->{ $sources{inst_external_lib} }     = $Config::Config{flavour_install_lib};
#        $target->{ $sources{inst_external_bin} }     = $Config::Config{flavour_install_bin};
#        $target->{ $sources{inst_external_include} } = $Config::Config{flavour_install_include};
#        $target->{ $sources{inst_external_src} }     = $Config::Config{flavour_install_src};
#    }
    
    # insert user overrides
    foreach my $key (keys %$user) {
        my $value = $user->{$key};
        if (not defined $value and $key ne 'packlist_read' and $key ne 'packlist_write') {
          # undef means "remove"
          delete $target->{ $sources{$key} };
        }
        elsif (exists $sources{$key}) {
          # overwrite stuff, don't let the user create new entries
          $target->{ $sources{$key} } = $value;
        }
    }

    # apply the automatic inst_lib => inst_archlib conversion again
    # if the user asks for it and there is an archlib in the .par
    if ($user->{auto_inst_lib_conversion} and $par_has_archlib) {
      $target->{inst_lib} = $target->{inst_archlib};
    }

    return $target;
}

sub _directory_not_empty {
    require File::Find;
    my($dir) = @_;
    my $files = 0;
    File::Find::find(sub {
        return if $_ eq ".exists";
        if (-f) {
            $File::Find::prune++;
            $files = 1;
            }
    }, $dir);
    return $files;
}

#line 589

sub sign_par {
    my %args = &_args;
    _verify_or_sign(%args, action => 'sign');
}

#line 604

sub verify_par {
    my %args = &_args;
    $! = _verify_or_sign(%args, action => 'verify');
    return ( $! == Module::Signature::SIGNATURE_OK() );
}

#line 633

sub merge_par {
    my $base_par = shift;
    my @additional_pars = @_;
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Find;

    # parameter checking
    if (not defined $base_par) {
        croak "First argument to merge_par() must be the .par archive to modify.";
    }

    if (not -f $base_par or not -r _ or not -w _) {
        croak "'$base_par' is not a file or you do not have enough permissions to read and modify it.";
    }
    
    foreach (@additional_pars) {
        if (not -f $_ or not -r _) {
            croak "'$_' is not a file or you do not have enough permissions to read it.";
        }
    }

    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $base_par, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');

    # move the META.yml to the (main) temp. dir.
    my $main_meta_file = File::Spec->catfile($base_dir, 'META.yml');
    File::Copy::move(
        File::Spec->catfile($blibdir, 'META.yml'),
        $main_meta_file
    );
    # delete (incorrect) MANIFEST
    unlink File::Spec->catfile($blibdir, 'MANIFEST');

    # extract additional pars and merge    
    foreach my $par (@additional_pars) {
        # restore original directory because the par path
        # might have been relative!
        chdir($old_cwd);
        (undef, my $add_dir) = _unzip_to_tmpdir(
            dist => $par
        );

        # merge the meta (at least the provides info) into the main meta.yml
        my $meta_file = File::Spec->catfile($add_dir, 'META.yml');
        if (-f $meta_file) {
          _merge_meta($main_meta_file, $meta_file);
        }

        my @files;
        my @dirs;
        # I hate File::Find
        # And I hate writing portable code, too.
        File::Find::find(
            {wanted =>sub {
                my $file = $File::Find::name;
                push @files, $file if -f $file;
                push @dirs, $file if -d _;
            }},
            $add_dir
        );
        my ($vol, $subdir, undef) = File::Spec->splitpath( $add_dir, 1);
        my @dir = File::Spec->splitdir( $subdir );
    
        # merge directory structure
        foreach my $dir (@dirs) {
            my ($v, $d, undef) = File::Spec->splitpath( $dir, 1 );
            my @d = File::Spec->splitdir( $d );
            shift @d foreach @dir; # remove tmp dir from path
            my $target = File::Spec->catdir( $blibdir, @d );
            mkdir($target);
        }

        # merge files
        foreach my $file (@files) {
            my ($v, $d, $f) = File::Spec->splitpath( $file );
            my @d = File::Spec->splitdir( $d );
            shift @d foreach @dir; # remove tmp dir from path
            my $target = File::Spec->catfile(
                File::Spec->catdir( $blibdir, @d ),
                $f
            );
            File::Copy::copy($file, $target)
              or die "Could not copy '$file' to '$target': $!";
            
        }
        chdir($old_cwd);
        File::Path::rmtree([$add_dir]);
    }
    
    # delete (copied) MANIFEST and META.yml
    unlink File::Spec->catfile($blibdir, 'MANIFEST');
    unlink File::Spec->catfile($blibdir, 'META.yml');
    
    chdir($base_dir);
    my $resulting_par_file = Cwd::abs_path(blib_to_par(quiet => 1));
    chdir($old_cwd);
    File::Copy::move($resulting_par_file, $base_par);
    
    File::Path::rmtree([$base_dir]);
}


sub _merge_meta {
  my $meta_orig_file = shift;
  my $meta_extra_file = shift;
  return() if not defined $meta_orig_file or not -f $meta_orig_file;
  return 1 if not defined $meta_extra_file or not -f $meta_extra_file;

  my $yaml_functions = _get_yaml_functions();

  die "Cannot merge META.yml files without a YAML reader/writer"
    if !exists $yaml_functions->{LoadFile}
    or !exists $yaml_functions->{DumpFile};

  my $orig_meta  = $yaml_functions->{LoadFile}->($meta_orig_file);
  my $extra_meta = $yaml_functions->{LoadFile}->($meta_extra_file);

  # I seem to remember there was this incompatibility between the different
  # YAML implementations with regards to "document" handling:
  my $orig_tree  = (ref($orig_meta) eq 'ARRAY' ? $orig_meta->[0] : $orig_meta);
  my $extra_tree = (ref($extra_meta) eq 'ARRAY' ? $extra_meta->[0] : $extra_meta);

  _merge_provides($orig_tree, $extra_tree);
  _merge_requires($orig_tree, $extra_tree);
  
  $yaml_functions->{DumpFile}->($meta_orig_file, $orig_meta);

  return 1;
}

# merge the two-level provides sections of META.yml
sub _merge_provides {
  my $orig_hash  = shift;
  my $extra_hash = shift;

  return() if not exists $extra_hash->{provides};
  $orig_hash->{provides} ||= {};

  my $orig_provides  = $orig_hash->{provides};
  my $extra_provides = $extra_hash->{provides};

  # two level clone is enough wrt META spec 1.4
  # overwrite the original provides since we're also overwriting the files.
  foreach my $module (keys %$extra_provides) {
    my $extra_mod_hash = $extra_provides->{$module};
    my %mod_hash;
    $mod_hash{$_} = $extra_mod_hash->{$_} for keys %$extra_mod_hash;
    $orig_provides->{$module} = \%mod_hash;
  }
}

# merge the single-level requires-like sections of META.yml
sub _merge_requires {
  my $orig_hash  = shift;
  my $extra_hash = shift;

  foreach my $type (qw(requires build_requires configure_requires recommends)) {
    next if not exists $extra_hash->{$type};
    $orig_hash->{$type} ||= {};
    
    # one level clone is enough wrt META spec 1.4
    foreach my $module (keys %{ $extra_hash->{$type} }) {
      # FIXME there should be a version comparison here, BUT how are we going to do that without a guaranteed version.pm?
      $orig_hash->{$type}{$module} = $extra_hash->{$type}{$module}; # assign version and module name
    }
  }
}

#line 822

sub remove_man {
    my %args = &_args;
    my $par = $args{dist};
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Find;

    # parameter checking
    if (not defined $par) {
        croak "First argument to remove_man() must be the .par archive to modify.";
    }

    if (not -f $par or not -r _ or not -w _) {
        croak "'$par' is not a file or you do not have enough permissions to read and modify it.";
    }
    
    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $par, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');

    # move the META.yml to the (main) temp. dir.
    File::Copy::move(
        File::Spec->catfile($blibdir, 'META.yml'),
        File::Spec->catfile($base_dir, 'META.yml')
    );
    # delete (incorrect) MANIFEST
    unlink File::Spec->catfile($blibdir, 'MANIFEST');

    opendir DIRECTORY, 'blib' or die $!;
    my @dirs = grep { /^blib\/(?:man\d*|html)$/ }
               grep { -d $_ }
               map  { File::Spec->catfile('blib', $_) }
               readdir DIRECTORY;
    close DIRECTORY;
    
    File::Path::rmtree(\@dirs);
    
    chdir($base_dir);
    my $resulting_par_file = Cwd::abs_path(blib_to_par());
    chdir($old_cwd);
    File::Copy::move($resulting_par_file, $par);
    
    File::Path::rmtree([$base_dir]);
}


#line 888

sub get_meta {
    my %args = &_args;
    my $dist = $args{dist};
    return undef if not defined $dist or not -r $dist;
    require Cwd;
    require File::Path;

    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $dist, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');

    my $meta = File::Spec->catfile($blibdir, 'META.yml');

    if (not -r $meta) {
        return undef;
    }
    
    open FH, '<', $meta
      or die "Could not open file '$meta' for reading: $!";
    
    local $/ = undef;
    my $meta_text = <FH>;
    close FH;
    
    chdir($old_cwd);
    
    File::Path::rmtree([$base_dir]);
    
    return $meta_text;
}



sub _unzip {
    my %args = &_args;
    my $dist = $args{dist};
    my $path = $args{path} || File::Spec->curdir;
    return unless -f $dist;

    # Try fast unzipping first
    if (eval { require Archive::Unzip::Burst; 1 }) {
        my $return = !Archive::Unzip::Burst::unzip($dist, $path);
        return if $return; # true return value == error (a la system call)
    }
    # Then slow unzipping
    if (eval { require Archive::Zip; 1 }) {
        my $zip = Archive::Zip->new;
        local %SIG;
        $SIG{__WARN__} = sub { print STDERR $_[0] unless $_[0] =~ /\bstat\b/ };
        return unless $zip->read($dist) == Archive::Zip::AZ_OK()
                  and $zip->extractTree('', "$path/") == Archive::Zip::AZ_OK();
    }
    # Then fall back to the system
    else {
        undef $!;
        if (_system_wrapper(unzip => $dist, '-d', $path)) {
            die "Failed to unzip '$dist' to path '$path': Could neither load "
                . "Archive::Zip nor (successfully) run the system 'unzip' (unzip said: $!)";
        }
    }

    return 1;
}

sub _zip {
    my %args = &_args;
    my $dist = $args{dist};

    if (eval { require Archive::Zip; 1 }) {
        my $zip = Archive::Zip->new;
        $zip->addTree( File::Spec->curdir, '' );
        $zip->writeToFileNamed( $dist ) == Archive::Zip::AZ_OK() or die $!;
    }
    else {
        undef $!;
        if (_system_wrapper(qw(zip -r), $dist, File::Spec->curdir)) {
            die "Failed to zip '" .File::Spec->curdir(). "' to '$dist': Could neither load "
                . "Archive::Zip nor (successfully) run the system 'zip' (zip said: $!)";
        }
    }
    return 1;
}


# This sub munges the arguments to most of the PAR::Dist functions
# into a hash. On the way, it downloads PAR archives as necessary, etc.
sub _args {
    # default to the first .par in the CWD
    if (not @_) {
        @_ = (glob('*.par'))[0];
    }

    # single argument => it's a distribution file name or URL
    @_ = (dist => @_) if @_ == 1;

    my %args = @_;
    $args{name} ||= $args{dist};

    # If we are installing from an URL, we want to munge the
    # distribution name so that it is in form "Module-Name"
    if (defined $args{name}) {
        $args{name} =~ s/^\w+:\/\///;
        my @elems = parse_dist_name($args{name});
        # @elems is name, version, arch, perlversion
        if (defined $elems[0]) {
            $args{name} = $elems[0];
        }
        else {
            $args{name} =~ s/^.*\/([^\/]+)$/$1/;
            $args{name} =~ s/^([0-9A-Za-z_-]+)-\d+\..+$/$1/;
        }
    }

    # append suffix if there is none
    if ($args{dist} and not $args{dist} =~ /\.[a-zA-Z_][^.]*$/) {
        require Config;
        my $suffix = $args{suffix};
        $suffix ||= "$Config::Config{archname}-$Config::Config{version}.par";
        $args{dist} .= "-$suffix";
    }

    # download if it's an URL
    if ($args{dist} and $args{dist} =~ m!^\w+://!) {
        $args{dist} = _fetch(dist => $args{dist})
    }

    return %args;
}


# Download PAR archive, but only if necessary (mirror!)
my %escapes;
sub _fetch {
    my %args = @_;

    if ($args{dist} =~ s/^file:\/\///) {
      return $args{dist} if -e $args{dist};
      return;
    }
    require LWP::Simple;

    $ENV{PAR_TEMP} ||= File::Spec->catdir(File::Spec->tmpdir, 'par');
    mkdir $ENV{PAR_TEMP}, 0777;
    %escapes = map { chr($_) => sprintf("%%%02X", $_) } 0..255 unless %escapes;

    $args{dist} =~ s{^cpan://((([a-zA-Z])[a-zA-Z])[-_a-zA-Z]+)/}
                    {http://www.cpan.org/modules/by-authors/id/\U$3/$2/$1\E/};

    my $file = $args{dist};
    $file =~ s/([^\w\.])/$escapes{$1}/g;
    $file = File::Spec->catfile( $ENV{PAR_TEMP}, $file);
    my $rc = LWP::Simple::mirror( $args{dist}, $file );

    if (!LWP::Simple::is_success($rc) and $rc != 304) {
        die "Error $rc: ", LWP::Simple::status_message($rc), " ($args{dist})\n";
    }

    return $file if -e $file;
    return;
}

sub _verify_or_sign {
    my %args = &_args;

    require File::Path;
    require Module::Signature;
    die "Module::Signature version 0.25 required"
      unless Module::Signature->VERSION >= 0.25;

    require Cwd;
    my $cwd = Cwd::cwd();
    my $action = $args{action};
    my ($dist, $tmpdir) = _unzip_to_tmpdir($args{dist});
    $action ||= (-e 'SIGNATURE' ? 'verify' : 'sign');

    if ($action eq 'sign') {
        open FH, '>SIGNATURE' unless -e 'SIGNATURE';
        open FH, 'MANIFEST' or die $!;

        local $/;
        my $out = <FH>;
        if ($out !~ /^SIGNATURE(?:\s|$)/m) {
            $out =~ s/^(?!\s)/SIGNATURE\n/m;
            open FH, '>MANIFEST' or die $!;
            print FH $out;
        }
        close FH;

        $args{overwrite} = 1 unless exists $args{overwrite};
        $args{skip}      = 0 unless exists $args{skip};
    }

    my $rv = Module::Signature->can($action)->(%args);
    _zip(dist => $dist) if $action eq 'sign';
    File::Path::rmtree([$tmpdir]);

    chdir($cwd);
    return $rv;
}

sub _unzip_to_tmpdir {
    my %args = &_args;

    require File::Temp;

    my $dist   = File::Spec->rel2abs($args{dist});
    my $tmpdirname = File::Spec->catdir(File::Spec->tmpdir, "parXXXXX");
    my $tmpdir = File::Temp::mkdtemp($tmpdirname)        
      or die "Could not create temporary directory from template '$tmpdirname': $!";
    my $path = $tmpdir;
    $path = File::Spec->catdir($tmpdir, $args{subdir}) if defined $args{subdir};
    _unzip(dist => $dist, path => $path);

    chdir $tmpdir;
    return ($dist, $tmpdir);
}



#line 1136

sub parse_dist_name {
    my $file = shift;
    return(undef, undef, undef, undef) if not defined $file;

    (undef, undef, $file) = File::Spec->splitpath($file);
    
    my $version = qr/v?(?:\d+(?:_\d+)?|\d*(?:\.\d+(?:_\d+)?)+)/;
    $file =~ s/\.(?:par|tar\.gz|tar)$//i;
    my @elem = split /-/, $file;
    my (@dn, $dv, @arch, $pv);
    while (@elem) {
        my $e = shift @elem;
        if (
            $e =~ /^$version$/o
            and not(# if not next token also a version
                    # (assumes an arch string doesnt start with a version...)
                @elem and $elem[0] =~ /^$version$/o
            )
        ) {
            $dv = $e;
            last;
        }
        push @dn, $e;
    }
    
    my $dn;
    $dn = join('-', @dn) if @dn;

    if (not @elem) {
        return( $dn, $dv, undef, undef);
    }

    while (@elem) {
        my $e = shift @elem;
        if ($e =~ /^(?:$version|any_version)$/) {
            $pv = $e;
            last;
        }
        push @arch, $e;
    }

    my $arch;
    $arch = join('-', @arch) if @arch;

    return($dn, $dv, $arch, $pv);
}

#line 1212

sub generate_blib_stub {
    my %args = &_args;
    my $dist = $args{dist};
    require Config;
    
    my $name    = $args{name};
    my $version = $args{version};
    my $suffix  = $args{suffix};

    my ($parse_name, $parse_version, $archname, $perlversion)
      = parse_dist_name($dist);
    
    $name ||= $parse_name;
    $version ||= $parse_version;
    $suffix = "$archname-$perlversion"
      if (not defined $suffix or $suffix eq '')
         and $archname and $perlversion;
    
    $suffix ||= "$Config::Config{archname}-$Config::Config{version}";
    if ( grep { not defined $_ } ($name, $version, $suffix) ) {
        warn "Could not determine distribution meta information from distribution name '$dist'";
        return();
    }
    $suffix =~ s/\.par$//;

    if (not -f 'META.yml') {
        open META, '>', 'META.yml'
          or die "Could not open META.yml file for writing: $!";
        print META << "YAML" if fileno(META);
name: $name
version: $version
build_requires: {}
conflicts: {}
dist_name: $name-$version-$suffix.par
distribution_type: par
dynamic_config: 0
generated_by: 'PAR::Dist version $PAR::Dist::VERSION'
license: unknown
YAML
        close META;
    }

    mkdir('blib');
    mkdir(File::Spec->catdir('blib', 'lib'));
    mkdir(File::Spec->catdir('blib', 'script'));

    return 1;
}


#line 1280

sub contains_binaries {
    require File::Find;
    my %args = &_args;
    my $dist = $args{dist};
    return undef if not defined $dist or not -r $dist;
    require Cwd;
    require File::Path;

    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $dist, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');
    my $archdir = File::Spec->catdir($blibdir, 'arch');

    my $found = 0;

    File::Find::find(
      sub {
        $found++ if -f $_ and not /^\.exists$/;
      },
      $archdir
    );

    chdir($old_cwd);
    
    File::Path::rmtree([$base_dir]);
    
    return $found ? 1 : 0;
}

sub _system_wrapper {
  if ($DEBUG) {
    Carp::cluck("Running system call '@_' from:");
  }
  return system(@_);
}

# stolen from Module::Install::Can
# very much internal and subject to change or removal
sub _MI_can_run {
  require ExtUtils::MakeMaker;
  my ($cmd) = @_;

  my $_cmd = $cmd;
  return $_cmd if (-x $_cmd or $_cmd = MM->maybe_command($_cmd));

  for my $dir ((split /$Config::Config{path_sep}/, $ENV{PATH}), '.') {
    my $abs = File::Spec->catfile($dir, $cmd);
    return $abs if (-x $abs or $abs = MM->maybe_command($abs));
  }

  return;
}


# Tries to load any YAML reader writer I know of
# returns nothing on failure or hash reference containing
# a subset of Load, Dump, LoadFile, DumpFile
# entries with sub references on success.
sub _get_yaml_functions {
  # reasoning for the ranking here:
  # - XS is the de-facto standard nowadays.
  # - YAML.pm is slow and aging
  # - syck is fast and reasonably complete
  # - Tiny is only a very small subset
  # - Parse... is only a reader and only deals with the same subset as ::Tiny
  my @modules = qw(YAML::XS YAML YAML::Tiny YAML::Syck Parse::CPAN::Meta);

  my %yaml_functions;
  foreach my $module (@modules) {
    eval "require $module;";
    if (!$@) {
      warn "PAR::Dist testers/debug info: Using '$module' as YAML implementation" if $DEBUG;
      foreach my $sub (qw(Load Dump LoadFile DumpFile)) {
        no strict 'refs';
        my $subref = *{"${module}::$sub"}{CODE};
        if (defined $subref and ref($subref) eq 'CODE') {
          $yaml_functions{$sub} = $subref;
        }
      }
      $yaml_functions{yaml_provider} = $module;
      last;
    }
  } # end foreach module candidates
  if (not keys %yaml_functions) {
    warn "Cannot find a working YAML reader/writer implementation. Tried to load all of '@modules'";
  }
  return(\%yaml_functions);
}

sub _check_tools {
  my $tools = _get_yaml_functions();
  if ($DEBUG) {
    foreach (qw/Load Dump LoadFile DumpFile/) {
      warn "No YAML support for $_ found.\n" if not defined $tools->{$_};
    }
  }

  $tools->{zip} = undef;
  # A::Zip 1.28 was a broken release...
  if (eval {require Archive::Zip; 1;} and $Archive::Zip::VERSION ne '1.28') {
    warn "Using Archive::Zip as ZIP tool.\n" if $DEBUG;
    $tools->{zip} = 'Archive::Zip';
  }
  elsif (_MI_can_run("zip") and _MI_can_run("unzip")) {
    warn "Using zip/unzip as ZIP tool.\n" if $DEBUG;
    $tools->{zip} = 'zip';
  }
  else {
    warn "Found neither Archive::Zip (version != 1.28) nor ZIP/UNZIP as valid ZIP tools.\n" if $DEBUG;
    $tools->{zip} = undef;
  }

  return $tools;
}

1;

#line 1429
FILE   6c5e9df3/PAR/Filter.pm  x#line 1 "/home/pmarup/perl5/lib/perl5/PAR/Filter.pm"
package PAR::Filter;
use 5.006;
use strict;
use warnings;
our $VERSION = '0.03';

#line 64

sub new {
    my $class = shift;
    require "PAR/Filter/$_.pm" foreach @_;
    bless(\@_, $class);
}

sub apply {
    my ($self, $ref, $name) = @_;
    my $filename = $name || '-e';

    if (!ref $ref) {
	$name ||= $filename = $ref;
	local $/;
	open my $fh, $ref or die $!;
	binmode($fh);
	my $content = <$fh>;
	$ref = \$content;
	return $ref unless length($content);
    }

    "PAR::Filter::$_"->new->apply( $ref, $filename, $name ) foreach @$self;

    return $ref;
}

1;

#line 106
FILE   #b795879f/PAR/Filter/PatchContent.pm  ;#line 1 "/home/pmarup/perl5/lib/perl5/PAR/Filter/PatchContent.pm"
package PAR::Filter::PatchContent;
use 5.006;
use strict;
use warnings;
use base 'PAR::Filter';

#line 22

sub PATCH_CONTENT () { +{
    map { ref($_) ? $_ : lc($_) }
    'AutoLoader.pm' => [
        '$is_dosish = ' =>
        '$is_dosish = $^O eq \'cygwin\' || ',
    ],
    'MIME/Types.pm' => [
        'File::Spec->catfile(dirname(__FILE__),' =>
        'File::Spec->catfile($ENV{PAR_TEMP}, qw(inc lib MIME),',
    ],
    'Mozilla/CA.pm' => [
        'File::Spec->catfile(dirname(__FILE__), "CA", "cacert.pem")' =>
        'File::Spec->catfile($ENV{PAR_TEMP}, qw(inc lib Mozilla CA cacert.pem))',
    ],
    'Pod/Usage.pm' => [
        ' = $0' =>
        ' = $ENV{PAR_0} || $0',
    ],
    # Some versions of Spreadsheet::ParseExcel have a weird non-POD construct =cmmt
    # that is used to comment out a block of code. perl treats it as POD and strips it.
    # Since it's not POD, POD parsers ignore it.
    # PAR::Filter::PodStrip only strips valid POD. Hence we remove it here.
    'Spreadsheet/ParseExcel.pm' => [
        qr/^=cmmt\s+.*?^=cut\s*/sm =>
        '',
    ],
    'SQL/Parser.pm'      => [
        'my @dialects;' =>
        'require PAR;
         my @dialects = ();
         foreach my $member ( $PAR::LastAccessedPAR->members ) {
             next unless $member->fileName =~ m!\bSQL/Dialects/([^/]+)\.pm$!;
             push @dialects, $1;
         }
        ',
    ],
    'Tk.pm'             => [
        'foreach $dir (@INC)' => 
        'require PAR;
         if (my $member = PAR::unpar($0, $file, 1)) {
            $file =~ s![/\\\\]!_!g;
            return PAR::Heavy::_dl_extract($member,$file,$file);
         }
         if (my $member = PAR::unpar($0, my $name = $_[1], 1)) {
            $name =~ s![/\\\\]!_!g;
            return PAR::Heavy::_dl_extract($member,$name,$name);
         }
         foreach $dir (@INC)', 
    ],
    'Tk/Widget.pm'          => [
        'if (defined($name=$INC{"$pkg.pm"}))' =>
        'if (defined($name=$INC{"$pkg.pm"}) and !ref($name) and $name !~ m!^/loader/!)',
    ],
    'Win32/API/Type.pm'     => [
        'INIT ' => '',
    ],
    'Win32/SystemInfo.pm'   => [
        '$dll .= "cpuspd.dll";' =>
        'require PAR;
         $dll = "lib/Win32/cpuspd.dll";
         if (my $member = PAR::unpar($0, $dll, 1)) {
             $dll = PAR::Heavy::_dl_extract($member,"cpuspd.dll","cpuspd.dll");
             $dll =~ s!\\\\!/!g;
         } else { die $! }',
    ],
    'XSLoader.pm'     => [
        'goto retry unless $module and defined &dl_load_file;' =>
            'goto retry;',                              # XSLoader <= 0.10
        'goto \&XSLoader::bootstrap_inherit unless $module and defined &dl_load_file;' =>
            'goto \&XSLoader::bootstrap_inherit;',      # XSLoader >= 0.14
    ],
    'diagnostics.pm'        => [
        'CONFIG: ' => 'CONFIG: if (0) ',
        'if (eof(POD_DIAG)) ' => 'if (0 and eof(POD_DIAG)) ',
        'close POD_DIAG' => '# close POD_DIAG',
        'while (<POD_DIAG>) ' =>
        'require PAR; use Config;
        my @files = (
            "lib/pod/perldiag.pod",
            "lib/Pod/perldiag.pod",
            "lib/pod/perldiag-$Config{version}.pod",
            "lib/Pod/perldiag-$Config{version}.pod",
            "lib/pods/perldiag.pod",
            "lib/pods/perldiag-$Config{version}.pod",
        );
        my $contents;
        foreach my $file (@files) {
            $contents = PAR::read_file($file);
            last if defined $contents;
        }
        for(map "$_\\n\\n", split/(?:\\r?\\n){2,}/, $contents) ',
    ],
    'utf8_heavy.pl'	    => [
        '$list ||= eval { $caller->$type(); }'
        => '$list = eval { $caller->$type(); }',
    '|| croak("Can\'t find $encoding character property definition via $caller->$type or $file.pl")'
        => '|| croak("Can\'t find $encoding character property definition via $caller->$type or $file.pl") unless $list;'
    ],
} };

sub apply {
    my ($class, $ref, $filename, $name) = @_;
    { use bytes; $$ref =~ s/^\xEF\xBB\xBF//; } # remove utf8 BOM

    my @rule = @{PATCH_CONTENT->{lc($name)}||[]} or return $$ref;
    while (my ($from, $to) = splice(@rule, 0, 2)) {
        if (ref($from) eq 'Regexp') {
            $$ref =~ s/$from/$to/g;
        }
        else {
            $$ref =~ s/\Q$from\E/$to/g;
        }
    }
    return $$ref;
}

1;

#line 165
FILE   cf1d4da4/PAR/Filter/PodStrip.pm  �#line 1 "/home/pmarup/perl5/lib/perl5/PAR/Filter/PodStrip.pm"
package PAR::Filter::PodStrip;
use 5.006;
use strict;
use warnings;
use base 'PAR::Filter';

#line 22

sub apply {
    my ($class, $ref, $filename, $name) = @_;

    no warnings 'uninitialized';

    my $data = '';
    $data = $1 if $$ref =~ s/((?:^__DATA__\r?\n).*)//ms;

    my $line = 1;
    if ($$ref =~ /^=(?:head\d|pod|begin|item|over|for|back|end|cut)\b/) {
        $$ref = "\n$$ref";
        $line--;
    }
    $$ref =~ s{(
	(.*?\n)
	(?:=(?:head\d|pod|begin|item|over|for|back|end)\b
    .*?\n)
	(?:=cut[\t ]*[\r\n]*?|\Z)
	(\r?\n)?
    )}{
	my ($pre, $post) = ($2, $3);
        "$pre#line " . (
	    $line += ( () = ( $1 =~ /\n/g ) )
	) . $post;
    }gsex;

    $$ref =~ s{^=encoding\s+\S+\s*$}{\n}mg;

    $$ref = '#line 1 "' . ($filename) . "\"\n" . $$ref
        if length $filename;
    $$ref =~ s/^#line 1 (.*\n)(#!.*\n)/$2#line 2 $1/g;
    $$ref .= $data;
}

1;

#line 85
FILE   eda5919c/PAR/Heavy.pm  #line 1 "/home/pmarup/perl5/lib/perl5/PAR/Heavy.pm"
package PAR::Heavy;
$PAR::Heavy::VERSION = '0.12';

#line 17

########################################################################
# Dynamic inclusion of XS modules

my ($bootstrap, $dl_findfile);  # Caches for code references
my ($cache_key);                # The current file to find
my $is_insensitive_fs = (
    -s $0
        and (-s lc($0) || -1) == (-s uc($0) || -1)
        and (-s lc($0) || -1) == -s $0
);

# Adds pre-hooks to Dynaloader's key methods
sub _init_dynaloader {
    return if $bootstrap;
    return unless eval { require DynaLoader; DynaLoader::dl_findfile(); 1 };

    $bootstrap   = \&DynaLoader::bootstrap;
    $dl_findfile = \&DynaLoader::dl_findfile;

    local $^W;
    *{'DynaLoader::dl_expandspec'}  = sub { return };
    *{'DynaLoader::bootstrap'}      = \&_bootstrap;
    *{'DynaLoader::dl_findfile'}    = \&_dl_findfile;
}

# Return the cached location of .dll inside PAR first, if possible.
sub _dl_findfile {
    return $FullCache{$cache_key} if exists $FullCache{$cache_key};
    if ($is_insensitive_fs) {
        # We have a case-insensitive filesystem...
        my ($key) = grep { lc($_) eq lc($cache_key) } keys %FullCache;
        return $FullCache{$key} if defined $key;
    }
    return $dl_findfile->(@_);
}

# Find and extract .dll from PAR files for a given dynamic module.
sub _bootstrap {
    my (@args) = @_;
    my ($module) = $args[0] or return;

    my @modparts = split(/::/, $module);
    my $modfname = $modparts[-1];

    $modfname = &DynaLoader::mod2fname(\@modparts)
        if defined &DynaLoader::mod2fname;

    if (($^O eq 'NetWare') && (length($modfname) > 8)) {
        $modfname = substr($modfname, 0, 8);
    }

    my $modpname = join((($^O eq 'MacOS') ? ':' : '/'), @modparts);
    my $file = $cache_key = "auto/$modpname/$modfname.$DynaLoader::dl_dlext";

    if ($FullCache{$file}) {
        # TODO: understand
        local $DynaLoader::do_expand = 1;
        return $bootstrap->(@args);
    }

    my $member;
    # First, try to find things in the preferentially loaded PARs:
    $member = PAR::_find_par_internals([@PAR::PAR_INC], undef, $file, 1)
      if defined &PAR::_find_par_internals;

    # If that failed to find the dll, let DynaLoader (try or) throw an error
    unless ($member) { 
        my $filename = eval { $bootstrap->(@args) };
        return $filename if not $@ and defined $filename;

        # Now try the fallback pars
        $member = PAR::_find_par_internals([@PAR::PAR_INC_LAST], undef, $file, 1)
          if defined &PAR::_find_par_internals;

        # If that fails, let dynaloader have another go JUST to throw an error
        # While this may seem wasteful, nothing really matters once we fail to
        # load shared libraries!
        unless ($member) { 
            return $bootstrap->(@args);
        }
    }

    $FullCache{$file} = _dl_extract($member, $file);

    # Now extract all associated shared objs in the same auto/ dir
    # XXX: shouldn't this also set $FullCache{...} for those files?
    my $first = $member->fileName;
    my $path_pattern = $first;
    $path_pattern =~ s{[^/]*$}{};
    if ($PAR::LastAccessedPAR) {
        foreach my $member ( $PAR::LastAccessedPAR->members ) {
            next if $member->isDirectory;

            my $name = $member->fileName;
            next if $name eq $first;
            next unless $name =~ m{^/?\Q$path_pattern\E\/[^/]*\.\Q$DynaLoader::dl_dlext\E[^/]*$};
            $name =~ s{.*/}{};
            _dl_extract($member, $file, $name);
        }
    }

    local $DynaLoader::do_expand = 1;
    return $bootstrap->(@args);
}

sub _dl_extract {
    my ($member, $file, $name) = @_;

    require File::Spec;
    require File::Temp;

    my ($fh, $filename);

    # fix borked tempdir from earlier versions
    if ($ENV{PAR_TEMP} and -e $ENV{PAR_TEMP} and !-d $ENV{PAR_TEMP}) {
        unlink($ENV{PAR_TEMP});
        mkdir($ENV{PAR_TEMP}, 0755);
    }

    if ($ENV{PAR_CLEAN} and !$name) {
        ($fh, $filename) = File::Temp::tempfile(
            DIR         => ($ENV{PAR_TEMP} || File::Spec->tmpdir),
            SUFFIX      => ".$DynaLoader::dl_dlext",
            UNLINK      => ($^O ne 'MSWin32' and $^O !~ /hpux/),
        );
        ($filename) = $filename =~ /^([\x20-\xff]+)$/;
    }
    else {
        $filename = File::Spec->catfile(
            ($ENV{PAR_TEMP} || File::Spec->tmpdir),
            ($name || ($member->crc32String . ".$DynaLoader::dl_dlext"))
        );
        ($filename) = $filename =~ /^([\x20-\xff]+)$/;

        open $fh, '>', $filename or die $!
            unless -r $filename and -e _
                and -s _ == $member->uncompressedSize;
    }

    if ($fh) {
        binmode($fh);
        $member->extractToFileHandle($fh);
        close $fh;
        chmod 0750, $filename;
    }

    return $filename;
}

1;

#line 197
FILE   98c3b3f5/PAR/SetupProgname.pm  �#line 1 "/home/pmarup/perl5/lib/perl5/PAR/SetupProgname.pm"
package PAR::SetupProgname;
$PAR::SetupProgname::VERSION = '1.002';

use 5.006;
use strict;
use warnings;
use Config ();

#line 26

# for PAR internal use only!
our $Progname = $ENV{PAR_PROGNAME} || $0;

# same code lives in PAR::Packer's par.pl!
sub set_progname {
    require File::Spec;

    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $Progname = $1;
    }
    $Progname = $0 if not defined $Progname;

    if (( () = File::Spec->splitdir($Progname) ) > 1 or !$ENV{PAR_PROGNAME}) {
        if (open my $fh, $Progname) {
            return if -s $fh;
        }
        if (-s "$Progname$Config::Config{_exe}") {
            $Progname .= $Config::Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config::Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        my $name = File::Spec->catfile($dir, "$Progname$Config::Config{_exe}");
        if (-s $name) { $Progname = $name; last }
        $name = File::Spec->catfile($dir, "$Progname");
        if (-s $name) { $Progname = $name; last }
    }
}


1;

__END__

#line 94

FILE   e7500f63/PAR/SetupTemp.pm  #line 1 "/home/pmarup/perl5/lib/perl5/PAR/SetupTemp.pm"
package PAR::SetupTemp;
$PAR::SetupTemp::VERSION = '1.002';

use 5.006;
use strict;
use warnings;

use Fcntl ':mode';

use PAR::SetupProgname;

#line 31

# for PAR internal use only!
our $PARTemp;

# name of the canary file
our $Canary = "_CANARY_.txt";
# how much to "date back" the canary file (in seconds)
our $CanaryDateBack = 24 * 3600;        # 1 day

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::Packer's par.pl as _set_par_temp!
sub set_par_temp_env {
    PAR::SetupProgname::set_progname()
      unless defined $PAR::SetupProgname::Progname;

    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $PARTemp = $1;
        return;
    }

    my $stmpdir = _get_par_user_tempdir();
    die "unable to create cache directory" unless $stmpdir;

    require File::Spec;
      if (!$ENV{PAR_CLEAN} and my $mtime = (stat($PAR::SetupProgname::Progname))[9]) {
          my $ctx = _get_digester();

          # Workaround for bug in Digest::SHA 5.38 and 5.39
          my $sha_version = eval { $Digest::SHA::VERSION } || 0;
          if ($sha_version eq '5.38' or $sha_version eq '5.39') {
              $ctx->addfile($PAR::SetupProgname::Progname, "b") if ($ctx);
          }
          else {
              if ($ctx and open(my $fh, "<$PAR::SetupProgname::Progname")) {
                  binmode($fh);
                  $ctx->addfile($fh);
                  close($fh);
              }
          }

          $stmpdir = File::Spec->catdir(
              $stmpdir,
              "cache-" . ( $ctx ? $ctx->hexdigest : $mtime )
          );
      }
      else {
          $ENV{PAR_CLEAN} = 1;
          $stmpdir = File::Spec->catdir($stmpdir, "temp-$$");
      }

      $ENV{PAR_TEMP} = $stmpdir;
    mkdir $stmpdir, 0700;

    $PARTemp = $1 if defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

# Find any digester
# Used in PAR::Repository::Client!
sub _get_digester {
  my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
         || eval { require Digest::SHA1; Digest::SHA1->new }
         || eval { require Digest::MD5; Digest::MD5->new };
  return $ctx;
}

# find the per-user temporary directory (eg /tmp/par-$USER)
# Used in PAR::Repository::Client!
sub _get_par_user_tempdir {
  my $username = _find_username();
  my $temp_path;
  foreach my $path (
    (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
      qw( C:\\TEMP /tmp . )
  ) {
    next unless defined $path and -d $path and -w $path;
    # create a temp directory that is unique per user
    # NOTE: $username may be in an unspecified charset/encoding;
    # use a name that hopefully works for all of them;
    # also avoid problems with platform-specific meta characters in the name
    $temp_path = File::Spec->catdir($path, "par-".unpack("H*", $username));
    ($temp_path) = $temp_path =~ /^(.*)$/s;
    unless (mkdir($temp_path, 0700) || $!{EEXIST}) {
      warn "creation of private subdirectory $temp_path failed (errno=$!)"; 
      return;
    }

    unless ($^O eq 'MSWin32') {
        my @st;
        unless (@st = lstat($temp_path)) {
          warn "stat of private subdirectory $temp_path failed (errno=$!)";
          return;
        }
        if (!S_ISDIR($st[2])
            || $st[4] != $<
            || ($st[2] & 0777) != 0700 ) {
          warn "private subdirectory $temp_path is unsafe (please remove it and retry your operation)";
          return;
        }
    }

    last;
  }
  return $temp_path;
}

# tries hard to find out the name of the current user
sub _find_username {
  my $username;
  my $pwuid;
  # does not work everywhere:
  eval {($pwuid) = getpwuid($>) if defined $>;};

  if ( defined(&Win32::LoginName) ) {
    $username = &Win32::LoginName;
  }
  elsif (defined $pwuid) {
    $username = $pwuid;
  }
  else {
    $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
  }

  return $username;
}

1;

__END__

#line 191

FILE   acca038f/Data/Dumper.pm  V�#line 1 "/home/pmarup/perl5/lib/perl5/x86_64-linux-thread-multi/Data/Dumper.pm"
#
# Data/Dumper.pm
#
# convert perl data structures into perl syntax suitable for both printing
# and eval
#
# Documentation at the __END__
#

package Data::Dumper;

BEGIN {
    $VERSION = '2.154'; # Don't forget to set version and release
}               # date in POD below!

#$| = 1;

use 5.006_001;
require Exporter;
require overload;

use Carp;

BEGIN {
    @ISA = qw(Exporter);
    @EXPORT = qw(Dumper);
    @EXPORT_OK = qw(DumperX);

    # if run under miniperl, or otherwise lacking dynamic loading,
    # XSLoader should be attempted to load, or the pure perl flag
    # toggled on load failure.
    eval {
        require XSLoader;
        XSLoader::load( 'Data::Dumper' );
        1
    }
    or $Useperl = 1;
}

# module vars and their defaults
$Indent     = 2         unless defined $Indent;
$Purity     = 0         unless defined $Purity;
$Pad        = ""        unless defined $Pad;
$Varname    = "VAR"     unless defined $Varname;
$Useqq      = 0         unless defined $Useqq;
$Terse      = 0         unless defined $Terse;
$Freezer    = ""        unless defined $Freezer;
$Toaster    = ""        unless defined $Toaster;
$Deepcopy   = 0         unless defined $Deepcopy;
$Quotekeys  = 1         unless defined $Quotekeys;
$Bless      = "bless"   unless defined $Bless;
#$Expdepth   = 0         unless defined $Expdepth;
$Maxdepth   = 0         unless defined $Maxdepth;
$Pair       = ' => '    unless defined $Pair;
$Useperl    = 0         unless defined $Useperl;
$Sortkeys   = 0         unless defined $Sortkeys;
$Deparse    = 0         unless defined $Deparse;
$Sparseseen = 0         unless defined $Sparseseen;
$Maxrecurse = 1000      unless defined $Maxrecurse;

#
# expects an arrayref of values to be dumped.
# can optionally pass an arrayref of names for the values.
# names must have leading $ sign stripped. begin the name with *
# to cause output of arrays and hashes rather than refs.
#
sub new {
  my($c, $v, $n) = @_;

  croak "Usage:  PACKAGE->new(ARRAYREF, [ARRAYREF])"
    unless (defined($v) && (ref($v) eq 'ARRAY'));
  $n = [] unless (defined($n) && (ref($n) eq 'ARRAY'));

  my($s) = {
        level      => 0,           # current recursive depth
        indent     => $Indent,     # various styles of indenting
        pad        => $Pad,        # all lines prefixed by this string
        xpad       => "",          # padding-per-level
        apad       => "",          # added padding for hash keys n such
        sep        => "",          # list separator
        pair       => $Pair,    # hash key/value separator: defaults to ' => '
        seen       => {},          # local (nested) refs (id => [name, val])
        todump     => $v,          # values to dump []
        names      => $n,          # optional names for values []
        varname    => $Varname,    # prefix to use for tagging nameless ones
        purity     => $Purity,     # degree to which output is evalable
        useqq      => $Useqq,      # use "" for strings (backslashitis ensues)
        terse      => $Terse,      # avoid name output (where feasible)
        freezer    => $Freezer,    # name of Freezer method for objects
        toaster    => $Toaster,    # name of method to revive objects
        deepcopy   => $Deepcopy,   # do not cross-ref, except to stop recursion
        quotekeys  => $Quotekeys,  # quote hash keys
        'bless'    => $Bless,    # keyword to use for "bless"
#        expdepth   => $Expdepth,   # cutoff depth for explicit dumping
        maxdepth   => $Maxdepth,   # depth beyond which we give up
	maxrecurse => $Maxrecurse, # depth beyond which we abort
        useperl    => $Useperl,    # use the pure Perl implementation
        sortkeys   => $Sortkeys,   # flag or filter for sorting hash keys
        deparse    => $Deparse,    # use B::Deparse for coderefs
        noseen     => $Sparseseen, # do not populate the seen hash unless necessary
       };

  if ($Indent > 0) {
    $s->{xpad} = "  ";
    $s->{sep} = "\n";
  }
  return bless($s, $c);
}

# Packed numeric addresses take less memory. Plus pack is faster than sprintf

# Most users of current versions of Data::Dumper will be 5.008 or later.
# Anyone on 5.6.1 and 5.6.2 upgrading will be rare (particularly judging by
# the bug reports from users on those platforms), so for the common case avoid
# complexity, and avoid even compiling the unneeded code.

sub init_refaddr_format {
}

sub format_refaddr {
    require Scalar::Util;
    pack "J", Scalar::Util::refaddr(shift);
};

if ($] < 5.008) {
    eval <<'EOC' or die;
    no warnings 'redefine';
    my $refaddr_format;
    sub init_refaddr_format {
        require Config;
        my $f = $Config::Config{uvxformat};
        $f =~ tr/"//d;
        $refaddr_format = "0x%" . $f;
    }

    sub format_refaddr {
        require Scalar::Util;
        sprintf $refaddr_format, Scalar::Util::refaddr(shift);
    }

    1
EOC
}

#
# add-to or query the table of already seen references
#
sub Seen {
  my($s, $g) = @_;
  if (defined($g) && (ref($g) eq 'HASH'))  {
    init_refaddr_format();
    my($k, $v, $id);
    while (($k, $v) = each %$g) {
      if (defined $v) {
        if (ref $v) {
          $id = format_refaddr($v);
          if ($k =~ /^[*](.*)$/) {
            $k = (ref $v eq 'ARRAY') ? ( "\\\@" . $1 ) :
                 (ref $v eq 'HASH')  ? ( "\\\%" . $1 ) :
                 (ref $v eq 'CODE')  ? ( "\\\&" . $1 ) :
                 (   "\$" . $1 ) ;
          }
          elsif ($k !~ /^\$/) {
            $k = "\$" . $k;
          }
          $s->{seen}{$id} = [$k, $v];
        }
        else {
          carp "Only refs supported, ignoring non-ref item \$$k";
        }
      }
      else {
        carp "Value of ref must be defined; ignoring undefined item \$$k";
      }
    }
    return $s;
  }
  else {
    return map { @$_ } values %{$s->{seen}};
  }
}

#
# set or query the values to be dumped
#
sub Values {
  my($s, $v) = @_;
  if (defined($v)) {
    if (ref($v) eq 'ARRAY')  {
      $s->{todump} = [@$v];        # make a copy
      return $s;
    }
    else {
      croak "Argument to Values, if provided, must be array ref";
    }
  }
  else {
    return @{$s->{todump}};
  }
}

#
# set or query the names of the values to be dumped
#
sub Names {
  my($s, $n) = @_;
  if (defined($n)) {
    if (ref($n) eq 'ARRAY') {
      $s->{names} = [@$n];         # make a copy
      return $s;
    }
    else {
      croak "Argument to Names, if provided, must be array ref";
    }
  }
  else {
    return @{$s->{names}};
  }
}

sub DESTROY {}

sub Dump {
    return &Dumpxs
    unless $Data::Dumper::Useperl || (ref($_[0]) && $_[0]->{useperl}) ||
           $Data::Dumper::Deparse || (ref($_[0]) && $_[0]->{deparse});
    return &Dumpperl;
}

#
# dump the refs in the current dumper object.
# expects same args as new() if called via package name.
#
sub Dumpperl {
  my($s) = shift;
  my(@out, $val, $name);
  my($i) = 0;
  local(@post);
  init_refaddr_format();

  $s = $s->new(@_) unless ref $s;

  for $val (@{$s->{todump}}) {
    @post = ();
    $name = $s->{names}[$i++];
    $name = $s->_refine_name($name, $val, $i);

    my $valstr;
    {
      local($s->{apad}) = $s->{apad};
      $s->{apad} .= ' ' x (length($name) + 3) if $s->{indent} >= 2 and !$s->{terse};
      $valstr = $s->_dump($val, $name);
    }

    $valstr = "$name = " . $valstr . ';' if @post or !$s->{terse};
    my $out = $s->_compose_out($valstr, \@post);

    push @out, $out;
  }
  return wantarray ? @out : join('', @out);
}

# wrap string in single quotes (escaping if needed)
sub _quote {
    my $val = shift;
    $val =~ s/([\\\'])/\\$1/g;
    return  "'" . $val .  "'";
}

# Old Perls (5.14-) have trouble resetting vstring magic when it is no
# longer valid.
use constant _bad_vsmg => defined &_vstring && (_vstring(~v0)||'') eq "v0";

#
# twist, toil and turn;
# and recurse, of course.
# sometimes sordidly;
# and curse if no recourse.
#
sub _dump {
  my($s, $val, $name) = @_;
  my($out, $type, $id, $sname);

  $type = ref $val;
  $out = "";

  if ($type) {

    # Call the freezer method if it's specified and the object has the
    # method.  Trap errors and warn() instead of die()ing, like the XS
    # implementation.
    my $freezer = $s->{freezer};
    if ($freezer and UNIVERSAL::can($val, $freezer)) {
      eval { $val->$freezer() };
      warn "WARNING(Freezer method call failed): $@" if $@;
    }

    require Scalar::Util;
    my $realpack = Scalar::Util::blessed($val);
    my $realtype = $realpack ? Scalar::Util::reftype($val) : ref $val;
    $id = format_refaddr($val);

    # Note: By this point $name is always defined and of non-zero length.
    # Keep a tab on it so that we do not fall into recursive pit.
    if (exists $s->{seen}{$id}) {
      if ($s->{purity} and $s->{level} > 0) {
        $out = ($realtype eq 'HASH')  ? '{}' :
               ($realtype eq 'ARRAY') ? '[]' :
               'do{my $o}' ;
        push @post, $name . " = " . $s->{seen}{$id}[0];
      }
      else {
        $out = $s->{seen}{$id}[0];
        if ($name =~ /^([\@\%])/) {
          my $start = $1;
          if ($out =~ /^\\$start/) {
            $out = substr($out, 1);
          }
          else {
            $out = $start . '{' . $out . '}';
          }
        }
      }
      return $out;
    }
    else {
      # store our name
      $s->{seen}{$id} = [ (
          ($name =~ /^[@%]/)
            ? ('\\' . $name )
            : ($realtype eq 'CODE' and $name =~ /^[*](.*)$/)
              ? ('\\&' . $1 )
              : $name
        ), $val ];
    }
    my $no_bless = 0;
    my $is_regex = 0;
    if ( $realpack and ($] >= 5.009005 ? re::is_regexp($val) : $realpack eq 'Regexp') ) {
        $is_regex = 1;
        $no_bless = $realpack eq 'Regexp';
    }

    # If purity is not set and maxdepth is set, then check depth:
    # if we have reached maximum depth, return the string
    # representation of the thing we are currently examining
    # at this depth (i.e., 'Foo=ARRAY(0xdeadbeef)').
    if (!$s->{purity}
      and defined($s->{maxdepth})
      and $s->{maxdepth} > 0
      and $s->{level} >= $s->{maxdepth})
    {
      return qq['$val'];
    }

    # avoid recursing infinitely [perl #122111]
    if ($s->{maxrecurse} > 0
        and $s->{level} >= $s->{maxrecurse}) {
        die "Recursion limit of $s->{maxrecurse} exceeded";
    }

    # we have a blessed ref
    my ($blesspad);
    if ($realpack and !$no_bless) {
      $out = $s->{'bless'} . '( ';
      $blesspad = $s->{apad};
      $s->{apad} .= '       ' if ($s->{indent} >= 2);
    }

    $s->{level}++;
    my $ipad = $s->{xpad} x $s->{level};

    if ($is_regex) {
        my $pat;
        my $flags = "";
        if (defined(*re::regexp_pattern{CODE})) {
          ($pat, $flags) = re::regexp_pattern($val);
        }
        else {
          $pat = "$val";
        }
        $pat =~ s <(\\.)|/> { $1 || '\\/' }ge;
        $out .= "qr/$pat/$flags";
    }
    elsif ($realtype eq 'SCALAR' || $realtype eq 'REF'
    || $realtype eq 'VSTRING') {
      if ($realpack) {
        $out .= 'do{\\(my $o = ' . $s->_dump($$val, "\${$name}") . ')}';
      }
      else {
        $out .= '\\' . $s->_dump($$val, "\${$name}");
      }
    }
    elsif ($realtype eq 'GLOB') {
      $out .= '\\' . $s->_dump($$val, "*{$name}");
    }
    elsif ($realtype eq 'ARRAY') {
      my($pad, $mname);
      my($i) = 0;
      $out .= ($name =~ /^\@/) ? '(' : '[';
      $pad = $s->{sep} . $s->{pad} . $s->{apad};
      ($name =~ /^\@(.*)$/) ? ($mname = "\$" . $1) :
    # omit -> if $foo->[0]->{bar}, but not ${$foo->[0]}->{bar}
        ($name =~ /^\\?[\%\@\*\$][^{].*[]}]$/) ? ($mname = $name) :
        ($mname = $name . '->');
      $mname .= '->' if $mname =~ /^\*.+\{[A-Z]+\}$/;
      for my $v (@$val) {
        $sname = $mname . '[' . $i . ']';
        $out .= $pad . $ipad . '#' . $i
          if $s->{indent} >= 3;
        $out .= $pad . $ipad . $s->_dump($v, $sname);
        $out .= "," if $i++ < $#$val;
      }
      $out .= $pad . ($s->{xpad} x ($s->{level} - 1)) if $i;
      $out .= ($name =~ /^\@/) ? ')' : ']';
    }
    elsif ($realtype eq 'HASH') {
      my ($k, $v, $pad, $lpad, $mname, $pair);
      $out .= ($name =~ /^\%/) ? '(' : '{';
      $pad = $s->{sep} . $s->{pad} . $s->{apad};
      $lpad = $s->{apad};
      $pair = $s->{pair};
      ($name =~ /^\%(.*)$/) ? ($mname = "\$" . $1) :
    # omit -> if $foo->[0]->{bar}, but not ${$foo->[0]}->{bar}
        ($name =~ /^\\?[\%\@\*\$][^{].*[]}]$/) ? ($mname = $name) :
        ($mname = $name . '->');
      $mname .= '->' if $mname =~ /^\*.+\{[A-Z]+\}$/;
      my $sortkeys = defined($s->{sortkeys}) ? $s->{sortkeys} : '';
      my $keys = [];
      if ($sortkeys) {
        if (ref($s->{sortkeys}) eq 'CODE') {
          $keys = $s->{sortkeys}($val);
          unless (ref($keys) eq 'ARRAY') {
            carp "Sortkeys subroutine did not return ARRAYREF";
            $keys = [];
          }
        }
        else {
          $keys = [ sort keys %$val ];
        }
      }

      # Ensure hash iterator is reset
      keys(%$val);

      my $key;
      while (($k, $v) = ! $sortkeys ? (each %$val) :
         @$keys ? ($key = shift(@$keys), $val->{$key}) :
         () )
      {
        my $nk = $s->_dump($k, "");

        # _dump doesn't quote numbers of this form
        if ($s->{quotekeys} && $nk =~ /^(?:0|-?[1-9][0-9]{0,8})\z/) {
          $nk = $s->{useqq} ? qq("$nk") : qq('$nk');
        }
        elsif (!$s->{quotekeys} and $nk =~ /^[\"\']([A-Za-z_]\w*)[\"\']$/) {
          $nk = $1
        }

        $sname = $mname . '{' . $nk . '}';
        $out .= $pad . $ipad . $nk . $pair;

        # temporarily alter apad
        $s->{apad} .= (" " x (length($nk) + 4))
          if $s->{indent} >= 2;
        $out .= $s->_dump($val->{$k}, $sname) . ",";
        $s->{apad} = $lpad
          if $s->{indent} >= 2;
      }
      if (substr($out, -1) eq ',') {
        chop $out;
        $out .= $pad . ($s->{xpad} x ($s->{level} - 1));
      }
      $out .= ($name =~ /^\%/) ? ')' : '}';
    }
    elsif ($realtype eq 'CODE') {
      if ($s->{deparse}) {
        require B::Deparse;
        my $sub =  'sub ' . (B::Deparse->new)->coderef2text($val);
        $pad    =  $s->{sep} . $s->{pad} . $s->{apad} . $s->{xpad} x ($s->{level} - 1);
        $sub    =~ s/\n/$pad/gse;
        $out   .=  $sub;
      }
      else {
        $out .= 'sub { "DUMMY" }';
        carp "Encountered CODE ref, using dummy placeholder" if $s->{purity};
      }
    }
    else {
      croak "Can't handle '$realtype' type";
    }

    if ($realpack and !$no_bless) { # we have a blessed ref
      $out .= ', ' . _quote($realpack) . ' )';
      $out .= '->' . $s->{toaster} . '()'
        if $s->{toaster} ne '';
      $s->{apad} = $blesspad;
    }
    $s->{level}--;
  }
  else {                                 # simple scalar

    my $ref = \$_[1];
    my $v;
    # first, catalog the scalar
    if ($name ne '') {
      $id = format_refaddr($ref);
      if (exists $s->{seen}{$id}) {
        if ($s->{seen}{$id}[2]) {
          $out = $s->{seen}{$id}[0];
          #warn "[<$out]\n";
          return "\${$out}";
        }
      }
      else {
        #warn "[>\\$name]\n";
        $s->{seen}{$id} = ["\\$name", $ref];
      }
    }
    $ref = \$val;
    if (ref($ref) eq 'GLOB') {  # glob
      my $name = substr($val, 1);
      if ($name =~ /^[A-Za-z_][\w:]*$/ && $name ne 'main::') {
        $name =~ s/^main::/::/;
        $sname = $name;
      }
      else {
        $sname = $s->_dump(
          $name eq 'main::' || $] < 5.007 && $name eq "main::\0"
            ? ''
            : $name,
          "",
        );
        $sname = '{' . $sname . '}';
      }
      if ($s->{purity}) {
        my $k;
        local ($s->{level}) = 0;
        for $k (qw(SCALAR ARRAY HASH)) {
          my $gval = *$val{$k};
          next unless defined $gval;
          next if $k eq "SCALAR" && ! defined $$gval;  # always there

          # _dump can push into @post, so we hold our place using $postlen
          my $postlen = scalar @post;
          $post[$postlen] = "\*$sname = ";
          local ($s->{apad}) = " " x length($post[$postlen]) if $s->{indent} >= 2;
          $post[$postlen] .= $s->_dump($gval, "\*$sname\{$k\}");
        }
      }
      $out .= '*' . $sname;
    }
    elsif (!defined($val)) {
      $out .= "undef";
    }
    elsif (defined &_vstring and $v = _vstring($val)
      and !_bad_vsmg || eval $v eq $val) {
      $out .= $v;
    }
    elsif (!defined &_vstring
       and ref $ref eq 'VSTRING' || eval{Scalar::Util::isvstring($val)}) {
      $out .= sprintf "%vd", $val;
    }
    # \d here would treat "1\x{660}" as a safe decimal number
    elsif ($val =~ /^(?:0|-?[1-9][0-9]{0,8})\z/) { # safe decimal number
      $out .= $val;
    }
    else {                 # string
      if ($s->{useqq} or $val =~ tr/\0-\377//c) {
        # Fall back to qq if there's Unicode
        $out .= qquote($val, $s->{useqq});
      }
      else {
        $out .= _quote($val);
      }
    }
  }
  if ($id) {
    # if we made it this far, $id was added to seen list at current
    # level, so remove it to get deep copies
    if ($s->{deepcopy}) {
      delete($s->{seen}{$id});
    }
    elsif ($name) {
      $s->{seen}{$id}[2] = 1;
    }
  }
  return $out;
}

#
# non-OO style of earlier version
#
sub Dumper {
  return Data::Dumper->Dump([@_]);
}

# compat stub
sub DumperX {
  return Data::Dumper->Dumpxs([@_], []);
}

#
# reset the "seen" cache
#
sub Reset {
  my($s) = shift;
  $s->{seen} = {};
  return $s;
}

sub Indent {
  my($s, $v) = @_;
  if (defined($v)) {
    if ($v == 0) {
      $s->{xpad} = "";
      $s->{sep} = "";
    }
    else {
      $s->{xpad} = "  ";
      $s->{sep} = "\n";
    }
    $s->{indent} = $v;
    return $s;
  }
  else {
    return $s->{indent};
  }
}

sub Pair {
    my($s, $v) = @_;
    defined($v) ? (($s->{pair} = $v), return $s) : $s->{pair};
}

sub Pad {
  my($s, $v) = @_;
  defined($v) ? (($s->{pad} = $v), return $s) : $s->{pad};
}

sub Varname {
  my($s, $v) = @_;
  defined($v) ? (($s->{varname} = $v), return $s) : $s->{varname};
}

sub Purity {
  my($s, $v) = @_;
  defined($v) ? (($s->{purity} = $v), return $s) : $s->{purity};
}

sub Useqq {
  my($s, $v) = @_;
  defined($v) ? (($s->{useqq} = $v), return $s) : $s->{useqq};
}

sub Terse {
  my($s, $v) = @_;
  defined($v) ? (($s->{terse} = $v), return $s) : $s->{terse};
}

sub Freezer {
  my($s, $v) = @_;
  defined($v) ? (($s->{freezer} = $v), return $s) : $s->{freezer};
}

sub Toaster {
  my($s, $v) = @_;
  defined($v) ? (($s->{toaster} = $v), return $s) : $s->{toaster};
}

sub Deepcopy {
  my($s, $v) = @_;
  defined($v) ? (($s->{deepcopy} = $v), return $s) : $s->{deepcopy};
}

sub Quotekeys {
  my($s, $v) = @_;
  defined($v) ? (($s->{quotekeys} = $v), return $s) : $s->{quotekeys};
}

sub Bless {
  my($s, $v) = @_;
  defined($v) ? (($s->{'bless'} = $v), return $s) : $s->{'bless'};
}

sub Maxdepth {
  my($s, $v) = @_;
  defined($v) ? (($s->{'maxdepth'} = $v), return $s) : $s->{'maxdepth'};
}

sub Maxrecurse {
  my($s, $v) = @_;
  defined($v) ? (($s->{'maxrecurse'} = $v), return $s) : $s->{'maxrecurse'};
}

sub Useperl {
  my($s, $v) = @_;
  defined($v) ? (($s->{'useperl'} = $v), return $s) : $s->{'useperl'};
}

sub Sortkeys {
  my($s, $v) = @_;
  defined($v) ? (($s->{'sortkeys'} = $v), return $s) : $s->{'sortkeys'};
}

sub Deparse {
  my($s, $v) = @_;
  defined($v) ? (($s->{'deparse'} = $v), return $s) : $s->{'deparse'};
}

sub Sparseseen {
  my($s, $v) = @_;
  defined($v) ? (($s->{'noseen'} = $v), return $s) : $s->{'noseen'};
}

# used by qquote below
my %esc = (
    "\a" => "\\a",
    "\b" => "\\b",
    "\t" => "\\t",
    "\n" => "\\n",
    "\f" => "\\f",
    "\r" => "\\r",
    "\e" => "\\e",
);

# put a string value in double quotes
sub qquote {
  local($_) = shift;
  s/([\\\"\@\$])/\\$1/g;
  my $bytes; { use bytes; $bytes = length }
  s/([[:^ascii:]])/'\x{'.sprintf("%x",ord($1)).'}'/ge if $bytes > length;
  return qq("$_") unless
    /[^ !"\#\$%&'()*+,\-.\/0-9:;<=>?\@A-Z[\\\]^_`a-z{|}~]/;  # fast exit

  my $high = shift || "";
  s/([\a\b\t\n\f\r\e])/$esc{$1}/g;

  if (ord('^')==94)  { # ascii
    # no need for 3 digits in escape for these
    s/([\0-\037])(?!\d)/'\\'.sprintf('%o',ord($1))/eg;
    s/([\0-\037\177])/'\\'.sprintf('%03o',ord($1))/eg;
    # all but last branch below not supported --BEHAVIOR SUBJECT TO CHANGE--
    if ($high eq "iso8859") {
      s/([\200-\240])/'\\'.sprintf('%o',ord($1))/eg;
    } elsif ($high eq "utf8") {
#     use utf8;
#     $str =~ s/([^\040-\176])/sprintf "\\x{%04x}", ord($1)/ge;
    } elsif ($high eq "8bit") {
        # leave it as it is
    } else {
      s/([\200-\377])/'\\'.sprintf('%03o',ord($1))/eg;
      s/([^\040-\176])/sprintf "\\x{%04x}", ord($1)/ge;
    }
  }
  else { # ebcdic
      s{([^ !"\#\$%&'()*+,\-.\/0-9:;<=>?\@A-Z[\\\]^_`a-z{|}~])(?!\d)}
       {my $v = ord($1); '\\'.sprintf(($v <= 037 ? '%o' : '%03o'), $v)}eg;
      s{([^ !"\#\$%&'()*+,\-.\/0-9:;<=>?\@A-Z[\\\]^_`a-z{|}~])}
       {'\\'.sprintf('%03o',ord($1))}eg;
  }

  return qq("$_");
}

# helper sub to sort hash keys in Perl < 5.8.0 where we don't have
# access to sortsv() from XS
sub _sortkeys { [ sort keys %{$_[0]} ] }

sub _refine_name {
    my $s = shift;
    my ($name, $val, $i) = @_;
    if (defined $name) {
      if ($name =~ /^[*](.*)$/) {
        if (defined $val) {
            $name = (ref $val eq 'ARRAY') ? ( "\@" . $1 ) :
              (ref $val eq 'HASH')  ? ( "\%" . $1 ) :
              (ref $val eq 'CODE')  ? ( "\*" . $1 ) :
              ( "\$" . $1 ) ;
        }
        else {
          $name = "\$" . $1;
        }
      }
      elsif ($name !~ /^\$/) {
        $name = "\$" . $name;
      }
    }
    else { # no names provided
      $name = "\$" . $s->{varname} . $i;
    }
    return $name;
}

sub _compose_out {
    my $s = shift;
    my ($valstr, $postref) = @_;
    my $out = "";
    $out .= $s->{pad} . $valstr . $s->{sep};
    if (@{$postref}) {
        $out .= $s->{pad} .
            join(';' . $s->{sep} . $s->{pad}, @{$postref}) .
            ';' .
            $s->{sep};
    }
    return $out;
}

1;
__END__

#line 1431
FILE   47eb8434/List/Util.pm  �#line 1 "/home/pmarup/perl5/lib/perl5/x86_64-linux-thread-multi/List/Util.pm"
# Copyright (c) 1997-2009 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Maintained since 2013 by Paul Evans <leonerd@leonerd.org.uk>

package List::Util;

use strict;
require Exporter;

our @ISA        = qw(Exporter);
our @EXPORT_OK  = qw(
  all any first min max minstr maxstr none notall product reduce sum sum0 shuffle
  pairs unpairs pairkeys pairvalues pairmap pairgrep pairfirst
);
our $VERSION    = "1.42";
our $XS_VERSION = $VERSION;
$VERSION    = eval $VERSION;

require XSLoader;
XSLoader::load('List::Util', $XS_VERSION);

sub import
{
  my $pkg = caller;

  # (RT88848) Touch the caller's $a and $b, to avoid the warning of
  #   Name "main::a" used only once: possible typo" warning
  no strict 'refs';
  ${"${pkg}::a"} = ${"${pkg}::a"};
  ${"${pkg}::b"} = ${"${pkg}::b"};

  goto &Exporter::import;
}

# For objects returned by pairs()
sub List::Util::_Pair::key   { shift->[0] }
sub List::Util::_Pair::value { shift->[1] }

1;

__END__

#line 63

#line 69

#line 248

#line 284

#line 444

#line 448

#line 458

#line 531
FILE   5b1228fe/Scalar/Util.pm  �#line 1 "/home/pmarup/perl5/lib/perl5/x86_64-linux-thread-multi/Scalar/Util.pm"
# Copyright (c) 1997-2007 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Maintained since 2013 by Paul Evans <leonerd@leonerd.org.uk>

package Scalar::Util;

use strict;
require Exporter;

our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(
  blessed refaddr reftype weaken unweaken isweak

  dualvar isdual isvstring looks_like_number openhandle readonly set_prototype
  tainted
);
our $VERSION    = "1.42";
$VERSION   = eval $VERSION;

require List::Util; # List::Util loads the XS
List::Util->VERSION( $VERSION ); # Ensure we got the right XS version (RT#100863)

our @EXPORT_FAIL;

unless (defined &weaken) {
  push @EXPORT_FAIL, qw(weaken);
}
unless (defined &isweak) {
  push @EXPORT_FAIL, qw(isweak isvstring);
}
unless (defined &isvstring) {
  push @EXPORT_FAIL, qw(isvstring);
}

sub export_fail {
  if (grep { /^(?:weaken|isweak)$/ } @_ ) {
    require Carp;
    Carp::croak("Weak references are not implemented in the version of perl");
  }

  if (grep { /^isvstring$/ } @_ ) {
    require Carp;
    Carp::croak("Vstrings are not implemented in the version of perl");
  }

  @_;
}

# set_prototype has been moved to Sub::Util with a different interface
sub set_prototype(&$)
{
  my ( $code, $proto ) = @_;
  return Sub::Util::set_prototype( $proto, $code );
}

1;

__END__

#line 83

#line 369
FILE   #9116e9a9/auto/Data/Dumper/Dumper.so 2�ELF          >    �!      @                @ 8  @ % "                               �      �                    ��      ��      ��      �      �                    @�      @�      @�      �      �                   �      �      �      $       $              P�td   Ȉ      Ȉ      Ȉ      D       D              Q�td                                                           GNU 	_'��T ch�FM5F���       ]         ��p�A	]   `   c   ��(x��|CE�����qX������w�,H�                             	 P                                   2                     �                     �                     �                     +                     �                     y                     d                      |                                            +                       �                                          +                     z                     �                     �                     �                     L                     =                     �                     Q                      �                     �                     W                     �                     o                     
                     Y                     �                     Q                     �                     �                      �                        "                   �                     ?                     �                      �                                          �                     �                     �                     I                     %                     �                     h                     ~                     �                     �                     �                     k                     �                                          �                     �                     g                     �                     �                     e                                          �                     |                      �                                          -                     �                     �                      J                     �                                          X                     �                     �                      �                     �                     8                     �                     �                     x                     C                     �                     �                      �                                          �                                                               ]                     >                     ?     �"            C   ����              0   ��Џ                  (             7   ��Џ                  	 P                   ��              �     �j      �      �     �%             __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses boot_Data__Dumper Perl_Istack_sp_ptr Perl_Imarkstack_ptr_ptr Perl_Istack_base_ptr Perl_newSVpv Perl_new_version Perl_sv_derived_from Perl_vcmp XS_Data__Dumper_Dumpxs Perl_newXS_flags XS_Data__Dumper__vstring Perl_Iunitcheckav_ptr Perl_Iscopestack_ix_ptr Perl_call_list Perl_Isv_yes_ptr Perl_sv_2pv_flags Perl_form Perl_get_sv Perl_vstringify Perl_croak Perl_mg_find Perl_newSVpvn Perl_Isv_undef_ptr Perl_sv_2mortal Perl_croak_xs_usage Perl_sv_catpvn_flags Perl_sv_grow Perl_utf8_to_uvchr_buf Perl_utf8_to_uvchr PL_utf8skip __sprintf_chk __snprintf_chk Perl_hv_common_key_len Perl_av_fetch Perl_sv_catsv_flags Perl_av_push Perl_newSVsv Perl_warn_nocontext strlen Perl_safesysmalloc Perl_gv_fetchmeth Perl_push_scope Perl_Itmps_floor_ptr Perl_save_int Perl_Itmps_ix_ptr Perl_Imarkstack_max_ptr Perl_Istack_max_ptr Perl_call_method Perl_Ierrgv_ptr Perl_pop_scope Perl_mg_get Perl_sv_free2 Perl_sv_setiv Perl_newSV_type Perl_newRV Perl_sv_catpvf_nocontext strcpy Perl_sv_setsv_flags Perl_get_cv Perl_call_sv Perl_sv_free Perl_safesysfree Perl_stack_grow Perl_free_tmps Perl_sv_newmortal Perl_scan_vstring Perl_sv_eq Perl_Icurcop_ptr Perl_av_len Perl_newSViv memcpy Perl_hv_iterkeysv Perl_hv_iterval Perl_hv_iternext_flags Perl_instr Perl_sv_2iv_flags Perl_markstack_grow Perl_hv_iterinit Perl_sv_2bool Perl_Icompiling_ptr Perl_sv_cmp_locale Perl_sortsv __stack_chk_fail Perl_sv_cmp Perl_Ihints_ptr Perl_croak_nocontext Perl_Iop_ptr Perl_sv_insert_flags Perl_sv_setpvn Perl_av_clear Perl_dowantarray Perl_sv_backoff libc.so.6 _edata __bss_start _end GLIBC_2.3.4 GLIBC_2.4 GLIBC_2.2.5                                                                                                                                                                                                 &         ti	   H     ii
           `�                    h�                    p�                    x�                    ��                    ��                    ��                    ��                    ��                    ��                    ��                    ��                    ��                    ȍ                    Ѝ                    ؍                    ��                    �                    ��                    ��                      �         !           �         #           �         $           �         %            �         &           (�         '           0�         (           8�         `           @�         )           H�         *           P�         +           X�         ,           `�         -           h�         .           p�         /           x�         0           ��         1           ��         2           ��         3           ��         4           ��         5           ��         6           ��         7           ��         8           ��         9           Ȏ         :           Ў         ;           ؎         <           ��         =           �         ?           ��         @           ��         A            �         B           �         C           �         D           �         E            �         F           (�         G           0�         H           8�         I           @�         J           H�         K           P�         L           X�         M           `�         N           h�         O           p�         P           x�         Q           ��         R           ��         S           ��         T           ��         U           ��         V           ��         W           ��         X           ��         Y           ��         Z           ȏ         [           H���  �2  �h  H����5�p  �%�p  @ �%�p  h    ������%�p  h   ������%�p  h   ������%�p  h   �����%zp  h   �����%rp  h   �����%jp  h   �����%bp  h   �p����%Zp  h   �`����%Rp  h	   �P����%Jp  h
   �@����%Bp  h   �0����%:p  h   � ����%2p  h
p  h   ������%p  h   �����%�o  h   �����%�o  h   �����%�o  h   �����%�o  h   �p����%�o  h   �`����%�o  h   �P����%�o  h   �@����%�o  h   �0����%�o  h   � ����%�o  h   �����%�o  h   � ����%�o  h   ������%�o  h    ������%�o  h!   ������%�o  h"   ������%�o  h#   �����%zo  h$   �����%ro  h%   �����%jo  h&   �����%bo  h'   �p����%Zo  h(   �`����%Ro  h)   �P����%Jo  h*   �@����%Bo  h+   �0����%:o  h,   � ����%2o  h-   �����%*o  h.   � ����%"o  h/   ������%o  h0   ������%o  h1   ������%
o  h2   ������%o  h3   �����%�n  h4   �����%�n  h5   �����%�n  h6   �����%�n  h7   �p����%�n  h8   �`����%�n  h9   �P����%�n  h:   �@����%�n  h;   �0����%�n  h<   � ����%�n  h=   �����%�n  h>   � ����%�n  h?   ������%�n  h@   ������%�n  hA   ������%�n  hB   ������%�n  hC   �����%zn  hD   �����%rn  hE   �����%jn  hF   �����%bn  hG   �p����%Zn  hH   �`����%Rn  hI   �P����%Jn  hJ   �@����%Bn  hK   �0����%:n  hL   � ����%2n  hM   �����%*n  hN   � ����%"n  hO   ������%n  hP   ������%n  hQ   ������%
n  hR   ������%n  hS   �����%�m  hT   �����%�m  hU   �����%�m  hV   ����        H��H��j  H��t��H��Ð��������U�=�m   H��ATSubH�=�j   tH�=i  �B���H��h  L�%�h  H��m  L)�H��H��H9�s D  H��H�mm  A��H�bm  H9�r��Nm  [A\��f�     H�=xh   UH��tH�#j  H��tH�=_h  ���@ �Ð�����AWAVAUATUSH��H��8�����H��L�8����H�H��D�*H��H��B���H��L�0E�e�3���H� Mc�J�,�    J���@
H��
H����   H�P�A�E \I��H����  H���4  A�$H�
��� ��$�  A;M �w���A�D$
�q�@��v�q�@��vލq�@��	vՀ�_tЀ�:�X  H�JH9��K  �z:�A  H���
��    H�5eL  �   H���D���H��$�   H��$8  H��A�   H��I���@���H�yL  A�   �   L��H���#�����$�    �2'  H�L  A�   �
��  H�5JE  L��H��1������5���D  ��$�   ������r   L��H���*���H���k���H�=jD  �   L���Ƅ$  ����(���������D����     H�U H��H��H�RH�T� ���H�E L�uL��LpI�~A�*����H��$�  H��H��$�  H�U HB��$�  ���q���H�5�C  1�H��1������H�5�C  1�H��I�������H��$�  H��$�   1�L��$�   L��$�   I��H��$8  L��$�   ���5	  H��$�   H�BL� M���2  ��uA�D$<��  ��������  H��$�  H��$�   H��Ǆ$�      �+����   H��L��H��I���u���H�6F  A�   L��H��J�0H��H  J�0����H�C  A�   �   L��H�������H��$   L��H�������L��H�������H��$�   I��H�H�@    ��$�  ~#I�H��$�   H�yB  �   H��D�@�����I�E I�UM��L��H��H�HH��$  H��$�   ��$  ��$�   ��$   ��$�   H��$�   H�D$x��$�  �D$pH��$   H�D$h��$�  �D$`��$�  �D$X��$�  �D$PH��$  H�D$HH��$�   H�D$@H��$  H�D$8H��$0  H�D$0H��$�   H�D$(H��$�   H�D$ H��$(  H�D$��$�  L��$�   �D$H��$8  H�D$H��$   H�$����M��tA�D$���f  ����A�D$��  ��I���������H��$�    L��$�   t!H��$�   �B����  �����B��  M���v���A�E����  ����A�E�[���L��H���H����K��� H��$@  H��$�   E1�A�B   D��H���$    ������   ����� H�5{@  1�H��M������H��H��$�   HǄ$�       ��  H������H��L�8�����H�������H��H�������H������H��H��$�   �����H��$�   � H�߉�u���H�H��H��H�H��$�   �����H��$�   H;�    H���B���H�H��H��$�   �o���L��H+H��$�   H��H��H���� ���H� L)�H���Y  I�WM�gH��E1�H��$�   ����H��$�   H��H�H��$�   �   ����H�߉�$�   �v�����$�   L� HǄ$�       ~(I�$H��$�   M�|$�I��H��t�@M��tA�GH���-���H��L� �����H��D� �w���D; ��  H������M��tL��H������H��$�   H������A�G
��0��	�����H��u�   L��H��H���<�������L��L���   H������I������H�������1����V   L��H������H��I��t8H������IcUI�u I��H��H��H�����L��L��H����������  A�D$�Y���D  A�D$A�   HǄ$�       ����@ H��$�  Hc�H�H�FA�D6'A�D6}H��$�  A�D6 H��$�  �W����    ���M  H��$�   H�BL�` ����f.�     H��$   H��$�  �   H���[���H��$�  H���i��� H�������H� �@@���������fD  H��$�  �   L��H������I��H��$�  �����     H�E H��$�  H��H��H�@H�TP�X���H�E H�}1�Hx1��'H��$�  H��tKH�G�f.�     ��\tH���t#H��I��A�U ��'u�� \��H��A�U ��H��$�  Hc�H�H�P�D'H��$�  �D H�E H��$�  HP�w����    H��$�  L��   H��� ���I������H�9  A�   �   H��H�������D��$�  E������H�=�:  1�����������    H��$�   H�������*��� H���@���H� A�   �@@��������H��$�  �   L��H������H��$�  ���� H��$�   H���P��������H�5,8  H�ߺ   �����H��$�   H��$8  H��H��A�   I�������H�,8  L��H��A�   �   �����H��7  H��H��A�   �   ����I�$I�T$I��L��H��H�HH��$  H��$�   ��$  ��$�   ��$   ��$�   H��$�   H�D$x��$�  �D$pH��$   H�D$h��$�  �D$`��$�  �D$X��$�  �D$PH��$  H�D$HH��$�   H�D$@H��$  H�D$8H��$0  H�D$0H��$�   H�D$(H��$�   H�D$ H��$(  H�D$��$�  L��$�   L�l$�D$H��$   H�$�E��������L��H�����������A�U ��0�����f�����L��H������1�H�H��H��$�   ����H��$�   H��$  H������H��$8  H��H��$p  ����H��$8  �:@��  H�(6  �   A�   H��H��E1�����H��$�    H��$p  tNH��$8  H��$�   �D�<]��  <}��  H��$�   H��$p  I���-�D>I��H��L�� H��$p  �:*��  �[H��$p  I��L��$X  H��L�H��$H  �  H��$0  �����H��$(  H�ƹ   H��H��$�   ����H��$�   H��$�   �   H�������H��$�    �-  L��$`  E1�L��$h  L��$x  L��$p  �d  �    H��$�   �   H��H������H��$�   �   H��H������H��$  ��$  I�苄$   L��H��H��$�   ��$�   H��$�   ��$�  ��$�   H��$   H�T$x�L$p��$�  ��$�  H�D$h��$�  �T$`�L$XH��$  H��$�   �D$PH��$  H�T$HH�L$@H��$0  H��$�   H�D$8H��$�   H�T$0H�L$(H��$(  ��$�  H�D$ H�T$�L$L��H��$   H��$`  L��$�   H�$L��H�D$�;���L9�$�   ��   I��L9�$�   �
���H�������H��H�������H�������H��H��$�   ����H��$�   � H�߉����H�H��H��H�H��$�   �!���H��$�   H;��  H���h���H�H��H��$�   ����L��H+H��$�   H��H��H����&���H� L)�H���   I�T$L��H��H��$�   ����H��H�������H��I�D$����H��$�   H��H�H��$�   �   ����H�߉�$�   ������$�   L� ��tI�$I���@
�<]�  <}�  H��$`  H��"  A�   �   H��蠺��H��$8  ��5���A�D$A��j���H��H���ػ���\���H�w"  �   A�   H��H���V���H��$p  �$H��$p  L��$�   H�$�   ����H��"  A�   �   H��H�������X���B�|"�}�p���I���f���J�t"�H��!  H��H��$�   誸��H��H��$�   ��  �-H��$p  B�D!>H��$p  I��L�����H��$  H��贸������H��$�   H��蟸������H��$�   E�E 1�H��H�H�RA��H�H����H��$X  I�Ĺ   L��H�������   L��L��H������M���.���A�D$����  ����A�D$����L��H���V�������H�=�   1�L��� ���1������H�4!  A�   �   H��H��輸�������H��$8  H��$�   �|�}�I���H���?���H�t�H��   H���N���H���6  H��$`  H��   A�   �   H���S��������H�R   �   A�   H��H���1���H��$`  H�B� $H��$8  ������   H������H�����`���H�����������H���E���H� H�@H� �@
  HǄ$�       H�  E1�A�    �   H��H���$    衱��H��t
  HǄ$      H��  E1�A�    �   H��H���$    �\���H��Ǆ$�      tH�0�F
   H��H���$    �(���H��HǄ$(  �  tH�0�F
H�@�x
  H�fW�f. ����	�����$  �?���H�Vf�B ���������w	  H�H�x �t���Ǆ$d     �o���@ A�V��%� �_��   A�F�����L��H���"����t���D  H��$�   L��  1�1�A�   H���$   蠣��I�M�F1�H��$�   1�H��L�H�$   �z���H��$�   H��  A�   �   H��蘣��H��$�   �   L��H���`���H��$�   �   L��H���H���H��$�   �   L��H���0���@�������H��$�   �   L��H��1��
  �   1�H��L�@A���y���H��$  H��H��$�   詢��L��$�   �   H��H��H��L���ۣ��L��$�   M��tA�@���z  ����A�@��  H���ۡ��H��$�   L��H��H�I�I�VH�HH��$(  H�l$(H��$�   ��$l  ��$�   ��$d  ��$�   H��$�   H�D$x��$0  �D$pH��$8  H�D$h��$$  �D$`��$h  �D$X��$4  �D$PH��$@  H�D$HH��$H  H�D$@H��$P  H�D$8H��$�   H�D$0H��$X  H�D$ H��$�   L��$p  L��$�   L�<$H�D$��$�   �D$H��$x  H�D$�Q���H�������H� H��H��$�   ������E����   �����E�����H��H���١������@ A�D$
    Encountered CODE ref, using dummy placeholder   panic: snprintf buffer overflow Usage: Data::Dumper::Dumpxs(PACKAGE, VAL_ARY_REF, [NAME_ARY_REF])       Call to new() method failed to return HASH ref          T���F���8���*���U���������U���U���U���U���U���U���U���U���U���U���U���U���U��� ���                                 ;D      ����`   ����   (����   H���  X���0  x����  �����             zR x�  L      ����   B�B�B �B(�A0�A8�Gp�
8A0A(B BBBJ    <   l   `���   B�B�D �A(�G0�
(A ABBA     $   �   0���   M��[@�����
G   �   (���           L   �    ���   B�B�B �B(�A0�G8�G�
8A0A(B BBBG   L   <  ���S<   B�B�B �B(�D0�D8�J��
8A0A(B BBBH   L   �   ����   B�B�B �B(�A0�D8�J�y
8A0A(B BBBA           ��������        ��������                        ��      ��      ȅ      8�             &             P      
       j                            �             (                           (                                 	              ���o    �      ���o           ���o    �      ���o                                                                                                                                                           @�                      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                    .       >       N       ^       n       ~       �       �       �       �       �       �       �       �       !      !      .!      >!      N!      ^!      n!      ~!      �!      �!      �!      �!      �!      �!      GCC: (GNU) 4.4.7 20120313 (Red Hat 4.4.7-9) GCC: (GNU) 4.4.7 20120313 (Red Hat 4.4.7-4) ,             �"      �a                      w        �k  |S  boot_Data__Dumper �T  XS_Data__Dumper__vstring V  Perl_utf8_to_uvchr_buf �f  XS_Data__Dumper_Dumpxs     �k       t$  �   $  �"      u�          �
    s&  n&  �
  �,  int )  F  �B   �	  �;   �%  �;   *  �B   m'  �B   �  �;   �  �B   w  �^   o  �^   �  �W   j	  �^   <  �^     �^   ,  �^   |  �^        �%  B{   �	  Qp   ~  n  l	  <�   >  L�   �  �B   �  �W   �	{    	{    	B   �  
B    n  	 f  �  y�  9&  z�    �)  {^    i&  )  �    �,  
 �  	^   �  
B    �
  �$"  �  )�   (  *W   � �   +�  �  	�  2  
B     �  d"  W   
  _�     `�  3
  a�  <  bW     cW   "  dW    h%  e�  ( [  
B      �,  
B    #  �
B   
B    tm 8��  �   �W    �  �W   �  �W   �   �W   �  �W   �  �W   g  �W   �  �W   �  �W    c'  �^   (�  ��  0 tms  $�  '  %:   ,#  &:  g  (:  �  ):     �  
B   � 
  'q  -  (�    �  )�   /  *4   ?  +-     ,   DIR �|  �  IV �^   UV �B   NV \�  �     =	P  OP D	�  op ( |	  �  !�)   |  !�)  M#  !�?  �  !I>  �  !;   	 +  !;    �  !;    �  !;       !;     -  !;    �  !�&  "�  !�&  # COP E	�	  cop X��
  �  ��)   |  ��)  M#  ��?  �  �I>  �  �;   	 +  �;    �  �;    �  �;       �;     -  �;    �  ��&  "�  ��&  #  �'  $�  �  ((  �  0E  �  8q  �'  � �  �'  � �  �zG  � �  ��G  �  v  J	�
  
��  W  "�5   !Iop &�)  �  (�5  �  *�5  �  +�5   �  -�+  (C  .'  0�
  �AQ  ��  �=  ��*  ��H  �1%  �oG  ��  �X'  �&  �6  �z  ��)  ��
  ��+  ��#  ��)  �&)  ��)  ��+  �  ��
  ��  ��	  ��+  �f  ��+  �y)  �X'  ��  �a3  ��  �:*  �]&  ��&  �-  �  ��  �  ��  �GQ  ��  ��P  �/  �'  �  �'  ��,  ��  �	o  �  �	�*  �WQ  �	�&  �]Q  �	M  ��&  �	�  ��&  �	�  �  �	�  �  �	c   �cQ  �	�#  �  �	1,  �I   �	�	  �'  �	+  �W   �	K+  ��  �	~  ��)  �	{  ��)  �	,  ��)  �	�"  �  �	�  �X'  �	{  �X'  �	�  �X'  �	�'  �hQ  �	�  ��  �	�!  �  �
Q  �  �
�!  �  �
"  �  �
�!  �  �
�!  �  �
T!  �  �
y  �  �
K!  �  �
o  ��&  �
�  �  �
d  �  �
�&  �  �
^  ��&  �
T  �  �
Y  �  �
(  �  �
	  �X'  �
r  �E  �
�  �X'  �
o(  �'  �
�  �'  �
�  '  �
�  W   �
�  =  �
o
  	�)  �
_  
�)  �
E%  �)  �
  �)  �
�!  
_+  =  �
�  �)  �
&  �)  ��  �)  ��   �)  �$  0�)  �D  1X'  �r#  2X'  �  3X'  �  4=  �"  7�+  �%   8�+  ��  9X'  ��  :=  �"  ;=  ��  <=  ��+  ==  ��  >=  ��   ?�+  ��  @'  �i  CW   �  F'  ��  G'  ��  HX'  ��  IX'  �D+  L=  ��,  O  ��!  R�<  �9+  S�)  �  T�)  �H  U�)  ��%  V�)  �(  Y�I  ��  [W   �2  \W   �  ]  ��  ^sQ  ��  _  �
  ��<  �3-  �=  ��  �=  ��  �'  �z  �'  �W  ��<  � %  �W   �Q
  �X'  ��  �X'  ��)  �X'  �E
�&  ��%  W   �!  �Q  �*    ��
  �5  �+  �5  �  ,�Q  ��)  -=  ��  /�   ��'  4X'  ��  9�5  �3  ;=  �r  B�Q  �)(  E�+  � $  F�+  �3
  K�Q  ��&  NX'  ��*  P�P  ��  RX'  ��  SX'  �='  U�P  �3  W=  �i  X=  ��  Z^   �^"  \W   ��  ^'  ��*  `'  ��  bW   �U  d�+  �
  w�+  �N  �W   ��  ��Q  �  �\P  ��(  �'  �p  ��+  � SV Y	�  sv p1  �  q�    y(  q'  �  q'  d  r�5   AV Z	<  av �x  �  �%7   y(  �'  �  �'  d  ��6   HV [	�  hv ��  �  ��7   y(  �'  �  �'  d  �+7   CV \	�  cv �  �  ��6   y(  �'  �  �'  d  �s6   M  ]	  8  �E>  �  G�+   D  H�+  ?  K'  �  L'    M'  j  N'  �  O�+   t	  Q'  (r  T'  ,[  U�   0I"  Y'  8�!  Z'  <�  [�+  � �  \�+  � h  ^  �   a'  � a  e'  �    f�  � j  h  � "  i'  � �	  j'  � �   k�+  � c	  n'  � GP ^	I  gp P�  �
  X'     
�I     '    '  �"  
@;   R  �  �  �  ^  z;      �;   4  �+  ( 	  k	 "  s*  0u"  �*  `K   L  /  �  /  ^  !�K      %�K   4  &�+  ( �  l	�"    0S�"  �*  `�F   %  a�  �  b�  ^  i�F      mG   4  n�+  ( �  m	�"  
  5t?  �   6�<  � �#  7'  � �+  :�<  �  s  q	$  
  I�  !  JL'   I8  �I   U8  �-   U16  �4   I32  �W   U32  �;   Y$   �'  5'  �    )'  L'  L'  �    �  ;'  �  
  !W    �  !  q  !  �  !  �  !   �
  !$8)  � f   !&W   � <)  !*W   � �(  !,�   � B  !04   ��,  !1I   ��  !2>)  �*  !6N)  ��(  !?�   ��   !H�   �m  !I�   �!  !J�   �!  !K�   �!  !LP  ��  !NW   �H   !PT)  � $C  !��  !�2)  �  !�2)   {  !�8)    !�W    )  ^'  	  N)  
B     �(  	  d)  
B    c-  "co)  l,  m,  "e�)  d)  �  "z�)  �  �  #7  �  $��)  &*  $�'  ~  $�  }  $��)  �  $��)    $�  n"  $�'   �  �  �  $ԣ)  g  :*  �
  �&   A  �&    �&   g  	*  7   $�*  -"  %'   c  &'  3  'X'  .  (X'  �  )'   �  `+�*  �
B    �   5�*  �  6'   !end 7'   �   8�*  �  `}�+     ~!,   c  d,  l*  ��,  �'  ��,  �  ��,   �"  ��,  (&  �-  0  �A-  8%  �k-  � �  ��-  � #  ��,  � S'  ��-  �  �+  �*    �*  �*  x  8  o    u�+  �%  v�     w�+   '  |  x�+  %,  ,  L'  ,  ,     ,  ,  �  '  �+  %'  _,  L'  _,        '  X'  �   '   ,  ',  %  �,  L'  _,  X'      ,  �,   �+  j,  %X'  �,  L'  _,   �,  �,  L'  _,   �,  �,  L'  _,  �,  �,   '  X'  �,  -  L'  _,  �,  ,   -  %'  A-  L'  _,  ,  �,   "-  %X'  k-  L'  _,  �,  �,  ,   G-  %X'  �-  L'  _,  ,  ,   q-  %�   �-  L'  _,  �-   �&  �-  
  �W    �#  �  u Ya2   .  &��.  �   �R.   I"  �'  cp ��-   &��.  �   �R.   I"  �'  cp ��-  �  ��.   :*  &8�9/  �   �R.   I"  �'  cp ��-  k-  �9/  �  �'  �  �?/   B ��.  (me ��.  0 �-  �&  &8�/  �   R.   �  R.  -+  R.  �  �-  x
  '   cp �-  $�	  �-  (   
  S    TW    min UW   $max UW   (A V�.  0B V�.  8 '@��2  (yes �.  #�  �X.  #�  ��.  #W*  ��.  #  E/  #�$  �/  #T  �/  #�  #<0  #�  5S0  #�  @�0  #N  LK1  #
  W�1   �&  Z.   �*  �c?3  ,
B   1 3  �*  f3  
  ).(5  *�   *�  *  *�   *�$  *�#  *W  *m  *m  *�
*  *�  *L  
  (9W   ��7  (9W   �� 	  A  
B    	  ,A  ,B   � 	  <A  
B    �+  H))�A  �
  �H  #�  3I   |	  
  0��J  �  �=   �  ��J  n   � K  �  � K  
  j
  k
  +P   �  +'  4-  +=   �(  +�L  �  P+�O  �  +�O   R  +�)  �  +W   �
  +8'  � �  +9X'  � �  +:'  � >   +;'  � X   +<  ��  +=  ��  +>  �)  +?  �  +A�L  �x  +BX'  �?
  +C  �)  +D  �&  +E  �n  +F  �Y  +G  �D  +H  ��!  +I  ��  +J'  �y  +K�&  �R  +L�&  �  +M�&  �U%  +N�+  �P  +O'>  �	  +P=  �  +d�O  �*'  +e�O  ��  +f'  �0  +i�I  ��  +j  � (M  M  	�)  �O  
B    	'  �O  
B    �  +l(M  1&  �O  ]  p%  HP  P  %W   -P  L'   �  I9P  ?P  PP  L'  X'   c#  JP  E   LhP  nP  %  �P  L'  X'   
B    �  g�P  �P  �P  L'  �)   W#  w�P  �P  %'  �P  L'  X'  X'   
B    U3  �2  .�&  nQ  �  �  $Q  	�   �Q  
B    .'  	�&  �Q  
B   	 �O  f&  �D  �)  �   /�  �  �Q  0p ��  0len ��   1�	   W   R  0__s    2�   �  3 1�%  g  =R  2�  g  2�  g�   /w-  �  nR  0s ��  0len ��  4�!  ��   /�  �'  �R  0s ��  2t)  ��  5ret �'   /�  �'  �R  0d �  0s ��  2t)  Ȫ  5ret �'   1U  1�   S  2�  1�   2�  1  2U  1P   1'	  >W   DS  0__s >  0__n >P  2�  >�  3 /5	  b  |S  0s b�  0len b�  4�!  d�  6TOP r 7�  R�"      �%      ��T  8,  RL'      9cv R�<  I   :t  UW   ;sp U�5  l   ;ax U'  �   <T  U�5  @  =�,  U'  >I  \�  
	�      �?    iT  ;_sv aX'  �  ;vn a�  y  <g"  a�    @P   <�  aX'  R    @�   <   i�T  �    �  7�"  /�%      �&      �yU  8,  /L'  �  9cv /�<  .  :t  2W   ;sp 2�5  w  ;ax 2'  �  <T  2�5  #  =�,  2'  ?�   VU  ;sv 9X'  �  <l   :X'  �  AL&      �&      ;mg �yU  �    A�&      �&      <   K�T      U     Bi  {X'  �&      (      �V  8,  {L'  )  9sv {X'  r  9str {�    9len {�  P  9n {'  �  A�'      �'      <�  �V  2      C�  E�  (      (      �~V  D,  EL'  UEs E�-  TF�!  E�-  U  DP-  EzG  R5uv K~V   �  G�  �'   (      8.      �<X  F,  �L'  x  Hsv �X'  �  Hsrc ��  	  Ft)  ު  H	  F#  �'  ~	  Fb  �'  �	  Ir �  �	  J�  �    Is ��  �  J�!  �nQ  3
-      _LR  E  L�Q  q     Br  �'  @.      �j      ��f  8,  �L'  �  9val �X'  )  8  ��  R  80  ��  �  8�  �X'  �  8�  ��+  �  M	+  �=  � M�  ��+  �Mb&  �'  �Npad �X'  �M�   �X'  � 8,  �X'    Nsep �X'  �0M�   �X'  �8MQ  �X'  �� M�  �X'  �� M`  �'  �� M<-  �'  �� M�  �'  �� M=  �X'  �� M?  �'  �� M�  �X'  �� M'  �W   ��Mb  �'  ��M�  ��  ��>&  �A  ��~;i �P  7  ;c �  �  ;r �  !  <#  �  #  <9  ��     Oid �V  ��~�;svp ��5  �   ;sv �X'  7"  <�  �X'  �"  <&*  �X'  I%  <�  �X'  P(  <V  �=  }*  <�  �  �-  </  ��  M.  <	  ��  �/  <�  �'  �4  <:  �  T9  <L%  �  �;  P�(  �,;      ?`  r^  ;i #�  �@  ;mg $yU  �B  Q�R  L      �  ��[  L�R  	C  L�R  .C  L�R  {C  @@  R�R  D    ?�  �[  <�  C�,  MD  @�  ;_sv I�,  �D    ?�  �[  <U+  1X'  �D   QDS  �8      0  o\  L^S  -E  LUS  vE  @`  RiS  �E  StS  �8        Q�Q  0      �  �F\  L�Q  .F  L�Q  �F   ?�  +]  ;len N�  �G  T�H      �H      �\  >�  PW   PKS  �H      �H      PL7S  �G  L,S  	H  L!S  .H    ?@  ]  <�  RW   gH  KS  �/      �/      RL7S  �H  L,S  �H  L!S  I    @p  <�,  W�  :I  ;pv XnQ  uI    Q�R  �;      �  �n]  L�R  �I  L�R  �I  L�R  DJ  @�  R�R  �J    ?@  [^  >  ��f  	 �      >Y  ��f  	��      ;e �X'  RK  <�#  ��,  �K  <)  ��,  �L  Ugv ��f  ;j �'  XM  ?�  *^  <C  �'  �M  <:  �X'  �N  @   ;_sv ��,  O    ?`  D^  ;_sv ��,  QO   @�  ;_sv ��,  �O    @�  <�  ��,  �O    ? 	  �^  <U+  �X'  2P  @p	  <:  �X'  �P    ?�	  �^  <�  V�  �P  <�,  WnQ  S   ?�	  �_  <%  �'  @S  <�  �'  �S  ?@
  _  ;_sv �,  T   VnR  q4      �4      Y_  L�R  �T  LR  �T  Aq4      �4      R�R  8U    @�
  <G  
  �U  <    �U  K�R  �4      5      L�R  (V  L�R  KV  L�R  �V  A�4      5      R�R  W      ?�
  �_  ;sp ��5  {W  @  <�  �6Q  KX    ?@  (`  <�  I�  nX  <�  JnQ  �X   ?p  B`  <T  �X'  �X   ?�  ~`  <�  ��,  Y  A�:      �:      ;_sv ��,  MY    ?�  �`  <�  ��,  pY  @  ;_sv ��,  �Y    ?@  �`  ;_sv �,  �Y   ?�  a  <�  X'  QZ  ?�  �`  ;_sv .�,  �Z   A�=      �=      ;_sv *�,  ([    ? 
  �,  �d  @   ;_sv �,   e    @0  <8"  ��  6e  <d  �X'  �e  K�Q  YR      ~R      �WR  L�Q  �e     @p  <�)  X'  ?f  <)  X'  4g  <�   X'  �g  <Z  !6  8h  ;key "  di  <'  #'  �i  <  $X'  �j  <�  %=  0k  <�  '�,  �l  ?0  �c  <�
  �X'  �m  @`  ;_sv ��,   n    ?�  d  ;_sv ��,  6n   ?�  d  ;_sv ��,  �n   ?   Yd  ;sp e�5  �n  A8i      <i      ;_sv l�,  �o    ?P  vf  <w  z  �o  <�  {  dp  <�
  |'  �q  <�  }X'  �r  <]  ~�  Vs  <  '  �t  <#  �  �t  Tp]      �]      �d  <$  ��  ]v   Q=R  `Y      �  �Xe  LWR  �v  LNR  :w  @0  RbR  �w  X�Q  `Y      �  �L�Q  +x  L�Q  �x     ?   re  ;key �  �y   VnR  �Y      Z      ��e  L�R  �y  LR  8z  A�Y      Z      R�R  �z    V�R  @Z      rZ      �f  L�R  �z  L�R  {  L�R  f{  A@Z      rZ      R�R  �{    T"[      �[      Ef  <�  �  :|  <3  �'  ]|   ?p  _f  ;_sv ��,  �|   @�  ;_sv ��,  �|    A�h      �h      ;_sv M�,  9}     	�  �f  
B    �f  	�  �f  
B    �f  �)  /  7�  4�j      u�      �Ck  8,  4L'  \}  9cv 4�<  �}  :t  7W   ;sp 7�5  �}  ;ax 7'  �  <T  7�5  a�  <�,  7'  ��  @�  <�  @X'  �  @P  ;hv �+  ��  <�  X'  ?�  <�  X'  ��  <�  �+  ��  <	+  =  ��  <�  =  \�  <�'  =  ��  <@,  '  ��  <b&  '  ݇  <�  '  ��  <b  '  e�  ;i /  $�  <u  /  ��  <#  /  �  ;svp 	�5  k�  ;val 
X'  `�  <  
X'  ֑  ;pad 
X'  X�  <�   
X'  4�  <,  
X'  �  ;sep 
X'  �  <�   
X'  ș  <?  
X'  ��  <Q  X'  ��  <�  X'  \�  <=  X'  8�  <�  X'  ��  <`  '  <�  <<-  '  W�  <�  '  h�  <?  '  �  <�  
�  L,S  R�  L!S  ��     ?  �j  ;i �/  Ȱ  @@  <d  �X'  �    ?p  �j  <�-  ��,  6�  @�  ;_sv ��,  Y�    @�  ;_sv ��,  ��    ?0  *k  ;_sv ��,  ڱ   @p  ;_sv ��,  \�      	  Tk  ,B   � Z�  ,�8)  Z�
! I/  :;  & I  
 :;  7.?:;'@
  8 :;I  9 :;I  :4 :;I?<  ;4 :;I  <4 :;I  =4 :;I  >4 :;I
  ?U  @U  A  B.:;'I@
  C.?:;'I@
  D :;I
  E :;I
  F :;I  G.:;'I@
  H :;I  I4 :;I  J4 :;I  K1XY  L 1  M :;I
  N :;I
  O4 :;I
  P
 :;  Q1RUXY  R4 1  S
 1  T  U4 :;I  V1XY  W 1  X1RUXY  Y1RUXY  Z4 :;I?<  [!    �
���X�+JUf+fU<./� �:��KWK�Y��N~^�>W=��J�Yt�H�p3ust%�LVL��(�I�	��^��=;=;KIu_�'�N�=���G� Y}/j��s �%��}�����v����������� 0Jh�=;K;=IK�� t��iX�m�Zd��b<��f'Ȓ�w��0�e/k�� ���w.����7�z�Y�����us=Y/���y0�\~{uC� ��	���(������KW�v��8f��� ����Mڟ,��;�y.iH�H�f��y"WRx.	fx��=�.ut!s��z;�(��;=V�� @���"�~��t� �$+"��y��(��I��w��`��#v����=�=Y����
���.��w,��u���x����x�WRx.	fx��=� h�#�u$,������z�����ՃYg/=�I�@$e�;&�/"
�(=�=Yɏ�Y�=P���{�'�9u�w��<�wJ�J�wJ�X>��,Y�=Xg��.l#g��-�Z�>Y'�/��>��#�e"�417�{81�:>Y5;/Y;��?9K;=!;uY�=׻����;=��Y���L%h�Y`���w�%�����G.>�>:ZY� t���xt��=��Y���N��{ =�����y�$L�zXR>H��f-�{X���v�~@��~%�y���=u��{(�0��� 0��w��.�wJ�.=�w��X�w�WRx.	.x��=���=Y�z������t�{��(�J=�=Y����{��J�,0:�Z���{����{��Xy7]/I��g;��-�Y�>uu�a�#K�A�z.�%���uu�
�"=�=�/)�,,�} =�Il�����}<u����	��"�-�Y��"Y�;�M;=!�s=K�?�/��g��g<�s��/�����-C��,�Yt�yJjJJi���w<����#��z<1H�:�f>=q?��z�WRx.	.x��=�Rx.�.?YLd>c1cYZ��e=Y�u#�W=��{��X�{<��s�K��������� ���(��=u:�Y.��t�y0��S���x<�����-=�z���$L�zXR�H����y0����� #%�,�y@���F��J�|�� ��{�����z��F��J�z.���I��2���|��� (L"Y�3%K�J%�=�/�|60�X�~"%;�m'�����|��~��FI�|J������Cv��|X� �I��b���~���}��"�}�Q%�"��X�}�� f�e�YK���	 E�*�|Xv.U�$�$����� Xu*�J�|��|X�Xf09�>rL:�O�1<FJ	�4���(:>>;���;K/IKh��=Y;=�;�i�;=����;�]�AYI=�P,#9�9�7�7�0=0=<�<�<�<�<�<�<�<�0=7D<�7�8�,=;�+�Ij�ʎ>g�q1U�Y���uf�
�F��u��
�P���=
3	f�e=�3��utv����[!�=�?#/�L�g�u��
��u��
ȭ�~�4<�zeXv4� ;80(&"uuu������YztPYuxtT(��u-=�(�e=��9�P3�$lt� t�~<���_"a��S��)�K�� ��,� �1�)�%/]/T/� X�~An���444I
 Є      �S      e      
 Є      �e      �      
 ӄ      �                y       �       ���             ��                �       �        P�       �        P�       �        ];      S       ]�             ]                �      �       1�                       4       U4             S      (       S                       4       T4      �       \      (       \                ;      ?       p ?      a       ]                H      S       p S      T       VT      u       v�u      �       V      (       v�                T      u       v  $ &3$p "�u      y       v $ &3$p "�      (       v  $ &3$p "�                �      �       v 3$p "                �             ]                �      �       P                �             1�                0      j       Uj      �       ^�      F       ^                0      j       Tj      �       V�      �       P�      *       V*      7       T7      A       VA      F       P                0      j       Qj      �       \�      F       \                0      j       Rj      �       ]�      F       ]                0      j       Xj      �       S�      �       s��      �       S�             S      &       s�&      F       S                              P                P      S       Q                `      �       U�      �       w �      �       ���      x       w                 `      �       T�      x       ��                `      �       Q�      x       ��                `      �       R�
             R                `      �       X�      �       S�      x       S                `      �       Y�
      "       Y                +      8       ^8      p       ]p      {       Pc      p       ^p      ,	       ]K	      �	       ]�	      �	       P�	      �	       ]�	      �	       ]

      T
       ]~
      �
       ]"      _       ]c      x       ]                +      �       ^c      �	       ^�	      �	       ^

      T
       ^~
      �
       ^"      x       ^                w      �       ���      �       Q�             \             |�      1       Q1      �       \�      �       |��             Q8      ?       ��?      Z       \Z      b       |�b      g       \�      �       \�      �       Q�      .       \.      >       Qp      {       ��{      �	       \�	      �
       \�
      "       ��"      x       \                w      �       V�      x       V                {      �       P                �      �       t #�      x       ��                �      �       0�      $       ]�      �       ]�      �       ]&      .       ]�	      �	       ]
      

       ]�
      "       0�                �      �       0�      $       ���      �       ��^
      f
       ���
      "       0�                �      �       0�      $       ���      �       ��v
      ~
       ���
      "       0�                �      �       0�      $       ���      �       ���      �       ���
      "       0�                �      �       0�      $       ���      �       ���
      "       0�                �             Tb      u       T�             T      .       t0��	      �	       T                �      $       P1      �       P�      �       P�      .       P�	      �	       P�	      

       PT
      ~
       P                E      Z       | Z      g       |                �      2	       P2	      5	       QM	      b	       P�	      �	       P

      E
       PE
      I
       X~
      �
       P"      M       PM      Q       Qh      k       P                *
      T
      
 A�      �                *
      O
       ]                �      x       Ux      '       S1      :5       S:5      �<       V�<      �=       S�=      �=       V�=      �G       S                �      �       T�      A       \1      C       \B      g       Tg      �       \�      K       \c      �       \O      $       \p      {       \�      ;       \;      "       ��|="      �#       \b%      �%       \�%      �%       \&      '       \'      �'       \�'      q(       \q(      �(       ��|�(      �)       \ *      A*       \]*      �*       \�*      �*       \P,      �,       \2      %2       ��|%2      53       \�=      �=       ��|3?      K?       \K?      [?       ��|[?      �?       \�?      �?       ��|�?      e@       \e@      u@       ��|u@      �@       \1B      AC       \�C      D       \-D      kD       \�D      �D       \�D      9E       \�E      �E       \�F      G       \�G      �G       \                �      �       Q�      �G       ��}                �      �       R�      �G       ��|                �      x       Xx      �       V1      K       Vc             Vp      �       V="      q(       V�(      2       V%2      25       V25      �=       _�=      K?       V[?      �?       V�?      e@       Vu@      sF       VxF      �G       V                �      �       Y�      �G       ��|                �             �(1      �       �(�      �       P�      B       ��|B      Y       �(c      i       �(i      O       ��|O      $       �($             ��|p      "       �(="      b%       ��|b%      �%       �(�%      �%       ��|�%      �%       �(�%      &       ��|&      '       �('      '       ��|'      �'       �(�'      �'       ��|�'       *       �( *      ]*       ��|]*      �*       �(�*      �*       ��|�*      �*       �(�*      P,       ��|P,      e,       �(e,      �1       ��|�1      %2       �(%2      �=       ��|�=      �=       �(�=      3?       ��|3?      @       �(@      X@       ��|X@      u@       �(u@      �A       ��|�A      B       �(B      �B       ��|�B      �B       �(�B      �B       ��|�B      AC       �(AC      kC       ��|kC      �C       �(�C      �C       ��|�C      D       �(D      �D       ��|�D      �D       �(�D      �D       ��|�D      �E       �(�E      sF       ��|xF      �G       ��|�G      �G       �(                b4      p4      	 p  $ &��4      :5       0�:5      �=       ��|nA      �A       ��|B      1B       ��|AC      kC       ��|kD      �D       ��|�E      �E       ��|                I
 �      �                &      ,&       ��                &      &       ��~�&      ,&       ]                
 υ      �                �      �       ��                �      �       ��~�                '
_       ^_      ?_       ^?_      __       ��u__      d_       Pd_      @`       ��u@`      E`       PE`      �a       ��u�a      �a       ^�a      �a       ��u                &H      1H       p 1H      2H       ]2H      VH       }�VH      
O       P9O      QO       P�O      �O       P�O      P       PhP      �P       P�P      �P       P Q      !Q       PTQ      \Q       PLR      �R       V�T      �T       PU      1U       P1U      �U       V�V      �V       P�V      �V       V�W      �W       PtZ      �Z       V`[      x[       V�[      �[       P�[      �[       V�\      �\       V>^      J^       PW^      c^       Pq^      }^       P�^      �^       P�a      �a       V                ?J      CJ       PCJ      LR       ��uLR      T       \�T      �U       \V      �V       ��u�V      �V       \�X      �Z       \G[      �[       \�[      �[       P�[      �[       \�[      �[       ��u�\      �\       \)]      �^       ��ud_      �_       ��u`       `       ��uE`      ga       ��u�a      �a       ��u�a      �a       \                SJ      WJ       PWJ      �U       ^V      x\       ^{\      �^       ^d_      ga       ^�a      �a       ^                ?J      CJ       PCJ      hM       ��uhM      �U       ��uV      �V       ��u�V      9]       ��u9]      �]       ��u�]      q^       ��uq^      �^       ��u�^      �^       ��ud_      �_       ��u�_      �_       ��u�_      �_       ��u�_      �_       ��u�_      `       ��u`       `       ��u `      �`       ��u�`      a       ��ua      9a       ��u9a      Pa       ��uPa      ga       ��u�a      �a       ��u�a      �a       ��u                ?J      CJ       PCJ      �M       ��u�M      �U       ��vV      �V       ��u�V      9]       ��v9]      �]       ��u�]      q^       ��vq^      �^       ��u�^      �^       ��vd_      �_       ��v�_      �_       ��u�_      �_       ��v�_      �_       ��u�_      `       ��v`       `       ��u `      �`       ��v�`      a       ��ua      9a       ��v9a      Pa       ��uPa      ga       ��v�a      �a       ��u�a      �a       ��v                ?J      CJ       PCJ      �M       ��u�M      �U       ��vV      �V       ��u�V      9]       ��v9]      �]       ��u�]      q^       ��vq^      �^       ��u�^      �^       ��vd_      �_       ��v�_      �_       ��u�_      �_       ��v�_      �_       ��u�_      `       ��v`       `       ��u `      �`       ��v�`      a       ��ua      9a       ��v9a      Pa       ��uPa      ga       ��v�a      �a       ��u�a      �a       ��v                ?J      CJ       PCJ      =N       ��u=N      �U       ��uV      �V       ��u�V      9]       ��u9]      �]       ��u�]      q^       ��uq^      �^       ��u�^      �^       ��ud_      �_       ��u�_      �_       ��u�_      �_       ��u�_      �_       ��u�_      `       ��u`       `       ��u `      �`       ��u�`      a       ��ua      9a       ��u9a      Pa       ��uPa      ga       ��u�a      �a       ��u�a      �a       ��u                ?J      CJ       PCJ      �N       ��u�N      �U       ��vV      �V       ��u�V      9]       ��v9]      �]       ��u�]      q^       ��vq^      �^       ��u�^      �^       ��vd_      �_       ��v�_      �_       ��u�_      �_       ��v�_      �_       ��u�_      `       ��v`       `       ��u `      �`       ��v�`      a       ��ua      9a       ��v9a      Pa       ��uPa      ga       ��v�a      �a       ��u�a      �a       ��v                ?J      CJ       PCJ      �N       ��u�N      �U       ��wV      �V       ��u�V      9]       ��w9]      �]       ��u�]      q^       ��wq^      �^       ��u�^      �^       ��wd_      �_       ��w�_      �_       ��u�_      �_       ��w�_      �_       ��u�_      `       ��w`       `       ��u `      �`       ��w�`      a       ��ua      9a       ��w9a      Pa       ��uPa      ga       ��w�a      �a       ��u�a      �a       ��w                ?J      CJ       PCJ      O       ��uO      �U       ��vV      �V       ��u�V      9]       ��v9]      �]       ��u�]      q^       ��vq^      �^       ��u�^      �^       ��vd_      �_       ��v�_      �_       ��u�_      �_       ��v�_      �_       ��u�_      `       ��v`       `       ��u `      �`       ��v�`      a       ��ua      9a       ��v9a      Pa       ��uPa      ga       ��v�a      �a       ��u�a      �a       ��v                ?J      CJ       PCJ      YO       ��uYO      �U       ��vV      �V       ��u�V      9]       ��v9]      �]       ��u�]      q^       ��vq^      �^       ��u�^      �^       ��vd_      �_       ��v�_      �_       ��u�_      �_       ��v�_      �_       ��u�_      `       ��v`       `       ��u `      �`       ��v�`      a       ��ua      9a       ��v9a      Pa       ��uPa      ga       ��v�a      �a       ��u�a      �a       ��v                ?J      CJ       PCJ      �P       ��u�P      �U       ��vV      �V       ��u�V      )]       ��v)]      �]       ��u�]      q^       ��vq^      �^       ��u�^      �^       ��vd_      |_       ��v|_      �_       ��u�_      `       ��v`       `       ��u `      E`       ��vE`      w`       ��uw`      �`       ��v�`      a       ��ua      "a       ��v"a      ga       ��u�a      �a       ��u�a      �a       ��v                ?J      CJ       PCJ      gQ       ��ugQ      oQ       PoQ      �Q       Q�Q      �U       ��uV      �]       ��u�]      ^       Q^      �^       ��ud_      l_       Ql_      w`       ��uw`      �`       Q�`      a       ��ua      a       Qa      ga       ��u�a      �a       ��u                SJ      GL       0�GL      �U       ��vV      AV       0�AV      uV       ��vuV      �V       0��V      q^       ��vq^      �^       0��^      �^       ��vd_      `       ��v`       `       0� `      ga       ��v�a      �a       0��a      �a       ��v                SJ      �O       0��O      �U       ��vV      �V       0��V      )]       ��v)]      �]       0��]      �]       ��v�]      �]       0��]      q^       ��vq^      �^       0��^      �^       ��vd_      |_       ��v|_      �_       0��_      �_       ��v�_      �_       0��_      `       ��v`       `       0� `      U`       ��vU`      w`       0�w`      �`       ��v�`      a       0�a      "a       ��v"a      Pa       0�Pa      ga       ��v�a      �a       0��a      �a       ��v                SJ      AP       1�AP      �U       ��vV      �V       1��V      )]       ��v)]      �]       1��]      q^       ��vq^      �^       1��^      �^       ��vd_      |_       ��v|_      �_       1��_      `       ��v`       `       1� `      E`       ��vE`      w`       1�w`      �`       ��v�`      a       1�a      "a       ��v"a      ga       1��a      �a       1��a      �a       ��v                �H      �P       0��P      �U       ��v�U      �V       0��V      )]       ��v)]      �]       0��]      >^       ��v>^      W^       0�W^      q^       ��vq^      �^       0��^      �^       ��v�^      d_       0�d_      |_       ��v|_      �_       0��_      `       ��v`       `       0� `      E`       ��vE`      w`       0�w`      �`       ��v�`      a       0�a      "a       ��v"a      �a       0��a      �a       0��a      �a       ��v                �H      -Q       
��-Q      �U       ��v�U      �V       
���V      )]       ��v)]      �]       
���]      >^       ��v>^      �^       
���^      �^       ��v�^      d_       
��d_      |_       ��v|_      �_       
���_      `       ��v`       `       
�� `      E`       ��vE`      w`       
��w`      �`       ��v�`      a       
��a      "a       ��v"a      �a       
���a      �a       
���a      �a       ��v                �H      �U       ��vV      �a       ��v�a      �a       ��v                �H      �J       0��J      �U       ��vV      %V       ��v%V      AV       0�AV      �^       ��v�^      d_       0�d_      ga       ��vga      �a       0��a      �a       0��a      �a       ��v                �L      �L       t �`      �`       t                 �L      !M       t �`      �`       t                 �O      �O       t U`      w`       t                 P      AP       t E`      U`       t �`      �`       t                 {Q      �Q       q w`      �`       q                 �R      
T       ��v�X      �X       P�X      tZ       VG[      `[       Vx[      �[       V�[      �[       V                �U      �U      	 p  $ &�                �U      �U       P�a      �a       P                �U      �U      
 υ      ��a      �a      
 υ      �                �U      �U       
 ��a      �a       
 �                �U      �U       ��w�a      �a       ��w                �W      �W       0��W      �W       VOX      �X       V                �W      �W       p                 �X      �X       P                �X      Y       ��ux[      �[       X�[      �[       X                EZ      tZ       VG[      `[       V                �[      z\       _�\      )]       _�^      �^       _�_      `       _ `      E`       _�a      �a       _                \      {\       ��u�\      )]       ��u�^      �^       Q�^      �^       ��u�_      �_       Q�_      �_       ��u `      E`       ��u�a      �a       ��u                �       �k  e   __dev_t p   __uid_t {   __gid_t �   __ino_t �   __ino64_t �   __mode_t �   __nlink_t �   __off_t �   __off64_t �   __pid_t �   __clock_t �   __time_t �   __blksize_t �   __blkcnt_t   __ssize_t   gid_t $  uid_t /  ssize_t :  clock_t E  time_t P  size_t [  int32_t �  __sigset_t �  timespec �  __jmp_buf �  __jmp_buf_tag 2  sigjmp_buf C  random_data �  drand48_data   sigval ;  sigval_t �  siginfo �  siginfo_t   uint32_t '  stat �  tm �  tms �  netent 
  PMOP �  LOOP �  PerlInterpreter �  SV 1  AV x  HV �  CV   REGEXP >  GP �  GV ^  PERL_CONTEXT    MAGIC �   XPV �   XPVIV !  XPVUV ^!  XPVNV �!  XPVMG "  XPVAV u"  XPVHV �"  XPVGV >#  XPVCV $  XPVIO J%  MGVTBL �%  ANY f&  PTR_TBL_t �&  CLONE_PARAMS �&  I8 �&  U8 �&  U16 '  I32 '  U32 '  line_t �%  any �(  _IO_lock_t )  _IO_marker ^'  _IO_FILE d)  PerlIOl u)  PerlIO �)  PerlIO_list_t �)  Sighandler_t �)  YYSTYPE �)  YYSTYPE 	*  regnode :*  regnode E*  reg_substr_datum �*  reg_substr_data �*  regexp_paren_pair �*  regexp_paren_pair   regexp �+  regexp �+  re_scream_pos_data_s �+  re_scream_pos_data �*  regexp_engine �-  _reg_trie_accepted �-  reg_trie_accepted �-  CHECKPOINT .  regmatch_state �2  regmatch_state 3  regmatch_slab U3  regmatch_slab a3  re_save_state (5  svtype 35  HE m5  HEK �  sv �  gv �  cv <  av �  hv "  io �   xpv �   xpviv !  xpvuv j!  xpvnv �!  xpvmg �"  xpvgv �<  cv_flags_t $  xpvio �&  clone_params I  gp 3>  PADLIST >>  PAD I>  PADOFFSET J#  xpvcv �  op �
  pmop �  loop �?  passwd 5@  group r@  crypt_data <A  spwd �D  REENTR =5  he x5  hek $E  mro_alg �E  mro_meta �E  xpvhv_aux �"  xpvhv *G  jmpenv oG  JMPENV �	  cop �G  block_sub  H  block_eval �H  block_loop 3I  block_givwhen �  block �I  subst j  context �J  stackinfo K  PERL_SI  "  xpvav V%  mgvtbl    magic �L  SUBLEXINFO �L  _sublex_info M  yy_stack_frame (M  yy_parser �O  yy_parser 1&  ptr_tbl_ent r&  ptr_tbl P  runops_proc_t -P  share_proc_t PP  thrhook_proc_t \P  destroyable_proc_t �P  perl_debug_pad �P  peep_t �P  SVCOMPARE_t �P  exitlistentry $Q  PerlExitListEntry �  interpreter     6       9       �            �       �       @       y                       �       �       �            @      X                      �      �      �      �                      o      r      u      �                      �            X
      �
      �	      
      �	      �	      �      0      �      �      �      �      $      �                      @      V      Z      b                      �      b	      "      x      �
      �
      
      X
      �	      �	      �	      �	                      �      P	      "      x      �
      �
                      �      �
                 x             P      P                                    s             h      h      �                            ~             �!      �!      �b                             �             ��      ��                                    �             Є      Є      �                             �             Ȉ      Ȉ      D                              �             �      �      �                             �             ��      ��                                    �              �       �                                    �             �      �                                    �              �       �                                     �             @�      @�      �                           �             ��      ��      @                             �              �       �      �                            �             Џ      Џ                                    �      0               Џ      X                             �                      (�      0                              �                      X�      {                                                   Ӑ      �k                                                  ��      �                             (                     �     �
 h                    �!                    ��                   
 �p��"{   |   }   �   �   �       �   �   �           �   �       �   �   ��������\�.^����qX@��^wu���^O?|��|��`A(U�*^Z��"�o�$@�!r���2�CE�옖w.��x��x�(��_�����5(�x�::^����M��n��J����]sB��                                 	 �+              e                     �                     J                                          
                     ~                     �                     �                     �	                     M                     B	                     
                     \                      �                     �                     �                                            %                                            q                     �                     "                     I                      
                     �                     3                     �                      >                                              "                   P	                     �                     �                     �                      �                     �                     ;                     Y                     �                     �                     X                     �                     �	                     ]	                     
                     n	                     !                                          F
                     �	                     *
                     E                     �                     f                     +                     .                     �                     �                     J                     �	                     �                     �                     �                     _                     �                     t                      �                     x                     )                     	                     �	                     �                     o                     �                      �                     �	                     �	                                          �                     �                     �                     �	                     �                     �                      w                     �                     �                     /	                                          �                     a                     �	                     �                     �	                     H                     �                     �                     �                     �                     �                      X                     		                     y                     �                     �                     1                     �                     �                     l    @?      H           �              G    �U      �      �     P      �      �   	 �+              e
   ���              9      4      b	      +    �G      w           PY      2      �    �=      �      q
   ����              	    `I      w      �    PN      �      �      �      �      w    @S      �       /    �W      �      _     �      �          @a      �	      K    �            �     L            ^
   ���              _    T      �      �    �J      2      �     k                0M            F    �F      K      �    �Q      �      �    p�      �      �    �^      h      �     �      �	      �     ��      b      �    0y      1
         ui	   v
      ��             ��      8�         �           @�         �           H�         �           P�         �           X�         �           `�         �           h�                    p�                    x�         �           ��         �           ��         �           ��         �           ��         }           ��         �           ��         �           ��         �           ��         �           ��         ,           ��         �           ��         �           ��         �           ��         �           ��         �           ��         �           ��         �            �         K           �         �           �         {           �         �            �         R           (�         ~           0�         �           8�         `           @�         �           H�         �           P�         �           p�                    x�                    ��                    ��                    ��                    ��                    ��                    ��         	           ��         
           ��                    ��                    ��         
   �@����%
�  h   �0����%�  h   � ����%��  h
�  h+   �0����%�  h,   � ����%��  h-   �����%�  h.   � ����%�  h/   ������%�  h0   ������%ڨ  h1   ������%Ҩ  h2   ������%ʨ  h3   �����%¨  h4   �����%��  h5   �����%��  h6   �����%��  h7   �p����%��  h8   �`����%��  h9   �P����%��  h:   �@����%��  h;   �0����%��  h<   � ����%z�  h=   �����%r�  h>   � ����%j�  h?   ������%b�  h@   ������%Z�  hA   ������%R�  hB   ������%J�  hC   �����%B�  hD   �����%:�  hE   �����%2�  hF   �����%*�  hG   �p����%"�  hH   �`����%�  hI   �P����%�  hJ   �@����%
�  hK   �0����%�  hL   � ����%��  hM   �����%�  hN   � ����%�  hO   ������%�  hP   ������%ڧ  hQ   ������%ҧ  hR   ������%ʧ  hS   �����%§  hT   �����%��  hU   �����%��  hV   �����%��  hW   �p����%��  hX   �`����%��  hY   �P����%��  hZ   �@����%��  h[   �0����%��  h\   � ����%z�  h]   �����%r�  h^   � ����%j�  h_   ������%b�  h`   ������%Z�  ha   ������%R�  hb   ������%J�  hc   �����%B�  hd   �����%:�  he   �����%2�  hf   �����%*�  hg   �p����%"�  hh   �`����%�  hi   �P����%�  hj   �@����%
�  hk   �0����%�  hl   � ����%��  hm   �����%�  hn   � ����%�  ho   ������%�  hp   ������%ڦ  hq   ������%Ҧ  hr   ������%ʦ  hs   ����        H��H�
   H���t���H�$�  E1�A�0   �   H��H��I���$    �:���L� A�|$	t!H�
   L��L��H���~���I�D$H�8 �w  L� H�������   H��H��L������H������H�8 t H������H��L� ������0H��L���s���H��I�������L H���M���H��I�$�a���H��I�������H(I�,$H��8[]A\A]A^A_��     H������H� �"   1�H��J�4������H�D$(�a����     H�T$(H�
H�|$ L�T$L�L$�����L�L$H�T$ A�$   H�t$@��L���$    �����H��L�T$�  H�|$ �K���1�L���A���I��L+D$(H��A�   L��L��L��H�D$�����H�E L�T$H�X H����  H�8�  �fD  H�H����  H9Cu��C�t&H�sH��t�F����  �����F�4  �C��L�SL��CH�E �M  � f�`l�H�E L�PHH�\$0H�D$0H��L�p�����H�H��h[]A\A]A^A_Ð��:t��'�������H�������     H���H��������Ѓ�	�t  ����  ��������l  L������H� �@#�  A�F
�  1������H�=܀  1������D  H�\$�H�l$�H��L�d$�L�l$�H��(H���E���H��L�(����H�H��D�"H��H�����Ic�H��HI)�I��A���  H��A���n���H� Mc�J�,�    N�$�A�D$�    ��   ��u_%�   ��	ti��trH��I���-���L H���R���I�$H������H��I������H(I�,$H�\$H�l$L�d$L�l$ H��(� M�d$A�D$%�   ��	u�I�D$H��t�L�`M��t�I�$H�x0 u�A�D$��r����q   L��H������H���s����T���@ L��H�������A�D$�'���H�X~  H��H���Q���f�     AUATI��USH��H�������H��L�(�H���H�H�ߋ*H��H��$���Hc�H��HI)�I��A���  H�߃������H� Hc�L�,�    L�$�A�D$�    ��   ��uoL��H�����������   H������I��H������H� H��L�$�����H� H��H�4��S���H������H��H������L(L�m H��[]A\A]�fD  I�D$�@t�H������L��A�	   �	   H��H������H��H��LE�L���J������^���f.�     H������I���O���L��H���]���A�D$����H��|  L��H�������f�     H�\$�H�l$�H��L�d$�L�l$�I��L�t$�H��(�@���H��L�(����H�H�ߋ*H��H�����Hc�H��HI)�I��A����   H�߃��k���H� Hc�L�,�    L�$�A�D$ ��   H���E���A�D$  � L�0t'�V   L��H������H��tH������f��fD  H�������I��H������H��H�������L(L�m H�$H�l$L�d$L�l$L�t$ H��(�D  L��H�������k���H��{  L��H������fffff.�     H�\$�H�l$�H��L�d$�L�l$�H��L�t$�H��(� ���H��L�(�u���H�H��D�"H��H��P���Ic�H��HI)�I��A����   H��A�l$�(���H� Hc�H��L�$�    L�4�����L�(A�F%  �=  �tKH�������I�D� H���v���H��H�������L L�e H�$H�l$L�d$L�l$L�t$ H��(��    H�������H��z  H��H������fff.�     H�\$�H�l$�H��L�d$�L�l$�I��L�t$�H��(�����H��L�(�e���H�H�ߋ*H��H��A���Hc�H��HI)�I��A����   H�߃�����H� Hc�L�,�    L�$�A�D$  � ufH�������L�0A�D$��Dt��3u\H������I��H���`���H��H�������L(L�m H�$H�l$L�d$L�l$L�t$ H��(�f�     L��H�������� H��������H�cy  L��H���\���@ H�\$�H�l$�H��L�d$�L�l$�H��L�t$�L�|$�H��8�����H��L�(�@���H�H��D�"H��H�����Ic�H��HI)�I��A���.  H��A�������H� Mc�H��N�,�    N�4��:���H� �@# ��   H������H��A�F�    ��   �  � ��   E1�H������L��H��H��L�0�����E@tH��H�������K�,�H�������H��H���d���L(L�m H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8�f�H������H��H�(����H� H�@H�l� A�F�    �W���L��H���_���A�F�  � �H���L��H��A�   �������2����*���H��w  H��H�������     H�\$�H�l$�H��L�d$�L�l$�H��L�t$�L�|$�H��8����H��L�(����H�H��D�"H��H��k���Ic�H��HI)�I��A���  H��A���D���H� Mc�H��N�,�    N�4�����H� �@# ��   H������E�~H��A��    ��   H��A��   �����Ic�H��H��L�0�a����E@tH��H���0���K�,�H���T���H��H������L(L�m H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8��    H�������H��H�(�����H� E�~H�@A��    H�l� �W���L��H������E�~�C���H�)v  H��H���"���f.�     H�\$�H�l$�H��L�d$�L�l$�H��(H������H��L�(�
���H�H��D�"H��H������Ic�H��HI)�I��A���  H��A������H� Mc�J�,��E<��   �����u.����   ��  ���  �t.�   H����������   H�\$H�l$L�d$L�l$ H��(é   ��   L�mH���q���H��H�¹   H������A�EH��L�m�M   ����H��H������J������HH�U �f�H�U�B �  ���B���D  H�=�t  H�\$H�l$L�d$L�l$ 1�H��(�j���H��t  H��H������H�=�t  1�����H�5��  H�=it  1�����ffff.�     H�\$�H�l$�H��L�d$�L�l$�H��(I�������H��L�(�Z���H�H�ߋ*H��H��6���Hc�H��HI)�I��A��uXH�߃�����H� Hc�H��H�4������H������H��I�������H������HI�$H�\$H�l$L�d$L�l$ H��(�H��s  L��H������ffff.�     H�\$�H�l$�H��L�d$�L�l$�I��L�t$�L�|$�H��8����H��L�(����H�H�ߋ*H��H��\���Hc�H��HI)�I��A���A  H�߃��6���H� Hc�H��L�,�    L�4��|���H� �@# ��   H�������I��A�F�    ��   ����   M�~H�������L��H��L�0L������A�D$@��   M�$�H���G���H��H������L(L�m H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8�f.�     H�������H��L� �����H� H�@M�$�A�F�    �V���L��H������A�F���G���H��L���(���H(H���M���H�E �U���@ L��H���e����=���H��q  L��H�������fD  H�\$�H�l$�H��L�d$�L�l$�I��L�t$�H��(�P���H��L�(�����H�H�ߋ*H��H�����Hc�H��HI)�I��A���>  H�߃��{���H� Hc�H��L�,�    L�4������H� �@# ��   H���<���I��A�F�    ��   ����   I�v1�H������L��H��H�������H���
���f.�     ��%  �=  ���   ��H�M ��   I�H�@H�A�E�   ��   ���E�����D  L��H������������H�������8 �����E1�E1��t   1�H��H������������    L��H��������u�����@ L��H��H�D$�����H�D$�p���fD  ��H�M t_I�H�@H�A�E�   uj
�&���H��H�$����I�$H�$H��H�	H�IH��HH�
����I�$H��H������H��L� ����H� H��D�` ����H� D;`$�  H������L� H�������A�D$ H������H� H��L�`�t���H� H��Hc@ H��H��H��H)�I�fA�$�m���H�H��H�$�����H�$H+H��H��A�T$����H� H��I�D$����H�H��H�$����H�$H+H��H��A�T$�?���� H��A�D$�0���H� A�D$ M�|$ I�D$I��@A�D$L I�D$X    A�D$HI��p���M  H������H� �@#���A�D$MI��B�����B~I�H�t$0H�ߋP�z���H������H�0�!   H���"���H���j���I�H�t$0H��HcJH�VH��H�����H��I���@���H� H�@I�$I��|$H�P8H�T$��   A�   �fD  A��I��D9d$~vI�UI�FH��H�����H�L$H��H��n���H���H�������H� H;(t�H�������H� �   H��H��H������E@t�H��H��A���f���I��D9d$�I��x�&  A�W��A�W���#  ����A�W�'  �hH���0���H� H��L�h�!���H� H�ߋP Lc��L��I���P H��I)�O�d% ����H���_���I�T$H��H�����H��I�������IcT$H��H��HI�U ����A�T$H�߉�����I�T$H��H�����H��L�0����H� L�`M����  H���Z���H� H��L�(�����L+0H��I��M�u�����I�$H��H�RH�����H��I�������I�$H��H�H�RH��HI�U �=���H��I������I�$H��H�H�RH��HI�U �����I�$H��H������H��L� �*����T$?H� H�߈��   �t���H��������/����    H��H�����������     H������H� �@ �����@ H������H�l$(H(H���(���H�E ������    A�G�   L��H����������fD  A�W������    L��H���M���I������L��H���*���I�������   �    H������H��I�������H� H��I�D$�����H� L�`�)���H�~]  H��H���7���H�=�\  1��I���H���a���H�8 tH���S���H� �x	t&H���R���H�5D]  H��1�������   H�������H������H� H�@H�x t�H������H� H�@H�@H� H�x8 t�H�������H� H�@H�@H� H�@8�ffff.�     AWAVAUI��ATUSH��H��   ����H��L� ����H�H��L��D�2H��H��Y���Ic�H��HH)�H������
  H�5�[  �   �   H������H�5[  �   �   H��H�D$(�����H�D$ H�D$(H��H�p����H�T$ H��H�r�п��H�L$8H��@m�L  E1����  �L$P�D$    A�   E1��l$���L$h�:�     M����   �|$L��  l$A��H���D���L� D;l$�\  H���.���H�|$(M��L� H�o�  Ic�I��H�E H�D$ H�h�D$��D9��-  M����  Ic�I�D�H�E H���X���H�(H��H��H�(�6���H;(��  H���5���H��H�(����L+ �   H��I��D�e H�t$8�]���H�߉�胿����L� �����|$L����A��������HcD$E1�L�t$HD$XL�d$0A��D�l$@H��    ��D����H�I�T�I��H��I��f.�     L��I�݃��z���I�7L(L��H��I���4���A9�I�E �D��L��L�t$D�l$@L�d$0l$����D  H���`�������� �L$D)�Lc�M���6  �I*�fW��X�f.�[  �X
  I���L$L���*����   H��H��I������H��������t$PL��L��A�t5 A�   Hc�H��H0�����L$�L$�����fD  H��������^��� H�������T$PH� A�T Hc�H�������H���`����T$hH� D�Hc�H�������Lcd$�|$L�W  H���2���H�l$`H(L��H�������H��H���Խ��H��H�E 蘽��H��H�������H� HD$`H�E H�Ĉ   []A\A]A^A_�L��L��H���H	��H*��X�����H������H�|$`H8H�|$@H������H� �@"�D$h�   ����tJH������H� �@"�D$h    ����t+H���Ǽ��H� �@"�D$h   ����tH��������D$hH�T$8H��H�L�pX����H�������H� H�����   �D$o�"���H��H���W���H������H��I������� H��A�E �F���H��H������H������H� H��ƀ�   �1���H� L�hM���1  I�E A�E(   H��A�E ����H� H�@    �ڼ��H� H��L�8�|���Hc�H��H��I)�L+ I��M�g�_���I�U H��H�RH��,���H��I���A���I�U H��H�H�RH��HI�$賻��H��I������I�U H��H�H�RH��HI�$�J���I�U H��H��[���H��L�(�P���H� H��D�` �A���H� D;`$�  H���,���L� H������A�D$ H������H� H��L�`����H� H��Hc@ H��H��H��H)�I�fA�$�����H��L�(�c���L+(H��I��E�l$�/���H� H��I�D$�O���H��L�(����L+(H��I��E�l$����� H��A�D$�ѿ��H� A�D$I�D$H�L$8I�L$ H��@A�D$L I�D$X    A�D$HH��x���  H���)���H� �@#���A�D$MH�|$8H��B�����B~H�L��H�ߋP����H������H�0�!   H��軼��H������H�L$8H��H�HcJI�VH��H�贺��H��I���پ��H� ��H�@I�$H�|$8H�H�@8�D$    H�D$P�(  �D$   E1��l$D  H�T$(M��H�B��  Lc|$K��H��D$H�|$ ��;D$H�o��  M����  K�D�H��H�E ����H�L$PH��H��Ƹ��H���H���)���H��L�(莼��L+(I��A��E��~	M����  �D$E��~iD��H�L$@L�l$0��E��E1�H�H��   HcD$I��H�,��     H��A��輸��H� H��J�4 I���I���H�E H��E9��L�l$0Dl$�|$9|$�����H�T$8�B���B  �����B�F  H�L$8H��H��h�2���H� H��H�h�#���H�H�ߋJ Hc���H��H���J H��H)�H�苻��H���c���H�UH��H�脷��H��I������HcUH��H��HI�$�����UH�߉����H�UH��H��Ʒ��H��L�(蛶��H� H�hH����  H���c���H� H��L� ����L+(H��I��M�l$����H�U H��H�RH�辷��H��I���Ӻ��H�U H��H�H�RH��HI�$�E���H��I��誺��H�U H��H�H�RH��HI�$�ܷ��H�U H��H������H��H�(�2����T$oH� H�߈��   �|���H�������|$hLcd$������|$ �����L�d$@D�l$1�I�4$H�߃�I���ڶ��A9��Lcd$������   H���������x���H�=�R  1�蘶���e���H���k���H��H���й��H�L$XJ�T!�H��HH�U �����H������H� �@ �����f.�     �L$+L$Hc�H����   �H*�fW��X�f.S  ��  H���L$H��虹���   H��H��I��膸��H�D$@H��L��J�4��B����L$�D$   �L$����D  H���@����I��� Lc|$H�L$@J������D  H�T$@J�D�����f�     H��H��H���H	��H*��X��<����A�   H��H�����������H�t$8H���5�������H��H�����������   �    H��莺��H��I���ӳ��H� H��I�E�ĳ��H� L�h����H���p���H�8 tH���b���H� �x	t&H���a���H�5SO  H��1�� ����   H������H���+���H� H�@H�x t�H������H� H�@H�@H� H�x8 t�H�������H� H�@H�@H� H�@8�H��N  L��H��蒸��H�5]  H�=qN  1�蝷��D  AWAVAUATUH��SH��H��   �����H��L� �q���H�H��D�*H��H��L���Ic�H��HL��H)�H��H���҉T$�,  HcD$A��H��D�l$HH��I)�L�d$X����HcT$HH�L$xE1�H�T$PH��H�|$PH�T$`H� H�T$pH�4�H������H��H�D$(�&���H� �@"�D$D�   ����tOH������H� �@"�D$D    ����t0H������H� �@"�D$D   ����tH�������D$DD  �D$�-
  H�5�M  �   �   H���ܲ��H�5�L  �   �   H��H�������H�D$H�uH��迱��H�D$H��H�p讱��H�T$(H��@m�  �|$�D$$    �!  �L$H�|$PA�   H�l$8�D$$    H�l$��L�,�   �L$4��   @ H��H�$蔵��H� H�$N�t(L�2H��荱��H�H��H��H�H�$�g���H�$H;�"  H���b���H�H��H�$�C���H�L$H+H��H�$H��H���H�t$(1�����H��觱��H��蟱��H� H�0H��t9�F����   H�H��t%H�@H����  �|$D��   �    �T$$ A��I��D9d$�   H���@���H� H��H�D$H�D$8L�p藴��H� N�<(M�>D;d$4H�U�����H��H�$袵��H�$I�������fD  ����   H�H�x �������v����|$D�f���H��A��I���&����T$$T$HL��H��Hc�H��HH�$�ղ��H�$H��H�D�|$$����L��H��A��D|$HMc�I��L8裲��I��D$$D9d$�����     �|$D�M  �l$D����   H���)���H�|$XH�8H�Ĉ   []A\A]A^A_��    ��tKH�fW�f. ����	�������H�������H�F�80���������D  H���p�������� H��������������H������Hct$$H�l$`H��H(諲��H��H�E ����H��H������H� HD$`H�E �B��� H���Ȳ��H�L$`HH�|$(H�L$HH�H��L�hX����H���_���H� H�����   �D$o虯��H��H���ή��H��膯��H��I��苲��� H��A�$轮��H��H��蒰��H���
���H� H��ƀ�   設��H� L�`M����  I�$A�D$(   H��A�D$ ����H� H�@    �O���H� H��L�0����H�T$XH+H��H��H��I�F�ֱ��I�$H��H�RH�裮��H��I��踱��I�$H��H�H�RH��HI��+���H��I��萱��I�$H��H�H�RH��HI��î��I�$H��H��Ԭ��H��L� �ɬ��H� H��D�` 躬��H� D;`$�E  H��襬��L� H�������A�D$ H��荬��H� H��L�p�~���H� H��Lc` L��I��H��I)�O�$&fA�$�v���H��L�0�۰��L+0H��I��E�t$觲��H� H��I�D$�Ǭ��H��L�0�,���L+0H��I��E�t$�X���� H��A�D$�I���H� A�D$ I�D$H�L$(I�L$ H��@A�D$L I�D$X    A�D$HH�D�HE����  H��蟬��H� �@#���A�D$MH�D$(H��B�����B~H�T$(L��H��H��P脯��H��茱��H�0�!   H���,���H���t���H�L$(H��H�HcJI�UH��H��%���H��I���J���H� H�@I�$H�|$(�|$H�H�P8�D$$    �H  �D$H�l$8A�   L�l$HH�Ճ��D$4�H�     H�H��t%H�@H����  �|$D��   �    �T$$ A��I��D9d$��   H�T$8M�uH�BL�0D;d$4H�L$H�Q�$  M�}L�:H���U���H��H�(�
���H���H���m���H� H�0H��t��F���^�������  H�H�x �������l����|$D�\���L��H��A��轫��HcT$$H�L$HH��L��I��H��D�t$$蛫��H�|$HA��Mc�J���D$$D9d$�#��� H�T$(�B����  �����B��  H�L$(H��H��h膩��H� H��L�`�w���H� H�ߋP Hc��H��H���P H��H)�I�,,�ޭ��H��趯��H�UH��H��ש��H��I���<���HcUH��H��HI�$�e����UH�߉�X���H�UH��H�����H��L�(����H� H�hH����  H��趪��H� H��L� �X���L+(H��I��M�l$�D���H�U H��H�RH�����H��I���&���H�U H��H�H�RH��HI�$蘩��H��I�������H�U H��H�H�RH��HI�$�/���H�U H��H��@���H��H�(腭���T$oH� H�߈��   �Ϫ��H���7����|$DH� H�D$X�����D�D$$E��t*L�d$HD�l$$1�fD  I�4$H�߃�I���%���A9��H������H��H���M���HcT$$H�L$PH�T�H��HH�U ����fD  �   H���+����������H�=�D  1�赨�������     H���`���H� �@ ����@ H��H�$����H�$I���������t;H�fW�f. ����	��������H���d���H�F�80���������D  H��� ����������H�|$(�   �GH��H��蟪������f�H�t$(H����������H��H���˩�������   �    H���D���H��I��艦��H� H��I�D$�y���H� L�`�����H�"B  H��H���۫��H������H�8 tH������H� �x	t&H������H�5�A  H��1�裦���   H��膨��H���Ϊ��H� H�@H�x t�H��踪��H� H�@H�@H� H�x8 t�H��蛪��H� H�@H�@H� H�@8�ffffff.�     AWAVAUI��ATUSH��H��x迦��H��L�8�4���H�H��D�"H��H�����Ic�H��H(L��H)�H��H������
  H������H�H��H�T$�����H�L$0H+L��H�T$H��H��H���1��3���H���[���H���S���H� H�0H����   �F��ttH�H���   H�@H���
  �|$L�w	  H������H�l$@H(H���ߣ��H��H�E ����H��H���X���H� HD$@H�E H��x[]A\A]A^A_�D  ��tkH�H�x ������u���I��A9��g���L�d$XH��蔣��H��H�������J������HH�U �H��H�T$����H�T$H�D$(����@ ����  H�fW�f. ����	�����    �   H��裨�����M���H�=l?  1��-����:���H���p���H�t$@H0H��H�t$8I�E H�@XH�D$讧��H������H� H�����   �D$0�@���H��H���u���H���-���H��H�D$�0���H�T$� H�߉�_���H��H���4���H��謦��H� H��ƀ�   �J���H� H�PH���"	  H��B(   H���B ����H� H�@    H�T$����H� H��H�H�L$莥��Hc�H�L$H��H��I)�L+8I��L�y�l���H�T$H��H�
H�IH�H�T$�0���H��I���E���H�T$H��H�
H�	H�IH��HI�H�T$诡��H��I������H�T$H��H�
H�	H�IH��HI�H�T$�>���H�T$H��H�
H�H�T$�F���H�T$H��H��6���H� H��D�x �'���H� D;x$�b  H������L�8H���g���A�G H�������H� H��L�x����H� H��Hc@ H��H��H��H)�I�fA�����H�H��H�T$�F���H�T$H+H��H��A�W����H� H��I�G�/���H�H��H�T$菦��H�T$H+H��H��A�W跢��� H��A�G詥��H� A�G M�o I�GI�E �@A�GL I�GX    A�GHI�E D�PE����  H������H� �@#���A�GMI�U �B�����B~I�E H�t$H�ߋP�����H�������H�0�!   H��蜢��H������I�U H�t$H��HcJH�VH��H�蔠��H��I��蹤��H� ��H�@I�I�E H�@8H�D$�  �E��   L�|$8L�l$P�l$XM���D$(L�d$8��M�wI�EL�0;l$(H�L$ H�Q�/  M�gL�"H������H�t$H��H�0�Ȟ��H���H���+���H� H�0H����  �F���8  H�H���l  H�@H���N  L�l$PL�t$ M��L�d$8A�E���H  ����A�E�i  I�E H�߃h虝��H� H��L�h芝��H� H�ߋP Hc��H��H���P H��H)�I�l- ����H���ȣ��H�UH��H�����H��I���N���HcUH��H��HI�U �w����UH�߉�j���H�UH��H��+���H��L�0� ���H� H�hH���P  H���Ȟ��H� H��L�(�j���L+0H��I��M�u�W���H�U H��H�RH��$���H��I���9���H�U H��H�H�RH��HI�U 諝��H��I������H�U H��H�H�RH��HI�U �B���H�U H��H��S���H��H�(蘡���T$0H� H�߈��   ����H���J����|$L�(���H��觠��H�l$@H(H��H�t$ �b���H�E J�,�   H���~���I��L L��H���=���H��I�$����H��I���V���H(I�,$�����f�H��谛��H� �@ ����@ H���ȡ����������     H���'  �    ��I��9l$X����L�d$8L�l$PA�E���  ����A�E��  I�E H�߃h�2���H� H��L�h�#���H� H�ߋP Hc��H��H���P H��H)�I�l- 艟��H���a���H�UH��H�肛��H��I������HcUH��H��HI�U �����UH�߉����H�UH��H��ě��H��L�0虚��H� H�hH����  H���a���H� H��L�(����L+0H��I��M�u����H�U H��H�RH�轛��H��I���Ҟ��H�U H��H�H�RH��HI�U �D���H��I��詞��H�U H��H�H�RH��HI�U �ۛ��H�U H��H�����H��H�(�1����L$0H� H�߈��   �{���H�������B���fD  ����   H�H�x �������������I��9l$X�3������� H������H�l$@H(H��H�t$�Ü��H��H�E ����H�l$PH(H��H�t$(袜��H��H�E �V���H��H��軝��H� HD$PH�E H��x[]A\A]A^A_��     H��H�T$軞��H�T$I������fD  H���N���H�F�80�����8���D  ����   H�fW�f. ����	�������@ H���h������� A�E�   L��H���K����V���fD  L��H��蕘�������     H�F�80��������fD  L��H���U��������     H���P������w�����    H��蹞��H��H�D$�����H�T$H� H��H�BH�T$����H�T$H� H�P����L��H�����������L��H���ך���p���H�g3  L��H��� ���H���X���H�8 tH���J���H� �x	t&H���I���H�5;3  H��1������   H���˙��H������H� H�@H�x t�H�������H� H�@H�@H� H�x8 t�H�������H� H�@H�@H� H�@8�@ AWAVI��AUATI��USH��H����L��L�(脗��H�L��HcH��H��_����kH��HI)�I��D�l$I�$E��@8�D$,��  Hc�L���*���H��H�l$0H��H�T$8H� L�<�A�G���  ���1  %  �=  ���  I�E1��H*@�D$ �|$��  H�D$0A�   H�,�   ��   �    H�S�B��   E1��   H��L��L������H����  �P���  H�H����  H�RH����  �T$,������tP�C��tH�SI��A�   �Bu5����  %  �=  ���  H�I��E1��H*@�D$ �    A��H��D9l$��   L������H� E��H�(�3����C���������  %  �=  ���  H��H*HE��t2A�G���m  %  �=  ���  I��H*@�D$ fD  �D$ f.���   D�d$,E����E1���J���A��H��D9l$I���L$ �A���L���&���H�T$0H� L��L�<�袕��L��H������H� HD$8H�H��H[]A\A]A^A_�D  I�WA�   �B����������������  I�E1�� �D$ �����D  ����   H������� D�\$,E�����+����     H����  �D$,�����
  H��� ���H�L$ H�D� H���Έ��H��H���3���H� HD$(H�E H��X[]A\A]A^A_�H�F�80��������fD  A�F���f  ����A�F�w  I�H�߃h�F���H� H��L�`�7���H� H�ߋP Hc��H��H���P H��H)�I�,,螋��H���v���H�UH��H�藇��H��I�������HcUH��H��HI�$�%����UH�߉����H�UH��H��ه��H��L�(讆��H� H�hH���  H���v���H� H��L� ����L+(H��I��M�l$����H�U H��H�RH��ч��H��I������H�U H��H�H�RH��HI�$�X���H��I��轊��H�U H��H�H�RH��HI�$����H�U H��H�� ���H��H�(�E����T$?H� H�߈��   菈��H�������H���_���D�L$H�(E�������H��趆�������f�     H���Ћ��������H�@XH��H�D$�w���H���ϊ��H� H�����   �D$?�	���H��H���>���H�������H��I�������� H��A�$�-���H��H������H���z���H� H��ƀ�   ����H� L�`M���:  I�$A�D$(   H��A�D$ ����H� H�@    迆��H� H��H�H�T$�\���Hc�H�T$H��H��I)�L+(I��L�j�:���I�$H��H�RH�����H��I������I�$H��H�H�RH��HI�U 莅��H��I������I�$H��H�H�RH��HI�U �%���I�$H��H��6���H��L� �+���H� H��D�` ����H� D;`$�g  H������L� H���\���A�D$ H������H� H��L�h�����H� H��Lc` L��I��H��I)�O�d% fA�$�ׄ��H��L�(�<���L+(H��I��E�l$����H� H��I�D$�(���H��L�(荊��L+(H��I��E�l$蹆��� H��A�D$誉��H� A�D$ M�t$ I�D$I��@A�D$L I�D$X    A�D$HI�D�PE����  H������H� �@#���A�D$MI��B�����B~I�H�t$H�ߋP����H�������H�0�!   H��蚆��H������I�H�t$H��HcJH�VH��H�蓄��H��I��踈��H� ��H�@I�$I�H�@8H�D$� ���L�d$0A�   �< H�H����   H�P�   H����   D9������A��I��D9������H���ׅ��H� I�T$H��H�@H�� ���H�T$H��H�谂��H���H������H� H�01�H��t��F���r�����tEH�H�x �����y���f.�     H����������� H��蠁��H� �@ ����@ ��tSH�fW�f. ����	����'����     1�����f�     H��t�H�F�80���������f�     H���`����������A�F�   L��H�����������L��H���3�������L��H���#�������L��H����������L��H�������y����   �    H���l���H��I��豀��H� H��I�D$血��H� L�`����H�J  L��H������H���;���H�8 tH���-���H� �x	t4H���,���H�5  H��1��ˀ���   H��讂��H�=]  1��Є��H������H� H�@H�x t�H���҄��H� H�@H�@H� H�x8 t�H��资��H� H�@H�@H� H�@8�f�     AWAVAUATI��USH��H��H�߀��H��L�(�T���H�H��D�2H��H��/���Ic�H��H(L��H)�H��H�����   A��H��D�t$,�����HcT$,H� H��L�4�L�$�    ����H�L$8H�T$0E1�L��H��L�8����H��H�D$ ��
  ���q  M�H��A�   L�|$軂��H� H��H�p�<��H�T$ L�|$H��@m��  D  H������H� H��H�D$�x���H� I�WH��H�@H��R��L�(H��I��L�(�0���L;(�7  H���/��H��L�(����H�T$H+H��H��1�H��A�E H�t$ �R���H���z��H� H�0H����   �F��tkH�H��tzH�@H����   H��L��貂��H��H(观��Dt$,H� Mc�J��H��H�E ���H��H��聂��L L�e H��H[]A\A]A^A_� ��t;H�H�x ������u�A��I��D9������H��L���5���H��H(�Z������tCH�fW�f. ����	���� H��t�H�F�80�����@ H���(������� H���x������{����     H��L�pX����H���t���H� H��D���   �~��H��H����}��H���~��H��H�D$衁��H�T$� H�߉��}��H��H�����H������H� H��ƀ�   �|��H� H�PH���  H��B(   H���B ����H� H�@    H�T$�b~��H� H��H�H�L$�����L+(H�L$H��I��L�i����H�T$H��H�
H�IH�H�T$�}��H��I�������H�T$H��H�
H�	H�IH��HI�M H�T$�)}��H��I��莀��H�T$H��H�
H�	H�IH��HI�M H�T$�}��H�T$H��H�
H�H�T$�{��H�T$H��H��{��H� H��D�h �{��H� D;h$��  H���{��L�(H�������A�E H���t{��H� H��L�h�e{��H� H��Hc@ H��H��H��H)�I�fA�E �^|��H�H��H�T$���H�T$H+H��H��A�U膁��H� H��I�E�{��H�H��H�T$����H�T$H+H��H��A�U�/~��� H��A�E�!���H� A�E I�EH�L$ I�M H��@A�EL I�EX    A�EHH�D�XE���]  H���}{��H� �@#���A�EMH�L$ H��B�����B~H�L��H�ߋP�h~��H���p���H�0�!   H���~��H���X���H�L$ H��H�HcJI�VH��H��	|��H��I���.���H� H�@I�E H�T$ L�l$H�L�p8�D$   f�H���}��H� I�UH��H�@H��z��H��L�0�oz��H���H����z��H� H�0H���B  �F���  H�H���*  H�@H���  H�T$ H��x��  H�L$ �Q���Q����  H�L$ ���҉Q�@  �hH���6y��H� H��L�h�'y��H� H�ߋP Hc��H��H���P H��H)�I�l- �}��H���e��H�UH��H��y��H��I������HcUH��H��HI�U �|���UH�߉���H�UH��H���y��H��L�0�x��H� H�hH���K  H���ez��H� H��L�(�}��L+0H��I��M�u��|��H�U H��H�RH���y��H��I����|��H�U H��H�H�RH��HI�U �Hy��H��I���|��H�U H��H�H�RH��HI�U ��y��H�U H��H���w��H��H�(L���2}��H� H��D���   �z��H����x��H���P|��H��H(�E|���T$T$,H� Hc�H������fD  H���w��H� �@ ����@ ����  H�H�x ������������D$I��;l$�f���H�T$ H��x�R  H�L$ �Q���Q���L  H�L$ ���҉Q��  �hH���w��H� H��L�h��v��H� H�ߋP Hc��H��H���P H��H)�I�l- �^{��H���6}��H�UH��H��Ww��H��I���}��HcUH��H��HI�U ��y���UH�߉��|��H�UH��H��w��H��L�0�nv��H� H�hH���  H���6x��H� H��L�(��z��L+0H��I��M�u��z��H�U H��H�RH��w��H��I���z��H�U H��H�H�RH��HI�U �w��H��I���~z��H�U H��H�H�RH��HI�U �w��H�U H��H���u��H��H�(�{��H� H��D���   �Tx��H���v��������    ��tCH�fW�f. ����	��������     H�������H�F�80���������D  H���p{���������H�D$ �   H�߃@H����x������H��H���/x��H�T$ H������H��H���x��H�T$ H������R�����R�}���H�t$ H����t��H�L$ H�����H�t$ H����t��H�L$ H��d�����    H���G{��H��H�D$�t��H�T$H� H��H�BH�T$�qt��H�T$H� H�P����H�  L��H����y��H�=m  ��x��H����x��H�8 tH����x��H� �x	t&H����y��H�5�  H��1��t���   H���mv��H���x��H� H�@H�x t�H���x��H� H�@H�@H� H�x8 t�H���x��H� H�@H�@H� H�@8�fD  AWAVAUI��ATUSH��H��(�t��H��L�8�$t��H�H��Hc*H��H���w��A��H��H(I�E A��I)�@8I��E���D$��   Mc�H����w��L��L�d$H��A��H�T$H� J�,�~GN�,�   A�   �    H���w��H� H��H��N�4(L����t��;D$ID�A��I��E9��H���^w��H�T$H� H��H�,���s��H��H���?w��H� HD$H�E H��([]A\A]A^A_�@ Mc�H��I���w��L��H(H���3x��H��H�E �s��H��H����v��L L�e H��([]A\A]A^A_�fffff.�     AWAVAUI��ATUSH��H��X�?s��H��L�8�r��H�H��Lc"H��H��v��H��A�l$I��L I�E M)�D�`8��r��H� I���@# ��   H���s��H��L�(�r��H� H�@I�D� H�D$@1�A����E���D$,��   A���3  A���I  E��ulH��Hc��v��H��H��I��L �w��H��I�$�sr��H��I����u��H(I�,$H��X[]A\A]A^A_�f.�     H���t��H�D$@�k���fD  Hc�H���u��H��H�l$8H��H�T$HH� H�4�F���Q  H�V�B�C  H��H�t$@�   H���s��fW�L�t$@�D$   H�D$0    �D$ A���R  H�D$8A�   I��H�,�   �   �A�F
 List::Util::_Pair::   %s object version %-p does not match %s%s%s%s %-p       Scalar::Util::looks_like_number Can't use string ("%.32s") as %s ref while "strict refs" in use set_prototype: not a reference  set_prototype: not a subroutine reference       Odd number of elements in pairvalues    Odd number of elements in pairkeys      Odd number of elements in pairmap       Odd number of elements in pairgrep      Odd number of elements in pairfirst     Not a reference at List::Util::unpack() argument %d     Not an ARRAY reference at List::Util::unpack() argument %d      Odd number of elements in pairs               �C;     �i��    s��p  �t���   |���  p}��  �~��8  p���x  �����  �����  �����  ����    ���P  Ј���  �����  `����   ���   ����(   ���X  ����  �����  Ж��H  �����  �����   ���8  �����  ����  ����X  �����  �����  ���H  �����             zR x�  L      �h��b	   B�B�B �B(�A0�A8�Gp�
8A0A(B BBBI    $   l   �q���   M��M��I0�
GL   �   0s��H   B�B�B �B(�D0�D8�D�@
8A0A(B BBBB   $   �   0z��K   M��V0����
C  $     X{��w   M��N0���
D    <   4  �|��w   B�B�D �A(�G0�
(A ABBG     $   t  �}��2   M��M��I0��
F $   �  ��   M��V0����
H  $   �  ���   M��M��I0��
J ,   �  ����   M��[@����
C       ,     h����   M��[@���� 
H       ,   L  ȃ���   M��N0���
A�
E     $   |  H����    M��N0���
A    ,   �  �����   M��M��N@���
K       $   �  �����   M��M��I0�
D$   �  ����   M��M��I0��
G ,   $  ����2   M��[P����I
G       L   T  �����   B�B�B �B(�A0�A8�Gp�
8A0A(B BBBG    L   �  `���h   B�B�B �B(�A0�A8�G`
8A0A(B BBBG    L   �  ����H   B�B�B �B(�A0�A8�G`�
8A0A(B BBBI     L   D  �����	   B�B�B �B(�A0�D8�G��
8A0A(B BBBG   L   �  ���   B�B�B �E(�A0�A8�J��
8A0A(B BBBA   L   �  Ш��1
8A0A(B BBBH   d   4  �����   B�B�B �E(�A0�A8�G��
8A0A(B BBBF�	
8A0A(B BBBI d   �  ����   B�B�E �B(�D0�A8�D��
8A0A(B BBBF�
8A0A(B BBBI L     �����   B�B�B �B(�A0�D8�DP1
8A0A(B BBBD    L   T   ���   B�B�B �B(�A0�A8�Gp�
8A0A(B BBBG    L   �  ����G   B�B�B �B(�D0�A8�G��
8A0A(B BBBA   L   �  ����*   B�B�B �B(�D0�A8�G��
8A0A(B BBBD   \   D  ����b   B�B�B �E(�A0�A8�G`�
8A0A(B BBBE8A0A(B BBBd   �  �����	   B�B�B �E(�A0�A8�G��
8A0A(B BBBKH
8A0A(B BBBF          ��������        ��������                ��             T
             �+      
       �
                           X�             �
                            !             �             x      	              ���o    h      ���o           ���o    *      ���o                                                                                                                                                                                                                                                                                                                                                                                           ��                      ,      ,      .,      >,      N,      ^,      n,      ~,      �,      �,      �,      �,      �,      �,      �,      �,      -      -      .-      >-      N-      ^-      n-      ~-      �-      �-      �-      �-      �-      �-      �-      �-      .      .      ..      >.      N.      ^.      n.      ~.      �.      �.      �.      �.      �.      �.      �.      �.      /      /      ./      >/      N/      ^/      n/      ~/      �/      �/      �/      �/      �/      �/      �/      �/      0      0      .0      >0      N0      ^0      n0      ~0      �0      �0      �0      �0      �0      �0      �0      �0      1      1      .1      >1      N1      ^1      n1      ~1      �1      �1      �1      �1      �1      �1      �1      �1      2      2      .2      >2      N2      ^2      n2      ~2      �2      �2      �2      �2      �2      �2      �2      �2      3      3      .3      >3      GCC: (GNU) 4.4.7 20120313 (Red Hat 4.4.7-9) GCC: (GNU) 4.4.7 20120313 (Red Hat 4.4.7-4) ,              4      ��                      R       I�  6T  boot_List__Util �U  XS_Sub__Util_subname �V  XS_Sub__Util_set_subname �X  XS_Sub__Util_set_prototype �Y  XS_Scalar__Util_openhandle eZ  XS_Scalar__Util_looks_like_number H[  XS_Scalar__Util_isvstring \  XS_Scalar__Util_isweak �\  XS_Scalar__Util_isdual �]  XS_Scalar__Util_tainted d^  XS_Scalar__Util_readonly G_  XS_Scalar__Util_unweaken 0`  XS_Scalar__Util_weaken �`  XS_Scalar__Util_refaddr �a  XS_Scalar__Util_reftype �b  XS_Scalar__Util_blessed �c  XS_Scalar__Util_dualvar rd  XS_List__Util_shuffle `e  XS_List__Util_pairvalues Hf  XS_List__Util_pairkeys 0g  XS_List__Util_reduce �i  XS_List__Util_pairmap am  XS_List__Util_pairgrep �p  XS_List__Util_pairfirst �t  XS_List__Util_min Jv  XS_List__Util_unpairs Fw  XS_List__Util_pairs [x  XS_List__Util_any �{  XS_List__Util_first �~  XS_List__Util_minstr �  XS_List__Util_sum     E�       '  �
  �;   x(  �;   4-  �B   I*  �B   �
  �^   l  �^   �  �^   A  �^     �  z(  B{   :
  Qp   C  n  �	  <�     L�   q  �B     �W   �{  �  {    	B   �  
B    �   f  �  y�  �(  z�    �,  {^    )  ,  �    0  	 �  	^   �  
B    +  �
$"    
)�   �  
*W   �   
+�  �  	�  2  
B     �  
d"  W   
  _�   �  `�  �
  a�  �!  bW   2  cW   q  dW    �'  e�  ( [  
B      �/  ";  |  #W   

  $�    �'  %  @g    A�    �  Bp    G�  �-  HW    9+  IW   �/  J;   O�    P�    �  Qp   �/  R;    W    X�    �  Yp   �   ZW   �(  [�   @
  \�    a    b�     g<  %  h^    S)  iW    p;�  �-  <�  �  CF    Kg  _rt S�  �  ]�  �(  c  (  j   	W   �  
B    �%  �4�  d#  5W    v$  6W   �  8W   �"  k<   �+  l�     W      �    �  �    
B   
B    tm 8��  �   �W    �  �W   �"  �W   �#  �W   �  �W   �  �W   n  �W   �  �W   �  �W    ?*  �^   (�
B   � �
  'q  W0  (�    �  )�   T  *4   �!  +-   r  ,   DIR �|    IV �^   UV �B   NV \�  �  �"  =	P  OP D	�  op ( |	  k  !�)   �  !�)  &  !�?  4  !T>  �  !;   	 K  !;    �
  k  ��)   �  ��)  &  ��?  4  �T>  �  �;   	 K  �;    �
  
��  �  "
6   !Iop &�)  �  (
6  X	  *
6  �  +
6   �  -�+  (�  .'  0�  /'  42  1;Q  86   3'  � Q,  4'  � �  6
6  � �.  7'  �   8'  � 70  9'  � �  :'  � �  =�+  � �  ?�+  � $  @�+  � !ISv Bc'  � �(  CAQ  �!Ina P�  �a&  T'  �_  U'  �A-  V*  �?  Wc'  �K  Z�  �.  ^�4  �!Irs pc'  �  q*  �  rc'  ��   s*  ��	  t�  �|/  uc'  ��  vc'  �T  wc'  �  z�+  ��  {�+  ��  }�)  �=/  ~GQ  ��(  
  ��+  �X&  �*  �,  �*  �/  �  ��  ��  ��	  ��+  ��  ��+  �q,  �c'  �e  �l3  �  �E*  ��(  �'  �]0  �  ��  �  �  �RQ  ��  ��P  ��  �'  �"  �'  ��/  ��  �	=  �  �	�-  �bQ  �	~)  �hQ  �	  �'  �	  ��&  �	�  �  �	�  �  �	C#  �nQ  �	�&  �  �	X/  �I   �	
  �'  �	).  �W   �	d.  ��  �	�  �*  �	-  �*  �	(/  �*  �	�%  �  �	d	  �c'  �	�  �c'  �	�  �c'  �	�*  �sQ  �	u  ��  �	�$  �  �
�  �  �
�$  �  �
�$  �  �
�$  �  �
�$  �  �
-$  �  �
�  �  �
$$  �  �
�  ��&  �
l  �  �
�  �  �
7)  �  �
   ��&  �
|  �  �
�  �  �
�*  �  �
�	  �c'  �
�  �E  �
~  �c'  �
b+  �'  �
W  �'  �
�  '  �
U  W   �
�  =  �
�
  	*  �
�   
*  �
�'  *  �
=  *  �
�$  
n.  
�  *  �
  *  �   *  ��#  *  �D  0*  �q  1c'  �=&  2c'  ��  3c'  �p  4
  �=  ��0  �
  �c'  ��  �c'  ��,  �c'  �3  �c'  ��&  �c'  �  �c'  �>   c'  ��!  c'  ��  c'  ��   c'  �L+  c'  �'  c'  ��  �+  ��   �-  �`,  �  �  	�Q  ��  
�&  ��(  W   ��  �Q  �-    ��  
6  �z  
6  �y  ,�Q  ��,  -
6  ��  ;
*  U�P  �L  W
  w�+  ��  �W   �Q  ��Q  ��  �gP  ��+  �'  �Y
  j'  � t#  k�+  � �	  n'  � GP ^	I  gp P�  �  c'     
�I  �  '  $  '  c%  
K;   �  �    �  �  �;     �;   ;  �+  ( �  k	+"  �-  0�"  �-  kK   d  /  �  /  �  !�K     %�K   ;  &�+  ( �  l	�"  �  0S�"  �-  `�F   �'  a�  �  b�  �  i�F     mG   ;  n�+  ( �  m	�"  
  5?  � �  6=  � �&  7'  � �.  :�<  �  `  q	)$  
>  � G"  ��  � I
  ��  � *  ��  � .  ��  � q!  �  � �*  �*  � Q  �  � �0  �*  ��  �  ��  �*  �9  �  �Q  ��&  � �  r	a%  �  @�%  D+  L   p  L  �  9L  �  L  �  L   <,  hL  (*  �L  0@!  L  8 ANY s	�%  "any �<&  #  ��   #P&  �'  #    
   $C)  � �    &W   � 4,   *W   � v+   ,�   � �   04   �0   1I   �/   2I)  ��   6Y)  �z+   ?�   ��#   H�   ��   I�   ��#   J�   ��#   K�   ��#   LP  �-   NW   �\    P_)  � $�   ��   �=)     �=)   O   �C)  F   �W    )  i'  	  Y)  
B     )  	  o)  
B    �0  !cz)  �/  �/  !e�)  o)  ]  !z�)  �    "7  �  #��)  <-  #�'  
%  %'   �  &'  `  'c'  [  (c'  W   )'   �  `+�*  �  ,�*    	P*  �*  
B    
  �W    �&  �  u Yl2   *.  &��.  �#  �].   !%  �'  cp �.   &��.  �#  �].   !%  �'  cp �.  �
  .  (�"  
  <.  �  =  !  >'   �  ?'  $ &8B�1  �#  D].   c1 E'  c2 E'  cp F.  l  G'  �  H'  �  I  A J�.   B J�.  (me K�.  0 &@Nl2  #  O'   cp P.  c1 Q'  c2 Q'  �  R  R  S  �  TW    min UW   $max UW   (A V�.  0B V�.  8 '@�3  (yes �.  #�  �c.  #�
B   1 3  �-  f3  
  ).35  *k   *�  *�  *m#  *Z'  *�&  *%  *�  *  *�  	*�  
*4  *U  *�  
  E   HEK Z�5  hek �5  N  '   �(  '  �#  I)   r
6  5  r�  	'  r�  	  rc'  �  r    r
6  )  r6  )(  r6   c'  6  >5  >  x6  5  �  	'  �  	  c'  �      
6  )  6  )(  6   �"  ��6  5  ��  	'  ��  	  �c'  �  �    �
6  )  �6  )(  �6   I#  �07  5  ��  	'  ��  	  �c'  �  �    �
6  )  �6  )(  �6   "  ��7  5  ��  	'  ��  	  �c'  �  �    �
6  )  �6  )(  �6   �"  ��7  5  ��  	'  ��  	  �c'  �  �    �
6  )  �6  )(  �6   $  &�8  $  �'   �,  �'   &�C8  �  �'   E  ��&  �  ��&   '�}8  #�  ��  #�  ��+  #<  ��7  #s
>  #P-  ��4  #�.  ��+   '�,>  #�!  �,>  #,  ��    q  �)  -     $1  PAD $1  �  $B   �>  $  '   �,  '   �>  �  '   E  �&  �  �&   �>  �  �  �  �+  <  _>  s
B    	  7A  ,B   � 	  GA  
B    �.  H()�A  �  (*     (+  s  (,^   �  (-^   �  (.^    \#  (/^   (�  (1^   0f  (3^   8\  (5B   �  -H)r�D  �  )t   �  )uP  �  ){�D  
  )�  ��  )�P  �E  )��  ��"  )�  ��	  )�P  �:	  )��D  ��  )�W   ��  )��  �n%  )�  ��  )�P  ��
  )P  ��*  )�D  �L#  )C  ��  )  �  )P  ��   )  ��*  )P  �  )W   � }@  @@  
-  �YI  1  ��)    'P�I  #N%  �G  #�  +H  #H  �H  #�  >I   |	  
  j
  k
  *P   7   *'  �0  *
  *8'  � V!  *9c'  � -  *:'  � R   *;'  � 8#  *<  �i  *=  �.  *>  ��+  *?  �e  *A�L  �/  *Bc'  ��
  *C  ��  *D  ��  *E  �  *F  �"  *G  ��  *H  ��$  *I  ��  *J('  �f  *K'  �"
B    	'  �O  
B    I  *l3M  <&  P    (  H"P  (P  %W   8P  W'   <  IDP  JP  [P  W'  c'   .&  J"P  %#  LsP  yP  %  �P  W'  c'   
  H]�P  pad ^�P    	�  �P  
B      g�P  �P  �P  W'  �)   &  w�P  �P  %'  Q  W'  c'  c'   
B    `3  3  .�&  yQ  �  �  /Q  	�   �Q  
B    .'  	�&  �Q  
B   	 �O  q&  E  �)  �   )+rS  *   *�-  *�  *�  *]  *�  *j&  *�  *m  *�   	*/	  
*0  *�  *�  
  *�  *�   *�  *�  *�.  *�%  *  *�"  *�  *�  *�.  *�%  *  *�"  *|  *!  *A0  *�*   *�  !*�  "*�/  #*�*  $*�!  %*�   &*�  '*�.  (*R  )*(  **   +*�  ,*e   -*&	  .*�  /*�/  0*  1*�  2*F  3*p  4*�  5*$&  6*�,  7*�  8*�0  9*�  :*�  ;*�   <*^(  =*0*  >*�   ?*�  � *Z  � *�#  � *�  �  /�+  E�S  *Q"   *  *�&   0�  �  �S  1�  �  1K  ��   0q(  g  �S  1�  g  1K  g�   0n  1�   T  1�  1�   1K  1  1�  1P   2t  KrS  6T  3sv Kc'   4�   4      �=      ��U  5�  W'      6cv =  I   7�  W   8sp 
6  l   8ax '  �   9"  
6  @  :Q0  '  ;  �  
K�      �<    #U  8_sv c'  �  8vn �  y  9?%  �    =`   9�  c'  R    >5      �:      HU  8cv =  �   <�   �U  9   /�+  �  9�*  0*  �  9�  1c'  5   =�   9�  r�U  l    �  4�  ��=      4?      ��V  5�  �W'  �  6cv �=  �  7�  �W   8sp �
6  "  8ax �'  �  9"  �
6  Y  :Q0  �'  =   9�  �c'  �  8cv =  �  8gv *  %  <@  rV  9�  +�U  x   ?�>      ?      9�  (�U  �     4@
6  �	  8ax `'  �
  9"  `
6  j  :Q0  `'  =p  9  i  �  8sub jc'  4  8cv �=  �  8gv �*  �
6  [  9  �  ~  >TB      kB      qX  8_sv �-  �   ?�E      F      8_sv �-  �    =  8_sv -  (     4�   0�F      �G      ��Y  5�  0W'  r  6cv 0=  �  7�  3W   8sp 3
6    8ax 3'  �  9"  3
6    :Q0  3'  =P  95  <c'  3  9�  =c'  �  8cv �c'  �  ?WG      qG      9�  ��U  (     4i  �G      WI      �_Z  5�  W'  L  6cv =  �  7�  W   8sp 
6  �  8ax '    9"  
6  �  :Q0  '  =�  8sv c'  �  =�  8io w_Z  %  ?�H      �H      9�  ��U  �      "  4},  �`I      �J      �H[  5�  �W'  �  6cv �=  �  7�  �W   8sp �
6  :  8ax �'  q  9"  �
6  �  :Q0  �'  <  %[  8sv �c'  K  9�+  �c'  �  9�  `c'  �   ?%J      ?J      9�   �U  �    4~  ��J      L      �\  5�  �W'    6cv �=  `  7�  �W   8sp �
6  �  8ax �'  �  9"  �
6  h  :Q0  �'  =P  8sv �c'  �  ?�K      �K      9�  V�U  	     4�)  } L      $M      ��\  5�  }W'  -  6cv }=  v  7�  �W   8sp �
6  �  8ax �'  �  9"  �
6  ~  :Q0  �'  =�  8sv �c'  �  ?�L      �L      9�  5�U       4�  �0M      LN      ��]  5�  �W'  C  6cv �=  �  7�  �W   8sp �
6  �  8ax �'     9"  �
6  �   :Q0  �'  =�  8sv �c'  �   ?�M      �M      9�  ��U  5!     4�  �PN      �O      �d^  5�  �W'  Y!  6cv �=  �!  7�  �W   8sp �
6  �!  8ax �'  �"  9"  �
6  #  :Q0  �'  <  A^  8sv �c'  ^#  :�+  �W   97  �-  �#   ?AO      [O      9�  ��U  �#    4�  � P      �Q      �G_  5�  �W'  $  6cv �=  c$  7�  �W   8sp �
6  �$  8ax �'  E%  9"  �
6  �%  :Q0  �'  <P  $_  8sv �c'  @&  9�+  �W   �&  97  �-  �&   ?�P      Q      9�  ��U  '    4�/  J�Q      3S      �0`  5�  JW'  :'  6cv J=  �'  7�  MW   8sp M
6  �'  8ax M'  (  9"  M
6  �(  :Q0  M'  <�  `  8sv Tc'  )  8tsv c'  x)  ?�R      �R      8_sv '-  �)    =   9�  x�U  �)    4x&  2@S      T      ��`  5�  2W'  �)  6cv 2=  ?*  7�  5W   8sp 5
6  �*  8ax 5'  �*  9"  5
6  4+  :Q0  5'  <P  �`  @sv <c'   ?�S      �S      9�  E�U  �+    4�  T      �U      ��a  5�  W'  �+  6cv =  ,  7�  W   8sp 
6  p,  8ax '  -  9"  
6  �-  :Q0  '  <�  �a  8sv c'  �-  9�+   �  L.  97  !-  �.   ?�T      U      9�  -�U  �.    4�  ��U      �W      ��b  5�  �W'  /  6cv �=  L/  7�  �W   8sp �
6  �/  8ax �'  .0  9"  �
6  �0  :Q0  �'  <�  �b  8sv c'  1  9�+    j1  97  -  �1   ?�V      �V      9�  �U  �1    4�  ��W      OY      ��c  5�  �W'  �1  6cv �=  C2  7�  �W   8sp �
6  �2  8ax �'  3  9"  �
6  �3  :Q0  �'  <   uc  8sv �c'  
6  �5  8ax �'  �5  9"  �
6  P6  :Q0  �'  =@  8num �c'  �6  8str �c'  �6  =�  97  �-  B7  =�  9�  ��U  �7      4%  ^�\      ^      �`e  5�  ^W'  �7  6cv ^=  �7  7�  aW   8sp a
6  8  8ax a'  R8  9"  a
6  �8  9Q0  a'  �8  =�  9�(  |W   *9  > ^      +^      8e  9�  ��U  �9   =P  9�
6  �:  8ax �'  �:  9"  �
6  I;  ;Q0  �'  ��=�  9s  IW   z;  9�  JW   �;  >�_      �_      2f  :�  W�U   =�  8b Qc'  <     4�  ��_      8a      �0g  5�  �W'  3<  6cv �=  |<  7�  �W   8sp �
6  �<  8ax �'  �<  9"  �
6  H=  ;Q0  �'  ��=  9s  3W   y=  9�  4W   �=  >�`      �`      g  :�  A�U   =@  8a ;c'  �=     4Y  �@a      k      ��i  5�  �W'  <>  6cv �=  �>  7�  �W   8sp �
6  �>  8ax �'  Z?  9"  �
6  �?  9Q0  �'  *@  =�  9�  �c'  b@  =�  8ret 2c'  �@  9�(  3W   5A  8agv 4*  �A  8bgv 4*  B  Agv 4*  ��;?  5�+  ��9+  6
6  �B  8cv 7=  �B  <0	  |i  :;  G
6  8cx GK  lC  9�"  G=  �C  9�  G�)  �C  9-!  G  dD  9�  G�&  �D  9�
  H'  ;E  <�	  �h  8sp T
6  �E  9|
i  8_sv T-  F   =
  9�  J�i  dF  8cv J�i  �F  9�
  J�i  G  <p
  Xi  9  JLQ  �G   ?�f      �f      9�$  J�i  H     <�
  �i  8sp Z
6  PH   ?�c      �c      9�  e�U  �H      LQ  =  
6  �I  8ax �'  ~J  9"  �
6  K  9Q0  �'  oK  =   9�  �c'  �L  =p  8agv *  M  8bgv *  fM  Agv *  ��;?  �+  ��8cv =  �M  9�
  	
6  N  9�
  
'  HO  9s  W   �O  9�  
6  �Q  @a Oc'  @b Pc'  9�  SW   kR  8i TW   &S  =P  9+  \W   qS    <�  Hm  9m
6  �S  9�
  '  �S  8i W   .T  :;   
6  8cx  K  �T  9�"   =  �T  9�   �)  MU  9-!     �U  9�   �&  V  9�
  !'  OV  < 
6  �V  9|
  #�i  �X  >�r      s      0m  9�$  #�i  EY   =�  9  #LQ  �Y     =0  9�  t�U  ,Z      43  o0y      a�      ��p  5�  oW'  PZ  6cv o=  �Z  7�  rW   8sp r
6  �Z  8ax r'  �[  9"  r
6  C\  9Q0  r'  t\  =`  9�  {c'  �\  =�  8agv �*  ]  8bgv �*  �]  Agv �*  ��;?  ��+  ��8cv �=  <^  9�
  �'  �^  9s  �W   �^  9�  �W   �_  >X�      ��      �n  9�  ��U  q`   <  �n  9�  ��U  �`   <@  wp  9m
6  �`  8i �W   %a  :;  �
6  8cx �K  \a  9�"  �=  �a  9�  ��)  	b  9-!  �  Xb  9�  ��&  �b  9�
  �'  c  <�  �o  9�  ��i  >c  8cv ��i  �c  9�
  ��i  �c  <   �o  9  �LQ  Qd   ?��      ��      9�$  ��i  �d    <p  p  8a �c'  %e  8b �c'  �e  =�  8_sv �c'  �e  =P  9g  �AQ  (f     <�  7p  8_sv �-  `f   <�  Qp  9�$  ��i  �f   =�  8sp �
6  �f  9|
6  �g  8a �c'  �g  8b �c'  Rh  =�  8_sv �c'  �h  =  9g  �AQ  i        46  p�      �      ��t  5�  W'  Ci  6cv =  �i  7�  W   8sp 
6  �i  8ax '  �j  9"  
6  �l  9Q0  '  �l  =@  9�  c'  Tn  =�  8agv `*  �n  8bgv `*  �o  Agv `*  ��;?  a�+  ��8cv b=  ap  9�
  c'  �q  9s  dW   �q  <0  r  8sp �
6  �r  8a �c'  �r  8b �c'  �s  <�  Nr  8_sv �c'  )t  =0  9g  �AQ  �t    <`  hr  9�  ��U  �t   =�  9�  ��U  u    <�  �t  9m
6  ,u  :;  r
6  8cx rK  �u  9�"  r=  )v  9�  r�)  �v  9-!  r  �w  9�  r�&  >x  9�
  s'  �x  <p  �s  8a wc'  by  8b xc'  
6  �z  9|
  u�i  `~  <   *t  9  uLQ     ?�      "�      9�$  u�i  v    <p  gt  9�  ��U  �   <�  �t  8_sv �-  ;�   >�      �      �t  9�$  ��i  q�   =�  8sp �
6  ��  9|
6  ށ  Fax �'  �  G"  �
6  ��  GQ0  �'  ��  Fix �'  �  =   G�(  bW   -�  GQ  c�  w�  G�)  dc'  +�  G[  eW   8�  <p  �u  G�  h�U  m�   <�  3v  G�  pc'  ��  G�0  qc'  �  <  v  Gg  sAQ  ��   =P  Fval |�  ��    =�  G�  ��U  g�     4O  � �      �      �Fw  5�  �W'  ��  6cv �=  Ԉ  7�  �W   8sp �
6  ��  8ax �'  <�  9"  �
6  ��  9Q0  �'  !�  =   8i W   W�  9�
  
6  ��  >�      >�      w  9�  +�U  ׋   =P  9  c'  �  9�  
6  �  8ax c'  N�  9"  c
6  ��  ;Q0  c'  ��=�  9s  �W   ��  9�  �W   N�  9<  ��+  ��  >��      ��      (x  :�   �U   =0  8a �c'  ��  8b �c'  �  8av �
6  -�  8ax '  ��  9"  
6  ��  9Q0  '  Ǒ  8ix '  I�  =�  9�  #c'  ��  =�  9^  �W   �  9�  �W   S�  Agv �*  ��;?  ��+  ��9+  �
6  ݓ  8cv �=  ?�  <`  �y  9�(  �W   ��  =�  8sp �
6  Ҕ  =    8_sv �c'  ^�  =�   9g  �AQ  �      <�   �{  :;  �
6  8cx �K  -�  9�"  �=  ��  9�  ��)  �  9-!  �  ؗ  9�  ��&  y�  9�
  �'  �  9�(  �W   a�  <`!  |z  8_sv �c'  ��  =�!  9g  �AQ  ��    <�!  �z  9�  ��i  -�  8cv ��i  ��  9�
  ��i  1�  <P"  �z  9  �LQ  ֛   ?"�      %�      9�$  ��i  F�    <�"  {  8sp �
6  ۜ  9|
6  !�  9|
6  E�  8ax �'  ��  9"  �
6  A�  9Q0  �'  r�  =�#  9�  �c'  �  =0$  9�(  nW   0�  Agv o*  ��;?  p�+  ��9+  q
6  ��  8cv r=  {�  <�$  t~  :;  }
6  8cx }K  ۢ  9�"  }=  7�  9�  }�)  ��  9-!  }  �  9�  }�&  [�  9�
  ~'  ��  <�$  u}  8sp �
6  ߤ  9|
6  ��  9|
  �i  ��  >��      ��      \~  9�$  �i  
6  �  =0'  8_sv �c'  D�  =�'  9g  �AQ  ��     =�'  9�  ��U  �      4�  S��      �      ��  5�  SW'  �  6cv S=  Y�  7�  VW   8sp V
6  ��  8ax V'  ٪  9"  V
6  7�  9Q0  V'  h�  8ix Z'  ��  =�'  9$.  c'  ګ  9�(  
6  m�  Fax �'  ��  G"  �
6  e�  GQ0  �'  ��  Fix �'  ߯  =�(  G7  �-  ��  Fsv �c'  ԰  G`!  ��  j�  G�%  ��  ��  G�)  �c'  ��  G�(  �W   �  G�+  �rS  M�  G�  �W   ��  G�0  �c'  �  <�(  �  G�  ��U   �   IT  ��      )  �<�  J+T  $�   IT  ;�      P)  �]�  J+T  ��   =�)  G�  ��U  ��     EP!  ,�C)  E�  ,�C)  	  ��  K 7I  {��  ��  7�+  ���  ��  7�(  �́  ��  L�  VU%  	@�      EP!  ,�C)  E�  ,�C)  7I  {�  ��  7�+  �"�  ��  7�(  �5�  ��  7�  W    %  $ >  $ >   :;I      I  :;  
! I/  :;  & I  
  5 :;I  6 :;I  74 :;I?<  84 :;I  94 :;I  :4 :;I  ;4 :;I
  <U  =U  >  ?  @4 :;I  A4 :;I
  B.?:;'@
  C :;I  D :;I  E4 :;I?<  F4 :;I  G4 :;I  H4 :;I  I1RUXY  J 1  K!   L4 :;I
   y   m  �
��	 ����4�f�|��<K�#9��|�?��/;K�f�|#x��$���~�>?�2�|<�<�|��<�|X.>�
J�����Q�g�=�;K��v>�;K1�;YA�w����wX�(.�v�'<��gH��	$KWKu;	�&=�J�|<?Iuh�� ��{�Z��rf�hM#0�"�|0-0g�I>�Rf1t��y��� ����7.�=�| y�#yfM��#9�!;��|ȟ�K�ziY���|�
����| ��.�>6��|��^�
X�4�|����Zp9�JT��5��|��X�ȭ;K>��|/u<Jt*�J_�#5��}��I���|"����#6��}.�<�}�%���}$���~�#5��}��&���}&����X(6�":��}����.�x%�}���)a�(6�":��}��J�}<��5�x*�}X�J�}J�t�}X�����>6��}XL���J�}��	J��X�}<K�t�}#z�t�}<�.�}J�X�} ��"�>5i�}��<�}<��"t�\�(5�:��}���J)�s-�}�ɑ�#r�\t#5�:��}����)�s��}�ɑ�#r�[�#5�:��}��/���r#�}�)��q@�.(6�!;��~��<�~X����ut)�;K�f�})�	)'u�/5qt�=�%sz����F��~%�<�~��X�~t�<�~<�!;�K;�;!,;uFYY�+�~J%��~��~F��t�~g���?9/I5�(�~JK� ��~F��>9K�9KIM%?9Q�(�~fK�~�>C*Ni�f� <��\8@Y-=Z:>i�w<	XY�=�W=���#�Sk��9Y�G;K;�vyBQyX.=� ��Jm��W�#�;=�:MUܟ�p�zst
<�a����=K�N9���:0Z:>f�Pe=ՃW=I� f�~�
�u7�=Z�y��7y���#X�&;K���~ ��Ki�;=�Ym����9M��H>��yX�3;K�K����~X ���gsuWH�K� .�-ȃ7�=�yX�.�vtk�!�_"!8���~ �h<*NiyX	Jw<_��~����~��X�~X=;Yk���=ɻ" z.�pX�pX	t�J;ɼ�5%pX/�;Yu-׭t<�*;��Ks�.�����~�@
�qwqy�F���~ �|�>;HJ8<Hti#�+��-3�x5/�:L
 "Y2n&�n�f�;K� ��<>,yrtP�w8(v�� 9�f(H[�	t�<o�
8v��$<�~<�$�~JG?9Y�=Z�|��<�|X� ����(�l��l�<lJg=؄�v�Z"jtJj�JjJ<jJf�-�~ tro���v� X�*� ���ZVZj:�~@YI=7O/h:0�;=w<	JwXg�I��.�(�~JK(�>8FO-Kk�f� <��-YZ:>yf@�
.w<I�^>�z<�z(�;Y�:vJ;Y;�uA7@v��)� ��~�ot��yXi��;=\(�:v�Ch�yh
5�.�R<�>��� )�Wu��*� JsC
 �      ��      �      
 �      ��      �      
 �      �                y       �       ��      b	       ��                �       �        P�       �        P�       �        ]k      �       ]�      b	       ]                "      %       PO      Y       P�      �       P�      �       P�      �       P             P>      A       P�      �       P�      �       P             PG      J       P                             P      �       ]�      �       ]                !      I       p I      \       \�      �       \                \      c       p c      �       \                �      �       1�                p	      �	       U�	      �
       S�
             S                p	      �	       T�	      �	       \             \                �	      �	       p �	      �	       V�	      0
       vx�0
      q
       V�
      �
       V�
      �
       vx��
             vx�             V                �	      �	       p �	      �	       ^�	      �	       ~��	      �
       ^�
             ^             ~�                �	      �	       ~  $ &3$p "�                �	      �	       ~ 3$p "�	      �
       ]�
             ]                
      S
       }�
      �
       }�
      �
       }                '
      S
       }#H�
      �
       }#H�
      �
       P                f
      }
       1�                �
      �
       0�                       8       U8      x       \      h       \                       8       T8             V�             V<      f       V      $       V)      C       VH      `       V{      �       V�      �       V      (       V?      h       V                D      H       PH      |       ��|      d       ��@�d      u       Su             p       �       ��@��      �       ���      h       ��@�                Q      \       p \      ]       S]      �       s��      8       S�      f       S      `       S{      �       S�      �       s��      h       S                ]      l       s  $ &3$p "�                �      �       ]�      �       ���      z       ]z             ��      <       ]f      �       ]�      h       ]                �      �      	 s 3$p "#�      |       ^      <       ^f      �       ^�      h       ^                �             0�      v       V      �       V�             0�f             V      `       0�`      {       V{      �       0��      �       V�             V      (       0�?      h       0�                �      �       P             P                �      �       _�      �       p �      ~       _      <       _f      �       _�      h       _                :      >       s�W      [       s�[      �       S�      �       Sf      �       S�      �       S�      �       S                �      :       0�:      {       R{      �       ��      �       R�      �       R�      �       S�      <       0�      `       0�{      �       0��      h       0�                �      �       v # �      [       S�      �       S�      �       P�      �       S�             S`      {       S                �      �       P�      �       ]                �      �       P�      �       ��f      s       Ps      �       ���      �       ���      �       ��                �      �       ���      �       ���      �       ��                
)       V
)      )       v�)      �)       V                �)      �)      	   $ &��)      *       _                )      )       R)      �)       ��                7)      E)       R                `*      u*       Uu*      �+       S�+      �+       S                `*      u*       T                �*      �*       P�*      �*       ��                �*      �*       \�*      �*       V�*      �*       P�*      �+       ���+      �+       V                �*      �*       |  $ &3$p "�                �*      �*       0�9+      ;+       VN+      c+       V�+      �+       0�                �*      �*       0��+      �+       0�                �*      
       T                �+      �+       U�+      �,       S�,      -       S                �+      �+       T                �+      �+       P�+      ',       ��                �+      ,       \,      D,       VD,      K,       PK,      �,       ���,      -       V                ,      ,       |  $ &3$p "�                ',      K,       0��,      �,       \�,      -       0�                ',      K,       0��,      -       0�                m,      q,       p v "q,      z,       p v "@                 -      8-       U8-      �/       S�/      �6       S                 -      8-       T8-      �-       V?6      Q6       V                D-      H-       PH-      |/       ��~�/      *1       ��~Q5      h5       ��~�5      �5       ��~6      _6       ��~                R-      ]-       p ]-      ^-       \^-      �-       |��-      �-       \�-      ?6       ��?6      Q6       |�Q6      �6       ��                ^-      m-       |  $ &3$p "�                }-      �-       Q�-      �6       ��                �-      �-      	 ��3$p "�-      .       \�5      �5       \Q6      _6       \                �-      �-       P�-      �/       V�/      �5       V�5      ?6       VQ6      �6       V                }.      �.       2��.      �.       \m/      |/       \3      3       2�3      '3       \�3      �3       \                .      (.       P(.      �.       \�/       0       \Q5      h5       \                1.      8.       P8.      |/       ^�/      q4       ^Q5      �5       ^�5      ?6       ^                �-      �-      	 p ��"��-      .       } ��"��5      �5       } ��"�Q6      _6       } ��"�                �-      .       P.      �/       _�/      ?6       _Q6      Z6       PZ6      �6       _                �1      �2       \4      }4       \�5      �5       \                �2      Q5       _�5      6       __6      �6       _                3      3        #83      Q5       ��~�5      6       ��~_6      �6       ��~                0      0       P0      Q5       ��h5      �5       ���5      ?6       ��_6      �6       ��                �/      Q5       0�h5      �5       0��5      ?6       0�_6      �6       0�                �/      f4       0�h5      �5       0��5      ?6       0�                q4      u4       p u4      �4       ^_6      �6       ^                }4      �4       p�4      Q5       \_6      �6       \                �3      Q5       _�5      6       __6      �6       _                �/      Q5       _h5      �5       _�5      ?6       __6      �6       _                �/      Q5       _h5      �5       _�5      ?6       __6      �6       _                �/      �/        #X�/      Q5       ��h5      �5       ���5      ?6       ��_6      �6       ��                _0      h0       ph0      S1       \6      6       \6      "6       P"6      ?6       \                z2      Q5       _�5      6       __6      �6       _                �.      �.       ��~�.      �.       P�.      |/       ��~�/      �/       ��~                �/      �/       1�                 7      7       U7      :       S:      R:       \R:      �;       S�;      E       S                 7      7       T7      �8       ]�;      �<       ]�B      �B       ]�D      �D       ]                "7      &7       p &7      d7       \d7      �8       | v  $ &3$��;      )=       | v  $ &3$��B      �B       | v  $ &3$�D      PD       | v  $ &3$��D      �D       \                37      >7       p >7      ?7       ^?7      \7       ~�\7      �8       ^�8      �D       ���D      �D       ~��D      E       ��                ?7      \7       ~  $ &3$p "��D      �D       ~  $ &3$p "�                P7      �8       V�8      �:       ��~�:      �:       ��~�:      S;       ��~�;      �;       ��~�;      �?       V�?      �@       ��~�B      �B       V�B      �B       V�B      fC       ��~fC      {C       ��~{C      �C       ��~�C      �C       VD      PD       V�D      �D       V                �7      �7       p q "�7      �7       p q "�7      �7       p ��"                L8      P8       PP8      �B       ��~�B      �D       ��~�D      E       ��~                V8      [8       P[8      �B       ��~�B      �D       ��~�D      E       ��~                �7      �7       P�7      �D       ��~�D      E       ��~                �7      �8       0��8      �8       ^�9      �9       ^�:      �:       P�:      �:       ^N;      S;       ^�;      �?       0�(@      -@       ^�@      �@       ^�B      �B       0��B      �B       0�MC      QC       PQC      fC       ^�C      �C       0�D      PD       0�                8      �D       ���D      E       ��                8      �8       1��8      �8       ]�9      �9       ]�9      �9       }~��:      �:       0�N;      S;       ]�;      �?       1��@      �@       ��~�B      �B       1��B      �B       1��C      �C       1�D      PD       1�                8      �8       0��8      �8       ��~�9      :       ��~�:      �:       ��~N;      S;       ��~�;      �?       0�(@      X@       ��~�@      �@       ��~�B      �B       0��B      �B       0�fC      {C       ��~�C      �C       0�D      PD       0�                �B      �B       \                �8      �8       \9      9       p 9      �9       \�9      �9       p �9       :       \ :      [:       ��~[:      N;       \�;      �;       \                �8      �8       V�9      �9       P�9      �9       V�9      �9       P�9      H:       ^H:      [:       Vm:      �:       VN;      S;       V�;      �;       V                �9      :       0�;:      @:       V�:      �:       0�                w:      �:       R�;      �;       R                �;      �;       U�;      �B       ���B      �D       ��                T<      �B       ���B      �D       ��                (@      X@       0��@      �@       _TB      kB       0�~B      �B       VfC      {C       0�                >      J?       \A      tA       V�C      �C       \                ]?      �B       ��~�B      �C       ��~�C      D       ��~PD      �D       ��~                v?      �?       ��~#8�?      �B       ���B      �C       ���C      D       ��PD      �D       ��                �<      �<       P�<      �B       ���B      �D       ��                T<      �B       0��B      �D       0�                T<      ]A       1��B      PD       1�                hA      lA       p lA      �A       ]PD      �D       ]                tA      �A       p�A      kB       VPD      �D       V                �@      �B       ��~PD      �D       ��~                �@      �B       ��~�C      D       QD      D       ��~PD      �D       ��~                @      ?@       ]?@      T@       \T@      �@       ]�B      {C       \�C      �C       \                C      >C       R�C      �C       R                T<      �B       ��~�B      �D       ��~                T<      �B       ��~�B      �D       ��~                c<      g<       ��~#Xg<      �?       ^�B      �B       ^�C      �C       ^D      PD       ^                �>      �B       ��~�B      �C       ��~�C      D       ��~PD      �D       ��~                �<      �<       p�<      0>       ]�B      �B       ]D      0D       ]0D      4D       P4D      PD       ]                �;      �;       1�                E      +E       U+E      I       SI      AR       S                E      +E       T+E      pF       VjP      �P       V�Q      �Q       V                2E      6E       p 6E      �E       \�E      �F       \�F       K       ���O      P       PP      �P       ��bQ      �Q       ���Q      �Q       \                @E      KE       p KE      LE       ]LE      xE       }�xE      �F       ]�F      �Q       ���Q      �Q       }��Q      AR       ��                LE      YE       }  $ &3$p "�                iE      �E       Q�E      AR       ��~                �E      �E       p q "�E      �E       p q "�E      �E       p ��"                pF      wF       PwF      �F       V�F      �H       ��~I      �I       ��~�I      M       VM      MN       ��~�P      �P       V�P       Q       ��~ Q      >Q       VbQ      �Q       V                }F      �F       P�F      jP       ��~�P      �Q       ��~�Q      AR       ��~                �E      �E       P�E      �Q       ��~�Q      AR       ��~                8F      �Q       ���Q      AR       ��                8F      �F       1��G      �G       \�H      �H       \�I      (M       1�aM      pM       \BN      MN       \jP      �P       1� Q      >Q       1�bQ      �Q       1�                8F      �F       0��G      �G       ��~�H      �H       _�H      �H       ��~�I      (M       0�]M      pM       ��~6N      BN       ^BN      MN       ��~jP      �P       0� Q      >Q       0�bQ      �Q       0�                8P      jP       ��~� $ &�                �I      �I       1�                �I      �I       R�I      8P       ���P      �Q       ���Q      AR       ��                P      P       0�3P      8P       V                �K      �L       \�N      !O       V Q      >Q       \                �L      8P       ��~�P       Q       ��~>Q      bQ       ��~�Q      AR       ��~                �L      (M       ��~#8(M      MN       V�P       Q       V                
J      J       PJ      8P       ���P      �Q       ���Q      AR       ��                �I      8P       0��P      �Q       0��Q      AR       0�                �I      
O       0��P      �Q       0�                �I      8P       ��~�P      �Q       ��~�Q      AR       ��~                �I      8P       ��~�P      �Q       ��~�Q      AR       ��~                �I      �I       ��~#X�I      M       ]�P      �P       ] Q      >Q       ]bQ      �Q       ]                gJ      pJ       ppJ      IK       \bQ      zQ       \zQ      ~Q       P~Q      �Q       \                hL      8P       ��~�P       Q       ��~>Q      bQ       ��~�Q      AR       ��~                (M      pM       ^�M      �M       }�M      (N       ^�P       Q       ^                (M      pM       _�M      MN       _�P       Q       _                (M      QM       T�M      �M       p �M      �M       T�P      Q       T                3M      QM       t �P      Q       t                 MN      8P       ��~>Q      LQ       QLQ      bQ       ��~�Q      AR       ��~                nN      8P       ��~�Q      AR       ��~                O      O       p O      CO       ]�Q      AR       ]                !O      1O       p1O      P       V�Q      AR       V                �F      �G       ��~�G      �G       P�G      2H       ��~[I      mI       ��~                �F      �G       _H      %H       p } "%H      �H       _I      �I       _                G      �G       ^2H      �H       ^I      �I       ^                �G      �G       p �G      �G       T2H      OH       TI      [I       TmI      wI       T                �G      �G       t @I      [I       t                 PR      hR       UhR      QU       S[U      �^       S�^      �`       S                PR      hR       ThR      �R       ]V`      h`       ]                oR      sR       p sR      �R       _�R      �S        v  $ &3$��S      �S        |  $ &3$��U      W        v  $ &3$��_      6`        v  $ &3$�V`      h`       _                }R      �R       p �R      �R       \�R      �R       |��R      �S       \�S      U       ��[U      �U       ���U      �U       ���U      �Y       \�Y      N\       ��N\      d\       \d\      x\       ��x\      �\       ��J^      �^       ���^      �^       ���^      _       ��_      ;_       ��;_      d_       ��d_      u_       ��u_      �_       \�_      �_       ���_      6`       \V`      h`       |�                �R      �R       |  $ &3$p "�                �R      �S       V�S      U       \[U      �U       \�U      �U       \�U      �Y       V�Y      N\       ��N\      d\       Vd\      x\       \x\      �\       ��J^      �^       ���^      �^       \�^      �^       ���#��^      _       ��_      ;_       \;_      d_       ��d_      u_       \u_      �_       V�_      �_       ���_      6`       VV`      h`       V                �R      �R       p q "�R      �R       p q "�R      �R       p ��"                �S      �S       P�S      U       ^[U      �U       ^�U      �U       ^ V      �Y       ^�Y      7Z       ]N\      x\       ^x\      �\       ]J^      �^       ]�^      �^       ^�^      _       ]_      ;_       ^;_      d_       ]d_      �_       ^�_      �_       ]�_      �_       ]�_      6`       ^                �S      �S       P�S      �U       ��~ V      V`       ��~h`      �`       ��~                �R      �R       P�R      U       ][U      �U       ]�U      �Y       ]�Y      N\       ��N\      x\       ]x\      �\       ��J^      �^       ���^      �^       ]�^      _       ��_      ;_       ];_      d_       ��d_      �_       ]�_      �_       ���_      6`       ]                PS      V`       ��h`      �`       ��                PS      �S       1�zU      �U       V�U      �Y       1�N\      d\       1��\      �\       Vr^      �^       Vu_      �_       1��_      6`       1�                T      T       PT      �T       ���U      �U       ��d_      u_       ��                #T      U       ��~[U      �U       ��~�U      �U       ��~d\      x\       ��~�^      �^       ��~_      ;_       ��~d_      u_       ��~                `T      U       ��~[U      �U       ��~�U      �U       ��~d\      x\       ��~�^      �^       ��~_      ;_       ��~d_      u_       ��~                �T      �T       p �T      U       T[U      sU       T�U      �U       Td\      o\       T_      ;_       T                �T      U       t _      ;_       t                 0U      LU       1�                �^      �^       2�                8V      IV       TIV      d\       ��x\      �^       ���^      _       ��;_      d_       ��u_      V`       ��h`      �`       ��                7X      jY       _�Z      [       V
]      v]       Vu_      �_       _                |Y      �Y       ]�Y      N\       ��x\      �\       ��J^      �^       ���^      _       ��;_      d_       ���_      �_       ��                �Y      �Y       } #8�Y      �Y       ��#8�Y      N\       ��~x\      �^       ��~�^      _       ��~;_      d_       ��~�_      �_       ��~6`      V`       ��~h`      �`       ��~                cV      gV       PgV      d\       ��x\      �^       ���^      _       ��;_      d_       ��u_      V`       ��h`      �`       ��                8V      d\       0�x\      �^       0��^      _       0�;_      d_       0�u_      V`       0�h`      �`       0�                8V      �Z       0�N\      d\       0�x\      _]       0�J^      �^       0��^      _       0�;_      d_       0�u_      V`       0�                �Y      �Y       �Y      [       ^[      N\       ��~x\      �\       ^J^      �^       ^�^      _       ^;_      d_       ^�_      �_       ^                �Y      DZ       \DZ      N\       _x\      �\       \J^      �^       \;_      d_       \�_      �_       _�_      �_       \�_      �_       _�_      �_       \                2\      N\       2�                [      [       p [      1[       ^                [      [       p[      �[       V                _Z      N\       ��                <Z      N\       ���_      �_       ]�_      �_       ]                Z      Z       p Z      2Z       Tx\      �\       TJ^      g^       T;_      d_       T�_      �_       T�_      �_       T                Z      2Z       t x\      �\       t �_      �_       t                 8V      �Y       ]�Y      N\       ��N\      d\       ]x\      �\       ��J^      �^       ���^      _       ��;_      d_       ��u_      �_       ]�_      �_       ���_      6`       ]                8V      �Y       ]�Y      N\       ��N\      d\       ]x\      �\       ��J^      �^       ���^      _       ��;_      d_       ��u_      �_       ]�_      �_       ���_      6`       ]                EV      IV       } #XIV      d\       ��~x\      �^       ��~�^      _       ��~;_      d_       ��~u_      V`       ��~h`      �`       ��~                �V      �V       p�V      �V       Q�_      �_       Q�_      �_       p�_      `       P                �X      �Y       ]�Y      N\       ��x\      �\       ��J^      �^       ���^      _       ��;_      d_       ���_      �_       ��                E^      J^       0�                �\      �\       ]6`      V`       ]                �\      �\       ]                j]      n]       p n]      �]       ^                v]      �]       p�]      J^       V                �U      �U       0�                 a      a       Ua      �c       ^�c      Ee       ^He      �f       ^                 a      a       Ta      �a       \�c      �c       \�d      Ae       \                a      #a       p #a      Fa       ]                -a      <a       S<a      �a       V�a      �d       ���d      
e       VHe      �f       ��                9a      @a       s  $ &3$p "�                Oa      �a       ]�a      �f       ��                ]a      ma       | #8ma      �f       ��                �a      �a       1��b      �b       ]dc      jc       ]                �a      dc       ��dc      jc       bjc      �c       ���c      d       ��d      d       ad      �d       ��He      df       ���f      �f       ��                �a      �a       v 3$p "�a      Hb       _Hb      �b       S�b      ^c       _dc      jc       Sjc      �c       _�c      �d       _He      qe       Sqe      f       _f      Df       SDf      �f       _�f      �f       S�f      �f       _                �a      �a       0��a      ]b       \cb      �b       0��b      "c       \"c      dc       0�dc      �c       \�c      �c       0��c      d       \d      d       0�d      �d       \He      qe       0�qe      f       \f      Df       0�Df      df       \df      �f       0�                #e      He       1�                �a      �b       S�b      �b       p v "�b      jc       S�c      �d       SHe      df       S�f      �f       S                b      ;b       Pd      -d       P7d      Ld       P�d      �d       P�d      �d       P�e      �e       P�e      �e       P                $b      ;b       p d      -d       p �e      �e       p                 �b      "c       bjd      �d       bqe      �e       b�e      �e       bDf      df       b                �c      �c       1�                �f      �f       U�f      $i       V-i      �i       V                �f      �f       T                �f       g       p  g      0g       \0g      Xg       | s 3$��g      �g       \�g      �g       Q�g      h       w h      1h       \ph      �h       \�h      �h       R�h      �h       w �h      �h       \Ci      ]i       \vi      {i       P{i      �i       | s 3$��i      �i       | s 3$�                
g      g       p g      g       ]g      \g       }�\g      �g       ]�g      {i       ��{i      �i       }��i      �i       ���i      �i       }�                g      #g       }  $ &3$p "�                -g      �h       _-i      �i       _                �g      �g       0�+h      1h       ]�h      �h       ]                ug      yg       Pyg      �g       ^                �h      �h        1$ $ &�                4h      Bh       ~ Bh      Nh       S-i      Ci       S�i      �i       S                �g      1h       SXh      �h       SCi      {i       S                �i      �i       U�i      �k       S�k      �k       S                �i      �i       T                �i      �i       P�i      9j       ��                �i      j       \j      nj       Vnj      �j       R�j      �k       ���k      �k       V                j      #j       |  $ &3$p "�                9j      �j       0�)k      /k       V\k      sk       V�k      �k       0�                9j      �j       0��k      �k       0�                Hj      Nj       PNj      �k       ��                �j      �j       P�j      /k       w Fk      Sk       PSk      sk       w                 �j      �j       _�j      �j       T                �j      �j       P�j      /k       ]\k      sk       ]                �k      �k       U�k      vp       S�p      'x       S                �k      �k       T�k      jl       \sw      �w       \                �k      l       p l      @l       ]@l      �l       } v  $ &3$�pr      Ns       } v  $ &3$�:w      sw       } v  $ &3$�sw      �w       ]�w      �w       } v  $ &3$�                
  2 $0)��w      �w      
  2 $0)�                jl      �l        1��l      p       _�p      sw       _�w      �w       _�w      �w        1��w      'x       _                �l      �l       p ��"��l      sw      
 ����"��w      'x      
 ����"�                �l      �l       P�l      }p       ^�p      sw       ^�w      'x       ^                �l      �l       1�,m      9m       ]                �l      9m       ��Lm      Pm       PPm      �n       ���p      �p       ��Wr      pr       ��Fv      ]v       ��                �l      m       T�m      �m       p �m      	n       T9n      xn       T�p      �p       TWr      gr       T                m      m       t dn      xn       t �p      �p       t                 �n      Yo       V�p      aq       VEt      ku       \�v      �v       \                �n      )p       ^�p      Jr       ^~u      Fv       ^tv      �v       ^�v      :w       ^�w      �w       ^�w      'x       ^                �n      )p       ���p      Jr       ���u      �u       ~ #8�u      Fv       ��tv      �v       ���v      :w       ���w      �w       ���w      'x       ��                �n      )p       ���p      Jr       ���r      �r       P�r      Fv       ��]v      sw       ���w      �w       ���w      'x       ��                �n      )p       0��p      Jr       0�pr      Fv       0�]v      sw       0��w      �w       0��w      'x       0�                �n      Bo       0��p      Jq       0�pr      Fv       0�]v      sw       0�                �u      �u       1��u      �u       ]                �u      �u       Tv      v       p v      Fv       Ttv      �v       T                �u      �u       t �v      �v       t                 �n      )p       ^�p      Jr       ^pr      Fv       ^]v      sw       ^�w      �w       ^�w      'x       ^                �n      )p       ^�p      Jr       ^pr      Fv       ^]v      sw       ^�w      �w       ^�w      'x       ^                �n      )p       ���p      Jr       ��|r      �r       ~ #X�r      Fv       ��]v      sw       ���w      �w       ���w      'x       ��                �r       s       p s      �s       \:w      Rw       \Rw      Vw       PVw      sw       \                �n      )p       ^�p      Jr       ^u      Fv       ^tv      �v       ^�v      :w       ^�w      �w       ^�w      'x       ^                Mo      Qo       p Qo      {o       ]                Yo      io       pio      )p       V                �n      )p       ^                �n      )p       ^�v      
w       ^w      *w       ^                �p      Jr       ^
w      w       ^*w      :w       ^                �p      Jr       ^                Uq      Yq       p Yq      �q       ]                aq      qq       pqq      Ar       V                Rp      �p       1�                0x      Hx       UHx      #z       S-z      Z�       S                0x      Hx       THx      �x       \��      ��       \                Ox      Sx       p Sx      #y       ]�z      �{       ]b�      ƃ       ]                ]x      hx       p hx      ix       ^ix      �x       ~��x      �x       ^�x      ��       ����      ��       ~���      Z�       ��                ix      vx       ~  $ &3$p "�                �x      �y       V-z      Xz       Vpz      �~       Vj�      �       Vq�      ƃ       V                �x      �x       q 3$p "�x      �x       ^��      ƃ       ^                Kz      Xz       ^~      ~       1���      q�       ���      �       ���      &�       ��.�      H�       ��                �x      �x       p | "��x      �x        | "��x      y       _y       z       ��-z      Xz       ��pz      ��       ����      ƃ        | "�ƃ      Z�       ��                �x      �x       P�x      ��       ����      Ń       PŃ      Z�       ��                �|      �}       ]      r       V5�      ��       VЂ      �       ]                ~      j�       ����      Ђ       ���      b�       ��ƃ      Z�       ��                ~      ~       ��#8~      f       ^��      ��       ^q�      Ђ       ^�      b�       ^                �z      �z       p��z      ��       _ƃ      Z�       _                �z      ��       0�ƃ      Z�       0�                �z      [       0�j�      ��       0�q�      ��       0�                ��      ��       p ��      Á       ^                ��      ��       p��      q�       V                ڀ      q�       ���      ��       R��      �       ��.�      H�       ��                f      j       p j      �       ^                r      �       p�      !�       V!�      %�       p                 �~      j�       ���      �       R�      �       ��H�      b�       ��                \~      h~       p h~      �~       T��      ��       Tq�      ǂ       T                t~      �~       t ��      ��       t                 �z      ��       ��ƃ      Z�       ��                �z      ��       ��ƃ      Z�       ��                �z      �z       p� �z      ~       ^j�      ��       ^Ђ      �       ^b�      ��       ^                �}      j�       ����      Ђ       ���      b�       ��ƃ      Z�       ��                T{      ]{       p]{      �{       Qb�      d�       Qd�      p�       pq�      }�       P                ;y      ?y       P?y       z       ��-z      Xz       ��pz      �z       ��                �y      �y       p �y      �y       T-z      Cz       Tpz      �z       T�z      �z       T                �y      �y       t �z      �z       t                 z      -z       1�                `�      x�       Ux�      j�       St�      ��       S                `�      x�       Tx�      �       ]t�      ��       ]                �      ��       p ��      ��       _                ��      ��       V��      ��       \��      t�       ��t�      ��       \                ��      ��       v  $ &3$p "�                ��      s�       _t�      ��       _                ��      ̄       } #8̄             ��                �      ��       | 3$p "��      T�       V                �      ��       1�)�      2�       \                I�      t�       1�                �      �       p } "�      2�       ^                Ѕ      �       U�      ̆       Sֆ      ��       S��      r�       \r�      /�       S/�      Ɖ       \Ɖ      )�       S3�      ��       \��      ̋       S̋      ��       \��      ��       S��      #�       \#�      k�       Sk�      ̍       \̍      �       S�      ��       \��      ��       S��      ��       \��      ��       S                Ѕ      �       T�      G�       ]ֆ      �       ]                �      �       p �      �       _                ��      �       \�      ��       Vֆ      ��       V��      ʈ       ��ʈ      ڈ       V��      /�       V/�      ��       ����      ��       V̋      ��       ��                	�      �       |  $ &3$p "�                /�      Ն       _ֆ      2�       _3�      ��       _                /�      ��       \ֆ      ��       \r�      �       \��      /�       \��             \#�      k�       \̍      �       \��      ��       \��      ��       \                ]�      ֆ       ���      ��       ��                �      �       v 3$p "�      =�       T=�      I�       Q��      �       S%�      ;�       p v ";�      r�       Sr�      ʈ       T��      /�       T/�      Ɖ       S3�      ��       S̋      ��       S��      #�       S#�      L�       Tk�      ̍       S̍      ֍       T�      �       T�      ��       S��      ��       T��      ��       S��      ��       T                ]�      ֆ       0��      j�       0�j�      r�       ��r�      /�       0�/�      ��       ����      ̋       0�̋      v�       ��v�      {�       P{�      #�       ��#�      k�       0�k�      ̍       ��̍      �       0��      ��       ����      ��       0���      ��       ����      ��       0�                ]�      ֆ      
 �        �      j�      
 �        j�      r�       ��r�      /�      
 �        /�      ��       ����      É       aÉ      ��       ����      ̋      
 �        ̋      �       ���      �       b�      #�       ��#�      k�      
 �        k�      ��       ����      ��       b��      ̍       ��̍      �      
 �        �      ��       ����      ��      
 �        ��      ��       ����      ��      
 �                        ]�      ֆ       0��      5�       0�5�      j�       ��j�      �       ^��      r�       ^r�      /�       0�/�      0�       ^3�      ��       ^��      ̋       0�̋      #�       ^#�      k�       0�k�      ̍       ^̍      �       0��      ��       ^��      ��       0���      ��       ^��      ��       0�                j�      ��       1��      �       ]��      Ɖ       ]                5�      j�       2�j�      ��       ����      m�       ��m�      r�       2���      ʈ       1���      /�       1�/�      o�       ��o�      ��       1���      3�       ��3�      t�       1���      Ċ       1�Ċ      )�       ��)�      ]�       1�]�      m�       ����      ��       0�̋      �       1��      {�       ��{�      ��       1���      ��       ����      #�       1�<�      k�       0�k�      ��       1���      ̍       0�̍      �       1��      `�       ��`�      ��       1���      ��       0���      @�       1�@�      j�       ��j�      ��       1�                m�      ��       P��      ֆ       ���      �       P�      ��       ��                ·      ��       Pt�      ��       Pm�      ��       P̋      �       P��      �       Pk�      ~�       P��      ��       P`�      j�       P~�      ��       P�      "�       P,�      6�       P                �      3�       1�                ׇ      ��       Pt�      ��       Pm�      ��       P��      �       P��      ��       P`�      j�       P~�      ��       P                �      �       v 3$p "�      =�       T=�      I�       Qr�      ʈ       T��      /�       T#�      L�       T̍      ֍       T�      �       T��      ��       T��      ��       T                ��      ֆ       1�                �       I�  e   __dev_t p   __uid_t {   __gid_t �   __ino_t �   __ino64_t �   __mode_t �   __nlink_t �   __off_t �   __off64_t �   __pid_t �   __clock_t �   __time_t �   __blksize_t �   __blkcnt_t   __ssize_t   gid_t $  uid_t /  ssize_t :  clock_t E  time_t P  size_t [  int32_t �  __sigset_t �  timespec �  __jmp_buf �  __jmp_buf_tag 2  sigjmp_buf C  random_data �  drand48_data   sigval ;  sigval_t �  siginfo �  siginfo_t   uint32_t '  stat �  tm �  tms �  netent 
  PMOP �  LOOP �  PerlInterpreter �  SV 1  AV x  HV �  CV   REGEXP >  GP �  GV "  IO i  PERL_CONTEXT    MAGIC �   XPV �   XPVIV !  XPVUV i!  XPVNV �!  XPVMG "  XPVAV �"  XPVHV �"  XPVGV I#  XPVCV $  XPVIO U%  MGVTBL �%  ANY q&  PTR_TBL_t �&  CLONE_PARAMS �&  I8 �&  U8 '  U16 '  I32 '  U32 ('  line_t �%  any )  _IO_lock_t )  _IO_marker i'  _IO_FILE o)  PerlIOl �)  PerlIO �)  PerlIO_list_t �)  Sighandler_t �)  YYSTYPE 	*  YYSTYPE *  regnode E*  regnode P*  reg_substr_datum �*  reg_substr_data �*  regexp_paren_pair �*  regexp_paren_pair   regexp �+  regexp �+  re_scream_pos_data_s �+  re_scream_pos_data �*  regexp_engine �-  _reg_trie_accepted �-  reg_trie_accepted .  CHECKPOINT *.  regmatch_state 3  regmatch_state 3  regmatch_slab `3  regmatch_slab l3  re_save_state 35  svtype >5  HE x5  HEK �  sv �  gv �  cv <  av �  hv -  io �   xpv �   xpviv '!  xpvuv u!  xpvnv �!  xpvmg �"  xpvgv �<  cv_flags_t )$  xpvio �&  clone_params I  gp >>  PADLIST I>  PAD T>  PADOFFSET U#  xpvcv �  op �
  pmop �  loop �?  passwd @@  group }@  crypt_data GA  spwd E  REENTR H5  he �5  hek /E  mro_alg �E  mro_meta F  xpvhv_aux �"  xpvhv 5G  jmpenv zG  JMPENV �	  cop �G  block_sub +H  block_eval �H  block_loop >I  block_givwhen �  block �I  subst u  context �J  stackinfo K  PERL_SI +"  xpvav a%  mgvtbl    magic �L  SUBLEXINFO �L  _sublex_info (M  yy_stack_frame 3M  yy_parser �O  yy_parser <&  ptr_tbl_ent }&  ptr_tbl P  runops_proc_t 8P  share_proc_t [P  thrhook_proc_t gP  destroyable_proc_t �P  perl_debug_pad �P  peep_t �P  SVCOMPARE_t Q  exitlistentry /Q  PerlExitListEntry �  interpreter rS  slu_accum     6       9       �      b	      �      �      �       �       @       y                       �       �       �      b	      p      �                      �      w      �      �                      �      �      �      �                      �	      �	      �
            �	      }
                      _
      b
      f
      }
                      |            �      h      �      �      �      p                      �      �      �      �      �             p      �                      
      0      `      {                                    �      �      �      �      p      �      �      Q                            !      �      %      %      �                      <      �      �      %                      �      �      0      �      �                            "      %      �      �      (      �                      c      f      �      �      k      �                      r      u                   x      �                      �      �      `      �      �      !                      H      K            T      O      �                      �      �      �            �      �      �      �      �      �      r      }      @      o      �      '                      o      r      }      �                      y      |            �                      W       Z        !      �!      ]       �                       "      "      �"      P#      "      �"                      �#      �#      �$      %      �#      K$                      �%      �%      �&      P(      �%      &                      �%      �%      �&      P(      �%      &                      a&      d&      h&      &                      �(      �(       *      _*      �(      *      �(      �(      �(      �(                      �(      �(      �)      �)       )      �)                      �*      �+      �+      �+                      �*      +      ;+      P+      6+      9+      #+      3+                      ',      �,      �,      -                      P,      V,      �,      �,      q,      �,      i,      m,      Z,      e,                      �-      �/      Q6      �6      �/      ?6                      �-      �-      Q6      �6      �/      ?6      �-      �/                      �.      �.      _6      �6      �5      ?6      p5      �5      �/      X5                      `4      c4      _6      �6      &5      )5      f4      #5                      �3      �3      �5      6                      �/      �2      6      ?6      �5      �5      p5      �5      �2      3                      I0      L0      6      ?6      A1      D1      S0      >1                      �.      d/      �/      �/      h/      m/                      \7      _7      �D      E      )=      �D      =      "=      �;      =      d7      �;                      n7      v7      �D      E      )=      �D      =      "=      �;      =      �7      �;      7      �7                      �8      �8      �D      E      �;      �;      �8      N;      �8      �8                      �8      �8      �D      E      �;      �;      p:       ;                      �8      �8      �B      �D      )=      �B      =      "=      �;      =                      WA      ZA      PD      �D      B      !B      ]A      B                      �@      �@      �@      �@                      �@      �@      �C      D                      �?      �@       C      �C                      �?      �?      �C      �C       C      �C      -@      `@                      T<      =      D      PD      �C      �C      �B       C      q?      v?      U?      i?      )=      R?      =      "=                      �<      �<      D      PD      �=      �=      )=      �=      =      "=      �<      =                      �;      �;      �;      �;                      xE      {E      �Q      AR       I      �Q      �E      I                      �E      �E      �Q      AR       I      �Q      �E      �H      �E      �E                      �I      �I      �I      �I                      �F      �F      �Q      AR      �P      �Q      �I      8P      �F      �F      �F      �F                      �I      �I      bQ      �Q       Q      @Q      �P      �P      �L      �L      �I      �L                      QJ      TJ      bQ      �Q      7K      :K      [J      4K                      M      M      �P       Q      N      BN      N      N      pM      N      0M      ]M      M      M                      M      M      �P       Q      �M      �M      0M      FM      M      M                      0M      FM      �P      Q                      PN      nN      @Q      bQ                      nN      sN      vN      yN                      O      O      �Q      AR      �O      �O      
O      �O                      �F      �F       I      �I      mH      �H      �G      eH      �F      �G      �F      �F                      �F      �F      pI      �I       I      `I      8H      OH      �G      �G      �F      �F                      �G      �G      @I      `I                      �R      LU      h`      �`       _      V`      W      �^      
W                      �R      �R      h`      �`       _      V`      W      �^      
W      �R      LU                      �S      �S      h_      x_       _      @_      �^      �^      h\      �\      �U      �U      `U      wU      �S      LU                      �S      �S       _      @_      h\      �\      �U      �U      `U      sU      �T      U                      �T      U       _      @_                      )U      ,U      0U      LU                      �^      �^      �^      �^                      �S      �S      h`      �`      x_      V`      @_      h_       _       _      �\      �^      W      h\      
W      �S      �S                      �Y      �Y      �_      �_      @_      h_       _       _      P^      o^      �\      �\      �Y      P\                      +\      .\      2\      P\                      �Z      �Z      �[      �[      �Z      �[                      DZ      _Z      �_      �_      �_      �_                      �Y      �Y      �_      �_      �_      �_      @_      h_      P^      g^      �\      �\      �Y      DZ      �Y      �Y                      Z      DZ      �_      �_      �\      �\                      0V      3V      �_      6`      x_      �_      P\      h\      uY      �Y      W      rY      
W                      �V      �V      �_      6`      �W      �W      W      �W      
W                      �S      �S      �S      �S                      �\      �\      6`      V`                      Y]      \]      h`      �`      ^      "^      _]      ^                      Sa      Va      Pe      �f      �c      9e      ]a      �c                      e       e      #e      9e                      �a      �b      �f      �f      Pe      df      �c       e      [c      dc      �b      Nc                      !b      ;b      �e      �e       d      )d                      �b      Nc      Df      df      �e      f      xe      �e      pd      �d      �c       d      [c      dc                      zc      }c      �c      �c                      0g      Tg      0i      �i      �g      i      \g      �g                      �g       h      �i      �i      0i      {i      �h      �h      �h      �h      �h      �h      1h      �h      'h      +h      h      $h                      j      j      �k      �k      9j      �k                      �j      �j      /k      `k      $k      )k      �j       k      �j      �j                      Dl      qp      �w      'x      Ns      sw      ?s      Gs      �p      <s                      Wl      Zl      �w      'x      Ns      sw      ?s      Gs      �p      <s      jl      qp                      �l      �l      Pv      `v      `r      pr      �p      �p      �l      �n                       m      (m      Pv      `v      `r      pr      �p      �p      9m      �n                       m      m      `r      pr      �p      �p      @n      �n      �m       n                       m      m      �p      �p      hn      �n                      �l      �l      �w      'x      �w      �w      `v      sw      Ns      Pv      ?s      Gs      pr      <s      �p      Jr      �n      )p                      �u      �u      xv      �v      
w                      �p      �p      *w      :w      
w      w                      Dq      Gq      r      r      Jq      r                      �x      �x      ��      Z�      0z      ��      �x      z                      �x      �x      ��      Z�      0z      ��      �x      z                      �x      �x      ƃ      Z�      �z      ��      y      y                      ��      ��      ƃ      Z�      J�      M�      ��      G�                      ڀ      ��      .�      H�      �      �                      U      X      �      �      [      �                      �~      �~      H�      b�      �      �                      N~      �~      x�      Ђ      ��      ��                      q~      �~      ��      ��                      �z       ~      b�      ��      Ђ      �      p�      ��                      >{      A{      b�      ��      Q|      T|      H{      N|                      (y       z      pz      �z      0z      Gz                      �y      �y      �z      �z      pz      �z      0z      Cz                      �y      �y      �z      �z                       z      z      z      z                      ��      ��      x�      ��      ��      e�                      B�      E�      I�      e�                      ��      ��      ��      ��                      	�      �      8�      ��      ��      $�      /�      ǆ      #�      +�                      �      �      �      $�                      ׇ       �      p�      ��      x�      ��                      �      5�      (�      <�      x�      ��                      ��      ��      ��      ǆ                       .symtab .strtab .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .ctors .dtors .jcr .data.rel.ro .dynamic .got .got.plt .bss .comment .debug_aranges .debug_pubnames .debug_info .debug_abbrev .debug_line .debug_str .debug_loc .debug_pubtypes .debug_ranges                                                                                    �      �      $                              .   ���o       �      �                                  8             �      �      �                          @             �      �      �
                             H   ���o       *      *      >                           U   ���o       h      h                                   d             �      �      x                           n              !       !      �
         
                 x             �+      �+                                    s             �+      �+      P                            ~             P3      P3      ��                             �             �      �                                    �             �      �      X                             �             p�      p�                                   �             x�      x�                                   �             ��      ��                                    �             ��      ��                                    �             ��      ��                                    �             ��      ��                                    �             ��      ��      �                           �             8�      8�                                   �             X�      X�      �                            �              �      �      `                               �      0               �      X                             �                      h�      0                              �                      ��      V                                                  ��      I�                                                  7`     �                             (                     .d     }                             4     0               �v     �0                            ?                     �     ��                             J                     0d     �                             Z                     
m     �)                                                   ʖ     h                                                   x�     �      $   6                 	                      @�     �                                                           �                    �                    �                    �                    *                    h                    �                     !                   	 �+                   
 �+                    P3                    �                   
                     
                     $
                     7
                     H
                     X
   ���              _
                     j
                     z
                     �
                     �
                     �
                     �
                     �
                     �
                     �
                     �
                                                               -                     A     �      �      W    p�      �      o    @a      �	      �     4      b	      �   	 �+              �                     �                     �                     �                      call_gmon_start crtstuff.c __CTOR_LIST__ __DTOR_LIST__ __JCR_LIST__ __do_global_dtors_aux completed.6349 dtor_idx.6351 frame_dummy __CTOR_END__ __FRAME_END__ __JCR_END__ __do_global_ctors_aux ListUtil.c subname_vtbl _GLOBAL_OFFSET_TABLE_ __dso_handle __DTOR_END__ _DYNAMIC drand48_r@@GLIBC_2.2.5 XS_List__Util_pairmap Perl_mg_get Perl_Icurstackinfo_ptr Perl_sv_setiv XS_Scalar__Util_isdual Perl_sv_bless Perl_sv_free Perl_save_sptr Perl_Itainting_ptr Perl_get_hv XS_List__Util_sum XS_Scalar__Util_looks_like_number Perl_get_sv PerlIO_printf XS_Scalar__Util_tainted Perl_newRV_noinc Perl_Imarkstack_ptr_ptr Perl_Irunops_ptr Perl_gv_init Perl_newSVpvf_nocontext XS_List__Util_any __gmon_start__ _Jv_RegisterClasses Perl_save_int Perl_Iop_ptr _fini XS_List__Util_pairvalues Perl_Isv_yes_ptr Perl_call_list XS_List__Util_min Perl_Istack_sp_ptr Perl_gv_fetchpv Perl_warn_nocontext Perl_sv_2mortal XS_List__Util_minstr Perl_sv_setpv Perl_Istack_max_ptr Perl_vstringify XS_Scalar__Util_unweaken Perl_form XS_Scalar__Util_reftype Perl_Itmps_floor_ptr XS_List__Util_pairgrep Perl_looks_like_number Perl_newSVsv Perl_sv_setuv XS_List__Util_shuffle Perl_Icurstack_ptr Perl_Icurpad_ptr Perl_sv_cmp Perl_sv_reftype Perl_Isrand_called_ptr Perl_vcmp strlen@@GLIBC_2.2.5 XS_Scalar__Util_weaken XS_Scalar__Util_refaddr Perl_savepvn __cxa_finalize@@GLIBC_2.2.5 Perl_my_exit Perl_sv_rvweaken Perl_Imarkstack_max_ptr Perl_newXS_flags Perl_pop_scope Perl_sv_upgrade Perl_save_vptr XS_Scalar__Util_isvstring Perl_gv_SVadd Perl_call_sv Perl_sv_setsv_flags strcat@@GLIBC_2.2.5 Perl_sv_free2 Perl_stack_grow Perl_block_gimme Perl_Iscopestack_ix_ptr Perl_sv_mortalcopy XS_List__Util_pairs Perl_sv_2uv_flags XS_Scalar__Util_blessed Perl_sv_newmortal XS_List__Util_first Perl_sv_setnv memcpy@@GLIBC_2.2.5 XS_List__Util_pairkeys Perl_Idefgv_ptr Perl_safesyscalloc __bss_start XS_Scalar__Util_isweak Perl_save_pushptr XS_Scalar__Util_openhandle Perl_newSV Perl_mg_set Perl_IDBsub_ptr Perl_pad_push Perl_Iunitcheckav_ptr Perl_Ireentrant_buffer_ptr Perl_newSViv PL_no_usym Perl_hv_common_key_len XS_Scalar__Util_dualvar XS_Sub__Util_set_subname Perl_Isv_no_ptr strcpy@@GLIBC_2.2.5 Perl_mg_find Perl_Istack_base_ptr XS_Sub__Util_subname Perl_croak_nocontext PL_no_modify _end Perl_Itmps_ix_ptr Perl_Istderrgv_ptr Perl_safesysmalloc Perl_sv_copypv Perl_seed Perl_newSVpv Perl_amagic_call XS_Scalar__Util_readonly Perl_mg_size Perl_av_push Perl_sv_2iv_flags Perl_Itop_env_ptr XS_Sub__Util_set_prototype Perl_gv_stashpvn Perl_gv_stashpv PL_memory_wrap Perl_croak_xs_usage Perl_new_version Perl_croak Perl_sv_2cv Perl_Isv_undef_ptr Perl_PerlIO_stderr Perl_safesysfree Perl_push_scope _edata Perl_newXS Perl_newSV_type Perl_Icomppad_ptr Perl_sv_2bool Perl_sv_tainted Perl_Icurpm_ptr Perl_cxinc Perl_Icurcop_ptr Perl_sv_2nv Perl_sv_derived_from Perl_ckwarn Perl_new_stackinfo srand48_r@@GLIBC_2.2.5 Perl_markstack_grow XS_List__Util_unpairs XS_List__Util_pairfirst XS_List__Util_reduce boot_List__Util _init Perl_sv_backoff Perl_sv_2pv_flags Perl_sv_magic Perl_Imarkstack_ptr FILE   a8a1849c/Compress/Raw/Zlib.pm  :�#line 1 "/usr/lib64/perl5/Compress/Raw/Zlib.pm"

package Compress::Raw::Zlib;

require 5.004 ;
require Exporter;
use AutoLoader;
use Carp ;

#use Parse::Parameters;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, $AUTOLOAD);

$VERSION = '2.021';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
        adler32 crc32

        ZLIB_VERSION
        ZLIB_VERNUM

        DEF_WBITS
        OS_CODE

        MAX_MEM_LEVEL
        MAX_WBITS

        Z_ASCII
        Z_BEST_COMPRESSION
        Z_BEST_SPEED
        Z_BINARY
        Z_BLOCK
        Z_BUF_ERROR
        Z_DATA_ERROR
        Z_DEFAULT_COMPRESSION
        Z_DEFAULT_STRATEGY
        Z_DEFLATED
        Z_ERRNO
        Z_FILTERED
        Z_FIXED
        Z_FINISH
        Z_FULL_FLUSH
        Z_HUFFMAN_ONLY
        Z_MEM_ERROR
        Z_NEED_DICT
        Z_NO_COMPRESSION
        Z_NO_FLUSH
        Z_NULL
        Z_OK
        Z_PARTIAL_FLUSH
        Z_RLE
        Z_STREAM_END
        Z_STREAM_ERROR
        Z_SYNC_FLUSH
        Z_UNKNOWN
        Z_VERSION_ERROR

        WANT_GZIP
        WANT_GZIP_OR_ZLIB
);

use constant WANT_GZIP           => 16;
use constant WANT_GZIP_OR_ZLIB   => 32;

sub AUTOLOAD {
    my($constname);
    ($constname = $AUTOLOAD) =~ s/.*:://;
    my ($error, $val) = constant($constname);
    Carp::croak $error if $error;
    no strict 'refs';
    *{$AUTOLOAD} = sub { $val };
    goto &{$AUTOLOAD};
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;
use constant FLAG_LIMIT_OUTPUT       => 16 ;

eval {
    require XSLoader;
    XSLoader::load('Compress::Raw::Zlib', $XS_VERSION);
    1;
} 
or do {
    require DynaLoader;
    local @ISA = qw(DynaLoader);
    bootstrap Compress::Raw::Zlib $XS_VERSION ; 
};
 

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_custom   => 0x12;

use constant Parse_store_ref => 0x100 ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    #local $Carp::CarpLevel = 1 ;
    my $p = new Compress::Raw::Zlib::Parameters() ;
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}


sub Compress::Raw::Zlib::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'Compress::Raw::Zlib::Parameters' ;
}

sub Compress::Raw::Zlib::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub Compress::Raw::Zlib::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            push @entered, $_[2* $i] ;
            push @entered, \$_[2* $i+1] ;
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;
            #$value = $$value unless $type & Parse_store_ref ;
            $value = $$value ;
            $got->{$canonkey} = [1, $type, $value, $s] ;
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) @Bad") ;
    }

    return 1;
}

sub Compress::Raw::Zlib::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;
    if ( $type & Parse_store_ref)
    {
        #$value = $$value
        #    if ref ${ $value } ;

        $$output = $value ;
        return 1;
    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;    
        return 1;
    }

    $$output = $value ;
    return 1;
}



sub Compress::Raw::Zlib::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub Compress::Raw::Zlib::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

sub Compress::Raw::Zlib::Deflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::Deflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _deflateInit($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $windowBits, 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

}

sub Compress::Raw::Zlib::Inflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'AppendOutput'  => [1, 1, Parse_boolean,  0],
                        'LimitOutput'   => [1, 1, Parse_boolean,  0],
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'ConsumeInput'  => [1, 1, Parse_boolean,  1],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::Inflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    $flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;
    $flags |= FLAG_LIMIT_OUTPUT if $got->value('LimitOutput') ;


    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _inflateInit($flags, $windowBits, $got->value('Bufsize'), 
                 $got->value('Dictionary')) ;
}

sub Compress::Raw::Zlib::InflateScan::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   -MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::InflateScan::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    #$flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    #$flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;

    _inflateScanInit($flags, $got->value('WindowBits'), $got->value('Bufsize'), 
                 '') ;
}

sub Compress::Raw::Zlib::inflateScanStream::createDeflateStream
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   - MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
            }, @_) ;

    croak "Compress::Raw::Zlib::InflateScan::createDeflateStream: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    $pkg->_createDeflateStream($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                ) ;

}

sub Compress::Raw::Zlib::inflateScanStream::inflate
{
    my $self = shift ;
    my $buffer = $_[1];
    my $eof = $_[2];

    my $status = $self->scan(@_);

    if ($status == Z_OK() && $_[2]) {
        my $byte = ' ';
        
        $status = $self->scan(\$byte, $_[1]) ;
    }
    
    return $status ;
}

sub Compress::Raw::Zlib::deflateStream::deflateParams
{
    my $self = shift ;
    my ($got) = ParseParameters(0, {
                'Level'      => [1, 1, Parse_signed,   undef],
                'Strategy'   => [1, 1, Parse_unsigned, undef],
                'Bufsize'    => [1, 1, Parse_unsigned, undef],
                }, 
                @_) ;

    croak "Compress::Raw::Zlib::deflateParams needs Level and/or Strategy"
        unless $got->parsed('Level') + $got->parsed('Strategy') +
            $got->parsed('Bufsize');

    croak "Compress::Raw::Zlib::Inflate::deflateParams: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        if $got->parsed('Bufsize') && $got->value('Bufsize') <= 1;

    my $flags = 0;
    $flags |= 1 if $got->parsed('Level') ;
    $flags |= 2 if $got->parsed('Strategy') ;
    $flags |= 4 if $got->parsed('Bufsize') ;

    $self->_deflateParams($flags, $got->value('Level'), 
                          $got->value('Strategy'), $got->value('Bufsize'));

}


# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1420
FILE   e47c122b/Compress/Zlib.pm  7s#line 1 "/usr/lib64/perl5/Compress/Zlib.pm"

package Compress::Zlib;

require 5.004 ;
require Exporter;
use AutoLoader;
use Carp ;
use IO::Handle ;
use Scalar::Util qw(dualvar);

use IO::Compress::Base::Common 2.021 ;
use Compress::Raw::Zlib 2.021 ;
use IO::Compress::Gzip 2.021 ;
use IO::Uncompress::Gunzip 2.021 ;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, $AUTOLOAD);

$VERSION = '2.021';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
        deflateInit inflateInit

        compress uncompress

        gzopen $gzerrno
    );

push @EXPORT, @Compress::Raw::Zlib::EXPORT ;

BEGIN
{
    *zlib_version = \&Compress::Raw::Zlib::zlib_version;
}

sub AUTOLOAD {
    my($constname);
    ($constname = $AUTOLOAD) =~ s/.*:://;
    my ($error, $val) = Compress::Raw::Zlib::constant($constname);
    Carp::croak $error if $error;
    no strict 'refs';
    *{$AUTOLOAD} = sub { $val };
    goto &{$AUTOLOAD};
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;

our (@my_z_errmsg);

@my_z_errmsg = (
    "need dictionary",     # Z_NEED_DICT     2
    "stream end",          # Z_STREAM_END    1
    "",                    # Z_OK            0
    "file error",          # Z_ERRNO        (-1)
    "stream error",        # Z_STREAM_ERROR (-2)
    "data error",          # Z_DATA_ERROR   (-3)
    "insufficient memory", # Z_MEM_ERROR    (-4)
    "buffer error",        # Z_BUF_ERROR    (-5)
    "incompatible version",# Z_VERSION_ERROR(-6)
    );


sub _set_gzerr
{
    my $value = shift ;

    if ($value == 0) {
        $Compress::Zlib::gzerrno = 0 ;
    }
    elsif ($value == Z_ERRNO() || $value > 2) {
        $Compress::Zlib::gzerrno = $! ;
    }
    else {
        $Compress::Zlib::gzerrno = dualvar($value+0, $my_z_errmsg[2 - $value]);
    }

    return $value ;
}

sub _save_gzerr
{
    my $gz = shift ;
    my $test_eof = shift ;

    my $value = $gz->errorNo() || 0 ;

    if ($test_eof) {
        #my $gz = $self->[0] ;
        # gzread uses Z_STREAM_END to denote a successful end
        $value = Z_STREAM_END() if $gz->eof() && $value == 0 ;
    }

    _set_gzerr($value) ;
}

sub gzopen($$)
{
    my ($file, $mode) = @_ ;

    my $gz ;
    my %defOpts = (Level    => Z_DEFAULT_COMPRESSION(),
                   Strategy => Z_DEFAULT_STRATEGY(),
                  );

    my $writing ;
    $writing = ! ($mode =~ /r/i) ;
    $writing = ($mode =~ /[wa]/i) ;

    $defOpts{Level}    = $1               if $mode =~ /(\d)/;
    $defOpts{Strategy} = Z_FILTERED()     if $mode =~ /f/i;
    $defOpts{Strategy} = Z_HUFFMAN_ONLY() if $mode =~ /h/i;
    $defOpts{Append}   = 1                if $mode =~ /a/i;

    my $infDef = $writing ? 'deflate' : 'inflate';
    my @params = () ;

    croak "gzopen: file parameter is not a filehandle or filename"
        unless isaFilehandle $file || isaFilename $file  || 
               (ref $file && ref $file eq 'SCALAR');

    return undef unless $mode =~ /[rwa]/i ;

    _set_gzerr(0) ;

    if ($writing) {
        $gz = new IO::Compress::Gzip($file, Minimal => 1, AutoClose => 1, 
                                     %defOpts) 
            or $Compress::Zlib::gzerrno = $IO::Compress::Gzip::GzipError;
    }
    else {
        $gz = new IO::Uncompress::Gunzip($file, 
                                         Transparent => 1,
                                         Append => 0, 
                                         AutoClose => 1, 
                                         MultiStream => 1,
                                         Strict => 0) 
            or $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    }

    return undef
        if ! defined $gz ;

    bless [$gz, $infDef], 'Compress::Zlib::gzFile';
}

sub Compress::Zlib::gzFile::gzread
{
    my $self = shift ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'inflate';

    my $len = defined $_[1] ? $_[1] : 4096 ; 

    if ($self->gzeof() || $len == 0) {
        # Zap the output buffer to match ver 1 behaviour.
        $_[0] = "" ;
        return 0 ;
    }

    my $gz = $self->[0] ;
    my $status = $gz->read($_[0], $len) ; 
    _save_gzerr($gz, 1);
    return $status ;
}

sub Compress::Zlib::gzFile::gzreadline
{
    my $self = shift ;

    my $gz = $self->[0] ;
    {
        # Maintain backward compatibility with 1.x behaviour
        # It didn't support $/, so this can't either.
        local $/ = "\n" ;
        $_[0] = $gz->getline() ; 
    }
    _save_gzerr($gz, 1);
    return defined $_[0] ? length $_[0] : 0 ;
}

sub Compress::Zlib::gzFile::gzwrite
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';

    $] >= 5.008 and (utf8::downgrade($_[0], 1) 
        or croak "Wide character in gzwrite");

    my $status = $gz->write($_[0]) ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gztell
{
    my $self = shift ;
    my $gz = $self->[0] ;
    my $status = $gz->tell() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzseek
{
    my $self   = shift ;
    my $offset = shift ;
    my $whence = shift ;

    my $gz = $self->[0] ;
    my $status ;
    eval { $status = $gz->seek($offset, $whence) ; };
    if ($@)
    {
        my $error = $@;
        $error =~ s/^.*: /gzseek: /;
        $error =~ s/ at .* line \d+\s*$//;
        croak $error;
    }
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzflush
{
    my $self = shift ;
    my $f    = shift ;

    my $gz = $self->[0] ;
    my $status = $gz->flush($f) ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzclose
{
    my $self = shift ;
    my $gz = $self->[0] ;

    my $status = $gz->close() ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzeof
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return 0
        if $self->[1] ne 'inflate';

    my $status = $gz->eof() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzsetparams
{
    my $self = shift ;
    croak "Usage: Compress::Zlib::gzFile::gzsetparams(file, level, strategy)"
        unless @_ eq 2 ;

    my $gz = $self->[0] ;
    my $level = shift ;
    my $strategy = shift;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';
 
    my $status = *$gz->{Compress}->deflateParams(-Level   => $level, 
                                                -Strategy => $strategy);
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzerror
{
    my $self = shift ;
    my $gz = $self->[0] ;
    
    return $Compress::Zlib::gzerrno ;
}


sub compress($;$)
{
    my ($x, $output, $err, $in) =('', '', '', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in compress");

    my $level = (@_ == 2 ? $_[1] : Z_DEFAULT_COMPRESSION() );

    $x = new Compress::Raw::Zlib::Deflate -AppendOutput => 1, -Level => $level
            or return undef ;

    $err = $x->deflate($in, $output) ;
    return undef unless $err == Z_OK() ;

    $err = $x->flush($output) ;
    return undef unless $err == Z_OK() ;
    
    return $output ;

}

sub uncompress($)
{
    my ($x, $output, $err, $in) =('', '', '', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in uncompress");

    $x = new Compress::Raw::Zlib::Inflate -ConsumeInput => 0 or return undef ;
 
    $err = $x->inflate($in, $output) ;
    return undef unless $err == Z_STREAM_END() ;
 
    return $output ;
}


 
sub deflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
                }, @_ ) ;

    croak "Compress::Zlib::deflateInit: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $obj ;
 
    my $status = 0 ;
    ($obj, $status) = 
      Compress::Raw::Zlib::_deflateInit(0,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldDeflate"  : undef) ;
    return wantarray ? ($x, $status) : $x ;
}
 
sub inflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
                }, @_) ;


    croak "Compress::Zlib::inflateInit: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $status = 0 ;
    my $obj ;
    ($obj, $status) = Compress::Raw::Zlib::_inflateInit(FLAG_CONSUME_INPUT,
                                $got->value('WindowBits'), 
                                $got->value('Bufsize'), 
                                $got->value('Dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldInflate"  : undef) ;

    wantarray ? ($x, $status) : $x ;
}

package Zlib::OldDeflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::deflateStream);


sub deflate
{
    my $self = shift ;
    my $output ;

    my $status = $self->SUPER::deflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

sub flush
{
    my $self = shift ;
    my $output ;
    my $flag = shift || Compress::Zlib::Z_FINISH();
    my $status = $self->SUPER::flush($output, $flag) ;
    
    wantarray ? ($output, $status) : $output ;
}

package Zlib::OldInflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::inflateStream);

sub inflate
{
    my $self = shift ;
    my $output ;
    my $status = $self->SUPER::inflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

package Compress::Zlib ;

use IO::Compress::Gzip::Constants 2.021 ;

sub memGzip($)
{
  my $out;

  # if the deflation buffer isn't a reference, make it one
  my $string = (ref $_[0] ? $_[0] : \$_[0]) ;

  $] >= 5.008 and (utf8::downgrade($$string, 1) 
      or croak "Wide character in memGzip");

  IO::Compress::Gzip::gzip($string, \$out, Minimal => 1)
      or return undef ;

  return $out;
}


sub _removeGzipHeader($)
{
    my $string = shift ;

    return Z_DATA_ERROR() 
        if length($$string) < GZIP_MIN_HEADER_SIZE ;

    my ($magic1, $magic2, $method, $flags, $time, $xflags, $oscode) = 
        unpack ('CCCCVCC', $$string);

    return Z_DATA_ERROR()
        unless $magic1 == GZIP_ID1 and $magic2 == GZIP_ID2 and
           $method == Z_DEFLATED() and !($flags & GZIP_FLG_RESERVED) ;
    substr($$string, 0, GZIP_MIN_HEADER_SIZE) = '' ;

    # skip extra field
    if ($flags & GZIP_FLG_FEXTRA)
    {
        return Z_DATA_ERROR()
            if length($$string) < GZIP_FEXTRA_HEADER_SIZE ;

        my ($extra_len) = unpack ('v', $$string);
        $extra_len += GZIP_FEXTRA_HEADER_SIZE;
        return Z_DATA_ERROR()
            if length($$string) < $extra_len ;

        substr($$string, 0, $extra_len) = '';
    }

    # skip orig name
    if ($flags & GZIP_FLG_FNAME)
    {
        my $name_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
           if $name_end == -1 ;
        substr($$string, 0, $name_end + 1) =  '';
    }

    # skip comment
    if ($flags & GZIP_FLG_FCOMMENT)
    {
        my $comment_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
            if $comment_end == -1 ;
        substr($$string, 0, $comment_end + 1) = '';
    }

    # skip header crc
    if ($flags & GZIP_FLG_FHCRC)
    {
        return Z_DATA_ERROR()
            if length ($$string) < GZIP_FHCRC_SIZE ;
        substr($$string, 0, GZIP_FHCRC_SIZE) = '';
    }
    
    return Z_OK();
}


sub memGunzip($)
{
    # if the buffer isn't a reference, make it one
    my $string = (ref $_[0] ? $_[0] : \$_[0]);
 
    $] >= 5.008 and (utf8::downgrade($$string, 1) 
        or croak "Wide character in memGunzip");

    _removeGzipHeader($string) == Z_OK() 
        or return undef;
     
    my $bufsize = length $$string > 4096 ? length $$string : 4096 ;
    my $x = new Compress::Raw::Zlib::Inflate({-WindowBits => - MAX_WBITS(),
                         -Bufsize => $bufsize}) 

              or return undef;

    my $output = "" ;
    my $status = $x->inflate($string, $output);
    return undef 
        unless $status == Z_STREAM_END();

    if (length $$string >= 8)
    {
        my ($crc, $len) = unpack ("VV", substr($$string, 0, 8));
        substr($$string, 0, 8) = '';
        return undef 
            unless $len == length($output) and
                   $crc == crc32($output);
    }
    else
    {
        $$string = '';
    }
    return $output;   
}

# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1462
FILE   af9db838/Config.pm  
�#line 1 "/usr/lib64/perl5/Config.pm"
# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

# for a description of the variables, please have a look at the
# Glossary file, as written in the Porting folder, or use the url:
# http://perl5.git.perl.org/perl.git/blob/HEAD:/Porting/Glossary

package Config;
use strict;
# use warnings; Pulls in Carp
# use vars pulls in Carp
@Config::EXPORT = qw(%Config);
@Config::EXPORT_OK = qw(myconfig config_sh config_vars config_re);

# Need to stub all the functions to make code such as print Config::config_sh
# keep working

sub myconfig;
sub config_sh;
sub config_vars;
sub config_re;

my %Export_Cache = map {($_ => 1)} (@Config::EXPORT, @Config::EXPORT_OK);

our %Config;

# Define our own import method to avoid pulling in the full Exporter:
sub import {
    my $pkg = shift;
    @_ = @Config::EXPORT unless @_;

    my @funcs = grep $_ ne '%Config', @_;
    my $export_Config = @funcs < @_ ? 1 : 0;

    no strict 'refs';
    my $callpkg = caller(0);
    foreach my $func (@funcs) {
	die sprintf qq{"%s" is not exported by the %s module\n},
	    $func, __PACKAGE__ unless $Export_Cache{$func};
	*{$callpkg.'::'.$func} = \&{$func};
    }

    *{"$callpkg\::Config"} = \%Config if $export_Config;
    return;
}

die "Perl lib version (5.10.1) doesn't match executable version ($])"
    unless $^V;

$^V eq 5.10.1
    or die "Perl lib version (5.10.1) doesn't match executable version (" .
	sprintf("v%vd",$^V) . ")";


sub FETCH {
    my($self, $key) = @_;

    # check for cached value (which may be undef so we use exists not defined)
    return $self->{$key} if exists $self->{$key};

    return $self->fetch_string($key);
}
sub TIEHASH {
    bless $_[1], $_[0];
}

sub DESTROY { }

sub AUTOLOAD {
    require 'Config_heavy.pl';
    goto \&launcher unless $Config::AUTOLOAD =~ /launcher$/;
    die "&Config::AUTOLOAD failed on $Config::AUTOLOAD";
}

# tie returns the object, so the value returned to require will be true.
tie %Config, 'Config', {
    archlibexp => '/usr/lib64/perl5',
    archname => 'x86_64-linux-thread-multi',
    cc => 'gcc',
    d_readlink => 'define',
    d_symlink => 'define',
    dlsrc => 'dl_dlopen.xs',
    dont_use_nlink => undef,
    exe_ext => '',
    inc_version_list => '5.10.0',
    intsize => '4',
    ldlibpthname => 'LD_LIBRARY_PATH',
    libpth => '/usr/local/lib64 /lib64 /usr/lib64',
    osname => 'linux',
    osvers => '2.6.18-402.el5',
    path_sep => ':',
    privlibexp => '/usr/share/perl5',
    scriptdir => '/usr/bin',
    sitearchexp => '/usr/local/lib64/perl5',
    sitelibexp => '/usr/local/share/perl5',
    useithreads => 'define',
    usevendorprefix => 'define',
    version => '5.10.1',
};
FILE   c33fbebe/Config_git.pl  �######################################################################
# WARNING: 'lib/Config_git.pl' is generated by make_patchnum.pl
#          DO NOT EDIT DIRECTLY - edit make_patchnum.pl instead
######################################################################
$Config::Git_Data=<<'ENDOFGIT';
git_commit_id=''
git_describe=''
git_branch=''
git_uncommitted_changes=''
git_commit_id_title=''

ENDOFGIT
FILE   6d985aba/Config_heavy.pl  ��# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

package Config;
use strict;
# use warnings; Pulls in Carp
# use vars pulls in Carp
##
## This file was produced by running the Configure script. It holds all the
## definitions figured out by Configure. Should you modify one of these values,
## do not forget to propagate your changes by running "Configure -der". You may
## instead choose to run each of the .SH files by yourself, or "Configure -S".
##
#
## Package name      : perl5
## Source directory  : .
## Configuration time: Fri Mar 13 07:48:29 EDT 2015
## Configured by     : Red Hat, Inc.
## Target system     : linux x86-027.build.eng.bos.redhat.com 2.6.18-402.el5 #1 smp thu jan 8 06:22:34 est 2015 x86_64 x86_64 x86_64 gnulinux 
#
#: Configure command line arguments.
#
#: Variables propagated from previous config.sh file.

our $summary = <<'!END!';
Summary of my $package (revision $revision $version_patchlevel_string) configuration:
  $git_commit_id_title $git_commit_id$git_ancestor_line
  Platform:
    osname=$osname, osvers=$osvers, archname=$archname
    uname='$myuname'
    config_args='$config_args'
    hint=$hint, useposix=$useposix, d_sigaction=$d_sigaction
    useithreads=$useithreads, usemultiplicity=$usemultiplicity
    useperlio=$useperlio, d_sfio=$d_sfio, uselargefiles=$uselargefiles, usesocks=$usesocks
    use64bitint=$use64bitint, use64bitall=$use64bitall, uselongdouble=$uselongdouble
    usemymalloc=$usemymalloc, bincompat5005=undef
  Compiler:
    cc='$cc', ccflags ='$ccflags',
    optimize='$optimize',
    cppflags='$cppflags'
    ccversion='$ccversion', gccversion='$gccversion', gccosandvers='$gccosandvers'
    intsize=$intsize, longsize=$longsize, ptrsize=$ptrsize, doublesize=$doublesize, byteorder=$byteorder
    d_longlong=$d_longlong, longlongsize=$longlongsize, d_longdbl=$d_longdbl, longdblsize=$longdblsize
    ivtype='$ivtype', ivsize=$ivsize, nvtype='$nvtype', nvsize=$nvsize, Off_t='$lseektype', lseeksize=$lseeksize
    alignbytes=$alignbytes, prototype=$prototype
  Linker and Libraries:
    ld='$ld', ldflags ='$ldflags'
    libpth=$libpth
    libs=$libs
    perllibs=$perllibs
    libc=$libc, so=$so, useshrplib=$useshrplib, libperl=$libperl
    gnulibc_version='$gnulibc_version'
  Dynamic Linking:
    dlsrc=$dlsrc, dlext=$dlext, d_dlsymun=$d_dlsymun, ccdlflags='$ccdlflags'
    cccdlflags='$cccdlflags', lddlflags='$lddlflags'

!END!
my $summary_expanded;

sub myconfig {
    return $summary_expanded if $summary_expanded;
    ($summary_expanded = $summary) =~ s{\$(\w+)}
		 { 
			my $c;
			if ($1 eq 'git_ancestor_line') {
				if ($Config::Config{git_ancestor}) {
					$c= "\n  Ancestor: $Config::Config{git_ancestor}";
				} else {
					$c= "";
				}
			} else {
                     		$c = $Config::Config{$1}; 
			}
			defined($c) ? $c : 'undef' 
		}ge;
    $summary_expanded;
}

local *_ = \my $a;
$_ = <<'!END!';
Author=''
CONFIG='true'
Date='$Date'
Header=''
Id='$Id'
Locker=''
Log='$Log'
PATCHLEVEL='10'
PERL_API_REVISION='5'
PERL_API_SUBVERSION='0'
PERL_API_VERSION='10'
PERL_CONFIG_SH='true'
PERL_PATCHLEVEL=''
PERL_REVISION='5'
PERL_SUBVERSION='1'
PERL_VERSION='10'
RCSfile='$RCSfile'
Revision='$Revision'
SUBVERSION='1'
Source=''
State=''
_a='.a'
_exe=''
_o='.o'
afs='false'
afsroot='/afs'
alignbytes='8'
ansi2knr=''
aphostname=''
api_revision='5'
api_subversion='0'
api_version='10'
api_versionstring='5.10.0'
ar='ar'
archlib='/usr/lib64/perl5'
archlibexp='/usr/lib64/perl5'
archname64=''
archname='x86_64-linux-thread-multi'
archobjs=''
asctime_r_proto='REENTRANT_PROTO_B_SB'
awk='awk'
baserev='5.0'
bash=''
bin='/usr/bin'
binexp='/usr/bin'
bison='bison'
byacc='byacc'
byteorder='12345678'
c=''
castflags='0'
cat='cat'
cc='gcc'
cccdlflags='-fPIC'
ccdlflags='-Wl,-E -Wl,-rpath,/usr/lib64/perl5/CORE'
ccflags='-D_REENTRANT -D_GNU_SOURCE -fno-strict-aliasing -pipe -fstack-protector -I/usr/local/include -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccflags_uselargefiles='-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccname='gcc'
ccsymbols=''
ccversion=''
cf_by='Red Hat, Inc.'
cf_email='Red Hat, Inc.@localhost.localdomain'
cf_time='Fri Mar 13 07:48:29 EDT 2015'
chgrp=''
chmod='chmod'
chown=''
clocktype='clock_t'
comm='comm'
compress=''
config_arg0='Configure'
config_arg10='-Dvendorprefix=/usr'
config_arg11='-Dsiteprefix=/usr/local'
config_arg12='-Dsitelib=/usr/local/share/perl5'
config_arg13='-Dsitearch=/usr/local/lib64/perl5'
config_arg14='-Dprivlib=/usr/share/perl5'
config_arg15='-Darchlib=/usr/lib64/perl5'
config_arg16='-Dvendorlib=/usr/share/perl5/vendor_perl'
config_arg17='-Dvendorarch=/usr/lib64/perl5/vendor_perl'
config_arg18='-Dinc_version_list=5.10.0'
config_arg19='-Darchname=x86_64-linux-thread-multi'
config_arg1='-des'
config_arg20='-Dlibpth=/usr/local/lib64 /lib64 /usr/lib64'
config_arg21='-Duseshrplib'
config_arg22='-Dusethreads'
config_arg23='-Duseithreads'
config_arg24='-Duselargefiles'
config_arg25='-Dd_dosuid'
config_arg26='-Dd_semctl_semun'
config_arg27='-Di_db'
config_arg28='-Ui_ndbm'
config_arg29='-Di_gdbm'
config_arg2='-Doptimize=-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic'
config_arg30='-Di_shadow'
config_arg31='-Di_syslog'
config_arg32='-Dman3ext=3pm'
config_arg33='-Duseperlio'
config_arg34='-Dinstallusrbinperl=n'
config_arg35='-Ubincompat5005'
config_arg36='-Uversiononly'
config_arg37='-Dpager=/usr/bin/less -isr'
config_arg38='-Dd_gethostent_r_proto'
config_arg39='-Ud_endhostent_r_proto'
config_arg3='-DDEBUGGING=-g'
config_arg40='-Ud_sethostent_r_proto'
config_arg41='-Ud_endprotoent_r_proto'
config_arg42='-Ud_setprotoent_r_proto'
config_arg43='-Ud_endservent_r_proto'
config_arg44='-Ud_setservent_r_proto'
config_arg45='-Dscriptdir=/usr/bin'
config_arg46='-Dusesitecustomize'
config_arg4='-Dversion=5.10.1'
config_arg5='-Dmyhostname=localhost'
config_arg6='-Dperladmin=root@localhost'
config_arg7='-Dcc=gcc'
config_arg8='-Dcf_by=Red Hat, Inc.'
config_arg9='-Dprefix=/usr'
config_argc='46'
config_args='-des -Doptimize=-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic -DDEBUGGING=-g -Dversion=5.10.1 -Dmyhostname=localhost -Dperladmin=root@localhost -Dcc=gcc -Dcf_by=Red Hat, Inc. -Dprefix=/usr -Dvendorprefix=/usr -Dsiteprefix=/usr/local -Dsitelib=/usr/local/share/perl5 -Dsitearch=/usr/local/lib64/perl5 -Dprivlib=/usr/share/perl5 -Darchlib=/usr/lib64/perl5 -Dvendorlib=/usr/share/perl5/vendor_perl -Dvendorarch=/usr/lib64/perl5/vendor_perl -Dinc_version_list=5.10.0 -Darchname=x86_64-linux-thread-multi -Dlibpth=/usr/local/lib64 /lib64 /usr/lib64 -Duseshrplib -Dusethreads -Duseithreads -Duselargefiles -Dd_dosuid -Dd_semctl_semun -Di_db -Ui_ndbm -Di_gdbm -Di_shadow -Di_syslog -Dman3ext=3pm -Duseperlio -Dinstallusrbinperl=n -Ubincompat5005 -Uversiononly -Dpager=/usr/bin/less -isr -Dd_gethostent_r_proto -Ud_endhostent_r_proto -Ud_sethostent_r_proto -Ud_endprotoent_r_proto -Ud_setprotoent_r_proto -Ud_endservent_r_proto -Ud_setservent_r_proto -Dscriptdir=/usr/bin -Dusesitecustomize'
contains='grep'
cp='cp'
cpio=''
cpp='cpp'
cpp_stuff='42'
cppccsymbols=''
cppflags='-D_REENTRANT -D_GNU_SOURCE -fno-strict-aliasing -pipe -fstack-protector -I/usr/local/include'
cpplast='-'
cppminus='-'
cpprun='gcc -E'
cppstdin='gcc -E'
cppsymbols='_FILE_OFFSET_BITS=64 _GNU_SOURCE=1 _LARGEFILE64_SOURCE=1 _LARGEFILE_SOURCE=1 _LP64=1 _POSIX_C_SOURCE=200809L _POSIX_SOURCE=1 _REENTRANT=1 _XOPEN_SOURCE=700 _XOPEN_SOURCE_EXTENDED=1 __BIGGEST_ALIGNMENT__=16 __CHAR16_TYPE__=short\ unsigned\ int __CHAR32_TYPE__=unsigned\ int __CHAR_BIT__=8 __DBL_DENORM_MIN__=4.9406564584124654e-324 __DBL_DIG__=15 __DBL_EPSILON__=2.2204460492503131e-16 __DBL_HAS_DENORM__=1 __DBL_HAS_INFINITY__=1 __DBL_HAS_QUIET_NAN__=1 __DBL_MANT_DIG__=53 __DBL_MAX_10_EXP__=308 __DBL_MAX_EXP__=1024 __DBL_MAX__=1.7976931348623157e+308 __DBL_MIN_10_EXP__=(-307) __DBL_MIN_EXP__=(-1021) __DBL_MIN__=2.2250738585072014e-308 __DEC128_EPSILON__=1E-33DL __DEC128_MANT_DIG__=34 __DEC128_MAX_EXP__=6145 __DEC128_MAX__=9.999999999999999999999999999999999E6144DL __DEC128_MIN_EXP__=(-6142) __DEC128_MIN__=1E-6143DL __DEC128_SUBNORMAL_MIN__=0.000000000000000000000000000000001E-6143DL __DEC32_EPSILON__=1E-6DF __DEC32_MANT_DIG__=7 __DEC32_MAX_EXP__=97 __DEC32_MAX__=9.999999E96DF __DEC32_MIN_EXP__=(-94) __DEC32_MIN__=1E-95DF __DEC32_SUBNORMAL_MIN__=0.000001E-95DF __DEC64_EPSILON__=1E-15DD __DEC64_MANT_DIG__=16 __DEC64_MAX_EXP__=385 __DEC64_MAX__=9.999999999999999E384DD __DEC64_MIN_EXP__=(-382) __DEC64_MIN__=1E-383DD __DEC64_SUBNORMAL_MIN__=0.000000000000001E-383DD __DECIMAL_BID_FORMAT__=1 __DECIMAL_DIG__=21 __DEC_EVAL_METHOD__=2 __ELF__=1 __FINITE_MATH_ONLY__=0 __FLT_DENORM_MIN__=1.40129846e-45F __FLT_DIG__=6 __FLT_EPSILON__=1.19209290e-7F __FLT_EVAL_METHOD__=0 __FLT_HAS_DENORM__=1 __FLT_HAS_INFINITY__=1 __FLT_HAS_QUIET_NAN__=1 __FLT_MANT_DIG__=24 __FLT_MAX_10_EXP__=38 __FLT_MAX_EXP__=128 __FLT_MAX__=3.40282347e+38F __FLT_MIN_10_EXP__=(-37) __FLT_MIN_EXP__=(-125) __FLT_MIN__=1.17549435e-38F __FLT_RADIX__=2 __GCC_HAVE_DWARF2_CFI_ASM=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_1=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_2=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_4=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8=1 __GLIBC_MINOR__=12 __GLIBC__=2 __GNUC_GNU_INLINE__=1 __GNUC_MINOR__=4 __GNUC_PATCHLEVEL__=7 __GNUC_RH_RELEASE__=14 __GNUC__=4 __GNU_LIBRARY__=6 __GXX_ABI_VERSION=1002 __INTMAX_MAX__=9223372036854775807L __INTMAX_TYPE__=long\ int __INT_MAX__=2147483647 __LDBL_DENORM_MIN__=3.64519953188247460253e-4951L __LDBL_DIG__=18 __LDBL_EPSILON__=1.08420217248550443401e-19L __LDBL_HAS_DENORM__=1 __LDBL_HAS_INFINITY__=1 __LDBL_HAS_QUIET_NAN__=1 __LDBL_MANT_DIG__=64 __LDBL_MAX_10_EXP__=4932 __LDBL_MAX_EXP__=16384 __LDBL_MAX__=1.18973149535723176502e+4932L __LDBL_MIN_10_EXP__=(-4931) __LDBL_MIN_EXP__=(-16381) __LDBL_MIN__=3.36210314311209350626e-4932L __LONG_LONG_MAX__=9223372036854775807LL __LONG_MAX__=9223372036854775807L __LP64__=1 __MMX__=1 __PTRDIFF_TYPE__=long\ int __REGISTER_PREFIX__= __SCHAR_MAX__=127 __SHRT_MAX__=32767 __SIZEOF_DOUBLE__=8 __SIZEOF_FLOAT__=4 __SIZEOF_INT__=4 __SIZEOF_LONG_DOUBLE__=16 __SIZEOF_LONG_LONG__=8 __SIZEOF_LONG__=8 __SIZEOF_POINTER__=8 __SIZEOF_PTRDIFF_T__=8 __SIZEOF_SHORT__=2 __SIZEOF_SIZE_T__=8 __SIZEOF_WCHAR_T__=4 __SIZEOF_WINT_T__=4 __SIZE_TYPE__=long\ unsigned\ int __SSE2_MATH__=1 __SSE2__=1 __SSE_MATH__=1 __SSE__=1 __STDC_HOSTED__=1 __STDC__=1 __UINTMAX_TYPE__=long\ unsigned\ int __USER_LABEL_PREFIX__= __USE_BSD=1 __USE_FILE_OFFSET64=1 __USE_GNU=1 __USE_LARGEFILE64=1 __USE_LARGEFILE=1 __USE_MISC=1 __USE_POSIX199309=1 __USE_POSIX199506=1 __USE_POSIX2=1 __USE_POSIX=1 __USE_REENTRANT=1 __USE_SVID=1 __USE_UNIX98=1 __USE_XOPEN=1 __USE_XOPEN_EXTENDED=1 __VERSION__="4.4.7\ 20120313\ (Red\ Hat\ 4.4.7-14)" __WCHAR_MAX__=2147483647 __WCHAR_TYPE__=int __WINT_TYPE__=unsigned\ int __amd64=1 __amd64__=1 __gnu_linux__=1 __k8=1 __k8__=1 __linux=1 __linux__=1 __unix=1 __unix__=1 __x86_64=1 __x86_64__=1 linux=1 unix=1'
crypt_r_proto='REENTRANT_PROTO_B_CCS'
cryptlib=''
csh='csh'
ctermid_r_proto='0'
ctime_r_proto='REENTRANT_PROTO_B_SB'
d_Gconvert='gcvt((x),(n),(b))'
d_PRIEUldbl='define'
d_PRIFUldbl='define'
d_PRIGUldbl='define'
d_PRIXU64='define'
d_PRId64='define'
d_PRIeldbl='define'
d_PRIfldbl='define'
d_PRIgldbl='define'
d_PRIi64='define'
d_PRIo64='define'
d_PRIu64='define'
d_PRIx64='define'
d_SCNfldbl='define'
d__fwalk='undef'
d_access='define'
d_accessx='undef'
d_aintl='undef'
d_alarm='define'
d_archlib='define'
d_asctime64='undef'
d_asctime_r='define'
d_atolf='undef'
d_atoll='define'
d_attribute_deprecated='define'
d_attribute_format='define'
d_attribute_malloc='define'
d_attribute_nonnull='define'
d_attribute_noreturn='define'
d_attribute_pure='define'
d_attribute_unused='define'
d_attribute_warn_unused_result='define'
d_bcmp='define'
d_bcopy='define'
d_bsd='undef'
d_bsdgetpgrp='undef'
d_bsdsetpgrp='undef'
d_builtin_choose_expr='define'
d_builtin_expect='define'
d_bzero='define'
d_c99_variadic_macros='define'
d_casti32='undef'
d_castneg='define'
d_charvspr='undef'
d_chown='define'
d_chroot='define'
d_chsize='undef'
d_class='undef'
d_clearenv='define'
d_closedir='define'
d_cmsghdr_s='define'
d_const='define'
d_copysignl='define'
d_cplusplus='undef'
d_crypt='define'
d_crypt_r='define'
d_csh='define'
d_ctermid='define'
d_ctermid_r='undef'
d_ctime64='undef'
d_ctime_r='define'
d_cuserid='define'
d_dbl_dig='define'
d_dbminitproto='undef'
d_difftime64='undef'
d_difftime='define'
d_dir_dd_fd='undef'
d_dirfd='define'
d_dirnamlen='undef'
d_dlerror='define'
d_dlopen='define'
d_dlsymun='undef'
d_dosuid='define'
d_drand48_r='define'
d_drand48proto='define'
d_dup2='define'
d_eaccess='define'
d_endgrent='define'
d_endgrent_r='undef'
d_endhent='define'
d_endhostent_r='undef'
d_endnent='define'
d_endnetent_r='undef'
d_endpent='define'
d_endprotoent_r='undef'
d_endpwent='define'
d_endpwent_r='undef'
d_endsent='define'
d_endservent_r='undef'
d_eofnblk='define'
d_eunice='undef'
d_faststdio='define'
d_fchdir='define'
d_fchmod='define'
d_fchown='define'
d_fcntl='define'
d_fcntl_can_lock='define'
d_fd_macros='define'
d_fd_set='define'
d_fds_bits='define'
d_fgetpos='define'
d_finite='define'
d_finitel='define'
d_flexfnam='define'
d_flock='define'
d_flockproto='define'
d_fork='define'
d_fp_class='undef'
d_fpathconf='define'
d_fpclass='undef'
d_fpclassify='undef'
d_fpclassl='undef'
d_fpos64_t='undef'
d_frexpl='define'
d_fs_data_s='undef'
d_fseeko='define'
d_fsetpos='define'
d_fstatfs='define'
d_fstatvfs='define'
d_fsync='define'
d_ftello='define'
d_ftime='undef'
d_futimes='define'
d_gdbm_ndbm_h_uses_prototypes='undef'
d_gdbmndbm_h_uses_prototypes='undef'
d_getaddrinfo='define'
d_getcwd='define'
d_getespwnam='undef'
d_getfsstat='undef'
d_getgrent='define'
d_getgrent_r='define'
d_getgrgid_r='define'
d_getgrnam_r='define'
d_getgrps='define'
d_gethbyaddr='define'
d_gethbyname='define'
d_gethent='define'
d_gethname='define'
d_gethostbyaddr_r='define'
d_gethostbyname_r='define'
d_gethostent_r='define'
d_gethostprotos='define'
d_getitimer='define'
d_getlogin='define'
d_getlogin_r='define'
d_getmnt='undef'
d_getmntent='define'
d_getnameinfo='define'
d_getnbyaddr='define'
d_getnbyname='define'
d_getnent='define'
d_getnetbyaddr_r='define'
d_getnetbyname_r='define'
d_getnetent_r='define'
d_getnetprotos='define'
d_getpagsz='define'
d_getpbyname='define'
d_getpbynumber='define'
d_getpent='define'
d_getpgid='define'
d_getpgrp2='undef'
d_getpgrp='define'
d_getppid='define'
d_getprior='define'
d_getprotobyname_r='define'
d_getprotobynumber_r='define'
d_getprotoent_r='define'
d_getprotoprotos='define'
d_getprpwnam='undef'
d_getpwent='define'
d_getpwent_r='define'
d_getpwnam_r='define'
d_getpwuid_r='define'
d_getsbyname='define'
d_getsbyport='define'
d_getsent='define'
d_getservbyname_r='define'
d_getservbyport_r='define'
d_getservent_r='define'
d_getservprotos='define'
d_getspnam='define'
d_getspnam_r='define'
d_gettimeod='define'
d_gmtime64='undef'
d_gmtime_r='define'
d_gnulibc='define'
d_grpasswd='define'
d_hasmntopt='define'
d_htonl='define'
d_ilogbl='define'
d_inc_version_list='define'
d_index='undef'
d_inetaton='define'
d_inetntop='define'
d_inetpton='define'
d_int64_t='define'
d_isascii='define'
d_isfinite='undef'
d_isinf='define'
d_isnan='define'
d_isnanl='define'
d_killpg='define'
d_lchown='define'
d_ldbl_dig='define'
d_libm_lib_version='define'
d_link='define'
d_localtime64='undef'
d_localtime_r='define'
d_localtime_r_needs_tzset='define'
d_locconv='define'
d_lockf='define'
d_longdbl='define'
d_longlong='define'
d_lseekproto='define'
d_lstat='define'
d_madvise='define'
d_malloc_good_size='undef'
d_malloc_size='undef'
d_mblen='define'
d_mbstowcs='define'
d_mbtowc='define'
d_memchr='define'
d_memcmp='define'
d_memcpy='define'
d_memmove='define'
d_memset='define'
d_mkdir='define'
d_mkdtemp='define'
d_mkfifo='define'
d_mkstemp='define'
d_mkstemps='define'
d_mktime64='undef'
d_mktime='define'
d_mmap='define'
d_modfl='define'
d_modfl_pow32_bug='undef'
d_modflproto='define'
d_mprotect='define'
d_msg='define'
d_msg_ctrunc='define'
d_msg_dontroute='define'
d_msg_oob='define'
d_msg_peek='define'
d_msg_proxy='define'
d_msgctl='define'
d_msgget='define'
d_msghdr_s='define'
d_msgrcv='define'
d_msgsnd='define'
d_msync='define'
d_munmap='define'
d_mymalloc='undef'
d_ndbm='define'
d_ndbm_h_uses_prototypes='undef'
d_nice='define'
d_nl_langinfo='define'
d_nv_preserves_uv='undef'
d_nv_zero_is_allbits_zero='define'
d_off64_t='define'
d_old_pthread_create_joinable='undef'
d_oldpthreads='undef'
d_oldsock='undef'
d_open3='define'
d_pathconf='define'
d_pause='define'
d_perl_otherlibdirs='undef'
d_phostname='undef'
d_pipe='define'
d_poll='define'
d_portable='define'
d_printf_format_null='undef'
d_procselfexe='define'
d_pseudofork='undef'
d_pthread_atfork='define'
d_pthread_attr_setscope='define'
d_pthread_yield='define'
d_pwage='undef'
d_pwchange='undef'
d_pwclass='undef'
d_pwcomment='undef'
d_pwexpire='undef'
d_pwgecos='define'
d_pwpasswd='define'
d_pwquota='undef'
d_qgcvt='define'
d_quad='define'
d_random_r='define'
d_readdir64_r='define'
d_readdir='define'
d_readdir_r='define'
d_readlink='define'
d_readv='define'
d_recvmsg='define'
d_rename='define'
d_rewinddir='define'
d_rmdir='define'
d_safebcpy='undef'
d_safemcpy='undef'
d_sanemcmp='define'
d_sbrkproto='define'
d_scalbnl='define'
d_sched_yield='define'
d_scm_rights='define'
d_seekdir='define'
d_select='define'
d_sem='define'
d_semctl='define'
d_semctl_semid_ds='define'
d_semctl_semun='define'
d_semget='define'
d_semop='define'
d_sendmsg='define'
d_setegid='define'
d_seteuid='define'
d_setgrent='define'
d_setgrent_r='undef'
d_setgrps='define'
d_sethent='define'
d_sethostent_r='undef'
d_setitimer='define'
d_setlinebuf='define'
d_setlocale='define'
d_setlocale_r='undef'
d_setnent='define'
d_setnetent_r='undef'
d_setpent='define'
d_setpgid='define'
d_setpgrp2='undef'
d_setpgrp='define'
d_setprior='define'
d_setproctitle='undef'
d_setprotoent_r='undef'
d_setpwent='define'
d_setpwent_r='undef'
d_setregid='define'
d_setresgid='define'
d_setresuid='define'
d_setreuid='define'
d_setrgid='undef'
d_setruid='undef'
d_setsent='define'
d_setservent_r='undef'
d_setsid='define'
d_setvbuf='define'
d_sfio='undef'
d_shm='define'
d_shmat='define'
d_shmatprototype='define'
d_shmctl='define'
d_shmdt='define'
d_shmget='define'
d_sigaction='define'
d_signbit='define'
d_sigprocmask='define'
d_sigsetjmp='define'
d_sitearch='define'
d_snprintf='define'
d_sockatmark='define'
d_sockatmarkproto='define'
d_socket='define'
d_socklen_t='define'
d_sockpair='define'
d_socks5_init='undef'
d_sprintf_returns_strlen='define'
d_sqrtl='define'
d_srand48_r='define'
d_srandom_r='define'
d_sresgproto='define'
d_sresuproto='define'
d_statblks='define'
d_statfs_f_flags='define'
d_statfs_s='define'
d_statvfs='define'
d_stdio_cnt_lval='undef'
d_stdio_ptr_lval='define'
d_stdio_ptr_lval_nochange_cnt='undef'
d_stdio_ptr_lval_sets_cnt='define'
d_stdio_stream_array='undef'
d_stdiobase='define'
d_stdstdio='define'
d_strchr='define'
d_strcoll='define'
d_strctcpy='define'
d_strerrm='strerror(e)'
d_strerror='define'
d_strerror_r='define'
d_strftime='define'
d_strlcat='undef'
d_strlcpy='undef'
d_strtod='define'
d_strtol='define'
d_strtold='define'
d_strtoll='define'
d_strtoq='define'
d_strtoul='define'
d_strtoull='define'
d_strtouq='define'
d_strxfrm='define'
d_suidsafe='undef'
d_symlink='define'
d_syscall='define'
d_syscallproto='define'
d_sysconf='define'
d_sysernlst=''
d_syserrlst='define'
d_system='define'
d_tcgetpgrp='define'
d_tcsetpgrp='define'
d_telldir='define'
d_telldirproto='define'
d_time='define'
d_timegm='define'
d_times='define'
d_tm_tm_gmtoff='define'
d_tm_tm_zone='define'
d_tmpnam_r='define'
d_truncate='define'
d_ttyname_r='define'
d_tzname='define'
d_u32align='define'
d_ualarm='define'
d_umask='define'
d_uname='define'
d_union_semun='undef'
d_unordered='undef'
d_unsetenv='define'
d_usleep='define'
d_usleepproto='define'
d_ustat='define'
d_vendorarch='define'
d_vendorbin='define'
d_vendorlib='define'
d_vendorscript='define'
d_vfork='undef'
d_void_closedir='undef'
d_voidsig='define'
d_voidtty=''
d_volatile='define'
d_vprintf='define'
d_vsnprintf='define'
d_wait4='define'
d_waitpid='define'
d_wcstombs='define'
d_wctomb='define'
d_writev='define'
d_xenix='undef'
date='date'
db_hashtype='u_int32_t'
db_prefixtype='size_t'
db_version_major='4'
db_version_minor='7'
db_version_patch='25'
defvoidused='15'
direntrytype='struct dirent'
dlext='so'
dlsrc='dl_dlopen.xs'
doublesize='8'
drand01='drand48()'
drand48_r_proto='REENTRANT_PROTO_I_ST'
dtrace=''
dynamic_ext='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IO/Compress IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Time/HiRes Time/Piece Unicode/Normalize XS/APItest XS/Typemap attrs mro re threads threads/shared'
eagain='EAGAIN'
ebcdic='undef'
echo='echo'
egrep='egrep'
emacs=''
endgrent_r_proto='0'
endhostent_r_proto='0'
endnetent_r_proto='0'
endprotoent_r_proto='0'
endpwent_r_proto='0'
endservent_r_proto='0'
eunicefix=':'
exe_ext=''
expr='expr'
extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IO/Compress IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Time/HiRes Time/Piece Unicode/Normalize XS/APItest XS/Typemap attrs mro re threads threads/shared Attribute/Handlers Errno Module/Pluggable Safe Test/Harness'
extern_C='extern'
extras=''
fflushNULL='define'
fflushall='undef'
find=''
firstmakefile='makefile'
flex=''
fpossize='16'
fpostype='fpos_t'
freetype='void'
from=':'
full_ar='/usr/bin/ar'
full_csh='/bin/csh'
full_sed='/bin/sed'
gccansipedantic=''
gccosandvers=''
gccversion='4.4.7 20120313 (Red Hat 4.4.7-14)'
getgrent_r_proto='REENTRANT_PROTO_I_SBWR'
getgrgid_r_proto='REENTRANT_PROTO_I_TSBWR'
getgrnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gethostbyaddr_r_proto='REENTRANT_PROTO_I_TsISBWRE'
gethostbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
gethostent_r_proto='REENTRANT_PROTO_I_SBWRE'
getlogin_r_proto='REENTRANT_PROTO_I_BW'
getnetbyaddr_r_proto='REENTRANT_PROTO_I_uISBWRE'
getnetbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
getnetent_r_proto='REENTRANT_PROTO_I_SBWRE'
getprotobyname_r_proto='REENTRANT_PROTO_I_CSBWR'
getprotobynumber_r_proto='REENTRANT_PROTO_I_ISBWR'
getprotoent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwnam_r_proto='REENTRANT_PROTO_I_CSBWR'
getpwuid_r_proto='REENTRANT_PROTO_I_TSBWR'
getservbyname_r_proto='REENTRANT_PROTO_I_CCSBWR'
getservbyport_r_proto='REENTRANT_PROTO_I_ICSBWR'
getservent_r_proto='REENTRANT_PROTO_I_SBWR'
getspnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gidformat='"u"'
gidsign='1'
gidsize='4'
gidtype='gid_t'
glibpth='/usr/shlib  /lib /usr/lib /usr/lib/386 /lib/386 /usr/ccs/lib /usr/ucblib /usr/local/lib /lib64 /usr/lib64 /usr/local/lib64 '
gmake='gmake'
gmtime_r_proto='REENTRANT_PROTO_S_TS'
gnulibc_version='2.12'
grep='grep'
groupcat='cat /etc/group'
groupstype='gid_t'
gzip='gzip'
h_fcntl='false'
h_sysfile='true'
hint='recommended'
hostcat='cat /etc/hosts'
html1dir=' '
html1direxp=''
html3dir=' '
html3direxp=''
i16size='2'
i16type='short'
i32size='4'
i32type='int'
i64size='8'
i64type='long'
i8size='1'
i8type='signed char'
i_arpainet='define'
i_assert='define'
i_bsdioctl=''
i_crypt='define'
i_db='define'
i_dbm='undef'
i_dirent='define'
i_dld='undef'
i_dlfcn='define'
i_fcntl='undef'
i_float='define'
i_fp='undef'
i_fp_class='undef'
i_gdbm='define'
i_gdbm_ndbm='undef'
i_gdbmndbm='define'
i_grp='define'
i_ieeefp='undef'
i_inttypes='define'
i_langinfo='define'
i_libutil='undef'
i_limits='define'
i_locale='define'
i_machcthr='undef'
i_malloc='define'
i_mallocmalloc='undef'
i_math='define'
i_memory='undef'
i_mntent='define'
i_ndbm='undef'
i_netdb='define'
i_neterrno='undef'
i_netinettcp='define'
i_niin='define'
i_poll='define'
i_prot='undef'
i_pthread='define'
i_pwd='define'
i_rpcsvcdbm='undef'
i_sfio='undef'
i_sgtty='undef'
i_shadow='define'
i_socks='undef'
i_stdarg='define'
i_stddef='define'
i_stdlib='define'
i_string='define'
i_sunmath='undef'
i_sysaccess='undef'
i_sysdir='define'
i_sysfile='define'
i_sysfilio='undef'
i_sysin='undef'
i_sysioctl='define'
i_syslog='define'
i_sysmman='define'
i_sysmode='undef'
i_sysmount='define'
i_sysndir='undef'
i_sysparam='define'
i_syspoll='define'
i_sysresrc='define'
i_syssecrt='undef'
i_sysselct='define'
i_syssockio='undef'
i_sysstat='define'
i_sysstatfs='define'
i_sysstatvfs='define'
i_systime='define'
i_systimek='undef'
i_systimes='define'
i_systypes='define'
i_sysuio='define'
i_sysun='define'
i_sysutsname='define'
i_sysvfs='define'
i_syswait='define'
i_termio='undef'
i_termios='define'
i_time='define'
i_unistd='define'
i_ustat='define'
i_utime='define'
i_values='define'
i_varargs='undef'
i_varhdr='stdarg.h'
i_vfork='undef'
ignore_versioned_solibs='y'
inc_version_list='5.10.0'
inc_version_list_init='"5.10.0",0'
incpath=''
inews=''
initialinstalllocation='/usr/bin'
installarchlib='/usr/lib64/perl5'
installbin='/usr/bin'
installhtml1dir=''
installhtml3dir=''
installman1dir='/usr/share/man/man1'
installman3dir='/usr/share/man/man3'
installprefix='/usr'
installprefixexp='/usr'
installprivlib='/usr/share/perl5'
installscript='/usr/bin'
installsitearch='/usr/local/lib64/perl5'
installsitebin='/usr/local/bin'
installsitehtml1dir=''
installsitehtml3dir=''
installsitelib='/usr/local/share/perl5'
installsiteman1dir='/usr/local/share/man/man1'
installsiteman3dir='/usr/local/share/man/man3'
installsitescript='/usr/local/bin'
installstyle='lib64/perl5'
installusrbinperl='undef'
installvendorarch='/usr/lib64/perl5/vendor_perl'
installvendorbin='/usr/bin'
installvendorhtml1dir=''
installvendorhtml3dir=''
installvendorlib='/usr/share/perl5/vendor_perl'
installvendorman1dir='/usr/share/man/man1'
installvendorman3dir='/usr/share/man/man3'
installvendorscript='/usr/bin'
intsize='4'
issymlink='test -h'
ivdformat='"ld"'
ivsize='8'
ivtype='long'
known_extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IO/Compress IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Time/HiRes Time/Piece Unicode/Normalize Win32 Win32API/File Win32CORE XS/APItest XS/Typemap attrs mro re threads threads/shared'
ksh=''
ld='gcc'
lddlflags='-shared -O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic'
ldflags=' -fstack-protector'
ldflags_uselargefiles=''
ldlibpthname='LD_LIBRARY_PATH'
less='less'
lib_ext='.a'
libc=''
libdb_needs_pthread='N'
libperl='libperl.so'
libpth='/usr/local/lib64 /lib64 /usr/lib64'
libs='-lresolv -lnsl -lgdbm -ldb -ldl -lm -lcrypt -lutil -lpthread -lc'
libsdirs=' /usr/lib64'
libsfiles=' libresolv.so libnsl.so libgdbm.so libdb.so libdl.so libm.so libcrypt.so libutil.so libpthread.so libc.so'
libsfound=' /usr/lib64/libresolv.so /usr/lib64/libnsl.so /usr/lib64/libgdbm.so /usr/lib64/libdb.so /usr/lib64/libdl.so /usr/lib64/libm.so /usr/lib64/libcrypt.so /usr/lib64/libutil.so /usr/lib64/libpthread.so /usr/lib64/libc.so'
libspath=' /usr/local/lib64 /lib64 /usr/lib64'
libswanted='sfio socket resolv inet nsl nm ndbm gdbm dbm db malloc dl dld ld sun m crypt sec util pthread c cposix posix ucb BSD gdbm_compat'
libswanted_uselargefiles=''
line=''
lint=''
lkflags=''
ln='ln'
lns='/bin/ln -s'
localtime_r_proto='REENTRANT_PROTO_S_TS'
locincpth='/usr/local/include /opt/local/include /usr/gnu/include /opt/gnu/include /usr/GNU/include /opt/GNU/include'
loclibpth='/usr/local/lib /opt/local/lib /usr/gnu/lib /opt/gnu/lib /usr/GNU/lib /opt/GNU/lib'
longdblsize='16'
longlongsize='8'
longsize='8'
lp=''
lpr=''
ls='ls'
lseeksize='8'
lseektype='off_t'
mad='undef'
madlyh=''
madlyobj=''
madlysrc=''
mail=''
mailx=''
make='make'
make_set_make='#'
mallocobj=''
mallocsrc=''
malloctype='void *'
man1dir='/usr/share/man/man1'
man1direxp='/usr/share/man/man1'
man1ext='1'
man3dir='/usr/share/man/man3'
man3direxp='/usr/share/man/man3'
man3ext='3pm'
mips_type=''
mistrustnm=''
mkdir='mkdir'
mmaptype='void *'
modetype='mode_t'
more='more'
multiarch='undef'
mv=''
myarchname='x86_64-linux'
mydomain='.localdomain'
myhostname='localhost'
myuname='linux x86-027.build.eng.bos.redhat.com 2.6.18-402.el5 #1 smp thu jan 8 06:22:34 est 2015 x86_64 x86_64 x86_64 gnulinux '
n='-n'
need_va_copy='define'
netdb_hlen_type='size_t'
netdb_host_type='char *'
netdb_name_type='const char *'
netdb_net_type='in_addr_t'
nm='nm'
nm_opt=''
nm_so_opt='--dynamic'
nonxs_ext='Attribute/Handlers Errno Module/Pluggable Safe Test/Harness'
nroff='nroff'
nvEUformat='"E"'
nvFUformat='"F"'
nvGUformat='"G"'
nv_overflows_integers_at='256.0*256.0*256.0*256.0*256.0*256.0*2.0*2.0*2.0*2.0*2.0'
nv_preserves_uv_bits='53'
nveformat='"e"'
nvfformat='"f"'
nvgformat='"g"'
nvsize='8'
nvtype='double'
o_nonblock='O_NONBLOCK'
obj_ext='.o'
old_pthread_create_joinable=''
optimize='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic'
orderlib='false'
osname='linux'
osvers='2.6.18-402.el5'
otherlibdirs=' '
package='perl5'
pager='/usr/bin/less -isr'
passcat='cat /etc/passwd'
patchlevel='10'
path_sep=':'
perl5='/usr/bin/perl'
perl=''
perl_patchlevel=''
perladmin='root@localhost'
perllibs='-lresolv -lnsl -ldl -lm -lcrypt -lutil -lpthread -lc'
perlpath='/usr/bin/perl'
pg='pg'
phostname=''
pidtype='pid_t'
plibpth=''
pmake=''
pr=''
prefix='/usr'
prefixexp='/usr'
privlib='/usr/share/perl5'
privlibexp='/usr/share/perl5'
procselfexe='"/proc/self/exe"'
prototype='define'
ptrsize='8'
quadkind='2'
quadtype='long'
randbits='48'
randfunc='drand48'
random_r_proto='REENTRANT_PROTO_I_St'
randseedtype='long'
ranlib=':'
rd_nodata='-1'
readdir64_r_proto='REENTRANT_PROTO_I_TSR'
readdir_r_proto='REENTRANT_PROTO_I_TSR'
revision='5'
rm='rm'
rm_try='/bin/rm -f try try a.out .out try.[cho] try..o core core.try* try.core*'
rmail=''
run=''
runnm='false'
sGMTIME_max='67768036191676799'
sGMTIME_min='-62167219200'
sLOCALTIME_max='67768036191694799'
sLOCALTIME_min='-62167201438'
sPRIEUldbl='"LE"'
sPRIFUldbl='"LF"'
sPRIGUldbl='"LG"'
sPRIXU64='"lX"'
sPRId64='"ld"'
sPRIeldbl='"Le"'
sPRIfldbl='"Lf"'
sPRIgldbl='"Lg"'
sPRIi64='"li"'
sPRIo64='"lo"'
sPRIu64='"lu"'
sPRIx64='"lx"'
sSCNfldbl='"Lf"'
sched_yield='sched_yield()'
scriptdir='/usr/bin'
scriptdirexp='/usr/bin'
sed='sed'
seedfunc='srand48'
selectminbits='64'
selecttype='fd_set *'
sendmail=''
setgrent_r_proto='0'
sethostent_r_proto='0'
setlocale_r_proto='0'
setnetent_r_proto='0'
setprotoent_r_proto='0'
setpwent_r_proto='0'
setservent_r_proto='0'
sh='/bin/sh'
shar=''
sharpbang='#!'
shmattype='void *'
shortsize='2'
shrpenv=''
shsharp='true'
sig_count='65'
sig_name='ZERO HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT CHLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO PWR SYS NUM32 NUM33 RTMIN NUM35 NUM36 NUM37 NUM38 NUM39 NUM40 NUM41 NUM42 NUM43 NUM44 NUM45 NUM46 NUM47 NUM48 NUM49 NUM50 NUM51 NUM52 NUM53 NUM54 NUM55 NUM56 NUM57 NUM58 NUM59 NUM60 NUM61 NUM62 NUM63 RTMAX IOT CLD POLL UNUSED '
sig_name_init='"ZERO", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS", "NUM32", "NUM33", "RTMIN", "NUM35", "NUM36", "NUM37", "NUM38", "NUM39", "NUM40", "NUM41", "NUM42", "NUM43", "NUM44", "NUM45", "NUM46", "NUM47", "NUM48", "NUM49", "NUM50", "NUM51", "NUM52", "NUM53", "NUM54", "NUM55", "NUM56", "NUM57", "NUM58", "NUM59", "NUM60", "NUM61", "NUM62", "NUM63", "RTMAX", "IOT", "CLD", "POLL", "UNUSED", 0'
sig_num='0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 6 17 29 31 '
sig_num_init='0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 6, 17, 29, 31, 0'
sig_size='69'
signal_t='void'
sitearch='/usr/local/lib64/perl5'
sitearchexp='/usr/local/lib64/perl5'
sitebin='/usr/local/bin'
sitebinexp='/usr/local/bin'
sitehtml1dir=''
sitehtml1direxp=''
sitehtml3dir=''
sitehtml3direxp=''
sitelib='/usr/local/share/perl5'
sitelib_stem='/usr/local/share/perl5'
sitelibexp='/usr/local/share/perl5'
siteman1dir='/usr/local/share/man/man1'
siteman1direxp='/usr/local/share/man/man1'
siteman3dir='/usr/local/share/man/man3'
siteman3direxp='/usr/local/share/man/man3'
siteprefix='/usr/local'
siteprefixexp='/usr/local'
sitescript='/usr/local/bin'
sitescriptexp='/usr/local/bin'
sizesize='8'
sizetype='size_t'
sleep=''
smail=''
so='so'
sockethdr=''
socketlib=''
socksizetype='socklen_t'
sort='sort'
spackage='Perl5'
spitshell='cat'
srand48_r_proto='REENTRANT_PROTO_I_LS'
srandom_r_proto='REENTRANT_PROTO_I_TS'
src='.'
ssizetype='ssize_t'
startperl='#!/usr/bin/perl'
startsh='#!/bin/sh'
static_ext=' '
stdchar='char'
stdio_base='((fp)->_IO_read_base)'
stdio_bufsiz='((fp)->_IO_read_end - (fp)->_IO_read_base)'
stdio_cnt='((fp)->_IO_read_end - (fp)->_IO_read_ptr)'
stdio_filbuf=''
stdio_ptr='((fp)->_IO_read_ptr)'
stdio_stream_array=''
strerror_r_proto='REENTRANT_PROTO_B_IBW'
strings='/usr/include/string.h'
submit=''
subversion='1'
sysman='/usr/share/man/man1'
tail=''
tar=''
targetarch=''
tbl=''
tee=''
test='test'
timeincl='/usr/include/sys/time.h /usr/include/time.h '
timetype='time_t'
tmpnam_r_proto='REENTRANT_PROTO_B_B'
to=':'
touch='touch'
tr='tr'
trnl='\n'
troff=''
ttyname_r_proto='REENTRANT_PROTO_I_IBW'
u16size='2'
u16type='unsigned short'
u32size='4'
u32type='unsigned int'
u64size='8'
u64type='unsigned long'
u8size='1'
u8type='unsigned char'
uidformat='"u"'
uidsign='1'
uidsize='4'
uidtype='uid_t'
uname='uname'
uniq='uniq'
uquadtype='unsigned long'
use5005threads='undef'
use64bitall='define'
use64bitint='define'
usecrosscompile='undef'
usedevel='undef'
usedl='define'
usedtrace='undef'
usefaststdio='undef'
useithreads='define'
uselargefiles='define'
uselongdouble='undef'
usemallocwrap='define'
usemorebits='undef'
usemultiplicity='define'
usemymalloc='n'
usenm='false'
useopcode='true'
useperlio='define'
useposix='true'
usereentrant='undef'
userelocatableinc='undef'
usesfio='false'
useshrplib='true'
usesitecustomize='define'
usesocks='undef'
usethreads='define'
usevendorprefix='define'
usevfork='false'
usrinc='/usr/include'
uuname=''
uvXUformat='"lX"'
uvoformat='"lo"'
uvsize='8'
uvtype='unsigned long'
uvuformat='"lu"'
uvxformat='"lx"'
vendorarch='/usr/lib64/perl5/vendor_perl'
vendorarchexp='/usr/lib64/perl5/vendor_perl'
vendorbin='/usr/bin'
vendorbinexp='/usr/bin'
vendorhtml1dir=' '
vendorhtml1direxp=''
vendorhtml3dir=' '
vendorhtml3direxp=''
vendorlib='/usr/share/perl5/vendor_perl'
vendorlib_stem='/usr/share/perl5/vendor_perl'
vendorlibexp='/usr/share/perl5/vendor_perl'
vendorman1dir='/usr/share/man/man1'
vendorman1direxp='/usr/share/man/man1'
vendorman3dir='/usr/share/man/man3'
vendorman3direxp='/usr/share/man/man3'
vendorprefix='/usr'
vendorprefixexp='/usr'
vendorscript='/usr/bin'
vendorscriptexp='/usr/bin'
version='5.10.1'
version_patchlevel_string='version 10 subversion 1'
versiononly='undef'
vi=''
voidflags='15'
xlibpth='/usr/lib/386 /lib/386'
yacc='yacc'
yaccflags=''
zcat=''
zip='zip'
!END!

my $i = 0;
foreach my $c (8,7,6,5,4,3,2) { $i |= ord($c); $i <<= 8 }
$i |= ord(1);
our $byteorder = join('', unpack('aaaaaaaa', pack('L!', $i)));
s/(byteorder=)(['"]).*?\2/$1$2$Config::byteorder$2/m;

my $config_sh_len = length $_;

our $Config_SH_expanded = "\n$_" . << 'EOVIRTUAL';
ccflags_nolargefiles='-D_REENTRANT -D_GNU_SOURCE -fno-strict-aliasing -pipe -fstack-protector -I/usr/local/include '
ldflags_nolargefiles=' -fstack-protector'
libs_nolargefiles='-lresolv -lnsl -lgdbm -ldb -ldl -lm -lcrypt -lutil -lpthread -lc'
libswanted_nolargefiles='sfio socket resolv inet nsl nm ndbm gdbm dbm db malloc dl dld ld sun m crypt sec util pthread c cposix posix ucb BSD gdbm_compat'
EOVIRTUAL
eval {
	# do not have hairy conniptions if this isnt available
	require 'Config_git.pl';
	$Config_SH_expanded .= $Config::Git_Data;
	1;
} or warn "Warning: failed to load Config_git.pl, something strange about this perl...\n";

# Search for it in the big string
sub fetch_string {
    my($self, $key) = @_;

    # We only have ' delimted.
    my $start = index($Config_SH_expanded, "\n$key=\'");
    # Start can never be -1 now, as we've rigged the long string we're
    # searching with an initial dummy newline.
    return undef if $start == -1;

    $start += length($key) + 3;

    my $value = substr($Config_SH_expanded, $start,
                       index($Config_SH_expanded, "'\n", $start)
		       - $start);
    # So we can say "if $Config{'foo'}".
    $value = undef if $value eq 'undef';
    $self->{$key} = $value; # cache it
}

my $prevpos = 0;

sub FIRSTKEY {
    $prevpos = 0;
    substr($Config_SH_expanded, 1, index($Config_SH_expanded, '=') - 1 );
}

sub NEXTKEY {
    my $pos = index($Config_SH_expanded, qq('\n), $prevpos) + 2;
    my $len = index($Config_SH_expanded, "=", $pos) - $pos;
    $prevpos = $pos;
    $len > 0 ? substr($Config_SH_expanded, $pos, $len) : undef;
}

sub EXISTS {
    return 1 if exists($_[0]->{$_[1]});

    return(index($Config_SH_expanded, "\n$_[1]='") != -1
          );
}

sub STORE  { die "\%Config::Config is read-only\n" }
*DELETE = \&STORE;
*CLEAR  = \&STORE;


sub config_sh {
    substr $Config_SH_expanded, 1, $config_sh_len;
}

sub config_re {
    my $re = shift;
    return map { chomp; $_ } grep eval{ /^(?:$re)=/ }, split /^/,
    $Config_SH_expanded;
}

sub config_vars {
    # implements -V:cfgvar option (see perlrun -V:)
    foreach (@_) {
	# find optional leading, trailing colons; and query-spec
	my ($notag,$qry,$lncont) = m/^(:)?(.*?)(:)?$/;	# flags fore and aft, 
	# map colon-flags to print decorations
	my $prfx = $notag ? '': "$qry=";		# tag-prefix for print
	my $lnend = $lncont ? ' ' : ";\n";		# line ending for print

	# all config-vars are by definition \w only, any \W means regex
	if ($qry =~ /\W/) {
	    my @matches = config_re($qry);
	    print map "$_$lnend", @matches ? @matches : "$qry: not found"		if !$notag;
	    print map { s/\w+=//; "$_$lnend" } @matches ? @matches : "$qry: not found"	if  $notag;
	} else {
	    my $v = (exists $Config::Config{$qry}) ? $Config::Config{$qry}
						   : 'UNKNOWN';
	    $v = 'undef' unless defined $v;
	    print "${prfx}'${v}'$lnend";
	}
    }
}

# Called by the real AUTOLOAD
sub launcher {
    undef &AUTOLOAD;
    goto \&$Config::AUTOLOAD;
}

1;
FILE   4fd09253/Cwd.pm  B�#line 1 "/usr/lib64/perl5/Cwd.pm"
package Cwd;

#line 169

use strict;
use Exporter;
use vars qw(@ISA @EXPORT @EXPORT_OK $VERSION);

$VERSION = '3.30';
my $xs_version = $VERSION;
$VERSION = eval $VERSION;

@ISA = qw/ Exporter /;
@EXPORT = qw(cwd getcwd fastcwd fastgetcwd);
push @EXPORT, qw(getdcwd) if $^O eq 'MSWin32';
@EXPORT_OK = qw(chdir abs_path fast_abs_path realpath fast_realpath);

# sys_cwd may keep the builtin command

# All the functionality of this module may provided by builtins,
# there is no sense to process the rest of the file.
# The best choice may be to have this in BEGIN, but how to return from BEGIN?

if ($^O eq 'os2') {
    local $^W = 0;

    *cwd                = defined &sys_cwd ? \&sys_cwd : \&_os2_cwd;
    *getcwd             = \&cwd;
    *fastgetcwd         = \&cwd;
    *fastcwd            = \&cwd;

    *fast_abs_path      = \&sys_abspath if defined &sys_abspath;
    *abs_path           = \&fast_abs_path;
    *realpath           = \&fast_abs_path;
    *fast_realpath      = \&fast_abs_path;

    return 1;
}

# Need to look up the feature settings on VMS.  The preferred way is to use the
# VMS::Feature module, but that may not be available to dual life modules.

my $use_vms_feature;
BEGIN {
    if ($^O eq 'VMS') {
        if (eval { local $SIG{__DIE__}; require VMS::Feature; }) {
            $use_vms_feature = 1;
        }
    }
}

# Need to look up the UNIX report mode.  This may become a dynamic mode
# in the future.
sub _vms_unix_rpt {
    my $unix_rpt;
    if ($use_vms_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    } else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i; 
    }
    return $unix_rpt;
}

# Need to look up the EFS character set mode.  This may become a dynamic
# mode in the future.
sub _vms_efs {
    my $efs;
    if ($use_vms_feature) {
        $efs = VMS::Feature::current("efs_charset");
    } else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i; 
    }
    return $efs;
}


# If loading the XS stuff doesn't work, we can fall back to pure perl
eval {
  if ( $] >= 5.006 ) {
    require XSLoader;
    XSLoader::load( __PACKAGE__, $xs_version);
  } else {
    require DynaLoader;
    push @ISA, 'DynaLoader';
    __PACKAGE__->bootstrap( $xs_version );
  }
};

# Must be after the DynaLoader stuff:
$VERSION = eval $VERSION;

# Big nasty table of function aliases
my %METHOD_MAP =
  (
   VMS =>
   {
    cwd			=> '_vms_cwd',
    getcwd		=> '_vms_cwd',
    fastcwd		=> '_vms_cwd',
    fastgetcwd		=> '_vms_cwd',
    abs_path		=> '_vms_abs_path',
    fast_abs_path	=> '_vms_abs_path',
   },

   MSWin32 =>
   {
    # We assume that &_NT_cwd is defined as an XSUB or in the core.
    cwd			=> '_NT_cwd',
    getcwd		=> '_NT_cwd',
    fastcwd		=> '_NT_cwd',
    fastgetcwd		=> '_NT_cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   dos => 
   {
    cwd			=> '_dos_cwd',
    getcwd		=> '_dos_cwd',
    fastgetcwd		=> '_dos_cwd',
    fastcwd		=> '_dos_cwd',
    abs_path		=> 'fast_abs_path',
   },

   # QNX4.  QNX6 has a $os of 'nto'.
   qnx =>
   {
    cwd			=> '_qnx_cwd',
    getcwd		=> '_qnx_cwd',
    fastgetcwd		=> '_qnx_cwd',
    fastcwd		=> '_qnx_cwd',
    abs_path		=> '_qnx_abs_path',
    fast_abs_path	=> '_qnx_abs_path',
   },

   cygwin =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   epoc =>
   {
    cwd			=> '_epoc_cwd',
    getcwd	        => '_epoc_cwd',
    fastgetcwd		=> '_epoc_cwd',
    fastcwd		=> '_epoc_cwd',
    abs_path		=> 'fast_abs_path',
   },

   MacOS =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
   },
  );

$METHOD_MAP{NT} = $METHOD_MAP{MSWin32};


# Find the pwd command in the expected locations.  We assume these
# are safe.  This prevents _backtick_pwd() consulting $ENV{PATH}
# so everything works under taint mode.
my $pwd_cmd;
foreach my $try ('/bin/pwd',
		 '/usr/bin/pwd',
		 '/QOpenSys/bin/pwd', # OS/400 PASE.
		) {

    if( -x $try ) {
        $pwd_cmd = $try;
        last;
    }
}
my $found_pwd_cmd = defined($pwd_cmd);
unless ($pwd_cmd) {
    # Isn't this wrong?  _backtick_pwd() will fail if somenone has
    # pwd in their path but it is not /bin/pwd or /usr/bin/pwd?
    # See [perl #16774]. --jhi
    $pwd_cmd = 'pwd';
}

# Lazy-load Carp
sub _carp  { require Carp; Carp::carp(@_)  }
sub _croak { require Carp; Carp::croak(@_) }

# The 'natural and safe form' for UNIX (pwd may be setuid root)
sub _backtick_pwd {
    # Localize %ENV entries in a way that won't create new hash keys
    my @localize = grep exists $ENV{$_}, qw(PATH IFS CDPATH ENV BASH_ENV);
    local @ENV{@localize};
    
    my $cwd = `$pwd_cmd`;
    # Belt-and-suspenders in case someone said "undef $/".
    local $/ = "\n";
    # `pwd` may fail e.g. if the disk is full
    chomp($cwd) if defined $cwd;
    $cwd;
}

# Since some ports may predefine cwd internally (e.g., NT)
# we take care not to override an existing definition for cwd().

unless ($METHOD_MAP{$^O}{cwd} or defined &cwd) {
    # The pwd command is not available in some chroot(2)'ed environments
    my $sep = $Config::Config{path_sep} || ':';
    my $os = $^O;  # Protect $^O from tainting


    # Try again to find a pwd, this time searching the whole PATH.
    if (defined $ENV{PATH} and $os ne 'MSWin32') {  # no pwd on Windows
	my @candidates = split($sep, $ENV{PATH});
	while (!$found_pwd_cmd and @candidates) {
	    my $candidate = shift @candidates;
	    $found_pwd_cmd = 1 if -x "$candidate/pwd";
	}
    }

    # MacOS has some special magic to make `pwd` work.
    if( $os eq 'MacOS' || $found_pwd_cmd )
    {
	*cwd = \&_backtick_pwd;
    }
    else {
	*cwd = \&getcwd;
    }
}

if ($^O eq 'cygwin') {
  # We need to make sure cwd() is called with no args, because it's
  # got an arg-less prototype and will die if args are present.
  local $^W = 0;
  my $orig_cwd = \&cwd;
  *cwd = sub { &$orig_cwd() }
}


# set a reasonable (and very safe) default for fastgetcwd, in case it
# isn't redefined later (20001212 rspier)
*fastgetcwd = \&cwd;

# A non-XS version of getcwd() - also used to bootstrap the perl build
# process, when miniperl is running and no XS loading happens.
sub _perl_getcwd
{
    abs_path('.');
}

# By John Bazik
#
# Usage: $cwd = &fastcwd;
#
# This is a faster version of getcwd.  It's also more dangerous because
# you might chdir out of a directory that you can't chdir back into.
    
sub fastcwd_ {
    my($odev, $oino, $cdev, $cino, $tdev, $tino);
    my(@path, $path);
    local(*DIR);

    my($orig_cdev, $orig_cino) = stat('.');
    ($cdev, $cino) = ($orig_cdev, $orig_cino);
    for (;;) {
	my $direntry;
	($odev, $oino) = ($cdev, $cino);
	CORE::chdir('..') || return undef;
	($cdev, $cino) = stat('.');
	last if $odev == $cdev && $oino == $cino;
	opendir(DIR, '.') || return undef;
	for (;;) {
	    $direntry = readdir(DIR);
	    last unless defined $direntry;
	    next if $direntry eq '.';
	    next if $direntry eq '..';

	    ($tdev, $tino) = lstat($direntry);
	    last unless $tdev != $odev || $tino != $oino;
	}
	closedir(DIR);
	return undef unless defined $direntry; # should never happen
	unshift(@path, $direntry);
    }
    $path = '/' . join('/', @path);
    if ($^O eq 'apollo') { $path = "/".$path; }
    # At this point $path may be tainted (if tainting) and chdir would fail.
    # Untaint it then check that we landed where we started.
    $path =~ /^(.*)\z/s		# untaint
	&& CORE::chdir($1) or return undef;
    ($cdev, $cino) = stat('.');
    die "Unstable directory path, current directory changed unexpectedly"
	if $cdev != $orig_cdev || $cino != $orig_cino;
    $path;
}
if (not defined &fastcwd) { *fastcwd = \&fastcwd_ }


# Keeps track of current working directory in PWD environment var
# Usage:
#	use Cwd 'chdir';
#	chdir $newdir;

my $chdir_init = 0;

sub chdir_init {
    if ($ENV{'PWD'} and $^O ne 'os2' and $^O ne 'dos' and $^O ne 'MSWin32') {
	my($dd,$di) = stat('.');
	my($pd,$pi) = stat($ENV{'PWD'});
	if (!defined $dd or !defined $pd or $di != $pi or $dd != $pd) {
	    $ENV{'PWD'} = cwd();
	}
    }
    else {
	my $wd = cwd();
	$wd = Win32::GetFullPathName($wd) if $^O eq 'MSWin32';
	$ENV{'PWD'} = $wd;
    }
    # Strip an automounter prefix (where /tmp_mnt/foo/bar == /foo/bar)
    if ($^O ne 'MSWin32' and $ENV{'PWD'} =~ m|(/[^/]+(/[^/]+/[^/]+))(.*)|s) {
	my($pd,$pi) = stat($2);
	my($dd,$di) = stat($1);
	if (defined $pd and defined $dd and $di == $pi and $dd == $pd) {
	    $ENV{'PWD'}="$2$3";
	}
    }
    $chdir_init = 1;
}

sub chdir {
    my $newdir = @_ ? shift : '';	# allow for no arg (chdir to HOME dir)
    $newdir =~ s|///*|/|g unless $^O eq 'MSWin32';
    chdir_init() unless $chdir_init;
    my $newpwd;
    if ($^O eq 'MSWin32') {
	# get the full path name *before* the chdir()
	$newpwd = Win32::GetFullPathName($newdir);
    }

    return 0 unless CORE::chdir $newdir;

    if ($^O eq 'VMS') {
	return $ENV{'PWD'} = $ENV{'DEFAULT'}
    }
    elsif ($^O eq 'MacOS') {
	return $ENV{'PWD'} = cwd();
    }
    elsif ($^O eq 'MSWin32') {
	$ENV{'PWD'} = $newpwd;
	return 1;
    }

    if (ref $newdir eq 'GLOB') { # in case a file/dir handle is passed in
	$ENV{'PWD'} = cwd();
    } elsif ($newdir =~ m#^/#s) {
	$ENV{'PWD'} = $newdir;
    } else {
	my @curdir = split(m#/#,$ENV{'PWD'});
	@curdir = ('') unless @curdir;
	my $component;
	foreach $component (split(m#/#, $newdir)) {
	    next if $component eq '.';
	    pop(@curdir),next if $component eq '..';
	    push(@curdir,$component);
	}
	$ENV{'PWD'} = join('/',@curdir) || '/';
    }
    1;
}


sub _perl_abs_path
{
    my $start = @_ ? shift : '.';
    my($dotdots, $cwd, @pst, @cst, $dir, @tst);

    unless (@cst = stat( $start ))
    {
	_carp("stat($start): $!");
	return '';
    }

    unless (-d _) {
        # Make sure we can be invoked on plain files, not just directories.
        # NOTE that this routine assumes that '/' is the only directory separator.
	
        my ($dir, $file) = $start =~ m{^(.*)/(.+)$}
	    or return cwd() . '/' . $start;
	
	# Can't use "-l _" here, because the previous stat was a stat(), not an lstat().
	if (-l $start) {
	    my $link_target = readlink($start);
	    die "Can't resolve link $start: $!" unless defined $link_target;
	    
	    require File::Spec;
            $link_target = $dir . '/' . $link_target
                unless File::Spec->file_name_is_absolute($link_target);
	    
	    return abs_path($link_target);
	}
	
	return $dir ? abs_path($dir) . "/$file" : "/$file";
    }

    $cwd = '';
    $dotdots = $start;
    do
    {
	$dotdots .= '/..';
	@pst = @cst;
	local *PARENT;
	unless (opendir(PARENT, $dotdots))
	{
	    # probably a permissions issue.  Try the native command.
	    return File::Spec->rel2abs( $start, _backtick_pwd() );
	}
	unless (@cst = stat($dotdots))
	{
	    _carp("stat($dotdots): $!");
	    closedir(PARENT);
	    return '';
	}
	if ($pst[0] == $cst[0] && $pst[1] == $cst[1])
	{
	    $dir = undef;
	}
	else
	{
	    do
	    {
		unless (defined ($dir = readdir(PARENT)))
	        {
		    _carp("readdir($dotdots): $!");
		    closedir(PARENT);
		    return '';
		}
		$tst[0] = $pst[0]+1 unless (@tst = lstat("$dotdots/$dir"))
	    }
	    while ($dir eq '.' || $dir eq '..' || $tst[0] != $pst[0] ||
		   $tst[1] != $pst[1]);
	}
	$cwd = (defined $dir ? "$dir" : "" ) . "/$cwd" ;
	closedir(PARENT);
    } while (defined $dir);
    chop($cwd) unless $cwd eq '/'; # drop the trailing /
    $cwd;
}


my $Curdir;
sub fast_abs_path {
    local $ENV{PWD} = $ENV{PWD} || ''; # Guard against clobberage
    my $cwd = getcwd();
    require File::Spec;
    my $path = @_ ? shift : ($Curdir ||= File::Spec->curdir);

    # Detaint else we'll explode in taint mode.  This is safe because
    # we're not doing anything dangerous with it.
    ($path) = $path =~ /(.*)/;
    ($cwd)  = $cwd  =~ /(.*)/;

    unless (-e $path) {
 	_croak("$path: No such file or directory");
    }

    unless (-d _) {
        # Make sure we can be invoked on plain files, not just directories.
	
	my ($vol, $dir, $file) = File::Spec->splitpath($path);
	return File::Spec->catfile($cwd, $path) unless length $dir;

	if (-l $path) {
	    my $link_target = readlink($path);
	    die "Can't resolve link $path: $!" unless defined $link_target;
	    
	    $link_target = File::Spec->catpath($vol, $dir, $link_target)
                unless File::Spec->file_name_is_absolute($link_target);
	    
	    return fast_abs_path($link_target);
	}
	
	return $dir eq File::Spec->rootdir
	  ? File::Spec->catpath($vol, $dir, $file)
	  : fast_abs_path(File::Spec->catpath($vol, $dir, '')) . '/' . $file;
    }

    if (!CORE::chdir($path)) {
 	_croak("Cannot chdir to $path: $!");
    }
    my $realpath = getcwd();
    if (! ((-d $cwd) && (CORE::chdir($cwd)))) {
 	_croak("Cannot chdir back to $cwd: $!");
    }
    $realpath;
}

# added function alias to follow principle of least surprise
# based on previous aliasing.  --tchrist 27-Jan-00
*fast_realpath = \&fast_abs_path;


# --- PORTING SECTION ---

# VMS: $ENV{'DEFAULT'} points to default directory at all times
# 06-Mar-1996  Charles Bailey  bailey@newman.upenn.edu
# Note: Use of Cwd::chdir() causes the logical name PWD to be defined
#   in the process logical name table as the default device and directory
#   seen by Perl. This may not be the same as the default device
#   and directory seen by DCL after Perl exits, since the effects
#   the CRTL chdir() function persist only until Perl exits.

sub _vms_cwd {
    return $ENV{'DEFAULT'};
}

sub _vms_abs_path {
    return $ENV{'DEFAULT'} unless @_;
    my $path = shift;

    my $efs = _vms_efs;
    my $unix_rpt = _vms_unix_rpt;

    if (defined &VMS::Filespec::vmsrealpath) {
        my $path_unix = 0;
        my $path_vms = 0;

        $path_unix = 1 if ($path =~ m#(?<=\^)/#);
        $path_unix = 1 if ($path =~ /^\.\.?$/);
        $path_vms = 1 if ($path =~ m#[\[<\]]#);
        $path_vms = 1 if ($path =~ /^--?$/);

        my $unix_mode = $path_unix;
        if ($efs) {
            # In case of a tie, the Unix report mode decides.
            if ($path_vms == $path_unix) {
                $unix_mode = $unix_rpt;
            } else {
                $unix_mode = 0 if $path_vms;
            }
        }

        if ($unix_mode) {
            # Unix format
            return VMS::Filespec::unixrealpath($path);
        }

	# VMS format

	my $new_path = VMS::Filespec::vmsrealpath($path);

	# Perl expects directories to be in directory format
	$new_path = VMS::Filespec::pathify($new_path) if -d $path;
	return $new_path;
    }

    # Fallback to older algorithm if correct ones are not
    # available.

    if (-l $path) {
        my $link_target = readlink($path);
        die "Can't resolve link $path: $!" unless defined $link_target;

        return _vms_abs_path($link_target);
    }

    # may need to turn foo.dir into [.foo]
    my $pathified = VMS::Filespec::pathify($path);
    $path = $pathified if defined $pathified;
	
    return VMS::Filespec::rmsexpand($path);
}

sub _os2_cwd {
    $ENV{'PWD'} = `cmd /c cd`;
    chomp $ENV{'PWD'};
    $ENV{'PWD'} =~ s:\\:/:g ;
    return $ENV{'PWD'};
}

sub _win32_cwd {
    if (defined &DynaLoader::boot_DynaLoader) {
	$ENV{'PWD'} = Win32::GetCwd();
    }
    else { # miniperl
	chomp($ENV{'PWD'} = `cd`);
    }
    $ENV{'PWD'} =~ s:\\:/:g ;
    return $ENV{'PWD'};
}

*_NT_cwd = defined &Win32::GetCwd ? \&_win32_cwd : \&_os2_cwd;

sub _dos_cwd {
    if (!defined &Dos::GetCwd) {
        $ENV{'PWD'} = `command /c cd`;
        chomp $ENV{'PWD'};
        $ENV{'PWD'} =~ s:\\:/:g ;
    } else {
        $ENV{'PWD'} = Dos::GetCwd();
    }
    return $ENV{'PWD'};
}

sub _qnx_cwd {
	local $ENV{PATH} = '';
	local $ENV{CDPATH} = '';
	local $ENV{ENV} = '';
    $ENV{'PWD'} = `/usr/bin/fullpath -t`;
    chomp $ENV{'PWD'};
    return $ENV{'PWD'};
}

sub _qnx_abs_path {
	local $ENV{PATH} = '';
	local $ENV{CDPATH} = '';
	local $ENV{ENV} = '';
    my $path = @_ ? shift : '.';
    local *REALPATH;

    defined( open(REALPATH, '-|') || exec '/usr/bin/fullpath', '-t', $path ) or
      die "Can't open /usr/bin/fullpath: $!";
    my $realpath = <REALPATH>;
    close REALPATH;
    chomp $realpath;
    return $realpath;
}

sub _epoc_cwd {
    $ENV{'PWD'} = EPOC::getcwd();
    return $ENV{'PWD'};
}


# Now that all the base-level functions are set up, alias the
# user-level functions to the right places

if (exists $METHOD_MAP{$^O}) {
  my $map = $METHOD_MAP{$^O};
  foreach my $name (keys %$map) {
    local $^W = 0;  # assignments trigger 'subroutine redefined' warning
    no strict 'refs';
    *{$name} = \&{$map->{$name}};
  }
}

# In case the XS version doesn't load.
*abs_path = \&_perl_abs_path unless defined &abs_path;
*getcwd = \&_perl_getcwd unless defined &getcwd;

# added function alias for those of us more
# used to the libc function.  --tchrist 27-Jan-00
*realpath = \&abs_path;

1;
FILE   266d379f/Digest/SHA.pm   #line 1 "/usr/lib64/perl5/Digest/SHA.pm"
package Digest::SHA;

require 5.003000;

use strict;
use integer;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

$VERSION = '5.47';

require Exporter;
require DynaLoader;
@ISA = qw(Exporter DynaLoader);
@EXPORT_OK = qw(
	hmac_sha1	hmac_sha1_base64	hmac_sha1_hex
	hmac_sha224	hmac_sha224_base64	hmac_sha224_hex
	hmac_sha256	hmac_sha256_base64	hmac_sha256_hex
	hmac_sha384	hmac_sha384_base64	hmac_sha384_hex
	hmac_sha512	hmac_sha512_base64	hmac_sha512_hex
	sha1		sha1_base64		sha1_hex
	sha224		sha224_base64		sha224_hex
	sha256		sha256_base64		sha256_hex
	sha384		sha384_base64		sha384_hex
	sha512		sha512_base64		sha512_hex);

# If possible, inherit from Digest::base (which depends on MIME::Base64)

*addfile = \&Addfile;

eval {
	require MIME::Base64;
	require Digest::base;
	push(@ISA, 'Digest::base');
};
if ($@) {
	*hexdigest = \&Hexdigest;
	*b64digest = \&B64digest;
}

# The following routines aren't time-critical, so they can be left in Perl

sub new {
	my($class, $alg) = @_;
	$alg =~ s/\D+//g if defined $alg;
	if (ref($class)) {	# instance method
		unless (defined($alg) && ($alg != $class->algorithm)) {
			sharewind($$class);
			return($class);
		}
		shaclose($$class) if $$class;
		$$class = shaopen($alg) || return;
		return($class);
	}
	$alg = 1 unless defined $alg;
	my $state = shaopen($alg) || return;
	my $self = \$state;
	bless($self, $class);
	return($self);
}

sub DESTROY {
	my $self = shift;
	shaclose($$self) if $$self;
}

sub clone {
	my $self = shift;
	my $state = shadup($$self) || return;
	my $copy = \$state;
	bless($copy, ref($self));
	return($copy);
}

*reset = \&new;

sub add_bits {
	my($self, $data, $nbits) = @_;
	unless (defined $nbits) {
		$nbits = length($data);
		$data = pack("B*", $data);
	}
	shawrite($data, $nbits, $$self);
	return($self);
}

sub _bail {
	my $msg = shift;

        require Carp;
        Carp::croak("$msg: $!");
}

sub _addfile {  # this is "addfile" from Digest::base 1.00
    my ($self, $handle) = @_;

    my $n;
    my $buf = "";

    while (($n = read($handle, $buf, 4096))) {
        $self->add($buf);
    }
    _bail("Read failed") unless defined $n;

    $self;
}

sub Addfile {
	my ($self, $file, $mode) = @_;

	return(_addfile($self, $file)) unless ref(\$file) eq 'SCALAR';

	$mode = defined($mode) ? $mode : "";
	my ($binary, $portable) = map { $_ eq $mode } ("b", "p");
	my $text = -T $file;

	local *FH;
		# protect any leading or trailing whitespace in $file;
		# otherwise, 2-arg "open" will ignore them
	$file =~ s#^(\s)#./$1#;
	open(FH, "< $file\0") or _bail("Open failed");
	binmode(FH) if $binary || $portable;

	unless ($portable && $text) {
		$self->_addfile(*FH);
		close(FH);
		return($self);
	}

	my ($n1, $n2);
	my ($buf1, $buf2) = ("", "");

	while (($n1 = read(FH, $buf1, 4096))) {
		while (substr($buf1, -1) eq "\015") {
			$n2 = read(FH, $buf2, 4096);
			_bail("Read failed") unless defined $n2;
			last unless $n2;
			$buf1 .= $buf2;
		}
		$buf1 =~ s/\015?\015\012/\012/g; 	# DOS/Windows
		$buf1 =~ s/\015/\012/g;          	# early MacOS
		$self->add($buf1);
	}
	_bail("Read failed") unless defined $n1;
	close(FH);

	$self;
}

sub dump {
	my $self = shift;
	my $file = shift || "";

	shadump($file, $$self) || return;
	return($self);
}

sub load {
	my $class = shift;
	my $file = shift || "";
	if (ref($class)) {	# instance method
		shaclose($$class) if $$class;
		$$class = shaload($file) || return;
		return($class);
	}
	my $state = shaload($file) || return;
	my $self = \$state;
	bless($self, $class);
	return($self);
}

Digest::SHA->bootstrap($VERSION);

1;
__END__

#line 670
FILE   dfbb78f9/DynaLoader.pm  +�#line 1 "/usr/lib64/perl5/DynaLoader.pm"

# Generated from DynaLoader_pm.PL

package DynaLoader;

#   And Gandalf said: 'Many folk like to know beforehand what is to
#   be set on the table; but those who have laboured to prepare the
#   feast like to keep their secret; for wonder makes the words of
#   praise louder.'

#   (Quote from Tolkien suggested by Anno Siegel.)
#
# See pod text at end of file for documentation.
# See also ext/DynaLoader/README in source tree for other information.
#
# Tim.Bunce@ig.co.uk, August 1994

BEGIN {
    $VERSION = '1.10';
}

require AutoLoader;
*AUTOLOAD = \&AutoLoader::AUTOLOAD;

use Config;

# enable debug/trace messages from DynaLoader perl code
$dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

#
# Flags to alter dl_load_file behaviour.  Assigned bits:
#   0x01  make symbols available for linking later dl_load_file's.
#         (only known to work on Solaris 2 using dlopen(RTLD_GLOBAL))
#         (ignored under VMS; effect is built-in to image linking)
#
# This is called as a class method $module->dl_load_flags.  The
# definition here will be inherited and result on "default" loading
# behaviour unless a sub-class of DynaLoader defines its own version.
#

sub dl_load_flags { 0x00 }

($dl_dlext, $dl_so, $dlsrc) = @Config::Config{qw(dlext so dlsrc)};


$do_expand = 0;



@dl_require_symbols = ();       # names of symbols we need
@dl_resolve_using   = ();       # names of files to link with
@dl_library_path    = ();       # path to look for files

#XSLoader.pm may have added elements before we were required
#@dl_shared_objects  = ();       # shared objects for symbols we have 
#@dl_librefs         = ();       # things we have loaded
#@dl_modules         = ();       # Modules we have loaded

# This is a fix to support DLD's unfortunate desire to relink -lc
@dl_resolve_using = dl_findfile('-lc') if $dlsrc eq "dl_dld.xs";

# Initialise @dl_library_path with the 'standard' library path
# for this platform as determined by Configure.

push(@dl_library_path, split(' ', $Config::Config{libpth}));


my $ldlibpthname         = $Config::Config{ldlibpthname};
my $ldlibpthname_defined = defined $Config::Config{ldlibpthname};
my $pthsep               = $Config::Config{path_sep};

# Add to @dl_library_path any extra directories we can gather from environment
# during runtime.

if ($ldlibpthname_defined &&
    exists $ENV{$ldlibpthname}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{$ldlibpthname}));
}

# E.g. HP-UX supports both its native SHLIB_PATH *and* LD_LIBRARY_PATH.

if ($ldlibpthname_defined &&
    $ldlibpthname ne 'LD_LIBRARY_PATH' &&
    exists $ENV{LD_LIBRARY_PATH}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{LD_LIBRARY_PATH}));
}


# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
# NOTE: All dl_*.xs (including dl_none.xs) define a dl_error() XSUB
boot_DynaLoader('DynaLoader') if defined(&boot_DynaLoader) &&
                                !defined(&dl_error);

if ($dl_debug) {
    print STDERR "DynaLoader.pm loaded (@INC, @dl_library_path)\n";
    print STDERR "DynaLoader not linked into this perl\n"
	    unless defined(&boot_DynaLoader);
}

1; # End of main code


sub croak   { require Carp; Carp::croak(@_)   }

sub bootstrap_inherit {
    my $module = $_[0];
    local *isa = *{"$module\::ISA"};
    local @isa = (@isa, 'DynaLoader');
    # Cannot goto due to delocalization.  Will report errors on a wrong line?
    bootstrap(@_);
}

# The bootstrap function cannot be autoloaded (without complications)
# so we define it here:

sub bootstrap {
    # use local vars to enable $module.bs script to edit values
    local(@args) = @_;
    local($module) = $args[0];
    local(@dirs, $file);

    unless ($module) {
	require Carp;
	Carp::confess("Usage: DynaLoader::bootstrap(module)");
    }

    # A common error on platforms which don't support dynamic loading.
    # Since it's fatal and potentially confusing we give a detailed message.
    croak("Can't load module $module, dynamic loading not available in this perl.\n".
	"  (You may need to build a new perl executable which either supports\n".
	"  dynamic loading or has the $module module statically linked into it.)\n")
	unless defined(&dl_load_file);


    
    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];

    # Some systems have restrictions on files names for DLL's etc.
    # mod2fname returns appropriate file base name (typically truncated)
    # It may also edit @modparts if required.
    $modfname = &mod2fname(\@modparts) if defined &mod2fname;

    

    my $modpname = join('/',@modparts);

    print STDERR "DynaLoader::bootstrap for $module ",
		       "(auto/$modpname/$modfname.$dl_dlext)\n"
	if $dl_debug;

    foreach (@INC) {
	
	
	    my $dir = "$_/auto/$modpname";
	
	
	next unless -d $dir; # skip over uninteresting directories
	
	# check for common cases to avoid autoload of dl_findfile
	my $try =  "$dir/$modfname.$dl_dlext";
	last if $file = ($do_expand) ? dl_expandspec($try) : ((-f $try) && $try);
	
	# no luck here, save dir for possible later dl_findfile search
	push @dirs, $dir;
    }
    # last resort, let dl_findfile have a go in all known locations
    $file = dl_findfile(map("-L$_",@dirs,@INC), $modfname) unless $file;

    croak("Can't locate loadable object for module $module in \@INC (\@INC contains: @INC)")
	unless $file;	# wording similar to error from 'require'

    
    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @dl_require_symbols = ($bootname);

    # Execute optional '.bootstrap' perl script for this module.
    # The .bs file can be used to configure @dl_resolve_using etc to
    # match the needs of the individual module on this architecture.
    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/; # look for .bs 'beside' the library
    if (-s $bs) { # only read file if it's not empty
        print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    my $boot_symbol_ref;

    

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $libref = dl_load_file($file, $module->dl_load_flags) or
	croak("Can't load '$file' for module $module: ".dl_error());

    push(@dl_librefs,$libref);  # record loaded object

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
	require Carp;
	Carp::carp("Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol($libref, $bootname) or
         croak("Can't find '$bootname' symbol in $file\n");

    push(@dl_modules, $module); # record loaded module

  boot:
    my $xs = dl_install_xsub("${module}::bootstrap", $boot_symbol_ref, $file);

    # See comment block above

	push(@dl_shared_objects, $file); # record files loaded

    &$xs(@args);
}


#sub _check_file {   # private utility to handle dl_expandspec vs -f tests
#    my($file) = @_;
#    return $file if (!$do_expand && -f $file); # the common case
#    return $file if ( $do_expand && ($file=dl_expandspec($file)));
#    return undef;
#}


# Let autosplit and the autoloader deal with these functions:
__END__


sub dl_findfile {
    # Read ext/DynaLoader/DynaLoader.doc for detailed information.
    # This function does not automatically consider the architecture
    # or the perl library auto directories.
    my (@args) = @_;
    my (@dirs,  $dir);   # which directories to search
    my (@found);         # full paths to real files we have found
    #my $dl_ext= 'so'; # $Config::Config{'dlext'} suffix for perl extensions
    #my $dl_so = 'so'; # $Config::Config{'so'} suffix for shared libraries

    print STDERR "dl_findfile(@args)\n" if $dl_debug;

    # accumulate directories but process files as they appear
    arg: foreach(@args) {
        #  Special fast case: full filepath requires no search
	
	
	
        if (m:/: && -f $_) {
	    push(@found,$_);
	    last arg unless wantarray;
	    next;
	}
	

        # Deal with directories first:
        #  Using a -L prefix is the preferred option (faster and more robust)
        if (m:^-L:) { s/^-L//; push(@dirs, $_); next; }

	
	
        #  Otherwise we try to try to spot directories by a heuristic
        #  (this is a more complicated issue than it first appears)
        if (m:/: && -d $_) {   push(@dirs, $_); next; }

	

        #  Only files should get this far...
        my(@names, $name);    # what filenames to look for
        if (m:-l: ) {          # convert -lname to appropriate library name
            s/-l//;
            push(@names,"lib$_.$dl_so");
            push(@names,"lib$_.a");
        } else {                # Umm, a bare name. Try various alternatives:
            # these should be ordered with the most likely first
            push(@names,"$_.$dl_dlext")    unless m/\.$dl_dlext$/o;
            push(@names,"$_.$dl_so")     unless m/\.$dl_so$/o;
            push(@names,"lib$_.$dl_so")  unless m:/:;
            push(@names,"$_.a")          if !m/\.a$/ and $dlsrc eq "dl_dld.xs";
            push(@names, $_);
        }
	my $dirsep = '/';
	
        foreach $dir (@dirs, @dl_library_path) {
            next unless -d $dir;
	    
            foreach $name (@names) {
		my($file) = "$dir$dirsep$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
		$file = ($do_expand) ? dl_expandspec($file) : (-f $file && $file);
		#$file = _check_file($file);
		if ($file) {
                    push(@found, $file);
                    next arg; # no need to look any further
                }
            }
        }
    }
    if ($dl_debug) {
        foreach(@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n" unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}


sub dl_expandspec {
    my($spec) = @_;
    # Optional function invoked if DynaLoader.pm sets $do_expand.
    # Most systems do not require or use this function.
    # Some systems may implement it in the dl_*.xs file in which case
    # this autoload version will not be called but is harmless.

    # This function is designed to deal with systems which treat some
    # 'filenames' in a special way. For example VMS 'Logical Names'
    # (something like unix environment variables - but different).
    # This function should recognise such names and expand them into
    # full file paths.
    # Must return undef if $spec is invalid or file does not exist.

    my $file = $spec; # default output to input

    
	return undef unless -f $file;
    
    print STDERR "dl_expandspec($spec) => $file\n" if $dl_debug;
    $file;
}

sub dl_find_symbol_anywhere
{
    my $sym = shift;
    my $libref;
    foreach $libref (@dl_librefs) {
	my $symref = dl_find_symbol($libref,$sym);
	return $symref if $symref;
    }
    return undef;
}

#line 772
FILE   7b362c40/Errno.pm  �#line 1 "/usr/lib64/perl5/Errno.pm"
#
# This file is auto-generated. ***ANY*** changes here will be lost
#

package Errno;
our (@EXPORT_OK,%EXPORT_TAGS,@ISA,$VERSION,%errno,$AUTOLOAD);
use Exporter ();
use Config;
use strict;

"$Config{'archname'}-$Config{'osvers'}" eq
"x86_64-linux-thread-multi-2.6.18-402.el5" or
	die "Errno architecture (x86_64-linux-thread-multi-2.6.18-402.el5) does not match executable architecture ($Config{'archname'}-$Config{'osvers'})";

$VERSION = "1.11";
$VERSION = eval $VERSION;
@ISA = qw(Exporter);

@EXPORT_OK = qw(EBADR ENOMSG ENOTSUP ESTRPIPE EADDRINUSE EL3HLT EBADF
	ENOTBLK ENAVAIL ECHRNG ENOTNAM ELNRNG ENOKEY EXDEV EBADE EBADSLT
	ECONNREFUSED ENOSTR ENONET EOVERFLOW EISCONN EFBIG EKEYREVOKED
	ECONNRESET EWOULDBLOCK ELIBMAX EREMOTEIO ERFKILL ENOPKG ELIBSCN
	EDESTADDRREQ ENOTSOCK EIO EMEDIUMTYPE EINPROGRESS ERANGE EAFNOSUPPORT
	EADDRNOTAVAIL EINTR EREMOTE EILSEQ ENOMEM EPIPE ENETUNREACH ENODATA
	EUSERS EOPNOTSUPP EPROTO EISNAM ESPIPE EALREADY ENAMETOOLONG ENOEXEC
	EISDIR EBADRQC EEXIST EDOTDOT ELIBBAD EOWNERDEAD ESRCH EFAULT EXFULL
	EDEADLOCK EAGAIN ENOPROTOOPT ENETDOWN EPROTOTYPE EL2NSYNC ENETRESET
	EUCLEAN EADV EROFS ESHUTDOWN EMULTIHOP EPROTONOSUPPORT ENFILE ENOLCK
	ECONNABORTED ECANCELED EDEADLK ESRMNT ENOLINK ETIME ENOTDIR EINVAL
	ENOTTY ENOANO ELOOP ENOENT EPFNOSUPPORT EBADMSG ENOMEDIUM EL2HLT EDOM
	EBFONT EKEYEXPIRED EMSGSIZE ENOCSI EL3RST ENOSPC EIDRM ENOBUFS ENOSYS
	EHOSTDOWN EBADFD ENOSR ENOTCONN ESTALE EDQUOT EKEYREJECTED EMFILE
	ENOTRECOVERABLE EACCES EBUSY E2BIG EPERM ELIBEXEC ETOOMANYREFS ELIBACC
	ENOTUNIQ ECOMM ERESTART ESOCKTNOSUPPORT EUNATCH ETIMEDOUT ENXIO ENODEV
	ETXTBSY EHWPOISON EMLINK ECHILD EHOSTUNREACH EREMCHG ENOTEMPTY);
	
%EXPORT_TAGS = (
    POSIX => [qw(
	E2BIG EACCES EADDRINUSE EADDRNOTAVAIL EAFNOSUPPORT EAGAIN EALREADY
	EBADF EBUSY ECHILD ECONNABORTED ECONNREFUSED ECONNRESET EDEADLK
	EDESTADDRREQ EDOM EDQUOT EEXIST EFAULT EFBIG EHOSTDOWN EHOSTUNREACH
	EINPROGRESS EINTR EINVAL EIO EISCONN EISDIR ELOOP EMFILE EMLINK
	EMSGSIZE ENAMETOOLONG ENETDOWN ENETRESET ENETUNREACH ENFILE ENOBUFS
	ENODEV ENOENT ENOEXEC ENOLCK ENOMEM ENOPROTOOPT ENOSPC ENOSYS ENOTBLK
	ENOTCONN ENOTDIR ENOTEMPTY ENOTSOCK ENOTTY ENXIO EOPNOTSUPP EPERM
	EPFNOSUPPORT EPIPE EPROTONOSUPPORT EPROTOTYPE ERANGE EREMOTE ERESTART
	EROFS ESHUTDOWN ESOCKTNOSUPPORT ESPIPE ESRCH ESTALE ETIMEDOUT
	ETOOMANYREFS ETXTBSY EUSERS EWOULDBLOCK EXDEV
    )]
);

sub EPERM () { 1 }
sub ENOENT () { 2 }
sub ESRCH () { 3 }
sub EINTR () { 4 }
sub EIO () { 5 }
sub ENXIO () { 6 }
sub E2BIG () { 7 }
sub ENOEXEC () { 8 }
sub EBADF () { 9 }
sub ECHILD () { 10 }
sub EWOULDBLOCK () { 11 }
sub EAGAIN () { 11 }
sub ENOMEM () { 12 }
sub EACCES () { 13 }
sub EFAULT () { 14 }
sub ENOTBLK () { 15 }
sub EBUSY () { 16 }
sub EEXIST () { 17 }
sub EXDEV () { 18 }
sub ENODEV () { 19 }
sub ENOTDIR () { 20 }
sub EISDIR () { 21 }
sub EINVAL () { 22 }
sub ENFILE () { 23 }
sub EMFILE () { 24 }
sub ENOTTY () { 25 }
sub ETXTBSY () { 26 }
sub EFBIG () { 27 }
sub ENOSPC () { 28 }
sub ESPIPE () { 29 }
sub EROFS () { 30 }
sub EMLINK () { 31 }
sub EPIPE () { 32 }
sub EDOM () { 33 }
sub ERANGE () { 34 }
sub EDEADLOCK () { 35 }
sub EDEADLK () { 35 }
sub ENAMETOOLONG () { 36 }
sub ENOLCK () { 37 }
sub ENOSYS () { 38 }
sub ENOTEMPTY () { 39 }
sub ELOOP () { 40 }
sub ENOMSG () { 42 }
sub EIDRM () { 43 }
sub ECHRNG () { 44 }
sub EL2NSYNC () { 45 }
sub EL3HLT () { 46 }
sub EL3RST () { 47 }
sub ELNRNG () { 48 }
sub EUNATCH () { 49 }
sub ENOCSI () { 50 }
sub EL2HLT () { 51 }
sub EBADE () { 52 }
sub EBADR () { 53 }
sub EXFULL () { 54 }
sub ENOANO () { 55 }
sub EBADRQC () { 56 }
sub EBADSLT () { 57 }
sub EBFONT () { 59 }
sub ENOSTR () { 60 }
sub ENODATA () { 61 }
sub ETIME () { 62 }
sub ENOSR () { 63 }
sub ENONET () { 64 }
sub ENOPKG () { 65 }
sub EREMOTE () { 66 }
sub ENOLINK () { 67 }
sub EADV () { 68 }
sub ESRMNT () { 69 }
sub ECOMM () { 70 }
sub EPROTO () { 71 }
sub EMULTIHOP () { 72 }
sub EDOTDOT () { 73 }
sub EBADMSG () { 74 }
sub EOVERFLOW () { 75 }
sub ENOTUNIQ () { 76 }
sub EBADFD () { 77 }
sub EREMCHG () { 78 }
sub ELIBACC () { 79 }
sub ELIBBAD () { 80 }
sub ELIBSCN () { 81 }
sub ELIBMAX () { 82 }
sub ELIBEXEC () { 83 }
sub EILSEQ () { 84 }
sub ERESTART () { 85 }
sub ESTRPIPE () { 86 }
sub EUSERS () { 87 }
sub ENOTSOCK () { 88 }
sub EDESTADDRREQ () { 89 }
sub EMSGSIZE () { 90 }
sub EPROTOTYPE () { 91 }
sub ENOPROTOOPT () { 92 }
sub EPROTONOSUPPORT () { 93 }
sub ESOCKTNOSUPPORT () { 94 }
sub ENOTSUP () { 95 }
sub EOPNOTSUPP () { 95 }
sub EPFNOSUPPORT () { 96 }
sub EAFNOSUPPORT () { 97 }
sub EADDRINUSE () { 98 }
sub EADDRNOTAVAIL () { 99 }
sub ENETDOWN () { 100 }
sub ENETUNREACH () { 101 }
sub ENETRESET () { 102 }
sub ECONNABORTED () { 103 }
sub ECONNRESET () { 104 }
sub ENOBUFS () { 105 }
sub EISCONN () { 106 }
sub ENOTCONN () { 107 }
sub ESHUTDOWN () { 108 }
sub ETOOMANYREFS () { 109 }
sub ETIMEDOUT () { 110 }
sub ECONNREFUSED () { 111 }
sub EHOSTDOWN () { 112 }
sub EHOSTUNREACH () { 113 }
sub EALREADY () { 114 }
sub EINPROGRESS () { 115 }
sub ESTALE () { 116 }
sub EUCLEAN () { 117 }
sub ENOTNAM () { 118 }
sub ENAVAIL () { 119 }
sub EISNAM () { 120 }
sub EREMOTEIO () { 121 }
sub EDQUOT () { 122 }
sub ENOMEDIUM () { 123 }
sub EMEDIUMTYPE () { 124 }
sub ECANCELED () { 125 }
sub ENOKEY () { 126 }
sub EKEYEXPIRED () { 127 }
sub EKEYREVOKED () { 128 }
sub EKEYREJECTED () { 129 }
sub EOWNERDEAD () { 130 }
sub ENOTRECOVERABLE () { 131 }
sub ERFKILL () { 132 }
sub EHWPOISON () { 133 }

sub TIEHASH { bless [] }

sub FETCH {
    my ($self, $errname) = @_;
    my $proto = prototype("Errno::$errname");
    my $errno = "";
    if (defined($proto) && $proto eq "") {
	no strict 'refs';
	$errno = &$errname;
        $errno = 0 unless $! == $errno;
    }
    return $errno;
}

sub STORE {
    require Carp;
    Carp::confess("ERRNO hash is read only!");
}

*CLEAR = \&STORE;
*DELETE = \&STORE;

sub NEXTKEY {
    my($k,$v);
    while(($k,$v) = each %Errno::) {
	my $proto = prototype("Errno::$k");
	last if (defined($proto) && $proto eq "");
    }
    $k
}

sub FIRSTKEY {
    my $s = scalar keys %Errno::;	# initialize iterator
    goto &NEXTKEY;
}

sub EXISTS {
    my ($self, $errname) = @_;
    my $r = ref $errname;
    my $proto = !$r || $r eq 'CODE' ? prototype($errname) : undef;
    defined($proto) && $proto eq "";
}

tie %!, __PACKAGE__;

1;
__END__

#line 287

FILE   406e80e3/Fcntl.pm  #line 1 "/usr/lib64/perl5/Fcntl.pm"
package Fcntl;

#line 57

use strict;
our($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS, $AUTOLOAD);

require Exporter;
use XSLoader ();
@ISA = qw(Exporter);
BEGIN {
  $VERSION = "1.06";
}

# Items to export into callers namespace by default
# (move infrequently used names to @EXPORT_OK below)
@EXPORT =
  qw(
	FD_CLOEXEC
	F_ALLOCSP
	F_ALLOCSP64
	F_COMPAT
	F_DUP2FD
	F_DUPFD
	F_EXLCK
	F_FREESP
	F_FREESP64
	F_FSYNC
	F_FSYNC64
	F_GETFD
	F_GETFL
	F_GETLK
	F_GETLK64
	F_GETOWN
	F_NODNY
	F_POSIX
	F_RDACC
	F_RDDNY
	F_RDLCK
	F_RWACC
	F_RWDNY
	F_SETFD
	F_SETFL
	F_SETLK
	F_SETLK64
	F_SETLKW
	F_SETLKW64
	F_SETOWN
	F_SHARE
	F_SHLCK
	F_UNLCK
	F_UNSHARE
	F_WRACC
	F_WRDNY
	F_WRLCK
	O_ACCMODE
	O_ALIAS
	O_APPEND
	O_ASYNC
	O_BINARY
	O_CREAT
	O_DEFER
	O_DIRECT
	O_DIRECTORY
	O_DSYNC
	O_EXCL
	O_EXLOCK
	O_LARGEFILE
	O_NDELAY
	O_NOCTTY
	O_NOFOLLOW
	O_NOINHERIT
	O_NONBLOCK
	O_RANDOM
	O_RAW
	O_RDONLY
	O_RDWR
	O_RSRC
	O_RSYNC
	O_SEQUENTIAL
	O_SHLOCK
	O_SYNC
	O_TEMPORARY
	O_TEXT
	O_TRUNC
	O_WRONLY
     );

# Other items we are prepared to export if requested
@EXPORT_OK = qw(
	DN_ACCESS
	DN_ATTRIB
	DN_CREATE
	DN_DELETE
	DN_MODIFY
	DN_MULTISHOT
	DN_RENAME
	FAPPEND
	FASYNC
	FCREAT
	FDEFER
	FDSYNC
	FEXCL
	FLARGEFILE
	FNDELAY
	FNONBLOCK
	FRSYNC
	FSYNC
	FTRUNC
	F_GETLEASE
	F_GETSIG
	F_NOTIFY
	F_SETLEASE
	F_SETSIG
	LOCK_EX
	LOCK_MAND
	LOCK_NB
	LOCK_READ
	LOCK_RW
	LOCK_SH
	LOCK_UN
	LOCK_WRITE
	O_IGNORE_CTTY
	O_NOATIME
	O_NOLINK
	O_NOTRANS
	SEEK_CUR
	SEEK_END
	SEEK_SET
	S_IFSOCK S_IFBLK S_IFCHR S_IFIFO S_IFWHT S_ENFMT
	S_IREAD S_IWRITE S_IEXEC
	S_IRGRP S_IWGRP S_IXGRP S_IRWXG
	S_IROTH S_IWOTH S_IXOTH S_IRWXO
	S_IRUSR S_IWUSR S_IXUSR S_IRWXU
	S_ISUID S_ISGID S_ISVTX S_ISTXT
	_S_IFMT S_IFREG S_IFDIR S_IFLNK
	&S_ISREG &S_ISDIR &S_ISLNK &S_ISSOCK &S_ISBLK &S_ISCHR &S_ISFIFO
	&S_ISWHT &S_ISENFMT &S_IFMT &S_IMODE
);
# Named groups of exports
%EXPORT_TAGS = (
    'flock'   => [qw(LOCK_SH LOCK_EX LOCK_NB LOCK_UN)],
    'Fcompat' => [qw(FAPPEND FASYNC FCREAT FDEFER FDSYNC FEXCL FLARGEFILE
		     FNDELAY FNONBLOCK FRSYNC FSYNC FTRUNC)],
    'seek'    => [qw(SEEK_SET SEEK_CUR SEEK_END)],
    'mode'    => [qw(S_ISUID S_ISGID S_ISVTX S_ISTXT
		     _S_IFMT S_IFREG S_IFDIR S_IFLNK
		     S_IFSOCK S_IFBLK S_IFCHR S_IFIFO S_IFWHT S_ENFMT
		     S_IRUSR S_IWUSR S_IXUSR S_IRWXU
		     S_IRGRP S_IWGRP S_IXGRP S_IRWXG
		     S_IROTH S_IWOTH S_IXOTH S_IRWXO
		     S_IREAD S_IWRITE S_IEXEC
		     S_ISREG S_ISDIR S_ISLNK S_ISSOCK
		     S_ISBLK S_ISCHR S_ISFIFO
		     S_ISWHT S_ISENFMT		
		     S_IFMT S_IMODE
                  )],
);

# Force the constants to become inlined
BEGIN {
  XSLoader::load 'Fcntl', $VERSION;
}

sub S_IFMT  { @_ ? ( $_[0] & _S_IFMT() ) : _S_IFMT()  }
sub S_IMODE { $_[0] & 07777 }

sub S_ISREG    { ( $_[0] & _S_IFMT() ) == S_IFREG()   }
sub S_ISDIR    { ( $_[0] & _S_IFMT() ) == S_IFDIR()   }
sub S_ISLNK    { ( $_[0] & _S_IFMT() ) == S_IFLNK()   }
sub S_ISSOCK   { ( $_[0] & _S_IFMT() ) == S_IFSOCK()  }
sub S_ISBLK    { ( $_[0] & _S_IFMT() ) == S_IFBLK()   }
sub S_ISCHR    { ( $_[0] & _S_IFMT() ) == S_IFCHR()   }
sub S_ISFIFO   { ( $_[0] & _S_IFMT() ) == S_IFIFO()   }
sub S_ISWHT    { ( $_[0] & _S_IFMT() ) == S_IFWHT()   }
sub S_ISENFMT  { ( $_[0] & _S_IFMT() ) == S_IFENFMT() }

sub AUTOLOAD {
    (my $constname = $AUTOLOAD) =~ s/.*:://;
    die "&Fcntl::constant not defined" if $constname eq 'constant';
    my ($error, $val) = constant($constname);
    if ($error) {
        my (undef,$file,$line) = caller;
        die "$error at $file line $line.\n";
    }
    no strict 'refs';
    *$AUTOLOAD = sub { $val };
    goto &$AUTOLOAD;
}

1;
FILE   29c6386e/File/Glob.pm  "#line 1 "/usr/lib64/perl5/File/Glob.pm"
package File::Glob;

use strict;
our($VERSION, @ISA, @EXPORT_OK, @EXPORT_FAIL, %EXPORT_TAGS,
    $AUTOLOAD, $DEFAULT_FLAGS);

use XSLoader ();

@ISA = qw(Exporter);

# NOTE: The glob() export is only here for compatibility with 5.6.0.
# csh_glob() should not be used directly, unless you know what you're doing.

@EXPORT_OK   = qw(
    csh_glob
    bsd_glob
    glob
    GLOB_ABEND
    GLOB_ALPHASORT
    GLOB_ALTDIRFUNC
    GLOB_BRACE
    GLOB_CSH
    GLOB_ERR
    GLOB_ERROR
    GLOB_LIMIT
    GLOB_MARK
    GLOB_NOCASE
    GLOB_NOCHECK
    GLOB_NOMAGIC
    GLOB_NOSORT
    GLOB_NOSPACE
    GLOB_QUOTE
    GLOB_TILDE
);

%EXPORT_TAGS = (
    'glob' => [ qw(
        GLOB_ABEND
	GLOB_ALPHASORT
        GLOB_ALTDIRFUNC
        GLOB_BRACE
        GLOB_CSH
        GLOB_ERR
        GLOB_ERROR
        GLOB_LIMIT
        GLOB_MARK
        GLOB_NOCASE
        GLOB_NOCHECK
        GLOB_NOMAGIC
        GLOB_NOSORT
        GLOB_NOSPACE
        GLOB_QUOTE
        GLOB_TILDE
        glob
        bsd_glob
    ) ],
);

$VERSION = '1.06';

sub import {
    require Exporter;
    my $i = 1;
    while ($i < @_) {
	if ($_[$i] =~ /^:(case|nocase|globally)$/) {
	    splice(@_, $i, 1);
	    $DEFAULT_FLAGS &= ~GLOB_NOCASE() if $1 eq 'case';
	    $DEFAULT_FLAGS |= GLOB_NOCASE() if $1 eq 'nocase';
	    if ($1 eq 'globally') {
		local $^W;
		*CORE::GLOBAL::glob = \&File::Glob::csh_glob;
	    }
	    next;
	}
	++$i;
    }
    goto &Exporter::import;
}

sub AUTOLOAD {
    # This AUTOLOAD is used to 'autoload' constants from the constant()
    # XS function.  If a constant is not found then control is passed
    # to the AUTOLOAD in AutoLoader.

    my $constname;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    my ($error, $val) = constant($constname);
    if ($error) {
	require Carp;
	Carp::croak($error);
    }
    eval "sub $AUTOLOAD { $val }";
    goto &$AUTOLOAD;
}

XSLoader::load 'File::Glob', $VERSION;

# Preloaded methods go here.

sub GLOB_ERROR {
    return (constant('GLOB_ERROR'))[1];
}

sub GLOB_CSH () {
    GLOB_BRACE()
	| GLOB_NOMAGIC()
	| GLOB_QUOTE()
	| GLOB_TILDE()
	| GLOB_ALPHASORT()
}

$DEFAULT_FLAGS = GLOB_CSH();
if ($^O =~ /^(?:MSWin32|VMS|os2|dos|riscos|MacOS)$/) {
    $DEFAULT_FLAGS |= GLOB_NOCASE();
}

# Autoload methods go after =cut, and are processed by the autosplit program.

sub bsd_glob {
    my ($pat,$flags) = @_;
    $flags = $DEFAULT_FLAGS if @_ < 2;
    return doglob($pat,$flags);
}

# File::Glob::glob() is deprecated because its prototype is different from
# CORE::glob() (use bsd_glob() instead)
sub glob {
    splice @_, 1; # don't pass PL_glob_index as flags!
    goto &bsd_glob;
}

## borrowed heavily from gsar's File::DosGlob
my %iter;
my %entries;

sub csh_glob {
    my $pat = shift;
    my $cxix = shift;
    my @pat;

    # glob without args defaults to $_
    $pat = $_ unless defined $pat;

    # extract patterns
    $pat =~ s/^\s+//;	# Protect against empty elements in
    $pat =~ s/\s+$//;	# things like < *.c> and <*.c >.
			# These alone shouldn't trigger ParseWords.
    if ($pat =~ /\s/) {
        # XXX this is needed for compatibility with the csh
	# implementation in Perl.  Need to support a flag
	# to disable this behavior.
	require Text::ParseWords;
	@pat = Text::ParseWords::parse_line('\s+',0,$pat);
    }

    # assume global context if not provided one
    $cxix = '_G_' unless defined $cxix;
    $iter{$cxix} = 0 unless exists $iter{$cxix};

    # if we're just beginning, do it all first
    if ($iter{$cxix} == 0) {
	if (@pat) {
	    $entries{$cxix} = [ map { doglob($_, $DEFAULT_FLAGS) } @pat ];
	}
	else {
	    $entries{$cxix} = [ doglob($pat, $DEFAULT_FLAGS) ];
	}
    }

    # chuck it all out, quick or slow
    if (wantarray) {
        delete $iter{$cxix};
        return @{delete $entries{$cxix}};
    }
    else {
        if ($iter{$cxix} = scalar @{$entries{$cxix}}) {
            return shift @{$entries{$cxix}};
        }
        else {
            # return undef for EOL
            delete $iter{$cxix};
            delete $entries{$cxix};
            return undef;
        }
    }
}

1;
__END__

#line 497
FILE   dfc76248/File/GlobMapper.pm  �#line 1 "/usr/lib64/perl5/File/GlobMapper.pm"
package File::GlobMapper;

use strict;
use warnings;
use Carp;

our ($CSH_GLOB);

BEGIN
{
    if ($] < 5.006)
    { 
        require File::BSDGlob; import File::BSDGlob qw(:glob) ;
        $CSH_GLOB = File::BSDGlob::GLOB_CSH() ;
        *globber = \&File::BSDGlob::csh_glob;
    }  
    else
    { 
        require File::Glob; import File::Glob qw(:glob) ;
        $CSH_GLOB = File::Glob::GLOB_CSH() ;
        #*globber = \&File::Glob::bsd_glob;
        *globber = \&File::Glob::csh_glob;
    }  
}

our ($Error);

our ($VERSION, @EXPORT_OK);
$VERSION = '1.000';
@EXPORT_OK = qw( globmap );


our ($noPreBS, $metachars, $matchMetaRE, %mapping, %wildCount);
$noPreBS = '(?<!\\\)' ; # no preceeding backslash
$metachars = '.*?[](){}';
$matchMetaRE = '[' . quotemeta($metachars) . ']';

%mapping = (
                '*' => '([^/]*)',
                '?' => '([^/])',
                '.' => '\.',
                '[' => '([',
                '(' => '(',
                ')' => ')',
           );

%wildCount = map { $_ => 1 } qw/ * ? . { ( [ /;           

sub globmap ($$;)
{
    my $inputGlob = shift ;
    my $outputGlob = shift ;

    my $obj = new File::GlobMapper($inputGlob, $outputGlob, @_)
        or croak "globmap: $Error" ;
    return $obj->getFileMap();
}

sub new
{
    my $class = shift ;
    my $inputGlob = shift ;
    my $outputGlob = shift ;
    # TODO -- flags needs to default to whatever File::Glob does
    my $flags = shift || $CSH_GLOB ;
    #my $flags = shift ;

    $inputGlob =~ s/^\s*\<\s*//;
    $inputGlob =~ s/\s*\>\s*$//;

    $outputGlob =~ s/^\s*\<\s*//;
    $outputGlob =~ s/\s*\>\s*$//;

    my %object =
            (   InputGlob   => $inputGlob,
                OutputGlob  => $outputGlob,
                GlobFlags   => $flags,
                Braces      => 0,
                WildCount   => 0,
                Pairs       => [],
                Sigil       => '#',
            );

    my $self = bless \%object, ref($class) || $class ;

    $self->_parseInputGlob()
        or return undef ;

    $self->_parseOutputGlob()
        or return undef ;
    
    my @inputFiles = globber($self->{InputGlob}, $flags) ;

    if (GLOB_ERROR)
    {
        $Error = $!;
        return undef ;
    }

    #if (whatever)
    {
        my $missing = grep { ! -e $_ } @inputFiles ;

        if ($missing)
        {
            $Error = "$missing input files do not exist";
            return undef ;
        }
    }

    $self->{InputFiles} = \@inputFiles ;

    $self->_getFiles()
        or return undef ;

    return $self;
}

sub _retError
{
    my $string = shift ;
    $Error = "$string in input fileglob" ;
    return undef ;
}

sub _unmatched
{
    my $delimeter = shift ;

    _retError("Unmatched $delimeter");
    return undef ;
}

sub _parseBit
{
    my $self = shift ;

    my $string = shift ;

    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS(,|$matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};

        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq ',')
        { 
            return _unmatched "("
                if $depth ;
            
            $out .= '|';
        }
        elsif ($2 eq '(')
        { 
            ++ $depth ;
        }
        elsif ($2 eq ')')
        { 
            return _unmatched ")"
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched "[" ;
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched "]" ;
        }
        elsif ($2 eq '{' || $2 eq '}')
        {
            return _retError "Nested {} not allowed" ;
        }
    }

    $out .= quotemeta $string;

    return _unmatched "("
        if $depth ;

    return $out ;
}

sub _parseInputGlob
{
    my $self = shift ;

    my $string = $self->{InputGlob} ;
    my $inGlob = '';

    # Multiple concatenated *'s don't make sense
    #$string =~ s#\*\*+#*# ;

    # TODO -- Allow space to delimit patterns?
    #my @strings = split /\s+/, $string ;
    #for my $str (@strings)
    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS($matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};
        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq '(')
        { 
            ++ $depth ;
        }
        elsif ($2 eq ')')
        { 
            return _unmatched ")"
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/' or '(' or ')'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched "[";
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched "]" ;
        }
        elsif ($2 eq '}')
        {
            return _unmatched "}" ;
        }
        elsif ($2 eq '{')
        {
            # TODO -- check no '/' within the {}
            # TODO -- check for \}  & other \ within the {}

            my $tmp ;
            unless ( $string =~ s/(.*?)$noPreBS\}//)
            {
                return _unmatched "{";
            }
            #$string =~ s#(.*?)\}##;

            #my $alt = join '|', 
            #          map { quotemeta $_ } 
            #          split "$noPreBS,", $1 ;
            my $alt = $self->_parseBit($1);
            defined $alt or return 0 ;
            $out .= "($alt)" ;

            ++ $self->{Braces} ;
        }
    }

    return _unmatched "("
        if $depth ;

    $out .= quotemeta $string ;


    $self->{InputGlob} =~ s/$noPreBS[\(\)]//g;
    $self->{InputPattern} = $out ;

    #print "# INPUT '$self->{InputGlob}' => '$out'\n";

    return 1 ;

}

sub _parseOutputGlob
{
    my $self = shift ;

    my $string = $self->{OutputGlob} ;
    my $maxwild = $self->{WildCount};

    if ($self->{GlobFlags} & GLOB_TILDE)
    #if (1)
    {
        $string =~ s{
              ^ ~             # find a leading tilde
              (               # save this in $1
                  [^/]        # a non-slash character
                        *     # repeated 0 or more times (0 means me)
              )
            }{
              $1
                  ? (getpwnam($1))[7]
                  : ( $ENV{HOME} || $ENV{LOGDIR} )
            }ex;

    }

    # max #1 must be == to max no of '*' in input
    while ( $string =~ m/#(\d)/g )
    {
        croak "Max wild is #$maxwild, you tried #$1"
            if $1 > $maxwild ;
    }

    my $noPreBS = '(?<!\\\)' ; # no preceeding backslash
    #warn "noPreBS = '$noPreBS'\n";

    #$string =~ s/${noPreBS}\$(\d)/\${$1}/g;
    $string =~ s/${noPreBS}#(\d)/\${$1}/g;
    $string =~ s#${noPreBS}\*#\${inFile}#g;
    $string = '"' . $string . '"';

    #print "OUTPUT '$self->{OutputGlob}' => '$string'\n";
    $self->{OutputPattern} = $string ;

    return 1 ;
}

sub _getFiles
{
    my $self = shift ;

    my %outInMapping = ();
    my %inFiles = () ;

    foreach my $inFile (@{ $self->{InputFiles} })
    {
        next if $inFiles{$inFile} ++ ;

        my $outFile = $inFile ;

        if ( $inFile =~ m/$self->{InputPattern}/ )
        {
            no warnings 'uninitialized';
            eval "\$outFile = $self->{OutputPattern};" ;

            if (defined $outInMapping{$outFile})
            {
                $Error =  "multiple input files map to one output file";
                return undef ;
            }
            $outInMapping{$outFile} = $inFile;
            push @{ $self->{Pairs} }, [$inFile, $outFile];
        }
    }

    return 1 ;
}

sub getFileMap
{
    my $self = shift ;

    return $self->{Pairs} ;
}

sub getHash
{
    my $self = shift ;

    return { map { $_->[0] => $_->[1] } @{ $self->{Pairs} } } ;
}

1;

__END__

#line 680FILE   82fd8b99/IO.pm  �#line 1 "/usr/lib64/perl5/IO.pm"
#

package IO;

use XSLoader ();
use Carp;
use strict;
use warnings;

our $VERSION = "1.25";
XSLoader::load 'IO', $VERSION;

sub import {
    shift;

    warnings::warnif('deprecated', qq{Parameterless "use IO" deprecated})
        if @_ == 0 ;
    
    my @l = @_ ? @_ : qw(Handle Seekable File Pipe Socket Dir);

    eval join("", map { "require IO::" . (/(\w+)/)[0] . ";\n" } @l)
	or croak $@;
}

1;

__END__

#line 68

FILE   '6168e7d0/IO/Compress/Adapter/Deflate.pm  7#line 1 "/usr/lib64/perl5/IO/Compress/Adapter/Deflate.pm"
package IO::Compress::Adapter::Deflate ;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common  2.021 qw(:Status);

use Compress::Raw::Zlib  2.021 qw(Z_OK Z_FINISH MAX_WBITS) ;
our ($VERSION);

$VERSION = '2.021';

sub mkCompObject
{
    my $crc32    = shift ;
    my $adler32  = shift ;
    my $level    = shift ;
    my $strategy = shift ;

    my ($def, $status) = new Compress::Raw::Zlib::Deflate
                                -AppendOutput   => 1,
                                -CRC32          => $crc32,
                                -ADLER32        => $adler32,
                                -Level          => $level,
                                -Strategy       => $strategy,
                                -WindowBits     => - MAX_WBITS;

    return (undef, "Cannot create Deflate object: $status", $status) 
        if $status != Z_OK;    

    return bless {'Def'        => $def,
                  'Error'      => '',
                 } ;     
}

sub compr
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflate($_[0], $_[1]) ;
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub flush
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $opt = $_[1] || Z_FINISH;
    my $status = $def->flush($_[0], $opt);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
    
}

sub close
{
    my $self = shift ;

    my $def   = $self->{Def};

    $def->flush($_[0], Z_FINISH)
        if defined $def ;
}

sub reset
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateReset() ;
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub deflateParams 
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateParams(@_);
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "deflateParams Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;   
}



#sub total_out
#{
#    my $self = shift ;
#    $self->{Def}->total_out();
#}
#
#sub total_in
#{
#    my $self = shift ;
#    $self->{Def}->total_in();
#}

sub compressedBytes
{
    my $self = shift ;

    $self->{Def}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Def}->uncompressedBytes();
}




sub crc32
{
    my $self = shift ;
    $self->{Def}->crc32();
}

sub adler32
{
    my $self = shift ;
    $self->{Def}->adler32();
}


1;

__END__

FILE   71249032/IO/Compress/Base.pm  Q?#line 1 "/usr/lib64/perl5/IO/Compress/Base.pm"

package IO::Compress::Base ;

require 5.004 ;

use strict ;
use warnings;

use IO::Compress::Base::Common 2.021 ;

use IO::File ;
use Scalar::Util qw(blessed readonly);

#use File::Glob;
#require Exporter ;
use Carp ;
use Symbol;
use bytes;

our (@ISA, $VERSION);
@ISA    = qw(Exporter IO::File);

$VERSION = '2.021';

#Can't locate object method "SWASHNEW" via package "utf8" (perhaps you forgot to load "utf8"?) at .../ext/Compress-Zlib/Gzip/blib/lib/Compress/Zlib/Common.pm line 16.

sub saveStatus
{
    my $self   = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 ;
    ${ *$self->{Error} } = '' ;

    return ${ *$self->{ErrorNo} } ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;
    ${ *$self->{Error} } = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 if @_ ;

    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    croak $_[0];
}

sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}



sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return ${ *$self->{ErrorNo} } ;
}


sub writeAt
{
    my $self = shift ;
    my $offset = shift;
    my $data = shift;

    if (defined *$self->{FH}) {
        my $here = tell(*$self->{FH});
        return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) 
            if $here < 0 ;
        seek(*$self->{FH}, $offset, SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
        defined *$self->{FH}->write($data, length $data)
            or return $self->saveErrorString(undef, $!, $!) ;
        seek(*$self->{FH}, $here, SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
    }
    else {
        substr(${ *$self->{Buffer} }, $offset, length($data)) = $data ;
    }

    return 1;
}

sub output
{
    my $self = shift ;
    my $data = shift ;
    my $last = shift ;

    return 1 
        if length $data == 0 && ! $last ;

    if ( *$self->{FilterEnvelope} ) {
        *_ = \$data;
        &{ *$self->{FilterEnvelope} }();
    }

    if (length $data) {
        if ( defined *$self->{FH} ) {
                defined *$self->{FH}->write( $data, length $data )
                or return $self->saveErrorString(0, $!, $!); 
        }
        else {
                ${ *$self->{Buffer} } .= $data ;
        }
    }

    return 1;
}

sub getOneShotParams
{
    return ( 'MultiStream' => [1, 1, Parse_boolean,   1],
           );
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();

    $got->parse(
        {
            # Generic Parameters
            'AutoClose' => [1, 1, Parse_boolean,   0],
            #'Encode'    => [1, 1, Parse_any,       undef],
            'Strict'    => [0, 1, Parse_boolean,   1],
            'Append'    => [1, 1, Parse_boolean,   0],
            'BinModeIn' => [1, 1, Parse_boolean,   0],

            'FilterEnvelope' => [1, 1, Parse_any,   undef],

            $self->getExtraParams(),
            *$self->{OneShot} ? $self->getOneShotParams() 
                              : (),
        }, 
        @_) or $self->croakError("${class}: $got->{Error}")  ;

    return $got ;
}

sub _create
{
    my $obj = shift;
    my $got = shift;

    *$obj->{Closed} = 1 ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Output parameter")
        if ! @_ && ! $got ;

    my $outValue = shift ;
    my $oneShot = 1 ;

    if (! $got)
    {
        $oneShot = 0 ;
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $lax = ! $got->value('Strict') ;

    my $outType = whatIsOutput($outValue);

    $obj->ckOutputParam($class, $outValue)
        or return undef ;

    if ($outType eq 'buffer') {
        *$obj->{Buffer} = $outValue;
    }
    else {
        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    # Merge implies Append
    my $merge = $got->value('Merge') ;
    my $appendOutput = $got->value('Append') || $merge ;
    *$obj->{Append} = $appendOutput;
    *$obj->{FilterEnvelope} = $got->value('FilterEnvelope') ;

    if ($merge)
    {
        # Switch off Merge mode if output file/buffer is empty/doesn't exist
        if (($outType eq 'buffer' && length $$outValue == 0 ) ||
            ($outType ne 'buffer' && (! -e $outValue || (-w _ && -z _))) )
          { $merge = 0 }
    }

    # If output is a file, check that it is writable
    #no warnings;
    #if ($outType eq 'filename' && -e $outValue && ! -w _)
    #  { return $obj->saveErrorString(undef, "Output file '$outValue' is not writable" ) }



    if ($got->parsed('Encode')) { 
        my $want_encoding = $got->value('Encode');
        *$obj->{Encoding} = getEncoding($obj, $class, $want_encoding);
    }

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . $obj->error());


    $obj->saveStatus(STATUS_OK) ;

    my $status ;
    if (! $merge)
    {
        *$obj->{Compress} = $obj->mkComp($got)
            or return undef;
        
        *$obj->{UnCompSize} = new U64 ;
        *$obj->{CompSize} = new U64 ;

        if ( $outType eq 'buffer') {
            ${ *$obj->{Buffer} }  = ''
                unless $appendOutput ;
        }
        else {
            if ($outType eq 'handle') {
                *$obj->{FH} = $outValue ;
                setBinModeOutput(*$obj->{FH}) ;
                $outValue->flush() ;
                *$obj->{Handle} = 1 ;
                if ($appendOutput)
                {
                    seek(*$obj->{FH}, 0, SEEK_END)
                        or return $obj->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;

                }
            }
            elsif ($outType eq 'filename') {    
                no warnings;
                my $mode = '>' ;
                $mode = '>>'
                    if $appendOutput;
                *$obj->{FH} = new IO::File "$mode $outValue" 
                    or return $obj->saveErrorString(undef, "cannot open file '$outValue': $!", $!) ;
                *$obj->{StdIO} = ($outValue eq '-'); 
                setBinModeOutput(*$obj->{FH}) ;
            }
        }

        *$obj->{Header} = $obj->mkHeader($got) ;
        $obj->output( *$obj->{Header} )
            or return undef;
    }
    else
    {
        *$obj->{Compress} = $obj->createMerge($outValue, $outType)
            or return undef;
    }

    *$obj->{Closed} = 0 ;
    *$obj->{AutoClose} = $got->value('AutoClose') ;
    *$obj->{Output} = $outValue;
    *$obj->{ClassName} = $class;
    *$obj->{Got} = $got;
    *$obj->{OneShot} = 0 ;

    return $obj ;
}

sub ckOutputParam 
{
    my $self = shift ;
    my $from = shift ;
    my $outType = whatIsOutput($_[0]);

    $self->croakError("$from: output parameter not a filename, filehandle or scalar ref")
        if ! $outType ;

    #$self->croakError("$from: output filename is undef or null string")
        #if $outType eq 'filename' && (! defined $_[0] || $_[0] eq '')  ;

    $self->croakError("$from: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[0] });
    
    return 1;    
}


sub _def
{
    my $obj = shift ;
    
    my $class= (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;

    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;

    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;

    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, 1, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }

    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, 1, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $inFile, $in, \$out, @_)
                or return undef ;

            push @$output, \$out ;
            #if ($x->{outType} eq 'array')
            #  { push @$output, \$out }
            #else
            #  { $output->{$in} = \$out }
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, 1, $input, $output, @_);

    croak "should not be here" ;
}

sub _singleTarget
{
    my $obj             = shift ;
    my $x               = shift ;
    my $inputIsFilename = shift;
    my $input           = shift;
    
    if ($x->{oneInput})
    {
        $obj->getFileInfo($x->{Got}, $input)
            if isaFilename($input) and $inputIsFilename ;

        my $z = $obj->_create($x->{Got}, @_)
            or return undef ;


        defined $z->_wr2($input, $inputIsFilename) 
            or return $z->closeError(undef) ;

        return $z->close() ;
    }
    else
    {
        my $afterFirst = 0 ;
        my $inputIsFilename = ($x->{inType} ne 'array');
        my $keep = $x->{Got}->clone();

        #for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        for my $element ( @$input)
        {
            my $isFilename = isaFilename($element);

            if ( $afterFirst ++ )
            {
                defined addInterStream($obj, $element, $isFilename)
                    or return $obj->closeError(undef) ;
            }
            else
            {
                $obj->getFileInfo($x->{Got}, $element)
                    if $isFilename;

                $obj->_create($x->{Got}, @_)
                    or return undef ;
            }

            defined $obj->_wr2($element, $isFilename) 
                or return $obj->closeError(undef) ;

            *$obj->{Got} = $keep->clone();
        }
        return $obj->close() ;
    }

}

sub _wr2
{
    my $self = shift ;

    my $source = shift ;
    my $inputIsFilename = shift;

    my $input = $source ;
    if (! $inputIsFilename)
    {
        $input = \$source 
            if ! ref $source;
    }

    if ( ref $input && ref $input eq 'SCALAR' )
    {
        return $self->syswrite($input, @_) ;
    }

    if ( ! ref $input  || isaFilehandle($input))
    {
        my $isFilehandle = isaFilehandle($input) ;

        my $fh = $input ;

        if ( ! $isFilehandle )
        {
            $fh = new IO::File "<$input"
                or return $self->saveErrorString(undef, "cannot open file '$input': $!", $!) ;
        }
        binmode $fh if *$self->{Got}->valueOrDefault('BinModeIn') ;

        my $status ;
        my $buff ;
        my $count = 0 ;
        while ($status = read($fh, $buff, 16 * 1024)) {
            $count += length $buff;
            defined $self->syswrite($buff, @_) 
                or return undef ;
        }

        return $self->saveErrorString(undef, $!, $!) 
            if ! defined $status ;

        if ( (!$isFilehandle || *$self->{AutoClose}) && $input ne '-')
        {    
            $fh->close() 
                or return undef ;
        }

        return $count ;
    }

    croak "Should not be here";
    return undef;
}

sub addInterStream
{
    my $self = shift ;
    my $input = shift ;
    my $inputIsFilename = shift ;

    if (*$self->{Got}->value('MultiStream'))
    {
        $self->getFileInfo(*$self->{Got}, $input)
            #if isaFilename($input) and $inputIsFilename ;
            if isaFilename($input) ;

        # TODO -- newStream needs to allow gzip/zip header to be modified
        return $self->newStream();
    }
    elsif (*$self->{Got}->value('AutoFlush'))
    {
        #return $self->flush(Z_FULL_FLUSH);
    }

    return 1 ;
}

sub getFileInfo
{
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;
}
  
sub UNTIE
{
    my $self = shift ;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);
    
    $self->close() ;

    # TODO - memory leak with 5.8.0 - this isn't called until 
    #        global destruction
    #
    %{ *$self } = () ;
    undef $self ;
}



sub filterUncompressed
{
}

sub syswrite
{
    my $self = shift ;

    my $buffer ;
    if (ref $_[0] ) {
        $self->croakError( *$self->{ClassName} . "::write: not a scalar reference" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $buffer = \$_[0] ;
    }

    $] >= 5.008 and ( utf8::downgrade($$buffer, 1) 
        or croak "Wide character in " .  *$self->{ClassName} . "::write:");


    if (@_ > 1) {
        my $slen = defined $$buffer ? length($$buffer) : 0;
        my $len = $slen;
        my $offset = 0;
        $len = $_[1] if $_[1] < $len;

        if (@_ > 2) {
            $offset = $_[2] || 0;
            $self->croakError(*$self->{ClassName} . "::write: offset outside string") 
                if $offset > $slen;
            if ($offset < 0) {
                $offset += $slen;
                $self->croakError( *$self->{ClassName} . "::write: offset outside string") if $offset < 0;
            }
            my $rem = $slen - $offset;
            $len = $rem if $rem < $len;
        }

        $buffer = \substr($$buffer, $offset, $len) ;
    }

    return 0 if ! defined $$buffer || length $$buffer == 0 ;

    if (*$self->{Encoding}) {
        $$buffer = *$self->{Encoding}->encode($$buffer);
    }

    $self->filterUncompressed($buffer);

    my $buffer_length = defined $$buffer ? length($$buffer) : 0 ;
    *$self->{UnCompSize}->add($buffer_length) ;

    my $outBuffer='';
    my $status = *$self->{Compress}->compr($buffer, $outBuffer) ;

    return $self->saveErrorString(undef, *$self->{Compress}{Error}, 
                                         *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->output($outBuffer)
        or return undef;

    return $buffer_length;
}

sub print
{
    my $self = shift;

    #if (ref $self) {
    #    $self = *$self{GLOB} ;
    #}

    if (defined $\) {
        if (defined $,) {
            defined $self->syswrite(join($,, @_) . $\);
        } else {
            defined $self->syswrite(join("", @_) . $\);
        }
    } else {
        if (defined $,) {
            defined $self->syswrite(join($,, @_));
        } else {
            defined $self->syswrite(join("", @_));
        }
    }
}

sub printf
{
    my $self = shift;
    my $fmt = shift;
    defined $self->syswrite(sprintf($fmt, @_));
}



sub flush
{
    my $self = shift ;

    my $outBuffer='';
    my $status = *$self->{Compress}->flush($outBuffer, @_) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, 
                                    *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    if ( defined *$self->{FH} ) {
        *$self->{FH}->clearerr();
    }

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->output($outBuffer)
        or return 0;

    if ( defined *$self->{FH} ) {
        defined *$self->{FH}->flush()
            or return $self->saveErrorString(0, $!, $!); 
    }

    return 1;
}

sub newStream
{
    my $self = shift ;
  
    $self->_writeTrailer()
        or return 0 ;

    my $got = $self->checkParams('newStream', *$self->{Got}, @_)
        or return 0 ;    

    $self->ckParams($got)
        or $self->croakError("newStream: $self->{Error}");

    *$self->{Compress} = $self->mkComp($got)
        or return 0;

    *$self->{Header} = $self->mkHeader($got) ;
    $self->output(*$self->{Header} )
        or return 0;
    
    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    return 1 ;
}

sub reset
{
    my $self = shift ;
    return *$self->{Compress}->reset() ;
}

sub _writeTrailer
{
    my $self = shift ;

    my $trailer = '';

    my $status = *$self->{Compress}->close($trailer) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $trailer) ;

    $trailer .= $self->mkTrailer();
    defined $trailer
      or return 0;

    return $self->output($trailer);
}

sub _writeFinalTrailer
{
    my $self = shift ;

    return $self->output($self->mkFinalTrailer());
}

sub close
{
    my $self = shift ;

    return 1 if *$self->{Closed} || ! *$self->{Compress} ;
    *$self->{Closed} = 1 ;

    untie *$self 
        if $] >= 5.008 ;

    $self->_writeTrailer()
        or return 0 ;

    $self->_writeFinalTrailer()
        or return 0 ;

    $self->output( "", 1 )
        or return 0;

    if (defined *$self->{FH}) {

        #if (! *$self->{Handle} || *$self->{AutoClose}) {
        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
            $! = 0 ;
            *$self->{FH}->close()
                or return $self->saveErrorString(0, $!, $!); 
        }
        delete *$self->{FH} ;
        # This delete can set $! in older Perls, so reset the errno
        $! = 0 ;
    }

    return 1;
}


#sub total_in
#sub total_out
#sub msg
#
#sub crc
#{
#    my $self = shift ;
#    return *$self->{Compress}->crc32() ;
#}
#
#sub msg
#{
#    my $self = shift ;
#    return *$self->{Compress}->msg() ;
#}
#
#sub dict_adler
#{
#    my $self = shift ;
#    return *$self->{Compress}->dict_adler() ;
#}
#
#sub get_Level
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Level() ;
#}
#
#sub get_Strategy
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Strategy() ;
#}


sub tell
{
    my $self = shift ;

    return *$self->{UnCompSize}->get32bit() ;
}

sub eof
{
    my $self = shift ;

    return *$self->{Closed} ;
}


sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;

    #use IO::Handle qw(SEEK_SET SEEK_CUR SEEK_END);
    use IO::Handle ;

    if ($whence == IO::Handle::SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == IO::Handle::SEEK_CUR || $whence == IO::Handle::SEEK_END) {
        $target = $here + $position ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    return 1 if $target == $here ;    

    # Outlaw any attempt to seek backwards
    $self->croakError(*$self->{ClassName} . "::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $buffer ;
    defined $self->syswrite("\x00" x $offset)
        or return 0;

    return 1 ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH} 
#            ? binmode *$self->{FH} 
#            : 1 ;
}

sub fileno
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->fileno() 
            : undef ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->autoflush(@_) 
            : undef ;
}

sub input_line_number
{
    return undef ;
}


sub _notAvailable
{
    my $name = shift ;
    return sub { croak "$name Not Available: File opened only for output" ; } ;
}

*read     = _notAvailable('read');
*READ     = _notAvailable('read');
*readline = _notAvailable('readline');
*READLINE = _notAvailable('readline');
*getc     = _notAvailable('getc');
*GETC     = _notAvailable('getc');

*FILENO   = \&fileno;
*PRINT    = \&print;
*PRINTF   = \&printf;
*WRITE    = \&syswrite;
*write    = \&syswrite;
*SEEK     = \&seek; 
*TELL     = \&tell;
*EOF      = \&eof;
*CLOSE    = \&close;
*BINMODE  = \&binmode;

#*sysread  = \&_notAvailable;
#*syswrite = \&_write;

1; 

__END__

#line 982
FILE   #e7b55129/IO/Compress/Base/Common.pm  T�#line 1 "/usr/lib64/perl5/IO/Compress/Base/Common.pm"
package IO::Compress::Base::Common;

use strict ;
use warnings;
use bytes;

use Carp;
use Scalar::Util qw(blessed readonly);
use File::GlobMapper;

require Exporter;
our ($VERSION, @ISA, @EXPORT, %EXPORT_TAGS, $HAS_ENCODE);
@ISA = qw(Exporter);
$VERSION = '2.021';

@EXPORT = qw( isaFilehandle isaFilename whatIsInput whatIsOutput 
              isaFileGlobString cleanFileGlobString oneTarget
              setBinModeInput setBinModeOutput
              ckInOutParams 
              createSelfTiedObject
              getEncoding

              WANT_CODE
              WANT_EXT
              WANT_UNDEF
              WANT_HASH

              STATUS_OK
              STATUS_ENDSTREAM
              STATUS_EOF
              STATUS_ERROR
          );  

%EXPORT_TAGS = ( Status => [qw( STATUS_OK
                                 STATUS_ENDSTREAM
                                 STATUS_EOF
                                 STATUS_ERROR
                           )]);

                       
use constant STATUS_OK        => 0;
use constant STATUS_ENDSTREAM => 1;
use constant STATUS_EOF       => 2;
use constant STATUS_ERROR     => -1;
          
sub hasEncode()
{
    if (! defined $HAS_ENCODE) {
        eval
        {
            require Encode;
            Encode->import();
        };

        $HAS_ENCODE = $@ ? 0 : 1 ;
    }

    return $HAS_ENCODE;
}

sub getEncoding($$$)
{
    my $obj = shift;
    my $class = shift ;
    my $want_encoding = shift ;

    $obj->croakError("$class: Encode module needed to use -Encode")
        if ! hasEncode();

    my $encoding = Encode::find_encoding($want_encoding);

    $obj->croakError("$class: Encoding '$want_encoding' is not available")
       if ! $encoding;

    return $encoding;
}

our ($needBinmode);
$needBinmode = ($^O eq 'MSWin32' || 
                    ($] >= 5.006 && eval ' ${^UNICODE} || ${^UTF8LOCALE} '))
                    ? 1 : 1 ;

sub setBinModeInput($)
{
    my $handle = shift ;

    binmode $handle 
        if  $needBinmode;
}

sub setBinModeOutput($)
{
    my $handle = shift ;

    binmode $handle 
        if  $needBinmode;
}

sub isaFilehandle($)
{
    use utf8; # Pragma needed to keep Perl 5.6.0 happy
    return (defined $_[0] and 
             (UNIVERSAL::isa($_[0],'GLOB') or 
              UNIVERSAL::isa($_[0],'IO::Handle') or
              UNIVERSAL::isa(\$_[0],'GLOB')) 
          )
}

sub isaFilename($)
{
    return (defined $_[0] and 
           ! ref $_[0]    and 
           UNIVERSAL::isa(\$_[0], 'SCALAR'));
}

sub isaFileGlobString
{
    return defined $_[0] && $_[0] =~ /^<.*>$/;
}

sub cleanFileGlobString
{
    my $string = shift ;

    $string =~ s/^\s*<\s*(.*)\s*>\s*$/$1/;

    return $string;
}

use constant WANT_CODE  => 1 ;
use constant WANT_EXT   => 2 ;
use constant WANT_UNDEF => 4 ;
#use constant WANT_HASH  => 8 ;
use constant WANT_HASH  => 0 ;

sub whatIsInput($;$)
{
    my $got = whatIs(@_);
    
    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        #use IO::File;
        $got = 'handle';
        $_[0] = *STDIN;
        #$_[0] = new IO::File("<-");
    }

    return $got;
}

sub whatIsOutput($;$)
{
    my $got = whatIs(@_);
    
    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        $got = 'handle';
        $_[0] = *STDOUT;
        #$_[0] = new IO::File(">-");
    }
    
    return $got;
}

sub whatIs ($;$)
{
    return 'handle' if isaFilehandle($_[0]);

    my $wantCode = defined $_[1] && $_[1] & WANT_CODE ;
    my $extended = defined $_[1] && $_[1] & WANT_EXT ;
    my $undef    = defined $_[1] && $_[1] & WANT_UNDEF ;
    my $hash     = defined $_[1] && $_[1] & WANT_HASH ;

    return 'undef'  if ! defined $_[0] && $undef ;

    if (ref $_[0]) {
        return ''       if blessed($_[0]); # is an object
        #return ''       if UNIVERSAL::isa($_[0], 'UNIVERSAL'); # is an object
        return 'buffer' if UNIVERSAL::isa($_[0], 'SCALAR');
        return 'array'  if UNIVERSAL::isa($_[0], 'ARRAY')  && $extended ;
        return 'hash'   if UNIVERSAL::isa($_[0], 'HASH')   && $hash ;
        return 'code'   if UNIVERSAL::isa($_[0], 'CODE')   && $wantCode ;
        return '';
    }

    return 'fileglob' if $extended && isaFileGlobString($_[0]);
    return 'filename';
}

sub oneTarget
{
    return $_[0] =~ /^(code|handle|buffer|filename)$/;
}

sub IO::Compress::Base::Validator::new
{
    my $class = shift ;

    my $Class = shift ;
    my $error_ref = shift ;
    my $reportClass = shift ;

    my %data = (Class       => $Class, 
                Error       => $error_ref,
                reportClass => $reportClass, 
               ) ;

    my $obj = bless \%data, $class ;

    local $Carp::CarpLevel = 1;

    my $inType    = $data{inType}    = whatIsInput($_[0], WANT_EXT|WANT_HASH);
    my $outType   = $data{outType}   = whatIsOutput($_[1], WANT_EXT|WANT_HASH);

    my $oneInput  = $data{oneInput}  = oneTarget($inType);
    my $oneOutput = $data{oneOutput} = oneTarget($outType);

    if (! $inType)
    {
        $obj->croakError("$reportClass: illegal input parameter") ;
        #return undef ;
    }    

#    if ($inType eq 'hash')
#    {
#        $obj->{Hash} = 1 ;
#        $obj->{oneInput} = 1 ;
#        return $obj->validateHash($_[0]);
#    }

    if (! $outType)
    {
        $obj->croakError("$reportClass: illegal output parameter") ;
        #return undef ;
    }    


    if ($inType ne 'fileglob' && $outType eq 'fileglob')
    {
        $obj->croakError("Need input fileglob for outout fileglob");
    }    

#    if ($inType ne 'fileglob' && $outType eq 'hash' && $inType ne 'filename' )
#    {
#        $obj->croakError("input must ne filename or fileglob when output is a hash");
#    }    

    if ($inType eq 'fileglob' && $outType eq 'fileglob')
    {
        $data{GlobMap} = 1 ;
        $data{inType} = $data{outType} = 'filename';
        my $mapper = new File::GlobMapper($_[0], $_[1]);
        if ( ! $mapper )
        {
            return $obj->saveErrorString($File::GlobMapper::Error) ;
        }
        $data{Pairs} = $mapper->getFileMap();

        return $obj;
    }
    
    $obj->croakError("$reportClass: input and output $inType are identical")
        if $inType eq $outType && $_[0] eq $_[1] && $_[0] ne '-' ;

    if ($inType eq 'fileglob') # && $outType ne 'fileglob'
    {
        my $glob = cleanFileGlobString($_[0]);
        my @inputs = glob($glob);

        if (@inputs == 0)
        {
            # TODO -- legal or die?
            die "globmap matched zero file -- legal or die???" ;
        }
        elsif (@inputs == 1)
        {
            $obj->validateInputFilenames($inputs[0])
                or return undef;
            $_[0] = $inputs[0]  ;
            $data{inType} = 'filename' ;
            $data{oneInput} = 1;
        }
        else
        {
            $obj->validateInputFilenames(@inputs)
                or return undef;
            $_[0] = [ @inputs ] ;
            $data{inType} = 'filenames' ;
        }
    }
    elsif ($inType eq 'filename')
    {
        $obj->validateInputFilenames($_[0])
            or return undef;
    }
    elsif ($inType eq 'array')
    {
        $data{inType} = 'filenames' ;
        $obj->validateInputArray($_[0])
            or return undef ;
    }

    return $obj->saveErrorString("$reportClass: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[1] });

    if ($outType eq 'filename' )
    {
        $obj->croakError("$reportClass: output filename is undef or null string")
            if ! defined $_[1] || $_[1] eq ''  ;

        if (-e $_[1])
        {
            if (-d _ )
            {
                return $obj->saveErrorString("output file '$_[1]' is a directory");
            }
        }
    }
    
    return $obj ;
}

sub IO::Compress::Base::Validator::saveErrorString
{
    my $self   = shift ;
    ${ $self->{Error} } = shift ;
    return undef;
    
}

sub IO::Compress::Base::Validator::croakError
{
    my $self   = shift ;
    $self->saveErrorString($_[0]);
    croak $_[0];
}



sub IO::Compress::Base::Validator::validateInputFilenames
{
    my $self = shift ;

    foreach my $filename (@_)
    {
        $self->croakError("$self->{reportClass}: input filename is undef or null string")
            if ! defined $filename || $filename eq ''  ;

        next if $filename eq '-';

        if (! -e $filename )
        {
            return $self->saveErrorString("input file '$filename' does not exist");
        }

        if (-d _ )
        {
            return $self->saveErrorString("input file '$filename' is a directory");
        }

        if (! -r _ )
        {
            return $self->saveErrorString("cannot open file '$filename': $!");
        }
    }

    return 1 ;
}

sub IO::Compress::Base::Validator::validateInputArray
{
    my $self = shift ;

    if ( @{ $_[0] } == 0 )
    {
        return $self->saveErrorString("empty array reference") ;
    }    

    foreach my $element ( @{ $_[0] } )
    {
        my $inType  = whatIsInput($element);
    
        if (! $inType)
        {
            $self->croakError("unknown input parameter") ;
        }    
        elsif($inType eq 'filename')
        {
            $self->validateInputFilenames($element)
                or return undef ;
        }
        else
        {
            $self->croakError("not a filename") ;
        }
    }

    return 1 ;
}

#sub IO::Compress::Base::Validator::validateHash
#{
#    my $self = shift ;
#    my $href = shift ;
#
#    while (my($k, $v) = each %$href)
#    {
#        my $ktype = whatIsInput($k);
#        my $vtype = whatIsOutput($v, WANT_EXT|WANT_UNDEF) ;
#
#        if ($ktype ne 'filename')
#        {
#            return $self->saveErrorString("hash key not filename") ;
#        }    
#
#        my %valid = map { $_ => 1 } qw(filename buffer array undef handle) ;
#        if (! $valid{$vtype})
#        {
#            return $self->saveErrorString("hash value not ok") ;
#        }    
#    }
#
#    return $self ;
#}

sub createSelfTiedObject
{
    my $class = shift || (caller)[0] ;
    my $error_ref = shift ;

    my $obj = bless Symbol::gensym(), ref($class) || $class;
    tie *$obj, $obj if $] >= 5.005;
    *$obj->{Closed} = 1 ;
    $$error_ref = '';
    *$obj->{Error} = $error_ref ;
    my $errno = 0 ;
    *$obj->{ErrorNo} = \$errno ;

    return $obj;
}



#package Parse::Parameters ;
#
#
#require Exporter;
#our ($VERSION, @ISA, @EXPORT);
#$VERSION = '2.000_08';
#@ISA = qw(Exporter);

$EXPORT_TAGS{Parse} = [qw( ParseParameters 
                           Parse_any Parse_unsigned Parse_signed 
                           Parse_boolean Parse_custom Parse_string
                           Parse_multiple Parse_writable_scalar
                         )
                      ];              

push @EXPORT, @{ $EXPORT_TAGS{Parse} } ;

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_custom   => 0x12;

#use constant Parse_store_ref        => 0x100 ;
use constant Parse_multiple         => 0x100 ;
use constant Parse_writable         => 0x200 ;
use constant Parse_writable_scalar  => 0x400 | Parse_writable ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    local $Carp::CarpLevel = 1 ;
    
    return $_[1]
        if @_ == 2 && defined $_[1] && UNIVERSAL::isa($_[1], "IO::Compress::Base::Parameters");
    
    my $p = new IO::Compress::Base::Parameters() ;            
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}

#package IO::Compress::Base::Parameters;

use strict;
use warnings;
use Carp;

sub IO::Compress::Base::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

sub IO::Compress::Base::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub IO::Compress::Base::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;
    my $other;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;
    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            if ($_[2 * $i] eq '__xxx__') {
                $other = $_[2 * $i + 1] ;
            }
            else {
                push @entered, $_[2 * $i] ;
                push @entered, \$_[2 * $i + 1] ;
            }
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $x = [ $x ]
                if $type & Parse_multiple;

            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    my %parsed = ();
    
    if ($other) 
    {
        for my $key (keys %$default)  
        {
            my $canonkey = lc $key;
            if ($other->parsed($canonkey))
            {
                my $value = $other->value($canonkey);
#print "SET '$canonkey' to $value [$$value]\n";
                ++ $parsed{$canonkey};
                $got->{$canonkey}[OFF_PARSED]  = 1;
                $got->{$canonkey}[OFF_DEFAULT] = $value;
                $got->{$canonkey}[OFF_FIXED]   = $value;
            }
        }
    }
    
    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $parsed = $parsed{$canonkey};
            ++ $parsed{$canonkey};

            return $self->setError("Muliple instances of '$key' found") 
                if $parsed && $type & Parse_multiple == 0 ;

            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;

            $value = $$value ;
            if ($type & Parse_multiple) {
                $got->{$canonkey}[OFF_PARSED] = 1;
                push @{ $got->{$canonkey}[OFF_FIXED] }, $s ;
            }
            else {
                $got->{$canonkey} = [1, $type, $value, $s] ;
            }
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) $bad") ;
    }

    return 1;
}

sub IO::Compress::Base::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;

    if ($type & Parse_writable_scalar)
    {
        return $self->setError("Parameter '$key' not writable")
            if $validate &&  readonly $$value ;

        if (ref $$value) 
        {
            return $self->setError("Parameter '$key' not a scalar reference")
                if $validate &&  ref $$value ne 'SCALAR' ;

            $$output = $$value ;
        }
        else  
        {
            return $self->setError("Parameter '$key' not a scalar")
                if $validate &&  ref $value ne 'SCALAR' ;

            $$output = $value ;
        }

        return 1;
    }

#    if ($type & Parse_store_ref)
#    {
#        #$value = $$value
#        #    if ref ${ $value } ;
#
#        $$output = $value ;
#        return 1;
#    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;    
        return 1;
    }

    $$output = $value ;
    return 1;
}



sub IO::Compress::Base::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub IO::Compress::Base::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

sub IO::Compress::Base::Parameters::valueOrDefault
{
    my $self = shift ;
    my $name = shift ;
    my $default = shift ;

    my $value = $self->{Got}{lc $name}[OFF_DEFAULT] ;

    return $value if defined $value ;
    return $default ;
}

sub IO::Compress::Base::Parameters::wantValue
{
    my $self = shift ;
    my $name = shift ;

    return defined $self->{Got}{lc $name}[OFF_DEFAULT] ;

}

sub IO::Compress::Base::Parameters::clone
{
    my $self = shift ;
    my $obj = { };
    my %got ;

    while (my ($k, $v) = each %{ $self->{Got} }) {
        $got{$k} = [ @$v ];
    }

    $obj->{Error} = $self->{Error};
    $obj->{Got} = \%got ;

    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

package U64;

use constant MAX32 => 0xFFFFFFFF ;
use constant HI_1 => MAX32 + 1 ;
use constant LOW   => 0 ;
use constant HIGH  => 1;

sub new
{
    my $class = shift ;

    my $high = 0 ;
    my $low  = 0 ;

    if (@_ == 2) {
        $high = shift ;
        $low  = shift ;
    }
    elsif (@_ == 1) {
        $low  = shift ;
    }

    bless [$low, $high], $class;
}

sub newUnpack_V64
{
    my $string = shift;

    my ($low, $hi) = unpack "V V", $string ;
    bless [ $low, $hi ], "U64";
}

sub newUnpack_V32
{
    my $string = shift;

    my $low = unpack "V", $string ;
    bless [ $low, 0 ], "U64";
}

sub reset
{
    my $self = shift;
    $self->[HIGH] = $self->[LOW] = 0;
}

sub clone
{
    my $self = shift;
    bless [ @$self ], ref $self ;
}

sub getHigh
{
    my $self = shift;
    return $self->[HIGH];
}

sub getLow
{
    my $self = shift;
    return $self->[LOW];
}

sub get32bit
{
    my $self = shift;
    return $self->[LOW];
}

sub get64bit
{
    my $self = shift;
    # Not using << here because the result will still be
    # a 32-bit value on systems where int size is 32-bits
    return $self->[HIGH] * HI_1 + $self->[LOW];
}

sub add
{
    my $self = shift;
    my $value = shift;

    if (ref $value eq 'U64') {
        $self->[HIGH] += $value->[HIGH] ;
        $value = $value->[LOW];
    }
     
    my $available = MAX32 - $self->[LOW] ;

    if ($value > $available) {
       ++ $self->[HIGH] ;
       $self->[LOW] = $value - $available - 1;
    }
    else {
       $self->[LOW] += $value ;
    }

}

sub equal
{
    my $self = shift;
    my $other = shift;

    return $self->[LOW]  == $other->[LOW] &&
           $self->[HIGH] == $other->[HIGH] ;
}

sub is64bit
{
    my $self = shift;
    return $self->[HIGH] > 0 ;
}

sub getPacked_V64
{
    my $self = shift;

    return pack "V V", @$self ;
}

sub getPacked_V32
{
    my $self = shift;

    return pack "V", $self->[LOW] ;
}

sub pack_V64
{
    my $low  = shift;

    return pack "V V", $low, 0;
}


package IO::Compress::Base::Common;

1;
FILE   1a087f4e/IO/Compress/Gzip.pm  �#line 1 "/usr/lib64/perl5/IO/Compress/Gzip.pm"

package IO::Compress::Gzip ;

require 5.004 ;

use strict ;
use warnings;
use bytes;


use IO::Compress::RawDeflate 2.021 ;

use Compress::Raw::Zlib  2.021 ;
use IO::Compress::Base::Common  2.021 qw(:Status :Parse createSelfTiedObject);
use IO::Compress::Gzip::Constants 2.021 ;
use IO::Compress::Zlib::Extra 2.021 ;

BEGIN
{
    if (defined &utf8::downgrade ) 
      { *noUTF8 = \&utf8::downgrade }
    else
      { *noUTF8 = sub {} }  
}

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $GzipError);

$VERSION = '2.021';
$GzipError = '' ;

@ISA    = qw(Exporter IO::Compress::RawDeflate);
@EXPORT_OK = qw( $GzipError gzip ) ;
%EXPORT_TAGS = %IO::Compress::RawDeflate::DEFLATE_CONSTANTS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class, \$GzipError);

    $obj->_create(undef, @_);
}


sub gzip
{
    my $obj = createSelfTiedObject(undef, \$GzipError);
    return $obj->_def(@_);
}

#sub newHeader
#{
#    my $self = shift ;
#    #return GZIP_MINIMUM_HEADER ;
#    return $self->mkHeader(*$self->{Got});
#}

sub getExtraParams
{
    my $self = shift ;

    return (
            # zlib behaviour
            $self->getZlibParams(),

            # Gzip header fields
            'Minimal'   => [0, 1, Parse_boolean,   0],
            'Comment'   => [0, 1, Parse_any,       undef],
            'Name'      => [0, 1, Parse_any,       undef],
            'Time'      => [0, 1, Parse_any,       undef],
            'TextFlag'  => [0, 1, Parse_boolean,   0],
            'HeaderCRC' => [0, 1, Parse_boolean,   0],
            'OS_Code'   => [0, 1, Parse_unsigned,  $Compress::Raw::Zlib::gzip_os_code],
            'ExtraField'=> [0, 1, Parse_any,       undef],
            'ExtraFlags'=> [0, 1, Parse_any,       undef],

        );
}


sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gzip always needs crc32
    $got->value('CRC32' => 1);

    return 1
        if $got->value('Merge') ;

    my $strict = $got->value('Strict') ;


    {
        if (! $got->parsed('Time') ) {
            # Modification time defaults to now.
            $got->value('Time' => time) ;
        }

        # Check that the Name & Comment don't have embedded NULLs
        # Also check that they only contain ISO 8859-1 chars.
        if ($got->parsed('Name') && defined $got->value('Name')) {
            my $name = $got->value('Name');
                
            return $self->saveErrorString(undef, "Null Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
        }

        if ($got->parsed('Comment') && defined $got->value('Comment')) {
            my $comment = $got->value('Comment');

            return $self->saveErrorString(undef, "Null Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o;
        }

        if ($got->parsed('OS_Code') ) {
            my $value = $got->value('OS_Code');

            return $self->saveErrorString(undef, "OS_Code must be between 0 and 255, got '$value'")
                if $value < 0 || $value > 255 ;
            
        }

        # gzip only supports Deflate at present
        $got->value('Method' => Z_DEFLATED) ;

        if ( ! $got->parsed('ExtraFlags')) {
            $got->value('ExtraFlags' => 2) 
                if $got->value('Level') == Z_BEST_SPEED ;
            $got->value('ExtraFlags' => 4) 
                if $got->value('Level') == Z_BEST_COMPRESSION ;
        }

        my $data = $got->value('ExtraField') ;
        if (defined $data) {
            my $bad = IO::Compress::Zlib::Extra::parseExtraField($data, $strict, 1) ;
            return $self->saveErrorString(undef, "Error with ExtraField Parameter: $bad", Z_DATA_ERROR)
                if $bad ;

            $got->value('ExtraField', $data) ;
        }
    }

    return 1;
}

sub mkTrailer
{
    my $self = shift ;
    return pack("V V", *$self->{Compress}->crc32(), 
                       *$self->{UnCompSize}->get32bit());
}

sub getInverseClass
{
    return ('IO::Uncompress::Gunzip',
                \$IO::Uncompress::Gunzip::GunzipError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $filename = shift ;

    my $defaultTime = (stat($filename))[9] ;

    $params->value('Name' => $filename)
        if ! $params->parsed('Name') ;

    $params->value('Time' => $defaultTime) 
        if ! $params->parsed('Time') ;
}


sub mkHeader
{
    my $self = shift ;
    my $param = shift ;

    # stort-circuit if a minimal header is requested.
    return GZIP_MINIMUM_HEADER if $param->value('Minimal') ;

    # METHOD
    my $method = $param->valueOrDefault('Method', GZIP_CM_DEFLATED) ;

    # FLAGS
    my $flags       = GZIP_FLG_DEFAULT ;
    $flags |= GZIP_FLG_FTEXT    if $param->value('TextFlag') ;
    $flags |= GZIP_FLG_FHCRC    if $param->value('HeaderCRC') ;
    $flags |= GZIP_FLG_FEXTRA   if $param->wantValue('ExtraField') ;
    $flags |= GZIP_FLG_FNAME    if $param->wantValue('Name') ;
    $flags |= GZIP_FLG_FCOMMENT if $param->wantValue('Comment') ;
    
    # MTIME
    my $time = $param->valueOrDefault('Time', GZIP_MTIME_DEFAULT) ;

    # EXTRA FLAGS
    my $extra_flags = $param->valueOrDefault('ExtraFlags', GZIP_XFL_DEFAULT);

    # OS CODE
    my $os_code = $param->valueOrDefault('OS_Code', GZIP_OS_DEFAULT) ;


    my $out = pack("C4 V C C", 
            GZIP_ID1,   # ID1
            GZIP_ID2,   # ID2
            $method,    # Compression Method
            $flags,     # Flags
            $time,      # Modification Time
            $extra_flags, # Extra Flags
            $os_code,   # Operating System Code
            ) ;

    # EXTRA
    if ($flags & GZIP_FLG_FEXTRA) {
        my $extra = $param->value('ExtraField') ;
        $out .= pack("v", length $extra) . $extra ;
    }

    # NAME
    if ($flags & GZIP_FLG_FNAME) {
        my $name .= $param->value('Name') ;
        $name =~ s/\x00.*$//;
        $out .= $name ;
        # Terminate the filename with NULL unless it already is
        $out .= GZIP_NULL_BYTE 
            if !length $name or
               substr($name, 1, -1) ne GZIP_NULL_BYTE ;
    }

    # COMMENT
    if ($flags & GZIP_FLG_FCOMMENT) {
        my $comment .= $param->value('Comment') ;
        $comment =~ s/\x00.*$//;
        $out .= $comment ;
        # Terminate the comment with NULL unless it already is
        $out .= GZIP_NULL_BYTE
            if ! length $comment or
               substr($comment, 1, -1) ne GZIP_NULL_BYTE;
    }

    # HEADER CRC
    $out .= pack("v", crc32($out) & 0x00FF ) if $param->value('HeaderCRC') ;

    noUTF8($out);

    return $out ;
}

sub mkFinalTrailer
{
    return '';
}

1; 

__END__

#line 1202
FILE   &e5a60a79/IO/Compress/Gzip/Constants.pm  x#line 1 "/usr/lib64/perl5/IO/Compress/Gzip/Constants.pm"
package IO::Compress::Gzip::Constants;

use strict ;
use warnings;
use bytes;

require Exporter;

our ($VERSION, @ISA, @EXPORT, %GZIP_OS_Names);
our ($GZIP_FNAME_INVALID_CHAR_RE, $GZIP_FCOMMENT_INVALID_CHAR_RE);

$VERSION = '2.021';

@ISA = qw(Exporter);

@EXPORT= qw(

    GZIP_ID_SIZE
    GZIP_ID1
    GZIP_ID2

    GZIP_FLG_DEFAULT
    GZIP_FLG_FTEXT
    GZIP_FLG_FHCRC
    GZIP_FLG_FEXTRA
    GZIP_FLG_FNAME
    GZIP_FLG_FCOMMENT
    GZIP_FLG_RESERVED

    GZIP_CM_DEFLATED

    GZIP_MIN_HEADER_SIZE
    GZIP_TRAILER_SIZE

    GZIP_MTIME_DEFAULT
    GZIP_XFL_DEFAULT
    GZIP_FEXTRA_HEADER_SIZE
    GZIP_FEXTRA_MAX_SIZE
    GZIP_FEXTRA_SUBFIELD_HEADER_SIZE
    GZIP_FEXTRA_SUBFIELD_ID_SIZE
    GZIP_FEXTRA_SUBFIELD_LEN_SIZE
    GZIP_FEXTRA_SUBFIELD_MAX_SIZE

    $GZIP_FNAME_INVALID_CHAR_RE
    $GZIP_FCOMMENT_INVALID_CHAR_RE

    GZIP_FHCRC_SIZE

    GZIP_ISIZE_MAX
    GZIP_ISIZE_MOD_VALUE


    GZIP_NULL_BYTE

    GZIP_OS_DEFAULT

    %GZIP_OS_Names

    GZIP_MINIMUM_HEADER

    );

# Constant names derived from RFC 1952

use constant GZIP_ID_SIZE                     => 2 ;
use constant GZIP_ID1                         => 0x1F;
use constant GZIP_ID2                         => 0x8B;

use constant GZIP_MIN_HEADER_SIZE             => 10 ;# minimum gzip header size
use constant GZIP_TRAILER_SIZE                => 8 ;


use constant GZIP_FLG_DEFAULT                 => 0x00 ;
use constant GZIP_FLG_FTEXT                   => 0x01 ;
use constant GZIP_FLG_FHCRC                   => 0x02 ; # called CONTINUATION in gzip
use constant GZIP_FLG_FEXTRA                  => 0x04 ;
use constant GZIP_FLG_FNAME                   => 0x08 ;
use constant GZIP_FLG_FCOMMENT                => 0x10 ;
#use constant GZIP_FLG_ENCRYPTED              => 0x20 ; # documented in gzip sources
use constant GZIP_FLG_RESERVED                => (0x20 | 0x40 | 0x80) ;

use constant GZIP_XFL_DEFAULT                 => 0x00 ;

use constant GZIP_MTIME_DEFAULT               => 0x00 ;

use constant GZIP_FEXTRA_HEADER_SIZE          => 2 ;
use constant GZIP_FEXTRA_MAX_SIZE             => 0xFFFF ;
use constant GZIP_FEXTRA_SUBFIELD_ID_SIZE     => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_LEN_SIZE    => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_HEADER_SIZE => GZIP_FEXTRA_SUBFIELD_ID_SIZE +
                                                 GZIP_FEXTRA_SUBFIELD_LEN_SIZE;
use constant GZIP_FEXTRA_SUBFIELD_MAX_SIZE    => GZIP_FEXTRA_MAX_SIZE - 
                                                 GZIP_FEXTRA_SUBFIELD_HEADER_SIZE ;


if (ord('A') == 193)
{
    # EBCDIC 
    $GZIP_FNAME_INVALID_CHAR_RE = '[\x00-\x3f\xff]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE = '[\x00-\x0a\x11-\x14\x16-\x3f\xff]';
    
}
else
{
    $GZIP_FNAME_INVALID_CHAR_RE       =  '[\x00-\x1F\x7F-\x9F]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE    =  '[\x00-\x09\x11-\x1F\x7F-\x9F]';
}            

use constant GZIP_FHCRC_SIZE        => 2 ; # aka CONTINUATION in gzip

use constant GZIP_CM_DEFLATED       => 8 ;

use constant GZIP_NULL_BYTE         => "\x00";
use constant GZIP_ISIZE_MAX         => 0xFFFFFFFF ;
use constant GZIP_ISIZE_MOD_VALUE   => GZIP_ISIZE_MAX + 1 ;

# OS Names sourced from http://www.gzip.org/format.txt

use constant GZIP_OS_DEFAULT=> 0xFF ;
%GZIP_OS_Names = (
    0   => 'MS-DOS',
    1   => 'Amiga',
    2   => 'VMS',
    3   => 'Unix',
    4   => 'VM/CMS',
    5   => 'Atari TOS',
    6   => 'HPFS (OS/2, NT)',
    7   => 'Macintosh',
    8   => 'Z-System',
    9   => 'CP/M',
    10  => 'TOPS-20',
    11  => 'NTFS (NT)',
    12  => 'SMS QDOS',
    13  => 'Acorn RISCOS',
    14  => 'VFAT file system (Win95, NT)',
    15  => 'MVS',
    16  => 'BeOS',
    17  => 'Tandem/NSK',
    18  => 'THEOS',
    GZIP_OS_DEFAULT()   => 'Unknown',
    ) ;

use constant GZIP_MINIMUM_HEADER =>   pack("C4 V C C",  
        GZIP_ID1, GZIP_ID2, GZIP_CM_DEFLATED, GZIP_FLG_DEFAULT,
        GZIP_MTIME_DEFAULT, GZIP_XFL_DEFAULT, GZIP_OS_DEFAULT) ;


1;
FILE   "6638d265/IO/Compress/RawDeflate.pm  m#line 1 "/usr/lib64/perl5/IO/Compress/RawDeflate.pm"
package IO::Compress::RawDeflate ;

# create RFC1951
#
use strict ;
use warnings;
use bytes;


use IO::Compress::Base 2.021 ;
use IO::Compress::Base::Common  2.021 qw(:Status createSelfTiedObject);
use IO::Compress::Adapter::Deflate  2.021 ;

require Exporter ;


our ($VERSION, @ISA, @EXPORT_OK, %DEFLATE_CONSTANTS, %EXPORT_TAGS, $RawDeflateError);

$VERSION = '2.021';
$RawDeflateError = '';

@ISA = qw(Exporter IO::Compress::Base);
@EXPORT_OK = qw( $RawDeflateError rawdeflate ) ;

%EXPORT_TAGS = ( flush     => [qw{  
                                    Z_NO_FLUSH
                                    Z_PARTIAL_FLUSH
                                    Z_SYNC_FLUSH
                                    Z_FULL_FLUSH
                                    Z_FINISH
                                    Z_BLOCK
                              }],
                 level     => [qw{  
                                    Z_NO_COMPRESSION
                                    Z_BEST_SPEED
                                    Z_BEST_COMPRESSION
                                    Z_DEFAULT_COMPRESSION
                              }],
                 strategy  => [qw{  
                                    Z_FILTERED
                                    Z_HUFFMAN_ONLY
                                    Z_RLE
                                    Z_FIXED
                                    Z_DEFAULT_STRATEGY
                              }],

              );

{
    my %seen;
    foreach (keys %EXPORT_TAGS )
    {
        push @{$EXPORT_TAGS{constants}}, 
                 grep { !$seen{$_}++ } 
                 @{ $EXPORT_TAGS{$_} }
    }
    $EXPORT_TAGS{all} = $EXPORT_TAGS{constants} ;
}


%DEFLATE_CONSTANTS = %EXPORT_TAGS;

push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;

Exporter::export_ok_tags('all');
              


sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class, \$RawDeflateError);

    return $obj->_create(undef, @_);
}

sub rawdeflate
{
    my $obj = createSelfTiedObject(undef, \$RawDeflateError);
    return $obj->_def(@_);
}

sub ckParams
{
    my $self = shift ;
    my $got = shift;

    return 1 ;
}

sub mkComp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Compress::Adapter::Deflate::mkCompObject(
                                                 $got->value('CRC32'),
                                                 $got->value('Adler32'),
                                                 $got->value('Level'),
                                                 $got->value('Strategy')
                                                 );

   return $self->saveErrorString(undef, $errstr, $errno)
       if ! defined $obj;

   return $obj;    
}


sub mkHeader
{
    my $self = shift ;
    return '';
}

sub mkTrailer
{
    my $self = shift ;
    return '';
}

sub mkFinalTrailer
{
    return '';
}


#sub newHeader
#{
#    my $self = shift ;
#    return '';
#}

sub getExtraParams
{
    my $self = shift ;
    return $self->getZlibParams();
}

sub getZlibParams
{
    my $self = shift ;

    use IO::Compress::Base::Common  2.021 qw(:Parse);
    use Compress::Raw::Zlib  2.021 qw(Z_DEFLATED Z_DEFAULT_COMPRESSION Z_DEFAULT_STRATEGY);

    
    return (
        
            # zlib behaviour
            #'Method'   => [0, 1, Parse_unsigned,  Z_DEFLATED],
            'Level'     => [0, 1, Parse_signed,    Z_DEFAULT_COMPRESSION],
            'Strategy'  => [0, 1, Parse_signed,    Z_DEFAULT_STRATEGY],

            'CRC32'     => [0, 1, Parse_boolean,   0],
            'ADLER32'   => [0, 1, Parse_boolean,   0],
            'Merge'     => [1, 1, Parse_boolean,   0],
        );
    
    
}

sub getInverseClass
{
    return ('IO::Uncompress::RawInflate', 
                \$IO::Uncompress::RawInflate::RawInflateError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $file = shift ;
    
}

use IO::Seekable qw(SEEK_SET);

sub createMerge
{
    my $self = shift ;
    my $outValue = shift ;
    my $outType = shift ;

    my ($invClass, $error_ref) = $self->getInverseClass();
    eval "require $invClass" 
        or die "aaaahhhh" ;

    my $inf = $invClass->new( $outValue, 
                             Transparent => 0, 
                             #Strict     => 1,
                             AutoClose   => 0,
                             Scan        => 1)
       or return $self->saveErrorString(undef, "Cannot create InflateScan object: $$error_ref" ) ;

    my $end_offset = 0;
    $inf->scan() 
        or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $inf->errorNo) ;
    $inf->zap($end_offset) 
        or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $inf->errorNo) ;

    my $def = *$self->{Compress} = $inf->createDeflate();

    *$self->{Header} = *$inf->{Info}{Header};
    *$self->{UnCompSize} = *$inf->{UnCompSize}->clone();
    *$self->{CompSize} = *$inf->{CompSize}->clone();
    # TODO -- fix this
    #*$self->{CompSize} = new U64(0, *$self->{UnCompSize_32bit});


    if ( $outType eq 'buffer') 
      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
    elsif ($outType eq 'handle' || $outType eq 'filename') {
        *$self->{FH} = *$inf->{FH} ;
        delete *$inf->{FH};
        *$self->{FH}->flush() ;
        *$self->{Handle} = 1 if $outType eq 'handle';

        #seek(*$self->{FH}, $end_offset, SEEK_SET) 
        *$self->{FH}->seek($end_offset, SEEK_SET) 
            or return $self->saveErrorString(undef, $!, $!) ;
    }

    return $def ;
}

#### zlib specific methods

sub deflateParams 
{
    my $self = shift ;

    my $level = shift ;
    my $strategy = shift ;

    my $status = *$self->{Compress}->deflateParams(Level => $level, Strategy => $strategy) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    return 1;    
}




1;

__END__

#line 977
FILE   "1ffdc630/IO/Compress/Zlib/Extra.pm  �#line 1 "/usr/lib64/perl5/IO/Compress/Zlib/Extra.pm"
package IO::Compress::Zlib::Extra;

require 5.004 ;

use strict ;
use warnings;
use bytes;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.021';

use IO::Compress::Gzip::Constants 2.021 ;

sub ExtraFieldError
{
    return $_[0];
    return "Error with ExtraField Parameter: $_[0]" ;
}

sub validateExtraFieldPair
{
    my $pair = shift ;
    my $strict = shift;
    my $gzipMode = shift ;

    return ExtraFieldError("Not an array ref")
        unless ref $pair &&  ref $pair eq 'ARRAY';

    return ExtraFieldError("SubField must have two parts")
        unless @$pair == 2 ;

    return ExtraFieldError("SubField ID is a reference")
        if ref $pair->[0] ;

    return ExtraFieldError("SubField Data is a reference")
        if ref $pair->[1] ;

    # ID is exactly two chars   
    return ExtraFieldError("SubField ID not two chars long")
        unless length $pair->[0] == GZIP_FEXTRA_SUBFIELD_ID_SIZE ;

    # Check that the 2nd byte of the ID isn't 0    
    return ExtraFieldError("SubField ID 2nd byte is 0x00")
        if $strict && $gzipMode && substr($pair->[0], 1, 1) eq "\x00" ;

    return ExtraFieldError("SubField Data too long")
        if length $pair->[1] > GZIP_FEXTRA_SUBFIELD_MAX_SIZE ;


    return undef ;
}

sub parseRawExtra
{
    my $data     = shift ;
    my $extraRef = shift;
    my $strict   = shift;
    my $gzipMode = shift ;

    #my $lax = shift ;

    #return undef
    #    if $lax ;

    my $XLEN = length $data ;

    return ExtraFieldError("Too Large")
        if $XLEN > GZIP_FEXTRA_MAX_SIZE;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + $subLen > $XLEN ;

        my $bad = validateExtraFieldPair( [$id, 
                                           substr($data, $offset, $subLen)], 
                                           $strict, $gzipMode );
        return $bad if $bad ;
        push @$extraRef, [$id => substr($data, $offset, $subLen)]
            if defined $extraRef;;

        $offset += $subLen ;
    }

        
    return undef ;
}


sub mkSubField
{
    my $id = shift ;
    my $data = shift ;

    return $id . pack("v", length $data) . $data ;
}

sub parseExtraField
{
    my $dataRef  = $_[0];
    my $strict   = $_[1];
    my $gzipMode = $_[2];
    #my $lax     = @_ == 2 ? $_[1] : 1;


    # ExtraField can be any of
    #
    #    -ExtraField => $data
    #
    #    -ExtraField => [$id1, $data1,
    #                    $id2, $data2]
    #                     ...
    #                   ]
    #
    #    -ExtraField => [ [$id1 => $data1],
    #                     [$id2 => $data2],
    #                     ...
    #                   ]
    #
    #    -ExtraField => { $id1 => $data1,
    #                     $id2 => $data2,
    #                     ...
    #                   }
    
    if ( ! ref $dataRef ) {

        return undef
            if ! $strict;

        return parseRawExtra($dataRef, undef, 1, $gzipMode);
    }

    #my $data = $$dataRef;
    my $data = $dataRef;
    my $out = '' ;

    if (ref $data eq 'ARRAY') {    
        if (ref $data->[0]) {

            foreach my $pair (@$data) {
                return ExtraFieldError("Not list of lists")
                    unless ref $pair eq 'ARRAY' ;

                my $bad = validateExtraFieldPair($pair, $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField(@$pair);
            }   
        }   
        else {
            return ExtraFieldError("Not even number of elements")
                unless @$data % 2  == 0;

            for (my $ix = 0; $ix <= length(@$data) -1 ; $ix += 2) {
                my $bad = validateExtraFieldPair([$data->[$ix],
                                                  $data->[$ix+1]], 
                                                 $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField($data->[$ix], $data->[$ix+1]);
            }   
        }
    }   
    elsif (ref $data eq 'HASH') {    
        while (my ($id, $info) = each %$data) {
            my $bad = validateExtraFieldPair([$id, $info], $strict, $gzipMode);
            return $bad if $bad ;

            $out .= mkSubField($id, $info);
        }   
    }   
    else {
        return ExtraFieldError("Not a scalar, array ref or hash ref") ;
    }

    return ExtraFieldError("Too Large")
        if length $out > GZIP_FEXTRA_MAX_SIZE;

    $_[0] = $out ;

    return undef;
}

1;

__END__
FILE   f94acd2c/IO/File.pm  �#line 1 "/usr/lib64/perl5/IO/File.pm"
#

package IO::File;

#line 126

use 5.006_001;
use strict;
our($VERSION, @EXPORT, @EXPORT_OK, @ISA);
use Carp;
use Symbol;
use SelectSaver;
use IO::Seekable;
use File::Spec;

require Exporter;

@ISA = qw(IO::Handle IO::Seekable Exporter);

$VERSION = "1.14";

@EXPORT = @IO::Seekable::EXPORT;

eval {
    # Make all Fcntl O_XXX constants available for importing
    require Fcntl;
    my @O = grep /^O_/, @Fcntl::EXPORT;
    Fcntl->import(@O);  # first we import what we want to export
    push(@EXPORT, @O);
};

################################################
## Constructor
##

sub new {
    my $type = shift;
    my $class = ref($type) || $type || "IO::File";
    @_ >= 0 && @_ <= 3
	or croak "usage: new $class [FILENAME [,MODE [,PERMS]]]";
    my $fh = $class->SUPER::new();
    if (@_) {
	$fh->open(@_)
	    or return undef;
    }
    $fh;
}

################################################
## Open
##

sub open {
    @_ >= 2 && @_ <= 4 or croak 'usage: $fh->open(FILENAME [,MODE [,PERMS]])';
    my ($fh, $file) = @_;
    if (@_ > 2) {
	my ($mode, $perms) = @_[2, 3];
	if ($mode =~ /^\d+$/) {
	    defined $perms or $perms = 0666;
	    return sysopen($fh, $file, $mode, $perms);
	} elsif ($mode =~ /:/) {
	    return open($fh, $mode, $file) if @_ == 3;
	    croak 'usage: $fh->open(FILENAME, IOLAYERS)';
	} else {
            return open($fh, IO::Handle::_open_mode_string($mode), $file);
        }
    }
    open($fh, $file);
}

################################################
## Binmode
##

sub binmode {
    ( @_ == 1 or @_ == 2 ) or croak 'usage $fh->binmode([LAYER])';

    my($fh, $layer) = @_;

    return binmode $$fh unless $layer;
    return binmode $$fh, $layer;
}

1;
FILE   70853c7f/IO/Handle.pm  D#line 1 "/usr/lib64/perl5/IO/Handle.pm"
package IO::Handle;

#line 259

use 5.006_001;
use strict;
our($VERSION, @EXPORT_OK, @ISA);
use Carp;
use Symbol;
use SelectSaver;
use IO ();	# Load the XS module

require Exporter;
@ISA = qw(Exporter);

$VERSION = "1.28";
$VERSION = eval $VERSION;

@EXPORT_OK = qw(
    autoflush
    output_field_separator
    output_record_separator
    input_record_separator
    input_line_number
    format_page_number
    format_lines_per_page
    format_lines_left
    format_name
    format_top_name
    format_line_break_characters
    format_formfeed
    format_write

    print
    printf
    say
    getline
    getlines

    printflush
    flush

    SEEK_SET
    SEEK_CUR
    SEEK_END
    _IOFBF
    _IOLBF
    _IONBF
);

################################################
## Constructors, destructors.
##

sub new {
    my $class = ref($_[0]) || $_[0] || "IO::Handle";
    @_ == 1 or croak "usage: new $class";
    my $io = gensym;
    bless $io, $class;
}

sub new_from_fd {
    my $class = ref($_[0]) || $_[0] || "IO::Handle";
    @_ == 3 or croak "usage: new_from_fd $class FD, MODE";
    my $io = gensym;
    shift;
    IO::Handle::fdopen($io, @_)
	or return undef;
    bless $io, $class;
}

#
# There is no need for DESTROY to do anything, because when the
# last reference to an IO object is gone, Perl automatically
# closes its associated files (if any).  However, to avoid any
# attempts to autoload DESTROY, we here define it to do nothing.
#
sub DESTROY {}


################################################
## Open and close.
##

sub _open_mode_string {
    my ($mode) = @_;
    $mode =~ /^\+?(<|>>?)$/
      or $mode =~ s/^r(\+?)$/$1</
      or $mode =~ s/^w(\+?)$/$1>/
      or $mode =~ s/^a(\+?)$/$1>>/
      or croak "IO::Handle: bad open mode: $mode";
    $mode;
}

sub fdopen {
    @_ == 3 or croak 'usage: $io->fdopen(FD, MODE)';
    my ($io, $fd, $mode) = @_;
    local(*GLOB);

    if (ref($fd) && "".$fd =~ /GLOB\(/o) {
	# It's a glob reference; Alias it as we cannot get name of anon GLOBs
	my $n = qualify(*GLOB);
	*GLOB = *{*$fd};
	$fd =  $n;
    } elsif ($fd =~ m#^\d+$#) {
	# It's an FD number; prefix with "=".
	$fd = "=$fd";
    }

    open($io, _open_mode_string($mode) . '&' . $fd)
	? $io : undef;
}

sub close {
    @_ == 1 or croak 'usage: $io->close()';
    my($io) = @_;

    close($io);
}

################################################
## Normal I/O functions.
##

# flock
# select

sub opened {
    @_ == 1 or croak 'usage: $io->opened()';
    defined fileno($_[0]);
}

sub fileno {
    @_ == 1 or croak 'usage: $io->fileno()';
    fileno($_[0]);
}

sub getc {
    @_ == 1 or croak 'usage: $io->getc()';
    getc($_[0]);
}

sub eof {
    @_ == 1 or croak 'usage: $io->eof()';
    eof($_[0]);
}

sub print {
    @_ or croak 'usage: $io->print(ARGS)';
    my $this = shift;
    print $this @_;
}

sub printf {
    @_ >= 2 or croak 'usage: $io->printf(FMT,[ARGS])';
    my $this = shift;
    printf $this @_;
}

sub say {
    @_ or croak 'usage: $io->say(ARGS)';
    my $this = shift;
    local $\ = "\n";
    print $this @_;
}

sub getline {
    @_ == 1 or croak 'usage: $io->getline()';
    my $this = shift;
    return scalar <$this>;
} 

*gets = \&getline;  # deprecated

sub getlines {
    @_ == 1 or croak 'usage: $io->getlines()';
    wantarray or
	croak 'Can\'t call $io->getlines in a scalar context, use $io->getline';
    my $this = shift;
    return <$this>;
}

sub truncate {
    @_ == 2 or croak 'usage: $io->truncate(LEN)';
    truncate($_[0], $_[1]);
}

sub read {
    @_ == 3 || @_ == 4 or croak 'usage: $io->read(BUF, LEN [, OFFSET])';
    read($_[0], $_[1], $_[2], $_[3] || 0);
}

sub sysread {
    @_ == 3 || @_ == 4 or croak 'usage: $io->sysread(BUF, LEN [, OFFSET])';
    sysread($_[0], $_[1], $_[2], $_[3] || 0);
}

sub write {
    @_ >= 2 && @_ <= 4 or croak 'usage: $io->write(BUF [, LEN [, OFFSET]])';
    local($\) = "";
    $_[2] = length($_[1]) unless defined $_[2];
    print { $_[0] } substr($_[1], $_[3] || 0, $_[2]);
}

sub syswrite {
    @_ >= 2 && @_ <= 4 or croak 'usage: $io->syswrite(BUF [, LEN [, OFFSET]])';
    if (defined($_[2])) {
	syswrite($_[0], $_[1], $_[2], $_[3] || 0);
    } else {
	syswrite($_[0], $_[1]);
    }
}

sub stat {
    @_ == 1 or croak 'usage: $io->stat()';
    stat($_[0]);
}

################################################
## State modification functions.
##

sub autoflush {
    my $old = new SelectSaver qualify($_[0], caller);
    my $prev = $|;
    $| = @_ > 1 ? $_[1] : 1;
    $prev;
}

sub output_field_separator {
    carp "output_field_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $,;
    $, = $_[1] if @_ > 1;
    $prev;
}

sub output_record_separator {
    carp "output_record_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $\;
    $\ = $_[1] if @_ > 1;
    $prev;
}

sub input_record_separator {
    carp "input_record_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $/;
    $/ = $_[1] if @_ > 1;
    $prev;
}

sub input_line_number {
    local $.;
    () = tell qualify($_[0], caller) if ref($_[0]);
    my $prev = $.;
    $. = $_[1] if @_ > 1;
    $prev;
}

sub format_page_number {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $%;
    $% = $_[1] if @_ > 1;
    $prev;
}

sub format_lines_per_page {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $=;
    $= = $_[1] if @_ > 1;
    $prev;
}

sub format_lines_left {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $-;
    $- = $_[1] if @_ > 1;
    $prev;
}

sub format_name {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $~;
    $~ = qualify($_[1], caller) if @_ > 1;
    $prev;
}

sub format_top_name {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $^;
    $^ = qualify($_[1], caller) if @_ > 1;
    $prev;
}

sub format_line_break_characters {
    carp "format_line_break_characters is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $:;
    $: = $_[1] if @_ > 1;
    $prev;
}

sub format_formfeed {
    carp "format_formfeed is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $^L;
    $^L = $_[1] if @_ > 1;
    $prev;
}

sub formline {
    my $io = shift;
    my $picture = shift;
    local($^A) = $^A;
    local($\) = "";
    formline($picture, @_);
    print $io $^A;
}

sub format_write {
    @_ < 3 || croak 'usage: $io->write( [FORMAT_NAME] )';
    if (@_ == 2) {
	my ($io, $fmt) = @_;
	my $oldfmt = $io->format_name(qualify($fmt,caller));
	CORE::write($io);
	$io->format_name($oldfmt);
    } else {
	CORE::write($_[0]);
    }
}

sub fcntl {
    @_ == 3 || croak 'usage: $io->fcntl( OP, VALUE );';
    my ($io, $op) = @_;
    return fcntl($io, $op, $_[2]);
}

sub ioctl {
    @_ == 3 || croak 'usage: $io->ioctl( OP, VALUE );';
    my ($io, $op) = @_;
    return ioctl($io, $op, $_[2]);
}

# this sub is for compatability with older releases of IO that used
# a sub called constant to detemine if a constant existed -- GMB
#
# The SEEK_* and _IO?BF constants were the only constants at that time
# any new code should just chech defined(&CONSTANT_NAME)

sub constant {
    no strict 'refs';
    my $name = shift;
    (($name =~ /^(SEEK_(SET|CUR|END)|_IO[FLN]BF)$/) && defined &{$name})
	? &{$name}() : undef;
}


# so that flush.pl can be deprecated

sub printflush {
    my $io = shift;
    my $old;
    $old = new SelectSaver qualify($io, caller) if ref($io);
    local $| = 1;
    if(ref($io)) {
        print $io @_;
    }
    else {
	print @_;
    }
}

1;
FILE   0cd4231c/IO/Seekable.pm  �#line 1 "/usr/lib64/perl5/IO/Seekable.pm"
#

package IO::Seekable;

#line 96

use 5.006_001;
use Carp;
use strict;
our($VERSION, @EXPORT, @ISA);
use IO::Handle ();
# XXX we can't get these from IO::Handle or we'll get prototype
# mismatch warnings on C<use POSIX; use IO::File;> :-(
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
require Exporter;

@EXPORT = qw(SEEK_SET SEEK_CUR SEEK_END);
@ISA = qw(Exporter);

$VERSION = "1.10";
$VERSION = eval $VERSION;

sub seek {
    @_ == 3 or croak 'usage: $io->seek(POS, WHENCE)';
    seek($_[0], $_[1], $_[2]);
}

sub sysseek {
    @_ == 3 or croak 'usage: $io->sysseek(POS, WHENCE)';
    sysseek($_[0], $_[1], $_[2]);
}

sub tell {
    @_ == 1 or croak 'usage: $io->tell()';
    tell($_[0]);
}

1;
FILE   )441b2a32/IO/Uncompress/Adapter/Inflate.pm  
package IO::Uncompress::Adapter::Inflate;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common  2.021 qw(:Status);
use Compress::Raw::Zlib  2.021 qw(Z_OK Z_BUF_ERROR Z_STREAM_END Z_FINISH MAX_WBITS);

our ($VERSION);
$VERSION = '2.021';



sub mkUncompObject
{
    my $crc32   = shift || 1;
    my $adler32 = shift || 1;
    my $scan    = shift || 0;

    my $inflate ;
    my $status ;

    if ($scan)
    {
        ($inflate, $status) = new Compress::Raw::Zlib::InflateScan
                                    #LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }
    else
    {
        ($inflate, $status) = new Compress::Raw::Zlib::Inflate
                                    AppendOutput => 1,
                                    LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }

    return (undef, "Could not create Inflation object: $status", $status) 
        if $status != Z_OK ;

    return bless {'Inf'        => $inflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                  'ConsumesInput' => 1,
                 } ;     
    
}

sub uncompr
{
    my $self = shift ;
    my $from = shift ;
    my $to   = shift ;
    my $eof  = shift ;

    my $inf   = $self->{Inf};

    my $status = $inf->inflate($from, $to, $eof);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK && $status != Z_STREAM_END && $status != Z_BUF_ERROR)
    {
        $self->{Error} = "Inflation Error: $status";
        return STATUS_ERROR;
    }
            
    return STATUS_OK        if $status == Z_BUF_ERROR ; # ???
    return STATUS_OK        if $status == Z_OK ;
    return STATUS_ENDSTREAM if $status == Z_STREAM_END ;
    return STATUS_ERROR ;
}

sub reset
{
    my $self = shift ;
    $self->{Inf}->inflateReset();

    return STATUS_OK ;
}

#sub count
#{
#    my $self = shift ;
#    $self->{Inf}->inflateCount();
#}

sub crc32
{
    my $self = shift ;
    $self->{Inf}->crc32();
}

sub compressedBytes
{
    my $self = shift ;
    $self->{Inf}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Inf}->uncompressedBytes();
}

sub adler32
{
    my $self = shift ;
    $self->{Inf}->adler32();
}

sub sync
{
    my $self = shift ;
    ( $self->{Inf}->inflateSync(@_) == Z_OK) 
            ? STATUS_OK 
            : STATUS_ERROR ;
}


sub getLastBlockOffset
{
    my $self = shift ;
    $self->{Inf}->getLastBlockOffset();
}

sub getEndOffset
{
    my $self = shift ;
    $self->{Inf}->getEndOffset();
}

sub resetLastBlockByte
{
    my $self = shift ;
    $self->{Inf}->resetLastBlockByte(@_);
}

sub createDeflateStream
{
    my $self = shift ;
    my $deflate = $self->{Inf}->createDeflateStream(@_);
    return bless {'Def'        => $deflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                 }, 'IO::Compress::Adapter::Deflate';
}

1;


__END__

FILE   cf28a3fa/IO/Uncompress/Base.pm  ��#line 1 "/usr/lib64/perl5/IO/Uncompress/Base.pm"

package IO::Uncompress::Base ;

use strict ;
use warnings;
use bytes;

our (@ISA, $VERSION, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(Exporter IO::File);


$VERSION = '2.021';

use constant G_EOF => 0 ;
use constant G_ERR => -1 ;

use IO::Compress::Base::Common 2.021 ;
#use Parse::Parameters ;

use IO::File ;
use Symbol;
use Scalar::Util qw(readonly);
use List::Util qw(min);
use Carp ;

%EXPORT_TAGS = ( );
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
#Exporter::export_ok_tags('all') ;



sub smartRead
{
    my $self = $_[0];
    my $out = $_[1];
    my $size = $_[2];
    $$out = "" ;

    my $offset = 0 ;


    if (defined *$self->{InputLength}) {
        return 0
            if *$self->{InputLengthRemaining} <= 0 ;
        $size = min($size, *$self->{InputLengthRemaining});
    }

    if ( length *$self->{Prime} ) {
        #$$out = substr(*$self->{Prime}, 0, $size, '') ;
        $$out = substr(*$self->{Prime}, 0, $size) ;
        substr(*$self->{Prime}, 0, $size) =  '' ;
        if (length $$out == $size) {
            *$self->{InputLengthRemaining} -= length $$out
                if defined *$self->{InputLength};

            return length $$out ;
        }
        $offset = length $$out ;
    }

    my $get_size = $size - $offset ;

    if (defined *$self->{FH}) {
        if ($offset) {
            # Not using this 
            #
            #  *$self->{FH}->read($$out, $get_size, $offset);
            #
            # because the filehandle may not support the offset parameter
            # An example is Net::FTP
            my $tmp = '';
            *$self->{FH}->read($tmp, $get_size) &&
                (substr($$out, $offset) = $tmp);
        }
        else
          { *$self->{FH}->read($$out, $get_size) }
    }
    elsif (defined *$self->{InputEvent}) {
        my $got = 1 ;
        while (length $$out < $size) {
            last 
                if ($got = *$self->{InputEvent}->($$out, $get_size)) <= 0;
        }

        if (length $$out > $size ) {
            #*$self->{Prime} = substr($$out, $size, length($$out), '');
            *$self->{Prime} = substr($$out, $size, length($$out));
            substr($$out, $size, length($$out)) =  '';
        }

       *$self->{EventEof} = 1 if $got <= 0 ;
    }
    else {
       no warnings 'uninitialized';
       my $buf = *$self->{Buffer} ;
       $$buf = '' unless defined $$buf ;
       #$$out = '' unless defined $$out ;
       substr($$out, $offset) = substr($$buf, *$self->{BufferOffset}, $get_size);
       if (*$self->{ConsumeInput})
         { substr($$buf, 0, $get_size) = '' }
       else  
         { *$self->{BufferOffset} += length($$out) - $offset }
    }

    *$self->{InputLengthRemaining} -= length($$out) #- $offset 
        if defined *$self->{InputLength};
        
    $self->saveStatus(length $$out < 0 ? STATUS_ERROR : STATUS_OK) ;

    return length $$out;
}

sub pushBack
{
    my $self = shift ;

    return if ! defined $_[0] || length $_[0] == 0 ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        *$self->{Prime} = $_[0] . *$self->{Prime} ;
        *$self->{InputLengthRemaining} += length($_[0]);
    }
    else {
        my $len = length $_[0];

        if($len > *$self->{BufferOffset}) {
            *$self->{Prime} = substr($_[0], 0, $len - *$self->{BufferOffset}) . *$self->{Prime} ;
            *$self->{InputLengthRemaining} = *$self->{InputLength};
            *$self->{BufferOffset} = 0
        }
        else {
            *$self->{InputLengthRemaining} += length($_[0]);
            *$self->{BufferOffset} -= length($_[0]) ;
        }
    }
}

sub smartSeek
{
    my $self   = shift ;
    my $offset = shift ;
    my $truncate = shift;
    #print "smartSeek to $offset\n";

    # TODO -- need to take prime into account
    if (defined *$self->{FH})
      { *$self->{FH}->seek($offset, SEEK_SET) }
    else {
        *$self->{BufferOffset} = $offset ;
        substr(${ *$self->{Buffer} }, *$self->{BufferOffset}) = ''
            if $truncate;
        return 1;
    }
}

sub smartWrite
{
    my $self   = shift ;
    my $out_data = shift ;

    if (defined *$self->{FH}) {
        # flush needed for 5.8.0 
        defined *$self->{FH}->write($out_data, length $out_data) &&
        defined *$self->{FH}->flush() ;
    }
    else {
       my $buf = *$self->{Buffer} ;
       substr($$buf, *$self->{BufferOffset}, length $out_data) = $out_data ;
       *$self->{BufferOffset} += length($out_data) ;
       return 1;
    }
}

sub smartReadExact
{
    return $_[0]->smartRead($_[1], $_[2]) == $_[2];
}

sub smartEof
{
    my ($self) = $_[0];
    local $.; 

    return 0 if length *$self->{Prime} || *$self->{PushMode};

    if (defined *$self->{FH})
    {
        # Could use
        #
        #  *$self->{FH}->eof() 
        #
        # here, but this can cause trouble if
        # the filehandle is itself a tied handle, but it uses sysread.
        # Then we get into mixing buffered & non-buffered IO, which will cause trouble

        my $info = $self->getErrInfo();
        
        my $buffer = '';
        my $status = $self->smartRead(\$buffer, 1);
        $self->pushBack($buffer) if length $buffer;
        $self->setErrInfo($info);
        
        return $status == 0 ;
    }
    elsif (defined *$self->{InputEvent})
     { *$self->{EventEof} }
    else 
     { *$self->{BufferOffset} >= length(${ *$self->{Buffer} }) }
}

sub clearError
{
    my $self   = shift ;

    *$self->{ErrorNo}  =  0 ;
    ${ *$self->{Error} } = '' ;
}

sub getErrInfo
{
    my $self   = shift ;

    return [ *$self->{ErrorNo}, ${ *$self->{Error} } ] ;
}

sub setErrInfo
{
    my $self   = shift ;
    my $ref    = shift;

    *$self->{ErrorNo}  =  $ref->[0] ;
    ${ *$self->{Error} } = $ref->[1] ;
}

sub saveStatus
{
    my $self   = shift ;
    my $errno = shift() + 0 ;
    #return $errno unless $errno || ! defined *$self->{ErrorNo};
    #return $errno unless $errno ;

    *$self->{ErrorNo}  = $errno;
    ${ *$self->{Error} } = '' ;

    return *$self->{ErrorNo} ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;

    #return $retval if ${ *$self->{Error} };

    ${ *$self->{Error} } = shift ;
    *$self->{ErrorNo} = shift() + 0 if @_ ;

    #warn "saveErrorString: " . ${ *$self->{Error} } . " " . *$self->{Error} . "\n" ;
    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    croak $_[0];
}


sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}

sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return *$self->{ErrorNo};
}

sub HeaderError
{
    my ($self) = shift;
    return $self->saveErrorString(undef, "Header Error: $_[0]", STATUS_ERROR);
}

sub TrailerError
{
    my ($self) = shift;
    return $self->saveErrorString(G_ERR, "Trailer Error: $_[0]", STATUS_ERROR);
}

sub TruncatedHeader
{
    my ($self) = shift;
    return $self->HeaderError("Truncated in $_[0] Section");
}

sub TruncatedTrailer
{
    my ($self) = shift;
    return $self->TrailerError("Truncated in $_[0] Section");
}

sub postCheckParams
{
    return 1;
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();
    
    my $Valid = {
                    'BlockSize'     => [1, 1, Parse_unsigned, 16 * 1024],
                    'AutoClose'     => [1, 1, Parse_boolean,  0],
                    'Strict'        => [1, 1, Parse_boolean,  0],
                    'Append'        => [1, 1, Parse_boolean,  0],
                    'Prime'         => [1, 1, Parse_any,      undef],
                    'MultiStream'   => [1, 1, Parse_boolean,  0],
                    'Transparent'   => [1, 1, Parse_any,      1],
                    'Scan'          => [1, 1, Parse_boolean,  0],
                    'InputLength'   => [1, 1, Parse_unsigned, undef],
                    'BinModeOut'    => [1, 1, Parse_boolean,  0],
                    #'Encode'        => [1, 1, Parse_any,       undef],

                   #'ConsumeInput'  => [1, 1, Parse_boolean,  0],

                    $self->getExtraParams(),

                    #'Todo - Revert to ordinary file on end Z_STREAM_END'=> 0,
                    # ContinueAfterEof
                } ;

    $Valid->{TrailingData} = [1, 1, Parse_writable_scalar, undef]
        if  *$self->{OneShot} ;
        
    $got->parse($Valid, @_ ) 
        or $self->croakError("${class}: $got->{Error}")  ;

    $self->postCheckParams($got) 
        or $self->croakError("${class}: " . $self->error())  ;

    return $got;
}

sub _create
{
    my $obj = shift;
    my $got = shift;
    my $append_mode = shift ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Input parameter")
        if ! @_ && ! $got ;

    my $inValue = shift ;

    *$obj->{OneShot}           = 0 ;

    if (! $got)
    {
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $inType  = whatIsInput($inValue, 1);

    $obj->ckInputParam($class, $inValue, 1) 
        or return undef ;

    *$obj->{InNew} = 1;

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . *$obj->{Error});

    if ($inType eq 'buffer' || $inType eq 'code') {
        *$obj->{Buffer} = $inValue ;        
        *$obj->{InputEvent} = $inValue 
           if $inType eq 'code' ;
    }
    else {
        if ($inType eq 'handle') {
            *$obj->{FH} = $inValue ;
            *$obj->{Handle} = 1 ;

            # Need to rewind for Scan
            *$obj->{FH}->seek(0, SEEK_SET) 
                if $got->value('Scan');
        }  
        else {    
            no warnings ;
            my $mode = '<';
            $mode = '+<' if $got->value('Scan');
            *$obj->{StdIO} = ($inValue eq '-');
            *$obj->{FH} = new IO::File "$mode $inValue"
                or return $obj->saveErrorString(undef, "cannot open file '$inValue': $!", $!) ;
        }
        
        *$obj->{LineNo} = $. = 0;
        setBinModeInput(*$obj->{FH}) ;

        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    if ($got->parsed('Encode')) { 
        my $want_encoding = $got->value('Encode');
        *$obj->{Encoding} = getEncoding($obj, $class, $want_encoding);
    }


    *$obj->{InputLength}       = $got->parsed('InputLength') 
                                    ? $got->value('InputLength')
                                    : undef ;
    *$obj->{InputLengthRemaining} = $got->value('InputLength');
    *$obj->{BufferOffset}      = 0 ;
    *$obj->{AutoClose}         = $got->value('AutoClose');
    *$obj->{Strict}            = $got->value('Strict');
    *$obj->{BlockSize}         = $got->value('BlockSize');
    *$obj->{Append}            = $got->value('Append');
    *$obj->{AppendOutput}      = $append_mode || $got->value('Append');
    *$obj->{ConsumeInput}      = $got->value('ConsumeInput');
    *$obj->{Transparent}       = $got->value('Transparent');
    *$obj->{MultiStream}       = $got->value('MultiStream');

    # TODO - move these two into RawDeflate
    *$obj->{Scan}              = $got->value('Scan');
    *$obj->{ParseExtra}        = $got->value('ParseExtra') 
                                  || $got->value('Strict')  ;
    *$obj->{Type}              = '';
    *$obj->{Prime}             = $got->value('Prime') || '' ;
    *$obj->{Pending}           = '';
    *$obj->{Plain}             = 0;
    *$obj->{PlainBytesRead}    = 0;
    *$obj->{InflatedBytesRead} = 0;
    *$obj->{UnCompSize}        = new U64;
    *$obj->{CompSize}          = new U64;
    *$obj->{TotalInflatedBytesRead} = 0;
    *$obj->{NewStream}         = 0 ;
    *$obj->{EventEof}          = 0 ;
    *$obj->{ClassName}         = $class ;
    *$obj->{Params}            = $got ;

    if (*$obj->{ConsumeInput}) {
        *$obj->{InNew} = 0;
        *$obj->{Closed} = 0;
        return $obj
    }

    my $status = $obj->mkUncomp($got);

    return undef
        unless defined $status;

    if ( !  $status) {
        return undef 
            unless *$obj->{Transparent};

        $obj->clearError();
        *$obj->{Type} = 'plain';
        *$obj->{Plain} = 1;
        #$status = $obj->mkIdentityUncomp($class, $got);
        $obj->pushBack(*$obj->{HeaderPending})  ;
    }

    push @{ *$obj->{InfoList} }, *$obj->{Info} ;

    $obj->saveStatus(STATUS_OK) ;
    *$obj->{InNew} = 0;
    *$obj->{Closed} = 0;

    return $obj;
}

sub ckInputParam
{
    my $self = shift ;
    my $from = shift ;
    my $inType = whatIsInput($_[0], $_[1]);

    $self->croakError("$from: input parameter not a filename, filehandle, array ref or scalar ref")
        if ! $inType ;

#    if ($inType  eq 'filename' )
#    {
#        return $self->saveErrorString(1, "$from: input filename is undef or null string", STATUS_ERROR)
#            if ! defined $_[0] || $_[0] eq ''  ;
#
#        if ($_[0] ne '-' && ! -e $_[0] )
#        {
#            return $self->saveErrorString(1, 
#                            "input file '$_[0]' does not exist", STATUS_ERROR);
#        }
#    }

    return 1;
}


sub _inf
{
    my $obj = shift ;

    my $class = (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;


    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;
    
    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;
    
    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    if ($got->parsed('TrailingData'))
    {
        *$obj->{TrailingData} = $got->value('TrailingData');
    }

    *$obj->{MultiStream} = $got->value('MultiStream');
    $got->value('MultiStream', 0);

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }
    
    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $in, $output, @_)
                or return undef ;
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, $input, $output, @_);

    croak "should not be here" ;
}

sub retErr
{
    my $x = shift ;
    my $string = shift ;

    ${ $x->{Error} } = $string ;

    return undef ;
}

sub _singleTarget
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
    
    my $buff = '';
    $x->{buff} = \$buff ;

    my $fh ;
    if ($x->{outType} eq 'filename') {
        my $mode = '>' ;
        $mode = '>>'
            if $x->{Got}->value('Append') ;
        $x->{fh} = new IO::File "$mode $output" 
            or return retErr($x, "cannot open file '$output': $!") ;
        binmode $x->{fh} if $x->{Got}->valueOrDefault('BinModeOut');

    }

    elsif ($x->{outType} eq 'handle') {
        $x->{fh} = $output;
        binmode $x->{fh} if $x->{Got}->valueOrDefault('BinModeOut');
        if ($x->{Got}->value('Append')) {
                seek($x->{fh}, 0, SEEK_END)
                    or return retErr($x, "Cannot seek to end of output filehandle: $!") ;
            }
    }

    
    elsif ($x->{outType} eq 'buffer' )
    {
        $$output = '' 
            unless $x->{Got}->value('Append');
        $x->{buff} = $output ;
    }

    if ($x->{oneInput})
    {
        defined $self->_rd2($x, $input, $output)
            or return undef; 
    }
    else
    {
        for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        {
            defined $self->_rd2($x, $element, $output) 
                or return undef ;
        }
    }


    if ( ($x->{outType} eq 'filename' && $output ne '-') || 
         ($x->{outType} eq 'handle' && $x->{Got}->value('AutoClose'))) {
        $x->{fh}->close() 
            or return retErr($x, $!); 
        delete $x->{fh};
    }

    return 1 ;
}

sub _rd2
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
        
    my $z = createSelfTiedObject($x->{Class}, *$self->{Error});
    
    $z->_create($x->{Got}, 1, $input, @_)
        or return undef ;

    my $status ;
    my $fh = $x->{fh};
    
    while (1) {

        while (($status = $z->read($x->{buff})) > 0) {
            if ($fh) {
                print $fh ${ $x->{buff} }
                    or return $z->saveErrorString(undef, "Error writing to output file: $!", $!);
                ${ $x->{buff} } = '' ;
            }
        }

        if (! $x->{oneOutput} ) {
            my $ot = $x->{outType} ;

            if ($ot eq 'array') 
              { push @$output, $x->{buff} }
            elsif ($ot eq 'hash') 
              { $output->{$input} = $x->{buff} }

            my $buff = '';
            $x->{buff} = \$buff;
        }

        last if $status < 0 || $z->smartEof();
        #last if $status < 0 ;

        last 
            unless *$self->{MultiStream};

        $status = $z->nextStream();

        last 
            unless $status == 1 ;
    }

    return $z->closeError(undef)
        if $status < 0 ;

    ${ *$self->{TrailingData} } = $z->trailingData()
        if defined *$self->{TrailingData} ;

    $z->close() 
        or return undef ;

    return 1 ;
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;

}
  
sub UNTIE
{
    my $self = shift ;
}


sub getHeaderInfo
{
    my $self = shift ;
    wantarray ? @{ *$self->{InfoList} } : *$self->{Info};
}

sub readBlock
{
    my $self = shift ;
    my $buff = shift ;
    my $size = shift ;

    if (defined *$self->{CompressedInputLength}) {
        if (*$self->{CompressedInputLengthRemaining} == 0) {
            delete *$self->{CompressedInputLength};
            *$self->{CompressedInputLengthDone} = 1;
            return STATUS_OK ;
        }
        $size = min($size, *$self->{CompressedInputLengthRemaining} );
        *$self->{CompressedInputLengthRemaining} -= $size ;
    }
    
    my $status = $self->smartRead($buff, $size) ;
    return $self->saveErrorString(STATUS_ERROR, "Error Reading Data")
        if $status < 0  ;

    if ($status == 0 ) {
        *$self->{Closed} = 1 ;
        *$self->{EndStream} = 1 ;
        return $self->saveErrorString(STATUS_ERROR, "unexpected end of file", STATUS_ERROR);
    }

    return STATUS_OK;
}

sub postBlockChk
{
    return STATUS_OK;
}

sub _raw_read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    return G_EOF if *$self->{Closed} ;
    #return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;
    return G_EOF if *$self->{EndStream} ;

    my $buffer = shift ;
    my $scan_mode = shift ;

    if (*$self->{Plain}) {
        my $tmp_buff ;
        my $len = $self->smartRead(\$tmp_buff, *$self->{BlockSize}) ;
        
        return $self->saveErrorString(G_ERR, "Error reading data: $!", $!) 
                if $len < 0 ;

        if ($len == 0 ) {
            *$self->{EndStream} = 1 ;
        }
        else {
            *$self->{PlainBytesRead} += $len ;
            $$buffer .= $tmp_buff;
        }

        return $len ;
    }

    if (*$self->{NewStream}) {

        $self->gotoNextStream() > 0
            or return G_ERR;

        # For the headers that actually uncompressed data, put the
        # uncompressed data into the output buffer.
        $$buffer .=  *$self->{Pending} ;
        my $len = length  *$self->{Pending} ;
        *$self->{Pending} = '';
        return $len; 
    }

    my $temp_buf = '';
    my $outSize = 0;
    my $status = $self->readBlock(\$temp_buf, *$self->{BlockSize}, $outSize) ;
    return G_ERR
        if $status == STATUS_ERROR  ;

    my $buf_len = 0;
    if ($status == STATUS_OK) {
        my $beforeC_len = length $temp_buf;
        my $before_len = defined $$buffer ? length $$buffer : 0 ;
        $status = *$self->{Uncomp}->uncompr(\$temp_buf, $buffer,
                                    defined *$self->{CompressedInputLengthDone} ||
                                                $self->smartEof(), $outSize);
                                                
        # Remember the input buffer if it wasn't consumed completely
        $self->pushBack($temp_buf) if *$self->{Uncomp}{ConsumesInput};

        return $self->saveErrorString(G_ERR, *$self->{Uncomp}{Error}, *$self->{Uncomp}{ErrorNo})
            if $self->saveStatus($status) == STATUS_ERROR;    

        $self->postBlockChk($buffer, $before_len) == STATUS_OK
            or return G_ERR;

        $buf_len = defined $$buffer ? length($$buffer) - $before_len : 0;
    
        *$self->{CompSize}->add($beforeC_len - length $temp_buf) ;

        *$self->{InflatedBytesRead} += $buf_len ;
        *$self->{TotalInflatedBytesRead} += $buf_len ;
        *$self->{UnCompSize}->add($buf_len) ;

        $self->filterUncompressed($buffer);

        if (*$self->{Encoding}) {
            $$buffer = *$self->{Encoding}->decode($$buffer);
        }
    }

    if ($status == STATUS_ENDSTREAM) {

        *$self->{EndStream} = 1 ;
#$self->pushBack($temp_buf)  ;
#$temp_buf = '';

        my $trailer;
        my $trailer_size = *$self->{Info}{TrailerLength} ;
        my $got = 0;
        if (*$self->{Info}{TrailerLength})
        {
            $got = $self->smartRead(\$trailer, $trailer_size) ;
        }

        if ($got == $trailer_size) {
            $self->chkTrailer($trailer) == STATUS_OK
                or return G_ERR;
        }
        else {
            return $self->TrailerError("trailer truncated. Expected " . 
                                      "$trailer_size bytes, got $got")
                if *$self->{Strict};
            $self->pushBack($trailer)  ;
        }

        # TODO - if want to file file pointer, do it here

        if (! $self->smartEof()) {
            *$self->{NewStream} = 1 ;

            if (*$self->{MultiStream}) {
                *$self->{EndStream} = 0 ;
                return $buf_len ;
            }
        }

    }
    

    # return the number of uncompressed bytes read
    return $buf_len ;
}

sub reset
{
    my $self = shift ;

    return *$self->{Uncomp}->reset();
}

sub filterUncompressed
{
}

#sub isEndStream
#{
#    my $self = shift ;
#    return *$self->{NewStream} ||
#           *$self->{EndStream} ;
#}

sub nextStream
{
    my $self = shift ;

    my $status = $self->gotoNextStream();
    $status == 1
        or return $status ;

    *$self->{TotalInflatedBytesRead} = 0 ;
    *$self->{LineNo} = $. = 0;

    return 1;
}

sub gotoNextStream
{
    my $self = shift ;

    if (! *$self->{NewStream}) {
        my $status = 1;
        my $buffer ;

        # TODO - make this more efficient if know the offset for the end of
        # the stream and seekable
        $status = $self->read($buffer) 
            while $status > 0 ;

        return $status
            if $status < 0;
    }

    *$self->{NewStream} = 0 ;
    *$self->{EndStream} = 0 ;
    $self->reset();
    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    my $magic = $self->ckMagic();
    #*$self->{EndStream} = 0 ;

    if ( ! defined $magic) {
        if (! *$self->{Transparent} || $self->eof())
        {
            *$self->{EndStream} = 1 ;
            return 0;
        }

        $self->clearError();
        *$self->{Type} = 'plain';
        *$self->{Plain} = 1;
        $self->pushBack(*$self->{HeaderPending})  ;
    }
    else
    {
        *$self->{Info} = $self->readHeader($magic);

        if ( ! defined *$self->{Info} ) {
            *$self->{EndStream} = 1 ;
            return -1;
        }
    }

    push @{ *$self->{InfoList} }, *$self->{Info} ;

    return 1; 
}

sub streamCount
{
    my $self = shift ;
    return 1 if ! defined *$self->{InfoList};
    return scalar @{ *$self->{InfoList} }  ;
}

sub read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    return G_EOF if *$self->{Closed} ;

    my $buffer ;

    if (ref $_[0] ) {
        $self->croakError(*$self->{ClassName} . "::read: buffer parameter is read-only")
            if readonly(${ $_[0] });

        $self->croakError(*$self->{ClassName} . "::read: not a scalar reference $_[0]" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::read: buffer parameter is read-only")
            if readonly($_[0]);

        $buffer = \$_[0] ;
    }

    my $length = $_[1] ;
    my $offset = $_[2] || 0;

    if (! *$self->{AppendOutput}) {
        if (! $offset) {    
            $$buffer = '' ;
        }
        else {
            if ($offset > length($$buffer)) {
                $$buffer .= "\x00" x ($offset - length($$buffer));
            }
            else {
                substr($$buffer, $offset) = '';
            }
        }
    }

    return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;

    # the core read will return 0 if asked for 0 bytes
    return 0 if defined $length && $length == 0 ;

    $length = $length || 0;

    $self->croakError(*$self->{ClassName} . "::read: length parameter is negative")
        if $length < 0 ;

    # Short-circuit if this is a simple read, with no length
    # or offset specified.
    unless ( $length || $offset) {
        if (length *$self->{Pending}) {
            $$buffer .= *$self->{Pending} ;
            my $len = length *$self->{Pending};
            *$self->{Pending} = '' ;
            return $len ;
        }
        else {
            my $len = 0;
            $len = $self->_raw_read($buffer) 
                while ! *$self->{EndStream} && $len == 0 ;
            return $len ;
        }
    }

    # Need to jump through more hoops - either length or offset 
    # or both are specified.
    my $out_buffer = *$self->{Pending} ;
    *$self->{Pending} = '';


    while (! *$self->{EndStream} && length($out_buffer) < $length)
    {
        my $buf_len = $self->_raw_read(\$out_buffer);
        return $buf_len 
            if $buf_len < 0 ;
    }

    $length = length $out_buffer 
        if length($out_buffer) < $length ;

    return 0 
        if $length == 0 ;

    $$buffer = '' 
        if ! defined $$buffer;

    $offset = length $$buffer
        if *$self->{AppendOutput} ;

    *$self->{Pending} = $out_buffer;
    $out_buffer = \*$self->{Pending} ;

    #substr($$buffer, $offset) = substr($$out_buffer, 0, $length, '') ;
    substr($$buffer, $offset) = substr($$out_buffer, 0, $length) ;
    substr($$out_buffer, 0, $length) =  '' ;

    return $length ;
}

sub _getline
{
    my $self = shift ;

    # Slurp Mode
    if ( ! defined $/ ) {
        my $data ;
        1 while $self->read($data) > 0 ;
        return \$data ;
    }

    # Record Mode
    if ( ref $/ eq 'SCALAR' && ${$/} =~ /^\d+$/ && ${$/} > 0) {
        my $reclen = ${$/} ;
        my $data ;
        $self->read($data, $reclen) ;
        return \$data ;
    }

    # Paragraph Mode
    if ( ! length $/ ) {
        my $paragraph ;    
        while ($self->read($paragraph) > 0 ) {
            if ($paragraph =~ s/^(.*?\n\n+)//s) {
                *$self->{Pending}  = $paragraph ;
                my $par = $1 ;
                return \$par ;
            }
        }
        return \$paragraph;
    }

    # $/ isn't empty, or a reference, so it's Line Mode.
    {
        my $line ;    
        my $offset;
        my $p = \*$self->{Pending}  ;

        if (length(*$self->{Pending}) && 
                    ($offset = index(*$self->{Pending}, $/)) >=0) {
            my $l = substr(*$self->{Pending}, 0, $offset + length $/ );
            substr(*$self->{Pending}, 0, $offset + length $/) = '';    
            return \$l;
        }

        while ($self->read($line) > 0 ) {
            my $offset = index($line, $/);
            if ($offset >= 0) {
                my $l = substr($line, 0, $offset + length $/ );
                substr($line, 0, $offset + length $/) = '';    
                $$p = $line;
                return \$l;
            }
        }

        return \$line;
    }
}

sub getline
{
    my $self = shift;
    my $current_append = *$self->{AppendOutput} ;
    *$self->{AppendOutput} = 1;
    my $lineref = $self->_getline();
    $. = ++ *$self->{LineNo} if defined $$lineref ;
    *$self->{AppendOutput} = $current_append;
    return $$lineref ;
}

sub getlines
{
    my $self = shift;
    $self->croakError(*$self->{ClassName} . 
            "::getlines: called in scalar context\n") unless wantarray;
    my($line, @lines);
    push(@lines, $line) 
        while defined($line = $self->getline);
    return @lines;
}

sub READLINE
{
    goto &getlines if wantarray;
    goto &getline;
}

sub getc
{
    my $self = shift;
    my $buf;
    return $buf if $self->read($buf, 1);
    return undef;
}

sub ungetc
{
    my $self = shift;
    *$self->{Pending} = ""  unless defined *$self->{Pending} ;    
    *$self->{Pending} = $_[0] . *$self->{Pending} ;    
}


sub trailingData
{
    my $self = shift ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        return *$self->{Prime} ;
    }
    else {
        my $buf = *$self->{Buffer} ;
        my $offset = *$self->{BufferOffset} ;
        return substr($$buf, $offset) ;
    }
}


sub eof
{
    my $self = shift ;

    return (*$self->{Closed} ||
              (!length *$self->{Pending} 
                && ( $self->smartEof() || *$self->{EndStream}))) ;
}

sub tell
{
    my $self = shift ;

    my $in ;
    if (*$self->{Plain}) {
        $in = *$self->{PlainBytesRead} ;
    }
    else {
        $in = *$self->{TotalInflatedBytesRead} ;
    }

    my $pending = length *$self->{Pending} ;

    return 0 if $pending > $in ;
    return $in - $pending ;
}

sub close
{
    # todo - what to do if close is called before the end of the gzip file
    #        do we remember any trailing data?
    my $self = shift ;

    return 1 if *$self->{Closed} ;

    untie *$self 
        if $] >= 5.008 ;

    my $status = 1 ;

    if (defined *$self->{FH}) {
        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
        #if ( *$self->{AutoClose}) {
            local $.; 
            $! = 0 ;
            $status = *$self->{FH}->close();
            return $self->saveErrorString(0, $!, $!)
                if !*$self->{InNew} && $self->saveStatus($!) != 0 ;
        }
        delete *$self->{FH} ;
        $! = 0 ;
    }
    *$self->{Closed} = 1 ;

    return 1;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);

    $self->close() ;
}

sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;


    if ($whence == SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == SEEK_CUR) {
        $target = $here + $position ;
    }
    elsif ($whence == SEEK_END) {
        $target = $position ;
        $self->croakError(*$self->{ClassName} . "::seek: SEEK_END not allowed") ;
    }
    else {
        $self->croakError(*$self->{ClassName} ."::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    if ($target == $here) {
        # On ordinary filehandles, seeking to the current
        # position also clears the EOF condition, so we
        # emulate this behavior locally while simultaneously
        # cascading it to the underlying filehandle
        if (*$self->{Plain}) {
            *$self->{EndStream} = 0;
            seek(*$self->{FH},0,1) if *$self->{FH};
        }
        return 1;
    }

    # Outlaw any attempt to seek backwards
    $self->croakError( *$self->{ClassName} ."::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $got;
    while (($got = $self->read(my $buffer, min($offset, *$self->{BlockSize})) ) > 0)
    {
        $offset -= $got;
        last if $offset == 0 ;
    }

    $here = $self->tell() ;
    return $offset == 0 ? 1 : 0 ;
}

sub fileno
{
    my $self = shift ;
    return defined *$self->{FH} 
           ? fileno *$self->{FH} 
           : undef ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH} 
#            ? binmode *$self->{FH} 
#            : 1 ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->autoflush(@_) 
            : undef ;
}

sub input_line_number
{
    my $self = shift ;
    my $last = *$self->{LineNo};
    $. = *$self->{LineNo} = $_[1] if @_ ;
    return $last;
}


*BINMODE  = \&binmode;
*SEEK     = \&seek; 
*READ     = \&read;
*sysread  = \&read;
*TELL     = \&tell;
*EOF      = \&eof;

*FILENO   = \&fileno;
*CLOSE    = \&close;

sub _notAvailable
{
    my $name = shift ;
    #return sub { croak "$name Not Available" ; } ;
    return sub { croak "$name Not Available: File opened only for intput" ; } ;
}


*print    = _notAvailable('print');
*PRINT    = _notAvailable('print');
*printf   = _notAvailable('printf');
*PRINTF   = _notAvailable('printf');
*write    = _notAvailable('write');
*WRITE    = _notAvailable('write');

#*sysread  = \&read;
#*syswrite = \&_notAvailable;



package IO::Uncompress::Base ;


1 ;
__END__

#line 1475
FILE    3e3930ea/IO/Uncompress/Gunzip.pm  #line 1 "/usr/lib64/perl5/IO/Uncompress/Gunzip.pm"

package IO::Uncompress::Gunzip ;

require 5.004 ;

# for RFC1952

use strict ;
use warnings;
use bytes;

use IO::Uncompress::RawInflate 2.021 ;

use Compress::Raw::Zlib 2.021 qw( crc32 ) ;
use IO::Compress::Base::Common 2.021 qw(:Status createSelfTiedObject);
use IO::Compress::Gzip::Constants 2.021 ;
use IO::Compress::Zlib::Extra 2.021 ;

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $GunzipError);

@ISA = qw( Exporter IO::Uncompress::RawInflate );
@EXPORT_OK = qw( $GunzipError gunzip );
%EXPORT_TAGS = %IO::Uncompress::RawInflate::DEFLATE_CONSTANTS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

$GunzipError = '';

$VERSION = '2.021';

sub new
{
    my $class = shift ;
    $GunzipError = '';
    my $obj = createSelfTiedObject($class, \$GunzipError);

    $obj->_create(undef, 0, @_);
}

sub gunzip
{
    my $obj = createSelfTiedObject(undef, \$GunzipError);
    return $obj->_inf(@_) ;
}

sub getExtraParams
{
    use IO::Compress::Base::Common  2.021 qw(:Parse);
    return ( 'ParseExtra' => [1, 1, Parse_boolean,  0] ) ;
}

sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gunzip always needs crc32
    $got->value('CRC32' => 1);

    return 1;
}

sub ckMagic
{
    my $self = shift;

    my $magic ;
    $self->smartReadExact(\$magic, GZIP_ID_SIZE);

    *$self->{HeaderPending} = $magic ;

    return $self->HeaderError("Minimum header size is " . 
                              GZIP_MIN_HEADER_SIZE . " bytes") 
        if length $magic != GZIP_ID_SIZE ;                                    

    return $self->HeaderError("Bad Magic")
        if ! isGzipMagic($magic) ;

    *$self->{Type} = 'rfc1952';

    return $magic ;
}

sub readHeader
{
    my $self = shift;
    my $magic = shift;

    return $self->_readGzipHeader($magic);
}

sub chkTrailer
{
    my $self = shift;
    my $trailer = shift;

    # Check CRC & ISIZE 
    my ($CRC32, $ISIZE) = unpack("V V", $trailer) ;
    *$self->{Info}{CRC32} = $CRC32;    
    *$self->{Info}{ISIZE} = $ISIZE;    

    if (*$self->{Strict}) {
        return $self->TrailerError("CRC mismatch")
            if $CRC32 != *$self->{Uncomp}->crc32() ;

        my $exp_isize = *$self->{UnCompSize}->get32bit();
        return $self->TrailerError("ISIZE mismatch. Got $ISIZE"
                                  . ", expected $exp_isize")
            if $ISIZE != $exp_isize ;
    }

    return STATUS_OK;
}

sub isGzipMagic
{
    my $buffer = shift ;
    return 0 if length $buffer < GZIP_ID_SIZE ;
    my ($id1, $id2) = unpack("C C", $buffer) ;
    return $id1 == GZIP_ID1 && $id2 == GZIP_ID2 ;
}

sub _readFullGzipHeader($)
{
    my ($self) = @_ ;
    my $magic = '' ;

    $self->smartReadExact(\$magic, GZIP_ID_SIZE);

    *$self->{HeaderPending} = $magic ;

    return $self->HeaderError("Minimum header size is " . 
                              GZIP_MIN_HEADER_SIZE . " bytes") 
        if length $magic != GZIP_ID_SIZE ;                                    


    return $self->HeaderError("Bad Magic")
        if ! isGzipMagic($magic) ;

    my $status = $self->_readGzipHeader($magic);
    delete *$self->{Transparent} if ! defined $status ;
    return $status ;
}

sub _readGzipHeader($)
{
    my ($self, $magic) = @_ ;
    my ($HeaderCRC) ;
    my ($buffer) = '' ;

    $self->smartReadExact(\$buffer, GZIP_MIN_HEADER_SIZE - GZIP_ID_SIZE)
        or return $self->HeaderError("Minimum header size is " . 
                                     GZIP_MIN_HEADER_SIZE . " bytes") ;

    my $keep = $magic . $buffer ;
    *$self->{HeaderPending} = $keep ;

    # now split out the various parts
    my ($cm, $flag, $mtime, $xfl, $os) = unpack("C C V C C", $buffer) ;

    $cm == GZIP_CM_DEFLATED 
        or return $self->HeaderError("Not Deflate (CM is $cm)") ;

    # check for use of reserved bits
    return $self->HeaderError("Use of Reserved Bits in FLG field.")
        if $flag & GZIP_FLG_RESERVED ; 

    my $EXTRA ;
    my @EXTRA = () ;
    if ($flag & GZIP_FLG_FEXTRA) {
        $EXTRA = "" ;
        $self->smartReadExact(\$buffer, GZIP_FEXTRA_HEADER_SIZE) 
            or return $self->TruncatedHeader("FEXTRA Length") ;

        my ($XLEN) = unpack("v", $buffer) ;
        $self->smartReadExact(\$EXTRA, $XLEN) 
            or return $self->TruncatedHeader("FEXTRA Body");
        $keep .= $buffer . $EXTRA ;

        if ($XLEN && *$self->{'ParseExtra'}) {
            my $bad = IO::Compress::Zlib::Extra::parseRawExtra($EXTRA,
                                                \@EXTRA, 1, 1);
            return $self->HeaderError($bad)
                if defined $bad;
        }
    }

    my $origname ;
    if ($flag & GZIP_FLG_FNAME) {
        $origname = "" ;
        while (1) {
            $self->smartReadExact(\$buffer, 1) 
                or return $self->TruncatedHeader("FNAME");
            last if $buffer eq GZIP_NULL_BYTE ;
            $origname .= $buffer 
        }
        $keep .= $origname . GZIP_NULL_BYTE ;

        return $self->HeaderError("Non ISO 8859-1 Character found in Name")
            if *$self->{Strict} && $origname =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
    }

    my $comment ;
    if ($flag & GZIP_FLG_FCOMMENT) {
        $comment = "";
        while (1) {
            $self->smartReadExact(\$buffer, 1) 
                or return $self->TruncatedHeader("FCOMMENT");
            last if $buffer eq GZIP_NULL_BYTE ;
            $comment .= $buffer 
        }
        $keep .= $comment . GZIP_NULL_BYTE ;

        return $self->HeaderError("Non ISO 8859-1 Character found in Comment")
            if *$self->{Strict} && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o ;
    }

    if ($flag & GZIP_FLG_FHCRC) {
        $self->smartReadExact(\$buffer, GZIP_FHCRC_SIZE) 
            or return $self->TruncatedHeader("FHCRC");

        $HeaderCRC = unpack("v", $buffer) ;
        my $crc16 = crc32($keep) & 0xFF ;

        return $self->HeaderError("CRC16 mismatch.")
            if *$self->{Strict} && $crc16 != $HeaderCRC;

        $keep .= $buffer ;
    }

    # Assume compression method is deflated for xfl tests
    #if ($xfl) {
    #}

    *$self->{Type} = 'rfc1952';

    return {
        'Type'          => 'rfc1952',
        'FingerprintLength'  => 2,
        'HeaderLength'  => length $keep,
        'TrailerLength' => GZIP_TRAILER_SIZE,
        'Header'        => $keep,
        'isMinimalHeader' => $keep eq GZIP_MINIMUM_HEADER ? 1 : 0,

        'MethodID'      => $cm,
        'MethodName'    => $cm == GZIP_CM_DEFLATED ? "Deflated" : "Unknown" ,
        'TextFlag'      => $flag & GZIP_FLG_FTEXT ? 1 : 0,
        'HeaderCRCFlag' => $flag & GZIP_FLG_FHCRC ? 1 : 0,
        'NameFlag'      => $flag & GZIP_FLG_FNAME ? 1 : 0,
        'CommentFlag'   => $flag & GZIP_FLG_FCOMMENT ? 1 : 0,
        'ExtraFlag'     => $flag & GZIP_FLG_FEXTRA ? 1 : 0,
        'Name'          => $origname,
        'Comment'       => $comment,
        'Time'          => $mtime,
        'OsID'          => $os,
        'OsName'        => defined $GZIP_OS_Names{$os} 
                                 ? $GZIP_OS_Names{$os} : "Unknown",
        'HeaderCRC'     => $HeaderCRC,
        'Flags'         => $flag,
        'ExtraFlags'    => $xfl,
        'ExtraFieldRaw' => $EXTRA,
        'ExtraField'    => [ @EXTRA ],


        #'CompSize'=> $compsize,
        #'CRC32'=> $CRC32,
        #'OrigSize'=> $ISIZE,
      }
}


1;

__END__


#line 1071
FILE   $5052f099/IO/Uncompress/RawInflate.pm  "#line 1 "/usr/lib64/perl5/IO/Uncompress/RawInflate.pm"
package IO::Uncompress::RawInflate ;
# for RFC1951

use strict ;
use warnings;
use bytes;

use Compress::Raw::Zlib  2.021 ;
use IO::Compress::Base::Common  2.021 qw(:Status createSelfTiedObject);

use IO::Uncompress::Base  2.021 ;
use IO::Uncompress::Adapter::Inflate  2.021 ;

require Exporter ;
our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, %DEFLATE_CONSTANTS, $RawInflateError);

$VERSION = '2.021';
$RawInflateError = '';

@ISA    = qw( Exporter IO::Uncompress::Base );
@EXPORT_OK = qw( $RawInflateError rawinflate ) ;
%DEFLATE_CONSTANTS = ();
%EXPORT_TAGS = %IO::Uncompress::Base::EXPORT_TAGS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

#{
#    # Execute at runtime  
#    my %bad;
#    for my $module (qw(Compress::Raw::Zlib IO::Compress::Base::Common IO::Uncompress::Base IO::Uncompress::Adapter::Inflate))
#    {
#        my $ver = ${ $module . "::VERSION"} ;
#        
#        $bad{$module} = $ver
#            if $ver ne $VERSION;
#    }
#    
#    if (keys %bad)
#    {
#        my $string = join "\n", map { "$_ $bad{$_}" } keys %bad;
#        die caller(0)[0] . "needs version $VERSION mismatch\n$string\n";
#    }
#}

sub new
{
    my $class = shift ;
    my $obj = createSelfTiedObject($class, \$RawInflateError);
    $obj->_create(undef, 0, @_);
}

sub rawinflate
{
    my $obj = createSelfTiedObject(undef, \$RawInflateError);
    return $obj->_inf(@_);
}

sub getExtraParams
{
    return ();
}

sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    return 1;
}

sub mkUncomp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Uncompress::Adapter::Inflate::mkUncompObject(
                                                                $got->value('CRC32'),
                                                                $got->value('ADLER32'),
                                                                $got->value('Scan'),
                                                            );

    return $self->saveErrorString(undef, $errstr, $errno)
        if ! defined $obj;

    *$self->{Uncomp} = $obj;

     my $magic = $self->ckMagic()
        or return 0;

    *$self->{Info} = $self->readHeader($magic)
        or return undef ;

    return 1;

}


sub ckMagic
{
    my $self = shift;

    return $self->_isRaw() ;
}

sub readHeader
{
    my $self = shift;
    my $magic = shift ;

    return {
        'Type'          => 'rfc1951',
        'FingerprintLength'  => 0,
        'HeaderLength'  => 0,
        'TrailerLength' => 0,
        'Header'        => ''
        };
}

sub chkTrailer
{
    return STATUS_OK ;
}

sub _isRaw
{
    my $self   = shift ;

    my $got = $self->_isRawx(@_);

    if ($got) {
        *$self->{Pending} = *$self->{HeaderPending} ;
    }
    else {
        $self->pushBack(*$self->{HeaderPending});
        *$self->{Uncomp}->reset();
    }
    *$self->{HeaderPending} = '';

    return $got ;
}

sub _isRawx
{
    my $self   = shift ;
    my $magic = shift ;

    $magic = '' unless defined $magic ;

    my $buffer = '';

    $self->smartRead(\$buffer, *$self->{BlockSize}) >= 0  
        or return $self->saveErrorString(undef, "No data to read");

    my $temp_buf = $magic . $buffer ;
    *$self->{HeaderPending} = $temp_buf ;    
    $buffer = '';
    my $status = *$self->{Uncomp}->uncompr(\$temp_buf, \$buffer, $self->smartEof()) ;
    
    return $self->saveErrorString(undef, *$self->{Uncomp}{Error}, STATUS_ERROR)
        if $status == STATUS_ERROR;

    $self->pushBack($temp_buf)  ;

    return $self->saveErrorString(undef, "unexpected end of file", STATUS_ERROR)
        if $self->smartEof() && $status != STATUS_ENDSTREAM;
            
    #my $buf_len = *$self->{Uncomp}->uncompressedBytes();
    my $buf_len = length $buffer;

    if ($status == STATUS_ENDSTREAM) {
        if (*$self->{MultiStream} 
                    && (length $temp_buf || ! $self->smartEof())){
            *$self->{NewStream} = 1 ;
            *$self->{EndStream} = 0 ;
        }
        else {
            *$self->{EndStream} = 1 ;
        }
    }
    *$self->{HeaderPending} = $buffer ;    
    *$self->{InflatedBytesRead} = $buf_len ;    
    *$self->{TotalInflatedBytesRead} += $buf_len ;    
    *$self->{Type} = 'rfc1951';

    $self->saveStatus(STATUS_OK);

    return {
        'Type'          => 'rfc1951',
        'HeaderLength'  => 0,
        'TrailerLength' => 0,
        'Header'        => ''
        };
}


sub inflateSync
{
    my $self = shift ;

    # inflateSync is a no-op in Plain mode
    return 1
        if *$self->{Plain} ;

    return 0 if *$self->{Closed} ;
    #return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;
    return 0 if ! length *$self->{Pending} && *$self->{EndStream} ;

    # Disable CRC check
    *$self->{Strict} = 0 ;

    my $status ;
    while (1)
    {
        my $temp_buf ;

        if (length *$self->{Pending} )
        {
            $temp_buf = *$self->{Pending} ;
            *$self->{Pending} = '';
        }
        else
        {
            $status = $self->smartRead(\$temp_buf, *$self->{BlockSize}) ;
            return $self->saveErrorString(0, "Error Reading Data")
                if $status < 0  ;

            if ($status == 0 ) {
                *$self->{EndStream} = 1 ;
                return $self->saveErrorString(0, "unexpected end of file", STATUS_ERROR);
            }
        }
        
        $status = *$self->{Uncomp}->sync($temp_buf) ;

        if ($status == STATUS_OK)
        {
            *$self->{Pending} .= $temp_buf ;
            return 1 ;
        }

        last unless $status == STATUS_ERROR ;
    }

    return 0;
}

#sub performScan
#{
#    my $self = shift ;
#
#    my $status ;
#    my $end_offset = 0;
#
#    $status = $self->scan() 
#    #or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $self->errorNo) ;
#        or return $self->saveErrorString(G_ERR, "Error Scanning: $status")
#
#    $status = $self->zap($end_offset) 
#        or return $self->saveErrorString(G_ERR, "Error Zapping: $status");
#    #or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $self->errorNo) ;
#
#    #(*$obj->{Deflate}, $status) = $inf->createDeflate();
#
##    *$obj->{Header} = *$inf->{Info}{Header};
##    *$obj->{UnCompSize_32bit} = 
##        *$obj->{BytesWritten} = *$inf->{UnCompSize_32bit} ;
##    *$obj->{CompSize_32bit} = *$inf->{CompSize_32bit} ;
#
#
##    if ( $outType eq 'buffer') 
##      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
##    elsif ($outType eq 'handle' || $outType eq 'filename') {
##        *$self->{FH} = *$inf->{FH} ;
##        delete *$inf->{FH};
##        *$obj->{FH}->flush() ;
##        *$obj->{Handle} = 1 if $outType eq 'handle';
##
##        #seek(*$obj->{FH}, $end_offset, SEEK_SET) 
##        *$obj->{FH}->seek($end_offset, SEEK_SET) 
##            or return $obj->saveErrorString(undef, $!, $!) ;
##    }
#    
#}

sub scan
{
    my $self = shift ;

    return 1 if *$self->{Closed} ;
    return 1 if !length *$self->{Pending} && *$self->{EndStream} ;

    my $buffer = '' ;
    my $len = 0;

    $len = $self->_raw_read(\$buffer, 1) 
        while ! *$self->{EndStream} && $len >= 0 ;

    #return $len if $len < 0 ? $len : 0 ;
    return $len < 0 ? 0 : 1 ;
}

sub zap
{
    my $self  = shift ;

    my $headerLength = *$self->{Info}{HeaderLength};
    my $block_offset =  $headerLength + *$self->{Uncomp}->getLastBlockOffset();
    $_[0] = $headerLength + *$self->{Uncomp}->getEndOffset();
    #printf "# End $_[0], headerlen $headerLength \n";;
    #printf "# block_offset $block_offset %x\n", $block_offset;
    my $byte ;
    ( $self->smartSeek($block_offset) &&
      $self->smartRead(\$byte, 1) ) 
        or return $self->saveErrorString(0, $!, $!); 

    #printf "#byte is %x\n", unpack('C*',$byte);
    *$self->{Uncomp}->resetLastBlockByte($byte);
    #printf "#to byte is %x\n", unpack('C*',$byte);

    ( $self->smartSeek($block_offset) && 
      $self->smartWrite($byte) )
        or return $self->saveErrorString(0, $!, $!); 

    #$self->smartSeek($end_offset, 1);

    return 1 ;
}

sub createDeflate
{
    my $self  = shift ;
    my ($def, $status) = *$self->{Uncomp}->createDeflateStream(
                                    -AppendOutput   => 1,
                                    -WindowBits => - MAX_WBITS,
                                    -CRC32      => *$self->{Params}->value('CRC32'),
                                    -ADLER32    => *$self->{Params}->value('ADLER32'),
                                );
    
    return wantarray ? ($status, $def) : $def ;                                
}


1; 

__END__


#line 1070
FILE   acfd2bdd/MIME/Base64.pm  d#line 1 "/usr/lib64/perl5/MIME/Base64.pm"
package MIME::Base64;

use strict;
use vars qw(@ISA @EXPORT $VERSION);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(encode_base64 decode_base64);

$VERSION = '3.08';

require XSLoader;
XSLoader::load('MIME::Base64', $VERSION);

*encode = \&encode_base64;
*decode = \&decode_base64;

1;

__END__

#line 176
FILE   e2ab1cfb/PerlIO/scalar.pm   �#line 1 "/usr/lib64/perl5/PerlIO/scalar.pm"
package PerlIO::scalar;
our $VERSION = '0.07';
use XSLoader ();
XSLoader::load 'PerlIO::scalar';
1;
__END__

#line 42
FILE   25529da5/XSLoader.pm  
# Generated from XSLoader.pm.PL (resolved %Config::Config value)

package XSLoader;

$VERSION = "0.10";

#use strict;

# enable debug/trace messages from DynaLoader perl code
# $dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

  my $dl_dlext = 'so';

package DynaLoader;

# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
# NOTE: All dl_*.xs (including dl_none.xs) define a dl_error() XSUB
boot_DynaLoader('DynaLoader') if defined(&boot_DynaLoader) &&
                                !defined(&dl_error);
package XSLoader;

sub load {
    package DynaLoader;

    die q{XSLoader::load('Your::Module', $Your::Module::VERSION)} unless @_;

    my($module) = $_[0];

    # work with static linking too
    my $boots = "$module\::bootstrap";
    goto &$boots if defined &$boots;

    goto retry;

    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];

    my $modpname = join('/',@modparts);
    my $modlibname = (caller())[1];
    my $c = @modparts;
    $modlibname =~ s,[\\/][^\\/]+$,, while $c--;	# Q&D basename
    my $file = "$modlibname/auto/$modpname/$modfname.$dl_dlext";

#   print STDERR "XSLoader::load for $module ($file)\n" if $dl_debug;

    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/; # look for .bs 'beside' the library

    if (-s $bs) { # only read file if it's not empty
#       print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    goto retry if not -f $file or -s $bs;

    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @DynaLoader::dl_require_symbols = ($bootname);

    my $boot_symbol_ref;

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $libref = dl_load_file($file, 0) or do { 
        require Carp;
        Carp::croak("Can't load '$file' for module $module: " . dl_error());
    };
    push(@DynaLoader::dl_librefs,$libref);  # record loaded object

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
        require Carp;
        Carp::carp("Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol($libref, $bootname) or do {
        require Carp;
        Carp::croak("Can't find '$bootname' symbol in $file\n");
    };

    push(@DynaLoader::dl_modules, $module); # record loaded module

  boot:
    my $xs = dl_install_xsub($boots, $boot_symbol_ref, $file);

    # See comment block above
    push(@DynaLoader::dl_shared_objects, $file); # record files loaded
    return &$xs(@_);

  retry:
    my $bootstrap_inherit = DynaLoader->can('bootstrap_inherit') || 
                            XSLoader->can('bootstrap_inherit');
    goto &$bootstrap_inherit;
}

# Versions of DynaLoader prior to 5.6.0 don't have this function.
sub bootstrap_inherit {
    package DynaLoader;

    my $module = $_[0];
    local *DynaLoader::isa = *{"$module\::ISA"};
    local @DynaLoader::isa = (@DynaLoader::isa, 'DynaLoader');
    # Cannot goto due to delocalization.  Will report errors on a wrong line?
    require DynaLoader;
    DynaLoader::bootstrap(@_);
}

1;


__END__

#line 359
FILE   '20266eb2/auto/Compress/Raw/Zlib/Zlib.so p`ELF          >    �6      @       �i         @ 8  @                                 |b     |b                   �b     �b!     �b!     `      p                    �b     �b!     �b!     �      �                   �      �      �      $       $              P�td   �O     �O     �O     $      $             Q�td                                                           GNU ���M}y��`�g;�pe}�    %   V      	   ���X"�J    @��  @ (*ATF���  @�PB�+'$���6�
    �L      �      �	     +     �	           85             �    �t      �      �
    `O      �      x    ��      �      
    X      �      �     �      e      �    ��      �          0�      !      �    P     �      �    ��      �      ~    ��      �      &    ��      �      L    ��      �      �    �     �          p}      �                +      =	     �      4      �	    �Z      �      r	     �      !      t    @�      D	      	    ��      [           Ћ      �      �    �     �      )    ��      �          �F      �      �    �            �    �     K      �    0�      �      8    ��      0      H    �z      �      �     �!     �	      �    pf      �      n    �     !         ���h!             =    ��      4      }    �      �      �    Pi      �      (   ���h!             m    ��                0�      �      �    P�      �      ^    P�      �      F
    0U      �      ?     �7      �      �    p�      �      �    �I      �      �    ��      �      9    @�      [         ���h!             �    ��      �      N    �`      �      �    г      �      �    P     G      J    0�      �           �c      �      �    �q      �          	 �1              �
    PR      �       __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses boot_Compress__Raw__Zlib Perl_Gthr_key_ptr pthread_getspecific Perl_Istack_sp_ptr Perl_Imarkstack_ptr_ptr Perl_Istack_base_ptr Perl_newSVpv Perl_new_version Perl_sv_derived_from Perl_vcmp XS_Compress__Raw__Zlib_constant Perl_newXS XS_Compress__Raw__Zlib_zlib_version XS_Compress__Raw__Zlib_ZLIB_VERNUM XS_Compress__Raw__Zlib_adler32 XS_Compress__Raw__Zlib_crc32 XS_Compress__Raw__Zlib_crc32_combine XS_Compress__Raw__Zlib_adler32_combine XS_Compress__Raw__Zlib__deflateInit XS_Compress__Raw__Zlib__inflateInit XS_Compress__Raw__Zlib__deflateStream_DispStream XS_Compress__Raw__Zlib__deflateStream_deflateReset XS_Compress__Raw__Zlib__deflateStream_deflate XS_Compress__Raw__Zlib__deflateStream_DESTROY XS_Compress__Raw__Zlib__deflateStream_flush XS_Compress__Raw__Zlib__deflateStream__deflateParams XS_Compress__Raw__Zlib__deflateStream_get_Level XS_Compress__Raw__Zlib__deflateStream_get_Strategy XS_Compress__Raw__Zlib__deflateStream_get_Bufsize XS_Compress__Raw__Zlib__deflateStream_status XS_Compress__Raw__Zlib__deflateStream_crc32 XS_Compress__Raw__Zlib__deflateStream_dict_adler XS_Compress__Raw__Zlib__deflateStream_adler32 XS_Compress__Raw__Zlib__deflateStream_compressedBytes XS_Compress__Raw__Zlib__deflateStream_uncompressedBytes XS_Compress__Raw__Zlib__deflateStream_total_in XS_Compress__Raw__Zlib__deflateStream_total_out XS_Compress__Raw__Zlib__deflateStream_msg XS_Compress__Raw__Zlib__deflateStream_deflateTune XS_Compress__Raw__Zlib__inflateStream_DispStream XS_Compress__Raw__Zlib__inflateStream_inflateReset XS_Compress__Raw__Zlib__inflateStream_inflate XS_Compress__Raw__Zlib__inflateStream_inflateCount XS_Compress__Raw__Zlib__inflateStream_compressedBytes XS_Compress__Raw__Zlib__inflateStream_uncompressedBytes XS_Compress__Raw__Zlib__inflateStream_inflateSync XS_Compress__Raw__Zlib__inflateStream_DESTROY XS_Compress__Raw__Zlib__inflateStream_status XS_Compress__Raw__Zlib__inflateStream_crc32 XS_Compress__Raw__Zlib__inflateStream_dict_adler XS_Compress__Raw__Zlib__inflateStream_total_in XS_Compress__Raw__Zlib__inflateStream_adler32 XS_Compress__Raw__Zlib__inflateStream_total_out XS_Compress__Raw__Zlib__inflateStream_msg XS_Compress__Raw__Zlib__inflateStream_get_Bufsize XS_Compress__Raw__Zlib__inflateStream_set_Append XS_Compress__Raw__Zlib__inflateScanStream_DESTROY XS_Compress__Raw__Zlib__inflateScanStream_DispStream XS_Compress__Raw__Zlib__inflateScanStream_inflateReset XS_Compress__Raw__Zlib__inflateScanStream_scan XS_Compress__Raw__Zlib__inflateScanStream_getEndOffset XS_Compress__Raw__Zlib__inflateScanStream_inflateCount XS_Compress__Raw__Zlib__inflateScanStream_compressedBytes XS_Compress__Raw__Zlib__inflateScanStream_uncompressedBytes XS_Compress__Raw__Zlib__inflateScanStream_getLastBlockOffset XS_Compress__Raw__Zlib__inflateScanStream_getLastBufferOffset XS_Compress__Raw__Zlib__inflateScanStream_resetLastBlockByte XS_Compress__Raw__Zlib__inflateScanStream__createDeflateStream XS_Compress__Raw__Zlib__inflateScanStream_status XS_Compress__Raw__Zlib__inflateScanStream_crc32 XS_Compress__Raw__Zlib__inflateScanStream_adler32 zlibVersion Perl_get_sv Perl_sv_setiv Perl_Iunitcheckav_ptr Perl_Iscopestack_ix_ptr Perl_call_list Perl_Isv_yes_ptr Perl_sv_2pv_flags Perl_form Perl_croak_nocontext Perl_vstringify Perl_croak Perl_Iop_ptr Perl_sv_newmortal Perl_sv_setuv Perl_mg_set Perl_Icurpad_ptr Perl_sv_2iv_flags Perl_croak_xs_usage Perl_sv_setpv __errno_location strerror Perl_sv_setnv Perl_safesysmalloc deflateInit2_ Perl_safesysfree Perl_Istack_max_ptr Perl_sv_setref_pv Perl_sv_2uv_flags Perl_dowantarray Perl_newSViv Perl_sv_2mortal Perl_stack_grow deflateSetDictionary deflatePrime Perl_sv_2pvbyte Perl_Icurcop_ptr Perl_sv_utf8_downgrade Perl_mg_get __printf_chk inflateEnd Perl_sv_free Perl_sv_free2 Perl_Isv_no_ptr Perl_sv_2bool memmove Perl_sv_backoff Perl_sv_upgrade Perl_Icompiling_ptr Perl_sv_pvbyten_force Perl_sv_grow inflateSetDictionary Perl_sv_utf8_upgrade_flags deflateEnd inflateInit2_ Perl_newSVsv Perl_newSVpvf_nocontext Perl_Isv_undef_ptr Perl_sv_setpvn memcpy libz.so.1 libc.so.6 _edata __bss_start _end GLIBC_2.2.5 GLIBC_2.3.4 ZLIB_1.2.0.8 ZLIB_1.2.2.3 ZLIB_1.2.2                                                                                                                                                                                                                                                  0   ui	   -     ti	   9                 8��   E     3��   R     ��'   _      �b!            �b!     @d!        h           Hd!        v           Pd!        �           Xd!        `           `d!        y           hd!        p           pd!        
           �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                   �f!                    g!                   g!                   g!                   g!                    g!                   (g!                   0g!                    8g!        !           @g!        "           Hg!        #           Pg!        $           Xg!        %           `g!        &           hg!        '           pg!        (           xg!        )           �g!        *           �g!        +           �g!        ,           �g!        -           �g!        .           �g!        /           �g!        0           �g!        1           �g!        2           �g!        3           �g!        4           �g!        5           �g!        6           �g!        7           �g!        8           �g!        9            h!        :           h!        ;           h!        <           h!        =            h!        >           (h!        ?           0h!        @           8h!        A           @h!        B           Hh!        C           Ph!        D           Xh!        E           `h!        F           hh!        G           ph!        H           xh!        I           �h!        J           �h!        K           �h!        L           �h!        M           �h!        N           �h!        O           �h!        P           �h!        Q           �h!        R           �h!        S           �h!        T           �h!        U           H���?  ��  �E H����5z4! �%|4! @ �%z4! h    ������%r4! h   ������%j4! h   ������%b4! h   �����%Z4! h   �����%R4! h   �����%J4! h   �����%B4! h   �p����%:4! h   �`����%24! h	   �P����%*4! h
   �@����%"4! h   �0����%4! h   � ����%4! h
4! h   � ����%4! h   ������%�3! h   ������%�3! h   ������%�3! h   ������%�3! h   �����%�3! h   �����%�3! h   �����%�3! h   �����%�3! h   �p����%�3! h   �`����%�3! h   �P����%�3! h   �@����%�3! h   �0����%�3! h   � ����%�3! h   �����%�3! h   � ����%�3! h   ������%z3! h    ������%r3! h!   ������%j3! h"   ������%b3! h#   �����%Z3! h$   �����%R3! h%   �����%J3! h&   �����%B3! h'   �p����%:3! h(   �`����%23! h)   �P����%*3! h*   �@����%"3! h+   �0����%3! h,   � ����%3! h-   �����%
3! h.   � ����%3! h/   ������%�2! h0   ������%�2! h1   ������%�2! h2   ������%�2! h3   �����%�2! h4   �����%�2! h5   �����%�2! h6   �����%�2! h7   �p����%�2! h8   �`����%�2! h9   �P����%�2! h:   �@����%�2! h;   �0����%�2! h<   � ����%�2! h=   �����%�2! h>   � ����%�2! h?   ������%z2! h@   ������%r2! hA   ������%j2! hB   ������%b2! hC   �����%Z2! hD   �����%R2! hE   �����%J2! hF   �����%B2! hG   �p����%:2! hH   �`����%22! hI   �P����%*2! hJ   �@����%"2! hK   �0����%2! hL   � ����%2! hM   �����%
2! hN   � ����%2! hO   ������%�1! hP   ������%�1! hQ   �����H��H�u-! H��t��H��Ð��������U�=�1!  H��ATSubH�=�-!  tH�=w+! �����H�[+! L�%L+! H��1! L)�H��H��H9�s D  H��H�}1! A��H�r1! H9�r��^1! [A\��f�     H�=+!  UH��tH��,! H��tH�=�*! ���@ �Ð�����AW1�AVAUATUSH��8�����8����H�������1�L�(�����8�����H���S���H�1��*H��H��p����8�]Hc������H��L�$�    �c���1�L�0�I����8����H���J���H� H���@
����8�c���H�L+! H�
����8�c���H������L L�#[]A\A]A^�@ 1�������8�:���H�������1�H�(������8�!���H�������H� H�@H�l� �{����     1������8�����H������H� 1�H��L�h�x����8������   L��H������������1��U����8����L���  H�
���1�H�(������8�I���H�������H� H�@H�l� �c���1�������8�"���H�������H� 1�H��L�h�����8�����   L��H�����������1������8�����L���  H�
���H� 1�H��L�h������8�A����   L��H���A��������1�������8����L���  H�
���1�L�(������8�I���L��H��H�������E@t1�������8�'���H��H���l���I�l� 1������8�	���H������1�H�������8�����H������L L�#[]A\A]A^�f�     1��i����8�����H���j���1�H�(�P����8����H���Q���H� H�@H�l� �s���1��)����8����H���*���H� 1�H��L�h�����8�a����   L��H���a��������1�������8�>���L��  H�
���H�0�  H��H���(����     AV1�AUATUH��S�~����8�����H�������1�L� �e����8����H���&���H�1��H��H��C����8����H���D���Hc�H��HI)�I��A���A  1������8�k���H������H� �@# �f  1�������8�H���H���@���H��1���������8Hc�L�$�    �!���H�������H� 1�L�,������8����H���  L��H����������~  1������8�����H������H� H��H�@�@
���H��H���O���I�l� 1������8�����H�������1�H���z����8�����H���{���L L�#[]A\A]A^�@ 1��Q����8����H���R���1�H�(�8����8����H���9���H� H�@H�l� �{����     1��	����8�b���H���
���H� 1�H��L�h������8�A����   L��H���A��������1�������8����L��  H�
���1�L�(������8�I���L��H��H�������E@t1�������8�'���H��H���l���I�l� 1������8�	���H������1�H�������8�����H������L L�#[]A\A]A^�f�     1��i����8�����H���j���1�H�(�P����8����H���Q���H� H�@H�l� �s���1��)����8����H���*���H� 1�H��L�h�����8�a����   L��H���a��������1�������8�>���L�?�  H�
���H�0�  H��H���(����     AV1�AUATUH��S�~����8�����H�������1�L� �e����8����H���&���H�1��H��H��C����8����H���D���Hc�H��HI)�I��A���A  1������8�k���H������H� �@# �f  1�������8�H���H���@���H��1���������8Hc�L�$�    �!���H�������H� 1�L�,������8����H��  L��H����������~  1������8�����H������H� H��H�@�@
���H� 1�H��L�h�����8�A����   L��H���A��������1��Ű���8����L�G�  H�
���H�0�  H��H���(����     AV1�AUATUH��S�~����8�ת��H���ϩ��1�L� �e����8辪��H���&���H�1��H��H��C����8蜪��H���D���Hc�H��HI)�I��A���A  1������8�k���H������H� �@# �f  1������8�H���H���@���H��1����Ӭ���8Hc�L�$�    �!���H���ɫ��H� 1�L�,�諬���8����H�-�  L��H���¬�����~  1�胬���8�ܩ��H��脫��H� H��H�@�@
���H��貥��1�H�(蘨���8����H��虤��H� H�@H�l� �{����     1��i����8�¥��H���j���H� 1�H��L�h�H����8补���   L��H��衧�������1��%����8�~���L���  H�
���1�H�(�����8�I���H������H� H�@H�l� �s���1��ɟ���8�"���H���ʞ��H� 1�H��L�h訟���8�����   L��H�����������1�腟���8�ޜ��L��  H�
���H��貕��H� H��H�@�@
����K "  1��|����8�Մ��H�������H� H)�H����   H��H�] �����1��I����8袄��L��L��   H���O���I���
����    D���8���I������1��I����8袃��L�{�  H�
������I��1��n���8� l��H���m��H� 1�H�,��n���8��k��L��H��H����j��1��nn���8��k��H���om��H� 1�H�؁H "  �Jn���8�k��H���j��1�H���1n���8�k��H���2m��L(L�+H��[]A\A]Ð1��	n���8�bk��H���
m��H� H��H�@H� L�`I�|$�^i�����������A��$�   I��$�   L��A�4$���������1��m���8�k��L��~  H�
���a���I��1��wk���8��h��H���xj��H� 1�H�,��Zk���8�h��L��H��H����g��1��>k���8�h��H���?j��H� 1�H�؁H "  �k���8�sh��H���kg��1�H���k���8�Zh��H���j��L(L�+H��[]A\A]Ð1���j���8�2h��H����i��H� H��H�@H� L�`I�|$�.f�����������A��$�   I��$�   L��A�4$���������1��|j���8��g��L��{  H�
c���H�5\i  H��   IE�1���b���H�5Xi  H��   IE�1���b���H�5Ti  H��   IE�1��b��H���   H�5Li  �   1��b��H�5.g  []A\�   1��b��f�H�5 g  �   1��mb���"����     AT1�I��US�Rf���8�c��H���b��1�H�(�9f���8�c��H����a��H�1��H��H��f���8�pc��H���e��Hc�H��HH)�H���E����k  1�����e���8Hc��7c��H����d��H� 1�L�$���e���8�c��H��v  L��H����e�����@  1��e���8��b��H���d��H� H��H�@�@
`��H� H��@%   =   tD1���`���8�6^��H����_��H� 1�H�,���`���8�^��H��1�H���\^��H������@ 1��`���8��]��H���_��H� H��H�p�����f.�     1��i`���8��]��H���j_��H� H��H�@�@ �  ������1��9`���8�]��H��b  L��H���_��1��`���8�r]��L�sq  H�
Z  H��H���Z��1��kZ���8��W��H�
  1��dK���8�H��H���eJ��H�T$H� H��H�@�@
  �    ��  %  )=   ��  1��J���8�
H��H�t$ H�T$HH����F��H�CH�T$ H�5�M  L��H�H�@�C ������D$? �@ H���D  �uH�E H�@    �C8    H�U H�BH����  E1��D$,    E1�L�kHǃ�       fD  �K8��ty�   L���G��������   �t�������  ����  ����  ����  ����  ���f���  �����   ��t���A������  �    H�E 1�E�H�@I�TH�T$�|I���8��F��H�T$H��H���H���E%   =   �*  H�ED��E��D�c8H�M�H�C0�$���D  H���    �)���H�CxH���   H���   H�H�H�F%   =   ��  H�v��L���(G����������������f�     �S8��t�C ����  ǃ�   ����A�����D+t$,�S D+s8E�L��   L���   H�L$ H�H�@H��   H)�H���   �E%� �_��D�ED�l$,H�E L��H��   H�PH�E H�UH�@� �|$? ��  �E@��  ��tPH�E L�p�E%   =   ��  1��H���8�[E��1�H��H���E��D��+T$,H�{J�4(�E��H�C��tNH�E L�p�E%   =   ��  1��G���8�E��1�H��H���JE��D��+T$,H�{J�4(�G��H�C���  D��1��L$H�-H  �dG���8�D��H���eF��1�H�\$0H�FG���8�D��H���E��1�H��-G���8�D��H���.F��H�T$H� 1�H���G���8�dD���L$H��H���*��aE���L$��t
���³��H��1���F���8�1D��H����E��H�L$H� 1�H���F���8�D��H��H��H���!C��1��F���8��C��H���E��H�T$H� 1�H�ЁH "  �qF���8��C��H����B��1�H���XF���8�C��H���YE��H� HD$0H�H��X[]A\A]A^A_��    1��!F���8�zC��1�H��H���C�������     1�H�L$H�t$��E���8�HC��H�t$1�H���C��H�L$H�������@ ��A�������	҉��   �A  ����*�������� �D�rtH�P�E��L)�I9���  A�VE1�D�t$,H9��:����E%   =   �=  1��ME���8�B��1�H��H����B��D��E��H�A��H�C0H�E DxD�{8D�t$,����� H�T$ �B�    �5���1���D���8�OB��H����D��H� �@@��  H�L$ �A%  )=   �
���H�L$ H�H�@H�D$HH�A�����     1��D���8��A��H���C��H�T$H� 1�H��H�X�sD���8��A��H�޺   H����C����H���K���1��ID���8�A��H���JC��H�l$H� H��H�<� ����1��D���8�uA��H���C��H� H���@
=���8�c:��H���[9��1�H����<���8�J:��H����;��L L�#H��[]A\A]A^A_�D  1���<���8�:��H����;��H� H��H� �@�D$�)���@ 1��<���8��9��H����:��H���R���f.�     1��i<���8��9��H���j;��H� 1�H�,��L<���8�9���   H��H���;��A������D  1��!<���8�z9��H���";��H� 1�H�,��<���8�]9���   H��H���];��A������D  1���;���8�29��H����:��H� 1�H�,��;���8�9���   H��H���;��A���y���D  1��;���8��8��H���:��H� 1�H��H�pH�4$�l;���8��8��H�4$�   H����:�������1��H;���8�8��L��L  H�
�D$���   A��tD���   A��tL���   H���   ���   ���   H�}�E     �E8   H�E0�<8��A��1�E��u�u8����1����   L����7���8L�5�8  �L5��H����6��1�H(��7���8�35��H���+6��1�H�E ��7���8�5��H����6��H� 1�H�,��7���8��4���A*�H��H����5��E��tD���_���I��1��u7���8��4��H���v6��H� 1�H�,��X7���8�4��L��H��H����3��1��<7���8�4��H���=6��H� 1�H�؁H "  �7���8�q4��H���i3��1�H����6���8�X4��H��� 6��L(L�+H��[]A\A]A^A_� 1���6���8�*4��H����5��H� H��H� D�`�����    1��6���8��3��H���5��H� 1�H�,��6���8��3���   H��H���4��I���Q���D  1��Y6���8�3��H���Z5��H� 1�H�,��<6���8�3���   H��H���5��A������D  1��6���8�j3��H���5��H� 1�H�,���5���8�M3���   H��H���M5���D$�"���@ 1���5���8�"3��H����4��H� 1�H��H�h�5���8�3��H��   H���5��H������1��5���8��2��L�G  H�
����@ H����  �;��uH�E H�@    H�E �@�D$�E%   =   ��  1��v3���8��0��1�H��H���1���T$H�H�C0H�U L�zD+|$D�|$���    D�{8�T$t���   ��S8H�C0ƃ�    ���S8H�C��D�|$H�D$t"H�|$D���/�������S8��   ����   H�E L��1�HPH�$��2���8�%0��H�$H��H����1���ED|$%   =   u"H�ED��H�H�C0D�d$D�c8M��fD  1��y2���8��/��1�H��H���0���� ���_  ���   D|$D��+D$+C8H��   ���[  1��$H�-�2  �"2���8�{/��H���#1��1�H�\$H�2���8�]/��H���U0��1�H���1���8�D/��H����0��H� 1�J����1���8�'/���$H��H���*��%0���$��t
��臞��H��1��1���8��.��H���0��H� 1�J���1���8��.��H��H��H����-��1��d1���8�.��H���e0��H� 1�J��H "  �@1���8�.��H���-��1�H���'1���8�.��H���(0��H� HD$H�H��([]A\A]A^A_�fD  ǃ�       D|$D��+D$+C8H��   �E1�%� �_��D�ED+{8H�E L�x�E@����1��0���8�.��H��H���I/��1��_���f�1�A�   �0���8��-��H���/��H� 1�J��H�X�b0���8�-��H�޺   H���/����H���h���1�I�m�40���8�-��H���5/��H� H���@
���}���H��1��*���8��'��H���)��H� 1�J���v*���8��'��H��H��H����&��1��Z*���8�'��H���[)��H� 1�J���H "  �6*���8�'��H���&��1�H���*���8�v'��H���)��H� HD$(H�H��8[]A\A]A^A_�@ 1���)���8�B'��H����(��H� 1�J��H�X��)���8�!'��H�޺   H���!)��H���.���f�     H�E������    H�T$H�B�]���f�1��y)���8��&��H���z)��H� �@@��   H�T$�B�����1��I)���8�&��H���J)��H� �@@�K���1��&)���8�&���   H��H����'�����%���H�=�>  �(�� �S H�sH�{�h(��H�C������    H�{H���&���H�C�����1��,���f�     1��L$�(���8��%��H��H���C'���L$�^���f.�     1��y(���8��%��H�t$�   H���@'����taH�L$�A�����1��H(���8�%��H�+  H��H���'��1��((���8�%��L��9  H�
��衐��I��1��#���8�!��H���"��H� 1�H�,��#���8�� ��L��H��H��� ��1��~#���8�� ��H���"��H� 1�H�؁H "  �Z#���8� ��H�����1�H���A#���8� ��H���B"��L(L�+H��[]A\A]Ð1��#���8�r ��H���"��H� H��H�@H� L�`I�|$�~ �����������A��$�   I��$�   L��A�4$��������1��"���8� ��L�>4  H�
��H�������f�1�����8����H�����H� 1�H�,��|���8�����   H��H�����I���[���D  1��Q���8���H���R��H� 1�H�,��4���8����   H��H���m��I�������1�����8�g��H�q  H��H�����D  AW1�AVAUATUH��SH�������8�1��H���)��1�H�����8���H�����H�1�D�*H��H�����8����H�����Ic�H��HH��H)�H������  1�H�k��e���8���H���f��H� �@# ��   1��B���8���H�����I��1�A���%���8Mc��{��H���#��H� N�,�A�E
   H�=p  �����f�     L��������A�   ����f.�     1��Y���8�
   L��A�   �����8��{����R���fD  H�='  �   L��I�����������8��J����!����   H�=�  ����H�=�  �   L��A�   �����8����������H�=X  �   L��A�   �����8�����������   H�="  �����   H�=
  ����H�=�  �   L��������1��P
��H����	��H� H)�H���  1�L�m�&
��H������1�H�E�
��H��  �   L��H����
��A�D$@t1������8�8
��L��H���}��I�]M�e����H�=  �   L��I�����������8������������   H�=�  �����   H�=�  �����H�=�  �   L��A�   �����8�������u����   H�=c  ������     1��)���8�	��H��H��   H���/
��H��������    H�=�  �	   L��A�   �����8��+�������fD  �
   H�=�  ������    H�=�  �   L��I�����������8����������1�����8����H��  H��H����
��ffff.�     AW1�AVAUATUSH��H��(�H���8���H�����1�H�(�/���8���H������H�1�D�"H��H�����8�e��H���
��Ic�H��HH)�H���E����	  1�A����
���8Mc��+��H����	��H� 1�N�l��
���8�
���8����H��  H��H���
������  1��b
���8���H���c	��H� J��H�@�@
���8���H���8	��H� ��J��H�@H� H�X�0  H�5L  L���.���I�Ƌ@�    ��  %  )=   ��  1���	���8�/��H�T$L��H������H�CI�L�{A� �  H�P�S �ЉT$Hǃ�       �3@ D��)��   �Cp��y�@�6  �����   ���A  �C ����  D��+��   �   L���C8���   H��   H�C0�/���|$��~H�C�@���  �����  �����  ����?  ����   ��uN���   ��+C8 �  H��   H���   H���   �C8���.���ǃ�       ǃ�      � ���D  ���   H�{��H��   ��+S8�� �  ����H�C��    ���   H�{��H��   ��+S8�� �  ���H�C��O���f��������   H�C(H��  �����H�S(ǃ�      H���   H���   I�HA�K H)�H���   ƃ�   I�H��D���   HHH��  E��H��   tH��H��  D���   E����  �C I�A�Ņ�L�jt'A�FH�[%   =   �  I�~L��H�����I�I�VH�@� A�F@�  1�L�-�  �M���8���H���N��1�H�\$H�/���8���H�����1�H�����8�o��H�����H� 1�J�������8�R���*�H��H���S����t
���s��I��1������8�'��H������H� 1�J������8�
��L��H��H�����1�����8����H�����H� 1�J���H "  �q���8����H������1�H���X���8���H���Y��H� HD$H�H��([]A\A]A^A_��    1��!���8�z��H���"��H� 1�J��H�X� ���8�Y��H�޺   H���Y����H�������1������8�/��H�������������1�I�l$����8���H�����H� H�<� �����1�����8����H�����H� H���@
E�АD��I�|= D�H����    ��
H��J�H�� ���H9�HB�H9�u�A��D�u��s���E���  I�}��  L���r ��E�} �Q���1������8�+���H��  H��H���I��1�����8����L��  H�
     stream pointer is NULL
     stream           0x%p
            zalloc    0x%p
            zfree     0x%p
            opaque    0x%p
            msg       %s
            msg       
            next_in   0x%p  =>  %02x            next_out  0x%p            avail_in  %lu
            avail_out %lu
            total_in  %ld
            total_out %ld
            adler     %ld
     bufsize          %ld
     dictionary       0x%p
     dict_adler       0x%ld
     zip_mode         %d
     crc32            0x%x
     adler32          0x%x
     flags            0x%x
 Disabled Enabled            APPEND    %s
            CRC32     %s
            ADLER32   %s
            CONSUME   %s
            LIMIT     %s
     window           0x%p
 s, message=NULL %s: %s is not a reference s, mode s, buf inflateSync s, buf, output, eof=FALSE inflate s, output, f=Z_FINISH flush s, buf, output deflate adler1, adler2, len2 crc1, crc2, len2 sv Z_OK Z_RLE Z_NULL Z_FIXE OS_COD Z_ASCI Z_BLOC Z_ERRN Z_BINARY DEF_WBITS Z_UNKNOWN MAX_WBITS Z_FILTERED Z_DEFLATED Z_NO_FLUSH Z_NEED_DICT Z_BUF_ERROR Z_MEM_ERROR Z_FULL_FLUSH Z_SYNC_FLUSH Z_STREAM_END Z_BEST_SPEED Z_DATA_ERROR ZLIB_VERSION MAX_MEM_LEVEL Z_STREAM_ERROR Z_HUFFMAN_ONLY Z_VERSION_ERROR Z_PARTIAL_FLUSH Z_NO_COMPRESSION Z_BEST_COMPRESSION Z_DEFAULT_STRATEGY Z_DEFAULT_COMPRESSION %s is not a valid Zlib macro s, buf, out=NULL, eof=FALSE inflateScan       %s object version %-p does not match %s%s%s%s %-p       Compress::Raw::Zlib::zlib_version       Compress::Raw::Zlib::ZLIB_VERNUM        Compress::Raw::Zlib::crc32_combine      Compress::Raw::Zlib::adler32_combine    Compress::Raw::Zlib::_deflateInit       Compress::Raw::Zlib::_inflateScanInit   Compress::Raw::Zlib::_inflateInit       Compress::Raw::Zlib::deflateStream::DispStream  Compress::Raw::Zlib::deflateStream::deflateReset        Compress::Raw::Zlib::deflateStream::deflate     Compress::Raw::Zlib::deflateStream::DESTROY     Compress::Raw::Zlib::deflateStream::flush       Compress::Raw::Zlib::deflateStream::_deflateParams      Compress::Raw::Zlib::deflateStream::get_Level   Compress::Raw::Zlib::deflateStream::get_Strategy        Compress::Raw::Zlib::deflateStream::get_Bufsize Compress::Raw::Zlib::deflateStream::status      Compress::Raw::Zlib::deflateStream::crc32       Compress::Raw::Zlib::deflateStream::dict_adler  Compress::Raw::Zlib::deflateStream::adler32     Compress::Raw::Zlib::deflateStream::compressedBytes     Compress::Raw::Zlib::deflateStream::uncompressedBytes   Compress::Raw::Zlib::deflateStream::total_in    Compress::Raw::Zlib::deflateStream::total_out   Compress::Raw::Zlib::deflateStream::msg Compress::Raw::Zlib::deflateStream::deflateTune Compress::Raw::Zlib::inflateStream::DispStream  Compress::Raw::Zlib::inflateStream::inflateReset        Compress::Raw::Zlib::inflateStream::inflate     Compress::Raw::Zlib::inflateStream::inflateCount        Compress::Raw::Zlib::inflateStream::compressedBytes     Compress::Raw::Zlib::inflateStream::uncompressedBytes   Compress::Raw::Zlib::inflateStream::inflateSync Compress::Raw::Zlib::inflateStream::DESTROY     Compress::Raw::Zlib::inflateStream::status      Compress::Raw::Zlib::inflateStream::crc32       Compress::Raw::Zlib::inflateStream::dict_adler  Compress::Raw::Zlib::inflateStream::total_in    Compress::Raw::Zlib::inflateStream::adler32     Compress::Raw::Zlib::inflateStream::total_out   Compress::Raw::Zlib::inflateStream::msg Compress::Raw::Zlib::inflateStream::get_Bufsize Compress::Raw::Zlib::inflateStream::set_Append  Compress::Raw::Zlib::inflateScanStream::DESTROY Compress::Raw::Zlib::inflateScanStream::DispStream      Compress::Raw::Zlib::inflateScanStream::inflateReset    Compress::Raw::Zlib::inflateScanStream::scan    Compress::Raw::Zlib::inflateScanStream::getEndOffset    Compress::Raw::Zlib::inflateScanStream::inflateCount    Compress::Raw::Zlib::inflateScanStream::compressedBytes Compress::Raw::Zlib::inflateScanStream::uncompressedBytes       Compress::Raw::Zlib::inflateScanStream::getLastBlockOffset      Compress::Raw::Zlib::inflateScanStream::getLastBufferOffset     Compress::Raw::Zlib::inflateScanStream::resetLastBlockByte      Compress::Raw::Zlib::inflateScanStream::_createDeflateStream    Compress::Raw::Zlib::inflateScanStream::status  Compress::Raw::Zlib::inflateScanStream::crc32   Compress::Raw::Zlib::inflateScanStream::adler32 Compress::Raw::Zlib needs zlib version 1.x
     Compress::Raw::Zlib::gzip_os_code       Compress::Raw::Zlib::inflateScanStream  Compress::Raw::Zlib::inflateStream      Compress::Raw::Zlib::deflateStream      inf_s, flags, level, method, windowBits, memLevel, strategy, bufsize    flags, level, method, windowBits, memLevel, strategy, bufsize, dictionary       Wide character in Compress::Raw::Zlib::Deflate::new dicrionary parameter        %s: buffer parameter is not a SCALAR reference  %s: buffer parameter is a reference to a reference      Wide character in Compress::Raw::Zlib::crc32    Wide character in Compress::Raw::Zlib::adler32  Wide character in Compress::Raw::Zlib::Inflate::inflateSync     %s: buffer parameter is read-only       Compress::Raw::Zlib::Inflate::inflate input parameter cannot be read-only when ConsumeInput is specified        Wide character in Compress::Raw::Zlib::Inflate::inflate input parameter Wide character in Compress::Raw::Zlib::Inflate::inflate output parameter        s, good_length, max_lazy, nice_length, max_chain        s, flags, level, strategy, bufsize      Wide character in Compress::Raw::Zlib::Deflate::flush input parameter   Wide character in Compress::Raw::Zlib::Deflate::deflate input parameter Wide character in Compress::Raw::Zlib::Deflate::deflate output parameter        flags, windowBits, bufsize, dictionary  Your vendor has not defined Zlib macro %s, used Unexpected return type %d while processing Zlib macro %s, used  Wide character in Compress::Raw::Zlib::InflateScan::scan input parameter        ��������x���@�����������@���������������`���0������,�������,���,��� ���o�������E���������������4���#�����������������������������������������������J�����������������������������������������������s���                        need dictionary                 stream end                                                      file error                      stream error                    data error                      insufficient memory             buffer error                    incompatible version                                            ;$  C    ���@   ����   ����  ����  ����P  ����  ����  p��  P��P  0���  ���  ���  ���P  ����  ����  p��  P"��P  0%���  (���  �*��  �-��P  �0���  �3���  p6��  P9��P  0<���  ?���  �A��	  �D��P	  �G���	  �J���	  @L�� 
   O��@
   R���
  �S���
   T���
  �V��   W��(  �W��X  �`���  0d���  m��(  @n��`  Pr���  `v���  �y��0
8A0A(B BBBI    <   l   �����   B�D�B �A(�D0��
(A BBBE  <   �   (����   B�D�B �A(�D0��
(A BBBE  <   �   �����   B�D�B �A(�D0��
(A BBBJ  <   ,  h����   B�D�B �A(�D0��
(A BBBK  <   l  ����   B�D�B �A(�D0��
(A BBBJ  <   �  ����   B�D�B �A(�D0��
(A BBBJ  <   �  X���   B�D�B �A(�D0��
(A BBBJ  <   ,  ����   B�D�B �A(�D0��
(A BBBJ  <   l  �	���   B�D�B �A(�D0��
(A BBBJ  <   �  8���   B�D�B �A(�D0��
(A BBBE  <   �  ����   B�D�B �A(�D0��
(A BBBE  <   ,  x���   B�D�B �A(�D0��
(A BBBE  <   l  ���   B�D�B �A(�D0��
(A BBBJ  <   �  ����   B�D�B �A(�D0��
(A BBBE  <   �  X���   B�D�B �A(�D0��
(A BBBJ  <   ,  ����   B�D�B �A(�D0��
(A BBBJ  <   l  ����   B�D�B �A(�D0��
(A BBBJ  <   �  8!���   B�D�B �A(�D0��
(A BBBJ  <   �  �#���   B�D�B �A(�D0��
(A BBBE  <   ,  x&���   B�D�B �A(�D0��
(A BBBE  <   l  )���   B�D�B �A(�D0��
(A BBBJ  <   �  �+���   B�D�B �A(�D0��
(A BBBJ  <   �  X.���   B�D�B �A(�D0��
(A BBBE  <   ,  �0���   B�D�B �A(�D0��
(A BBBJ  <   l  �3���   B�D�B �A(�D0��
(A BBBE  <   �  86���   B�D�B �A(�D0��
(A BBBJ  <   �  �8���   B�D�B �A(�D0��
(A BBBJ  <   ,  x;���   B�D�B �A(�D0��
(A BBBJ  <   l  >���   B�D�B �A(�D0��
(A BBBJ  ,   �  �@���   B�C�A �B
ABE  <   �  8B���   B�D�A �D(�D0�
(A ABBI    <     �D���   B�D�A �D(�D0�
(A ABBI    ,   \  xG���   B�C�A �H
ABG     �  I��=    A�m
BF <   �  (I���   B�D�A �D(�D0L
(A ABBG       �  �K��&    Da ,   	  �K��y    A�I�G M
AAH     L   4	  @L��D	   B�D�B �B(�A0�D8�D��
8A0A(B BBBD   ,   �	  @U��:   B�C�D ��
ABE  L   �	  PX���   B�D�B �B(�A0�D8�D��
8A0A(B BBBD   4   
  �`��,   A�D�I s
AAER
JAK D   <
  �a��   B�D�B �A(�D0�D@�
0A(A BBBJ    D   �
  �e��   B�D�B �A(�D0�D@�
0A(A BBBJ    <   �
  hi��!   B�D�A �D(�D0Y
(A ABBB    <     Xl��!   B�D�A �D(�D0Y
(A ABBB    ,   L  Ho���   B�F�K �|
ABN  ,   |  �r��4   B�F�A ��
ABH  ,   �  �u��4   B�F�A ��
ABH  ,   �  �x��4   B�F�A ��
ABH  ,     |��[   B�C�D ��
ABF  ,   <  8~��[   B�C�D ��
ABF  <   l  h����   B�D�A �D(�D0q
(A ABBJ    L   �  �����   B�D�B �B(�A0�A8�G@$
8A0A(B BBBG    $   �  ���   M��P0���
D    L   $
8A0A(B BBBH   L   t
8A0A(B BBBF    L   �
8A0A(B BBBD    L     p���G   B�D�B �B(�A0�A8�G`
8A0A(B BBBG    L   d  p����   B�D�B �B(�A0�A8�Gp�
8A0A(B BBBE    ,   �   ���K   B�C�D �}
ABG  <   �  @���!   B�D�A �D(�D0Y
(A ABBB    L   $  0���+   B�D�B �B(�D0�A8�D`
8A0A(B BBBD    L   t  ����   B�D�B �B(�A0�D8�D@|
8A0A(B BBBG    L   �  `����   B�D�B �B(�A0�D8�D@|
8A0A(B BBBG    L     �����	   B�D�B �B(�A0�D8�DPV
8A0A(B BBBE    L   d  �����	   B�D�B �B(�A0�A8�G`
8A0A(B BBBH            ��������        ��������                �b!                                      �1      
       j                           8f!            �                           �)             �#                    	              ���o    �#      ���o           ���o    R"      ���o                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   �b!                     �1      �1      �1      2      2      &2      62      F2      V2      f2      v2      �2      �2      �2      �2      �2      �2      �2      �2      3      3      &3      63      F3      V3      f3      v3      �3      �3      �3      �3      �3      �3      �3      �3      4      4      &4      64      F4      V4      f4      v4      �4      �4      �4      �4      �4      �4      �4      �4      5      5      &5      65      F5      V5      f5      v5      �5      �5      �5      �5      �5      �5      �5      �5      6      6      &6      66      F6      V6      f6      v6      �6      �6      �6      �6      �6      �6      �6      Zlib.so.debug   ��6 .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .ctors .dtors .jcr .data.rel.ro .dynamic .got .got.plt .bss .gnu_debuglink                                                                                     �      �      $                                 ���o       �      �      �                            (             �      �      @                          0             �      �      j                             8   ���o       R"      R"      0                           E   ���o       �#      �#      p                            T             �#      �#                                  ^             �)      �)      �         
                 h             �1      �1                                    c             �1      �1      0                            n             �6      �6      H�                             t             85     85                                   z             `5     `5     @                              �             �O     �O     $                             �             �Q     �Q     �                             �             �b!     �b                                   �             �b!     �b                                   �             �b!     �b                                   �             �b!     �b                                   �             �b!     �b     �                           �             @d!     @d     �                            �             8f!     8f     �                            �             �h!     �h                                   �                      �h                                                         �h     �                              FILE   ,bd549a47/auto/Compress/Raw/Zlib/autosplit.ix   �#line 1 "/usr/lib64/perl5/auto/Compress/Raw/Zlib/autosplit.ix"
# Index created by AutoSplit for ../../lib/Compress/Raw/Zlib.pm
#    (file acts as timestamp)
1;
FILE   (35a74833/auto/Compress/Zlib/autosplit.ix   �#line 1 "/usr/lib64/perl5/auto/Compress/Zlib/autosplit.ix"
# Index created by AutoSplit for ../../lib/Compress/Zlib.pm
#    (file acts as timestamp)
1;
FILE   7d60da8f/auto/Cwd/Cwd.so  0�ELF          >    p      @       `*          @ 8  @                                 &      &                    &      &      &      H      X                    H&      H&      H&      �      �                   �      �      �      $       $              P�td   �$      �$      �$      ,       ,              Q�td                                                           GNU +��km�U��@ۑ�<;���       .         ��` �H.   0   3   ��|CE���qX*����������X�{+�o��                             	 �              P                     �                     �                                             +                       �                     `                     Q                     n                      �                     �                     �                     �                     �                      Z                         "                   9                     �                     A                     0                     9                     q                     �                     %                     �                     �                     #                     �                     �                                                               �                      �                      �                     �                      �                     �                     �                                           H                      �                      �                     q                     c                        ��p)              �   ��`)              �   ��`)                  P       �          	 �                   $              ?     @      �      �     �!      �                 %       __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses boot_Cwd Perl_Gthr_key_ptr pthread_getspecific Perl_Istack_sp_ptr Perl_Imarkstack_ptr_ptr Perl_Istack_base_ptr Perl_newSVpv Perl_new_version Perl_sv_derived_from Perl_vcmp XS_Cwd_fastcwd Perl_newXS XS_Cwd_getcwd XS_Cwd_abs_path Perl_Iunitcheckav_ptr Perl_Iscopestack_ix_ptr Perl_call_list Perl_Isv_yes_ptr Perl_sv_2pv_flags Perl_form Perl_get_sv Perl_vstringify Perl_croak Perl_Iop_ptr Perl_Icurpad_ptr __errno_location Perl_my_strlcpy strchr __memcpy_chk __memmove_chk Perl_my_strlcat __lxstat64 readlink strrchr Perl_sv_setpvn Perl_Itainting_ptr Perl_sv_magic Perl_sv_newmortal Perl_Isv_undef_ptr Perl_sv_setsv_flags Perl_mg_set __stack_chk_fail Perl_croak_xs_usage Perl_getcwd_sv libc.so.6 _edata __bss_start _end GLIBC_2.4 GLIBC_2.2.5 GLIBC_2.3.4                                                                                                  �         ii
           H(                    P(                    X(         
  h   �p����%  h   �`����%�  h	   �P����%�  h
   �@����%�  h   �0����%�  h   � ����%�  h
  h'   �p����%  h(   �`����%�  h)   �P���        H��H�M  H��t��H��Ð��������U�=�   H��ATSubH�=8   tH�=�  �����H�s  L�%d  H��  L)�H��H��H9�s D  H��H�}  A��H�r  H9�r��^  [A\��f�     H�=    UH��tH��  H��tH�=  ���@ �Ð�����AW1�AVAUATUSH��8������8�,���H�������1�L�(�����8����H���k���H�1��*H��H������8�]Hc������H��L�$�    �����1�L�0�a����8�����H�������H� H���@
  ��   M���  �/   H������N�#H��I��LE�M��I)�I���  ��  H�|$�   L��H��L�D$�z���BƄ4�   L�D$H��L)�I�M��tI�T$I�p�   H������A�|/�/M��tH�EH=�  ��  A�//A�D/ H�ŀ�$�   �F���H�T$��V	  9������F	  9��3  H�t$�   L������H=�  H���J  H�T$0L���   �������@  �D$h% �  = �  ������|$<�i  H�t$@��  L��������A���$  Hc�Ƅ�    ��$�   /��  H��v(�/   L��A�D/� H�T$����H�h�@ H�T$L)�M��tTA�D$�H����   /t%A��A���  ��  Mc�Ƅ�   /BƄ$�    H�|$@�   H��� ���H=�  ��  H�t$@�   H�߃D$<����I��M�������f�     H��vI�D.��8/��  L��H����������!�%����t�������  D�H�SHD� �H��1��8����8L)�����H�t$L��H��H�������H�L$1��A%� �_��D�A�����8�j���H�������8 ��   1�������8�K���H�t$E1�E1��t   1�H��������   @ 1������8����H������H�D$�����H�T$�B:�  ������B:�  �����H��������/   L��A�D/� �����H�h�@ L)�����fD  H�D$(� $   D  1��)����8����H�������1�H�������8�y���H�t$H�ǹ   H������1�������8�V���H���^���H�H�D$�@@��   H�T$ H�L$1�H�D��H�HH�X�����8����H���O����8 t(1������8�����H�t$E1�E1��t   1�H������1��k����8�����H���l���H�H��$�@  dH3%(   �J  H���@  []A\A]A^A_��     1��!����8����H�t$H���-����<���Ƅ$�0  /Ƅ$�0   I�t$A�|$ L��$�0  �k���H��$�   �   �   H�������I��1����� H�T$(�$   �x���1������8�
����   1�H��H������I��������  ����Ƅ$�0   �   �Y���fD  H�L$(�$   � ���M������H�D$(�8�	����T$L�����L��$�0  ����H�5�  �   L���-��������H�L$(�(   ������3���1�������8�U���H�C  H��H���s���ff.�     AT1�US�����8�&���H������1������8����H���h���H�1�D�"H��H������8�����H�������1��n����8�����H���?���H� �@# ��   1��K����8����H������1�H��2����8����H������H� H�@H��1������8�z���H��H���O���1�������8�a���H���i����C@H�(��   A��1�Mc�J�D��H�XH�h������8�*���H���b����8 t&1������8����E1�E1��t   1�H��H�������1������8�����H������H�([]A\Ð1��a����8�����H���2���H���2���f�1��A����8����H��H���O����N���f�AT1�USH�������8����H������1�L� �����8�j���H�������H�1��*H��H�������8�H���H���P���Hc�H��HI)�I��E���L  1������8����H������H� �@# ��   1������8�����H���]���H��1��s����8�����H��H������1��Z����8�����H��������C@L� ��   ��1�Hc�I�D��H�XH�h�$����8����H��������8 t&1��	����8�r���E1�E1��t   1�H��H���*���1�������8�L���H�������H�([]A\�@ 1�������8�*���H������1�H������8����H���y���H� H�@H�������1������8�����H��H�������,���1��c����8�����H�x   H��H���������UH��SH��H�8  H���tH�+   H����H�H���u�H��[�Ð�H������H���  XS_VERSION %s::%s 3.30 version :: $ bootstrap parameter Cwd.c Cwd::fastcwd Cwd::getcwd Cwd::abs_path pathsv=Nullsv ..   %s object version %-p does not match %s%s%s%s %-p       ;,      x���H   X����   �����   (���             zR x�  L      (����   B�D�B �B(�A0�A8�Dp�
8A0A(B BBBK    L   l   ����%   B�D�B �B(�A0�A8�J���
8A0A(B BBBI  ,   �   �����   B�C�A �U
ABB  ,   �   ����   B�C�A �R
ABE          ��������        ��������                @&             �             �      
       .                           �'             �                           �                          �       	              ���o    �
      ���o           ���o    V
      ���o                                                                                                                                           H&                      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      Cwd.so.debug    �n� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .ctors .dtors .jcr .data.rel.ro .dynamic .got .got.plt .bss .gnu_debuglink                                                                                     �      �      $                                 ���o       �      �      H                             (                           (                          0             (      (      .                             8   ���o       V
      V
      n                            E   ���o       �
      �
      @                            T                         �                            ^             �      �      �         
                 h             �      �                                    c             �      �      �                            n             p      p      �                             t             $      $                                    z      2       $      $      �                             �             �$      �$      ,                              �             �$      �$                                   �             &      &                                    �             (&      (&                                    �             8&      8&                                    �             @&      @&                                    �             H&      H&      �                           �             �'      �'      0                             �             �'      �'      h                            �             `)      `)                                    �                      `)                                                          t)      �                              FILE   7b170f6c/auto/Digest/SHA/SHA.so  � ELF          >    �      @       `�          @ 8  @                                 ĺ      ĺ                     �       �       �      `      p                    0�      0�      0�      �      �                   �      �      �      $       $              P�td   `�      `�      `�      \      \             Q�td                                                           GNU �]����Q�h�P �je�;k�    %   8         @   Ȍe� ��DP$@�2�i  $    8   9           ;       >   @       B   C   D       E   G   H               J       K   L   M   Q       R   T       U   W           X   Z   \   a�|\���|��������iHW�#MA��Jw�Ց@o��i��wȲJq �'2��vD�I�
                     1                     x                      �                      �                     �                     I     �b             �    `�      |      �    p{      }            ��              ~    ��            �     �      �      q    p�      �      S    ��      �      S     c             �    P�      	       �    P�      �          �{      �      �    Е      �       �    ��      j       (    p�      s      g     0c      +          P�      �      \      c      	       �    ��      	       �    `q      7          �s      �      D    p�      {      j    �      #       �    �               ��`�                 ��p�              �    ��      �      �    ��      �      *    �s      %       �    ��      f       �   ��`�              �    �      	       �    �~      #      �    �v      +       [     �      �          	 @              ?     0a      �       __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses shafinish shadigest shadsize hmacdigest boot_Digest__SHA Perl_Gthr_key_ptr pthread_getspecific Perl_Istack_sp_ptr Perl_Imarkstack_ptr_ptr Perl_Istack_base_ptr Perl_newSVpv Perl_new_version Perl_sv_derived_from Perl_vcmp XS_Digest__SHA_shaclose Perl_newXS_flags XS_Digest__SHA_shadump XS_Digest__SHA_shadup XS_Digest__SHA_shaload XS_Digest__SHA_shaopen XS_Digest__SHA_sharewind XS_Digest__SHA_shawrite XS_Digest__SHA_sha1 XS_Digest__SHA_hmac_sha1 XS_Digest__SHA_hashsize XS_Digest__SHA_add XS_Digest__SHA_digest Perl_Iunitcheckav_ptr Perl_Iscopestack_ix_ptr Perl_call_list Perl_Isv_yes_ptr Perl_sv_2pv_flags Perl_form Perl_get_sv Perl_vstringify Perl_croak Perl_sv_isa Perl_newSViv Perl_sv_2mortal Perl_sv_2iv_flags Perl_Isv_undef_ptr Perl_croak_xs_usage Perl_safesysfree Perl_Iop_ptr Perl_sv_newmortal Perl_sv_setiv Perl_mg_set Perl_Icurpad_ptr hmacclose __memcpy_chk memcpy __stack_chk_fail Perl_sv_setuv Perl_sv_2uv_flags hmacfinish hmacwrite Perl_safesyscalloc Perl_sv_setref_pv hmacopen __ctype_b_loc Perl_PerlIO_stdout PerlIO_printf Perl_PerlIO_close PerlIO_open Perl_safesysmalloc shabase64 strcat hmacbase64 shahex __sprintf_chk hmachex Perl_PerlIO_eof PerlIO_getc strcmp strtoul Perl_PerlIO_stdin libc.so.6 _edata __bss_start _end GLIBC_2.4 GLIBC_2.2.5 GLIBC_2.3 GLIBC_2.3.4                                                                                                                                                   �         ii
           ��                    ��         8           ��                    ��         
   �@����%z�  h   �0����%r�  h   � ����%j�  h
�  h   �P����%�  h   �@����%��  h   �0����%�  h   � ����%�  h   �����%�  h   � ����%ڦ  h   ������%Ҧ  h    ������%ʦ  h!   ������%¦  h"   ������%��  h#   �����%��  h$   �����%��  h%   �����%��  h&   �����%��  h'   �p����%��  h(   �`����%��  h)   �P����%��  h*   �@����%z�  h+   �0����%r�  h,   � ����%j�  h-   �����%b�  h.   � ����%Z�  h/   ������%R�  h0   ������%J�  h1   ������%B�  h2   ������%:�  h3   �����%2�  h4   �����%*�  h5   �����%"�  h6   �����%�  h7   �p����%�  h8   �`����%
�  h9   �P����%�  h:   �@����%��  h;   �0����%�  h<   � ����%�  h=   �����%�  h>   � ����%ڥ  h?   ������%ҥ  h@   ������%ʥ  hA   ������%¥  hB   ������%��  hC   �����%��  hD   �����%��  hE   �����%��  hF   ����        H��H�բ  H��t��H��Ð��������U�=X�   H��ATSubH�=Ȣ   tH�=�  �����H��  L�%ܠ  H�-�  L)�H��H��H9�s D  H��H�
�}UD��D1�D!�D1�A�D����D1�E��A��D1�A��A�A	���!�A!�A	։���
D1�E��A�D��A����D1�E��A��D1�A�E��E1�E���i��E!�E��E1�A��E�E��A��E1�E��A��E1�A��G�47A!�A��D�t$�A��A	�A!�E	�A��A��
E1�A��E�A��A��A��E1�A��A��E1�E��G�44E��E1�D�t$�E!�G��3�G��E1�E��E�E��A��A��E1�E��A��E1�E��E�E��A!�A	�A�<>A!�E	�E��A��
E1�D�E��E1�E��*Ɲ�A��A!�A��E1�E�A��A��E1�A��A��E1�E��E�E��E!�E	�A�46A!�E	�E��A��
E1�A��D�A��A��E1�E��̡$A!�E1�E�A��A��E1�A��A��E1�E��G�E	�E��E!�E!�E	�E��A�
A��
E1�E��G�
A��E	�A��E!�D�L$�G��o,�-A��A1�A!�A1�E�A��A��E1�A��A��E1�E��G�E��A��E!�E	�E��G�,)A��
E1�E��G�E��E	�A��E!�D�D$�B����tJA��A1�E!�A1�D�E��A��E1�E��A��E1�E��F�D��A��D!�A	�D��G���
D1�E��A�<8E��E	�A��E!�|$���>ܩ�\D��1�D!�1��D����D1�E��A��D1�E�Ѝ<>D��A��D!�A	�D��F�$'��
D1�E�ȍ47D��E	���E!��t$���1ڈ�vD��D1�D!�D1��D����1�D����1�D�ύ41D����D!�A	�D��F�46��
1�D������L$�A��
D1�A���D��A�����L$�E��m�1�D��D1�D!�D1�A�D����1�D����1��A�D	Ɖ�D!�D!�G�	Ή���
D1�A��A�A���L$�E���'�D��D1�E��D!�A��D1�A�D����D1�E��A��D1�A��A�A	���!�E!�A	̉���
E1�E��G�A��D�L$�G���Y�E��E1�A��E!�A��E1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�A!�E	�A��A��
E1�E��G�D A��D�D$�G�����E��E1�E��E!�A��E1�E�E��A��E1�E��A��E1�E��E�A	�E��A!�A!�E	�E��A��
D1�E��A�<>A���|$�E��:G���D��D1�D!�D1�E�4:D��E��A����D1�E��A��D1�E��A�E	�D��D!�A!�A	�D����
D1�A��A�42A���t$�E��3Qc�D��D1�E��D!�A��D1�A�D����D1�E��A��D1�A��A�E	É�D!�E!�A	����
D1�A��A�E��A��A���L$�E��g))D��D1�D!�D1�A�D����D1�E��A��D1�A��A�A	���!�E!�G�A	ˉ���
E1�F�D��D1�G��+�
�'D!�D�\$�D1�E��A��A�D��A����A��D1�E��A��D1�A��A�A	��!�A!�G�A	Ӊ���
D1�A�E��A���T$�F��28!.D��D1�E��D!�A��D1�A�D����D1�E��A��D1�E��A�A	�D��!�A!�A�|= A	�D����
E1�D�E��E1�F���m,MA��A!�A��E1�E�A��A��E1�A��A��E1�A��E�A��E!�E	�A!�E	�A��A��
D1�E��43��A��D1�D!�F��
D1�E�΍D��A��1�D!�F��Ts
e1�A�D����D1�E��A��D1�E��A�E	�D��D!�A!�G�A	�D����
D1�E��A�E��A��A���\$���;�
jvD��D1�D!�D1��D����D1�E��A��D1�E���E	�D��D!�E!�A	�D����
D1�A��A�A��A��A���T$�F��*.�D��D1�!�D1�AՉ���D1�A��A��D1�A��A�E	���D!�E!�G�T A	Љ���
E1�A��G�D A��D�D$�G���,r�A��E1�E��E!�A��E1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�E!�G�d% E	�A��A��
E1�E��G�D A��D�D$�G���迢E��A1�E!�A1�G�,E��E��A��A��E1�E��A��E1�E��E�A	�E��A!�A!�G�t5 E	�E��A��
E1�E��G�\ E��A��A��D�\$�A��;Kf�E��E1�E!�E1�D�E��A��E1�E��A��E1�E��F�E	�D��D!�A!�A	�D����
D1�A��A�\ E�݉\$�F��p�K�D��D1�D!�A��A��D1�A�D����D1�E��A��D1�A��A�E	ŉ�D!�E!�A	݉���
�T$���D1�D�|$�A��
D1�A��A�T E�ՉT$�F��"�Ql�D��D1�D!�D1�A��A��A�D����D1�E��A��D1�A��A�A	���!�E!�A	Չ���
E1�G�A��D�L$�G��1��E��E1�E��E!�E1�E�E��A��A��A��E1�E��A��E1�A��E�A	�A��A!�A!�E	�A��A��
E1�E��G�E��D�D$�G��$��E��E1�E!�E1�E�E��A��A��A��E1�E��A��E1�E��E�A	�E��A!�A!�E	�E��A��
D1�E��A�<>E�މ|$�F���5�D��D1�D!�D1�A�D����A��A��D1�E��A��D1�E��A�E	�D��D!�A!�A	�D����
D1�A��A�E��A���\$�F��#p�jD��D1�D!�D1�A�D����D1�E��A��A��D1�A��A�E	Ɖ�D!�E!�A	މ���
D1�A��A��T$�F��*��D��D1�E��D!�A��D1�A�D����D1�E��A��A��D1�A��A�A	���!�E!�G�A	Չ���
E1�G�,.E��E1�G��l7E!�E��E1�A��E�E��A��E1�E��A��E1�A��G�47A��D�t$�A��A	�A!�A��A!�DD$�E	�A��A��
E1�D�E��E1�F��LwH'E��E!�A��E1�E�E��A��E1�E��A��E1�E��G�47E��D�t$�E��A	�A!�A!�A��E	�E��|$�A��
E1�D�E��E1�F��&���4A��A!�A��E1�E�A��A��E1�A��A��E1�E��G�47E��D�t$�E��E	�A!�E!�A��E	�E��\$�A��
E1�E��F�41��D1�!�G���9D�t$�D1�E�4	��A��A����D1�A��A��D1�E��A�E	�D��D!�E!�A�A	�D����
E1�A��G�A��D�L$�G��J��NA��A1�A!�A1�G�4A��A��A��A��E1�A��A��E1�A��E�A��E!�E	�G�E!�E	�A��A��
E1�E��G�A��D�D$�A��8Oʜ[A��A1�E!�A1�F�4E��D����A��A1�D����A1�D��E�E��!�A	�G�E!�A	�D����
D1�E��A�<>A���|$����o.hD��1�D!�1�D�4;D��D������1�D����1�D��A�D��D!�D	�G�$&!�	�D����
D1�A�D��D1�A��tD!�D1�D�4D��D������1�D����1Ӊ�Aމ�D!�D	�D!�	Ӊ���
1�D���D����D1�F��oc�xD!�D1�A�D����1�D����1ʉ�A�	���!�D!�G�	щ���
D1��D��D1�F��xȄD!�D1�E�D��E��A����D1�E��A��D1�A��A�A	ډ�!�A!�G�A	҉���
E1�A��A1�D��A��D1�E�D!�E��G��#ǌD1�A��A�D����D1�E��A��D1�A��A�A	ʉ�!�A!�A	����
D1�1�D��A�D1�D��G��7����D!���D1�A��A�D��A����1�D����1���A�	׉�!�!�A�	�����
D1�D1�E�>D��A��D1�A��G��
�lP�!�D1�E�9��A��A����D1�A��A��D1�A��A�A	��!�A!�A�A	�����
��A1���E1�D1�G������!�E��D1�A��E�A��A���A����D1�A��A��D1�E��A�A	�D��A!�!�A	�D����
��1�D��D1���E���xqƉ�1�D!�E�E��1�E!�A�D����1�D����1�D��A�D����
H��P  []A\A]A^A_Á?   H���   L�G=1� A�<H��   A��A���D�H�����u�H��H�� u���f.�     H��H@ I�H��   H�� A��A���D�H�����u�A�H�F�   A��A���D�H�����u�I9�tI��H���@ ��fffff.�     AW�<   A�x   AVA�|   AUL�oPATA�   U��  SH��H�����      ���   ����LD�8LD�f��D�������f� ��DP���   �����   �-�    ����D������������ LP���   ���   9�s&9��   w�L��H���Sǃ�       ��f�     v5���   �    ���щ���������҉��� LP9ŉ�w߉��   ���      vJ���   H���   �   �����@�0H�����u틓�   H���   �   �����@�0H�����u틓�   J�D;P�   �����@�0H�����u틓�   J�D3P�   �����@�0H�����u�H�CH��H��[]A\L��A]A^A_�� SH���w���H���   [�fffff.�     ��(  �f�     H������    AW1�AVAUATUSH��8�3����8�|���H���Է��1�L�(�����8�c���H���K���H�1�D�"H��H�������8A�\$Hc��8���H��H�,�    �����1�L�0�κ���8����H���߹��H� H���@
   �h����8豳��L�+C  H�
   �ű���8����L��>  H�
   i� ���H�T$(�T$$�� ����D$$�|$$��tA�T$$H�D$(H�t$��L�Df.�     ��P��H����D����	ڈH��L9�u�H�T$(����L���:L�����D<0H�|$�����H��$8  dH3%(   H�D$u-H��H  []A\A]A^A_�I�vPL��A�VAǆ�       �e���躡��f�H��tc���   ����   ��H9�v6���   �������   u#���   �������   u���   f�     ���   ��t�t�-���D  1��D  ���� �#��� AW1�AVAUATUH��SH��(�p����8蹟��H������1�L� �W����8蠟��H��舞��H�1��H��H��5����8�~���H���F���Hc�H��HI)�I��E���  1��������8Hc�L�<�    �@���H������H� 1�H�,��ڡ���8�#���H��.  H��H����������!  H�EH�h�E
���     1��A   �H�H�o����   H�BH�
H��[�@ �  �   �є��H��t�H��H�D$�=���H�D$H��[�f.�     AU1�ATUSH��H�������8�]���H��赒��1�L� ������8�D���H���,���H�1��*H��H��ٕ���8�"���H������Hc�H��HI)�I��A���_  1���襕���8Hc�H��    ����H��諔��H� H���@
����8�S���H�4$H�ǹ   L���?���H���q����    L���(���D���VUUUH�D$    ��D����)RA)���   A����   L��菂��I��1�蕃���8�ހ��H��覂��H�\$1�L�t$H��H��H(�k����8贀��L��L��H��趂��1�I���L����8蕀��L��H������L��H�E �.���1��'����8�p���H������1�H�������8�W���H������HH�] H��([]A\A]A^A_ÐL�����L��I���E��H�H�D$�-����L��蠀��I������1�Hc�讂���8H��H������H��踁��1�H(莂���8����H���O���H�E �H���fffff.�     H��?����    AW1�AVAUATI��USH��(�@����8���H����~��1�L�(�'����8�p��H���X~��H�1�Hc*H��H������8��H�����D��H������H(I�$1�D�x8�ځ���8I)�I��A�����H��A�l �ۀ��H� Hc�H���@
t1��}���8��z��H��H����z����t�A� �T$`��#�d������\����T$��z���T$I��H�H�D$�@ H������.���H���DQ u�H�D$HH�|$H��H�D$����L��H����{��������L�l$H�T$L�l$8L�l$(E��L�|$PH�T$0�5f�     ��u#�T$$1�H���}��H�T$�H��H�T$D  A��E����   H�t$H�|$H�,���H��H����   ����   ~���f�tf��u��D$P �D$Q E1��!f.�     I���   1�L���|��N�$ H�I�H���T$P�DPu�H�D$(L� H��H�D$(�e���D  �T$$1�H���B|��H�T$0�H��H�T$0�=���D  �T$$1�H���|��H�T$8�H��H�T$8����D  �   ������qz��f�     USH��H��t	�? �t  1��{���8��x��H���z��H��H�L$H�5�  A�
   A�   �   H�������1ۅ�tD�|$�z��H��H��t31ҁ|$  H�HH�5�  A�   A�   H����������uTH��t41��{���8�Yx��H���1z��H9�t1���z���8�>x��H��H���x��H��t
H��1���y��H��H��[]�f�D���   H�KPH�5A  A�   �   H��A���7������{���H���   H�56  A�
   A�   �   H���������L����D$=   �  =  ~���   �  �&���H���   H�5�  A�
   A�   �   H�������������H���   H�5�  A�
   A�   �   H�������������H���   H�5�  A�
   A�   �   H���U����������H���   H�5o  A�
   A�   �   H���&������j���1��y���8��v��H���x��H9������1��`y���8�v��H��H���w���u�������   �  ��������� H�5�  1��2w��H��H��������=���f�     AU1�ATUH��SH����x���8�=v��H���u��1�L� ��x���8�$v��H���u��H�1��H��H��x���8�v��H����w��Hc�H��HI)�I��A���]  1����x���8Hc�H�,�    ��u��H���w��H� H���@
H %s%02x 
block :%02x 
blockcnt:%u
 file, s blockcnt lenhh lenhl lenlh lenll file      %s object version %-p does not match %s%s%s%s %-p       Digest::SHA::hmac_sha512_base64 Digest::SHA::hmac_sha256_base64 Digest::SHA::hmac_sha384_base64 Digest::SHA::hmac_sha224_base64 lenhh:%lu
lenhl:%lu
lenlh:%lu
lenll:%lu
                         �   �   �            �  �  �               ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/                                "�(ט/�B�e�#�D7q/;M������ۉ��۵�8�H�[�V9����Y�O���?��m��^�B���ؾopE[����N��1$����}Uo�{�t]�r��;��ހ5�%�ܛ�&i�t���J��i���%O8�G��Ռ�Ɲ�e��w̡$u+Yo,�-��n��tJ��A�ܩ�\�S�ڈ�v��f�RQ>�2�-m�1�?!���'����Y��=���%�
�G���o��Qc�pn
g))�/�F�
�'&�&\8!.�*�Z�m,M߳��
e��w<�
jv��G.�;5��,r�d�L�迢0B�Kf�����p�K�0�T�Ql�R�����eU$��* qW�5��ѻ2p�j��Ҹ��S�AQl7���LwH'�H�ᵼ�4cZ�ų9ˊA�J��Ns�cwOʜ[�����o.h���]t`/Coc�xr��xȄ�9dǌ(c#����齂��lP�yƲ����+Sr��xqƜa&��>'���!Ǹ������}��x�n�O}��or�g���Ȣ�}c
�
��<L
             zR x�  L      �m��   B�D�B �B(�A0�A8�Dh�8A0A(B BBB       L   l   ����F)   B�K�B �B(�A0�A8�DH$)8A0A(B BBB       L   �   ����P   B�F�B �B(�A0�A8�G�08A0A(B BBB           �����           L   $  H����   B�M�H �F(�G0�F8�G@}8A0A(B EBB          t  ����    A�P          �  ����              �  ����	           L   �  ����+   B�D�B �B(�A0�A8�Dp"
8A0A(B BBBD    <     ����7   B�D�A �A(�G0�
(A ABBH       T  ����%    D` <   l  �����   B�D�B �A(�D0��
(A BBBI     �  @���+    D�f       $   �  P����    A�D�G0�AA4   �  ����z    B�E�D �D(�G0Z(D ABB,   ,   ����    M��M��N@��d
D       L   \  ����n   B�B�E �B(�A0�A8�G�/
8A0A(B BBBA      �   ���}           L   �  h����   B�D�B �B(�A0�D8�D`K
8A0A(B BBBH    L     ����#   B�D�B �B(�A0�D8�DP�
8A0A(B BBBC       d  ����j    M��I �O    �  ���	              �   ���|          ,   �  h����   B�C�D �f
ABF  $   �  8���f    A�F k
AElA<     �����   B�D�A �A(�G0�
(A ABBG    <   L  @����   B�E�J �A(�H0�;
(A BBBA  ,   �  �����    A�D�G c
AAG     L   �  ����   B�B�B �B(�A0�D8�JP�
8A0A(B BBBA    L     ����{   B�D�B �B(�A0�D8�D@w
8A0A(B BBBD       \  ����#    A�a       <   |  �����   B�D�A �A(�G0�
(A ABBI    <   �  0���   B�E�A �A(�D@�
(A ABBD        �   ���	           4     �����    B�E�A �A(�D0v(H ABB<   L  `���s   B�D�B �A(�A0��
(A BBBH  L   �  ����   B�D�B �B(�D0�A8�D`�
8A0A(B BBBB       �  p���	           L   �  h����   B�D�B �B(�D0�A8�D`
8A0A(B BBBB    L   D  ����   B�E�B �E(�D0�C8�J�k
8A0A(B BBBD    ,   �  h����   A�A�D0�
AAC     <   �  �����   B�D�A �D(�D0�
(A ABBE                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    ��������        ��������                (�             �             @      
       B                           (�             �                           �                          �      	              ���o    �      ���o           ���o    
      ���o                                                                                                                                                                                                                   0�                      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �      �      �      �                  .      >      N      ^      n      ~      �      �      �      �      �              #Eg�����ܺ�vT2����            ؞��|6�p09Y�1��Xh���d�O��g�	j��g�r�n<:�O�RQ�h��ك��[؞�]����|6*)�b�p0ZY�9Y���/1��g&3gXh�J�����d
      
      �                            E   ���o       �      �      P                            T                         �                           ^             �      �      �         
                 h             @      @                                    c             X      X      �                            n             �      �      Ȉ                             t             ��      ��                                    z             ��      ��      �                              �             `�      `�      \                             �             ��      ��      	                             �              �       �                                    �             �      �                                    �              �       �                                    �             (�      (�                                    �             0�      0�      �                           �             ��      ��      x                             �             (�      (�      P                            �             ��      ��      �                               �             `�      `�                                    �                      `�                                                          t�      �                              FILE   '6121cc11/auto/DynaLoader/dl_findfile.al  �#line 1 "/usr/lib64/perl5/auto/DynaLoader/dl_findfile.al"
# NOTE: Derived from ../../lib/DynaLoader.pm.
# Changes made here will be lost when autosplit is run again.
# See AutoSplit.pm.
package DynaLoader;

#line 239 "../../lib/DynaLoader.pm (autosplit into ../../lib/auto/DynaLoader/dl_findfile.al)"
sub dl_findfile {
    # Read ext/DynaLoader/DynaLoader.doc for detailed information.
    # This function does not automatically consider the architecture
    # or the perl library auto directories.
    my (@args) = @_;
    my (@dirs,  $dir);   # which directories to search
    my (@found);         # full paths to real files we have found
    #my $dl_ext= 'so'; # $Config::Config{'dlext'} suffix for perl extensions
    #my $dl_so = 'so'; # $Config::Config{'so'} suffix for shared libraries

    print STDERR "dl_findfile(@args)\n" if $dl_debug;

    # accumulate directories but process files as they appear
    arg: foreach(@args) {
        #  Special fast case: full filepath requires no search
	
	
	
        if (m:/: && -f $_) {
	    push(@found,$_);
	    last arg unless wantarray;
	    next;
	}
	

        # Deal with directories first:
        #  Using a -L prefix is the preferred option (faster and more robust)
        if (m:^-L:) { s/^-L//; push(@dirs, $_); next; }

	
	
        #  Otherwise we try to try to spot directories by a heuristic
        #  (this is a more complicated issue than it first appears)
        if (m:/: && -d $_) {   push(@dirs, $_); next; }

	

        #  Only files should get this far...
        my(@names, $name);    # what filenames to look for
        if (m:-l: ) {          # convert -lname to appropriate library name
            s/-l//;
            push(@names,"lib$_.$dl_so");
            push(@names,"lib$_.a");
        } else {                # Umm, a bare name. Try various alternatives:
            # these should be ordered with the most likely first
            push(@names,"$_.$dl_dlext")    unless m/\.$dl_dlext$/o;
            push(@names,"$_.$dl_so")     unless m/\.$dl_so$/o;
            push(@names,"lib$_.$dl_so")  unless m:/:;
            push(@names,"$_.a")          if !m/\.a$/ and $dlsrc eq "dl_dld.xs";
            push(@names, $_);
        }
	my $dirsep = '/';
	
        foreach $dir (@dirs, @dl_library_path) {
            next unless -d $dir;
	    
            foreach $name (@names) {
		my($file) = "$dir$dirsep$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
		$file = ($do_expand) ? dl_expandspec($file) : (-f $file && $file);
		#$file = _check_file($file);
		if ($file) {
                    push(@found, $file);
                    next arg; # no need to look any further
                }
            }
        }
    }
    if ($dl_debug) {
        foreach(@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n" unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}

# end of DynaLoader::dl_findfile
1;
FILE   72b63f14/auto/Fcntl/Fcntl.so  F8ELF          >    �      @       �?          @ 8  @                                 �+      �+                     0       0       0      �      �                    �;      �;      �;      �      �                   �      �      �      $       $              P�td   �*      �*      �*      $       $              Q�td                                                           GNU Z��=���[��[��ga:(�       %         ��( �@	%   (   +   �TU���|CE��.6bx�qX������                             	 �              �                     ?                                           �                      ?                     �                                            +                       k                     �                     �                      W                     /                                                                9                        "                   r                      |                     �                     �                     Z                     �                     M                     K                      �                      �                      g                     �                      $                                          b                      '                     �                      �                     
    @#      E      �   ���>              �   ���>              �     P      �      �   ���>                  	 �                   �$               __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses Perl_get_hv Perl_hv_common_key_len Perl_newSV_type Perl_sv_upgrade boot_Fcntl Perl_Istack_sp_ptr Perl_Imarkstack_ptr_ptr Perl_Istack_base_ptr Perl_newSVpv Perl_new_version Perl_sv_derived_from Perl_vcmp XS_Fcntl_constant Perl_newXS Perl_Gthr_key_ptr pthread_getspecific Perl_newSViv Perl_newCONSTSUB Perl_Isv_yes_ptr Perl_sv_setpvn Perl_sv_free Perl_sv_free2 Perl_Isub_generation_ptr Perl_Iunitcheckav_ptr Perl_Iscopestack_ix_ptr Perl_call_list Perl_sv_2pv_flags Perl_form Perl_get_sv Perl_croak Perl_vstringify Perl_newSVpvf_nocontext Perl_sv_2mortal Perl_croak_xs_usage libc.so.6 _edata __bss_start _end GLIBC_2.2.5                                                                                          {         ui	   �      @0             >&      X0             H&      p0             R&      �0             \&      �0             f&      �0             p&      �0             z&      �0             �&       1             �&      1             �&      01             �&      H1             �&      `1             �&      x1             �&      �1             �&      �1             �&      �1             �&      �1             �&      �1             �&      2             �&       2             �&      82             '      P2             '      h2             '      �2             '      �2             #'      �2             .'      �2             6'      �2             @'      �2             I'      3             T'      (3             ]'      @3             f'      X3             n'      p3             v'      �3             ~'      �3             �'      �3             �'      �3             �'      �3             �'       4             �'      4             �'      04             �'      H4             �'      `4             �'      x4             �'      �4             �'      �4             �'      �4             �'      �4             (      �4             
(      5             (       5             (      85             ((      P5             3(      h5             <(      �5             C(      �5             K(      �5             R(      �5             Y(      �5             a(      �5             j(      6             r(      (6             z(      @6             �(      X6             �(      p6             �(      �6             �(      �6             �(      �6             �(      �6             �(      �6             �(       7             �(      7             �(      07             �(      H7             �(      `7             �(      x7             �(      �7             �(      �7             �(      �7             )      �7             )      �7             )      8             )       8             $)      88             ,)      P8             4)      h8             <)      �8             D)      �8             L)      �8             T)      �8             ])      �8             f)      �8             o)      @9             w)      P9             ~)      `9             �)      p9             �)      �9             �)      �9             �)      �9             �)      �9             �)      �9             �)      �9             �)      �9             �)      �9             �)       :             �)      :             �)       :             �)      0:             �)      @:             �)      P:             *      `:             	*      p:             *      �:             *      �:             !*      �:             )*      �:             1*      �:             ;*      �:             C*      �:             K*      �:             S*       ;             [*      ;             d*       ;             r*      0;             ~*      @;             �*      P;             �*      `;             �*      p;             �*      �;             �*      �;             �*      �;             �*      �;             �*      �;             �*      �;             �*      �;             �;      x=                    �=         	           �=                    �=         %           �=                    �=                    �=                    �=                    �=                    �=                    �=         
           �=                    �=                    �=         
  H����5�#  �%�#  @ �%�#  h    ������%�#  h   ������%�#  h   ������%�#  h   �����%�#  h   �����%�#  h   �����%�#  h   �����%�#  h   �p����%�#  h   �`����%�#  h	   �P����%�#  h
   �@����%�#  h   �0����%�#  h   � ����%�#  h
#  h   �����%#  h   � ����%�"  h   ������%�"  h    �����        H��H��!  H��t��H��Ð��������U�=�"   H��ATSubH�=�!   tH�=�  ����H��  L�%�  H��"  L)�H��H��H9�s D  H��H�u"  A��H�j"  H9�r��V"  [A\��f�     H�=�   UH��tH��   H��tH�=�  ���@ �Ð�����UH�50  �   SH��H��(����H�	  E1�A�0   �   H��H���$    �7���H��1�H��tH�E �@
H�H�x tcH���b���H�L��H��H���!���I��H� H�p8H��t�F���  �����F�  I�E f�`l��I�E H�@@    I�E H�@8    H��������K�$    I��H�A�$   L��H�������H���R  H��H�H����   �KE1�A�0   L��H���$    ����H���	  H�0�F�Ѓ�����H�Vf�B �����H�c  1�H�������_���fD  H�Vf�B �������   H��H�D$(�����H�D$(H�0�����f�     H������������ H�������I�E ������    H�������� H�|$0�����H�8 t&H�|$0����H�|$0H�����H�|$0�0H�������H�|$0�����H�\$8HH�|$0����H�H�|$0����H�|$0H������H� HD$8H�H��H[]A\A]A^A_��    H�|$0�n���H� H�|$0�"   1�H�4������I�������H�|$0H�
AAAj
AAD L   T   �����   B�B�B �B(�A0�A8�D�@
8A0A(B BBBH   <   �   ����E   B�B�A �D(�GP�
(A ABBC                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             ��������        ��������                                        >&      	              H&      	              R&      	              \&      	              f&      	              p&      	               z&                �    �&                    �&                     �&      
              �&                    �&      	              �&                     �&                    �&                    �&                    �&      
             �&                    �&      	              �&             	       �&                    '                   '                     '                    '                    #'      
              .'                    6'      	              @'                    I'      
              T'                    ]'             
       f'                    n'                    v'                    ~'      	               �'      	       @       �'      
       �       �'             �       �'      	              �'                    �'                     �'                     �'             @       �'              @      �'                    �'                    �'             �       �'                     (                    
(      	              (                    (      
              ((      
              3(                     <(                    C(                   K(                   R(                     Y(                    a(                    j(             @       r(              `      z(                     �(              @      �(                    �(              �      �(              �      �(              �      �(                    �(                     �(                    �(                    �(             8       �(                    �(             �      �(                    �(                    �(                    �(                    )                    )             �       )             �       )                    $)                    ,)             @       4)                    <)                    D)                    L)                    T)                     ])                    f)                    o)              �                                                      w)             ~)             �)             �)             �)      
       �)             �)             �)             �)      	       �)             �)             �)             �)             �)      
       �)             �)      	       �)             *             	*             *             *             !*             )*             1*      	       ;*             C*             K*             S*             [*             d*      
       �                           �=                                        x             @	             8
                 h             �      �                                    c             �      �                                   n             �      �      �                             t             �$      �$                                    z      2       �$      �$      	                            �             �*      �*      $                              �             +      +      �                              �              0       0                                    �             0      0                                    �              0       0                                    �             @0      @0      �                              �             �;      �;      �                           �             x=      x=                                    �             �=      �=                                   �             �>      �>                                    �                      �>                                                          �>      �                              FILE   88ede8e3/auto/File/Glob/Glob.so  R@ELF          >    �      @       �K          @ 8  @                                 �F      �F                    �F      �F      �F      �                           �F      �F      �F      �      �                   �      �      �      $       $              P�td   xA      xA      xA      �       �              Q�td                                                           GNU ٥>H�c"Ax}�3����-��u       A         ��`�@
           �H                    �H                    �H         
   �@����%B3  h   �0����%:3  h   � ����%23  h
3  h   ������%3  h   �����%�2  h   �����%�2  h   �����%�2  h   �����%�2  h   �p����%�2  h   �`����%�2  h   �P����%�2  h   �@����%�2  h   �0����%�2  h   � ����%�2  h   �����%�2  h   � ����%�2  h   ������%�2  h    ������%�2  h!   ������%�2  h"   ������%�2  h#   �����%z2  h$   �����%r2  h%   �����%j2  h&   �����%b2  h'   �p����%Z2  h(   �`����%R2  h)   �P����%J2  h*   �@����%B2  h+   �0����%:2  h,   � ����%22  h-   �����%*2  h.   � ����%"2  h/   ������%2  h0   ������%2  h1   ������%
2  h2   ������%2  h3   �����%�1  h4   �����%�1  h5   �����%�1  h6   �����%�1  h7   �p����%�1  h8   �`����%�1  h9   �P����%�1  h:   �@����%�1  h;   �0����%�1  h<   � ����%�1  h=   ����        H��H�e/  H��t��H��Ð��������U�=�1   H��ATSubH�=X/   tH�=�-  �B���H��-  L�%|-  H�]1  L)�H��H��H9�s D  H��H�=1  A��H�21  H9�r��1  [A\��f�     H�=8-   UH��tH��.  H��tH�=-  ���@ �Ð�����ATI��USH�H��tLA�$A�D$��t1H���H�,���     H����H�} H��t�#�����u�I�|$����I�D$    []A\�ffffff.�     H��  dH�%(   H��$  1�L��$   H���f�     L9�t[D�H��D�H��E��u��B@u1H��   H���9���H��$  dH3%(   u%H��  �fD  H���R8���     ��������\���@ H��  dH�%(   H��$  1�L��$   H���f�     L9�t[D�H��D�H��E��u��B@u1H��   H���i���H��$  dH3%(   u%H��  �fD  H���R@���     �����������@ AWAVAUI��ATA��USH��H��HH9���   L�I���   �H��L��f��?���   f��[��  f��*���   E��A�6�,  �����   =  w)�T$�L$�t$�����t$�L$�T$Hc�H��H0�6�ꍅ�   =  w!�L$�t$�N���HcՋt$�L$H��H�*9����  �     fA�> L��tZI��I��I9��1���1�f�? ���@f.�     L9�u�  fD  H��D��L��H��H�����������  f�}  u�1�H��H[]A\A]A^A_� A�f��t��;1�f��!������D$4�6  ��1�Hc�H��H�D$8���   �D$0�   fD  �����   =  w1�T$�L$�t$�|$ �C����|$ �t$�L$�T$Hc�H��H8�?�|$0  ��w1�T$�L$�t$�|$ ����L�D$8H� �|$ �t$�L$�T$B� 9�����E��;H��f��]��>  f�;-�tE���V���f9�����fD  E����   �����   =  w1�T$�L$�t$�|$ �����|$ �t$�L$�T$Hc�H��H8�?�|$0  ��w1�T$�L$�t$�|$ �E���L�D$8H� �|$ �t$�L$�T$B� 9�m�|$0  A����   �{���   =  w;�T$�L$�t$�|$ D�D$(������|$ D�D$(�t$�L$�T$Hc�H��H8�?A9��   fD  H��������    f9�w�f;Sw�   ��fD  ;l$4L���e�������fD  f9�����L���I�������f.�     H���;����@ H��H�   []A\A]A^A_�@ �T$�L$�t$����H�|$8H� �t$�L$�T$D�8�����f.�     �#���ff.�     AWAVAUI��ATUH��SH��H��D�&DfH�~A��Mc�I��H���R  M���1  �I*��X�  f.�  ��  J�4�    �A���I��H�EH��M����  H���M  L�}I��fD  A�I��f��u�I)�I��Mu L���i���H��H��H��u�  �H��H��M���   �I�����u�E �M���Hc�I�ωE EH�I��    �E
H��H9�r�f�  M��k��$   �����f�     H���m���A��!f�[�H�Q��   ���    �Ƀ�]tLH��f��� H�Ff�
�H��f��-u��NH�Ff��]t>f��� f�-�H�Ff�J�NH���Ƀ�]u��K   H�Jf�]��g����    �-   두f�A!�H�Q�m����H�|$H��$@  M���  M��H�$H���  H��H�D$H���������������kH�� @  []A\A]A^� �C�u��   ��   �����H��$@  �kH��L����������f.�     H�=  �L���H���K����������W���H���2����kA�U M���R����E f�H��f���Q���H��I���  �	D  H��H9��2����E f�H��f��u�����L������fD  AUATI��UH��SH���f��{twL�l$H���    f��{t"f��u=L��H������H��[]A\A]��    L��L��H��H���O   ��t��fD  H����f.�     �D$H��[]A\A]Ðf�}u�f� �w����fff.�     AWH��AVAUATUSH��H��   H9�L�|$M��t0L�|$H��M����:H��fA�} I��H9�u�H�VH)�H��H�tFfA�E   �~L�Ff����   ��L��E1��+f.�     f��{��   f��}��   H���u f��tOf��[u�H���u f����   f��]H����    H���f��t�f��]u�f��t��pH�hf��u�@ H��L��H�L$����H�L$�H��   1�[]A\A]A^A_�D  H��A���u �k����    E��tA���N���f.�     ��H���L9�M��s�I�    f��,tGI��L9�r3A�<$f��[��   v�f��{��   f��}u�E��tI��A��L9�s��    �R���E��u�M9�L��L��L��s*�     �0H��f�2H��L9�r�I��K� H��I�tE1�@ �Tf�H��f��u�H��L��H�L$�6���H�L$M�D$M�ĉ�D���A���7���f�     I��A�$f��t:f��]L��t1f�     H���f������f��]u�f�������L�b�����L���� ��H��   �    �����   H�A    �A    �AH�Q�A    uY�����   L�GH��L��$�  �	D  I��f�H��L9�sA���u�@��f�   x~H��H�������H��   � D�E��trL�OH�T$L��$�  �"@ fD�B�H��L9�s�E�H��E��t�I��A��\u�E��\@  E��t
D��I����@f�B�H���� H��H������H��   �H���]������������������t��
���H������HH�] H��8[]A\A]A^A_�@ 1�������8�����H�������H� 1�L�<�������8����L���"   1�H������I������ 1������8����H�
  H��
  M��1�H�T$(H�L$ �k����8�d���L��H������1�H���O����8�H���H�L$ H�T$(H�5�  H��M��I��1�L�l$H�L$H�$H��L������L�5}
  L�-_
  L��L���D  AV1�AUATUH��SH��������8�����H�������1�H�������8�����H������H�1�D�"H��H������8����H������Ic�H��HH��H)�H�����\  1��s����8�l���H���T���H� �@# ��   1��P����8�I���H������H��1�A���3����8Mc��)���H���!���H� N�$�A�D$
  L��1�����1�H��������8����H��H�������H�1������8����H������H�H��[]A\A]A^�f�1������8�z���H���"���1�H�(�h����8�a���H���I���H� H�@H�l� �
���H�	
  Jc�H����    1��)����8�"���H�T$�   L��H���m���L�t$I�������     H�=8	  �   L��A�@   �����8������ 1�H��������8����H�������H� H)�H����  1�L�k�����8����H���<���1�H�C�����8�z���L��H��H�������E@t1��_����8�X���H��H�������I�]I�m�����     H�=i  �   L��A�    �����8��C����.���fD  A�E	<E��  <G��z  <A�
���H�=�  �   L��I�����������8������������    A�E	<R�  <S������H�=�  �   L��A�   �����8����������A�E��A<�����H�I  ��Hc�H���@ H�=�  �	   L��A�   �����8��[����F���fD  H�=�  �   L��A�   �����8��+�������fD  1�������8�����H��H�޹   H�������H���!���H�=�  �
   L��������1������8����H���:���Hc�  H� H��Lc ����H�=`  �
   L��A�   �����8�������z���H�=+  �
   L��A� @  �����8��e����P���H�=�  �
   L��A�   �����8��;����&���H�=�  �
   L��I�����������8����������H�=�  �
   L��A��   �����8�����������f�     H�=�  �   L��A�    �����8����������fD  H�=�  �   L��A�   �����8�������n���fD  H�=_  �   L��A�   �����8��S����>���1������8����H��  H��H���~���fD  AW1�AVAUATI��USH��X������8�����H�������1�H�������8�����H������H�1�D�2H��H������8Ic�H������H������H(H��H)�H��H�����'  Hc�1�A��H��Mc�H)��^����8�W���H���O���H� J���@
G       l   (����    G� r
G    d   �   ����   B�B�B �E(�D0�A8�G�3
8A0A(B BBBDl
8F0A(B BBBE    �   P���           d     H���j   B�B�B �E(�A0�D8�GP�
8A0A(B BBBA|
8F0A(B BBBE     D   t  P����   B�H�B �A(�D0�J�j
0A(A BBBC    L   �  ����=   B�B�H �B(�D0�D8�J�A�
8A0A(B BBBK        ����           $   $  �����    A��
E[
G     \   L  H���:   B�B�E �A(�A0�JЀT
0A(A BBBG�
0A(A BBBD   L   �  (����    B�B�D �D(�D@r
(A ABBHx
(A ABBB    L   �  �����   B�E�B �B(�A0�A8�J�@�
8C0A(B BBBF    $   L  ����   I�@�
Dz
A        t  ����           L   �  �����   B�D�B �B(�A0�A8�Dp�
8A0A(B BBBE    D   �  X����   B�D�B �A(�D0�D@T
0A(A BBBC    L   $  ����   B�D�B �B(�D0�A8�D��
8A0A(B BBBA           ��������        ��������                �F                           �      
       b                           pH             �                           �             H             �       	              ���o          ���o           ���o    r
                 h             �      �                                    c             �      �      �                            n             �      �      �&                             t             X?      X?                                    z             h?      h?                                   �             xA      xA      �                              �             B      B      t                             �             �F      �F                                    �             �F      �F                                    �             �F      �F                                    �             �F      �F                                    �             �F      �F      �                           �             @H      @H      0                             �             pH      pH                                  �             xJ      xJ                                    �             �J      |J                                    �                      |J                                                          �J      �                              FILE   7da4498f/auto/IO/IO.so  K�ELF          >    0      @       E          @ 8  @                                 �?      �?                     @       @       @                                 0@      0@      0@      �      �                   �      �      �      $       $              P�td   p<      p<      p<      �       �              Q�td                                                           GNU ے�_{��塹���5:��       <         � H��
                     }                     ?                     �                                          !                     M                     r                      ?                     I                     0                     �                      �                                          }                     �                                          �                      �                     �                     �                      �                     �                     �                      �                     r                     �                     �    �!      W           X9              �    �'      �          	 �              d    �*      �      �   ��D              �     �7      9      �   �� D              �    0%      �       �   ��D              �     #      �      x    P)      �          �0            �     @6      �      O    �,      �      �    �$      u       ?            �      �     �3      b      �     &      �      '    �.      @       __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses boot_IO Perl_Istack_sp_ptr Perl_Imarkstack_ptr_ptr Perl_Istack_base_ptr Perl_newSVpv Perl_new_version Perl_sv_derived_from Perl_vcmp XS_IO__Seekable_getpos Perl_newXS XS_IO__Seekable_setpos XS_IO__File_new_tmpfile XS_IO__Poll__poll XS_IO__Handle_blocking Perl_newXS_flags XS_IO__Handle_ungetc XS_IO__Handle_error XS_IO__Handle_clearerr XS_IO__Handle_untaint XS_IO__Handle_flush XS_IO__Handle_setbuf XS_IO__Handle_setvbuf XS_IO__Handle_sync XS_IO__Socket_sockatmark Perl_gv_stashpvn Perl_newSViv Perl_newCONSTSUB Perl_Iunitcheckav_ptr Perl_Iscopestack_ix_ptr Perl_call_list Perl_Isv_yes_ptr Perl_sv_2pv_flags Perl_form Perl_get_sv Perl_vstringify Perl_croak Perl_sv_2io Perl_PerlIO_fileno Perl_sv_newmortal Perl_sv_setiv Perl_sv_setpvn Perl_croak_xs_usage fsync __errno_location Perl_croak_nocontext Perl_PerlIO_flush Perl_Iop_ptr Perl_mg_set Perl_Icurpad_ptr Perl_PerlIO_clearerr Perl_PerlIO_error Perl_sv_2iv_flags PerlIO_ungetc fcntl Perl_sv_2mortal Perl_Isv_undef_ptr Perl_newSV Perl_sv_free Perl_sv_free2 PerlIO_tmpfile Perl_newGVgen Perl_hv_common_key_len Perl_do_openn Perl_newRV Perl_gv_stashpv Perl_sv_bless PerlIO_setpos PerlIO_getpos libc.so.6 _edata __bss_start _end GLIBC_2.2.5                                                                                                                                            �         ui	   �      (@             (@      �A         G           �A         B           �A         H           �A                    �A         	           �A         >           �A         K           �A         N           �A                    �A         @            B         M           B         F           B         I           B         O            B         <           (B         J           0B         D           PB                    XB                    `B                    hB                    pB                    xB                    �B         
           �B                    �B                    �B         
   �@����%B+  h   �0����%:+  h   � ����%2+  h
+  h   ������%+  h   �����%�*  h   �����%�*  h   �����%�*  h   �����%�*  h   �p����%�*  h   �`����%�*  h   �P����%�*  h   �@����%�*  h   �0����%�*  h   � ����%�*  h   �����%�*  h   � ����%�*  h   ������%�*  h    ������%�*  h!   ������%�*  h"   ������%�*  h#   �����%z*  h$   �����%r*  h%   �����%j*  h&   �����%b*  h'   �p����%Z*  h(   �`����%R*  h)   �P����%J*  h*   �@����%B*  h+   �0����%:*  h,   � ����%2*  h-   �����%**  h.   � ����%"*  h/   ������%*  h0   ������%*  h1   ������%
*  h2   ������%*  h3   �����%�)  h4   �����%�)  h5   �����%�)  h6   �����%�)  h7   �p���H��H��'  H��t��H��Ð��������U�=�)   H��ATSubH�=�'   tH�=�%  �:���H��%  L�%�%  H��)  L)�H��H��H9�s D  H��H�m)  A��H�b)  H9�r��N)  [A\��f�     H�=H%   UH��tH��&  H��tH�=/%  ���@ �Ð�����AWAVAUATUSH��H��8�*���H��L�8�����H�H��D�*H��H�����H��L�0E�e����H� Mc�J�,�    J���@
   H���%���1�H��I������H��  H��L��H�������   H���v���H��  H��L��H��������   H���T���H��  H��L��H�������1�H���5���H��  H��L��H�������   H������H��  H��L��H�������   H�������H�l  H��L��H���l���H������H�8 t H������H��L� �����0H��L������H��I�������L H�������H��I�$�����H��I������H(I�,$H��8[]A\A]A^A_� H������H� �"   1�H��J�4�����H�D$(�����H�T$(H�
   H��J�4�������H�O  H��H���i���f�     H�\$�H�l$�H��L�d$�L�l$�H��L�t$�H��(�����H��L�(����H�H��D�"H��H�����Ic�H��HI)�I��A���  H��A���a���H� Mc�H��J�,�    J�4�����H� H�p8H����   H��I���|���������H��A������L0H���O���A���I�tE��tQH�������H� Ic�H��J�4�����H���/���H��I�������H(I�,$H�$H�l$L�d$L�l$L�t$ H��(�H������H� H�  �
