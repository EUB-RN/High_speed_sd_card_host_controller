/* uart_read -- read the benchmark report straight off the FT2232H's channel B,
 * without the ftdi_sio kernel driver and without root.
 *
 * The Tang Primer 20K's debugger is an FT2232H: channel A is the JTAG the
 * bitstream loader uses, channel B is wired to the dock's UART pins. Normally
 * the kernel's ftdi_sio driver turns channel B into /dev/ttyUSB1, but loading a
 * kernel module needs root. libftdi talks to the same endpoint over libusb, and
 * the udev rule that already lets openFPGALoader run unprivileged covers this
 * too -- same device, same permissions.
 *
 *   gcc -O2 -o uart_read uart_read.c $(pkg-config --cflags --libs libftdi1)
 *   ./uart_read            # run until idle, then exit
 *
 * Exits after IDLE_MS with no new bytes, so it terminates on its own once the
 * report has been printed rather than hanging like a terminal emulator.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libftdi1/ftdi.h>

#define BAUD     115200
#define IDLE_MS  3000     /* quit after this long with nothing arriving */
#define FIRST_MS 180000   /* ...but the report only comes at the END of the run,
                           * so before the first byte arrives we wait this long
                           * instead. Override with argv[1], in seconds. */

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int main(int argc, char **argv)
{
    struct ftdi_context *f = ftdi_new();
    unsigned char buf[4096];
    long last, first_ms = FIRST_MS;
    int  seen = 0;

    if (argc > 1) first_ms = atol(argv[1]) * 1000L;

    if (!f) { fprintf(stderr, "ftdi_new failed\n"); return 1; }

    /* INTERFACE_B is channel B. Channel A is JTAG -- opening it would fight
     * with openFPGALoader. */
    ftdi_set_interface(f, INTERFACE_B);

    if (ftdi_usb_open(f, 0x0403, 0x6010) < 0) {
        fprintf(stderr, "open failed: %s\n", ftdi_get_error_string(f));
        fprintf(stderr, "is the board plugged in? is openFPGALoader still running?\n");
        ftdi_free(f);
        return 1;
    }

    /* If ftdi_sio ever does get loaded it will have claimed this interface;
     * take it back for the duration rather than failing. */
    ftdi_set_bitmode(f, 0x00, BITMODE_RESET);
    ftdi_set_baudrate(f, BAUD);
    ftdi_set_line_property(f, BITS_8, STOP_BIT_1, NONE);
    ftdi_setflowctrl(f, SIO_DISABLE_FLOW_CTRL);
    ftdi_tcioflush(f);

    fprintf(stderr, "listening on FT2232H channel B at %d 8N1 "
                    "(up to %ld ms for the first byte, then %d ms of silence "
                    "ends the capture)\n", BAUD, first_ms, IDLE_MS);

    last = now_ms();
    for (;;) {
        int n = ftdi_read_data(f, buf, sizeof(buf));
        if (n < 0) {
            fprintf(stderr, "read error: %s\n", ftdi_get_error_string(f));
            break;
        }
        if (n > 0) {
            fwrite(buf, 1, (size_t)n, stdout);
            fflush(stdout);
            last = now_ms();
            seen = 1;
        } else {
            if (now_ms() - last > (seen ? IDLE_MS : first_ms)) break;
            struct timespec t = { 0, 2 * 1000 * 1000 };  /* 2 ms */
            nanosleep(&t, NULL);
        }
    }

    ftdi_usb_close(f);
    ftdi_free(f);
    return 0;
}
