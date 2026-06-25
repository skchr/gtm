/* PulseAudio backend for Termux/Android.
 * Compiled when -DUSE_PULSEAUDIO is defined.
 * Integrates via the same AndroidAudioCtx interface as AAudio/OpenSL ES.
 */

#ifndef ANDROID_PULSE_AUDIO_H
#define ANDROID_PULSE_AUDIO_H

#include "audio_impl.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ANDROID_AUDIO_BACKEND_PULSE 3

/* Try connecting to the default PulseAudio server via libpulse-simple.
 * Returns NULL if PulseAudio is unavailable or connection fails. */
AndroidAudioCtx *pulse_audio_init(int sampleRate, int channels,
                                  android_pcm_callback cb, void *userdata);

#ifdef __cplusplus
}
#endif

#endif
