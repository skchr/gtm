/* Android audio backend — AAudio primary + OpenSL ES fallback.
 * Shareable interface for Nim bridge.
 */

#ifndef ANDROID_AUDIO_IMPL_H
#define ANDROID_AUDIO_IMPL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*android_pcm_callback)(float *buffer, int frames, void *userdata);

#define ANDROID_AUDIO_BACKEND_AAUDIO 1
#define ANDROID_AUDIO_BACKEND_SLES   2

typedef struct {
    int backend;               /* ANDROID_AUDIO_BACKEND_AAUDIO or _SLES */
    android_pcm_callback cb;
    void *userdata;
    int sampleRate;
    int channels;
    int64_t framesWritten;
} AndroidAudioCtx;

/* Try AAudio first; returns NULL if AAudio unavailable (API < 26).
 * On success, sets ctx->backend = ANDROID_AUDIO_BACKEND_AAUDIO. */
AndroidAudioCtx *android_audio_init(int sampleRate, int channels,
                                    android_pcm_callback cb, void *userdata);

int  android_audio_start(AndroidAudioCtx *ctx);
int  android_audio_stop(AndroidAudioCtx *ctx);
int  android_audio_get_position(AndroidAudioCtx *ctx, int64_t *frames);
int  android_audio_set_volume(AndroidAudioCtx *ctx, float volume);
void android_audio_destroy(AndroidAudioCtx *ctx);
const char *android_audio_get_backend_name(AndroidAudioCtx *ctx);

#ifdef __cplusplus
}
#endif

#endif
