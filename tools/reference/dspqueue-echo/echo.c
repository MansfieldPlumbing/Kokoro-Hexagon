/* Diagnostic packet echo for the SDK 6.4.0.2 dspqueue ABI.
 * Reference source: Kokoro-Hexagon 85b20cc80570c20c53d2ca1c43dc03a66aae08ae.
 * Not part of the PowerShell-emitted product path.
 */
#include <stdint.h>
#include "remote.h"
#include "dspqueue.h"
#include "AEEStdErr.h"

static dspqueue_t queue;
static volatile uint32_t received;
static volatile uint32_t failed;

static void on_error(dspqueue_t q, AEEResult error, void *context) {
    (void)q;
    (void)context;
    failed = (uint32_t)error;
}

static void on_packet(dspqueue_t q, AEEResult error, void *context) {
    (void)context;
    if (error != 0) {
        failed = (uint32_t)error;
        return;
    }
    for (;;) {
        uint32_t flags = 0, count = 0, length = 0;
        uint32_t message[2] = {0, 0};
        struct dspqueue_buffer buffers[1];
        AEEResult rc = dspqueue_read_noblock(q, &flags, 1, &count, buffers,
                                             sizeof(message), &length,
                                             (uint8_t *)message);
        if (rc == AEE_EWOULDBLOCK) return;
        if (rc != 0) { failed = 0x10000000u | (uint32_t)rc; return; }
        if (length != sizeof(message)) { failed = 0x20000000u | length; return; }
        if (count != 0) { failed = 0x30000000u | count; return; }
        if ((flags & DSPQUEUE_PACKET_FLAG_MESSAGE) == 0 ||
            (flags & (DSPQUEUE_PACKET_FLAG_BUFFERS |
                      DSPQUEUE_PACKET_FLAG_WAKEUP |
                      DSPQUEUE_PACKET_FLAG_RESERVED_ZERO)) != 0) {
            failed = 0x40000000u | flags;
            return;
        }
        message[0] ^= 0x5a5aa5a5u;
        ++received;
        rc = dspqueue_write(q, 0, 0, 0, sizeof(message),
                            (const uint8_t *)message, 1000000u);
        if (rc != 0) {
            failed = (uint32_t)rc;
            return;
        }
    }
}

__attribute__((visibility("default")))
int kokoro_queue_skel_handle_invoke(remote_handle64 handle, uint32_t sc,
                                    remote_arg *args) {
    (void)handle;
    if (sc == 0x00020001u) {
        if (!args) return 14;
        args[2].h64 = 1;
        return 0;
    }
    if (sc == 0x01000010u) return 0;
    if (sc == 0x00010000u) {
        if (queue || !args || !args[0].buf.pv || args[0].buf.nLen != 8)
            return 14;
        const uint64_t id = *(const uint64_t *)args[0].buf.pv;
        received = 0;
        failed = 0;
        return dspqueue_import(id, on_packet, on_error, 0, &queue);
    }
    if (sc == 0x01000100u) {
        if (!queue || !args || !args[0].buf.pv || args[0].buf.nLen < 8)
            return 14;
        uint32_t *status = (uint32_t *)args[0].buf.pv;
        status[0] = received;
        status[1] = failed;
        AEEResult rc = dspqueue_close(queue);
        queue = 0;
        return rc;
    }
    if (sc == 0x02010100u) {
        if (!args || !args[0].buf.pv || !args[1].buf.pv ||
            args[0].buf.nLen != 8 || args[1].buf.nLen != 8) return 14;
        const uint32_t *input = (const uint32_t *)args[0].buf.pv;
        uint32_t *output = (uint32_t *)args[1].buf.pv;
        output[0] = input[0] ^ 0x5a5aa5a5u;
        output[1] = input[1];
        return 0;
    }
    return 20;
}
