#!/bin/bash

set -e

_setup_env_at_exit() {
    # Cleanup the override dir if set, at exit
    if [[ -n $_OVERRIDE_DIR ]]; then
        rm -fr "$_OVERRIDE_DIR"
    fi
}

trap _setup_env_at_exit EXIT

# STR copies tests over to /var/str which breaks the internal Beakerlib library
# lookup. Let's workaround it by explicitly setting where it should look for
# the libraries.
# Beakerlib library machinery expects libraries to be found under a specific
# directory hierarchy. For example, library systemd/nspawn must be under
# whatever/systemd/Library/nspawn. Let's trick it by making a temporary
# override directory with a OVERRIDE_DIR/systemd/Library symlink to a local
# Library directory and setting the BEAKERLIB_LIBRARY_PATH accordingly.
_TEST_REPO_ROOT="$(dirname $(readlink -f "$0"))"
_OVERRIDE_DIR="$(mktemp -d "$_TEST_REPO_ROOT/.beakerlib-library-override.XXXXXX")"
mkdir "$_OVERRIDE_DIR/systemd"
ln -f -s "$_TEST_REPO_ROOT/Library" "$_OVERRIDE_DIR/systemd/Library"
export BEAKERLIB_LIBRARY_PATH="$_OVERRIDE_DIR"
