package ksb::FirstRun 0.10;

use 5.014;
use strict;
use warnings;
use File::Spec qw(splitpath);

use ksb::BuildException;
use ksb::Debug qw(colorize);
use ksb::OSSupport;
use ksb::Util;

=head1 NAME

ksb::FirstRun

=head1 DESCRIPTION

Performs initial-install setup, implementing the C<--initial-setup> option.

B<NOTE> This module is supposed to be loadable even under minimal Perl
environments as fielded in "minimal Docker container" forms of popular distros.

=head1 SYNOPSIS

    my $exitcode = ksb::FirstRun::setupUserSystem();
    exit $exitcode;

=cut

sub setupUserSystem
{
    my $baseDir = shift;
    my $os = ksb::OSSupport->new;

    eval {
        _installSystemPackages($os);
        _setupBaseConfiguration($baseDir);
        _setupBashrcFile();
    };

    if (had_an_exception($@)) {
        my $msg = $@->{message};
        say colorize ("  b[r[*] r[$msg]");
        return 1;
    }

    return 0;
}

# Internal functions

# Reads from the __DATA__ section below and dumps the contents in a hash keyed
# by filename (the @@ part between each resource).
my %packages;
sub _readPackages
{
    return \%packages if %packages;

    my $cur_file;
    my $cur_value;
    my $commit = sub {
        return unless $cur_file;
        $packages{$cur_file} = ($cur_value =~ s/ *$//r);
        $cur_value = '';
    };

    while(my $line = <DATA>) {
        next if $line =~ /^\s*#/ and $cur_file !~ /sample-rc/;
        chomp $line;

        my ($fname) = ($line =~ /^@@ *([^ ]+)$/);
        if ($fname) {
            $commit->();
            $cur_file = $fname;
        }
        else {
            $cur_value .= "$line\n";
        }
    }

    $commit->();
    return \%packages;
}

sub _throw
{
    my $msg = shift;
    die (make_exception('Setup', $msg));
}

sub _installSystemPackages
{
    my $os = shift;
    my $vendor = $os->vendorID;
    my $osVersion = $os->vendorVersion;

    print colorize(<<DONE);
 b[-] Installing b[system packages] for b[$vendor]...
DONE

    my @packages = _findBestVendorPackageList($os);
    if (@packages) {
        my @installCmd = _findBestInstallCmd($os);
        say colorize (" b[*] Running b[" . join(' ', @installCmd) . "]");
        my $result = system (@installCmd, @packages);
        if ($result >> 8 == 0) {
            say colorize (" b[*] b[g[Looks like the necessary packages were successfully installed!]");
        } else {
            say colorize (" r[b[*] Ran into an error with the installer!");
        }
    } else {
        say colorize (" r[b[*] Packages could not be installed, because kdesrc-build does not know your linux distribution.");
    }
}

sub _setupBaseConfiguration
{
    my $baseDir = shift;

    if (-e "kdesrc-buildrc" || -e "$ENV{HOME}/.kdesrc-buildrc") {
        print colorize(<<DONE);
 b[-] You b[y[already have a configuration file].
DONE
    } else {
        print colorize(<<DONE);
 b[-] Installing b[sample configuration file]...
DONE

        my $sampleRc = $packages{'sample-rc'} or
            _throw("Embedded sample file missing!");

        my $numCpus = `nproc 2>/dev/null` || 4;
        $sampleRc =~ s/%\{num_cpus}/$numCpus/g;
        $sampleRc =~ s/%\{base_dir}/$baseDir/g;

        open my $sampleFh, '>', "$ENV{HOME}/.kdesrc-buildrc"
            or _throw("Couldn't open new ~/.kdesrc-buildrc: $!");

        print $sampleFh $sampleRc
            or _throw("Couldn't write to ~/.kdesrc-buildrc: $!");

        close $sampleFh
            or _throw("Error closing ~/.kdesrc-buildrc: $!");
    }
}

sub _setupBashrcFile
{
    my $modifiedBashrc = 0;
    
    # Add kdesrc-build path to PATH if not already in there
    if (!ksb::Util::isInPath('src/kdesrc-build')) {
        
        say colorize(<<DONE);
 b[-] Amending your ~/.bashrc to b[also point to install dir]...
DONE
        open(my $bashrc, '>>', "$ENV{HOME}/.bashrc") or _throw("Couldn't open ~/.bashrc: $!");
        
        print $bashrc "\n# Adding the kdesrc-build directory to the path\n";
        print $bashrc 'export PATH="$HOME/kde/src/kdesrc-build:$PATH"';
        print $bashrc "\n";
        
        $modifiedBashrc = 1;
    }
    
    # Create kdesrc-run alias for more convenient program execution
    if (!ksb::Util::fileHasLine("$ENV{HOME}/.bashrc", "kdesrc-run ()")) {
        say colorize(<<DONE);
 b[-] Amending your ~/.bashrc to b[add kdesrc-run alias]...
DONE
        open(my $bashrc, '>>', "$ENV{HOME}/.bashrc") or _throw("Couldn't open ~/.bashrc: $!");
        
        print $bashrc "\n# Creating alias for running software built with kdesrc-build\n";
        print $bashrc "kdesrc-run ()\n";
        print $bashrc "{\n";
        print $bashrc '  source "$HOME/kde/build/$1/prefix.sh" && "$HOME/kde/usr/bin/$1"';
        print $bashrc "\n}\n";
        
        $modifiedBashrc = 1;
    }

    
    
    if ($modifiedBashrc) {
        say colorize(<<DONE);
 b[-] Your b[y[~/.bashrc has been successfully setup].
DONE
    } else {
        say colorize(<<DONE);
 b[-] Your b[y[~/.bashrc is already setup].
DONE
    }
}



sub _findBestInstallCmd
{
    my $os = shift;
    my $pkgsRef = _readPackages();

    my @supportedDistros =
        map  { s{^cmd/install/([^/]+)/.*$}{$1}; $_ }
        grep { /^cmd\/install\// }
            keys %{$pkgsRef};

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    say colorize ("    Using installer for b[$bestVendor]");

    my $version = $os->vendorVersion();
    my @cmd;

    for my $opt ("$bestVendor/$version", "$bestVendor/unknown") {
        my $key = "cmd/install/$opt";
        next unless exists $pkgsRef->{$key};
        @cmd = split(' ', $pkgsRef->{$key});
        last;
    }

    _throw("No installer for $bestVendor!")
        unless @cmd;

    # If not running as root already, add sudo
    unshift @cmd, 'sudo' if $> != 0;

    return @cmd;
}

sub _findBestVendorPackageList
{
    my $os = shift;

    # Debian handles Ubuntu also
    my @supportedDistros =
        map  { s{^pkg/([^/]+)/.*$}{$1}; $_ }
        grep { /^pkg\// }
            keys %{_readPackages()};

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    my $version = $os->vendorVersion();
    say colorize ("    Installing packages for b[$bestVendor]/b[$version]");
    return _packagesForVendor($bestVendor, $version);
}

sub _packagesForVendor
{
    my ($vendor, $version) = @_;
    my $packagesRef = _readPackages();

    foreach my $opt ("pkg/$vendor/$version", "pkg/$vendor/unknown") {
        next unless exists $packagesRef->{$opt};
        my @packages = split(' ', $packagesRef->{$opt});
        return @packages;
    }

    return;
}

1;

__DATA__
@@ pkg/debian/unknown
libyaml-libyaml-perl libio-socket-ssl-perl libjson-xs-perl
git shared-mime-info cmake build-essential flex bison gperf libssl-dev intltool
liburi-perl gettext

@@ pkg/opensuse/unknown
cmake
docbook-xsl-stylesheets
docbook_4
flex bison
gettext-runtime
gettext-tools
giflib-devel
git
gperf
intltool
libboost_headers-devel
libqt5-qtbase-common-devel
libqt5-qtbase-private-headers-devel
libqt5-qtimageformats-devel    
libQt5Core-private-headers-devel
libQt5DesignerComponents5  
libxml2-tools
lmdb-devel
make
perl 
perl(IO::Socket::SSL)
perl(JSON)
perl(URI)
perl(YAML::LibYAML)
pkgconfig(libattr)
pkgconfig(libical)
pkgconfig(libpng)
pkgconfig(libqrencode)
pkgconfig(libudev)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(ModemManager)
pkgconfig(NetworkManager)
pkgconfig(openssl)
pkgconfig(Qt5Core)
pkgconfig(Qt5Multimedia)
pkgconfig(Qt5Qml)
pkgconfig(Qt5QuickControls2)
pkgconfig(Qt5Script)
pkgconfig(Qt5Svg)
pkgconfig(Qt5UiTools)
pkgconfig(Qt5WebKit)
pkgconfig(Qt5WebKitWidgets)
pkgconfig(Qt5X11Extras)
pkgconfig(Qt5XmlPatterns)
pkgconfig(sm)
pkgconfig(wayland-server)
pkgconfig(xcb-keysyms) 
pkgconfig(xrender)
polkit-devel
shared-mime-info

@@ pkg/fedora/unknown
bison
boost-devel
bzr
cmake
docbook-style-xsl
docbook-utils
doxygen
flex
gcc
gcc-c++
gettext
gettext-devel
giflib-devel
git
gperf
intltool
libxml2
make
pam-devel
perl(IO::Socket::SSL)
perl(IPC::Cmd)
perl(JSON::PP)
perl(URI)
perl(YAML::LibYAML)
pkgconfig(dbus-1)  
pkgconfig(gbm)
pkgconfig(gl) 
pkgconfig(gstreamer-1.0)
pkgconfig(libassuan)
pkgconfig(libattr)
pkgconfig(libnm)
pkgconfig(libpng)
pkgconfig(libqrencode)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(lmdb)
pkgconfig(ModemManager)
pkgconfig(openssl)
pkgconfig(polkit-gobject-1)
pkgconfig(sm)
pkgconfig(wayland-client)
pkgconfig(wayland-protocols)
pkgconfig(xapian-core)
pkgconfig(xcb-cursor)
pkgconfig(xcb-ewmh)
pkgconfig(xcb-keysyms)
pkgconfig(xcb-util)
pkgconfig(xfixes)
pkgconfig(xrender)
python
shared-mime-info
texinfo
systemd-devel

@@ pkg/mageia/unknown

bison
boost
cmake
docbook-style-xsl
docbook-utils
flex
gcc
gcc-c++
gettext
gettext-devel
giflib
git
gperf
intltool
lib64lmdb-devel
make
perl(IO::Socket::SSL) 
perl(IPC::Cmd)
perl(JSON::PP) 
perl(URI)
perl(YAML::LibYAML) 
pkgconfig(dbus-1)
pkgconfig(gl) 
pkgconfig(gstreamer-1.0)
pkgconfig(libattr)
pkgconfig(libnm)
pkgconfig(libpng)
pkgconfig(libqrencode)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(ModemManager)
pkgconfig(openssl)
pkgconfig(polkit-gobject-1)
pkgconfig(sm)
pkgconfig(wayland-client)
pkgconfig(xcb-keysyms)
pkgconfig(xrender)
python
shared-mime-info


@@ pkg/gentoo/unknown
dev-util/cmake
dev-lang/perl

@@ pkg/arch/unknown
perl-json perl-yaml-libyaml perl-io-socket-ssl
cmake gcc make qt5-base
doxygen

@@ cmd/install/debian/unknown
apt-get -q -y --no-install-recommends install

@@ cmd/install/opensuse/unknown
zypper install -y --no-recommends

@@ cmd/install/arch/unknown
pacman -Syu --noconfirm --needed

@@ cmd/install/fedora/unknown
dnf -y install

@@ sample-rc
# This file controls options to apply when configuring/building modules, and
# controls which modules are built in the first place.
# List of all options: https://go.kde.org/u/ksboptions

global
    # Paths

    kdedir ~/kde/usr # Where to install KF5-based software
    qtdir  ~/kde/qt5 # Where to find Qt5

    source-dir ~/kde/src   # Where sources are downloaded
    build-dir  ~/kde/build # Where the source build is run

    ignore-kde-structure true # Use flat structure

    # Will pull in KDE-based dependencies only, to save you the trouble of
    # listing them all below
    include-dependencies true

    cmake-options -DCMAKE_BUILD_TYPE=RelWithDebInfo
    make-options  -j%{num_cpus}
end global

# With base options set, the remainder of the file is used to define modules to build, in the
# desired order, and set any module-specific options.
#
# Modules may be grouped into sets, and this is the normal practice.
#
# You can include other files inline using the "include" command. We do this here
# to include files which are updated with kdesrc-build.

# Qt and some Qt-using middleware libraries
include %{base_dir}/qt5-build-include
include %{base_dir}/custom-qt5-libs-build-include

# KF5 and Plasma :)
include %{base_dir}/kf5-qt5-build-include

# To change options for modules that have already been defined, use an
# 'options' block
options kcoreaddons
    make-options -j4
end options
