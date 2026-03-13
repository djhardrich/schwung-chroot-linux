/*
 * midi-bridge — PipeWire MIDI bridge daemon for Move Everything
 *
 * Runs inside the PipeWire chroot. Creates two MIDI ports:
 *   "Move MIDI In"  — source: reads from FIFO, emits to PipeWire
 *   "Move MIDI Out" — sink: captures from PipeWire, writes to FIFO
 *
 * Usage: midi-bridge <midi-in-fifo> <midi-out-fifo>
 *   midi-in-fifo:  FIFO written by DSP plugin's on_midi() (Move → chroot)
 *   midi-out-fifo: FIFO read by DSP plugin's pump_midi_out() (chroot → Move)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>

#include <pipewire/pipewire.h>
#include <spa/control/control.h>
#include <spa/pod/builder.h>
#include <spa/pod/parser.h>

#define MAX_MIDI_MSG 65535

struct data {
    struct pw_main_loop *loop;
    struct pw_filter *filter;
    struct port *port_in;   /* MIDI from PipeWire apps → outbound FIFO */
    struct port *port_out;  /* Inbound FIFO → MIDI to PipeWire apps */
    int fifo_in_fd;         /* read: Move → chroot */
    int fifo_out_fd;        /* write: chroot → Move */
    /* Accumulation buffer for inbound FIFO reads */
    uint8_t in_buf[4096];
    uint16_t in_buf_len;
};

struct port {
    struct data *data;
};

static struct pw_main_loop *global_loop = NULL;

static void signal_handler(int sig) {
    (void)sig;
    if (global_loop)
        pw_main_loop_quit(global_loop);
}

/* Read complete MIDI frames from inbound FIFO into accumulation buffer,
 * emit them as SPA_CONTROL_Midi events on the output port */
static void fifo_to_pipewire(struct data *data, struct pw_buffer *buf) {
    struct spa_pod_builder b;
    struct spa_pod_frame f;
    uint8_t tmp[512];

    if (!buf || !buf->buffer || !buf->buffer->datas[0].data) return;

    spa_pod_builder_init(&b, buf->buffer->datas[0].data,
                         buf->buffer->datas[0].maxsize);
    spa_pod_builder_push_sequence(&b, &f, 0);

    /* Fill accumulation buffer from FIFO */
    while (1) {
        size_t space = sizeof(data->in_buf) - data->in_buf_len;
        if (space == 0) break;
        ssize_t n = read(data->fifo_in_fd, tmp,
                         space < sizeof(tmp) ? space : sizeof(tmp));
        if (n <= 0) break;
        memcpy(data->in_buf + data->in_buf_len, tmp, (size_t)n);
        data->in_buf_len += (uint16_t)n;
    }

    /* Consume complete frames */
    size_t pos = 0;
    while (pos + 2 <= data->in_buf_len) {
        uint16_t msg_len = (uint16_t)data->in_buf[pos]
                         | ((uint16_t)data->in_buf[pos + 1] << 8);
        if (msg_len == 0) { pos += 2; continue; }
        if (pos + 2 + msg_len > data->in_buf_len) break;

        /* Emit as SPA MIDI control event at offset 0 */
        spa_pod_builder_control(&b, 0, SPA_CONTROL_Midi);
        spa_pod_builder_bytes(&b, data->in_buf + pos + 2, msg_len);

        pos += 2 + msg_len;
    }

    /* Shift unconsumed */
    if (pos > 0 && pos < data->in_buf_len) {
        memmove(data->in_buf, data->in_buf + pos, data->in_buf_len - pos);
        data->in_buf_len -= (uint16_t)pos;
    } else if (pos >= data->in_buf_len) {
        data->in_buf_len = 0;
    }

    spa_pod_builder_pop(&b, &f);
    buf->buffer->datas[0].chunk->offset = 0;
    buf->buffer->datas[0].chunk->size = b.state.offset;
}

/* Read SPA_CONTROL_Midi events from input port, write to outbound FIFO */
static void pipewire_to_fifo(struct data *data, struct pw_buffer *buf) {
    struct spa_pod *pod;
    struct spa_pod_control *c;

    if (!buf || !buf->buffer || !buf->buffer->datas[0].data) return;

    pod = spa_pod_from_data(buf->buffer->datas[0].data,
                            buf->buffer->datas[0].maxsize,
                            0,
                            buf->buffer->datas[0].chunk->size);
    if (pod == NULL) return;
    if (!spa_pod_is_sequence(pod)) return;

    SPA_POD_SEQUENCE_FOREACH((struct spa_pod_sequence *)pod, c) {
        if (c->type != SPA_CONTROL_Midi) continue;

        uint32_t size = SPA_POD_BODY_SIZE(&c->value);
        uint8_t *midi_data = (uint8_t *)SPA_POD_BODY(&c->value);

        if (size == 0 || size > MAX_MIDI_MSG) continue;

        /* Write length-prefixed frame as single atomic write */
        uint8_t frame[4098];
        if (size > sizeof(frame) - 2) continue;
        frame[0] = (uint8_t)(size & 0xFF);
        frame[1] = (uint8_t)((size >> 8) & 0xFF);
        memcpy(frame + 2, midi_data, size);
        (void)write(data->fifo_out_fd, frame, 2 + size);
    }
}

static void on_process(void *userdata, struct spa_io_position *position) {
    struct data *data = userdata;
    struct pw_buffer *b;
    (void)position;

    /* Output port: FIFO → PipeWire (Move → apps) */
    b = pw_filter_dequeue_buffer(data->port_out);
    if (b) {
        fifo_to_pipewire(data, b);
        pw_filter_queue_buffer(data->port_out, b);
    }

    /* Input port: PipeWire → FIFO (apps → Move) */
    b = pw_filter_dequeue_buffer(data->port_in);
    if (b) {
        pipewire_to_fifo(data, b);
        pw_filter_queue_buffer(data->port_in, b);
    }
}

static const struct pw_filter_events filter_events = {
    PW_VERSION_FILTER_EVENTS,
    .process = on_process,
};

int main(int argc, char *argv[]) {
    struct data data = {0};

    if (argc < 3) {
        fprintf(stderr, "Usage: midi-bridge <midi-in-fifo> <midi-out-fifo>\n");
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open FIFOs non-blocking */
    data.fifo_in_fd = open(argv[1], O_RDWR | O_NONBLOCK);
    if (data.fifo_in_fd < 0) {
        fprintf(stderr, "Cannot open inbound FIFO %s: %s\n",
                argv[1], strerror(errno));
        return 1;
    }
    data.fifo_out_fd = open(argv[2], O_RDWR | O_NONBLOCK);
    if (data.fifo_out_fd < 0) {
        fprintf(stderr, "Cannot open outbound FIFO %s: %s\n",
                argv[2], strerror(errno));
        close(data.fifo_in_fd);
        return 1;
    }

    pw_init(&argc, &argv);

    data.loop = pw_main_loop_new(NULL);
    if (!data.loop) {
        fprintf(stderr, "Failed to create main loop\n");
        return 1;
    }
    global_loop = data.loop;

    data.filter = pw_filter_new_simple(
        pw_main_loop_get_loop(data.loop),
        "midi-bridge",
        pw_properties_new(
            PW_KEY_MEDIA_TYPE, "Midi",
            PW_KEY_MEDIA_CATEGORY, "Filter",
            PW_KEY_MEDIA_ROLE, "DSP",
            PW_KEY_NODE_NAME, "midi-bridge",
            PW_KEY_NODE_DESCRIPTION, "Move MIDI Bridge",
            NULL),
        &filter_events,
        &data);

    if (!data.filter) {
        fprintf(stderr, "Failed to create filter\n");
        return 1;
    }

    /* Output port: "Move MIDI In" — Move hardware MIDI → PipeWire apps */
    data.port_out = pw_filter_add_port(data.filter,
        PW_DIRECTION_OUTPUT,
        PW_FILTER_PORT_FLAG_MAP_BUFFERS,
        sizeof(struct port),
        pw_properties_new(
            PW_KEY_FORMAT_DSP, "8 bit raw midi",
            PW_KEY_PORT_NAME, "Move MIDI In",
            NULL),
        NULL, 0);

    /* Input port: "Move MIDI Out" — PipeWire apps → Move hardware */
    data.port_in = pw_filter_add_port(data.filter,
        PW_DIRECTION_INPUT,
        PW_FILTER_PORT_FLAG_MAP_BUFFERS,
        sizeof(struct port),
        pw_properties_new(
            PW_KEY_FORMAT_DSP, "8 bit raw midi",
            PW_KEY_PORT_NAME, "Move MIDI Out",
            NULL),
        NULL, 0);

    if (!data.port_out || !data.port_in) {
        fprintf(stderr, "Failed to add filter ports\n");
        return 1;
    }

    if (pw_filter_connect(data.filter,
            PW_FILTER_FLAG_RT_PROCESS, NULL, 0) < 0) {
        fprintf(stderr, "Failed to connect filter\n");
        return 1;
    }

    fprintf(stderr, "midi-bridge: running (in=%s out=%s)\n", argv[1], argv[2]);
    pw_main_loop_run(data.loop);

    pw_filter_destroy(data.filter);
    pw_main_loop_destroy(data.loop);
    pw_deinit();

    close(data.fifo_in_fd);
    close(data.fifo_out_fd);

    return 0;
}
