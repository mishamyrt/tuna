#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <fstream>
#include <iostream>
#include <numbers>
#include <string>
#include <thread>
#include <vector>

#include "../mac/DSP.h"

namespace {
constexpr unsigned frames = 128;
constexpr unsigned impulseBlocks = 256;

void expect(bool ok, const char* what)
{
    if (!ok) {
        std::cerr << what << '\n';
        std::exit(1);
    }
}

void check(OSStatus status, const char* what)
{
    if (status != noErr) {
        std::cerr << what << ": " << status << '\n';
        std::exit(1);
    }
}

struct Source {
    double rate;
    bool signal = false;

    static OSStatus pull(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp* timestamp,
                         UInt32, UInt32 count, AudioBufferList* output)
    {
        const auto& source = *static_cast<Source*>(ref);
        for (UInt32 channel = 0; channel < 2; ++channel) {
            auto* data = static_cast<float*>(output->mBuffers[channel].mData);
            for (UInt32 i = 0; i < count; ++i) {
                const double frame = timestamp->mSampleTime + i;
                data[i] = source.signal
                    ? 0.2f * std::sin(frame * (channel == 0 ? 0.051 : 0.078))
                    : frame == 0.0 ? 1.0f : 0.0f;
            }
        }
        return noErr;
    }
};

struct Output {
    UInt32 mNumberBuffers = 2;
    AudioBuffer mBuffers[2]{};
};

void renderBlock(AudioUnit unit, AudioTimeStamp& timestamp, float* left, float* right)
{
    Output data;
    data.mBuffers[0] = {1, frames * sizeof(float), left};
    data.mBuffers[1] = {1, frames * sizeof(float), right};
    AudioUnitRenderActionFlags flags = 0;
    check(AudioUnitRender(unit, &flags, &timestamp, 0, frames,
                          reinterpret_cast<AudioBufferList*>(&data)), "render stereo");
    timestamp.mSampleTime += frames;
}

void verify(AudioUnit unit, const ACConfig& profile, double rate, UInt32 mode)
{
    const AudioStreamBasicDescription format{
        rate, kAudioFormatLinearPCM, AudioFormatFlags(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved,
        sizeof(float), 1, sizeof(float), 2, 32, 0
    };
    for (const auto scope : {kAudioUnitScope_Input, kAudioUnitScope_Output}) {
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, sizeof(format)),
              "set stream format");
    }

    auto config = profile;
    config.mode = mode;
    check(AudioUnitSetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0, &config, sizeof(config)),
          "apply profile and mode");

    Source source{rate};
    const AURenderCallbackStruct input{&Source::pull, &source};
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                               &input, sizeof(input)), "set render source");
    check(AudioUnitInitialize(unit), "initialize stereo AU");

    double latency = -1;
    UInt32 size = sizeof(latency);
    check(AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size),
          "get latency");
    expect(std::abs(latency * rate - ac_latency(mode, rate)) < 1e-8, "AU latency disagrees with DSP");

    std::array<std::vector<float>, 2> impulse;
    for (auto& channel : impulse) {
        channel.resize(frames * impulseBlocks);
    }
    AudioTimeStamp timestamp{};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    auto render = [&](float* left, float* right) {
        renderBlock(unit, timestamp, left, right);
    };
    for (unsigned i = 0; i < impulseBlocks; ++i) {
        render(impulse[0].data() + i * frames, impulse[1].data() + i * frames);
    }

    constexpr unsigned points = 160;
    double maxError = 0;
    for (unsigned channel = 0; channel < 2; ++channel) {
        std::array<float, points> target;
        ac_curve(&config, rate, channel, false, ac_headroom(&config, rate), target.data(), target.size());
        for (unsigned index = 0; index < points; ++index) {
            const double frequency = 20 * std::pow(1000.0, double(index) / (points - 1));
            const auto advance = std::polar(1.0, -2 * std::numbers::pi * frequency / rate);
            std::complex<double> sum = 0, phasor = 1;
            for (float sample : impulse[channel]) {
                sum += double(sample) * phasor;
                phasor *= advance;
            }
            maxError = std::max(maxError, std::abs(20 * std::log10(std::abs(sum)) - target[index]));
        }
    }
    if (config.wet == 0) {
        for (const auto& channel : impulse) {
            for (size_t i = 0; i < channel.size(); ++i) {
                expect(channel[i] == (i == ac_latency(mode, rate) ? 1.0f : 0.0f),
                       "dry output differs from the latency-aligned original");
            }
        }
    } else {
        expect(impulse[0] != impulse[1], "stereo responses were identical");
    }
    expect(maxError < 0.75, "measured response exceeded 0.75 dB from the imported profile");

    if (mode == 2) {
        const auto delay = static_cast<size_t>(std::round(latency * rate));
        for (const auto& channel : impulse) {
            for (size_t i = 1; i <= delay; ++i) {
                expect(std::abs(channel[delay - i] - channel[delay + i]) < 3e-6,
                       "linear-phase impulse was asymmetric");
            }
        }
    }

    source.signal = true;
    std::array<float, frames> left, right;
    std::vector<double> timings;
    timings.reserve(2500);
    for (unsigned i = 0; i < 2500; ++i) {
        const auto start = std::chrono::steady_clock::now();
        render(left.data(), right.data());
        timings.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count());
    }
    std::sort(timings.begin(), timings.end());
    std::cout << rate << " Hz, mode " << mode << ", wet " << config.wet << ": " << latency * 1000 << " ms, "
              << maxError << " dB max error, " << timings[timings.size() * 99 / 100]
              << " µs p99 at 128 frames\n";
    if (config.wet == 0.5f) {
        config.wet = 0;
        check(AudioUnitSetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0, &config, sizeof(config)),
              "change the mixer during playback");
        for (unsigned block = 0; block < 4; ++block) {
            render(left.data(), right.data());
        }
        for (unsigned i = 0; i < frames; ++i) {
            const double frame = timestamp.mSampleTime - frames + i - ac_latency(mode, rate);
            expect(std::abs(left[i] - 0.2f * std::sin(frame * 0.051)) < 1e-6,
                   "live mixer should settle on dry, latency-aligned audio");
            expect(std::abs(right[i] - 0.2f * std::sin(frame * 0.078)) < 1e-6,
                   "live mixer should preserve the right channel");
        }
    }
    check(AudioUnitUninitialize(unit), "uninitialize AU");
}

void verifyLiveChanges(AudioUnit unit)
{
    constexpr double rate = 48000;
    ACConfig config{};
    config.version = 2;
    config.wet = 1;
    config.alignment = 1;
    config.safe_headroom = 1;
    config.left.delay_ms = 42;
    auto setConfig = [&] {
        check(AudioUnitSetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0,
                                   &config, sizeof(config)), "set live transition config");
    };
    auto latency = [&] {
        double seconds = -1;
        UInt32 size = sizeof(seconds);
        check(AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                                   &seconds, &size), "read live latency");
        return seconds;
    };
    Source source{rate, true};
    const AURenderCallbackStruct input{&Source::pull, &source};
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                               &input, sizeof(input)), "set live transition source");
    setConfig();
    check(AudioUnitInitialize(unit), "initialize live transition AU");

    AudioTimeStamp timestamp{};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    std::array<float, frames> left, right;
    auto render = [&] { renderBlock(unit, timestamp, left.data(), right.data()); };
    for (unsigned block = 0; block < 24; ++block) {
        render();
    }
    config.right.trim = -6;
    setConfig();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    bool rightSettled = false;
    while (!rightSettled && std::chrono::steady_clock::now() < deadline) {
        render();
        rightSettled = true;
        for (unsigned i = 0; i < frames; ++i) {
            const double frame = timestamp.mSampleTime - frames + i;
            const double expectedLeft = 0.2f * std::sin((frame - 2016) * 0.051);
            expect(std::abs(left[i] - expectedLeft) < 1e-6, "live edit dropped the aligned left channel");
            const double expectedRight = 0.2f * std::sin(frame * 0.078) * std::pow(10.0, -6.0 / 20.0);
            rightSettled &= std::abs(right[i] - expectedRight) < 1e-6;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    expect(rightSettled, "live trim never took effect");

    struct Listener {
        std::thread::id renderThread = std::this_thread::get_id();
        std::atomic<bool> notified{false};
    } listener;
    const AudioUnitPropertyListenerProc onLatency = [](void* context, AudioUnit, AudioUnitPropertyID,
                                                       AudioUnitScope, AudioUnitElement) {
        auto& listener = *static_cast<Listener*>(context);
        expect(std::this_thread::get_id() != listener.renderThread, "latency notified on the render thread");
        listener.notified.store(true);
    };
    check(AudioUnitAddPropertyListener(unit, kAudioUnitProperty_Latency, onLatency, &listener),
          "add live latency listener");
    config.mode = 2;
    setConfig();
    expect(latency() == 0.0, "AU published the pending latency before render");
    render();
    expect(latency() == 0.0, "AU published the latency during the first warm-up block");

    const auto handoffDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!listener.notified.load() && std::chrono::steady_clock::now() < handoffDeadline) {
        render();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    expect(listener.notified.load(), "AU did not notify the host after the latency handoff");
    expect(std::abs(latency() * rate - ac_latency(2, rate)) < 1e-8, "AU did not publish the active latency");
    check(AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_Latency, onLatency, &listener),
          "remove live latency listener");
    for (unsigned block = 0; block < 4; ++block) {
        render();
    }
    for (unsigned i = 0; i < frames; ++i) {
        const double frame = timestamp.mSampleTime - frames + i - ac_latency(2, rate);
        const double expected = 0.2f * std::sin(frame * 0.078) * std::pow(10.0, -6.0 / 20.0);
        expect(std::abs(right[i] - expected) < 1e-6, "active render disagrees with the reported latency");
    }
    config.target = ACTargetHarman;
    setConfig();
    bool targetAudible = false;
    const auto targetDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!targetAudible && std::chrono::steady_clock::now() < targetDeadline) {
        render();
        targetAudible = std::all_of(right.begin(), right.end(), [](float value) {
            return std::abs(value) < 0.06f;
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    expect(targetAudible, "live Target Curve change never reached the render path");
    expect(std::abs(latency() * rate - ac_latency(2, rate)) < 1e-8, "Target Curve changed the filter latency");
    config.range_low = 1'000;
    config.range_high = 5'000;
    config.range_enabled = 1;
    setConfig();
    bool rangeAudible = false;
    const auto rangeDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!rangeAudible && std::chrono::steady_clock::now() < rangeDeadline) {
        render();
        rangeAudible = std::any_of(right.begin(), right.end(), [](float value) {
            return std::abs(value) > 0.075f;
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    expect(rangeAudible, "live calibration range did not remove the out-of-band trim");
    check(AudioUnitUninitialize(unit), "uninitialize live transition AU");

    config.mode = 0;
    config.target = ACTargetFlat;
    config.range_low = config.range_high = 0;
    config.range_enabled = 0;
    config.user[0] = {20, 24, 20, 0, 1};
    setConfig();
    check(AudioUnitInitialize(unit), "initialize narrow-band tail AU");
    double tail = 0;
    UInt32 size = sizeof(tail);
    check(AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0,
                               &tail, &size), "read narrow-band tail");
    expect(tail > 2.0 && tail == ac_tail_time(&config, rate), "AU did not report the narrow-band tail");
    check(AudioUnitUninitialize(unit), "uninitialize narrow-band tail AU");
}
}

int main(int argc, char** argv)
{
    expect(argc == 2, "usage: verify path-to-stereo.tmreq");
    std::ifstream file(argv[1], std::ios::binary);
    expect(file.good(), "read profile file");
    const std::string data{std::istreambuf_iterator<char>(file), {}};
    ACConfig config{};
    config.version = 2;
    config.wet = 1;
    config.target = ACTargetMarshall;
    expect(ac_import(reinterpret_cast<const uint8_t*>(data.data()), data.size(), "Test profile", &config),
           "import asymmetric stereo profile");
    expect(config.target == ACTargetMarshall, "profile import should preserve the Target Curve");
    config.target = ACTargetFlat;
    expect(config.left.bands[0].frequency != config.right.bands[0].frequency, "first L/R band should differ");
    expect(!ac_import(reinterpret_cast<const uint8_t*>(data.data()), data.size() / 2, "Broken", &config),
           "reject a truncated preset");
    expect(std::strcmp(config.name, "Test profile") == 0, "failed import should preserve the profile");

    const AudioComponentDescription description{kAudioUnitType_Effect, 'ACal', 'Myrt', 0, 0};
    const auto component = AudioComponentFindNext(nullptr, &description);
    expect(component, "AU is missing from the Core Audio registry");
    AudioUnit unit = nullptr;
    check(AudioComponentInstanceNew(component, &unit), "open AU");
    AudioUnitCocoaViewInfo view{};
    UInt32 size = sizeof(view);
    check(AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &view, &size),
          "get SwiftUI view factory");
    expect(CFEqual(view.mCocoaAUViewClass[0], CFSTR("CalibrationViewFactory")), "wrong editor factory");
    CFRelease(view.mCocoaAUViewClass[0]);
    CFRelease(view.mCocoaAUViewBundleLocation);

    for (double rate : {44100., 48000., 96000.}) {
        for (UInt32 mode : {0, 1, 2}) {
            verify(unit, config, rate, mode);
        }
    }
    for (float wet : {0.0f, 0.5f}) {
        config.wet = wet;
        for (UInt32 mode : {0, 1, 2}) {
            verify(unit, config, 48000, mode);
        }
    }
    verifyLiveChanges(unit);
    auto targetConfig = config;
    targetConfig.wet = 1;
    targetConfig.safe_headroom = 1;
    for (unsigned target : {ACTargetHarman, ACTargetMarshall}) {
        targetConfig.target = target;
        for (UInt32 mode : {0, 1, 2}) {
            verify(unit, targetConfig, 48000, mode);
        }
    }
    targetConfig.range_low = 200;
    targetConfig.range_high = 5'000;
    targetConfig.range_enabled = 1;
    for (UInt32 mode : {0, 1, 2}) {
        verify(unit, targetConfig, 48000, mode);
    }

    ac_set_user_band(&config, 0, {2000, -4, 1.25, 0, 2});
    config.mode = 2;
    config.alignment = 1;
    config.safe_headroom = 1;
    config.wet = 0.37f;
    config.target = ACTargetHarman;
    config.range_low = 200;
    config.range_high = 5'000;
    config.range_enabled = 1;
    check(AudioUnitSetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0, &config, sizeof(config)),
          "set state for round trip");
    CFPropertyListRef state = nullptr;
    size = sizeof(state);
    check(AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size),
          "save profile and user EQ into AU preset");
    check(AudioComponentInstanceDispose(unit), "close first AU");
    check(AudioComponentInstanceNew(component, &unit), "open fresh AU");
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, sizeof(state)),
          "restore profile and user EQ from AU preset");
    ACConfig restored{};
    size = sizeof(restored);
    check(AudioUnitGetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0, &restored, &size), "get restored state");
    expect(std::memcmp(&config, &restored, sizeof(config)) == 0, "the preset changed across restart");
    auto legacyState = CFDictionaryCreateMutableCopy(nullptr, 0, static_cast<CFDictionaryRef>(state));
    CFRelease(state);
    const auto configKey = CFSTR("com.myrt.audio-calibration.config");
    const auto targetKey = CFSTR("com.myrt.audio-calibration.target");
    const auto rangeKey = CFSTR("com.myrt.audio-calibration.range");
    const auto storedData = static_cast<CFDataRef>(CFDictionaryGetValue(legacyState, configKey));
    expect(CFDataGetLength(storedData) == 812, "older components need the original v2 config payload");
    CFDictionaryRemoveValue(legacyState, targetKey);
    CFDictionaryRemoveValue(legacyState, rangeKey);
    CFPropertyListRef legacy = legacyState;
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &legacy, sizeof(legacy)),
          "restore a v2 preset saved before Target Curve");
    check(AudioUnitGetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0, &restored, &size), "get restored v2 state");
    config.target = ACTargetFlat;
    config.range_low = config.range_high = 0;
    config.range_enabled = 0;
    expect(std::memcmp(&config, &restored, sizeof(config)) == 0, "v2 preset should restore with a flat target");

    auto legacyConfig = config;
    legacyConfig.version = 1;
    auto legacyData = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&legacyConfig), offsetof(ACConfig, wet));
    CFDictionarySetValue(legacyState, configKey, legacyData);
    CFRelease(legacyData);
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &legacy, sizeof(legacy)),
          "restore a preset saved before the mixer");
    CFRelease(legacyState);
    check(AudioUnitGetProperty(unit, ACConfigProperty, kAudioUnitScope_Global, 0, &restored, &size), "get migrated state");
    config.wet = 1;
    expect(std::memcmp(&config, &restored, sizeof(config)) == 0, "legacy preset should restore fully wet");
    check(AudioComponentInstanceDispose(unit), "close the AU");
    std::cout << "AU preset round trip and editor factory passed\n";
}
