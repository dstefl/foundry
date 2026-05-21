# Audio scripts

Toolchain for sourcing + encoding game audio.

## `encode-music-stems.mjs`

Suno-track → 24-stem Opus pipeline for the per-mood HiFi stem mixer pattern
(see lunarpowerpulse `src/lib/audio/stemMixer.ts` for the consumer). Takes
a directory of Suno `<moodNum>_<moodName>..._<variant>_<take>.wav` files,
runs each through Demucs htdemucs (CPU) for drums/bass/melody-pad split,
ffmpeg-encodes each stem to Opus 96 kbps stereo with `loudnorm I=-18`.

Prereqs (local, not CI): `pip install demucs` + ffmpeg on PATH.

```bash
node scripts/audio/encode-music-stems.mjs ./my-suno-tracks
```

See script header for full flag reference (`--mood=...`, `--prefer-suno=N`,
`--takes-as-variants`, `--dry-run`).

## `bake-intro-cinematic.mjs`

Renders the lunarpowerpulse Tone.js Kraftwerk intro cinematic to a static
.opus file via Playwright + Tone.Offline() in headless Chrome. Used to
sidestep the Web Audio autoplay block: HTMLAudio playback of the baked
.opus has more permissive autoplay rules in Chrome's MEI-gated policy.

```bash
node scripts/audio/bake-intro-cinematic.mjs
```

Outputs `static/audio/intro-cinematic.opus` (~80 KB).

The Tone synth graph inside the script is project-specific (the
lunarpowerpulse cinematic). Adapt for other projects by editing the
`bakeInBrowser` function or by passing a different synth-builder callback.

## Prereqs

* Node 22+
* For `encode-music-stems`: Python 3 + `demucs` + ffmpeg
* For `bake-intro-cinematic`: `@playwright/test`, Chrome installed on the
  host (auto-falls-back to bundled Chromium if Chrome channel isn't there)
  + ffmpeg
