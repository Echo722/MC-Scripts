# MC Scripts

Unified ReaPack repository for REAPER scripts and effects developed by MC Scripts.

Import this ReaPack repository:

```text
https://github.com/Echo722/MC-Scripts/raw/main/index.xml
```

Scripts install under:

```text
REAPER/Scripts/MC Scripts Release/<script-folder>/
```

Effects (JSFX) install under:

```text
REAPER/Effects/MC Scripts Release/<effect-folder>/
```

## Packages

- MediaEye: Media Explorer album art viewer for embedded and sidecar cover images.
- TonalReducer (effect, beta): MC Tonal Reducer turns down sustained tones, notes, chords and glides in sound effects while keeping impacts and noise texture. It is a pre-release, so install it from the package browser with right-click > Versions...
- ChannelFit: MC ChannelFit batch-exports regions as mono or stereo files depending on whether their left and right channels actually differ. Requires ReaImGui and js_ReaScriptAPI.

## Release Convention

Packages in this repository use:

- Author: `MC Scripts`
- Repository name: `MC Scripts Release`
- Category: `<script-folder>` (or `<effect-folder>`)
- Source file paths: direct package files such as `MediaEye.lua` or `MC_TonalReducer.jsfx`
