use std::ffi::{CStr, c_char};

pub const PROFILE_BANDS: usize = 9;
pub const USER_BANDS: usize = 8;
const NAME_BYTES: usize = 256;

const fn target_band(frequency: f32, gain: f32, q: f32, kind: u32) -> Band {
    Band {
        frequency,
        gain,
        q,
        kind,
        channels: 3,
    }
}

const TARGET_BANDS: [&[Band]; 3] = [
    &[],
    &[
        target_band(105.0, 6.6, std::f32::consts::FRAC_1_SQRT_2, 1),
        target_band(2_500.0, -2.4, std::f32::consts::FRAC_1_SQRT_2, 2),
    ],
    &[
        target_band(100.0, -2.0, std::f32::consts::FRAC_1_SQRT_2, 1),
        target_band(1_600.0, 3.0, 0.8, 0),
    ],
];

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Band {
    pub frequency: f32,
    pub gain: f32,
    pub q: f32,
    pub kind: u32,
    pub channels: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Channel {
    pub bands: [Band; PROFILE_BANDS],
    pub trim: f32,
    pub delay_ms: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Config {
    pub version: u32,
    pub mode: u32,
    pub alignment: u32,
    pub safe_headroom: u32,
    pub profile: [Channel; 2],
    pub user: [Band; USER_BANDS],
    pub name: [u8; NAME_BYTES],
    pub wet: f32,
    pub target: u32,
    pub range_low: u32,
    pub range_high: u32,
    pub range_enabled: u32,
}

impl Config {
    pub fn valid(&self) -> bool {
        self.version == 2
            && self.mode <= 2
            && self.alignment <= 1
            && self.safe_headroom <= 1
            && (self.target as usize) < TARGET_BANDS.len()
            && self.range_enabled <= 1
            && ((self.range_enabled == 0 && self.range_low == 0 && self.range_high == 0)
                || (self.range_low >= 20
                    && self.range_low < self.range_high
                    && self.range_high <= 20_000))
            && (0.0..=1.0).contains(&self.wet)
            && self.name.contains(&0)
            && self.profile.iter().all(|channel| {
                (-36.0..=24.0).contains(&channel.trim)
                    && (0.0..=42.0).contains(&channel.delay_ms)
                    && channel.bands.iter().all(|band| band.valid(4))
            })
            && self.user.iter().all(|band| band.valid(2))
    }

    pub fn bands(
        &self,
        channel: usize,
        profile: bool,
        overlay: bool,
    ) -> impl Iterator<Item = Band> + '_ {
        self.profile_bands(channel)
            .filter(move |_| profile)
            .chain(self.overlay_bands(channel).filter(move |_| overlay))
    }

    pub fn profile_bands(&self, channel: usize) -> impl Iterator<Item = Band> + '_ {
        self.profile[channel]
            .bands
            .iter()
            .copied()
            .filter(move |band| band.active_on(channel))
    }

    fn overlay_bands(&self, channel: usize) -> impl Iterator<Item = Band> + '_ {
        self.user
            .iter()
            .chain(
                TARGET_BANDS
                    .get(self.target as usize)
                    .copied()
                    .unwrap_or_default(),
            )
            .copied()
            .filter(move |band| band.active_on(channel))
    }
}

impl Band {
    fn active_on(&self, channel: usize) -> bool {
        (self.channels & (1 << channel)) != 0 && (self.gain != 0.0 || self.kind >= 3)
    }

    fn valid(&self, max_kind: u32) -> bool {
        self.frequency.is_finite()
            && self.gain.is_finite()
            && self.q.is_finite()
            && self.kind <= max_kind
            && self.channels <= 3
            && (self.channels == 0
                || ((10.0..=24_000.0).contains(&self.frequency)
                    && (-30.0..=30.0).contains(&self.gain)
                    && (0.1..=30.0).contains(&self.q)))
    }
}

fn read_channel(preset: &str, tag: &str, mask: u32) -> Option<Channel> {
    let (_, remainder) = preset.split_once(&format!("<{tag}>"))?;
    let (section, rest) = remainder.split_once(&format!("</{tag}>"))?;
    if rest.contains(&format!("<{tag}>")) {
        return None;
    }
    let mut values = section
        .trim()
        .strip_prefix("<Params>")?
        .trim_end()
        .strip_suffix("</Params>")?;
    let mut channel = Channel::default();
    let mut fields = [[None; 4]; PROFILE_BANDS];
    let mut trim = None;
    let mut delay = None;
    while !values.trim().is_empty() {
        values = values.trim_start().strip_prefix("<val e=\"")?;
        let (key, rest) = values.split_once("\" v=\"")?;
        let (number, rest) = rest.split_once("\"/>")?;
        values = rest;
        let value: f32 = number
            .trim()
            .strip_suffix(',')
            .unwrap_or(number.trim())
            .parse()
            .ok()?;
        if !value.is_finite() {
            return None;
        }
        let slot = match key {
            "REQ Delay" => &mut delay,
            "Chan Gain" => &mut trim,
            _ => {
                let band = key.strip_prefix("REQ Band")?;
                let (index, field) = band.split_at_checked(1)?;
                let index = index.parse::<usize>().ok()?.checked_sub(1)?;
                let field = match field.trim() {
                    "Freq" => 0,
                    "Gain" => 1,
                    "Q" => 2,
                    "Type" => 3,
                    _ => return None,
                };
                &mut fields.get_mut(index)?[field]
            }
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    channel.trim = trim.unwrap_or(0.0);
    channel.delay_ms = delay.unwrap_or(0.0);
    for (index, ([frequency, gain, q, kind], band)) in
        fields.into_iter().zip(&mut channel.bands).enumerate()
    {
        let kind = match kind.unwrap_or(0.0) {
            0.0 => 0,
            1.0 if index == 0 => 1,
            1.0 if index >= 7 => 2,
            2.0 => 3,
            3.0 => 4,
            _ => return None,
        };
        *band = Band {
            frequency: frequency?,
            gain: gain?,
            q: q?,
            kind,
            channels: mask,
        };
    }
    Some(channel)
}

fn read_profile(text: &str) -> Option<[Channel; 2]> {
    let preset = text
        .trim_start_matches('\u{feff}')
        .trim()
        .strip_prefix("<Preset>")?
        .strip_suffix("</Preset>")?;
    Some([
        read_channel(preset, "Room EQ L", 1)?,
        read_channel(preset, "Room EQ R", 2)?,
    ])
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_validate(config: &Config) -> bool {
    config.valid()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ac_import(
    bytes: *const u8,
    size: usize,
    name: *const c_char,
    config: &mut Config,
) -> bool {
    if bytes.is_null() || size > 64 * 1024 {
        return false;
    }
    let bytes = unsafe { std::slice::from_raw_parts(bytes, size) };
    let Some(profile) = std::str::from_utf8(bytes).ok().and_then(read_profile) else {
        return false;
    };
    let mut candidate = *config;
    candidate.profile = profile;
    candidate.name.fill(0);
    let name = if name.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(name) }.to_str().ok()
    };
    if let Some(name) = name {
        let mut length = name.len().min(NAME_BYTES - 1);
        while !name.is_char_boundary(length) {
            length -= 1;
        }
        candidate.name[..length].copy_from_slice(&name.as_bytes()[..length]);
    }
    if !candidate.valid() {
        return false;
    }
    *config = candidate;
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_user_band(config: &Config, index: usize) -> Band {
    config.user.get(index).copied().unwrap_or_default()
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_set_user_band(config: &mut Config, index: usize, band: Band) {
    if let Some(slot) = config.user.get_mut(index) {
        *slot = band;
    }
}
