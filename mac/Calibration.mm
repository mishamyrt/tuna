#import <AppKit/AppKit.h>
#include <AudioUnitSDK/AUEffectBase.h>
#include <AudioUnitSDK/AUPlugInDispatch.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "DSP.h"

namespace {
const auto configKey = CFSTR("com.myrt.audio-calibration.config");
const auto targetKey = CFSTR("com.myrt.audio-calibration.target");
const auto rangeKey = CFSTR("com.myrt.audio-calibration.range");
constexpr ACConfig defaultConfig{.version = 2, .safe_headroom = 1, .wet = 1.0f};
constexpr auto legacyConfigSize = offsetof(ACConfig, wet);
constexpr auto storedConfigSize = offsetof(ACConfig, target);

struct Prepared {
    ACProcessor* processor;
    size_t latency;
    size_t alignmentFrames;
    size_t rangeWarmup;
    double tailSeconds;
    Prepared* next = nullptr;

    ~Prepared() { ac_destroy(processor); }
};

static_assert(legacyConfigSize == 808 && storedConfigSize == 812 && sizeof(ACConfig) == 828);
static_assert(std::atomic<Prepared*>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
}

class Calibration final : public ausdk::AUEffectBase {
    struct Notifications {
        ausdk::AUMutex mutex;
        Calibration* unit = nullptr;
    };

public:
    explicit Calibration(AudioComponentInstance unit)
        : AUEffectBase(unit), worker_(dispatch_queue_create("com.myrt.audio-calibration.prepare", DISPATCH_QUEUE_SERIAL)),
          notifications_(std::make_shared<Notifications>()),
          notificationTimer_(dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)))
    {
        const auto notifications = notifications_;
        notifications->unit = this;
        SetMutex(&notifications->mutex);
        dispatch_source_set_event_handler(notificationTimer_, ^{
            const std::unique_lock lock(notifications->mutex, std::try_to_lock);
            auto* owner = lock ? notifications->unit : nullptr;
            if (owner && owner->IsInitialized()) {
                owner->notifyProperties();
            }
        });
        dispatch_activate(notificationTimer_);
    }

    ~Calibration() override
    {
        const std::lock_guard lock(notifications_->mutex);
        notifications_->unit = nullptr;
        dispatch_source_cancel(notificationTimer_);
        stop();
        SetMutex(nullptr);
    }

    UInt32 SupportedNumChannels(const AUChannelInfo** out) override
    {
        static constexpr AUChannelInfo channels[] = {{2, 2}};
        if (out) {
            *out = channels;
        }
        return 1;
    }

    bool ValidFormat(AudioUnitScope scope, AudioUnitElement bus, const AudioStreamBasicDescription& format) override
    {
        return format.mSampleRate >= 8000 && format.mSampleRate <= 384000
            && AUEffectBase::ValidFormat(scope, bus, format);
    }

    bool CanScheduleParameters() const override { return false; }
    bool ShouldBypassEffect() override { return false; }

    OSStatus Initialize() override
    {
        auto result = AUEffectBase::Initialize();
        if (result != noErr) {
            return result;
        }
        const double rate = GetSampleRate();
        if (rate != GetInput0().GetStreamFormat().mSampleRate) {
            return kAudioUnitErr_FormatNotSupported;
        }
        active_ = prepare(config_, rate);
        if (!active_) {
            return memFullErr;
        }
        for (auto& buffer : scratch_) {
            buffer.resize(GetMaxFramesPerSlice());
        }
        fadeFrames_ = std::max<UInt32>(1, static_cast<UInt32>(rate * 0.005));
        sampleRate_.store(rate);
        notifiedLatency_ = active_->latency / rate;
        notifiedTail_ = active_->tailSeconds;
        latencySeconds_.store(notifiedLatency_);
        tailSeconds_.store(notifiedTail_);
        constexpr uint64_t interval = 20 * NSEC_PER_MSEC;
        dispatch_source_set_timer(notificationTimer_, dispatch_time(DISPATCH_TIME_NOW, interval),
                                  interval, 5 * NSEC_PER_MSEC);
        return noErr;
    }

    void Cleanup() override
    {
        dispatch_source_set_timer(notificationTimer_, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        stop();
        for (auto& buffer : scratch_) {
            std::vector<float>().swap(buffer);
        }
        AUEffectBase::Cleanup();
    }

    OSStatus Reset(AudioUnitScope, AudioUnitElement) override
    {
        reset_.store(true, std::memory_order_relaxed);
        return noErr;
    }

    Float64 GetLatency() override { return latencySeconds_.load(std::memory_order_relaxed); }
    Float64 GetTailTime() override
    {
        return IsInitialized() ? tailSeconds_.load(std::memory_order_relaxed)
                               : ac_tail_time(&config_, GetSampleRate());
    }
    bool SupportsTail() override { return true; }

    OSStatus ProcessBufferLists(AudioUnitRenderActionFlags& flags, const AudioBufferList& input,
                                AudioBufferList& output, UInt32 frames) override
    {
        if (frames == 0) {
            return noErr;
        }
        if (input.mNumberBuffers != 2 || output.mNumberBuffers != 2 || frames > scratch_[0].size()) {
            return kAudioUnitErr_FormatNotSupported;
        }
        if (reset_.exchange(false, std::memory_order_relaxed)) {
            ac_reset(active_->processor);
            if (incoming_) {
                ac_reset(incoming_->processor);
                if (active_->latency == incoming_->latency || position_ < warmFrames_ + fadeFrames_) {
                    position_ = 0;
                }
            }
        }
        if (!incoming_) {
            incoming_ = pending_.exchange(nullptr, std::memory_order_acq_rel);
            if (incoming_) {
                position_ = 0;
                warmFrames_ = std::max<size_t>(fadeFrames_ * 2,
                                               incoming_->latency * 2 + incoming_->alignmentFrames
                                               + incoming_->rangeWarmup);
                tailSeconds_.store(std::max(active_->tailSeconds, incoming_->tailSeconds),
                                   std::memory_order_relaxed);
            }
        }

        const float wet = bypass_.load(std::memory_order_relaxed) ? 0.0f : wet_.load(std::memory_order_relaxed);
        const bool silent = (flags & kAudioUnitRenderAction_OutputIsSilence) != 0;
        const float zero = 0.0f;
        float peak = 0.0f;
        const bool latencyChanges = incoming_ && active_->latency != incoming_->latency;
        for (size_t channel = 0; channel < 2; ++channel) {
            const auto* source = silent ? &zero : static_cast<const float*>(input.mBuffers[channel].mData);
            auto* dest = static_cast<float*>(output.mBuffers[channel].mData);
            const size_t stride = silent ? 0 : 1;
            auto* candidate = scratch_[channel].data();
            if (incoming_) {
                ac_process(incoming_->processor, channel, source, stride, candidate, 1, frames, wet);
            }
            const float oldPeak = ac_process(active_->processor, channel, source, stride, dest, 1, frames, wet);
            if (!incoming_) {
                peak = std::max(peak, oldPeak);
                continue;
            }
            for (size_t i = 0; i < frames; ++i) {
                if (position_ + i >= warmFrames_) {
                    const float step = static_cast<float>(position_ + i - warmFrames_) / fadeFrames_;
                    if (latencyChanges) {
                        dest[i] = step < 1.0f ? dest[i] * (1.0f - step)
                            : candidate[i] * std::min(1.0f, step - 1.0f);
                    } else {
                        dest[i] += std::min(1.0f, step) * (candidate[i] - dest[i]);
                    }
                }
                peak = std::max(peak, std::abs(dest[i]));
            }
        }
        if (incoming_) {
            const size_t handoff = warmFrames_ + fadeFrames_;
            if (latencyChanges && position_ < handoff && position_ + frames >= handoff) {
                latencySeconds_.store(incoming_->latency / sampleRate_.load(std::memory_order_relaxed),
                                      std::memory_order_relaxed);
            }
            position_ += frames;
            if (position_ >= warmFrames_ + fadeFrames_ * (latencyChanges ? 2 : 1)) {
                retire(active_);
                active_ = incoming_;
                incoming_ = nullptr;
                tailSeconds_.store(active_->tailSeconds, std::memory_order_relaxed);
            }
        }
        if (peak == 0.0f) {
            flags |= kAudioUnitRenderAction_OutputIsSilence;
        } else {
            flags &= ~kAudioUnitRenderAction_OutputIsSilence;
            float last = peak_.load(std::memory_order_relaxed);
            while (peak > last && !peak_.compare_exchange_weak(last, peak, std::memory_order_relaxed)) {}
        }
        return noErr;
    }

    OSStatus GetPropertyInfo(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                             UInt32& size, bool& writable) override
    {
        if (scope == kAudioUnitScope_Global && element == 0) {
            switch (property) {
            case ACConfigProperty:
                size = sizeof(ACConfig);
                writable = true;
                return noErr;
            case ACStatusProperty:
                size = sizeof(ACStatus);
                writable = false;
                return noErr;
            case kAudioUnitProperty_CocoaUI:
                size = sizeof(AudioUnitCocoaViewInfo);
                writable = false;
                return noErr;
            }
        }
        return AUEffectBase::GetPropertyInfo(property, scope, element, size, writable);
    }

    OSStatus GetProperty(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                         void* data) override
    {
        if (scope == kAudioUnitScope_Global && element == 0) {
            switch (property) {
            case ACConfigProperty:
                std::memcpy(data, &config_, sizeof(config_));
                return noErr;
            case ACStatusProperty: {
                const ACStatus status{sampleRate_.load(), peak_.exchange(0.0f)};
                std::memcpy(data, &status, sizeof(status));
                return noErr;
            }
            case kAudioUnitProperty_BypassEffect: {
                const UInt32 bypass = bypass_.load() ? 1 : 0;
                std::memcpy(data, &bypass, sizeof(bypass));
                return noErr;
            }
            case kAudioUnitProperty_CocoaUI: {
                @autoreleasepool {
                    Class factory = NSClassFromString(@"CalibrationViewFactory");
                    NSURL* url = factory ? [NSBundle bundleForClass:factory].bundleURL : nil;
                    if (!url) {
                        return kAudioUnitErr_InvalidProperty;
                    }
                    auto* info = static_cast<AudioUnitCocoaViewInfo*>(data);
                    info->mCocoaAUViewBundleLocation = static_cast<CFURLRef>(CFRetain((__bridge CFURLRef)url));
                    info->mCocoaAUViewClass[0] = static_cast<CFStringRef>(CFRetain(CFSTR("CalibrationViewFactory")));
                    return noErr;
                }
            }
            }
        }
        return AUEffectBase::GetProperty(property, scope, element, data);
    }

    OSStatus SetProperty(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                         const void* data, UInt32 size) override
    {
        if (scope == kAudioUnitScope_Global && element == 0) {
            if (property == ACConfigProperty) {
                if (size != sizeof(ACConfig)) {
                    return kAudioUnitErr_InvalidPropertyValue;
                }
                ACConfig config{};
                std::memcpy(&config, data, sizeof(config));
                const auto result = setConfig(config);
                if (result == noErr) {
                    PropertyChanged(kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0);
                }
                return result;
            }
            if (property == kAudioUnitProperty_BypassEffect) {
                if (size != sizeof(UInt32)) {
                    return kAudioUnitErr_InvalidPropertyValue;
                }
                UInt32 bypass = 0;
                std::memcpy(&bypass, data, sizeof(bypass));
                bypass_.store(bypass != 0, std::memory_order_relaxed);
                return noErr;
            }
        }
        return AUEffectBase::SetProperty(property, scope, element, data, size);
    }

    OSStatus SaveState(CFPropertyListRef* out) override
    {
        const auto result = AUEffectBase::SaveState(out);
        if (result != noErr) {
            return result;
        }
        // Keep the v2 config readable by older components.
        CFDataRef data = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&config_), storedConfigSize);
        if (!data) {
            CFRelease(*out);
            *out = nullptr;
            return memFullErr;
        }
        auto dict = static_cast<CFMutableDictionaryRef>(const_cast<void*>(*out));
        CFDictionarySetValue(dict, configKey, data);
        CFRelease(data);
        if (config_.target != ACTargetFlat) {
            const SInt32 target = config_.target;
            CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &target);
            if (!number) {
                CFRelease(*out);
                *out = nullptr;
                return memFullErr;
            }
            CFDictionarySetValue(dict, targetKey, number);
            CFRelease(number);
        }
        if (config_.range_low != 0) {
            const UInt32 bounds[]{config_.range_low, config_.range_high, config_.range_enabled};
            CFDataRef range = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(bounds), sizeof(bounds));
            if (!range) {
                CFRelease(*out);
                *out = nullptr;
                return memFullErr;
            }
            CFDictionarySetValue(dict, rangeKey, range);
            CFRelease(range);
        }
        return noErr;
    }

    OSStatus RestoreState(CFPropertyListRef state) override
    {
        if (!state || CFGetTypeID(state) != CFDictionaryGetTypeID()) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        const auto dict = static_cast<CFDictionaryRef>(state);
        auto data = static_cast<CFDataRef>(CFDictionaryGetValue(dict, configKey));
        ACConfig config = defaultConfig;
        if (data) {
            if (CFGetTypeID(data) != CFDataGetTypeID()) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            const auto size = CFDataGetLength(data);
            if (size != storedConfigSize && size != legacyConfigSize) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            std::memcpy(&config, CFDataGetBytePtr(data), size);
            if (size == legacyConfigSize && config.version == 1) {
                config.version = defaultConfig.version;
            } else if (size != storedConfigSize) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
        }
        if (const auto number = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, targetKey))) {
            SInt32 target = 0;
            if (CFGetTypeID(number) != CFNumberGetTypeID()
                || !CFNumberGetValue(number, kCFNumberSInt32Type, &target)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            config.target = static_cast<UInt32>(target);
        }
        if (const auto range = static_cast<CFDataRef>(CFDictionaryGetValue(dict, rangeKey))) {
            UInt32 bounds[3]{};
            if (CFGetTypeID(range) != CFDataGetTypeID() || CFDataGetLength(range) != sizeof(bounds)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            std::memcpy(bounds, CFDataGetBytePtr(range), sizeof(bounds));
            config.range_low = bounds[0];
            config.range_high = bounds[1];
            config.range_enabled = bounds[2];
        }
        if (!ac_validate(&config)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        const auto result = AUEffectBase::RestoreState(state);
        return result == noErr ? setConfig(config) : result;
    }

private:
    static Prepared* prepare(const ACConfig& config, double rate)
    {
        auto* processor = ac_create(&config, rate);
        return processor ? new Prepared{processor, ac_latency(config.mode, rate),
                                        ac_alignment_frames(&config, rate), ac_range_warmup(&config, rate),
                                        ac_tail_time(&config, rate)}
                         : nullptr;
    }

    OSStatus setConfig(const ACConfig& config)
    {
        if (!ac_validate(&config)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        const bool filtersChanged = config_.target != config.target
            || config_.range_low != config.range_low || config_.range_high != config.range_high
            || config_.range_enabled != config.range_enabled
            || std::memcmp(&config_, &config, legacyConfigSize) != 0;
        config_ = config;
        wet_.store(config.wet, std::memory_order_relaxed);
        if (IsInitialized() && filtersChanged) {
            const double rate = GetSampleRate();
            const auto generation = generation_.fetch_add(1) + 1;
            // A block captures the reference's value only through an explicit by-value copy.
            const ACConfig snapshot = config;
            dispatch_async(worker_, ^{
                collect();
                if (generation != generation_.load()) {
                    return;
                }
                auto* prepared = prepare(snapshot, rate);
                if (generation == generation_.load() && prepared) {
                    delete pending_.exchange(prepared, std::memory_order_acq_rel);
                } else {
                    delete prepared;
                }
            });
        }
        return noErr;
    }

    void notifyProperties()
    {
        const auto notifications = notifications_;
        const double latency = GetLatency();
        if (latency != std::exchange(notifiedLatency_, latency)) {
            PropertyChanged(kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0);
        }
        if (notifications->unit == this && IsInitialized()) {
            const double tail = GetTailTime();
            if (tail != std::exchange(notifiedTail_, tail)) {
                PropertyChanged(kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0);
            }
        }
    }

    void retire(Prepared* prepared)
    {
        auto* head = retired_.load(std::memory_order_relaxed);
        do {
            prepared->next = head;
        } while (!retired_.compare_exchange_weak(head, prepared, std::memory_order_release, std::memory_order_relaxed));
    }

    void collect()
    {
        auto* node = retired_.exchange(nullptr, std::memory_order_acquire);
        while (node) {
            auto* next = node->next;
            delete node;
            node = next;
        }
    }

    void stop()
    {
        generation_.fetch_add(1);
        dispatch_sync(worker_, ^{});
        collect();
        delete pending_.exchange(nullptr);
        delete std::exchange(incoming_, nullptr);
        delete std::exchange(active_, nullptr);
        latencySeconds_.store(0.0);
        reset_.store(false);
    }

    ACConfig config_ = defaultConfig;
    dispatch_queue_t worker_;
    std::shared_ptr<Notifications> notifications_;
    dispatch_source_t notificationTimer_;
    double notifiedLatency_ = 0.0;
    double notifiedTail_ = 0.0;
    std::atomic<uint64_t> generation_{0};
    std::atomic<double> sampleRate_{44100.0};
    std::atomic<double> latencySeconds_{0.0};
    std::atomic<double> tailSeconds_{0.0};
    std::atomic<float> peak_{0.0f};
    std::atomic<float> wet_{defaultConfig.wet};
    std::atomic<bool> bypass_{false};
    std::atomic<bool> reset_{false};
    std::atomic<Prepared*> pending_{nullptr};
    std::atomic<Prepared*> retired_{nullptr};
    Prepared* active_ = nullptr;
    Prepared* incoming_ = nullptr;
    size_t position_ = 0;
    size_t warmFrames_ = 0;
    UInt32 fadeFrames_ = 1;
    std::array<std::vector<float>, 2> scratch_;
};

AUSDK_COMPONENT_ENTRY(ausdk::AUBaseFactory, Calibration)
