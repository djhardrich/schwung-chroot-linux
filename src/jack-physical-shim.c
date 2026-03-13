/*
 * jack-physical-shim.c — LD_PRELOAD shim that makes PipeWire's virtual
 * ports appear as physical JACK ports.
 *
 * PipeWire's pipe-tunnel module creates ports without SPA_PORT_FLAG_PHYSICAL.
 * Some JACK apps (Yoshimi, etc.) refuse to start without physical ports.
 * This shim intercepts jack_get_ports to remove the physical flag from
 * filters and jack_port_flags to add it to results.
 *
 * Usage: LD_PRELOAD=/usr/local/lib/jack-physical-shim.so pw-jack yoshimi
 * Or:    pw-jack-physical yoshimi
 */

#define _GNU_SOURCE
#include <stddef.h>
#include <dlfcn.h>

/* JACK port flags (from jack/types.h) */
#define JackPortIsPhysical  0x04
#define JackPortIsTerminal  0x10

typedef void jack_port_t;
typedef void jack_client_t;

/*
 * Wrap jack_get_ports: strip JackPortIsPhysical from the flags filter
 * so all ports are returned regardless of physical status.
 */
const char **jack_get_ports(jack_client_t *client,
                            const char *port_name_pattern,
                            const char *type_name_pattern,
                            unsigned long flags)
{
    static const char **(*real_fn)(jack_client_t *, const char *,
                                   const char *, unsigned long) = NULL;
    if (!real_fn)
        real_fn = dlsym(RTLD_NEXT, "jack_get_ports");

    /* Remove physical filter — return all matching ports */
    flags &= ~(unsigned long)JackPortIsPhysical;

    return real_fn(client, port_name_pattern, type_name_pattern, flags);
}

/*
 * Wrap jack_port_flags: add physical+terminal to all ports so apps
 * that check individual port flags also see them as physical.
 */
int jack_port_flags(const jack_port_t *port)
{
    static int (*real_fn)(const jack_port_t *) = NULL;
    if (!real_fn)
        real_fn = dlsym(RTLD_NEXT, "jack_port_flags");

    return real_fn(port) | JackPortIsPhysical | JackPortIsTerminal;
}
