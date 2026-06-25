/* Android audio backend: AAudio primary + OpenSL ES fallback + PulseAudio.
 * Single compilation unit to avoid symbol conflicts.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#include "audio_impl.h"
#ifdef USE_PULSEAUDIO
#include "pulse_audio.h"
#endif

/* ================================================================
 *  AAudio backend (Android 8.0+, loaded at runtime)
 * ================================================================ */
#define AAUDIO_STREAM_STATE_STARTING      3
#define AAUDIO_STREAM_STATE_STARTED       4
#define AAUDIO_STREAM_STATE_STOPPING      7
#define AAUDIO_STREAM_STATE_STOPPED       8
#define AAUDIO_OK                         0
#define AAUDIO_CALLBACK_RESULT_CONTINUE   0
#define AAUDIO_CALLBACK_RESULT_STOP       1
#define AAUDIO_FORMAT_PCM_FLOAT           0x00000004UL
#define AAUDIO_PERFORMANCE_MODE_LOW_LATENCY 10
#define AAUDIO_SHARING_MODE_SHARED         10
#define AAUDIO_DIRECTION_OUTPUT            1
#define AAUDIO_UNSPECIFIED                 0

typedef struct AAudioStreamBuilder AAudioStreamBuilder;
typedef struct AAudioStream       AAudioStream;
typedef int32_t aaudio_result_t;

typedef aaudio_result_t (*aaudio_data_callback_proc)(
    void *stream, void *userdata, void *audioData, int32_t numFrames);

static void *gAaudioLib = NULL;
static aaudio_result_t (*gCreateBuilder)(AAudioStreamBuilder**) = NULL;
static aaudio_result_t (*gBuilderSetFormat)(AAudioStreamBuilder*, uint32_t) = NULL;
static aaudio_result_t (*gBuilderSetChannels)(AAudioStreamBuilder*, int32_t) = NULL;
static aaudio_result_t (*gBuilderSetSampleRate)(AAudioStreamBuilder*, int32_t) = NULL;
static aaudio_result_t (*gBuilderSetPerfMode)(AAudioStreamBuilder*, int32_t) = NULL;
static aaudio_result_t (*gBuilderSetSharing)(AAudioStreamBuilder*, uint32_t) = NULL;
static aaudio_result_t (*gBuilderSetDirection)(AAudioStreamBuilder*, int32_t) = NULL;
static aaudio_result_t (*gBuilderSetDataCb)(AAudioStreamBuilder*, aaudio_data_callback_proc, void*) = NULL;
static aaudio_result_t (*gBuilderOpen)(AAudioStreamBuilder*, AAudioStream**) = NULL;
static void           (*gBuilderDelete)(AAudioStreamBuilder*) = NULL;
static aaudio_result_t (*gStreamStart)(AAudioStream*) = NULL;
static aaudio_result_t (*gStreamStop)(AAudioStream*) = NULL;
static aaudio_result_t (*gStreamClose)(AAudioStream*) = NULL;
static aaudio_result_t (*gStreamWaitState)(AAudioStream*, int32_t, int32_t*, int64_t) = NULL;
static aaudio_result_t (*gStreamTimestamp)(AAudioStream*, int, int64_t*, int64_t*) = NULL;
static int32_t         (*gStreamFramesWritten)(AAudioStream*) = NULL;
static int32_t         (*gStreamSampleRate)(AAudioStream*) = NULL;
static aaudio_result_t (*gStreamSetVolume)(AAudioStream*, float) = NULL;

static int loadAaudio(void) {
    if (gAaudioLib) return 1;
    gAaudioLib = dlopen("libaaudio.so", RTLD_NOW | RTLD_LOCAL);
    if (!gAaudioLib) return 0;
    #define L(n, v) do { \
        v = (__typeof__(v))dlsym(gAaudioLib, n); \
        if (!v) { dlclose(gAaudioLib); gAaudioLib = NULL; return 0; } \
    } while(0)
    L("AAudio_createStreamBuilder", gCreateBuilder);
    L("AAudioStreamBuilder_setFormat", gBuilderSetFormat);
    L("AAudioStreamBuilder_setChannelCount", gBuilderSetChannels);
    L("AAudioStreamBuilder_setSampleRate", gBuilderSetSampleRate);
    L("AAudioStreamBuilder_setPerformanceMode", gBuilderSetPerfMode);
    L("AAudioStreamBuilder_setSharingMode", gBuilderSetSharing);
    L("AAudioStreamBuilder_setDirection", gBuilderSetDirection);
    L("AAudioStreamBuilder_setDataCallback", gBuilderSetDataCb);
    L("AAudioStreamBuilder_openStream", gBuilderOpen);
    L("AAudioStreamBuilder_delete", gBuilderDelete);
    L("AAudioStream_requestStart", gStreamStart);
    L("AAudioStream_requestStop", gStreamStop);
    L("AAudioStream_close", gStreamClose);
    L("AAudioStream_waitForStateChange", gStreamWaitState);
    L("AAudioStream_getTimestamp", gStreamTimestamp);
    L("AAudioStream_getFramesWritten", gStreamFramesWritten);
    L("AAudioStream_getSampleRate", gStreamSampleRate);
    L("AAudioStream_setVolume", gStreamSetVolume);
    return 1;
}

typedef struct {
    AndroidAudioCtx base;
    AAudioStream   *stream;
    int             started;
} AaudioCtx;

static aaudio_result_t aaudioDataCb(void *stream, void *userdata, void *audioData, int32_t numFrames) {
    (void)stream;
    AaudioCtx *ctx = (AaudioCtx *)userdata;
    int ret = ctx->base.cb((float *)audioData, (int)numFrames, ctx->base.userdata);
    ctx->base.framesWritten += numFrames;
    return (ret == 0) ? AAUDIO_CALLBACK_RESULT_CONTINUE : AAUDIO_CALLBACK_RESULT_STOP;
}

static int aaudioInit(AaudioCtx *ctx, int sampleRate, int channels,
                      android_pcm_callback cb, void *userdata) {
    if (!loadAaudio()) return -1;

    AAudioStreamBuilder *b = NULL;
    if (gCreateBuilder(&b) != AAUDIO_OK || !b) return -1;

    gBuilderSetFormat(b, AAUDIO_FORMAT_PCM_FLOAT);
    gBuilderSetChannels(b, (int32_t)channels);
    if (sampleRate > 0) gBuilderSetSampleRate(b, (int32_t)sampleRate);
    gBuilderSetPerfMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    gBuilderSetSharing(b, AAUDIO_SHARING_MODE_SHARED);
    gBuilderSetDirection(b, AAUDIO_DIRECTION_OUTPUT);
    gBuilderSetDataCb(b, aaudioDataCb, ctx);

    aaudio_result_t res = gBuilderOpen(b, &ctx->stream);
    gBuilderDelete(b);
    if (res != AAUDIO_OK || !ctx->stream) return -1;

    ctx->base.backend   = ANDROID_AUDIO_BACKEND_AAUDIO;
    ctx->base.cb        = cb;
    ctx->base.userdata  = userdata;
    ctx->base.sampleRate = (int)gStreamSampleRate(ctx->stream);
    ctx->base.channels  = channels;
    ctx->base.framesWritten = 0;
    ctx->started        = 0;
    return 0;
}

/* ================================================================
 *  OpenSL ES backend (Android API 9+, fallback)
 * ================================================================ */
#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>

#define SLES_NUM_BUFS  4
#define SLES_BUF_FRAMES 1024

typedef struct {
    AndroidAudioCtx            base;
    SLObjectItf                engineObj;
    SLEngineItf                engine;
    SLObjectItf                outputMixObj;
    SLObjectItf                playerObj;
    SLPlayItf                  player;
    SLAndroidSimpleBufferQueueItf bufQueue;
    int16_t                   *buffers[SLES_NUM_BUFS];
    int                        bufIdx;
    volatile int               stopped;
    int                        queued;    /* total mixed frames before last clear */
} SlesCtx;

static void slesBufferCb(SLAndroidSimpleBufferQueueItf caller, void *context) {
    (void)caller;
    SlesCtx *ctx = (SlesCtx *)context;
    if (ctx->stopped) return;

    int idx = ctx->bufIdx;
    float tmp[SLES_BUF_FRAMES * 2]; /* max stereo, stack allocated */
    float *buf = tmp;
    /* For more channels we'd heap-allocate, but mobile is 1-2 ch */
    int frames = SLES_BUF_FRAMES;
    int ch = ctx->base.channels;

    if (ctx->base.cb(buf, frames, ctx->base.userdata) != 0)
        frames = 0;

    if (frames > 0) {
        ctx->base.framesWritten += frames;
        int16_t *dst = ctx->buffers[idx];
        for (int f = 0; f < frames; f++) {
            for (int c = 0; c < ch; c++) {
                float s = buf[f * ch + c];
                if (s > 1.0f) s = 1.0f;
                else if (s < -1.0f) s = -1.0f;
                dst[f * ch + c] = (int16_t)(s * 32767.0f);
            }
        }
        ctx->bufIdx = (idx + 1) % SLES_NUM_BUFS;
        (*caller)->Enqueue(caller, dst, (SLuint32)(frames * ch * sizeof(int16_t)));
    } else {
        ctx->stopped = 1;
    }
}

static int slesInit(SlesCtx *ctx, int sampleRate, int channels,
                    android_pcm_callback cb, void *userdata) {
    SLresult res;

    res = slCreateEngine(&ctx->engineObj, 1,
        (SLEngineOption[]){{ SL_ENGINEOPTION_THREADSAFE, SL_BOOLEAN_TRUE }},
        0, NULL, NULL);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->engineObj)->Realize(ctx->engineObj, SL_BOOLEAN_FALSE);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->engineObj)->GetInterface(ctx->engineObj, SL_IID_ENGINE, &ctx->engine);
    if (res != SL_RESULT_SUCCESS) return -1;

    res = (*ctx->engine)->CreateOutputMix(ctx->engine, &ctx->outputMixObj, 0, NULL, NULL);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->outputMixObj)->Realize(ctx->outputMixObj, SL_BOOLEAN_FALSE);
    if (res != SL_RESULT_SUCCESS) return -1;

    SLDataLocator_AndroidSimpleBufferQueue bufLoc = {
        SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, SLES_NUM_BUFS
    };
    SLDataFormat_PCM pcmFmt = {
        SL_DATAFORMAT_PCM,
        (SLuint32)channels,
        (SLuint32)(sampleRate * 1000),
        SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_PCMSAMPLEFORMAT_FIXED_16,
        (channels == 2) ?
            (SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT) :
            SL_SPEAKER_FRONT_CENTER,
        SL_BYTEORDER_LITTLEENDIAN
    };
    SLDataSource audioSrc = { &bufLoc, &pcmFmt };

    SLDataLocator_OutputMix outLoc = {
        SL_DATALOCATOR_OUTPUTMIX, ctx->outputMixObj
    };
    SLDataSink audioSink = { &outLoc, NULL };

    SLInterfaceID ifaceIds[] = { SL_IID_BUFFERQUEUE };
    SLboolean ifaceReq[] = { SL_BOOLEAN_TRUE };

    res = (*ctx->engine)->CreateAudioPlayer(ctx->engine, &ctx->playerObj,
                                            &audioSrc, &audioSink,
                                            1, ifaceIds, ifaceReq);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->playerObj)->Realize(ctx->playerObj, SL_BOOLEAN_FALSE);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->playerObj)->GetInterface(ctx->playerObj, SL_IID_PLAY, &ctx->player);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->playerObj)->GetInterface(ctx->playerObj,
                                          SL_IID_ANDROIDSIMPLEBUFFERQUEUE,
                                          &ctx->bufQueue);
    if (res != SL_RESULT_SUCCESS) return -1;
    res = (*ctx->bufQueue)->RegisterCallback(ctx->bufQueue, slesBufferCb, ctx);
    if (res != SL_RESULT_SUCCESS) return -1;

    ctx->base.backend   = ANDROID_AUDIO_BACKEND_SLES;
    ctx->base.cb        = cb;
    ctx->base.userdata  = userdata;
    ctx->base.sampleRate = sampleRate;
    ctx->base.channels  = channels;
    ctx->base.framesWritten = 0;
    ctx->stopped        = 1;
    ctx->bufIdx         = 0;
    ctx->queued         = 0;

    size_t bufBytes = (size_t)(SLES_BUF_FRAMES * channels * sizeof(int16_t));
    for (int i = 0; i < SLES_NUM_BUFS; i++) {
        ctx->buffers[i] = (int16_t *)malloc(bufBytes);
        if (!ctx->buffers[i]) return -1;
        memset(ctx->buffers[i], 0, bufBytes);
    }
    return 0;
}

/* ================================================================
 *  Public API (dispatches to AAudio or SLES based on backend tag)
 * ================================================================ */

AndroidAudioCtx *android_audio_init(int sampleRate, int channels,
                                    android_pcm_callback cb, void *userdata) {
    /* Try AAudio first */
    AaudioCtx *aaudio = (AaudioCtx *)calloc(1, sizeof(AaudioCtx));
    if (aaudio && aaudioInit(aaudio, sampleRate, channels, cb, userdata) == 0)
        return (AndroidAudioCtx *)aaudio;
    free(aaudio);

  /* Fall back to OpenSL ES */
  SlesCtx *sles = (SlesCtx *)calloc(1, sizeof(SlesCtx));
  if (sles && slesInit(sles, sampleRate, channels, cb, userdata) == 0)
    return (AndroidAudioCtx *)sles;
  free(sles);

#ifdef USE_PULSEAUDIO
  /* Fall back to PulseAudio */
  AndroidAudioCtx *pulse = pulse_audio_init(sampleRate, channels, cb, userdata);
  if (pulse) return pulse;
#endif

  return NULL;
}

int android_audio_start(AndroidAudioCtx *actx) {
    if (!actx) return -1;
    if (actx->backend == ANDROID_AUDIO_BACKEND_AAUDIO) {
        AaudioCtx *ctx = (AaudioCtx *)actx;
        aaudio_result_t res = gStreamStart(ctx->stream);
        if (res != AAUDIO_OK) return -1;
        int32_t state = AAUDIO_STREAM_STATE_STARTING;
        gStreamWaitState(ctx->stream, AAUDIO_STREAM_STATE_STARTING, &state, 1000000000LL);
        ctx->started = 1;
        return 0;
    } else if (actx->backend == ANDROID_AUDIO_BACKEND_SLES) {
        SlesCtx *ctx = (SlesCtx *)actx;
        ctx->stopped = 0;
        /* Prime all buffers */
        for (int i = 0; i < SLES_NUM_BUFS; i++) {
            slesBufferCb(ctx->bufQueue, ctx);
            if (ctx->stopped) break;
        }
        return ((*ctx->player)->SetPlayState(ctx->player, SL_PLAYSTATE_PLAYING) == SL_RESULT_SUCCESS) ? 0 : -1;
    }
#ifdef USE_PULSEAUDIO
    else if (actx->backend == ANDROID_AUDIO_BACKEND_PULSE) {
        return pulse_audio_start(actx);
    }
#endif
    return -1;
}

int android_audio_stop(AndroidAudioCtx *actx) {
    if (!actx) return -1;
    if (actx->backend == ANDROID_AUDIO_BACKEND_AAUDIO) {
        AaudioCtx *ctx = (AaudioCtx *)actx;
        aaudio_result_t res = gStreamStop(ctx->stream);
        if (res != AAUDIO_OK) return -1;
        int32_t state = AAUDIO_STREAM_STATE_STOPPING;
        gStreamWaitState(ctx->stream, AAUDIO_STREAM_STATE_STOPPING, &state, 1000000000LL);
        ctx->started = 0;
        return 0;
    } else if (actx->backend == ANDROID_AUDIO_BACKEND_SLES) {
        SlesCtx *ctx = (SlesCtx *)actx;
        ctx->stopped = 1;
        SLresult res = (*ctx->player)->SetPlayState(ctx->player, SL_PLAYSTATE_STOPPED);
        (*ctx->bufQueue)->Clear(ctx->bufQueue);
        return (res == SL_RESULT_SUCCESS) ? 0 : -1;
    }
#ifdef USE_PULSEAUDIO
    else if (actx->backend == ANDROID_AUDIO_BACKEND_PULSE) {
        return pulse_audio_stop(actx);
    }
#endif
    return -1;
}

int android_audio_get_position(AndroidAudioCtx *actx, int64_t *frames) {
    if (!actx) return -1;
    if (actx->backend == ANDROID_AUDIO_BACKEND_AAUDIO) {
        AaudioCtx *ctx = (AaudioCtx *)actx;
        int64_t fp = 0, tn = 0;
        if (gStreamTimestamp(ctx->stream, 1, &fp, &tn) == AAUDIO_OK)
            *frames = fp;
        else
            *frames = (int64_t)gStreamFramesWritten(ctx->stream);
        return 0;
    } else if (actx->backend == ANDROID_AUDIO_BACKEND_SLES) {
        SlesCtx *ctx = (SlesCtx *)actx;
        /* Approximate: frames written minus buffered */
        *frames = ctx->base.framesWritten;
        return 0;
    }
#ifdef USE_PULSEAUDIO
    else if (actx->backend == ANDROID_AUDIO_BACKEND_PULSE) {
        return pulse_audio_get_position(actx, frames);
    }
#endif
    return -1;
}

int android_audio_set_volume(AndroidAudioCtx *actx, float volume) {
    if (!actx) return -1;
    if (actx->backend == ANDROID_AUDIO_BACKEND_AAUDIO) {
        AaudioCtx *ctx = (AaudioCtx *)actx;
        return (gStreamSetVolume(ctx->stream, volume) == AAUDIO_OK) ? 0 : -1;
    } else if (actx->backend == ANDROID_AUDIO_BACKEND_SLES) {
        SlesCtx *ctx = (SlesCtx *)actx;
        SLmillibel mb = (volume <= 0.0f) ? SL_MILLIBEL_MIN :
                         (SLmillibel)(2000.0f * log10f(volume));
        return ((*ctx->player)->SetVolumeLevel(ctx->player, mb) == SL_RESULT_SUCCESS) ? 0 : -1;
    }
#ifdef USE_PULSEAUDIO
    else if (actx->backend == ANDROID_AUDIO_BACKEND_PULSE) {
        return pulse_audio_set_volume(actx, volume);
    }
#endif
    return -1;
}

const char *android_audio_get_backend_name(AndroidAudioCtx *actx) {
    if (!actx) return "none";
    switch (actx->backend) {
        case ANDROID_AUDIO_BACKEND_AAUDIO: return "AAudio";
        case ANDROID_AUDIO_BACKEND_SLES:   return "OpenSL ES";
#ifdef ANDROID_AUDIO_BACKEND_PULSE
        case ANDROID_AUDIO_BACKEND_PULSE:  return "PulseAudio";
#endif
        default: return "unknown";
    }
}

void android_audio_destroy(AndroidAudioCtx *actx) {
    if (!actx) return;
    if (actx->backend == ANDROID_AUDIO_BACKEND_AAUDIO) {
        AaudioCtx *ctx = (AaudioCtx *)actx;
        if (ctx->stream) {
            if (ctx->started) {
                gStreamStop(ctx->stream);
                int32_t state = AAUDIO_STREAM_STATE_STOPPING;
                gStreamWaitState(ctx->stream, AAUDIO_STREAM_STATE_STOPPING, &state, 100000000LL);
            }
            gStreamClose(ctx->stream);
        }
        free(ctx);
    } else if (actx->backend == ANDROID_AUDIO_BACKEND_SLES) {
        SlesCtx *ctx = (SlesCtx *)actx;
        if (ctx->playerObj) (*ctx->playerObj)->Destroy(ctx->playerObj);
        if (ctx->outputMixObj) (*ctx->outputMixObj)->Destroy(ctx->outputMixObj);
        if (ctx->engineObj) (*ctx->engineObj)->Destroy(ctx->engineObj);
        for (int i = 0; i < SLES_NUM_BUFS; i++) free(ctx->buffers[i]);
        free(ctx);
    }
#ifdef USE_PULSEAUDIO
    else if (actx->backend == ANDROID_AUDIO_BACKEND_PULSE) {
        pulse_audio_destroy(actx);
    }
#endif
}
