# Contributing to Tuna

## Build from source

You need Xcode and a Rust toolchain that supports your Mac's architecture. Run `make` to download the pinned version of Apple's AudioUnitSDK and build a signed component at `build/Tuna.component`.

```sh
make
make install
auval -v aufx ACal Myrt
```

`make install` builds and installs Tuna in your user Audio Units folder. When you update Tuna, the command replaces the previous component. Tuna uses the same AU identifier as Audio Calibration, so existing presets are compatible.

The release uses a self-signed certificate. If you installed Tuna or Audio Calibration manually, run `make uninstall` from the repository root before switching to Homebrew.

## Audio processing

The manual EQ supports up to eight bands. Each band can affect the left channel, the right channel, or both. The AU state includes the profile and your manual adjustments.

**Time alignment** rounds each channel’s exported delay to the nearest sample at the current sample rate. This preserves the channel’s frequency response at 100% wet, with a timing error of at most half a sample (10.4 µs at 48 kHz). **Safe headroom** lowers the overall level to compensate for frequency boosts.

The **Target Curve** menu adds frequency shaping to both channels on top of the SoundID profile and manual EQ. The curve appears in the combined frequency response, is factored into **Safe headroom**, and is saved in the AU preset.

- **Flat** preserves the original correction. This is the default for new and older presets.
- **Harman** adds shelving filters of +6.6 dB at 105 Hz and −2.4 dB at 2.5 kHz, inspired by research on listener preferences for loudspeaker response. [Study by Olive, Welti, and McMullin](https://aes.org/publications/elibrary/elibrary-page/?id=17042)
- **Marshall-style** emphasizes the upper midrange. This custom preset applies a −2 dB low shelf at 100 Hz and a +3 dB boost at 1.6 kHz.

**Limit Calibration Range** restricts the imported profile's frequency correction, including its per-channel gain, to a selected range. For example, with a range of 200–5,000 Hz, the correction ramps up above 200 Hz and tapers off below 5,000 Hz. The transition spans up to half an octave at each end. Target Curve and manual EQ apply across the full frequency spectrum. Time alignment and Safe headroom continue to control channel delays and overall headroom. The range limits are saved in the AU preset.

| Mode | Latency at 48 kHz |
| --- | ---: |
| Zero Latency | 0 ms |
| Mixed | 15.33 ms |
| Linear Phase | 80.33 ms |

These values are for the filter. Time alignment, the output device, and SoundSource add their own latency.

## Testing

```sh
make test
make lint
make test-au
```

`make test` runs the Rust tests. `make test-au` builds Tuna and loads that binary directly, measures the response and latency of all three modes at 44.1, 48, and 96 kHz, and checks that a new instance restores the saved state. It uses a synthetic stereo profile by default. Pass `PROFILE=/path/to/asymmetric-stereo.tmreq` to check another export.

`make lint` checks Rust formatting and runs Clippy. GitHub Actions runs the build, Rust tests, and lint checks on pushes and pull requests.

## Releasing

Set the repository secrets `P12_CERTIFICATE_BASE64`, `P12_CERTIFICATE_PASSWORD`, and `P12_CERTIFICATE_NAME` with the base64-encoded signing identity, its PKCS#12 password, and the certificate name. Set `HOMEBREW_TAP_TOKEN` to a token with write access to the contents of `mishamyrt/homebrew-tap`.

Set `VERSION` in the Makefile and run `make publish`. This writes the version to `Sources/TunaCore/Cargo.toml`, updates `Cargo.lock` and the changelog, and pushes the release commit and tag.

The tag triggers a universal Audio Unit build for Apple Silicon and Intel. GitHub Actions signs the component, publishes `Tuna.zip`, and updates the Homebrew cask with the archive's SHA-256 checksum.
