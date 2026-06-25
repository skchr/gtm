/* PulseAudio backend for Termux/Android.
 * Uses libpulse-simple for PCM playback via a helper thread.
 * Compiled when -DUSE_PULSEAUDIO is defined.
 */
#define _GNU_SOURCE
#include <pulse/simple.h>
#include <pulse/error.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>

#include "pulse_audio.h"

#define PULL_FRAMES 1024

typedef struct {
    AndroidAudioCtx    base;
    pa_simple         *s;
    pthread_t          thread;
    volatile int       started;
    volatile int       stopped;
} PulseCtx;

static void* pulsePullThread(void *arg) {
    PulseCtx *ctx = (PulseCtx *)arg;
    int ch = ctx->base.channels;
    /* Stack buffer for max stereo; for >2 channels we'd heap-allocate */
    float buf[PULL_FRAMES * 2];

    while (!ctx->stopped) {
        int frames = PULL_FRAMES;
        if (ctx->base.cb(buf, frames, ctx->base.userdata) != 0) {
            /* Callback signaled end; write silence for remaining */
            memset(buf, 0, sizeof(buf));
        }

        int bytes = frames * ch * (int)sizeof(float);
        int error;
        if (pa_simple_write(ctx->s, buf, (size_t)bytes, &error) < 0) {
            fprintf(stderr, "[pulse] pa_simple_write: %s\n", pa_strerror(error));
            break;
        }
        ctx->base.framesWritten += frames;
    }
    return NULL;
}

AndroidAudioCtx *pulse_audio_init(int sampleRate, int channels,
                                   android_pcm_callback cb, void *userdata) {
    pa_sample_spec ss;
    ss.format   = PA_SAMPLE_FLOAT32LE;
    ss.channels = (uint8_t)channels;
    ss.rate     = (uint32_t)sampleRate;

    int error;
    pa_simple *s = pa_simple_new(NULL, "gtm", PA_STREAM_PLAYBACK,
                                 NULL, "playback", &ss, NULL, NULL, &error);
    if (!s) {
        fprintf(stderr, "[pulse] pa_simple_new: %s\n", pa_strerror(error));
        return NULL;
    }

    PulseCtx *ctx = (PulseCtx *)calloc(1, sizeof(PulseCtx));
    if (!ctx) {
        pa_simple_free(s);
        return NULL;
    }

    ctx->base.backend      = ANDROID_AUDIO_BACKEND_PULSE;
    ctx->base.cb           = cb;
    ctx->base.userdata     = userdata;
    ctx->base.sampleRate   = sampleRate;
    ctx->base.channels     = channels;
    ctx->base.framesWritten = 0;
    ctx->s                 = s;
    ctx->started           = 0;
    ctx->stopped           = 1;

    return (AndroidAudioCtx *)ctx;
}

static int pulseStart(PulseCtx *ctx) {
    if (!ctx || !ctx->s) return -1;
    ctx->stopped = 0;
    if (pthread_create(&ctx->thread, NULL, pulsePullThread, ctx) != 0) {
        ctx->stopped = 1;
        return -1;
    }
    ctx->started = 1;
    return 0;
}

static int pulseStop(PulseCtx *ctx) {
    if (!ctx || !ctx->s) return -1;
    ctx->stopped = 1;
    if (ctx->started) {
        pthread_join(ctx->thread, NULL);
        ctx->started = 0;
    }
    return 0;
}

/* The public API dispatchers in audio_impl.c call these through the
 * AndroidAudioCtx interface. We only expose pulse_audio_init() in the
 * header; the remaining operations go through the dispatch table in
 * audio_impl.c based on backend type. For PA we implement the same
 * operations here and audio_impl.c's dispatchers will call them. */

int pulse_audio_start(AndroidAudioCtx *actx) {
    if (!actx || actx->backend != ANDROID_AUDIO_BACKEND_PULSE) return -1;
    return pulseStart((PulseCtx *)actx);
}

int pulse_audio_stop(AndroidAudioCtx *actx) {
    if (!actx || actx->backend != ANDROID_AUDIO_BACKEND_PULSE) return -1;
    return pulseStop((PulseCtx *)actx);
}

int pulse_audio_get_position(AndroidAudioCtx *actx, int64_t *frames) {
    if (!actx || actx->backend != ANDROID_AUDIO_BACKEND_PULSE) return -1;
    PulseCtx *ctx = (PulseCtx *)actx;
    *frames = ctx->base.framesWritten;
    return 0;
}

int pulse_audio_set_volume(AndroidAudioCtx *actx, float volume) {
    (void)actx;
    (void)volume;
    /* pa_simple does not support volume control; use software gain. */
    return 0;
}

void pulse_audio_destroy(AndroidAudioCtx *actx) {
    if (!actx || actx->backend != ANDROID_AUDIO_BACKEND_PULSE) return;
    PulseCtx *ctx = (PulseCtx *)actx;
    pulseStop(ctx);
    if (ctx->s) {
        int error;
        pa_simple_drain(ctx->s, &error);
        pa_simple_free(ctx->s);
    }
    free(ctx);
}
