// Domine for Linux: audio engine on PipeWire. See engine.h for the contract
// and engine_render.h for the real-time render path and its clocking.
//
// Threads:
//   GTK main thread: every dl_engine_* call. Takes the thread loop lock for
//     anything that touches PipeWire objects or engine tables.
//   PipeWire main loop thread (pw_thread_loop): registry, metadata, node and
//     stream state callbacks. Runs with the thread loop lock held.
//   PipeWire data threads: capture and playback process callbacks
//     (PW_STREAM_FLAG_RT_PROCESS). They only call dl_render_capture and
//     dl_render_pull, which are lock-free and allocation-free.
//
// Graph while playing:
//   apps -> "domine" null sink (made the default sink)
//   "domine" monitor -> capture stream -> surround kernel -> per-speaker rings
//   ring i -> playback stream i -> speaker i's sink (target.object, never
//   allowed to fall back to the default sink, which would be a feedback loop)
#include "engine.h"
#include "engine_internal.h"
#include "engine_render.h"
#include "DomineSpatial.h"

#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <glib.h>
#include <glib-unix.h>
#include <gio/gio.h>

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/pod/iter.h>
#include <spa/pod/parser.h>
#include <spa/utils/result.h>

#define DL_MAX_NODES 256
#define DL_MAX_APPS 64
#define DL_KEY_CONFIGURED "default.configured.audio.sink"
#define DL_KEY_DEFAULT "default.audio.sink"

enum { NODE_SINK = 1, NODE_APP, NODE_SELF };

typedef struct DLEngine DLEngine;

typedef struct {
    DLEngine *e;
    int used;
    int kind;
    uint32_t id;
    char name[256];
    char label[256];
    char appKey[256];
    char appLabel[256];
    uint32_t channels;      // audio.channels, or channel count seen in Props
    float volume;           // first channel volume from Props, -1 unknown
    int mute;
    int targetSet;          // we wrote target.object metadata for it
    struct pw_proxy *proxy;
    struct spa_hook listener;
} DLNode;

typedef struct {
    int used;
    char key[256];
    char label[256];
    float volume;
    int volumeSet;          // the user changed it in Domine
    int excluded;
    char excludeSink[256];
} DLAppEntry;

typedef struct {
    DLEngine *e;
    uint32_t index;
    struct pw_stream *stream;
    struct spa_hook listener;
    enum pw_stream_state state;
} DLPlayback;

struct DLEngine {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct spa_hook coreListener;
    struct pw_registry *registry;
    struct spa_hook registryListener;
    int syncSeq, syncDone, coreDead;

    DLNode nodes[DL_MAX_NODES];
    DLAppEntry apps[DL_MAX_APPS];

    struct pw_metadata *metadata;
    uint32_t metadataId;
    struct spa_hook metadataListener;
    char configuredValue[512];   // raw JSON of default.configured.audio.sink, "" if unset
    char defaultValue[512];      // raw JSON of default.audio.sink

    // Running state (loop lock).
    int running;
    DLSpeaker speakers[DL_MAX_SPEAKERS];
    uint32_t count;
    DLRender *render;
    struct pw_proxy *virtualSink;
    struct pw_stream *capture;
    struct spa_hook captureListener;
    enum pw_stream_state captureState;
    DLPlayback playback[DL_MAX_SPEAKERS];
    char savedConfigured[512];
    char previousSink[256];      // name the default sink had before start
    int defaultChanged;

    // Settings kept across restarts (main thread).
    float master, width, level, orbit, rotation, spatialAmount, spatialRoom;
    int demo, tone, click;
    float manualDelay[DL_MAX_SPEAKERS];
    uint8_t hasEq[DL_MAX_SPEAKERS], hasBass[DL_MAX_SPEAKERS], hasComp[DL_MAX_SPEAKERS];
    DomineEQParams eq[DL_MAX_SPEAKERS];
    DomineBassParams bass[DL_MAX_SPEAKERS];
    DomineCompressorParams comp[DL_MAX_SPEAKERS];
    float sinkVolume;            // Domine sink's own volume (volume keys), -1 unknown
    int sinkMute;

    _Atomic int state;
    char error[256];

    // Notification to the GTK main thread.
    pthread_mutex_t notifyLock;
    guint idleId;
    void (*onChange)(void *ctx);
    void *onChangeCtx;
    guint signalIds[3];
};

static DLEngine *g_exitEngine;   // engine the exit guard restores

// ---------------------------------------------------------------- helpers

static void set_err(char *err, uint32_t len, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void set_err(char *err, uint32_t len, const char *fmt, ...) {
    if (err == NULL || len == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

static void copy_str(char *dst, size_t len, const char *src) {
    if (len == 0) return;
    snprintf(dst, len, "%s", src != NULL ? src : "");
}

int dl_json_name(const char *json, char *out, size_t len) {
    if (out == NULL || len == 0) return 0;
    out[0] = '\0';
    if (json == NULL) return 0;
    const char *p = strstr(json, "\"name\"");
    if (p == NULL) return 0;
    p += 6;
    while (*p == ' ' || *p == '\t' || *p == '\n') p++;
    if (*p != ':') return 0;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n') p++;
    if (*p != '"') return 0;
    p++;
    size_t n = 0;
    while (*p != '\0' && *p != '"') {
        if (*p == '\\' && p[1] != '\0') p++;
        if (n + 1 < len) out[n++] = *p;
        p++;
    }
    if (*p != '"') { out[0] = '\0'; return 0; }
    out[n] = '\0';
    return n > 0;
}

static int is_own_node(const char *name) {
    return name != NULL && strncmp(name, DL_SINK_NAME, strlen(DL_SINK_NAME)) == 0
        && (name[strlen(DL_SINK_NAME)] == '\0' || name[strlen(DL_SINK_NAME)] == '.');
}

static gboolean idle_notify(gpointer data) {
    DLEngine *e = data;
    pthread_mutex_lock(&e->notifyLock);
    e->idleId = 0;
    void (*cb)(void *) = e->onChange;
    void *ctx = e->onChangeCtx;
    pthread_mutex_unlock(&e->notifyLock);
    if (cb != NULL) cb(ctx);
    return G_SOURCE_REMOVE;
}

static void notify(DLEngine *e) {
    pthread_mutex_lock(&e->notifyLock);
    if (e->onChange != NULL && e->idleId == 0) e->idleId = g_idle_add(idle_notify, e);
    pthread_mutex_unlock(&e->notifyLock);
}

static DLNode *node_by_id(DLEngine *e, uint32_t id) {
    for (int i = 0; i < DL_MAX_NODES; i++) if (e->nodes[i].used && e->nodes[i].id == id) return &e->nodes[i];
    return NULL;
}

static DLNode *node_by_name(DLEngine *e, int kind, const char *name) {
    for (int i = 0; i < DL_MAX_NODES; i++) {
        DLNode *n = &e->nodes[i];
        if (n->used && n->kind == kind && strcmp(n->name, name) == 0) return n;
    }
    return NULL;
}

static DLAppEntry *app_by_key(DLEngine *e, const char *key, int create) {
    for (int i = 0; i < DL_MAX_APPS; i++) if (e->apps[i].used && strcmp(e->apps[i].key, key) == 0) return &e->apps[i];
    if (!create) return NULL;
    for (int i = 0; i < DL_MAX_APPS; i++) {
        if (!e->apps[i].used) {
            memset(&e->apps[i], 0, sizeof e->apps[i]);
            e->apps[i].used = 1;
            e->apps[i].volume = 1.0f;
            copy_str(e->apps[i].key, sizeof e->apps[i].key, key);
            return &e->apps[i];
        }
    }
    return NULL;
}

// Waits for the server to process everything sent so far. Loop lock held.
static int roundtrip(DLEngine *e) {
    e->syncDone = 0;
    e->syncSeq = pw_core_sync(e->core, PW_ID_CORE, e->syncSeq);
    while (!e->syncDone && !e->coreDead) {
        if (pw_thread_loop_timed_wait(e->loop, 3) != 0) return -1;
    }
    return e->coreDead ? -1 : 0;
}

static void set_node_volume(DLNode *n, float volume) {
    if (n->proxy == NULL) return;
    uint32_t ch = n->channels > 0 && n->channels <= SPA_AUDIO_MAX_CHANNELS ? n->channels : 2;
    float vols[SPA_AUDIO_MAX_CHANNELS];
    for (uint32_t i = 0; i < ch; i++) vols[i] = volume;
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
        SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, ch, vols));
    pw_node_set_param((struct pw_node *)n->proxy, SPA_PARAM_Props, 0, pod);
}

static void master_to_render(DLEngine *e) {
    if (e->render != NULL) dl_render_set_master(e->render, e->sinkMute ? 0.0f : e->master);
}

// ---------------------------------------------------------------- state

static void update_state(DLEngine *e) {
    DLState s;
    if (!e->running) s = DL_IDLE;
    else if (e->coreDead || e->captureState == PW_STREAM_STATE_ERROR) s = DL_ERROR;
    else {
        int settled = e->captureState == PW_STREAM_STATE_PAUSED || e->captureState == PW_STREAM_STATE_STREAMING;
        int all = 1, any = 0;
        for (uint32_t i = 0; i < e->count; i++) {
            DLPlayback *p = &e->playback[i];
            const int up = p->stream != NULL
                && (p->state == PW_STREAM_STATE_PAUSED || p->state == PW_STREAM_STATE_STREAMING);
            if (p->stream != NULL && p->state == PW_STREAM_STATE_CONNECTING) settled = 0;
            if (up) any = 1; else all = 0;
        }
        if (!settled) s = DL_STARTING;
        else if (all) s = DL_PLAYING;
        else if (any) s = DL_DEGRADED;
        else s = DL_DEGRADED;
    }
    if (s == DL_DEGRADED && e->running) {
        char buf[256] = "";
        for (uint32_t i = 0; i < e->count; i++) {
            DLPlayback *p = &e->playback[i];
            if (p->stream == NULL || p->state == PW_STREAM_STATE_UNCONNECTED || p->state == PW_STREAM_STATE_ERROR) {
                size_t l = strlen(buf);
                snprintf(buf + l, sizeof buf - l, "%sspeaker %u", l ? ", " : "Missing: ", i + 1);
            }
        }
        copy_str(e->error, sizeof e->error, buf);
    }
    const int old = atomic_exchange(&e->state, (int)s);
    if (old != (int)s) notify(e);
}

// ---------------------------------------------------------------- streams

static const struct spa_pod *stereo_format(struct spa_pod_builder *b) {
    struct spa_audio_info_raw info = {
        .format = SPA_AUDIO_FORMAT_F32,
        .rate = DL_RATE,
        .channels = 2,
    };
    info.position[0] = SPA_AUDIO_CHANNEL_FL;
    info.position[1] = SPA_AUDIO_CHANNEL_FR;
    return spa_format_audio_raw_build(b, SPA_PARAM_EnumFormat, &info);
}

static void capture_process(void *data) {
    DLEngine *e = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(e->capture);
    if (b == NULL) return;
    struct spa_data *d = &b->buffer->datas[0];
    if (d->data != NULL && d->chunk != NULL && e->render != NULL) {
        uint32_t offset = d->chunk->offset % (d->maxsize ? d->maxsize : 1);
        uint32_t size = d->chunk->size;
        if (size > d->maxsize - offset) size = d->maxsize - offset;
        const uint32_t frames = size / (2 * sizeof(float));
        const float *in = SPA_PTROFF(d->data, offset, const float);
        if (d->chunk->flags & SPA_CHUNK_FLAG_EMPTY) in = NULL;
        if (frames > 0) dl_render_capture(e->render, in, frames);
    }
    pw_stream_queue_buffer(e->capture, b);
}

static void capture_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    DLEngine *e = data;
    e->captureState = state;
    if (state == PW_STREAM_STATE_ERROR) {
        set_err(e->error, sizeof e->error, "Capture from the Domine sink failed: %s", error ? error : "unknown error");
    }
    update_state(e);
}

static const struct pw_stream_events capture_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = capture_state,
    .process = capture_process,
};

static void playback_process(void *data) {
    DLPlayback *p = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(p->stream);
    if (b == NULL) return;
    struct spa_data *d = &b->buffer->datas[0];
    if (d->data != NULL && d->chunk != NULL) {
        uint32_t frames = d->maxsize / (2 * sizeof(float));
        if (b->requested > 0 && b->requested < frames) frames = (uint32_t)b->requested;
        if (p->e->render != NULL) dl_render_pull(p->e->render, p->index, d->data, frames);
        else memset(d->data, 0, (size_t)frames * 2 * sizeof(float));
        d->chunk->offset = 0;
        d->chunk->stride = 2 * sizeof(float);
        d->chunk->size = frames * 2 * sizeof(float);
    }
    pw_stream_queue_buffer(p->stream, b);
}

static void playback_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old; (void)error;
    DLPlayback *p = data;
    p->state = state;
    const int up = state == PW_STREAM_STATE_PAUSED || state == PW_STREAM_STATE_STREAMING;
    if (p->e->render != NULL) dl_render_set_present(p->e->render, p->index, up);
    update_state(p->e);
}

static const struct pw_stream_events playback_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = playback_state,
    .process = playback_process,
};

// Loop lock held.
static void playback_destroy(DLEngine *e, uint32_t i) {
    DLPlayback *p = &e->playback[i];
    if (e->render != NULL) dl_render_set_present(e->render, i, 0);
    if (p->stream == NULL) return;
    spa_hook_remove(&p->listener);
    pw_stream_destroy(p->stream);
    p->stream = NULL;
    p->state = PW_STREAM_STATE_UNCONNECTED;
}

// Loop lock held.
static int playback_create(DLEngine *e, uint32_t i) {
    DLPlayback *p = &e->playback[i];
    if (p->stream != NULL) return 0;
    char name[64], latency[32];
    snprintf(name, sizeof name, DL_SINK_NAME ".playback.%u", i + 1);
    snprintf(latency, sizeof latency, "256/%d", DL_RATE);
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_APP_NAME, "Domine",
        PW_KEY_NODE_NAME, name,
        PW_KEY_NODE_LATENCY, latency,
        PW_KEY_TARGET_OBJECT, e->speakers[i].sinkId,
        PW_KEY_NODE_DONT_RECONNECT, "true",
        "node.dont-fallback", "true",
        "node.dont-move", "true",
        NULL);
    p->e = e;
    p->index = i;
    p->state = PW_STREAM_STATE_CONNECTING;
    p->stream = pw_stream_new(e->core, name, props);
    if (p->stream == NULL) return -1;
    pw_stream_add_listener(p->stream, &p->listener, &playback_events, p);
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[1] = { stereo_format(&b) };
    int res = pw_stream_connect(p->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, params, 1);
    if (res < 0) { playback_destroy(e, i); return -1; }
    return 0;
}

// ---------------------------------------------------------------- default sink and app routing

static char *state_file(char *out, size_t len) {
    const char *base = getenv("XDG_STATE_HOME");
    const char *home = getenv("HOME");
    if (base != NULL && base[0] != '\0') snprintf(out, len, "%s/domine", base);
    else if (home != NULL) snprintf(out, len, "%s/.local/state/domine", home);
    else return NULL;
    return out;
}

static void save_previous_default(const char *value) {
    char dir[512], path[600];
    if (state_file(dir, sizeof dir) == NULL) return;
    char parent[512];
    copy_str(parent, sizeof parent, dir);
    char *slash = strrchr(parent, '/');
    if (slash != NULL) { *slash = '\0'; mkdir(parent, 0700); }
    mkdir(dir, 0700);
    snprintf(path, sizeof path, "%s/previous-default-sink", dir);
    FILE *f = fopen(path, "w");
    if (f == NULL) return;
    fputs(value, f);
    fclose(f);
}

static int load_previous_default(char *out, size_t len) {
    char dir[512], path[600];
    out[0] = '\0';
    if (state_file(dir, sizeof dir) == NULL) return 0;
    snprintf(path, sizeof path, "%s/previous-default-sink", dir);
    FILE *f = fopen(path, "r");
    if (f == NULL) return 0;
    size_t n = fread(out, 1, len - 1, f);
    out[n] = '\0';
    fclose(f);
    return 1;
}

static void forget_previous_default(void) {
    char dir[512], path[600];
    if (state_file(dir, sizeof dir) == NULL) return;
    snprintf(path, sizeof path, "%s/previous-default-sink", dir);
    unlink(path);
}

static int value_is_domine(const char *json) {
    char name[256];
    return dl_json_name(json, name, sizeof name) && strcmp(name, DL_SINK_NAME) == 0;
}

// Loop lock held. Puts back what default.configured.audio.sink was.
static void restore_default(DLEngine *e, const char *saved) {
    if (e->metadata == NULL) return;
    if (saved != NULL && saved[0] != '\0' && !value_is_domine(saved)) {
        pw_metadata_set_property(e->metadata, PW_ID_CORE, DL_KEY_CONFIGURED, "Spa:String:JSON", saved);
    } else {
        pw_metadata_set_property(e->metadata, PW_ID_CORE, DL_KEY_CONFIGURED, NULL, NULL);
    }
}

// Loop lock held. Routes one app stream node per its app's exclusion.
static void route_app_node(DLEngine *e, DLNode *n) {
    if (e->metadata == NULL || n->kind != NODE_APP) return;
    DLAppEntry *a = app_by_key(e, n->appKey, 0);
    const int exclude = e->running && a != NULL && a->excluded;
    if (exclude) {
        const char *sinkName = a->excludeSink[0] != '\0' ? a->excludeSink : e->previousSink;
        DLNode *sink = sinkName[0] != '\0' ? node_by_name(e, NODE_SINK, sinkName) : NULL;
        if (sink == NULL) return;
        char id[32];
        snprintf(id, sizeof id, "%u", sink->id);
        pw_metadata_set_property(e->metadata, n->id, "target.object", NULL, sink->name);
        pw_metadata_set_property(e->metadata, n->id, "target.node", "Spa:Id", id);
        n->targetSet = 1;
    } else if (n->targetSet) {
        pw_metadata_set_property(e->metadata, n->id, "target.object", NULL, NULL);
        pw_metadata_set_property(e->metadata, n->id, "target.node", NULL, NULL);
        n->targetSet = 0;
    }
}

static void route_all_apps(DLEngine *e) {
    for (int i = 0; i < DL_MAX_NODES; i++) if (e->nodes[i].used) route_app_node(e, &e->nodes[i]);
}

// ---------------------------------------------------------------- metadata

static int metadata_property(void *data, uint32_t subject, const char *key, const char *type, const char *value) {
    (void)type;
    DLEngine *e = data;
    if (subject != PW_ID_CORE) return 0;
    if (key == NULL) { e->configuredValue[0] = '\0'; e->defaultValue[0] = '\0'; return 0; }
    if (strcmp(key, DL_KEY_CONFIGURED) == 0) copy_str(e->configuredValue, sizeof e->configuredValue, value);
    else if (strcmp(key, DL_KEY_DEFAULT) == 0) copy_str(e->defaultValue, sizeof e->defaultValue, value);
    return 0;
}

static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = metadata_property,
};

// ---------------------------------------------------------------- nodes

static void node_info(void *data, const struct pw_node_info *info) {
    DLNode *n = data;
    DLEngine *e = n->e;
    if (info->props == NULL) return;
    const char *desc = spa_dict_lookup(info->props, PW_KEY_NODE_DESCRIPTION);
    const char *nick = spa_dict_lookup(info->props, PW_KEY_NODE_NICK);
    const char *ch = spa_dict_lookup(info->props, PW_KEY_AUDIO_CHANNELS);
    if (desc != NULL) copy_str(n->label, sizeof n->label, desc);
    else if (nick != NULL && n->label[0] == '\0') copy_str(n->label, sizeof n->label, nick);
    if (ch != NULL && atoi(ch) > 0) n->channels = (uint32_t)atoi(ch);
    if (n->kind == NODE_APP) {
        const char *bin = spa_dict_lookup(info->props, PW_KEY_APP_PROCESS_BINARY);
        const char *app = spa_dict_lookup(info->props, PW_KEY_APP_NAME);
        const char *key = bin != NULL ? bin : app != NULL ? app : n->name;
        const int first = n->appKey[0] == '\0';
        copy_str(n->appKey, sizeof n->appKey, key);
        copy_str(n->appLabel, sizeof n->appLabel, app != NULL ? app : key);
        DLAppEntry *a = app_by_key(e, n->appKey, 1);
        if (a != NULL) {
            copy_str(a->label, sizeof a->label, n->appLabel);
            if (first) {
                if (a->volumeSet) set_node_volume(n, a->volume);
                route_app_node(e, n);
            }
        }
    }
    notify(e);
}

static void node_param(void *data, int seq, uint32_t id, uint32_t index, uint32_t next, const struct spa_pod *param) {
    (void)seq; (void)index; (void)next;
    DLNode *n = data;
    DLEngine *e = n->e;
    if (id != SPA_PARAM_Props || param == NULL) return;
    struct spa_pod *vols = NULL;
    bool mute = false;
    int haveMute = 0;
    const struct spa_pod_object *obj = (const struct spa_pod_object *)param;
    struct spa_pod_prop *prop;
    if (!spa_pod_is_object_type(param, SPA_TYPE_OBJECT_Props)) return;
    SPA_POD_OBJECT_FOREACH(obj, prop) {
        if (prop->key == SPA_PROP_channelVolumes) vols = &prop->value;
        else if (prop->key == SPA_PROP_mute && spa_pod_get_bool(&prop->value, &mute) == 0) haveMute = 1;
    }
    float v[SPA_AUDIO_MAX_CHANNELS];
    uint32_t nv = vols != NULL ? spa_pod_copy_array(vols, SPA_TYPE_Float, v, SPA_AUDIO_MAX_CHANNELS) : 0;
    if (nv > 0) {
        n->channels = nv;
        float m = 0.0f;
        for (uint32_t i = 0; i < nv; i++) if (v[i] > m) m = v[i];
        n->volume = m;
    }
    if (haveMute) n->mute = mute;
    if (n->kind == NODE_SELF) {
        if (nv > 0) { e->sinkVolume = n->volume > 1.0f ? 1.0f : n->volume; e->master = e->sinkVolume; }
        if (haveMute) e->sinkMute = mute;
        master_to_render(e);
    } else if (n->kind == NODE_APP && nv > 0) {
        DLAppEntry *a = app_by_key(e, n->appKey, 0);
        if (a != NULL && !a->volumeSet) a->volume = n->volume > 1.0f ? 1.0f : n->volume;
    }
    notify(e);
}

static const struct pw_node_events node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = node_info,
    .param = node_param,
};

static void node_free(DLNode *n) {
    if (n->proxy != NULL) {
        spa_hook_remove(&n->listener);
        pw_proxy_destroy(n->proxy);
    }
    memset(n, 0, sizeof *n);
}

// ---------------------------------------------------------------- registry

static void registry_global(void *data, uint32_t id, uint32_t permissions, const char *type,
                            uint32_t version, const struct spa_dict *props) {
    (void)permissions; (void)version;
    DLEngine *e = data;
    if (props == NULL) return;
    if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
        const char *name = spa_dict_lookup(props, "metadata.name");
        if (name == NULL || strcmp(name, "default") != 0 || e->metadata != NULL) return;
        e->metadata = pw_registry_bind(e->registry, id, PW_TYPE_INTERFACE_Metadata, PW_VERSION_METADATA, 0);
        if (e->metadata == NULL) return;
        e->metadataId = id;
        pw_metadata_add_listener(e->metadata, &e->metadataListener, &metadata_events, e);
        return;
    }
    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0) return;
    const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (cls == NULL || name == NULL) return;
    int kind;
    if (strcmp(cls, "Audio/Sink") == 0) kind = strcmp(name, DL_SINK_NAME) == 0 ? NODE_SELF : NODE_SINK;
    else if (strcmp(cls, "Stream/Output/Audio") == 0) { if (is_own_node(name)) return; kind = NODE_APP; }
    else return;
    DLNode *n = NULL;
    for (int i = 0; i < DL_MAX_NODES; i++) if (!e->nodes[i].used) { n = &e->nodes[i]; break; }
    if (n == NULL) return;
    memset(n, 0, sizeof *n);
    n->used = 1;
    n->e = e;
    n->kind = kind;
    n->id = id;
    n->volume = -1.0f;
    n->channels = 2;
    copy_str(n->name, sizeof n->name, name);
    const char *desc = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
    copy_str(n->label, sizeof n->label, desc != NULL ? desc : name);
    n->proxy = pw_registry_bind(e->registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
    if (n->proxy != NULL) {
        pw_proxy_add_object_listener(n->proxy, &n->listener, &node_events, n);
        if (kind != NODE_SINK) {
            uint32_t ids[1] = { SPA_PARAM_Props };
            pw_node_subscribe_params((struct pw_node *)n->proxy, ids, 1);
        }
    }
    if (kind == NODE_SINK && e->running) {
        for (uint32_t i = 0; i < e->count; i++) {
            if (strcmp(e->speakers[i].sinkId, name) == 0 && e->playback[i].stream == NULL) playback_create(e, i);
        }
        route_all_apps(e);
        update_state(e);
    }
    if (kind == NODE_SELF && e->sinkVolume >= 0.0f) set_node_volume(n, e->sinkVolume);
    notify(e);
}

static void registry_global_remove(void *data, uint32_t id) {
    DLEngine *e = data;
    if (e->metadata != NULL && id == e->metadataId) {
        spa_hook_remove(&e->metadataListener);
        pw_proxy_destroy((struct pw_proxy *)e->metadata);
        e->metadata = NULL;
        return;
    }
    DLNode *n = node_by_id(e, id);
    if (n == NULL) return;
    if (n->kind == NODE_SINK && e->running) {
        for (uint32_t i = 0; i < e->count; i++) {
            if (strcmp(e->speakers[i].sinkId, n->name) == 0) playback_destroy(e, i);
        }
    }
    node_free(n);
    update_state(e);
    notify(e);
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_global,
    .global_remove = registry_global_remove,
};

// ---------------------------------------------------------------- core

static void core_done(void *data, uint32_t id, int seq) {
    DLEngine *e = data;
    if (id == PW_ID_CORE && seq == e->syncSeq) {
        e->syncDone = 1;
        pw_thread_loop_signal(e->loop, false);
    }
}

static void core_error(void *data, uint32_t id, int seq, int res, const char *message) {
    (void)seq;
    DLEngine *e = data;
    if (id == PW_ID_CORE) {
        if (res == -EPIPE) e->coreDead = 1;
        set_err(e->error, sizeof e->error, "PipeWire: %s (%s)", message ? message : "error", spa_strerror(res));
        update_state(e);
        pw_thread_loop_signal(e->loop, false);
    } else if (e->virtualSink != NULL && id == pw_proxy_get_id(e->virtualSink)) {
        set_err(e->error, sizeof e->error, "Could not create the Domine sink: %s", message ? message : spa_strerror(res));
        pw_thread_loop_signal(e->loop, false);
    }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = core_done,
    .error = core_error,
};

// ---------------------------------------------------------------- exit guard

static void exit_restore(void) {
    if (g_exitEngine != NULL && g_exitEngine->running) dl_engine_stop(g_exitEngine);
}

static gboolean on_signal(gpointer data) {
    DLEngine *e = data;
    // GLib delivers this on the main thread; the signal handler itself only
    // wrote to GLib's wakeup pipe.
    if (e->running) dl_engine_stop(e);
    GApplication *app = g_application_get_default();
    if (app != NULL) g_application_quit(app);
    else exit(0);
    return G_SOURCE_CONTINUE;
}

static void install_exit_guard(DLEngine *e) {
    static int atexitDone;
    if (g_exitEngine != NULL) return;
    g_exitEngine = e;
    if (!atexitDone) { atexit(exit_restore); atexitDone = 1; }
    e->signalIds[0] = g_unix_signal_add(SIGINT, on_signal, e);
    e->signalIds[1] = g_unix_signal_add(SIGTERM, on_signal, e);
    e->signalIds[2] = g_unix_signal_add(SIGHUP, on_signal, e);
}

// ---------------------------------------------------------------- public API

DLEngine *dl_engine_create(char *err, uint32_t errLen) {
    set_err(err, errLen, "%s", "");
    pw_init(NULL, NULL);
    DLEngine *e = calloc(1, sizeof *e);
    if (e == NULL) { set_err(err, errLen, "Out of memory"); pw_deinit(); return NULL; }
    pthread_mutex_init(&e->notifyLock, NULL);
    atomic_init(&e->state, DL_IDLE);
    e->master = 1.0f;
    e->width = DOMINE_SURROUND_WIDTH_DEFAULT;
    e->level = 0.7f;
    e->spatialAmount = 0.6f;
    e->spatialRoom = 15.0f;
    e->tone = -1;
    e->sinkVolume = -1.0f;

    e->loop = pw_thread_loop_new("domine-pw", NULL);
    if (e->loop == NULL) { set_err(err, errLen, "Could not create the PipeWire thread loop"); goto fail; }
    e->context = pw_context_new(pw_thread_loop_get_loop(e->loop), NULL, 0);
    if (e->context == NULL) {
        set_err(err, errLen, "Could not create a PipeWire context (%s). Is PipeWire installed?", strerror(errno));
        goto fail;
    }
    if (pw_thread_loop_start(e->loop) < 0) { set_err(err, errLen, "Could not start the PipeWire thread"); goto fail; }
    pw_thread_loop_lock(e->loop);
    e->core = pw_context_connect(e->context, NULL, 0);
    if (e->core == NULL) {
        const int code = errno;
        pw_thread_loop_unlock(e->loop);
        set_err(err, errLen, "Cannot connect to PipeWire (%s). Is the PipeWire daemon running?", strerror(code));
        goto fail;
    }
    pw_core_add_listener(e->core, &e->coreListener, &core_events, e);
    e->registry = pw_core_get_registry(e->core, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(e->registry, &e->registryListener, &registry_events, e);
    if (roundtrip(e) < 0 || roundtrip(e) < 0) {
        pw_thread_loop_unlock(e->loop);
        set_err(err, errLen, "PipeWire did not answer");
        goto fail;
    }
    // Crash recovery: a previous run left Domine as the configured default
    // and its sink is gone. Put back what was saved at that start.
    if (e->metadata != NULL && value_is_domine(e->configuredValue) && node_by_name(e, NODE_SELF, DL_SINK_NAME) == NULL) {
        char saved[512];
        load_previous_default(saved, sizeof saved);
        restore_default(e, saved);
        forget_previous_default();
    }
    pw_thread_loop_unlock(e->loop);
    install_exit_guard(e);
    return e;
fail:
    dl_engine_destroy(e);
    return NULL;
}

void dl_engine_destroy(DLEngine *e) {
    if (e == NULL) return;
    if (e->running) dl_engine_stop(e);
    if (e->loop != NULL) {
        pw_thread_loop_lock(e->loop);
        for (int i = 0; i < DL_MAX_NODES; i++) if (e->nodes[i].used) node_free(&e->nodes[i]);
        if (e->metadata != NULL) {
            spa_hook_remove(&e->metadataListener);
            pw_proxy_destroy((struct pw_proxy *)e->metadata);
            e->metadata = NULL;
        }
        if (e->registry != NULL) {
            spa_hook_remove(&e->registryListener);
            pw_proxy_destroy((struct pw_proxy *)e->registry);
        }
        if (e->core != NULL) {
            spa_hook_remove(&e->coreListener);
            pw_core_disconnect(e->core);
        }
        pw_thread_loop_unlock(e->loop);
        pw_thread_loop_stop(e->loop);
    }
    if (e->context != NULL) pw_context_destroy(e->context);
    if (e->loop != NULL) pw_thread_loop_destroy(e->loop);
    for (int i = 0; i < 3; i++) if (e->signalIds[i] != 0) g_source_remove(e->signalIds[i]);
    if (g_exitEngine == e) g_exitEngine = NULL;
    pthread_mutex_lock(&e->notifyLock);
    if (e->idleId != 0) g_source_remove(e->idleId);
    e->idleId = 0;
    pthread_mutex_unlock(&e->notifyLock);
    pthread_mutex_destroy(&e->notifyLock);
    free(e);
    pw_deinit();
}

uint32_t dl_engine_sinks(DLEngine *e, DLSink *out, uint32_t max) {
    if (e == NULL || out == NULL) return 0;
    uint32_t n = 0;
    pw_thread_loop_lock(e->loop);
    for (int i = 0; i < DL_MAX_NODES && n < max; i++) {
        DLNode *node = &e->nodes[i];
        if (!node->used || node->kind != NODE_SINK) continue;
        copy_str(out[n].id, sizeof out[n].id, node->name);
        copy_str(out[n].label, sizeof out[n].label, node->label);
        out[n].channels = node->channels;
        out[n].available = 1;
        n++;
    }
    pw_thread_loop_unlock(e->loop);
    return n;
}

void dl_engine_set_on_change(DLEngine *e, void (*on_change)(void *ctx), void *ctx) {
    if (e == NULL) return;
    pthread_mutex_lock(&e->notifyLock);
    e->onChange = on_change;
    e->onChangeCtx = ctx;
    pthread_mutex_unlock(&e->notifyLock);
}

// Applies every stored setting to a fresh render. Main thread.
static void apply_settings(DLEngine *e, DLRender *r) {
    dl_render_configure(r, e->speakers, e->count, e->sinkMute ? 0.0f : e->master);
    for (uint32_t i = 0; i < e->count; i++) {
        dl_render_set_manual_delay(r, i, e->manualDelay[i]);
        if (e->hasEq[i]) dl_render_set_eq(r, i, &e->eq[i]);
        if (e->hasBass[i]) dl_render_set_bass(r, i, &e->bass[i]);
        if (e->hasComp[i]) dl_render_set_compressor(r, i, &e->comp[i]);
    }
    domine_surround_set_width(r->kernel, e->width);
    domine_surround_set_surround_level(r->kernel, e->level);
    domine_surround_set_orbit_rate(r->kernel, e->orbit);
    domine_surround_set_rotation(r->kernel, e->rotation);
    DomineSpatialParams sp = { e->spatialAmount, e->spatialRoom, 5000.0f };
    domine_surround_set_spatial(r->kernel, &sp);
    dl_render_set_test_tone(r, e->tone);
    dl_render_set_click_test(r, e->click);
    if (e->demo) domine_surround_set_demo(r->kernel, 1);
    domine_surround_start_faded_out(r->kernel);
}

int dl_engine_start(DLEngine *e, const DLSpeaker *speakers, uint32_t count, char *err, uint32_t errLen) {
    set_err(err, errLen, "%s", "");
    if (e == NULL) { set_err(err, errLen, "No engine"); return -1; }
    if (speakers == NULL || count == 0 || count > DL_MAX_SPEAKERS) {
        set_err(err, errLen, "Choose between 1 and %d speakers", DL_MAX_SPEAKERS);
        return -1;
    }
    if (e->running) dl_engine_stop(e);
    memcpy(e->speakers, speakers, sizeof *speakers * count);
    for (uint32_t i = 0; i < count; i++) e->speakers[i].sinkId[sizeof e->speakers[i].sinkId - 1] = '\0';
    e->count = count;

    pw_thread_loop_lock(e->loop);
    if (e->coreDead) {
        pw_thread_loop_unlock(e->loop);
        set_err(err, errLen, "Lost the connection to PipeWire. Restart Domine.");
        return -1;
    }
    if (e->metadata == NULL) {
        pw_thread_loop_unlock(e->loop);
        set_err(err, errLen, "No session manager found (the \"default\" metadata is missing). Is WirePlumber running?");
        return -1;
    }
    int found = 0;
    for (uint32_t i = 0; i < count; i++) if (node_by_name(e, NODE_SINK, e->speakers[i].sinkId) != NULL) found++;
    if (found == 0) {
        pw_thread_loop_unlock(e->loop);
        set_err(err, errLen, "None of the chosen speakers is connected");
        return -1;
    }
    pw_thread_loop_unlock(e->loop);

    DLRender *r = dl_render_create(DL_RATE, count, DL_MAX_FRAMES, DL_RING_FRAMES, DL_RING_TARGET, DL_RING_HIGH);
    if (r == NULL) { set_err(err, errLen, "Out of memory"); return -1; }
    apply_settings(e, r);

    pw_thread_loop_lock(e->loop);
    e->render = r;
    e->error[0] = '\0';

    // Virtual sink. monitor.channel-volumes stays false so the monitor we
    // capture is before the sink's own volume: that volume (volume keys)
    // becomes the kernel's master gain instead.
    struct pw_properties *sp = pw_properties_new(
        PW_KEY_FACTORY_NAME, "support.null-audio-sink",
        PW_KEY_NODE_NAME, DL_SINK_NAME,
        PW_KEY_NODE_DESCRIPTION, "Domine",
        PW_KEY_MEDIA_CLASS, "Audio/Sink",
        "audio.position", "FL,FR",
        "audio.channels", "2",
        "monitor.channel-volumes", "false",
        PW_KEY_OBJECT_LINGER, "false",
        NULL);
    e->virtualSink = pw_core_create_object(e->core, "adapter", PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, &sp->dict, 0);
    pw_properties_free(sp);
    if (e->virtualSink == NULL || roundtrip(e) < 0 || node_by_name(e, NODE_SELF, DL_SINK_NAME) == NULL) {
        char msg[256];
        copy_str(msg, sizeof msg, e->error[0] ? e->error : "Could not create the Domine sink");
        if (e->virtualSink != NULL) pw_proxy_destroy(e->virtualSink);
        e->virtualSink = NULL;
        e->render = NULL;
        pw_thread_loop_unlock(e->loop);
        dl_render_destroy(r);
        set_err(err, errLen, "%s", msg);
        return -1;
    }

    // Default sink: remember, persist for crash recovery, switch to Domine.
    copy_str(e->savedConfigured, sizeof e->savedConfigured,
             value_is_domine(e->configuredValue) ? "" : e->configuredValue);
    if (!dl_json_name(e->savedConfigured, e->previousSink, sizeof e->previousSink)) {
        if (!value_is_domine(e->defaultValue)) dl_json_name(e->defaultValue, e->previousSink, sizeof e->previousSink);
    }
    save_previous_default(e->savedConfigured);
    pw_metadata_set_property(e->metadata, PW_ID_CORE, DL_KEY_CONFIGURED, "Spa:String:JSON",
                             "{ \"name\": \"" DL_SINK_NAME "\" }");
    e->defaultChanged = 1;

    // Capture the Domine sink's monitor.
    char latency[32];
    snprintf(latency, sizeof latency, "256/%d", DL_RATE);
    struct pw_properties *cp = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_APP_NAME, "Domine",
        PW_KEY_NODE_NAME, DL_SINK_NAME ".capture",
        PW_KEY_NODE_LATENCY, latency,
        PW_KEY_STREAM_CAPTURE_SINK, "true",
        PW_KEY_TARGET_OBJECT, DL_SINK_NAME,
        PW_KEY_NODE_DONT_RECONNECT, "true",
        "node.dont-fallback", "true",
        NULL);
    e->captureState = PW_STREAM_STATE_CONNECTING;
    e->capture = pw_stream_new(e->core, DL_SINK_NAME ".capture", cp);
    int res = -1;
    if (e->capture != NULL) {
        pw_stream_add_listener(e->capture, &e->captureListener, &capture_events, e);
        uint8_t buf[1024];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
        const struct spa_pod *params[1] = { stereo_format(&b) };
        res = pw_stream_connect(e->capture, PW_DIRECTION_INPUT, PW_ID_ANY,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, params, 1);
    }
    e->running = 1;
    if (res < 0) {
        pw_thread_loop_unlock(e->loop);
        dl_engine_stop(e);
        set_err(err, errLen, "Could not capture the Domine sink");
        return -1;
    }
    for (uint32_t i = 0; i < count; i++) {
        e->playback[i].stream = NULL;
        if (node_by_name(e, NODE_SINK, e->speakers[i].sinkId) != NULL) playback_create(e, i);
    }
    route_all_apps(e);
    update_state(e);
    pw_thread_loop_unlock(e->loop);
    notify(e);
    return 0;
}

void dl_engine_stop(DLEngine *e) {
    if (e == NULL || !e->running) return;
    pw_thread_loop_lock(e->loop);
    e->running = 0;
    route_all_apps(e);   // clears exclusion targets (running is 0)
    if (e->capture != NULL) {
        spa_hook_remove(&e->captureListener);
        pw_stream_destroy(e->capture);
        e->capture = NULL;
    }
    for (uint32_t i = 0; i < e->count; i++) playback_destroy(e, i);
    if (e->defaultChanged) {
        restore_default(e, e->savedConfigured);
        forget_previous_default();
        e->defaultChanged = 0;
    }
    if (e->virtualSink != NULL) {
        pw_proxy_destroy(e->virtualSink);
        e->virtualSink = NULL;
    }
    if (!e->coreDead) roundtrip(e);
    DLRender *r = e->render;
    e->render = NULL;
    e->captureState = PW_STREAM_STATE_UNCONNECTED;
    update_state(e);
    pw_thread_loop_unlock(e->loop);
    dl_render_destroy(r);
    notify(e);
}

DLState dl_engine_state(DLEngine *e) {
    return e != NULL ? (DLState)atomic_load(&e->state) : DL_ERROR;
}

void dl_engine_error(DLEngine *e, char *out, uint32_t len) {
    if (out == NULL || len == 0) return;
    out[0] = '\0';
    if (e == NULL) return;
    pw_thread_loop_lock(e->loop);
    copy_str(out, len, e->error);
    pw_thread_loop_unlock(e->loop);
}

void dl_engine_update_speakers(DLEngine *e, const DLSpeaker *speakers, uint32_t count) {
    if (e == NULL || speakers == NULL || count == 0 || count > DL_MAX_SPEAKERS) return;
    int sameSinks = count == e->count;
    for (uint32_t i = 0; sameSinks && i < count; i++) sameSinks = strcmp(speakers[i].sinkId, e->speakers[i].sinkId) == 0;
    if (e->running && !sameSinks) {
        // Different set of sinks: rebuild from scratch, like the macOS engine.
        char err[256];
        if (dl_engine_start(e, speakers, count, err, sizeof err) < 0) {
            pw_thread_loop_lock(e->loop);
            copy_str(e->error, sizeof e->error, err);
            atomic_store(&e->state, DL_ERROR);
            pw_thread_loop_unlock(e->loop);
            notify(e);
        }
        return;
    }
    memcpy(e->speakers, speakers, sizeof *speakers * count);
    e->count = count;
    if (e->render != NULL) dl_render_configure(e->render, e->speakers, count, e->sinkMute ? 0.0f : e->master);
}

void dl_engine_set_master(DLEngine *e, float volume) {
    if (e == NULL) return;
    if (!isfinite(volume) || volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    pw_thread_loop_lock(e->loop);
    e->master = volume;
    e->sinkVolume = volume;
    DLNode *self = node_by_name(e, NODE_SELF, DL_SINK_NAME);
    if (self != NULL) set_node_volume(self, volume);
    master_to_render(e);
    pw_thread_loop_unlock(e->loop);
}

float dl_engine_master(DLEngine *e) {
    if (e == NULL) return 0.0f;
    pw_thread_loop_lock(e->loop);
    const float m = e->sinkMute ? 0.0f : e->master;
    pw_thread_loop_unlock(e->loop);
    return m;
}

void dl_engine_set_width(DLEngine *e, float degrees) {
    if (e == NULL) return;
    e->width = degrees;
    if (e->render != NULL) domine_surround_set_width(e->render->kernel, degrees);
}

void dl_engine_set_surround_level(DLEngine *e, float level) {
    if (e == NULL) return;
    e->level = level;
    if (e->render != NULL) domine_surround_set_surround_level(e->render->kernel, level);
}

void dl_engine_set_orbit(DLEngine *e, float degreesPerSecond) {
    if (e == NULL) return;
    e->orbit = degreesPerSecond;
    if (e->render != NULL) domine_surround_set_orbit_rate(e->render->kernel, degreesPerSecond);
}

void dl_engine_set_rotation(DLEngine *e, float degrees) {
    if (e == NULL) return;
    e->rotation = degrees;
    if (e->render != NULL) domine_surround_set_rotation(e->render->kernel, degrees);
}

void dl_engine_set_demo(DLEngine *e, int on) {
    if (e == NULL) return;
    e->demo = on != 0;
    if (e->render != NULL) domine_surround_set_demo(e->render->kernel, e->demo);
}

int dl_engine_demo_status(DLEngine *e, float *seconds, float *azimuth, int *section) {
    if (e == NULL || e->render == NULL) {
        if (seconds) *seconds = 0.0f;
        if (azimuth) *azimuth = 0.0f;
        if (section) *section = 0;
        return 0;
    }
    return domine_surround_demo_status(e->render->kernel, seconds, azimuth, section);
}

float dl_engine_peak(DLEngine *e, uint32_t speaker) {
    if (e == NULL || e->render == NULL) return 0.0f;
    return dl_render_peak(e->render, speaker);
}

void dl_engine_set_delay_ms(DLEngine *e, uint32_t speaker, float ms) {
    if (e == NULL || speaker >= DL_MAX_SPEAKERS) return;
    if (!isfinite(ms) || ms < 0.0f) ms = 0.0f;
    if (ms > DOMINE_MAX_DELAY_MS) ms = DOMINE_MAX_DELAY_MS;
    e->manualDelay[speaker] = ms;
    if (e->render != NULL) dl_render_set_manual_delay(e->render, speaker, ms);
}

float dl_engine_reported_latency_ms(DLEngine *e, uint32_t speaker) {
    if (e == NULL || speaker >= DL_MAX_SPEAKERS) return -1.0f;
    float ms = -1.0f;
    pw_thread_loop_lock(e->loop);
    if (e->running && speaker < e->count && e->playback[speaker].stream != NULL) {
        struct pw_time t;
        memset(&t, 0, sizeof t);
        if (pw_stream_get_time_n(e->playback[speaker].stream, &t, sizeof t) == 0 && t.rate.denom > 0 && t.delay >= 0
            && e->playback[speaker].state == PW_STREAM_STATE_STREAMING) {
            ms = (float)((double)t.delay * t.rate.num / t.rate.denom * 1000.0);
        }
    }
    pw_thread_loop_unlock(e->loop);
    return ms;
}

void dl_engine_set_test_tone(DLEngine *e, int speaker) {
    if (e == NULL) return;
    e->tone = speaker;
    if (e->render != NULL) dl_render_set_test_tone(e->render, speaker);
}

void dl_engine_set_click_test(DLEngine *e, int on) {
    if (e == NULL) return;
    e->click = on == 1;
    if (e->render != NULL) dl_render_set_click_test(e->render, e->click);
}

void dl_engine_set_eq(DLEngine *e, uint32_t speaker, const void *eqParams) {
    if (e == NULL || eqParams == NULL || speaker >= DL_MAX_SPEAKERS) return;
    e->eq[speaker] = *(const DomineEQParams *)eqParams;
    e->hasEq[speaker] = 1;
    if (e->render != NULL) dl_render_set_eq(e->render, speaker, &e->eq[speaker]);
}

void dl_engine_set_bass(DLEngine *e, uint32_t speaker, const void *bassParams) {
    if (e == NULL || bassParams == NULL || speaker >= DL_MAX_SPEAKERS) return;
    e->bass[speaker] = *(const DomineBassParams *)bassParams;
    e->hasBass[speaker] = 1;
    if (e->render != NULL) dl_render_set_bass(e->render, speaker, &e->bass[speaker]);
}

void dl_engine_set_compressor(DLEngine *e, uint32_t speaker, const void *compressorParams) {
    if (e == NULL || compressorParams == NULL || speaker >= DL_MAX_SPEAKERS) return;
    e->comp[speaker] = *(const DomineCompressorParams *)compressorParams;
    e->hasComp[speaker] = 1;
    if (e->render != NULL) dl_render_set_compressor(e->render, speaker, &e->comp[speaker]);
}

void dl_engine_set_spatial(DLEngine *e, float amount, float roomMs) {
    if (e == NULL) return;
    e->spatialAmount = amount;
    e->spatialRoom = roomMs;
    if (e->render != NULL) {
        DomineSpatialParams sp = { amount, roomMs, 5000.0f };
        domine_surround_set_spatial(e->render->kernel, &sp);
    }
}

uint32_t dl_engine_apps(DLEngine *e, DLApp *out, uint32_t max) {
    if (e == NULL || out == NULL) return 0;
    uint32_t n = 0;
    pw_thread_loop_lock(e->loop);
    for (int i = 0; i < DL_MAX_APPS && n < max; i++) {
        DLAppEntry *a = &e->apps[i];
        if (!a->used) continue;
        int live = 0;
        for (int j = 0; j < DL_MAX_NODES && !live; j++) {
            live = e->nodes[j].used && e->nodes[j].kind == NODE_APP && strcmp(e->nodes[j].appKey, a->key) == 0;
        }
        if (!live) continue;
        copy_str(out[n].key, sizeof out[n].key, a->key);
        copy_str(out[n].label, sizeof out[n].label, a->label[0] ? a->label : a->key);
        out[n].volume = a->volume;
        out[n].excluded = a->excluded;
        n++;
    }
    pw_thread_loop_unlock(e->loop);
    return n;
}

void dl_engine_set_app_volume(DLEngine *e, const char *key, float volume) {
    if (e == NULL || key == NULL) return;
    if (!isfinite(volume) || volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    pw_thread_loop_lock(e->loop);
    DLAppEntry *a = app_by_key(e, key, 1);
    if (a != NULL) {
        a->volume = volume;
        a->volumeSet = 1;
        for (int i = 0; i < DL_MAX_NODES; i++) {
            DLNode *n = &e->nodes[i];
            if (n->used && n->kind == NODE_APP && strcmp(n->appKey, key) == 0) set_node_volume(n, volume);
        }
    }
    pw_thread_loop_unlock(e->loop);
}

void dl_engine_set_app_excluded(DLEngine *e, const char *key, int excluded, const char *excludeSinkId) {
    if (e == NULL || key == NULL) return;
    pw_thread_loop_lock(e->loop);
    DLAppEntry *a = app_by_key(e, key, 1);
    if (a != NULL) {
        a->excluded = excluded != 0;
        copy_str(a->excludeSink, sizeof a->excludeSink, excludeSinkId);
        for (int i = 0; i < DL_MAX_NODES; i++) {
            DLNode *n = &e->nodes[i];
            if (n->used && n->kind == NODE_APP && strcmp(n->appKey, key) == 0) {
                // Force a rewrite when the target sink changed.
                if (a->excluded) n->targetSet = 0;
                route_app_node(e, n);
            }
        }
    }
    pw_thread_loop_unlock(e->loop);
    notify(e);
}
