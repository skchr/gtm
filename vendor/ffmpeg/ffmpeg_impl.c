#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <stdint.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libswresample/swresample.h>
#include <alsa/asoundlib.h>
#include <math.h>

#define PCM_RING_SIZE (16384)

typedef struct {
  AVFormatContext*  fmt_ctx;
  AVCodecContext*   codec_ctx;
  SwrContext*       swr_ctx;
  int               audio_stream_idx;
  int               sample_rate;
  int               channels;
  AVRational        time_base;

  pthread_t         decode_thread;
  int               thread_started;
  volatile int      thread_stop;
  volatile int      playing;
  volatile int      paused;

  volatile int      seek_pending;
  volatile double   seek_target;
  double            current_time;

  snd_pcm_t*        alsa_handle;
  int               alsa_open;

  float             volume;

  float             pcm_ring[PCM_RING_SIZE];
  volatile int      pcm_wp;
  volatile int      pcm_rp;

  char              title[256];
  char              artist[256];
  char              album[256];
  double            duration;

  pthread_mutex_t   mutex;
} FfmpegAudioCtx;

static int alsa_open_device(FfmpegAudioCtx* ctx) {
  snd_pcm_hw_params_t* hw;
  unsigned int rate = ctx->sample_rate;
  int ret;

  ret = snd_pcm_open(&ctx->alsa_handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
  if (ret < 0) {
    fprintf(stderr, "[ffmpeg] decode snd_pcm_open: %s\n", snd_strerror(ret));
    return 0;
  }
  snd_pcm_hw_params_alloca(&hw);
  snd_pcm_hw_params_any(ctx->alsa_handle, hw);
  snd_pcm_hw_params_set_access(ctx->alsa_handle, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
  snd_pcm_hw_params_set_format(ctx->alsa_handle, hw, SND_PCM_FORMAT_FLOAT_LE);
  snd_pcm_hw_params_set_channels(ctx->alsa_handle, hw, ctx->channels);
  snd_pcm_hw_params_set_rate_near(ctx->alsa_handle, hw, &rate, 0);
  snd_pcm_uframes_t buf_frames = 4096;
  snd_pcm_hw_params_set_buffer_size_near(ctx->alsa_handle, hw, &buf_frames);
  ret = snd_pcm_hw_params(ctx->alsa_handle, hw);
  if (ret < 0) {
    fprintf(stderr, "[ffmpeg] snd_pcm_hw_params: %s\n", snd_strerror(ret));
    snd_pcm_close(ctx->alsa_handle);
    ctx->alsa_handle = NULL;
    return 0;
  }
  ctx->alsa_open = 1;
  return 1;
}

static void alsa_close_device(FfmpegAudioCtx* ctx) {
  if (ctx->alsa_handle) {
    snd_pcm_drain(ctx->alsa_handle);
    snd_pcm_close(ctx->alsa_handle);
    ctx->alsa_handle = NULL;
  }
  ctx->alsa_open = 0;
}

static int probe_alsa_default(void) {
  snd_pcm_t* handle = NULL;
  int ret = snd_pcm_open(&handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
  if (ret < 0) return 0;
  snd_pcm_close(handle);
  return 1;
}

FfmpegAudioCtx* ffmpeg_audio_init(void) {
  FfmpegAudioCtx* ctx = calloc(1, sizeof(FfmpegAudioCtx));
  if (!ctx) return NULL;
  if (!probe_alsa_default()) {
    fprintf(stderr, "[ffmpeg] ALSA default device not available\n");
    free(ctx);
    return NULL;
  }
  av_log_set_level(AV_LOG_QUIET);
  ctx->volume = 1.0f;
  ctx->audio_stream_idx = -1;
  pthread_mutex_init(&ctx->mutex, NULL);
  avformat_network_init();
  return ctx;
}

void ffmpeg_audio_uninit(FfmpegAudioCtx* ctx) {
  if (!ctx) return;
  ctx->thread_stop = 1;
  ctx->playing = 0;
  if (ctx->thread_started)
    pthread_join(ctx->decode_thread, NULL);
  alsa_close_device(ctx);
  if (ctx->swr_ctx) swr_free(&ctx->swr_ctx);
  if (ctx->codec_ctx) avcodec_free_context(&ctx->codec_ctx);
  if (ctx->fmt_ctx) avformat_close_input(&ctx->fmt_ctx);
  pthread_mutex_destroy(&ctx->mutex);
  free(ctx);
}

static void extract_metadata(FfmpegAudioCtx* ctx) {
  if (!ctx->fmt_ctx) return;
  AVDictionary* md = NULL;
  AVDictionaryEntry* t;

  /* Try format-level metadata first */
  t = av_dict_get(ctx->fmt_ctx->metadata, "title", NULL, 0);
  if (!t || !t->value[0]) {
    /* Fall back to stream-level metadata */
    if (ctx->audio_stream_idx >= 0) {
      AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
      if (st->metadata) {
        t = av_dict_get(st->metadata, "title", NULL, 0);
      }
    }
  }
  if (t && t->value[0]) strncpy(ctx->title, t->value, sizeof(ctx->title) - 1);

  t = av_dict_get(ctx->fmt_ctx->metadata, "artist", NULL, 0);
  if (!t || !t->value[0]) {
    if (ctx->audio_stream_idx >= 0) {
      AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
      if (st->metadata) {
        t = av_dict_get(st->metadata, "artist", NULL, 0);
      }
    }
  }
  if (t && t->value[0]) strncpy(ctx->artist, t->value, sizeof(ctx->artist) - 1);

  t = av_dict_get(ctx->fmt_ctx->metadata, "album", NULL, 0);
  if (!t || !t->value[0]) {
    if (ctx->audio_stream_idx >= 0) {
      AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
      if (st->metadata) {
        t = av_dict_get(st->metadata, "album", NULL, 0);
      }
    }
  }
  if (t && t->value[0]) strncpy(ctx->album, t->value, sizeof(ctx->album) - 1);

  if (ctx->fmt_ctx->duration != AV_NOPTS_VALUE)
    ctx->duration = (double)ctx->fmt_ctx->duration / AV_TIME_BASE;
  if (ctx->duration <= 0.0 && ctx->audio_stream_idx >= 0) {
    AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
    if (st->duration != AV_NOPTS_VALUE) {
      double sec = av_q2d(st->time_base) * st->duration;
      if (sec > 0) ctx->duration = sec;
    }
  }
}

int ffmpeg_audio_load(FfmpegAudioCtx* ctx, const char* path) {
  if (!ctx || !path || !path[0]) return 0;
  if (ctx->fmt_ctx) {
    avformat_close_input(&ctx->fmt_ctx);
    ctx->fmt_ctx = NULL;
  }
  if (ctx->codec_ctx) {
    avcodec_free_context(&ctx->codec_ctx);
    ctx->codec_ctx = NULL;
  }
  if (ctx->swr_ctx) {
    swr_free(&ctx->swr_ctx);
    ctx->swr_ctx = NULL;
  }
  ctx->audio_stream_idx = -1;
  ctx->duration = 0.0;
  ctx->current_time = 0.0;
  ctx->title[0] = '\0';
  ctx->artist[0] = '\0';
  ctx->album[0] = '\0';

  if (avformat_open_input(&ctx->fmt_ctx, path, NULL, NULL) != 0)
    return 0;
  if (avformat_find_stream_info(ctx->fmt_ctx, NULL) < 0)
    return 0;

  for (unsigned i = 0; i < ctx->fmt_ctx->nb_streams; i++) {
    if (ctx->fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
      ctx->audio_stream_idx = i;
      break;
    }
  }
  if (ctx->audio_stream_idx < 0) return 0;

  AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
  AVCodecParameters* par = st->codecpar;
  ctx->time_base = st->time_base;

  const AVCodec* codec = avcodec_find_decoder(par->codec_id);
  if (!codec) return 0;

  ctx->codec_ctx = avcodec_alloc_context3(codec);
  if (!ctx->codec_ctx) return 0;
  if (avcodec_parameters_to_context(ctx->codec_ctx, par) < 0) return 0;
  ctx->codec_ctx->pkt_timebase = st->time_base;
  if (avcodec_open2(ctx->codec_ctx, codec, NULL) < 0) return 0;

  ctx->sample_rate = par->sample_rate;
  ctx->channels = par->ch_layout.nb_channels;
  if (ctx->channels <= 0) ctx->channels = 2;

  ctx->swr_ctx = swr_alloc();
  if (!ctx->swr_ctx) return 0;

  AVChannelLayout out_ch_layout = AV_CHANNEL_LAYOUT_STEREO;
  if (ctx->channels == 1)
    out_ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;

  av_opt_set_chlayout(ctx->swr_ctx, "in_chlayout", &par->ch_layout, 0);
  av_opt_set_int(ctx->swr_ctx, "in_sample_rate", par->sample_rate, 0);
  av_opt_set_sample_fmt(ctx->swr_ctx, "in_sample_fmt", ctx->codec_ctx->sample_fmt, 0);
  av_opt_set_chlayout(ctx->swr_ctx, "out_chlayout", &out_ch_layout, 0);
  av_opt_set_int(ctx->swr_ctx, "out_sample_rate", par->sample_rate, 0);
  av_opt_set_sample_fmt(ctx->swr_ctx, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0);

  if (swr_init(ctx->swr_ctx) < 0) return 0;

  ctx->channels = out_ch_layout.nb_channels;
  extract_metadata(ctx);
  return 1;
}

static void* decode_thread(void* arg) {
  FfmpegAudioCtx* ctx = (FfmpegAudioCtx*)arg;
  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  float* conv_buf = NULL;
  int conv_cap = 0;
  uint8_t* out_planes[1] = { NULL };

  alsa_open_device(ctx);

  while (!ctx->thread_stop) {
    if (!ctx->playing || ctx->paused) {
      usleep(10000);
      continue;
    }

    if (ctx->seek_pending) {
      ctx->seek_pending = 0;
      double target = ctx->seek_target;
      avcodec_flush_buffers(ctx->codec_ctx);
      AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
      int64_t ts = (int64_t)(target / av_q2d(st->time_base));
      av_seek_frame(ctx->fmt_ctx, ctx->audio_stream_idx, ts, AVSEEK_FLAG_BACKWARD);
      ctx->current_time = target;
      continue;
    }

    int ret = av_read_frame(ctx->fmt_ctx, pkt);
    if (ret < 0) {
      ctx->playing = 0;
      break;
    }

    if (pkt->stream_index != ctx->audio_stream_idx) {
      av_packet_unref(pkt);
      continue;
    }

    ret = avcodec_send_packet(ctx->codec_ctx, pkt);
    av_packet_unref(pkt);
    if (ret < 0) continue;

    while (ret >= 0) {
      ret = avcodec_receive_frame(ctx->codec_ctx, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
      if (ret < 0) break;

      int need = frame->nb_samples * ctx->channels;
      if (need > conv_cap) {
        conv_buf = realloc(conv_buf, need * sizeof(float));
        conv_cap = need;
      }

      out_planes[0] = (uint8_t*)conv_buf;
      int conv = swr_convert(ctx->swr_ctx, out_planes, frame->nb_samples,
                             (const uint8_t**)frame->data, frame->nb_samples);
      if (conv <= 0) continue;

      int total = conv * ctx->channels;

      if (ctx->volume != 1.0f) {
        for (int i = 0; i < total; i++)
          conv_buf[i] *= ctx->volume;
      }

      if (ctx->alsa_open) {
        int fw = snd_pcm_writei(ctx->alsa_handle, conv_buf, conv);
        if (fw < 0) snd_pcm_recover(ctx->alsa_handle, fw, 1);
      }

      for (int i = 0; i < total; i++) {
        int wp = ctx->pcm_wp;
        int next = (wp + 1) % PCM_RING_SIZE;
        if (next != ctx->pcm_rp) {
          ctx->pcm_ring[wp] = conv_buf[i];
          ctx->pcm_wp = next;
        }
      }

      ctx->current_time += (double)conv / ctx->sample_rate;
      av_frame_unref(frame);
    }
  }

  av_packet_free(&pkt);
  av_frame_free(&frame);
  free(conv_buf);
  return NULL;
}

void ffmpeg_audio_start(FfmpegAudioCtx* ctx) {
  if (!ctx) return;
  ctx->playing = 1;
  ctx->paused = 0;
  if (!ctx->thread_started) {
    ctx->thread_stop = 0;
    pthread_create(&ctx->decode_thread, NULL, decode_thread, ctx);
    ctx->thread_started = 1;
  }
}

void ffmpeg_audio_pause(FfmpegAudioCtx* ctx) {
  if (!ctx) return;
  ctx->playing = 0;
  ctx->paused = 1;
  if (ctx->alsa_open) {
    snd_pcm_drop(ctx->alsa_handle);
    snd_pcm_prepare(ctx->alsa_handle);
  }
}

void ffmpeg_audio_stop(FfmpegAudioCtx* ctx) {
  if (!ctx) return;
  ctx->playing = 0;
  ctx->paused = 1;
  if (ctx->alsa_open) {
    snd_pcm_drop(ctx->alsa_handle);
    snd_pcm_prepare(ctx->alsa_handle);
  }
  ctx->current_time = 0.0;
  if (ctx->fmt_ctx && ctx->audio_stream_idx >= 0) {
    avcodec_flush_buffers(ctx->codec_ctx);
    AVStream* st = ctx->fmt_ctx->streams[ctx->audio_stream_idx];
    av_seek_frame(ctx->fmt_ctx, ctx->audio_stream_idx, 0, AVSEEK_FLAG_BACKWARD);
  }
  ctx->seek_pending = 0;
}

void ffmpeg_audio_seek(FfmpegAudioCtx* ctx, double seconds) {
  if (!ctx) return;
  ctx->seek_target = ctx->current_time + seconds;
  if (ctx->seek_target < 0.0) ctx->seek_target = 0.0;
  if (ctx->duration > 0.0 && ctx->seek_target > ctx->duration)
    ctx->seek_target = ctx->duration;
  ctx->seek_pending = 1;
}

void ffmpeg_audio_set_volume(FfmpegAudioCtx* ctx, float volume) {
  if (!ctx) return;
  ctx->volume = volume;
}

double ffmpeg_audio_get_time(FfmpegAudioCtx* ctx) {
  if (!ctx) return 0.0;
  return ctx->current_time;
}

double ffmpeg_audio_get_duration(FfmpegAudioCtx* ctx) {
  if (!ctx) return 0.0;
  return ctx->duration;
}

int ffmpeg_audio_is_playing(FfmpegAudioCtx* ctx) {
  if (!ctx) return 0;
  return ctx->playing && !ctx->paused ? 1 : 0;
}

int ffmpeg_audio_read_pcm(FfmpegAudioCtx* ctx, float* output, int count) {
  if (!ctx) return 0;
  int written = 0;
  while (written < count) {
    int rp = ctx->pcm_rp;
    if (rp == ctx->pcm_wp) break;
    output[written++] = ctx->pcm_ring[rp];
    ctx->pcm_rp = (rp + 1) % PCM_RING_SIZE;
  }
  return written;
}

void ffmpeg_audio_get_metadata(FfmpegAudioCtx* ctx,
                                char** title, char** artist,
                                char** album, double* duration) {
  if (!ctx) return;
  if (title) *title = ctx->title;
  if (artist) *artist = ctx->artist;
  if (album) *album = ctx->album;
  if (duration) *duration = ctx->duration;
}

// --- Biquad 10-band Equalizer ---

typedef struct {
  float b0, b1, b2, a1, a2;
  float x1, x2, y1, y2;
} Biquad;

#define EQ_BANDS 10

static const float EQ_FREQS[EQ_BANDS] = {
  31.25f, 62.5f, 125.0f, 250.0f, 500.0f,
  1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f
};

typedef struct {
  Biquad bands[EQ_BANDS];
  float  gains[EQ_BANDS];
  int    active;
  float  sample_rate;
} Equalizer;

static void biquad_peaking(Biquad* f, float fs, float freq, float gain_db, float q) {
  float a = powf(10.0f, gain_db / 40.0f);
  float omega = 2.0f * 3.14159265f * freq / fs;
  float alpha = sinf(omega) / (2.0f * q);
  float cosw = cosf(omega);
  f->b0 = 1.0f + alpha * a;
  f->b1 = -2.0f * cosw;
  f->b2 = 1.0f - alpha * a;
  f->a1 = -2.0f * cosw;
  f->a2 = 1.0f - alpha / a;
  float norm = 1.0f + alpha / a;
  f->b0 /= norm; f->b1 /= norm; f->b2 /= norm;
  f->a1 /= norm; f->a2 /= norm;
  f->x1 = f->x2 = f->y1 = f->y2 = 0.0f;
}

static float biquad_process(Biquad* f, float x) {
  float y = f->b0 * x + f->b1 * f->x1 + f->b2 * f->x2 - f->a1 * f->y1 - f->a2 * f->y2;
  f->x2 = f->x1; f->x1 = x;
  f->y2 = f->y1; f->y1 = y;
  return y;
}

static void eq_init(Equalizer* eq, float sample_rate) {
  memset(eq, 0, sizeof(Equalizer));
  eq->sample_rate = sample_rate;
  eq->active = 0;
}

static void eq_rebuild(Equalizer* eq) {
  eq->active = 0;
  for (int i = 0; i < EQ_BANDS; i++) {
    if (fabsf(eq->gains[i]) > 0.5f) eq->active = 1;
    biquad_peaking(&eq->bands[i], eq->sample_rate, EQ_FREQS[i], eq->gains[i], 1.0f);
  }
}

static void eq_set_band(Equalizer* eq, int band, float gain_db) {
  if (band < 0 || band >= EQ_BANDS) return;
  if (gain_db < -12.0f) gain_db = -12.0f;
  if (gain_db > 12.0f) gain_db = 12.0f;
  eq->gains[band] = gain_db;
  eq_rebuild(eq);
}

static void eq_apply(Equalizer* eq, float* data, int samples) {
  if (!eq->active) return;
  for (int i = 0; i < samples; i++) {
    float s = data[i];
    for (int b = 0; b < EQ_BANDS; b++) {
      s = biquad_process(&eq->bands[b], s);
    }
    data[i] = s;
  }
}

static const char* EQ_PRESET_NAMES[] = {
  "Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal",
  "BassBoost", "Headphones", "Laptop",
  "Electronic", "Acoustic", "Podcast", "Dance", NULL
};

static const float EQ_PRESETS[][EQ_BANDS] = {
  { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },         // Flat
  { 4, 4, 3, 1, 0, 0, 0, 2, 3, 4 },          // Rock — classic rock: boosted lows/highs, slight mid scoop
  { 2, 3, 4, 2, 0, -1, 0, 2, 3, 3 },         // Pop — presence boost, slight mid cut for clarity
  { 2, 2, 1, 0, 0, 0, 1, 2, 3, 4 },          // Classical — gentle rise in highs for brilliance
  { 2, 2, 1, 1, 2, 3, 2, 1, 1, 0 },          // Jazz — warm mids, rounded highs
  { 5, 5, 3, 1, 0, 0, 0, 0, 2, 3 },          // HipHop — heavy sub/bass, flat mids, crisp highs
  { -1, 0, 1, 3, 5, 5, 3, 1, 0, 0 },         // Vocal — boost speech presence 500-2kHz, cut rumble
  { 7, 6, 4, 2, 1, 0, 0, 0, 0, 0 },          // BassBoost — deep bass shelf only, clear mids/highs
  { 2, 2, 1, 0, -1, -2, -1, 1, 2, 3 },       // Headphones — compensate closed-back resonance
  { 0, 1, 2, 3, 4, 4, 3, 2, 1, 0 },          // Laptop — loudness contour for small speakers
  { 5, 4, 3, 0, -2, -2, 0, 3, 5, 6 },        // Electronic — smiley curve for synths/EDM
  { 2, 2, 1, 2, 3, 3, 2, 2, 2, 2 },          // Acoustic — slight low-mid warmth, natural top
  { -3, -2, -1, 2, 4, 5, 3, 1, 0, -1 },      // Podcast — cut rumble/sub, boost speech clarity 1-4kHz
  { 5, 4, 2, 0, -1, -1, 1, 3, 5, 5 },        // Dance — punchy low end, presence for percussion
};

// --- MixerCtx for PCM crossfade ---

typedef struct {
  FfmpegAudioCtx* master;
  FfmpegAudioCtx* slave;

  pthread_t         decode_thread;
  int               thread_started;
  volatile int      thread_stop;
  volatile int      playing;
  volatile int      paused;

  snd_pcm_t*        alsa_handle;
  int               alsa_open;

  volatile int      crossfade_active;
  int               crossfade_frames_remaining;
  int               crossfade_total_frames;

  float             pcm_ring[PCM_RING_SIZE];
  volatile int      pcm_wp;
  volatile int      pcm_rp;

  double            current_time;
  double            master_duration;

  float             volume;
  volatile int      master_ended;
  volatile int      slave_loaded;
  int               crossfade_reverse;
  int               crossfade_curve; /* 0=equal-power, 1=quadratic, 2=cubic, 3=asymmetric */
  volatile int      priming;        /* accumulate frames before first write */
  int               prime_target;   /* samples to accumulate before writing */
  Equalizer         eq;
} MixerCtx;

static int mixer_alsa_open(MixerCtx* mx) {
  if (!mx->master) { fprintf(stderr, "[ffmpeg] mixer_alsa_open: no master\n"); return 0; }
  snd_pcm_hw_params_t* hw;
  unsigned int rate = mx->master->sample_rate;
  int ret = snd_pcm_open(&mx->alsa_handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
  if (ret < 0) { fprintf(stderr, "[ffmpeg] mixer snd_pcm_open: %s\n", snd_strerror(ret)); return 0; }
  snd_pcm_hw_params_alloca(&hw);
  snd_pcm_hw_params_any(mx->alsa_handle, hw);
  snd_pcm_hw_params_set_access(mx->alsa_handle, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
  snd_pcm_hw_params_set_format(mx->alsa_handle, hw, SND_PCM_FORMAT_FLOAT_LE);
  snd_pcm_hw_params_set_channels(mx->alsa_handle, hw, mx->master->channels);
  snd_pcm_hw_params_set_rate_near(mx->alsa_handle, hw, &rate, 0);
  snd_pcm_uframes_t buf_frames = 4096;
  snd_pcm_hw_params_set_buffer_size_near(mx->alsa_handle, hw, &buf_frames);
  ret = snd_pcm_hw_params(mx->alsa_handle, hw);
  if (ret < 0) { snd_pcm_close(mx->alsa_handle); mx->alsa_handle = NULL; return 0; }
  mx->alsa_open = 1;
  return 1;
}

static void mixer_alsa_close(MixerCtx* mx) {
  if (mx->alsa_handle) { snd_pcm_drain(mx->alsa_handle); snd_pcm_close(mx->alsa_handle); mx->alsa_handle = NULL; }
  mx->alsa_open = 0;
}

static int decode_into_buf(FfmpegAudioCtx* ctx, AVPacket* pkt, AVFrame* frame,
                           float** buf, int* cap) {
  if (!ctx || !ctx->fmt_ctx) return 0;
  int ret = av_read_frame(ctx->fmt_ctx, pkt);
  if (ret < 0) return -1;
  if (pkt->stream_index != ctx->audio_stream_idx) { av_packet_unref(pkt); return 0; }
  ret = avcodec_send_packet(ctx->codec_ctx, pkt);
  av_packet_unref(pkt);
  if (ret < 0) return 0;
  ret = avcodec_receive_frame(ctx->codec_ctx, frame);
  if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
  if (ret < 0) return 0;
  int need = frame->nb_samples * ctx->channels;
  if (need > *cap) { *buf = realloc(*buf, need * sizeof(float)); *cap = need; }
  uint8_t* planes[1] = { (uint8_t*)*buf };
  int conv = swr_convert(ctx->swr_ctx, planes, frame->nb_samples,
                         (const uint8_t**)frame->data, frame->nb_samples);
  av_frame_unref(frame);
  if (conv <= 0) return 0;
  return conv * ctx->channels;
}

static void* mixer_thread(void* arg) {
  MixerCtx* mx = (MixerCtx*)arg;
  AVPacket* mpkt = av_packet_alloc();
  AVFrame* mframe = av_frame_alloc();
  AVPacket* spkt = av_packet_alloc();
  AVFrame* sframe = av_frame_alloc();
  float* mbuf = NULL; int mcap = 0;
  float* sbuf = NULL; int scap = 0;
  float* mixbuf = NULL; int mixcap = 0;
  float* prime_buf = NULL; int prime_cap = 0; int prime_filled = 0;

  if (!mixer_alsa_open(mx))
    fprintf(stderr, "[ffmpeg] mixer_thread: ALSA not available, no audio output\n");

  while (!mx->thread_stop) {
    if (!mx->playing || mx->paused) { usleep(10000); continue; }

    if (!mx->master || !mx->master->fmt_ctx) { usleep(10000); continue; }

    // Handle seek in mixer thread
    if (mx->master->seek_pending) {
      mx->master->seek_pending = 0;
      double target = mx->master->seek_target;
      avcodec_flush_buffers(mx->master->codec_ctx);
      AVStream* st = mx->master->fmt_ctx->streams[mx->master->audio_stream_idx];
      int64_t ts = (int64_t)(target / av_q2d(st->time_base));
      av_seek_frame(mx->master->fmt_ctx, mx->master->audio_stream_idx, ts, AVSEEK_FLAG_BACKWARD);
      mx->master->current_time = target;
      mx->current_time = target;
      continue;
    }

    // Decode master
    int mtotal = decode_into_buf(mx->master, mpkt, mframe, &mbuf, &mcap);
    if (mtotal < 0) {
      // Master EOF
      mx->master_ended = 1;
      if (!mx->crossfade_active) mx->playing = 0;
      break;
    }
    if (mtotal == 0) { usleep(1000); continue; }

    int ch = mx->master->channels;
    if (ch <= 0) ch = 2;

    if (mx->crossfade_active && mx->slave && mx->slave->fmt_ctx) {
      int stotal = decode_into_buf(mx->slave, spkt, sframe, &sbuf, &scap);
      if (stotal > 0) {
        int ch = mx->master->channels > 0 ? mx->master->channels : 2;
        int total_frames = mx->crossfade_total_frames;
        int remaining = mx->crossfade_frames_remaining;
        double p = 1.0 - (total_frames > 0 ? (double)remaining / total_frames : 0.0);
        float mgain, sgain;
        if (mx->crossfade_reverse) {
          double rp = 1.0 - p;
          switch (mx->crossfade_curve) {
            case 0: /* EqualPower */
              mgain = cos(rp * 3.14159f / 2.0f);
              sgain = sin(rp * 3.14159f / 2.0f);
              break;
            case 1: /* Quadratic */
              mgain = (1.0f - rp) * (1.0f - rp);
              sgain = rp * rp;
              break;
            case 2: /* Cubic */
              mgain = (1.0f - rp) * (1.0f - rp) * (1.0f - rp);
              sgain = rp * rp * rp;
              break;
            case 3: /* Asymmetric */
              mgain = cos(rp * 3.14159f / 2.0f);
              sgain = sin(rp * rp * 3.14159f / 2.0f);
              break;
            default:
              mgain = cos(rp * 3.14159f / 2.0f);
              sgain = sin(rp * 3.14159f / 2.0f);
          }
        } else {
          switch (mx->crossfade_curve) {
            case 0: /* EqualPower */
              mgain = cos(p * 3.14159f / 2.0f);
              sgain = sin(p * 3.14159f / 2.0f);
              break;
            case 1: /* Quadratic */
              mgain = (1.0f - p) * (1.0f - p);
              sgain = p * p;
              break;
            case 2: /* Cubic */
              mgain = (1.0f - p) * (1.0f - p) * (1.0f - p);
              sgain = p * p * p;
              break;
            case 3: /* Asymmetric */
              mgain = cos(p * p * 3.14159f / 2.0f);
              sgain = sin(p * 3.14159f / 2.0f);
              break;
            default:
              mgain = cos(p * 3.14159f / 2.0f);
              sgain = sin(p * 3.14159f / 2.0f);
          }
        }

        int nsamples = mtotal < stotal ? mtotal : stotal;
        if (nsamples > mixcap) { mixbuf = realloc(mixbuf, nsamples * sizeof(float)); mixcap = nsamples; }
        for (int i = 0; i < nsamples; i++) {
          mixbuf[i] = mbuf[i] * mgain + (i < stotal ? sbuf[i] : 0.0f) * sgain;
        }

        // Apply EQ to crossfaded output
        eq_apply(&mx->eq, mixbuf, nsamples);

        // Apply volume
        if (mx->volume != 1.0f)
          for (int i = 0; i < nsamples; i++) mixbuf[i] *= mx->volume;

        if (mx->alsa_open) {
          int fw = snd_pcm_writei(mx->alsa_handle, mixbuf, nsamples / ch);
          if (fw < 0) snd_pcm_recover(mx->alsa_handle, fw, 1);
        }

        // Write to pcm ring for visualizer
        for (int i = 0; i < nsamples; i++) {
          int wp = mx->pcm_wp;
          int next = (wp + 1) % PCM_RING_SIZE;
          if (next != mx->pcm_rp) { mx->pcm_ring[wp] = mixbuf[i]; mx->pcm_wp = next; }
        }

        int frames_proc = nsamples / ch;
        if (frames_proc < 1) frames_proc = 1;
        mx->current_time += (double)frames_proc / mx->master->sample_rate;
        mx->crossfade_frames_remaining -= frames_proc;
        if (mx->crossfade_frames_remaining <= 0) {
          mx->crossfade_active = 0;
          mx->crossfade_reverse = 0;
          // Auto-promote slave to master
          if (mx->slave) {
            FfmpegAudioCtx* old = mx->master;
            mx->master = mx->slave;
            mx->slave = NULL;
            mx->slave_loaded = 0;
            mx->master_ended = 0;
            mx->master_duration = mx->master->duration;
            ffmpeg_audio_uninit(old);
            // Reopen ALSA for new master's sample rate/channels
            mixer_alsa_close(mx);
            mixer_alsa_open(mx);
            continue;
          }
          mx->master_ended = 1;
          break;
        }
      } else if (stotal < 0) {
        // Slave finished
        mx->crossfade_active = 0;
        // Continue with master only
        goto normal_write;
      } else {
        // Slave not ready yet, write master only
        goto normal_write;
      }
    } else {
      normal_write:
      // Apply EQ to master output
      eq_apply(&mx->eq, mbuf, mtotal);
      // Apply volume
      if (mx->volume != 1.0f)
        for (int i = 0; i < mtotal; i++) mbuf[i] *= mx->volume;

      if (mx->alsa_open && mx->priming) {
        // Accumulate samples to prevent ALSA underrun on slow streams
        if (prime_filled + mtotal > prime_cap) {
          prime_cap = prime_filled + mtotal + 4096;
          prime_buf = realloc(prime_buf, prime_cap * sizeof(float));
        }
        memcpy(prime_buf + prime_filled, mbuf, mtotal * sizeof(float));
        prime_filled += mtotal;
        if (prime_filled >= mx->prime_target) {
          // Enough buffered, write all at once and disable priming
          if (mx->alsa_open) {
            int fw = snd_pcm_writei(mx->alsa_handle, prime_buf, prime_filled / ch);
            if (fw < 0) snd_pcm_recover(mx->alsa_handle, fw, 1);
          }
          // Copy to visualizer ring
          for (int i = 0; i < prime_filled; i++) {
            int wp = mx->pcm_wp;
            int next = (wp + 1) % PCM_RING_SIZE;
            if (next != mx->pcm_rp) { mx->pcm_ring[wp] = prime_buf[i]; mx->pcm_wp = next; }
          }
          mx->priming = 0;
          prime_filled = 0;
        }
      } else if (mx->alsa_open) {
        int fw = snd_pcm_writei(mx->alsa_handle, mbuf, mtotal / ch);
        if (fw < 0) {
          fprintf(stderr, "[ffmpeg] snd_pcm_writei err: %s\n", snd_strerror(fw));
          snd_pcm_recover(mx->alsa_handle, fw, 1);
        }
      }
      // If priming still active, already forwarded samples via prime_buf above
      if (!mx->priming) {
        for (int i = 0; i < mtotal; i++) {
          int wp = mx->pcm_wp;
          int next = (wp + 1) % PCM_RING_SIZE;
          if (next != mx->pcm_rp) { mx->pcm_ring[wp] = mbuf[i]; mx->pcm_wp = next; }
        }
      }
      mx->current_time += (double)(mtotal / ch) / mx->master->sample_rate;
    }
  }

  av_packet_free(&mpkt);
  av_frame_free(&mframe);
  av_packet_free(&spkt);
  av_frame_free(&sframe);
  mx->thread_started = 0;
  free(mbuf); free(sbuf); free(mixbuf); free(prime_buf);
  return NULL;
}

MixerCtx* ffmpeg_mixer_init(void) {
  MixerCtx* mx = calloc(1, sizeof(MixerCtx));
  if (!mx) return NULL;
  if (!probe_alsa_default()) {
    fprintf(stderr, "[ffmpeg] mixer: ALSA default device not available\n");
    free(mx);
    return NULL;
  }
  av_log_set_level(AV_LOG_QUIET);
  mx->volume = 1.0f;
  mx->priming = 0;
  mx->prime_target = 8192; /* ~93ms at 44100Hz stereo */
  avformat_network_init();
  return mx;
}

void ffmpeg_mixer_uninit(MixerCtx* mx) {
  if (!mx) return;
  mx->thread_stop = 1;
  mx->playing = 0;
  if (mx->thread_started) pthread_join(mx->decode_thread, NULL);
  mixer_alsa_close(mx);
  if (mx->master) ffmpeg_audio_uninit(mx->master);
  if (mx->slave) ffmpeg_audio_uninit(mx->slave);
  free(mx);
}

static void mixer_alsa_reopen(MixerCtx* mx) {
  mixer_alsa_close(mx);
  mixer_alsa_open(mx);
}

int ffmpeg_mixer_load_master(MixerCtx* mx, const char* path) {
  if (!mx) return 0;
  mx->crossfade_active = 0;
  mx->crossfade_reverse = 0;
  mx->priming = 0;
  if (mx->master) ffmpeg_audio_uninit(mx->master);
  mx->master = ffmpeg_audio_init();
  if (!mx->master) return 0;
  if (!ffmpeg_audio_load(mx->master, path)) return 0;
  mx->master_duration = mx->master->duration;
  mx->current_time = 0.0;
  mx->master_ended = 0;
  // Reopen ALSA for new stream's sample rate/channels
  mixer_alsa_reopen(mx);
  return 1;
}

int ffmpeg_mixer_load_slave(MixerCtx* mx, const char* path) {
  if (!mx) return 0;
  mx->slave_loaded = 0;
  if (mx->slave) ffmpeg_audio_uninit(mx->slave);
  mx->slave = ffmpeg_audio_init();
  if (!mx->slave) return 0;
  if (!ffmpeg_audio_load(mx->slave, path)) { mx->slave_loaded = 0; return 0; }
  mx->slave_loaded = 1;
  return 1;
}

void ffmpeg_mixer_start(MixerCtx* mx) {
  if (!mx) return;
  mx->playing = 1;
  mx->paused = 0;
  mx->priming = 1;
  if (!mx->thread_started) {
    mx->thread_stop = 0;
    pthread_create(&mx->decode_thread, NULL, mixer_thread, mx);
    mx->thread_started = 1;
  }
}

void ffmpeg_mixer_pause(MixerCtx* mx) {
  if (!mx) return;
  mx->playing = 0;
  mx->paused = 1;
  if (mx->alsa_open) { snd_pcm_drop(mx->alsa_handle); snd_pcm_prepare(mx->alsa_handle); }
}

void ffmpeg_mixer_stop(MixerCtx* mx) {
  if (!mx) return;
      mx->playing = 0;
  mx->paused = 1;
  if (mx->alsa_open) { snd_pcm_drop(mx->alsa_handle); snd_pcm_prepare(mx->alsa_handle); }
  mx->current_time = 0.0;
  mx->master_ended = 0;
  mx->crossfade_active = 0;
  mx->crossfade_reverse = 0;
  mx->priming = 0;
}

void ffmpeg_mixer_start_crossfade(MixerCtx* mx, int duration_frames, int reverse) {
  if (!mx || !mx->slave || !mx->slave_loaded) return;
  mx->crossfade_active = 1;
  mx->crossfade_total_frames = duration_frames;
  mx->crossfade_frames_remaining = duration_frames;
  mx->crossfade_reverse = reverse ? 1 : 0;
  // Rewind slave to beginning
  if (mx->slave->fmt_ctx && mx->slave->audio_stream_idx >= 0) {
    avcodec_flush_buffers(mx->slave->codec_ctx);
    AVStream* st = mx->slave->fmt_ctx->streams[mx->slave->audio_stream_idx];
    av_seek_frame(mx->slave->fmt_ctx, mx->slave->audio_stream_idx, 0, AVSEEK_FLAG_BACKWARD);
  }
}

void ffmpeg_mixer_set_crossfade_curve(MixerCtx* mx, int curve_type) {
  if (!mx) return;
  mx->crossfade_curve = curve_type;
}

double ffmpeg_mixer_get_time(MixerCtx* mx) {
  if (!mx) return 0.0;
  return mx->current_time;
}

double ffmpeg_mixer_get_duration(MixerCtx* mx) {
  if (!mx) return 0.0;
  return mx->master_duration;
}

int ffmpeg_mixer_get_sample_rate(MixerCtx* mx) {
  if (!mx || !mx->master) return 44100;
  return mx->master->sample_rate > 0 ? (int)mx->master->sample_rate : 44100;
}

int ffmpeg_mixer_is_playing(MixerCtx* mx) {
  if (!mx) return 0;
  return mx->playing && !mx->paused ? 1 : 0;
}

int ffmpeg_mixer_is_crossfading(MixerCtx* mx) {
  if (!mx) return 0;
  return mx->crossfade_active ? 1 : 0;
}

int ffmpeg_mixer_master_ended(MixerCtx* mx) {
  if (!mx) return 0;
  return mx->master_ended ? 1 : 0;
}

void ffmpeg_mixer_set_volume(MixerCtx* mx, float volume) {
  if (!mx) return;
  mx->volume = volume;
}

int ffmpeg_mixer_read_pcm(MixerCtx* mx, float* output, int count) {
  if (!mx) return 0;
  int written = 0;
  while (written < count) {
    int rp = mx->pcm_rp;
    if (rp == mx->pcm_wp) break;
    output[written++] = mx->pcm_ring[rp];
    mx->pcm_rp = (rp + 1) % PCM_RING_SIZE;
  }
  return written;
}

void ffmpeg_mixer_get_metadata(MixerCtx* mx, char** title, char** artist,
                                char** album, double* duration) {
  if (!mx || !mx->master) return;
  ffmpeg_audio_get_metadata(mx->master, title, artist, album, duration);
}

void ffmpeg_mixer_seek(MixerCtx* mx, double seconds) {
  if (!mx || !mx->master) return;
  mx->master->seek_target = mx->current_time + seconds;
  if (mx->master->seek_target < 0.0) mx->master->seek_target = 0.0;
  if (mx->master->duration > 0.0 && mx->master->seek_target > mx->master->duration)
    mx->master->seek_target = mx->master->duration;
  mx->master->seek_pending = 1;
}

int ffmpeg_mixer_set_eq_band(MixerCtx* mx, int band, float gain_db) {
  if (!mx || !mx->master) return 0;
  float sr = mx->master->sample_rate > 0 ? (float)mx->master->sample_rate : 44100.0f;
  // Lazy-init equalizer
  if (mx->eq.sample_rate != sr) eq_init(&mx->eq, sr);
  eq_set_band(&mx->eq, band, gain_db);
  return 1;
}

// === Album cover extraction ===

int ffmpeg_extract_cover(const char* path, unsigned char** out_data, unsigned int* out_size, char** out_mime) {
  AVFormatContext* fmt_ctx = NULL;
  *out_data = NULL;
  *out_size = 0;
  if (out_mime) *out_mime = NULL;

  int ret = avformat_open_input(&fmt_ctx, path, NULL, NULL);
  if (ret < 0) return 0;
  ret = avformat_find_stream_info(fmt_ctx, NULL);
  if (ret < 0) { avformat_close_input(&fmt_ctx); return 0; }

  for (unsigned i = 0; i < fmt_ctx->nb_streams; i++) {
    AVStream* st = fmt_ctx->streams[i];
    if (st->disposition & AV_DISPOSITION_ATTACHED_PIC) {
      AVPacket* pkt = &st->attached_pic;
      if (pkt->size > 0 && pkt->data) {
        *out_data = malloc(pkt->size);
        if (!*out_data) { avformat_close_input(&fmt_ctx); return 0; }
        memcpy(*out_data, pkt->data, pkt->size);
        *out_size = pkt->size;

        if (out_mime) {
          // Detect MIME type from magic bytes
          if (pkt->size >= 3 && pkt->data[0] == 0xFF && pkt->data[1] == 0xD8 && pkt->data[2] == 0xFF)
            *out_mime = strdup("image/jpeg");
          else if (pkt->size >= 4 && pkt->data[0] == 0x89 && pkt->data[1] == 'P' && pkt->data[2] == 'N' && pkt->data[3] == 'G')
            *out_mime = strdup("image/png");
          else if (pkt->size >= 12 && pkt->data[0] == 'R' && pkt->data[1] == 'I' && pkt->data[2] == 'F' && pkt->data[3] == 'F' &&
                   pkt->data[8] == 'W' && pkt->data[9] == 'E' && pkt->data[10] == 'B' && pkt->data[11] == 'P')
            *out_mime = strdup("image/webp");
          else
            *out_mime = strdup("image/jpeg"); // best guess
        }
        avformat_close_input(&fmt_ctx);
        return 1;
      }
    }
    // Also check for video stream that might be album art (some formats embed it differently)
    if (st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && i > 0) {
      // Not a cover — skip; we only want attached_pic
      continue;
    }
  }
  avformat_close_input(&fmt_ctx);
  return 0;
}

void ffmpeg_free_cover_data(unsigned char* data, char* mime) {
  if (data) free(data);
  if (mime) free(mime);
}

int ffmpeg_mixer_set_eq_preset(MixerCtx* mx, const char* name) {
  if (!mx || !name) return 0;
  if (!mx->master) return 0;
  float sr = mx->master->sample_rate > 0 ? (float)mx->master->sample_rate : 44100.0f;
  if (mx->eq.sample_rate != sr) eq_init(&mx->eq, sr);
  for (int p = 0; EQ_PRESET_NAMES[p] != NULL; p++) {
    if (strcasecmp(name, EQ_PRESET_NAMES[p]) == 0) {
      for (int b = 0; b < EQ_BANDS; b++)
        mx->eq.gains[b] = EQ_PRESETS[p][b];
      eq_rebuild(&mx->eq);
      return 1;
    }
  }
  // Flat if not matched
  for (int b = 0; b < EQ_BANDS; b++) mx->eq.gains[b] = 0.0f;
  eq_rebuild(&mx->eq);
  return 0;
}


