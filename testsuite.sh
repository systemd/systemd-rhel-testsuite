#!/bin/bash
# Run the downstream RHEL testsuite using the standard test roles framework (STR).
# Without arguments all *enabled* tests recognized by FMF (Flexible Metadata Format)
# will be executed, i.e. all tests which have the main.fmf metadata file in
# their directory and don't have the 'disabled' tag set. If an argument
# is specified, it is passed to the STR as a FMF filter to specify a subset
# of tests from the testsuite.
# FIXME: better documentation

set -e

## Sanity check
# The environment should already contain necessary 'base' packages
# for ansible, beakerlib, and standard test roles
REQUIRED_BINARIES=(ansible str-filter-tests)
REQUIRED_PATHS=(
    "/usr/share/beakerlib/beakerlib.sh"
)

for binary in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "$binary" > /dev/null; then
        echo >&2 "Missing required binary: '$binary'"
        exit 1
    fi
done

for path in "${REQUIRED_PATHS[@]}"; do
    if [[ ! -e $path ]]; then
        echo >&2 "Missing required path: '$path'"
        exit 1
    fi
done

## Source custom environment settings
. "$(dirname "$0")/setup-env.sh"

ANSIBLE_ARGS=(--extra-vars=beakerlib_libraries_path="$BEAKERLIB_LIBRARY_PATH")
TEST_ARTIFACTS="${TEST_ARTIFACTS:-$PWD/artifacts-$(date --iso=minutes)}"

if [[ -n $1 ]]; then
    ANSIBLE_ARGS+=(--extra-vars="fmf_filter='$1'")
fi

# Cleanup artifact directories, so we get the most relevant test results
rm -fr /tmp/artifacts
if [[ -e $TEST_ARTIFACTS ]]; then
    rm -fr "$TEST_ARTIFACTS"
fi

export TEST_ARTIFACTS
ansible-playbook "${ANSIBLE_ARGS[@]}" tests.yml
