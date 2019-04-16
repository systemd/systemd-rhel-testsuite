#!/bin/bash

set -e

# STR copies tests over to /var/str which breaks the internal Beakerlib library
# lookup. Let's workaround it by explicitly setting where it should look for
# the libraries.
TEST_REPO_ROOT="$(dirname $(readlink -f "$0"))"
export BEAKERLIB_LIBRARY_PATH="$TEST_REPO_ROOT"
