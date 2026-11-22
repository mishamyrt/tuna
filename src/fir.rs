use std::ffi::c_void;

const BLOCK: usize = 256;
const SIZE: usize = 2 * BLOCK;
pub const BUFFER_LATENCY: usize = BLOCK;

#[repr(C)]
struct SplitComplex {
    real: *mut f32,
    imag: *mut f32,
}

#[link(name = "Accelerate", kind = "framework")]
unsafe extern "C" {
    fn vDSP_create_fftsetup(log2_size: usize, radix: i32) -> *mut c_void;
    fn vDSP_destroy_fftsetup(setup: *mut c_void);
    fn vDSP_fft_zip(
        setup: *mut c_void,
        data: *mut SplitComplex,
        stride: isize,
        log2_size: usize,
        direction: i32,
    );
    fn vDSP_dotpr(a: *const f32, ia: isize, b: *const f32, ib: isize, sum: *mut f32, n: usize);
}

struct Spectrum {
    real: Vec<f32>,
    imag: Vec<f32>,
}

impl Spectrum {
    fn new(size: usize) -> Self {
        Self {
            real: vec![0.0; size],
            imag: vec![0.0; size],
        }
    }

    fn clear(&mut self) {
        self.real.fill(0.0);
        self.imag.fill(0.0);
    }
}

struct Fft {
    setup: *mut c_void,
    log2_size: usize,
}

impl Fft {
    fn new(size: usize) -> Option<Self> {
        let log2_size = size.ilog2() as usize;
        let setup = unsafe { vDSP_create_fftsetup(log2_size, 0) };
        (!setup.is_null()).then_some(Self { setup, log2_size })
    }

    fn transform(&self, spectrum: &mut Spectrum, inverse: bool) {
        let mut split = SplitComplex {
            real: spectrum.real.as_mut_ptr(),
            imag: spectrum.imag.as_mut_ptr(),
        };
        unsafe {
            vDSP_fft_zip(
                self.setup,
                &mut split,
                1,
                self.log2_size,
                if inverse { -1 } else { 1 },
            )
        };
    }
}

impl Drop for Fft {
    fn drop(&mut self) {
        unsafe { vDSP_destroy_fftsetup(self.setup) };
    }
}

pub fn design(half_length: usize, rate: f64, response: impl Fn(f64) -> f64) -> Option<Vec<f32>> {
    let size = (8 * half_length + 4).next_power_of_two();
    let fft = Fft::new(size)?;
    let mut spectrum = Spectrum::new(size);
    for bin in 0..=size / 2 {
        let magnitude = response(bin as f64 * rate / size as f64) as f32;
        spectrum.real[bin] = magnitude;
        spectrum.real[(size - bin) % size] = magnitude;
    }
    fft.transform(&mut spectrum, true);

    let mut taps = vec![0.0; 2 * half_length + 1];
    for offset in 0..=half_length {
        let taper_position = (5.0 * offset as f64 / half_length as f64 - 4.0).max(0.0);
        let taper = (1.0 + (std::f64::consts::PI * taper_position).cos()) * 0.5;
        let tap = spectrum.real[offset] * (taper as f32 / size as f32);
        taps[half_length + offset] = tap;
        taps[half_length - offset] = tap;
    }
    Some(taps)
}

pub fn centered_response(taps: &[f32], cos: [f64; 4]) -> [f64; 4] {
    let center = taps.len() / 2;
    let (current, previous) = cosine_series(&taps[center + 1..], cos);
    std::array::from_fn(|i| {
        f64::from(taps[center]) + 2.0 * cos[i].mul_add(current[i], -previous[i])
    })
}

pub fn causal_response(taps: &[f32], trig: [(f64, f64); 4]) -> [(f64, f64); 4] {
    let (current, previous) = cosine_series(&taps[1..], trig.map(|(_, cos)| cos));
    std::array::from_fn(|i| {
        let (sin, cos) = trig[i];
        (
            f64::from(taps[0]) + cos.mul_add(current[i], -previous[i]),
            -sin * current[i],
        )
    })
}

fn cosine_series(taps: &[f32], cos: [f64; 4]) -> ([f64; 4], [f64; 4]) {
    let (mut current, mut previous) = ([0.0; 4], [0.0; 4]);
    let twice_cos = cos.map(|v| 2.0 * v);
    // Clenshaw evaluation for both symmetric and causal impulse responses.
    for &tap in taps.iter().rev() {
        let next =
            std::array::from_fn(|i| twice_cos[i].mul_add(current[i], f64::from(tap) - previous[i]));
        previous = current;
        current = next;
    }
    (current, previous)
}

pub fn design_minimum_phase(
    length: usize,
    rate: f64,
    response: impl Fn(f64) -> f64,
) -> Option<Vec<f32>> {
    let size = (8 * length).next_power_of_two();
    let fft = Fft::new(size)?;
    let mut spectrum = Spectrum::new(size);
    for bin in 0..=size / 2 {
        let log_gain = response(bin as f64 * rate / size as f64).max(1e-12).ln() as f32;
        spectrum.real[bin] = log_gain;
        spectrum.real[(size - bin) % size] = log_gain;
    }
    fft.transform(&mut spectrum, true);
    // Fold the real cepstrum onto positive times to obtain a causal minimum-phase response.
    spectrum.real[0] /= size as f32;
    for sample in &mut spectrum.real[1..size / 2] {
        *sample *= 2.0 / size as f32;
    }
    spectrum.real[size / 2] /= size as f32;
    spectrum.real[size / 2 + 1..].fill(0.0);
    spectrum.imag.fill(0.0);
    fft.transform(&mut spectrum, false);
    for (real, imag) in spectrum.real.iter_mut().zip(&mut spectrum.imag) {
        let gain = real.exp();
        let (sin, cos) = imag.sin_cos();
        *real = gain * cos;
        *imag = gain * sin;
    }
    fft.transform(&mut spectrum, true);
    spectrum.real.truncate(length);
    for (i, tap) in spectrum.real.iter_mut().enumerate() {
        let end = (5.0 * i as f64 / (length - 1) as f64 - 4.0).max(0.0);
        *tap *= ((1.0 + (std::f64::consts::PI * end).cos()) / (2.0 * size as f64)) as f32;
    }
    Some(spectrum.real)
}

pub struct CausalConvolver {
    head: [f32; BLOCK],
    history: [f32; 2 * BLOCK],
    position: usize,
    tail: Convolver,
}

impl CausalConvolver {
    pub fn new(taps: &[f32]) -> Option<Self> {
        let head = std::array::from_fn(|i| taps[BLOCK - 1 - i]);
        Some(Self {
            head,
            history: [0.0; 2 * BLOCK],
            position: 0,
            tail: Convolver::new(&taps[BLOCK..])?,
        })
    }

    pub fn process(&mut self, sample: f32) -> f32 {
        let pos = self.position;
        self.history[pos] = sample;
        self.history[pos + BLOCK] = sample;
        let mut head = 0.0;
        unsafe {
            vDSP_dotpr(
                self.history[pos + 1..].as_ptr(),
                1,
                self.head.as_ptr(),
                1,
                &mut head,
                BLOCK,
            )
        };
        self.position = (pos + 1) % BLOCK;
        // The tail's block latency matches the offset of the taps removed into the direct head.
        head + self.tail.process(sample)
    }

    pub fn reset(&mut self) {
        self.history.fill(0.0);
        self.position = 0;
        self.tail.reset();
    }
}

pub struct Convolver {
    fft: Fft,
    filters: Vec<Spectrum>,
    history: Vec<Spectrum>,
    work: Spectrum,
    output: [f32; BLOCK],
    overlap: [f32; BLOCK],
    cursor: usize,
    position: usize,
}

impl Convolver {
    pub fn new(taps: &[f32]) -> Option<Self> {
        let fft = Fft::new(SIZE)?;
        let mut filters = Vec::new();
        for partition in taps.chunks(BLOCK) {
            let mut filter = Spectrum::new(SIZE);
            filter.real[..partition.len()].copy_from_slice(partition);
            fft.transform(&mut filter, false);
            filter.real.truncate(BLOCK + 1);
            filter.imag.truncate(BLOCK + 1);
            filters.push(filter);
        }
        let history = filters.iter().map(|_| Spectrum::new(SIZE)).collect();
        Some(Self {
            fft,
            filters,
            history,
            work: Spectrum::new(SIZE),
            output: [0.0; BLOCK],
            overlap: [0.0; BLOCK],
            cursor: 0,
            position: 0,
        })
    }

    fn finish_block(&mut self) {
        self.fft.transform(&mut self.history[self.cursor], false);
        self.work.clear();
        let partitions = self.filters.len();
        for (index, filter) in self.filters.iter().enumerate() {
            let history = &self.history[(self.cursor + partitions - index) % partitions];
            // Bound each slice once so the complex products can be vectorized.
            let xr = &history.real[..=BLOCK];
            let xi = &history.imag[..=BLOCK];
            let hr = &filter.real[..=BLOCK];
            let hi = &filter.imag[..=BLOCK];
            let real = &mut self.work.real[..=BLOCK];
            let imag = &mut self.work.imag[..=BLOCK];
            for bin in 0..=BLOCK {
                real[bin] += xr[bin] * hr[bin] - xi[bin] * hi[bin];
                imag[bin] += xr[bin] * hi[bin] + xi[bin] * hr[bin];
            }
        }
        for bin in 1..BLOCK {
            self.work.real[SIZE - bin] = self.work.real[bin];
            self.work.imag[SIZE - bin] = -self.work.imag[bin];
        }
        self.fft.transform(&mut self.work, true);
        for index in 0..BLOCK {
            self.output[index] = self.work.real[index] / SIZE as f32 + self.overlap[index];
            self.overlap[index] = self.work.real[BLOCK + index] / SIZE as f32;
        }
        self.cursor = (self.cursor + 1) % partitions;
        self.history[self.cursor].clear();
    }

    pub fn process(&mut self, sample: f32) -> f32 {
        let output = self.output[self.position];
        self.history[self.cursor].real[self.position] = sample;
        self.position += 1;
        if self.position == BLOCK {
            self.finish_block();
            self.position = 0;
        }
        output
    }

    pub fn reset(&mut self) {
        for history in &mut self.history {
            history.clear();
        }
        self.output.fill(0.0);
        self.overlap.fill(0.0);
        self.cursor = 0;
        self.position = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn causal_convolver_has_no_block_latency() {
        let taps: Vec<_> = (0..BLOCK * 3 + 1)
            .map(|i| (i as f32 * 0.031).cos())
            .collect();
        let mut convolver = CausalConvolver::new(&taps).unwrap();
        for (i, expected) in taps.iter().copied().chain([0.0; BLOCK]).enumerate() {
            let rendered = convolver.process(if i == 0 { 1.0 } else { 0.0 });
            assert!((rendered - expected).abs() < 2e-6);
        }
        convolver.reset();
        assert_eq!(convolver.process(1.0), taps[0]);
    }

    #[test]
    fn partitioned_convolution_matches_direct_convolution() {
        let taps: Vec<_> = (0..701)
            .map(|i| ((i as f32 * 0.031).sin()) / 701.0)
            .collect();
        let input: Vec<_> = (0..995).map(|i| (i as f32 * 0.3).cos()).collect();
        let mut convolver = Convolver::new(&taps).unwrap();
        let mut rendered = Vec::new();
        for i in 0..input.len() + taps.len() + BLOCK {
            rendered.push(convolver.process(input.get(i).copied().unwrap_or_default()));
        }
        for (index, &sample) in rendered.iter().enumerate() {
            let expected: f32 = taps
                .iter()
                .enumerate()
                .map(|(tap_index, tap)| {
                    index
                        .checked_sub(BLOCK + tap_index)
                        .and_then(|i| input.get(i))
                        .copied()
                        .unwrap_or_default()
                        * tap
                })
                .sum();
            assert!(
                (sample - expected).abs() < 2e-6,
                "sample {index}: {sample} vs {expected}"
            );
        }
    }
}
