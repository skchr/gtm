#define MINIAUDIO_IMPLEMENTATION
#include <stdint.h>
#include <stdio.h>
#include "miniaudio.h"

typedef struct {
    ma_engine engine;
    ma_sound  sound;
    int       sound_loaded;
} GtmAudioCtx;

GtmAudioCtx* gtm_audio_init(void) {
    GtmAudioCtx* ctx = (GtmAudioCtx*)ma_malloc(sizeof(GtmAudioCtx), NULL);
    if (!ctx) {
        fprintf(stderr, "[gtm] ma_malloc failed\n");
        return NULL;
    }
    ctx->sound_loaded = 0;
    ma_engine_config config = ma_engine_config_init();
    config.noDevice = MA_FALSE;
    if (ma_engine_init(&config, &ctx->engine) != MA_SUCCESS) {
        config.noDevice = MA_TRUE;
        if (ma_engine_init(&config, &ctx->engine) != MA_SUCCESS) {
            fprintf(stderr, "[gtm] ma_engine_init failed: no audio device available\n");
            ma_free(ctx, NULL);
            return NULL;
        }
    }
    fprintf(stderr, "[gtm] miniaudio engine initialized (noDevice=%d)\n", config.noDevice);
    return ctx;
}

void gtm_audio_uninit(GtmAudioCtx* ctx) {
    if (!ctx) return;
    if (ctx->sound_loaded) {
        ma_sound_stop(&ctx->sound);
        ma_sound_uninit(&ctx->sound);
        ctx->sound_loaded = 0;
    }
    ma_engine_uninit(&ctx->engine);
    ma_free(ctx, NULL);
}

int gtm_audio_load(GtmAudioCtx* ctx, const char* path) {
    if (!ctx) {
        fprintf(stderr, "[gtm] gtm_audio_load: ctx is NULL\n");
        return 0;
    }
    if (!path || !path[0]) {
        fprintf(stderr, "[gtm] gtm_audio_load: empty path\n");
        return 0;
    }
    if (ctx->sound_loaded) {
        ma_sound_stop(&ctx->sound);
        ma_sound_uninit(&ctx->sound);
        ctx->sound_loaded = 0;
    }
    if (ma_sound_init_from_file(&ctx->engine, path, 0, NULL, NULL, &ctx->sound) != MA_SUCCESS) {
        fprintf(stderr, "[gtm] ma_sound_init_from_file failed: %s\n", path);
        return 0;
    }
    ctx->sound_loaded = 1;
    fprintf(stderr, "[gtm] loaded audio: %s\n", path);
    return 1;
}

void gtm_audio_start(GtmAudioCtx* ctx) {
    if (!ctx || !ctx->sound_loaded) return;
    ma_sound_start(&ctx->sound);
}

void gtm_audio_stop(GtmAudioCtx* ctx) {
    if (!ctx || !ctx->sound_loaded) return;
    ma_sound_stop(&ctx->sound);
}

void gtm_audio_seek(GtmAudioCtx* ctx, double seconds) {
    if (!ctx || !ctx->sound_loaded) return;
    ma_uint64 total = 0;
    ma_sound_get_length_in_pcm_frames(&ctx->sound, &total);
    ma_uint64 current = ma_sound_get_time_in_pcm_frames(&ctx->sound);
    ma_uint32 sampleRate = ma_engine_get_sample_rate(&ctx->engine);
    int64_t delta = (int64_t)(seconds * sampleRate);
    int64_t target = (int64_t)current + delta;
    if (target < 0) target = 0;
    if ((ma_uint64)target > total) target = (int64_t)total;
    ma_sound_seek_to_pcm_frame(&ctx->sound, (ma_uint64)target);
}

void gtm_audio_set_volume(GtmAudioCtx* ctx, float volume) {
    if (!ctx || !ctx->sound_loaded) return;
    ma_sound_set_volume(&ctx->sound, volume);
}

double gtm_audio_get_time(GtmAudioCtx* ctx) {
    if (!ctx || !ctx->sound_loaded) return 0.0;
    ma_uint64 frames = ma_sound_get_time_in_pcm_frames(&ctx->sound);
    ma_uint32 sampleRate = ma_engine_get_sample_rate(&ctx->engine);
    if (sampleRate == 0) return 0.0;
    return (double)frames / (double)sampleRate;
}

double gtm_audio_get_duration(GtmAudioCtx* ctx) {
    if (!ctx || !ctx->sound_loaded) return 0.0;
    ma_uint64 frames = 0;
    ma_sound_get_length_in_pcm_frames(&ctx->sound, &frames);
    ma_uint32 sampleRate = ma_engine_get_sample_rate(&ctx->engine);
    if (sampleRate == 0) return 0.0;
    return (double)frames / (double)sampleRate;
}

int gtm_audio_is_playing(GtmAudioCtx* ctx) {
    if (!ctx || !ctx->sound_loaded) return 0;
    return ma_sound_is_playing(&ctx->sound) ? 1 : 0;
}
