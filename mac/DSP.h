#ifndef AUDIO_CALIBRATION_DSP_H
#define AUDIO_CALIBRATION_DSP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ACProfileBands = 9, ACUserBands = 8, ACNameBytes = 256,
    ACConfigProperty = 0x41430001, ACStatusProperty = 0x41430002,
    ACConfigEditProperty = 0x41430003, ACConfigChanged = -70001,
    ACTargetFlat = 0, ACTargetHarman = 1, ACTargetMarshall = 2
};

typedef struct {
    float frequency, gain, q;
    uint32_t kind, channels;
} ACBand;

typedef struct {
    ACBand bands[ACProfileBands];
    float trim, delay_ms;
} ACChannel;

typedef struct {
    uint32_t version, mode, alignment, safe_headroom;
    ACChannel left, right;
    ACBand user[ACUserBands];
    char name[ACNameBytes];
    float wet;
    uint32_t target;
    uint32_t range_low, range_high, range_enabled;
} ACConfig;

typedef struct {
    ACConfig original, updated;
} ACConfigEdit;

typedef struct {
    double sample_rate;
    float peak;
} ACStatus;

typedef struct ACProcessor ACProcessor;

bool ac_validate(const ACConfig *config);
bool ac_import(const uint8_t *bytes, size_t size, const char *name, ACConfig *config);
ACBand ac_user_band(const ACConfig *config, size_t index);
void ac_set_user_band(ACConfig *config, size_t index, ACBand band);
size_t ac_latency(uint32_t mode, double rate);
size_t ac_alignment_frames(const ACConfig *config, double rate);
size_t ac_range_warmup(const ACConfig *config, double rate);
double ac_tail_time(const ACConfig *config, double rate);
float ac_headroom(const ACConfig *config, double rate);
void ac_curve(const ACConfig *config, double rate, uint32_t channel, bool profile_only, float wet_gain_db,
              float *points, size_t count);
ACProcessor *ac_create(const ACConfig *config, double rate);
void ac_begin_transition(const ACProcessor *active, ACProcessor *incoming);
void ac_destroy(ACProcessor *processor);
void ac_reset(ACProcessor *processor);
float ac_process(ACProcessor *processor, size_t channel, const float *input, size_t input_stride,
                 float *output, size_t output_stride, size_t frames, float wet);

#ifdef __cplusplus
}
#endif
#endif
