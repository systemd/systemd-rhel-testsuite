#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Sanity/journalctl
#   Description: Basic test for journalctl
#   Author: Branislav Blaskovic <bblaskov@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2015 Red Hat, Inc.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="systemd"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlRun "TESTDIR=$(pwd)"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        rlImport "systemd/basic"
    rlPhaseEnd

if [ $REBOOTCOUNT -eq 0 ]
then
    # This needs to be run with in-memory journal
    rlPhaseStartTest "BZ#1082179 - error msg for in-memory journal"
        rlRun -s "journalctl -k -b -1 --no-pager"
        # Should be: Specifying boot ID has no effect, no persistent journal was found
        # Shouldn't be: Failed to look up boot -1: No such boot ID in journal
        # Also shouldn't be: Failed to look up boot -1: Cannot assign requested address
        rlAssertGrep "persistent journal" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "persistant storage setup"
        rlFileBackup "/etc/systemd/journald.conf"
        rlRun "echo 'Storage=persistent' >> /etc/systemd/journald.conf"
        rlRun "cat /etc/systemd/journald.conf"
    rlPhaseEnd
    rhts-reboot
elif [ $REBOOTCOUNT -eq 1 ]
then
    # Just rebooting to get some more boots in journal
    rhts-reboot
else
    rlPhaseStartTest "persistant storage test"
        rlRun -s "journalctl --list-boots"
        rlRun "journalctl -b -1 -l -n 10 --no-pager"
    rlPhaseEnd

    rlPhaseStartTest "Switch back to runtime journal"
        rlFileRestore
        rlRun "rm -fr /var/log/journal"
        rlRun "systemctl restart systemd-journald.service"
    rlPhaseEnd
fi

    rlPhaseStartTest
        rlRun "journalctl -r --no-pager | head -n 10"
    rlPhaseEnd

    rlPhaseStartTest "Check --reverse option"
        # journalctl options
        JCTLOPT="--utc SYSLOG_IDENTIFIER=check-journal \"PRIORITY=0\" \"PRIORITY=1\" \"PRIORITY=2\" \"PRIORITY=3\""
        # test journal path
        JRNLPATH="$TESTDIR/check-journal-testBasic-10.111.111.10-FAIL.journal/"
        # Expected output without --reverse option
        if rlIsRHEL 7; then
            EXPSOUT=$(echo -e "-- Logs begin at Wed 2015-04-15 10:01:03 GMT, end at Sat 2050-01-01 11:01:58 GMT. --\n" \
                    "Jan 01 11:00:12 m10 check-journal[2311]: BEFORE BOOT\n" \
                    "-- Reboot --\n" \
                    "Jan 01 11:00:47 m10 check-journal[2172]: AFTER BOOT")
        else
            EXPSOUT=$(echo -e "-- Logs begin at Wed 2015-04-15 10:01:03 UTC, end at Sat 2050-01-01 11:01:58 UTC. --\n" \
                    "Jan 01 11:00:12 m10 check-journal[2311]: BEFORE BOOT\n" \
                    "-- Reboot --\n" \
                    "Jan 01 11:00:47 m10 check-journal[2172]: AFTER BOOT")
        fi
        # Call journalctl with aforementioned arguments (and without --reverse)
        # and compare its output with content of $EXPSOUT
        rlRun "diff -w <(journalctl -D \"$JRNLPATH\" $JCTLOPT) <(echo \"$EXPSOUT\") &> log.out" 0 "journactl WITHOUT --reverse"
        rlRun "cat log.out" 0 "Print diff log"

        # Expected output with --reverse option
        if rlIsRHEL 7; then
            EXPROUT=$(echo -e "-- Logs begin at Wed 2015-04-15 10:01:03 GMT, end at Sat 2050-01-01 11:01:58 GMT. --\n" \
                    "Jan 01 11:00:47 m10 check-journal[2172]: AFTER BOOT\n" \
                    "-- Reboot --\n" \
                    "Jan 01 11:00:12 m10 check-journal[2311]: BEFORE BOOT")
        else
            EXPROUT=$(echo -e "-- Logs begin at Wed 2015-04-15 10:01:03 UTC, end at Sat 2050-01-01 11:01:58 UTC. --\n" \
                    "Jan 01 11:00:47 m10 check-journal[2172]: AFTER BOOT\n" \
                    "-- Reboot --\n" \
                    "Jan 01 11:00:12 m10 check-journal[2311]: BEFORE BOOT")
        fi
        # Call journalctl with same arguments as before, but now
        # with --reverse
        rlRun "diff -w <(journalctl -D \"$JRNLPATH\" --reverse $JCTLOPT) <(echo \"$EXPROUT\") &> log.out" 0 "journactl WITH --reverse"
        rlRun "cat log.out" 0 "Print diff log"
    rlPhaseEnd

    rlPhaseStartTest "SYSTEMD_COLORS env variable"
        # Env variable SYSTEMD_COLORS can be used to enable/disable
        # colored output. If SYSTEMD_COLORS is unset, value of TERM
        # variable is checked instead, where TERM="dumb" disables all
        # colors as well.
        RE_COLOR="\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]"
        LOG_TAG="systemd-color-test"
        # $1 - optional commands/settings before $BASECMD
        # $2 - description
        # $3 - expected grep EC
        function test_colors() {
            if [[ -z $2 || -z $3 ]]; then
                rlFail "[test_color] Missing arguments"
                return
            fi

            OUTFILE="$(mktemp journalctl_colors.XXXX)"
            BASECMD="journalctl -perr -t$LOG_TAG --no-pager"
            DESCR="$(echo "$1 $2" | xargs)"

            rlRun "script -q -c '$1 $BASECMD' '$OUTFILE'"
            rlRun "grep -P '$RE_COLOR' '$OUTFILE'" $3 "$DESCR"
            rm -f "$OUTFILE"
        }

        TERM_BAK="$TERM"
        export TERM="xterm"
        rlLogInfo "Current TERM=$TERM_BAK"
        rlLogInfo "Setting TERM=$TERM"

        rlRun "logger -t$LOG_TAG -perr 'COLO>RED< JOURNAL MESSAGE'"
        # colors_enabled() -> getenv("TERM") != "dumb" -> on_tty()
        test_colors "" "default (colors ENABLED)" 0
        # colors_enabled() -> getenv("TERM") == "dumb" -> false
        test_colors "TERM=dumb" "(colors DISABLED)" 1
        # colors_enabled() -> parse_boolean() == 0 -> false
        test_colors "SYSTEMD_COLORS=0" "(colors DISABLED)" 1
        # colors_enabled -> parse_boolean() == 1 -> true
        test_colors "SYSTEMD_COLORS=1" "(colors ENABLED)" 0
        # colors_enabed -> parse_boolean() == 1 -> true
        test_colors "SYSTEMD_COLORS=1 TERM=dumb" "(colors ENABLED)" 0
        # colors_enabled -> getenv("TERM") != "dumb" -> on_tty()
        test_colors "SYSTEMD_COLORS=0 TERM=xterm" "(colors DISABLED)" 1

        rlLogInfo "Restoring TERM=$TERM_BAK"
        export TERM="$TERM_BAK"
    rlPhaseEnd

    rlPhaseStartTest "journald backports - BZ#1318994"
        # https://github.com/lnykryn/systemd-rhel/pull/50/commits/c87355bc80da9e2cba7f7723d7c6568dfa56f1a1
        # Author: Jakub Martisko <jamartis@redhat.com>
        RANDOM_HELLO=$RANDOM
        rlRun "dd if=/dev/urandom bs=8k | od | systemd-cat &"
        RANDOM_PID=$!
        rlRun "systemd-run echo hello$RANDOM_HELLO &"
        rlRun "sleep 5" #make sure that "systemd-run echo hello &" got chance to do something
        rlRun -s "journalctl --output=verbose --no-pager --identifier=echo"
        rlAssertGrep "hello$RANDOM_HELLO" $rlRun_LOG
        rlRun "kill -9 $RANDOM_PID"
    rlPhaseEnd

    rlPhaseStartTest "Bug 947636 indexing by block device"
        rlRun "journalctl --no-pager $(blkid | grep "[vs]da" | head -n 1 | awk -F':' '{print $1}')"
    rlPhaseEnd

    rlPhaseStartTest "Avoid forever loop for journalctl --list-boots command [BZ#1294516]"
        rlImport "systemd/nspawn"
        rlRun "nspawnPrepareTemplate ." 0 "Prepare nspawn template"

        rlLogInfo "Install host's version of systemd into the container template"
        rlRun "nspawnInstallHostsSystemd $nspawnTEMPLATE_PATH"

        if ! rlGetPhaseState; then
            rlFail "Failed to prepare environment"
        else
            CONT_PATH="$(mktemp -d journalctl-list-boot-XXX)"
            rlRun "nspawnCreateContainer '$CONT_PATH'"
            rlRun "mkdir -p $CONT_PATH/var/log/journal"
            rlRun "systemd-nspawn -bD $CONT_PATH > /dev/null &"
            CONT_PID=$!
            rlRun "sleep 5"
            #MACHINE_ID="$(journalctl --header | grep -Pom 1 '(?<=Machine ID\: )(.+)$')"
            MACHINE_ID="$(cat $CONT_PATH/etc/machine-id)"
            rlRun "[[ ! -z $MACHINE_ID ]]" 0 "Check if \$MACHINE_ID is not empty"
            rlLogInfo "nspawn machine ID: $MACHINE_ID"
            rlRun "cp $TESTDIR/list-boots-loop/* $CONT_PATH/var/log/journal/$MACHINE_ID/"
            rlRun "systemctl -M $CONT_PATH restart systemd-journald"
            rlRun "timeout 10s strace journalctl --no-pager -M '$CONT_PATH' --list-boots"
            rlRun "kill -9 $CONT_PID"
            rlRun "rm -fr '$CONT_PATH'"
        fi

        rlRun "nspawnCleanupTemplate"
    rlPhaseEnd

    rlPhaseStartTest "sd_journal_process() - fix invalidation reporting [BZ#1446140]"
        rlRun "cp $TESTDIR/sd_journal_process.c ."
        rlRun "gcc -o sd_journal_process sd_journal_process.c -lsystemd"
        SD_APPEND=0
        SD_INVALIDATE=0

        for i in {0..9}; do
            sd_out="$(./sd_journal_process)"
            rlLogInfo "[#$i] Output: $sd_out"
            case "$sd_out" in
                append)
                    SD_APPEND=$(($SD_APPEND + 1))
                    ;;
                invalidate)
                    SD_INVALIDATE=$(($SD_INVALIDATE + 1))
                    ;;
                nop)
                    ;;
                *)
                    rlFail "Unexpected output: $sd_out"
            esac
        done

        rlLogInfo "SD_JOURNAL_APPEND count: $SD_APPEND"
        rlLogInfo "SD_JOURNAL_INVALIDATE count: $SD_INVALIDATE"
        rlRun "[[ $SD_APPEND > $SD_INVALIDATE ]]" 0 "SD_JOURNAL_APPEND > SD_JOURNAL_INVALIDATE"
        rlRun "rm -v sd_journal_process*"
    rlPhaseEnd

    rlPhaseStartTest "journald truncates lines at 2KB [BZ#1442262]"
        # Default LineMax
        LINE_MAX=$((48 * 1024))
        rlLogInfo "Max line size: $LINE_MAX"

        for cnt in $(($LINE_MAX-1)) $(($LINE_MAX+1)); do
            MESSAGE_ID="long$RANDOM"
            rlLogInfo "Generated message ID: $MESSAGE_ID"
            rlLogInfo "Message size: $cnt"
            rlRun "perl -e \"print 'a'x$cnt\" | systemd-cat -t $MESSAGE_ID"
            rlRun -s "journalctl --no-full -t $MESSAGE_ID"
            EXP_LINE_COUNT=$(($cnt/$LINE_MAX + 2))
            ACT_LINE_COUNT="$(wc -l < $rlRun_LOG)"
            rlLogInfo "Expected line count: $EXP_LINE_COUNT (header + log lines)"
            rlLogInfo "Actual line count: $ACT_LINE_COUNT"
            rlRun "[[ $ACT_LINE_COUNT -eq $EXP_LINE_COUNT ]]"
        done

        # LineMax=96K
        LINE_MAX=$((96 * 1024))
        rlLogInfo "Max line size: $LINE_MAX"

        rlFileBackup "/etc/systemd/journald.conf"
        rlRun "echo 'LineMax=$LINE_MAX' >> /etc/systemd/journald.conf"
        rlRun "systemctl restart systemd-journald.service"

        for cnt in $(($LINE_MAX-1)) $(($LINE_MAX+1)); do
            MESSAGE_ID="long$RANDOM"
            rlLogInfo "Generated message ID: $MESSAGE_ID"
            rlLogInfo "Message size: $cnt"
            rlRun "perl -e \"print 'a'x$cnt\" | systemd-cat -t $MESSAGE_ID"
            rlRun -s "journalctl --no-full -t $MESSAGE_ID"
            EXP_LINE_COUNT=$(($cnt/$LINE_MAX + 2))
            ACT_LINE_COUNT="$(wc -l < $rlRun_LOG)"
            rlLogInfo "Expected line count: $EXP_LINE_COUNT (header + log lines)"
            rlLogInfo "Actual line count: $ACT_LINE_COUNT"
            rlRun "[[ $ACT_LINE_COUNT -eq $EXP_LINE_COUNT ]]"
        done

        rlFileRestore
        rlRun "systemctl restart systemd-journald.service"
    rlPhaseEnd

    rlPhaseStartTest "Support for lz4 compressed journals [BZ#1431687]"
        rlRun "journalctl --no-pager -D $TESTDIR/journal-lz4-f27"
        rlRun "journalctl --no-pager --header -D $TESTDIR/journal-lz4-f27"
    rlPhaseEnd

    rlPhaseStartTest "Ignore invalid journal files [BZ#1465759]"
        EMPTY_JOURNAL="empty$RANDOM.journal"
        rlRun "journalctl --no-pager -D $TESTDIR/journal-rhel75"
        rlRun "touch $TESTDIR/journal-rhel75/$EMPTY_JOURNAL"
        rlRun "journalctl --no-pager -D $TESTDIR/journal-rhel75"
        rlRun "rm -fv $EMPTY_JOURNAL"
    rlPhaseEnd

    rlPhaseStartTest "Allow restarting journald without losing stream connections [BZ#1359939]"
        UNIT_PATH="$(mktemp /etc/systemd/system/streams-state-XXX.service)"
        UNIT_NAME="${UNIT_PATH##*/}"

        cat > "$UNIT_PATH" << EOF
[Unit]
Description=$UNIT_NAME

[Service]
ExecStart=/bin/sleep 99h
EOF
        rlRun "systemctl daemon-reload"
        rlRun "systemctl cat $UNIT_NAME"
        rlRun "systemctl start $UNIT_NAME"

        MAIN_PID="$(systemctl show -p MainPID $UNIT_NAME | awk -F= '{print $2}')"
        DEV_NUM="$(stat -Lc "%d" /proc/$MAIN_PID/fd/1)"
        INODE_S="$(stat -Lc "%i" /proc/$MAIN_PID/fd/1)"
        INODE_J="$(ss -n sport = :$INODE_S src \* | awk '/u_str/ {print $NF }')"
        STATE_FN="$DEV_NUM:$INODE_J"
        rlLogInfo "Before journald restart:"
        rlLogInfo "PID: $MAIN_PID"
        rlLogInfo "Device number: $DEV_NUM"
        rlLogInfo "Socket inode: $INODE_S"
        rlLogInfo "Journal inode: $INODE_J"
        rlLogInfo "State filename: $STATE_FN"

        STATE_FILE="/run/systemd/journal/streams/$STATE_FN"
        rlRun "cat $STATE_FILE"
        rlAssertGrep "UNIT=$UNIT_NAME" "$STATE_FILE"
        STREAM_ID="$(grep STREAM_ID "$STATE_FILE" | awk -F= '{print $2}')"

        rlRun "systemctl restart systemd-journald.service"
        rlRun "sleep 5"

        N_MAIN_PID="$(systemctl show -p MainPID $UNIT_NAME | awk -F= '{print $2}')"
        N_DEV_NUM="$(stat -Lc "%d" /proc/$N_MAIN_PID/fd/1)"
        N_INODE_S="$(stat -Lc "%i" /proc/$N_MAIN_PID/fd/1)"
        N_INODE_J="$(ss -n sport = :$N_INODE_S src \* | awk '/u_str/ {print $NF }')"
        N_STATE_FN="$N_DEV_NUM:$N_INODE_J"
        rlLogInfo "After journald restart:"
        rlLogInfo "PID: $N_MAIN_PID"
        rlLogInfo "Device number: $N_DEV_NUM"
        rlLogInfo "Socket inode: $N_INODE_S"
        rlLogInfo "Journal inode: $N_INODE_J"
        rlLogInfo "State filename: $N_STATE_FN"

        N_STREAM_ID="$(grep STREAM_ID "$STATE_FILE" | awk -F= '{print $2}')"
        rlRun "[[ $STREAM_ID == $N_STREAM_ID ]]" 0 "Stream IDs should equal"
        rlRun "[[ $INODE_J == $N_INODE_J ]]" 0 "Journal inodes should equal"

        rlRun "systemctl stop $UNIT_NAME"
        rlRun "rm -fv $UNIT_PATH"
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rlPhaseStartTest
        UNIT_PATH="$(mktemp /etc/systemd/system/ignore-sigpipe-XXX.service)"
        UNIT_NAME="${UNIT_PATH##*/}"

        cat > "$UNIT_PATH" << EOF
[Service]
ExecStart=/bin/bash -c "while true; do echo test; sleep 5; done"
IgnoreSIGPIPE=false
EOF

        rlRun "systemctl daemon-reload"
        rlRun "systemctl cat $UNIT_NAME"
        rlRun "systemctl start $UNIT_NAME"

        rlRun "systemctl restart systemd-journald.service"
        rlRun "sleep 12"
        rlRun "systemctl status $UNIT_NAME"
        rlRun -s "journalctl -r --no-pager _SYSTEMD_UNIT=$UNIT_NAME"
        # 3 records + header = 4
        rlRun "[[ $(wc -l < "$rlRun_LOG") -ge 4 ]]"

        rlRun "systemctl stop $UNIT_NAME"
        rlRun "rm -fv $UNIT_PATH $rlRun_LOG"
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rlPhaseStartSetup "Journal rotation and ENOSPC [BZ#1493846]"
        LOG_PART="$(mktemp journalXXX.part)"
        LOG_TAG="rotationtest$RANDOM"
        LOG_MESSAGE="rotation test message $RANDOM"
        HAS_RSYSLOG=false

        # rsyslog causes unnecessary AVCs and issues with journal locks
        if systemctl status rsyslog; then
            rlRun "systemctl stop rsyslog"
            HAS_RSYSLOG=true
        fi

        # Setup
        rlRun "dd if=/dev/zero of=$LOG_PART bs=1M count=512"
        rlRun "LO_DEV=\$(losetup --show -f $LOG_PART)"
        rlLogInfo "$LOG_PART attached to $LO_DEV"
        rlRun "mkfs -t xfs $LO_DEV"
        if [[ ! -d /var/log/journal ]]; then
            rlRun "mkdir /var/log/journal"
        fi
        rlRun "mount $LO_DEV /var/log/journal"
        rlRun "restorecon -Rv /var/log/journal"
        rlRun "systemd-tmpfiles --create --prefix /var/log/journal"
        rlRun "dmesg --clear"
        rlRun "systemctl restart systemd-journald.service"
        rlRun -s "journalctl --header"
        rlAssertNotGrep "/run/log/journal" "$rlRun_LOG"
        rm -f $rlRun_LOG
        rlRun "dmesg | grep -Ee 'systemd-journald.+?Failed to create new system journal:'" 1

        # Fill up free space on the journal partition
        rlRun "dd if=/dev/zero of=/var/log/journal/fill.tmp bs=1M count=3 oflag=direct"
        rlRun "dd if=/dev/zero of=/var/log/journal/fill.dat bs=512 oflag=direct" 1
        rlRun "rm -fv /var/log/journal/fill.tmp"
        rlRun "df -h /var/log/journal"
        sleep 1
        # Force journal rotation (SIGUSR2)
        rlRun "kill -SIGUSR2 $(pidof systemd-journald)"
        sleep 1
        # This check is really unstable in Beaker, let's disable it, at least temporarily
        # rlRun "dmesg | grep -Ee 'systemd-journald.+?Failed to create new system journal:'" 0

        JOURNAL_DUMP="$(mktemp)"
        rlRun "rm -fv /var/log/journal/fill.dat"
        rlRun "sleep 2"
        rlRun "logger -t $LOG_TAG $LOG_MESSAGE"
        rlRun "journalctl -t $LOG_TAG --no-pager | tee $JOURNAL_DUMP"
        rlAssertGrep "$LOG_MESSAGE" "$JOURNAL_DUMP"

        # Cleanup
        #rlRun "systemctl --force stop systemd-journald.{service,socket}"
        rlRun "systemctl mask systemd-journald.service"
        rlRun "systemctl stop systemd-journald.service"
        rlRun "sleep 5"
        rlRun "umount -f /var/log/journal"
        rlRun "systemctl unmask systemd-journald.service"
        rlRun "systemctl start systemd-journald.service"
        if $HAS_RSYSLOG; then
            rlRun "systemctl start rsyslog"
        fi
        rlRun "losetup -d $LO_DEV"
        # Remove the var-log-journal.mount unit
        rlRun "systemctl daemon-reload"
        rlRun "rm -fv $LOG_PART $JOURNAL_DUMP"
    rlPhaseEnd

    rlPhaseStartTest "Don't flush to /var/log/journal before we get asked to [BZ#1364092]"
        if [[ -d /var/log/journal ]]; then
            rlRun "rm -fr /var/log/journal"
            rlRun "systemctl restart systemd-journald.service"
            rlRun "journalctl --header | grep '/var/log/journal'" 1
        fi

        # Without 'flushed' flag -> journal should remain in runtime mode
        rlLogInfo "Without 'flushed' flag"
        rlRun "systemctl stop systemd-journal-flush.service"
        rlRun "rm -fv /run/systemd/journal/flushed"
        rlRun "mkdir /var/log/journal"
        rlRun "systemctl restart systemd-journald.service"
        rlRun -s "journalctl --header" 0
        rlAssertNotGrep "/var/log/journal" "$rlRun_LOG"

        # With 'flushed' flag -> journal should switch to persistent mode
        rlLogInfo "With 'flushed' flag"
        rlRun "systemctl start systemd-journal-flush.service"
        rlRun "[[ -f /run/systemd/journal/flushed ]]"
        rlRun "systemctl restart systemd-journald"
        rlRun -s "journalctl --header" 0
        rlAssertGrep "/var/log/journal" "$rlRun_LOG"
    rlPhaseEnd

if modprobe btrfs; then
    rlPhaseStartTest "Don't force FS_NOCOW_FL on new journal files [BZ#1299714]"
        BTRFS_PART="$(mktemp journal-btrfs-XXX.part)"
        HAS_RSYSLOG=false

        # rsyslog causes unnecessary AVCs and issues with journal locks
        if systemctl status rsyslog; then
            rlRun "systemctl stop rsyslog"
            HAS_RSYSLOG=true
        fi

        rlRun "dmesg --clear"
        # Reset start-limit counter
        rlRun "systemctl reset-failed systemd-journald.service"
        # Create a btrfs partition for journal files
        rlRun "dd if=/dev/zero of=$BTRFS_PART bs=1M count=512"
        rlRun "LO_DEV=\$(losetup --show -f $BTRFS_PART)"
        rlLogInfo "$BTRFS_PART attached to $LO_DEV"
        rlRun "mkfs -t btrfs $LO_DEV"
        if [[ ! -d /var/log/journal ]]; then
            rlRun "mkdir /var/log/journal"
        fi
        rlRun "mount $LO_DEV /var/log/journal"
        rlRun "systemd-tmpfiles --create --prefix /var/log/journal"
        rlRun "systemctl restart systemd-journald"
        rlRun "journalctl --header | grep /run/log/journal" 1

        for file in $(ls /var/log/journal/*/*.journal); do
            attrs="$(lsattr $file | awk '{print $1}')"
            rlLogInfo "$attrs $file"
            # CoW shouldn't be disabled automatically
            rlRun "[[ $attrs =~ ^[-]+$ ]]"
        done

        # Info message about disabling CoW
        rlRun -s "dmesg -H"
        rlAssertGrep "systemd-journald.+?copy-on-write is enabled" "$rlRun_LOG" "-E"
        rm -f "$rlRun_LOG"

        # See BZ#1531599
        # systemd-tmpfiles shoud disable CoW on journal files
        #rlRun "systemd-tmpfiles --create --prefix /var/log/journal"
        #for file in $(ls /var/log/journal/*/*.journal); do
        #    attrs="$(lsattr $file | awk '{print $1}')"
        #    rlLogInfo "$attrs $file"
        #    rlRun "[[ $attrs =~ ^[-]+C$ ]]"
        #done

        # Cleanup
        rlRun "systemctl mask systemd-journald.service"
        rlRun "systemctl stop systemd-journald.service"
        rlRun "sleep 5"
        rlRun "umount -f /var/log/journal"
        rlRun "systemctl unmask systemd-journald.service"
        rlRun "systemctl start systemd-journald.service"
        if $HAS_RSYSLOG; then
            rlRun "systemctl start rsyslog"
        fi
        rlRun "losetup -d $LO_DEV"
        rlRun "rm -fv $BTRFS_PART"
    rlPhaseEnd
fi

    rlPhaseStartTest "Watchdog support [BZ#1511565]"
        function get_journal_pid() {
            if [[ -z $1 ]]; then
                rlDie "get_journal_pid: missing argument"
                exit 1
            fi

            awk '
                match($0, "systemd-journald.+?PID ([0-9]+).+?WATCHDOG=1", m) {
                    print m[1];
                    exit 0;
                }
                END {
                    exit 1;
                }
            ' "$1"
        }

        rlRun "systemd-analyze set-log-level debug"

        TS="$(date +"%Y-%m-%d %H:%M:%S")"
        rlRun "sleep 3m"
        rlRun -s "journalctl --no-pager --since '$TS'"
        rlAssertGrep "systemd-journald.+?WATCHDOG=1" "$rlRun_LOG" "-E"
        JPID1="$(get_journal_pid $rlRun_LOG)"
        rlRun "[[ -n $JPID1 ]]"
        rlLogInfo "systemd-journald PID #1: $JPID1"
        rm $rlRun_LOG

        TS="$(date +"%Y-%m-%d %H:%M:%S")"
        rlRun "sleep 3m"
        rlRun -s "journalctl --no-pager --since '$TS'"
        rlAssertGrep "systemd-journald.+?WATCHDOG=1" "$rlRun_LOG" "-E"
        JPID2="$(get_journal_pid $rlRun_LOG)"
        rlRun "[[ -n $JPID2 ]]"
        rlLogInfo "systemd-journald PID #2: $JPID2"
        rm $rlRun_LOG

        rlRun "[[ $JPID1 == $JPID2 ]]" 0 "journald PIDs should be equal"

        rlRun "systemd-analyze set-log-level info"
    rlPhaseEnd

    rlPhaseStartTest "journal: fix HMAC calculation when appending a data object [BZ#1247963]"
        KEY_FILE="$(mktemp)"
        TEST_USER="journalHMAC$RANDOM"

        # Setup
        # We need a reasonable amount of entropy to generate journal keys
        rlRun "systemctl start rngd"
        rlRun "useradd $TEST_USER"

        rlRun "rm -fr /var/log/journal"
        rlRun "mkdir /var/log/journal"
        rlRun "systemd-tmpfiles --create --prefix /var/log/journal"
        rlRun "systemctl restart systemd-journald"
        rlRun "journalctl --setup-keys --interval 5 | tee $KEY_FILE"
        KEY=$(cat $KEY_FILE)
        rlLogInfo "Verification key: $KEY"

        # Test
        rlRun "journalctl --verify --verify-key=$KEY"
        rlRun "su - $TEST_USER -c 'whoami; logger ayy; journalctl --no-pager; sleep 5'"
        rlRun "journalctl --verify --verify-key=$KEY"

        # Cleanup
        rlRun "rm -fr /var/log/journal $KEY_FILE"
        rlRun "systemctl restart systemd-journald"
        rlRun "userdel -r $TEST_USER"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlFileRestore
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
        rlRun "rm -fr /var/log/journal"
        # Reset start-limit counter
        rlRun "systemctl reset-failed systemd-journald.service"
        rlRun "systemctl restart systemd-journald"
        # Force journal rotation
        rlRun "kill -SIGUSR2 $(pidof systemd-journald)"
        rlRun "journalctl --header | grep '/var/log/journal'" 1 "Persistent journal should not be enabled"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
