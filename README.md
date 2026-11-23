<p align="center">
    <img src="./Assets/logo.svg" width="80px" />
</p>

<h1 align="center">Tuna</h1>

<p align="center">
  <a href="https://github.com/mishamyrt/tuna/actions/workflows/quality-assurance.yml">
      <img src="https://github.com/mishamyrt/tuna/actions/workflows/quality-assurance.yml/badge.svg" />
  </a>
  <a href="https://github.com/mishamyrt/tuna/releases/latest">
    <img src="https://img.shields.io/github/v/tag/mishamyrt/tuna?label=version"
  </a>
</p>

Tuna is a stereo Audio Unit (AUv2) for macOS 14 or later. It applies a SoundID Reference monitor profile and lets you adjust the sound with parametric EQ.

## Install

```sh
brew install --cask mishamyrt/tap/tuna
```

macOS may ask you to approve the plug-in the first time your audio host loads it.

## Use

1. In SoundID Reference, choose **Export → RME** to save your stereo monitor profile as a `.tmreq` file.
2. Add **Myrt → Tuna** in your AUv2 host. In SoundSource, choose **System Output → Add Effect → Myrt → Tuna**.
3. Open the Tuna editor, click **Import Profile…**, and select the exported file.

For source builds, tests, and audio processing details, see [CONTRIBUTING.md](CONTRIBUTING.md).
