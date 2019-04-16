#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   lib.sh of /CoreOS/systemd/Library/nspawn
#   Description: A library for operations with nspawn containers
#   Author: Frantisek Sumsal <fsumsal@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2016 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   library-prefix = nspawn
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 NAME

systemd/nspawn - A library for operations with nspawn containers

=head1 DESCRIPTION

This library provides functions for manipulation with nspawn containers.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 VARIABLES

=over

=item nspawnBEAKER_DEPS

Necessary dependencies for tests written in beakerlib.

=over

=item nspawnTEMPLATE_PATH

This variable gets populated by nspawnPrepareTemplate function and contains
location of the nspawn container which works as a template for other
functions.

=over

=item nspawnOS_VER

Version of the current OS.

=over

=item nspawnYUM_BASE

Base yum command for preparation of nspawn containers.

=back

=cut

# Temporarily remove rhts-test-env from dependencies, until the
# /usr/bin/python symlink issue is resolved
nspawnBEAKER_DEPS="beakerlib beakerlib-redhat"
nspawnTEMPLATE_PATH=""
nspawnOS_VER="$(rlGetDistroRelease)"

if [[ $nspawnOS_VER -ge 8 ]]; then
    nspawnPKG_MAN="dnf"
else
    nspawnPKG_MAN="yum"
fi
nspawnYUM_BASE="$nspawnPKG_MAN --enablerepo beaker-harness -y --releasever $nspawnOS_VER --nogpgcheck"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=back
=cut

# Prepare a template container
#   $1 - root directory for template container
#
# Create a minimal container which is used as a template for
# future containers. This container contains a minimal (and bootable) OS tree
# (yum's 'minimal' group). This function also ensures that this container
# has a correct SELinux context and valid repositories for any future
# package installations. Dependencies for tests written in Beakerlib
# are installed as well.
function nspawnPrepareTemplate() {
    rlLogInfo "Prepare nspawn template"
    if [[ -z $1 ]]; then
        nspawnTEMPLATE_PATH="$(mktemp -d template.XXXXXX -p "$1")"
    else
        nspawnTEMPLATE_PATH="$(mktemp -d /var/tmp/template.XXXXXX)"
    fi
    if [[ -z $nspawnTEMPLATE_PATH ]]; then
         rlDie "Template name cannot be empty"
    fi

    local EC=0
    rlGetPhaseState
    local STATE=$?
    # Install the base OS tree
    rlRun "$nspawnYUM_BASE --installroot $nspawnTEMPLATE_PATH groupinstall 'Minimal Install'"
    # Copy all host's repositories into the container
    rlRun "cp -f /etc/yum.repos.d/* $nspawnTEMPLATE_PATH/etc/yum.repos.d/"
    # Set a correct SELinux context for the container
    local SECONTEXT
    if rlIsRHEL ">=7.5"; then
        SECONTEXT="container_file_t"
    else
        SECONTEXT="svirt_sandbox_file_t"
    fi
    rlRun "semanage fcontext -a -t $SECONTEXT '$nspawnTEMPLATE_PATH(/.*)?'"
    rlRun "restorecon -R $nspawnTEMPLATE_PATH"
    # Install necessary Beakerlib dependencies
    rlRun "$nspawnYUM_BASE --installroot $nspawnTEMPLATE_PATH install $nspawnBEAKER_DEPS"
    # Check if any command in this function failed
    rlGetPhaseState
    if [[ $? -ne $STATE ]]; then
        EC=1
    fi

    return $EC
}

# Remove the template's data directory
function nspawnCleanupTemplate() {
    if [[ ! -z $nspawnTEMPLATE_PATH && -d $nspawnTEMPLATE_PATH ]]; then
        rm -fr "$nspawnTEMPLATE_PATH"
    fi
}

# Wait for container PID to die (or help it with SIGKILL) and remove its directory
# Params:
#   $1 - PID of the container
#   $2 - container directory
function nspawnKillAndDestroy() {
    if [ $# -ne 2 ]; then
        echo >&2 "nspawnKillAndDestroy: Invalid arguments"
        return 1
    fi

    local PID=$1
    local DIR="$2"

    # First SIGTERM to start normal shutdown
    kill -SIGTERM $PID
    sleep 5
    # Second SIGTERM to start force shutdown
    kill -0 $PID && kill -SIGTERM $PID && sleep 2
    # SIGKILL if the process still exists
    kill -0 $PID && kill -SIGKILL $PID && sleep 2

    if kill -0 $PID; then
        echo >&2 "Couldn't kill $PID even with SIGKILL, giving up..."
        return 1
    fi

    echo "Removing $DIR"
    rm -fr "DIR"

    return $?
}

# Create an nspawn container from the template
# Params:
#   $1 - path where the VM will be created
#
# This functions simply copies the template directory to the given destination,
# thus the function nspawnPrepareTemplate MUST be called before.
# This saves time in tests which require more than one container, as the
# setup phase is somewhat time consuming.
function nspawnCreateContainer() {
    if [[ -z $nspawnTEMPLATE_PATH  || ! -d $nspawnTEMPLATE_PATH ]]; then
        rlDie "nspawnTEMPLATE_PATH cannot be empty (missing init phase?)"
    elif [[ -z $1 ]]; then
        rlDie "Missing destination path"
    fi

    if [[ ! -d $1 ]]; then
        if ! mkdir -p "$1"; then
            rlFail "Couldn't create a nspawn container directory"
            return 1
        fi
    fi

    if ! cp -a "$nspawnTEMPLATE_PATH/." "$1/"; then
        rlFail "Couldn't create a nspawn container"
        return 1
    fi

    return 0
}

# Install the same package version as found on the host system into
# a nspawn container
#   $1 - package name
#   $2 - path to the nspawn container
#
# This function retrieves the given package's version from a local RPM database,
# and tries to download it and install it in the container.
function nspawnInstallCurrentPkg() {
    if [[ -z $1 ]]; then
        rlDie "Missing a package name to install"
    fi
    if [[ -z $2 || ! -d $2 ]]; then
        rlDie "Invalid nspawn container/template path"
    fi

    local CONT_PATH="$(readlink -f "$2")"
    local TEMPDIR="$(mktemp -d)"
    if [[ -z $TEMPDIR || ! -d $TEMPDIR ]]; then
        rlDie "Failed to create a temp directory"
    fi

    pushd "$TEMPDIR"
    local RPMNAME="$(rpm -q --qf '%{name}\n' $1 | tail -n 1)"
    local RPMVER="$(rpm -q --qf '%{version}\n' $1 | tail -n 1)"
    local RPMREL="$(rpm -q --qf '%{release}\n' $1 | tail -n 1)"
    local RPMARCH="$(rpm -q --qf '%{arch}\n' $1 | tail -n 1)"
    local RPMFULL="$RPMNAME $RPMVER $RPMREL $RPMARCH"
    echo "RPM package parts: $RPMFULL"
    rlRpmDownload $RPMNAME $RPMVER $RPMREL $RPMARCH
    if [[ $? -ne 0 ]]; then
        rlFail "Failed to download $RPMFULL"
        return 1
    fi

    local LOG_FILE="$(mktemp)"
    $nspawnYUM_BASE --installroot "$CONT_PATH" install *.rpm &>"$LOG_FILE"
    EC=$?
    cat "$LOG_FILE"
    if grep -q -i "Error: Nothing to do" "$LOG_FILE"; then
        EC=0
    fi

    popd
    rm -fr "$TEMPDIR" "$LOG_FILE"

    return $EC
}

# Get a list of all currently installed packages and try to install
# the same version of them into given nspawn container
#   $1 - path to the nspawn container
#
# Warning: This function can take a really long time
function nspawnInstallEnvFromBrew() {
    if [[ -z $1 || ! -d $1 ]]; then
        rlDie "Invalid nspawn container/template path"
    fi

    local CONT_PATH="$(readlink -f "$1")"
    local TEMPDIR="$(mktemp -d)"
    if [[ -z $TEMPDIR || ! -d $TEMPDIR ]]; then
        rlDie "Failed to create a temp directory"
    fi

    pushd "$TEMPDIR"
    while read name ver rel arch; do
        rlRpmDownload $name $ver $rel $arch
        if [[ $? -ne 0 ]]; then
            rlLogError "Failed to download package $name-$ver-$rel-$arch"
        fi
    done <<< "$(rpm -qa --qf "%{name} %{version} %{release} %{arch}\n")"

    $nspawnYUM_BASE --installroot "$CONT_PATH" install *.rpm
    popd
    rm -fr "$TEMPDIR"

    return 0
}

# Install a package (or a set of packages) into a specified nspawn container
#   $1 - package name(s)
#   $2 - path to the nspawn container
function nspawnInstallPkg() {
    if [[ -z $1 ]]; then
        rlDie "Missing a package name to install"
    fi
    if [[ -z $2 || ! -d $2 ]]; then
        rlDie "Invalid nspawn container/template path"
    fi

    local CONT_PATH="$(readlink -f "$2")"
    $nspawnYUM_BASE --installroot "$CONT_PATH" install $1

    return $?
}

# Reinstall a package (or a set of packages) in a specified nspawn container
#   $1 - package name(s)
#   $2 - path to the nspawn container
function nspawnReinstallPkg() {
    if [[ -z $1 ]]; then
        rlDie "Missing a package name to reinstall"
    fi
    if [[ -z $2 || ! -d $2 ]]; then
        rlDie "Invalid nspawn container/template path"
    fi

    local CONT_PATH="$(readlink -f "$2")"
    $nspawnYUM_BASE --installroot "$CONT_PATH" reinstall $1

    return $?
}

# Get a version of a package installed in the container
#   $1 - package name
#   $2 - path to the nspawn container
#
# This is a simple wrapper around the rpm command, which sets a correct
# --root path to the RPM database.
function nspawnPkgVer() {
    if [[ -z $1 ]]; then
        rlDie "Missing package name"
    fi
    if [[ -z $2 || ! -d $2 ]]; then
        rlDie "Invalid nspawn container/template path"
    fi

    local CONT_PATH="$(readlink -f "$2")"
    rpm --root "$CONT_PATH" -q "$1"

    return $?
}

# Install host's systemd version into the given template/container
#   $1 - template/container path
function nspawnInstallHostsSystemd() {
    if [[ -z $1 ]]; then
        rlDie "Missing template/container path"
    fi

    local EC=0
    rlGetPhaseState
    local STATE=$?
    local CONT_PATH="$(readlink -f "$1")"
    local RPM_FORMAT="%{name} %{version} %{release} %{arch}\n"
    local GREP_EXPR="(^systemd|^libgudev)"

    while read name ver rel arch; do
        rlRpmDownload $name $ver $rel $arch
        if [[ $? -ne 0 ]]; then
            rlLogError "Failed to download package $name-$ver-$rel-$arch"
        fi
    done <<< "$(rpm -qa --qf "$RPM_FORMAT" | grep -P "$GREP_EXPR" | grep -v "CoreOS")"

    # Workaround for "Error: nothing to do" message by installation of already
    # installed beakerlib package
    rlRun "$nspawnYUM_BASE --installroot '$CONT_PATH' install beakerlib *.rpm"
    rlRun "$nspawnYUM_BASE --installroot '$CONT_PATH' update *.rpm"
    rlRun "rm -f *.rpm"

    rlGetPhaseState
    if [[ $? -ne $STATE ]]; then
        EC=1
    fi

    return $EC
}
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Execution
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 EXECUTION

=back

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.

function nspawnLibraryLoaded() {
    if [[ -z $nspawnOS_VER ]]; then
        rlDie "Couldn't determine OS version"
    fi

    # Install dependencies
    local deps
    if [[ $nspawnOS_VER -ge 8 ]]; then
        if ! rpm -q yum-utils; then
            deps+="dnf-utils "
        fi
        deps+="policycoreutils-python-utils systemd-container"
    else
        deps+="yum-utils policycoreutils-python"
    fi

    if ! $nspawnYUM_BASE install $deps; then
        rlDie "Failed to install library dependencies"
    fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Authors
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Frantisek Sumsal <fsumsal@redhat.com>

=back

=cut
