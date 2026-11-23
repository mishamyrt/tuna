mod fir;
mod profile;

use fir::{BUFFER_LATENCY, CausalConvolver, Convolver};
use profile::{Band, Config};
use std::f64::consts::TAU;

#[derive(Clone, Copy)]
struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    state: [f64; 2],
}

impl Biquad {
    fn new(band: Band, rate: f64) -> Self {
        let omega = TAU * (band.frequency as f64).min(rate * 0.49) / rate;
        let (sin, cos) = omega.sin_cos();
        let a = 10.0_f64.powf(band.gain as f64 / 40.0);
        let alpha = sin / (2.0 * band.q as f64);
        let ap = a + 1.0;
        let am = a - 1.0;
        let beta = 2.0 * a.sqrt() * alpha;
        let (b, d) = match band.kind {
            1 => (
                [
                    a * (ap - am * cos + beta),
                    2.0 * a * (am - ap * cos),
                    a * (ap - am * cos - beta),
                ],
                [
                    ap + am * cos + beta,
                    -2.0 * (am + ap * cos),
                    ap + am * cos - beta,
                ],
            ),
            2 => (
                [
                    a * (ap + am * cos + beta),
                    -2.0 * a * (am + ap * cos),
                    a * (ap + am * cos - beta),
                ],
                [
                    ap - am * cos + beta,
                    2.0 * (am - ap * cos),
                    ap - am * cos - beta,
                ],
            ),
            3 | 4 => {
                let sign = if band.kind == 3 { 1.0 } else { -1.0 };
                let half = (1.0 - sign * cos) * 0.5;
                (
                    [half, 2.0 * sign * half, half],
                    [1.0 + alpha, -2.0 * cos, 1.0 - alpha],
                )
            }
            _ => (
                [1.0 + alpha * a, -2.0 * cos, 1.0 - alpha * a],
                [1.0 + alpha / a, -2.0 * cos, 1.0 - alpha / a],
            ),
        };
        Self {
            b: b.map(|v| v / d[0]),
            a: [d[1] / d[0], d[2] / d[0]],
            state: [0.0; 2],
        }
    }

    #[inline]
    fn process(&mut self, input: f64) -> f64 {
        let output = self.b[0].mul_add(input, self.state[0]);
        self.state[0] = self.b[1].mul_add(input, self.state[1] - self.a[0] * output);
        self.state[1] = self.b[2].mul_add(input, -self.a[1] * output);
        output
    }

    fn response_terms(&self, sin: f64, cos: f64) -> (f64, f64, f64, f64) {
        let [b0, b1, b2] = self.b;
        let [a1, a2] = self.a;
        let b_re = b1 + (b0 + b2) * cos;
        let b_im = (b0 - b2) * sin;
        let a_re = a1 + (1.0 + a2) * cos;
        let a_im = (1.0 - a2) * sin;
        (b_re, b_im, a_re, a_im)
    }

    fn magnitude(&self, sin: f64, cos: f64) -> f64 {
        let (b_re, b_im, a_re, a_im) = self.response_terms(sin, cos);
        ((b_re * b_re + b_im * b_im) / (a_re * a_re + a_im * a_im)).sqrt()
    }

    fn phase(&self, sin: f64, cos: f64) -> f64 {
        let (b_re, b_im, a_re, a_im) = self.response_terms(sin, cos);
        b_im.atan2(b_re) - a_im.atan2(a_re)
    }

    fn dominant_pole(&self) -> (f64, f64) {
        let real = -0.5 * self.a[0];
        let discriminant = real * real - self.a[1];
        if discriminant < 0.0 {
            let imag = (-discriminant).sqrt();
            (self.a[1].sqrt(), imag.atan2(real))
        } else {
            (real.abs() + discriminant.sqrt(), 0.0_f64.atan2(real))
        }
    }
}

fn magnitude(filters: &[Biquad], frequency: f64, rate: f64) -> f64 {
    let (sin, cos) = (TAU * frequency / rate).sin_cos();
    filters.iter().map(|f| f.magnitude(sin, cos)).product()
}

fn rate_supported(rate: f64) -> bool {
    (8_000.0..=384_000.0).contains(&rate)
}

fn half_length(mode: u32, rate: f64) -> usize {
    match mode {
        1 => (rate * 0.010).round() as usize,
        2 => (rate * 0.075).round() as usize,
        _ => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_latency(mode: u32, rate: f64) -> usize {
    if mode == 0 || !rate_supported(rate) {
        0
    } else {
        half_length(mode, rate) + BUFFER_LATENCY
    }
}

fn db_to_amp(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}

fn graph_frequency(index: usize, count: usize, rate: f64) -> f64 {
    let upper = 20_000.0_f64.min(rate * 0.49);
    20.0 * (upper / 20.0).powf(index as f64 / (count - 1) as f64)
}

struct LimitedProfile {
    low: f64,
    high: f64,
    fade_octaves: f64,
    filters: Vec<Biquad>,
    trim: f64,
}

impl LimitedProfile {
    fn new(config: &Config, channel: usize, rate: f64) -> Option<Self> {
        if config.range_enabled == 0 || !has_profile_correction(config, channel) {
            return None;
        }
        let low = f64::from(config.range_low);
        let high = f64::from(config.range_high);
        Some(Self {
            low,
            high,
            fade_octaves: (0.5 * (high / low).log2()).min(0.5),
            filters: config
                .profile_bands(channel)
                .map(|band| Biquad::new(band, rate))
                .collect(),
            trim: f64::from(db_to_amp(config.profile[channel].trim)),
        })
    }

    fn magnitude(&self, frequency: f64, rate: f64) -> f64 {
        if frequency <= self.low || frequency >= self.high {
            return 1.0;
        }
        let octaves = (frequency / self.low).min(self.high / frequency).log2();
        let fade = (octaves / self.fade_octaves).min(1.0);
        let weight = 0.5 - 0.5 * (std::f64::consts::PI * fade).cos();
        (self.trim * magnitude(&self.filters, frequency, rate))
            .max(1e-12)
            .powf(weight)
    }
}

fn has_profile_correction(config: &Config, channel: usize) -> bool {
    config.profile[channel].trim != 0.0 || config.profile_bands(channel).next().is_some()
}

fn range_tap_count(rate: f64) -> usize {
    (rate * 0.15).round() as usize
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_headroom(config: &Config, rate: f64) -> f32 {
    if !rate_supported(rate) || config.safe_headroom == 0 {
        return 0.0;
    }
    design_channels(config, rate)
        .and_then(|designs| headroom(&designs, rate))
        .unwrap_or(0.0)
}

fn headroom(designs: &[ChannelDesign; 2], rate: f64) -> Option<f32> {
    let mut peak = 1.0_f64;
    for design in designs {
        peak = peak.max(design.peak_gain(rate)?);
    }
    Some(if peak > 1.0001 {
        -1.0 - 20.0 * peak.log10() as f32
    } else {
        0.0
    })
}

/// # Safety
/// When the arguments pass validation, `points` must point to `count` writable,
/// initialized floats that do not overlap `config`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ac_curve(
    config: &Config,
    rate: f64,
    channel: u32,
    profile_only: bool,
    wet_gain_db: f32,
    points: *mut f32,
    count: usize,
) {
    if count < 2 || channel > 1 || !rate_supported(rate) {
        return;
    }
    let channel = channel as usize;
    let points = unsafe { std::slice::from_raw_parts_mut(points, count) };
    let wet = if profile_only { 1.0 } else { config.wet as f64 };
    if wet == 0.0 {
        points.fill(0.0);
        return;
    }
    let Some(design) = design_channel(config, channel, profile_only, rate) else {
        return;
    };
    let delay = if profile_only {
        0
    } else {
        alignment_delay(config, rate, channel)
    };
    let gain = db_to_amp(design.trim + wet_gain_db) as f64;
    for (chunk, points) in points.chunks_mut(4).enumerate() {
        let omega: [f64; 4] =
            std::array::from_fn(|i| TAU * graph_frequency(chunk * 4 + i, count, rate) / rate);
        let trig = omega.map(f64::sin_cos);
        let linear = design.linear.as_ref().map_or([1.0; 4], |taps| {
            fir::centered_response(taps, trig.map(|(_, cos)| cos))
        });
        let causal = design
            .causal
            .as_ref()
            .map_or([(1.0, 0.0); 4], |taps| fir::causal_response(taps, trig));
        for (i, point) in points.iter_mut().enumerate() {
            let (sin, cos) = trig[i];
            let iir_gain = design
                .iir
                .iter()
                .map(|filter| filter.magnitude(sin, cos))
                .product::<f64>();
            let (range_real, range_imag) = causal[i];
            let amplitude = gain * iir_gain * linear[i] * range_real.hypot(range_imag);
            let blended = if wet == 1.0 {
                amplitude.abs()
            } else {
                // The FIR's common latency is also on the dry path.
                let phase = design.iir.iter().map(|f| f.phase(sin, cos)).sum::<f64>()
                    + range_imag.atan2(range_real)
                    - omega[i] * delay as f64;
                let (sin, cos) = phase.sin_cos();
                (1.0 - wet + wet * amplitude * cos).hypot(wet * amplitude * sin)
            };
            *point = 20.0 * blended.max(1e-6).log10() as f32;
        }
    }
}

struct Delay {
    buffer: Vec<f32>,
    cursor: usize,
}

impl Delay {
    fn new(samples: usize) -> Self {
        Self {
            buffer: vec![0.0; samples],
            cursor: 0,
        }
    }

    #[inline]
    fn process(&mut self, sample: f32) -> f32 {
        if self.buffer.is_empty() {
            return sample;
        }
        let output = std::mem::replace(&mut self.buffer[self.cursor], sample);
        self.cursor += 1;
        if self.cursor == self.buffer.len() {
            self.cursor = 0;
        }
        output
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.cursor = 0;
    }
}

struct Channel {
    iir: Vec<Biquad>,
    fir: Option<Convolver>,
    range: Option<CausalConvolver>,
    dry_delay: Delay,
    flat_wet_delay: Delay,
    alignment: Delay,
    gain: f32,
    wet_mix: f32,
    ramp_step: f32,
}

fn uses_iir(mode: u32, band: &Band) -> bool {
    mode == 0 || (mode == 1 && (band.frequency < 500.0 || band.frequency / band.q < 150.0))
}

fn alignment_delay(config: &Config, rate: f64, channel: usize) -> usize {
    if config.alignment == 0 {
        0
    } else {
        (f64::from(config.profile[channel].delay_ms) * rate / 1000.0).round() as usize
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_alignment_frames(config: &Config, rate: f64) -> usize {
    alignment_delay(config, rate, 0).max(alignment_delay(config, rate, 1))
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_range_warmup(config: &Config, rate: f64) -> usize {
    if rate_supported(rate)
        && config.range_enabled != 0
        && config.mode < 2
        && (0..2).any(|channel| has_profile_correction(config, channel))
    {
        range_tap_count(rate) - 1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_tail_time(config: &Config, rate: f64) -> f64 {
    if !rate_supported(rate) {
        return 0.0;
    }
    let mut longest: f64 = 0.0;
    for channel in 0..2 {
        let mut frames =
            (ac_latency(config.mode, rate) + alignment_delay(config, rate, channel)) as f64;
        let limited = config.range_enabled != 0 && has_profile_correction(config, channel);
        let mut has_fir = limited && config.mode == 2;
        if limited && config.mode < 2 {
            frames += (range_tap_count(rate) - 1) as f64;
        }
        let bands = config.bands(channel, !limited, true);
        for band in bands {
            if uses_iir(config.mode, &band) {
                let (radius, _) = Biquad::new(band, rate).dominant_pole();
                // Add each section's 120 dB pole decay time to cover a cascade.
                frames += (1e-6_f64.ln() / radius.ln()).ceil();
            } else {
                has_fir = true;
            }
        }
        if has_fir {
            frames += half_length(config.mode, rate) as f64;
        }
        longest = longest.max(frames);
    }
    longest / rate
}

struct ChannelDesign {
    iir: Vec<Biquad>,
    linear: Option<Vec<f32>>,
    causal: Option<Vec<f32>>,
    trim: f32,
}

impl ChannelDesign {
    fn peak_gain(&self, rate: f64) -> Option<f64> {
        let gains = fir::cascade_magnitudes([self.linear.as_deref(), self.causal.as_deref()])?;
        let trim = f64::from(db_to_amp(self.trim));
        if self.iir.is_empty() {
            return Some(trim * gains.into_iter().reduce(f64::max).unwrap_or(1.0));
        }
        let nyquist = rate * 0.5;
        let mut peak = 0.0_f64;
        let mut measure = |frequency, fir_gain| {
            peak = peak.max(magnitude(&self.iir, frequency, rate) * fir_gain);
        };
        if gains.is_empty() {
            let ratio = nyquist.powf(1.0 / 1023.0);
            measure(0.0, 1.0);
            for i in 0..=1023 {
                measure(ratio.powi(i), 1.0);
            }
        } else {
            for (bin, &gain) in gains.iter().enumerate() {
                measure(nyquist * bin as f64 / (gains.len() - 1) as f64, gain);
            }
        }
        // A narrow IIR resonance can fall between even oversampled FFT bins.
        for filter in &self.iir {
            let (radius, angle) = filter.dominant_pole();
            for step in -32..=32 {
                let omega = angle + f64::from(step) * (1.0 - radius) / 8.0;
                let frequency = (omega * rate / TAU).clamp(0.0, nyquist);
                let gain = if gains.is_empty() {
                    1.0
                } else {
                    let bin = frequency / nyquist * (gains.len() - 1) as f64;
                    gains[bin.floor() as usize].max(gains[bin.ceil() as usize])
                };
                measure(frequency, gain);
            }
        }
        Some(trim * peak)
    }
}

fn design_channels(config: &Config, rate: f64) -> Option<[ChannelDesign; 2]> {
    Some([
        design_channel(config, 0, false, rate)?,
        design_channel(config, 1, false, rate)?,
    ])
}

fn design_channel(
    config: &Config,
    channel: usize,
    profile_only: bool,
    rate: f64,
) -> Option<ChannelDesign> {
    let limited = LimitedProfile::new(config, channel, rate);
    let mode = if profile_only && limited.is_none() {
        0
    } else {
        config.mode
    };
    let bands = config.bands(channel, limited.is_none(), !profile_only);
    let (mut iir, mut linear) = (Vec::new(), Vec::new());
    for band in bands {
        let filters = if uses_iir(mode, &band) {
            &mut iir
        } else {
            &mut linear
        };
        filters.push(Biquad::new(band, rate));
    }
    let linear_range = limited.as_ref().filter(|_| mode == 2);
    let linear = if linear.is_empty() && linear_range.is_none() {
        None
    } else {
        Some(fir::design(half_length(mode, rate), rate, |f| {
            magnitude(&linear, f, rate)
                * linear_range.map_or(1.0, |profile| profile.magnitude(f, rate))
        })?)
    };
    let causal = match limited.as_ref().filter(|_| mode < 2) {
        Some(profile) => Some(fir::design_minimum_phase(
            range_tap_count(rate),
            rate,
            |f| profile.magnitude(f, rate),
        )?),
        None => None,
    };
    let trim = if limited.is_some() {
        0.0
    } else {
        config.profile[channel].trim
    };
    Some(ChannelDesign {
        iir,
        linear,
        causal,
        trim,
    })
}

impl Channel {
    #[cfg(test)]
    fn new(config: &Config, rate: f64, channel: usize, headroom: f32) -> Option<Self> {
        Self::from_design(
            design_channel(config, channel, false, rate)?,
            config,
            rate,
            channel,
            headroom,
        )
    }

    fn from_design(
        design: ChannelDesign,
        config: &Config,
        rate: f64,
        channel: usize,
        headroom: f32,
    ) -> Option<Self> {
        let latency = ac_latency(config.mode, rate);
        let fir = match design.linear {
            Some(taps) => Some(Convolver::new(&taps)?),
            None => None,
        };
        let range = match design.causal {
            Some(taps) => Some(CausalConvolver::new(&taps)?),
            None => None,
        };
        let flat_wet_delay = Delay::new(if fir.is_some() { 0 } else { latency });
        let delay = alignment_delay(config, rate, channel);
        Some(Self {
            iir: design.iir,
            fir,
            range,
            dry_delay: Delay::new(latency),
            flat_wet_delay,
            alignment: Delay::new(delay),
            gain: db_to_amp(design.trim + headroom),
            wet_mix: config.wet,
            ramp_step: (200.0 / rate) as f32,
        })
    }

    #[inline]
    fn process(&mut self, input: f32, target_wet: f32) -> f32 {
        let dry = self.dry_delay.process(input);
        let mut wet = input as f64;
        for filter in &mut self.iir {
            wet = filter.process(wet);
        }
        let wet = wet as f32;
        let wet = match &mut self.range {
            Some(range) => range.process(wet),
            None => wet,
        };
        let wet = match &mut self.fir {
            Some(fir) => fir.process(wet),
            None => self.flat_wet_delay.process(wet),
        };
        let wet = self.alignment.process(wet) * self.gain;
        self.wet_mix = if target_wet < self.wet_mix {
            (self.wet_mix - self.ramp_step).max(target_wet)
        } else {
            (self.wet_mix + self.ramp_step).min(target_wet)
        };
        match self.wet_mix {
            0.0 => dry,
            1.0 => wet,
            mix => dry + mix * (wet - dry),
        }
    }

    fn reset(&mut self) {
        for filter in &mut self.iir {
            filter.state = [0.0; 2];
        }
        if let Some(fir) = &mut self.fir {
            fir.reset();
        }
        if let Some(range) = &mut self.range {
            range.reset();
        }
        self.dry_delay.reset();
        self.flat_wet_delay.reset();
        self.alignment.reset();
    }
}

pub struct Processor([Channel; 2]);

#[unsafe(no_mangle)]
pub extern "C" fn ac_begin_transition(active: &Processor, incoming: &mut Processor) {
    for (old, new) in active.0.iter().zip(&mut incoming.0) {
        new.wet_mix = old.wet_mix;
        // IIR is first in the signal path. After the first changed section,
        // downstream sections no longer have the same input history.
        for (from, to) in old.iir.iter().zip(&mut new.iir) {
            if from.a != to.a || from.b != to.b {
                break;
            }
            to.state = from.state;
        }
    }
}

impl Processor {
    fn new(config: &Config, rate: f64) -> Option<Self> {
        if !config.valid() || !rate_supported(rate) {
            return None;
        }
        let designs = design_channels(config, rate)?;
        let gain = if config.safe_headroom != 0 {
            headroom(&designs, rate)?
        } else {
            0.0
        };
        let [left, right] = designs;
        Some(Self([
            Channel::from_design(left, config, rate, 0, gain)?,
            Channel::from_design(right, config, rate, 1, gain)?,
        ]))
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_create(config: &Config, rate: f64) -> *mut Processor {
    Processor::new(config, rate).map_or(std::ptr::null_mut(), |processor| {
        Box::into_raw(Box::new(processor))
    })
}

/// # Safety
/// A non-null pointer must come from `ac_create` and must no longer be in use.
/// Each such pointer may be destroyed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ac_destroy(processor: *mut Processor) {
    if !processor.is_null() {
        drop(unsafe { Box::from_raw(processor) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_reset(processor: &mut Processor) {
    for channel in &mut processor.0 {
        channel.reset();
    }
}

/// # Safety
/// The strided pointers must be valid for reads and writes respectively for
/// all `frames` samples, with offsets that fit in their allocations.
/// The buffers must not overlap the processor state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ac_process(
    processor: &mut Processor,
    channel: usize,
    input: *const f32,
    input_stride: usize,
    output: *mut f32,
    output_stride: usize,
    frames: usize,
    wet: f32,
) -> f32 {
    let channel = &mut processor.0[channel];
    let mut peak = 0.0_f32;
    for frame in 0..frames {
        let sample = unsafe { *input.add(frame * input_stride) };
        let value = channel.process(if sample.is_finite() { sample } else { 0.0 }, wet);
        unsafe { *output.add(frame * output_stride) = value };
        peak = peak.max(value.abs());
    }
    peak
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alignment_preserves_impulses_and_matches_the_wet_mix_curve() {
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.version = 2;
        config.alignment = 1;
        config.profile[0].delay_ms = 1.01;
        config.profile[1].delay_ms = 0.49;
        for (rate, expected_frames) in [(48_000.0, [48, 24]), (44_100.0, [45, 22])] {
            for (channel, delay) in expected_frames.into_iter().enumerate() {
                for wet in [1.0, 0.25] {
                    config.wet = wet;
                    let mut dsp = Channel::new(&config, rate, channel, 0.0).unwrap();
                    for frame in 0..=2 * delay {
                        let sample = dsp.process(if frame == 0 { 1.0 } else { 0.0 }, wet);
                        let expected = if frame == 0 {
                            1.0 - wet
                        } else if frame == delay {
                            wet
                        } else {
                            0.0
                        };
                        assert_eq!(
                            sample, expected,
                            "{rate} Hz, channel {channel}, frame {frame}"
                        );
                    }
                    let mut curve = [0.0; 32];
                    unsafe {
                        ac_curve(
                            &config,
                            rate,
                            channel as u32,
                            false,
                            0.0,
                            curve.as_mut_ptr(),
                            curve.len(),
                        )
                    };
                    for (i, db) in curve.iter().enumerate() {
                        let phase =
                            TAU * graph_frequency(i, curve.len(), rate) * delay as f64 / rate;
                        let mix = f64::from(wet);
                        let amplitude = (1.0 - mix + mix * phase.cos()).hypot(mix * phase.sin());
                        assert!((f64::from(*db) - 20.0 * amplitude.log10()).abs() < 1e-5);
                    }
                }
            }
            assert_eq!(ac_alignment_frames(&config, rate), expected_frames[0]);
            assert_eq!(
                ac_tail_time(&config, rate),
                expected_frames[0] as f64 / rate
            );
        }
    }

    #[test]
    fn targets_shape_both_channels_and_leave_profile_reference_flat() {
        let rate = 48_000.0;
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.version = 2;
        config.wet = 1.0;
        let gain = |config: &Config, channel, profile_only: bool, frequency| {
            let filters: Vec<_> = config
                .bands(channel, true, !profile_only)
                .map(|band| Biquad::new(band, rate))
                .collect();
            20.0 * magnitude(&filters, frequency, rate).log10()
        };
        assert_eq!(gain(&config, 0, false, 20.0), 0.0);
        config.target = 1;
        for channel in 0..2 {
            assert!(gain(&config, channel, false, 20.0) > 6.5);
            assert!(gain(&config, channel, false, 12_000.0) < -2.3);
            assert_eq!(gain(&config, channel, true, 20.0), 0.0);
        }
        config.safe_headroom = 1;
        assert!(ac_headroom(&config, rate) < -7.5);
        config.target = 2;
        assert!(gain(&config, 0, false, 20.0) < -1.9);
        assert!(gain(&config, 1, false, 1600.0) > 2.9);
        config.target = 3;
        assert!(!config.valid());
    }

    #[test]
    fn calibration_range_fades_the_profile_and_preserves_full_band_eq() {
        let rate = 48_000.0;
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.version = 2;
        config.wet = 1.0;
        config.range_low = 200;
        config.range_high = 5_000;
        config.range_enabled = 1;
        config.profile[0].trim = 6.0;
        config.target = 1;
        config.user[0] = Band {
            frequency: 10_000.0,
            gain: -3.0,
            q: 0.8,
            kind: 0,
            channels: 1,
        };
        assert!(config.valid());
        let render = |config: &Config| {
            let mut channel = Channel::new(config, rate, 0, 0.0).unwrap();
            (0..(rate / 2.0) as usize)
                .map(|i| channel.process(if i == 0 { 1.0 } else { 0.0 }, config.wet))
                .collect::<Vec<_>>()
        };
        let response = |samples: &[f32], frequency: f64| {
            let (real, imag) =
                samples
                    .iter()
                    .enumerate()
                    .fold((0.0_f64, 0.0_f64), |(re, im), (i, sample)| {
                        let (sin, cos) = (TAU * frequency * i as f64 / rate).sin_cos();
                        (re + f64::from(*sample) * cos, im + f64::from(*sample) * sin)
                    });
            20.0 * real.hypot(imag).log10()
        };
        for mode in 0..=2 {
            config.mode = mode;
            config.wet = 1.0;
            let mut overlay = config;
            overlay.profile[0].trim = 0.0;
            let samples = render(&config);
            let outside = render(&overlay);
            let calibration = |f| response(&samples, f) - response(&outside, f);
            for f in [60.0, 150.0, 6_000.0, 10_000.0] {
                assert!(
                    calibration(f).abs() < 0.1,
                    "mode {mode}, {f} Hz: {}",
                    calibration(f)
                );
            }
            assert!((calibration(1_000.0) - 6.0).abs() < 0.1);
            for f in [200.0 * 2.0_f64.powf(0.25), 5_000.0 / 2.0_f64.powf(0.25)] {
                assert!(
                    (calibration(f) - 3.0).abs() < 0.15,
                    "mode {mode}, {f} Hz: {}",
                    calibration(f)
                );
            }
            config.wet = 0.4;
            let samples = render(&config);
            let mut curve = [0.0; 31];
            unsafe {
                ac_curve(
                    &config,
                    rate,
                    0,
                    false,
                    0.0,
                    curve.as_mut_ptr(),
                    curve.len(),
                )
            };
            for (i, point) in curve.iter().enumerate() {
                let measured = response(&samples, graph_frequency(i, curve.len(), rate));
                assert!((measured - f64::from(*point)).abs() < 0.005);
            }
        }
        config.range_low = 5_000;
        assert!(!config.valid());
    }

    #[test]
    fn mixed_headroom_covers_the_rendered_filter_pair() {
        let rate = 48_000.0;
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.version = 2;
        config.mode = 1;
        config.safe_headroom = 1;
        config.wet = 1.0;
        let boost = Band {
            frequency: 500.0,
            gain: 24.0,
            q: 3.34,
            kind: 0,
            channels: 3,
        };
        config.user[0] = boost;
        config.user[1] = Band {
            gain: -24.0,
            q: 3.33,
            ..boost
        };
        let mut processor = Processor::new(&config, rate).unwrap();
        let peak = (0..48_000)
            .map(|frame| {
                let input = (TAU * 500.0 * f64::from(frame) / rate).sin() as f32;
                processor.0[0].process(input, 1.0).abs()
            })
            .skip(24_000)
            .fold(0.0_f32, f32::max);
        assert!((0.85..=0.90).contains(&peak), "rendered peak: {peak}");
    }

    #[test]
    fn headroom_covers_resonance_above_graph() {
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.safe_headroom = 1;
        config.user[0] = Band {
            frequency: 20_000.0,
            gain: 12.0,
            q: 20.0,
            kind: 2,
            channels: 3,
        };
        let rate = 48_000.0;
        let headroom = db_to_amp(ac_headroom(&config, rate)) as f64;
        let filter = Biquad::new(config.user[0], rate);
        let peak = (20_000..=24_000)
            .map(|f| headroom * magnitude(&[filter], f as f64, rate))
            .fold(0.0, f64::max);
        assert!(peak < 0.91, "peak: {peak}");
    }

    #[test]
    fn curve_matches_rendered_narrow_linear_phase_band() {
        let rate = 48_000.0;
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.mode = 2;
        config.safe_headroom = 1;
        config.user[0] = Band {
            frequency: 20.0,
            gain: 24.0,
            q: 20.0,
            kind: 0,
            channels: 1,
        };
        let headroom = ac_headroom(&config, rate);
        for wet in [1.0, 0.5] {
            config.wet = wet;
            let mut curve = [0.0; 2];
            unsafe {
                ac_curve(
                    &config,
                    rate,
                    0,
                    false,
                    headroom,
                    curve.as_mut_ptr(),
                    curve.len(),
                )
            };
            let mut channel = Channel::new(&config, rate, 0, headroom).unwrap();
            let mut sum = (0.0_f64, 0.0_f64);
            for i in 0..2 * ac_latency(config.mode, rate) + 1 {
                let sample = channel.process(if i == 0 { 1.0 } else { 0.0 }, wet) as f64;
                let (sin, cos) = (TAU * 20.0 * i as f64 / rate).sin_cos();
                sum.0 += sample * cos;
                sum.1 += sample * sin;
            }
            let measured = 20.0 * sum.0.hypot(sum.1).log10();
            assert!((measured - f64::from(curve[0])).abs() < 0.01);
        }
    }

    #[test]
    fn reported_tail_covers_narrow_iir_band() {
        let rate = 48_000.0;
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.wet = 1.0;
        config.safe_headroom = 1;
        config.user[0] = Band {
            frequency: 20.0,
            gain: 24.0,
            q: 20.0,
            kind: 0,
            channels: 1,
        };
        let mut channel = Channel::new(&config, rate, 0, ac_headroom(&config, rate)).unwrap();
        for frame in 0..(8.0 * rate) as usize {
            channel.process((TAU * 20.0 * frame as f64 / rate).sin() as f32, 1.0);
        }
        let tail = ac_tail_time(&config, rate);
        for _ in 0..(tail * rate) as usize {
            channel.process(0.0, 1.0);
        }
        let peak = (0..2400)
            .map(|_| channel.process(0.0, 1.0).abs())
            .fold(0.0, f32::max);
        assert!(peak < 1e-5, "tail peak: {peak}");
    }

    #[test]
    fn mode_latency_and_stereo_isolation() {
        let mut config: Config = unsafe { std::mem::zeroed() };
        config.version = 2;
        config.wet = 1.0;
        config.user[0] = Band {
            frequency: 1000.0,
            gain: -8.0,
            q: 1.0,
            kind: 0,
            channels: 1,
        };
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for mode in 0..=2 {
                config.mode = mode;
                let latency = ac_latency(mode, rate);
                let mut right = Channel::new(&config, rate, 1, 0.0).unwrap();
                let mut left = Channel::new(&config, rate, 0, 0.0).unwrap();
                let left_impulse: Vec<_> = (0..2 * latency + 2048)
                    .map(|i| {
                        let input = if i == 0 { 1.0 } else { 0.0 };
                        assert_eq!(
                            right.process(input, 1.0),
                            if i == latency { 1.0 } else { 0.0 }
                        );
                        left.process(input, 1.0)
                    })
                    .collect();
                let angle = TAU * 1000.0 / rate;
                let (mut real, mut imag) = (0.0, 0.0);
                for (i, &sample) in left_impulse.iter().enumerate() {
                    let (sin, cos) = (i as f64 * angle).sin_cos();
                    real += sample as f64 * cos;
                    imag += sample as f64 * sin;
                }
                assert!((20.0 * real.hypot(imag).log10() + 8.0).abs() < 0.15);
                if mode > 0 {
                    for offset in 1..=latency {
                        assert!(
                            (left_impulse[latency + offset] - left_impulse[latency - offset]).abs()
                                < 1e-6
                        );
                    }
                }
            }
        }
    }
}
