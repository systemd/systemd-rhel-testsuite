#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <systemd/sd-journal.h>

/* gcc journal-process-test.c -l systemd */

int main(void) {
        int r;
        sd_journal *j;

        r = sd_journal_open(&j, SD_JOURNAL_CURRENT_USER|SD_JOURNAL_LOCAL_ONLY);
        if (r < 0) {
                fprintf(stderr, "Failed to open system journal: %m");
                return EXIT_FAILURE;
        }

    /* seek to last message in journal */
        sd_journal_get_fd(j);
        sd_journal_seek_tail(j);
        sd_journal_previous(j);

    /* write to syslog and wait a bit for journal to append the message */
    openlog("sd-journal-process-test", LOG_NDELAY|LOG_PID, LOG_USER);
    syslog(LOG_DAEMON|LOG_ERR, "test message");

    sleep(1);

        r = sd_journal_process(j);
        switch (r) {
        case SD_JOURNAL_NOP:
                puts("nop");
                break;
        case SD_JOURNAL_APPEND:
                puts("append");
                break;
        case SD_JOURNAL_INVALIDATE:
                puts("invalidate");
                break;
        default:
                fprintf(stderr, "Failed to process journal events: %m");
                return EXIT_FAILURE;
        }

        return 0;
}
