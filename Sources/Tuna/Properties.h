#ifndef TUNA_PROPERTIES_H
#define TUNA_PROPERTIES_H

#include "DSP.h"

enum {
    ACConfigProperty = 0x41430001, ACStatusProperty = 0x41430002,
    ACConfigEditProperty = 0x41430003, ACConfigChanged = -70001
};

typedef struct {
    ACConfig original, updated;
} ACConfigEdit;

typedef struct {
    double sample_rate;
    float peak;
} ACStatus;

#endif
