#!/usr/bin/env node
/**
 * Bake the Tone.js intro cinematic to a static .opus file.
 *
 * The procedural Kraftwerk-style cinematic that `playIntroCinematic` synthesises
 * via Tone.js requires a user gesture to unlock the AudioContext — fresh-tab
 * browsers with strict autoplay policies silenced the splash music until the
 * player interacted. A static .opus file played via HTMLAudio sidesteps the
 * AudioContext gate (HTMLAudio.play() has more permissive autoplay rules in
 * Chrome's MEI-based policy than Web Audio), so on returning visits with
 * primed Media Engagement Index the music plays from t=0 of the splash.
 *
 * This script renders the SAME synth graph as `playIntroCinematic` (line ~810
 * of soundtrack.ts) via Tone.Offline() inside a headless Chromium spawned by
 * Playwright. The output is a 5.5 s stereo WAV → Opus 96 kbps stereo at
 * `static/audio/intro-cinematic.opus`. Re-run after any tweak to the
 * cinematic synth to refresh the static file.
 *
 * Usage:
 *   npm run intro:bake
 *
 * Prerequisites (already in package.json devDependencies):
 *   * @playwright/test
 *   * ffmpeg on PATH (winget install Gyan.FFmpeg / brew install ffmpeg)
 *
 * Output: static/audio/intro-cinematic.opus (~50-80 KB)
 */

import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '..');
const OUTPUT_OPUS = resolve(REPO_ROOT, 'static/audio/intro-cinematic.opus');
const TEMP_WAV = resolve(REPO_ROOT, '.intro-cinematic-bake.wav');

const CINEMATIC_DURATION_SEC = 5.5;

/**
 * Float32 channels → WAV PCM-16 bytes. Standard RIFF header + interleaved
 * little-endian int16 samples. Two channels (stereo) only — Tone's stereo
 * widener output guarantees both channels are present.
 */
function float32StereoToWav(left, right, sampleRate) {
	const numSamples = left.length;
	const numChannels = 2;
	const bytesPerSample = 2;
	const blockAlign = numChannels * bytesPerSample;
	const byteRate = sampleRate * blockAlign;
	const dataLen = numSamples * blockAlign;
	const buffer = new ArrayBuffer(44 + dataLen);
	const view = new DataView(buffer);
	// "RIFF" chunk header
	view.setUint8(0, 0x52); // R
	view.setUint8(1, 0x49); // I
	view.setUint8(2, 0x46); // F
	view.setUint8(3, 0x46); // F
	view.setUint32(4, 36 + dataLen, true);
	view.setUint8(8, 0x57); // W
	view.setUint8(9, 0x41); // A
	view.setUint8(10, 0x56); // V
	view.setUint8(11, 0x45); // E
	// "fmt " sub-chunk
	view.setUint8(12, 0x66); // f
	view.setUint8(13, 0x6d); // m
	view.setUint8(14, 0x74); // t
	view.setUint8(15, 0x20); // (space)
	view.setUint32(16, 16, true); // fmt chunk size
	view.setUint16(20, 1, true); // PCM format
	view.setUint16(22, numChannels, true);
	view.setUint32(24, sampleRate, true);
	view.setUint32(28, byteRate, true);
	view.setUint16(32, blockAlign, true);
	view.setUint16(34, bytesPerSample * 8, true);
	// "data" sub-chunk
	view.setUint8(36, 0x64); // d
	view.setUint8(37, 0x61); // a
	view.setUint8(38, 0x74); // t
	view.setUint8(39, 0x61); // a
	view.setUint32(40, dataLen, true);
	// Interleaved samples
	let offset = 44;
	for (let i = 0; i < numSamples; i += 1) {
		const ls = Math.max(-1, Math.min(1, left[i]));
		const rs = Math.max(-1, Math.min(1, right[i]));
		view.setInt16(offset, ls < 0 ? ls * 0x8000 : ls * 0x7fff, true);
		offset += 2;
		view.setInt16(offset, rs < 0 ? rs * 0x8000 : rs * 0x7fff, true);
		offset += 2;
	}
	return Buffer.from(buffer);
}

/**
 * Run ffmpeg WAV → Opus 96 kbps stereo. Matches the encoding of all music
 * stems + SFX in `static/audio/` so the player perceives a uniform mix.
 */
function encodeOpus(wavPath, opusPath) {
	return new Promise((resolvePromise, rejectPromise) => {
		const args = [
			'-y',
			'-i',
			wavPath,
			'-c:a',
			'libopus',
			'-b:a',
			'96k',
			'-ac',
			'2',
			'-application',
			'audio',
			opusPath
		];
		const child = spawn('ffmpeg', args, { stdio: ['ignore', 'inherit', 'inherit'] });
		child.on('exit', (code) => {
			if (code === 0) resolvePromise();
			else rejectPromise(new Error(`ffmpeg exited ${code}`));
		});
		child.on('error', (err) => {
			rejectPromise(new Error(`Failed to spawn ffmpeg: ${err.message}. Install ffmpeg.`));
		});
	});
}

/**
 * The bake function — runs inside the headless browser. Loads Tone from a CDN
 * (skipif-cached) and calls Tone.Offline() with the SAME synth graph that
 * `playIntroCinematic` builds at runtime. Returns the rendered AudioBuffer
 * as two Float32Array channels for the Node side to wrap in WAV.
 *
 * Keep this function in lockstep with `playIntroCinematic` in
 * `src/lib/audio/soundtrack.ts` (lines ~810-870). Any change there needs to
 * be mirrored here + a fresh re-bake.
 */
async function bakeInBrowser(page) {
	await page.setContent('<!doctype html><html><body><script type="module"></script></body></html>');

	const result = await page.evaluate(async (durationSec) => {
		const Tone = await import('https://esm.sh/tone@15.0.4');
		const buffer = await Tone.Offline(({ transport: _transport }) => {
			const master = new Tone.Volume(-12).toDestination();
			const filter = new Tone.Filter({ frequency: 400, type: 'lowpass', Q: 4 }).connect(master);
			const lfo = new Tone.LFO({ frequency: 0.18, min: 400, max: 6000 }).connect(filter.frequency);

			const bass = new Tone.MonoSynth({
				oscillator: { type: 'square' },
				envelope: { attack: 0.005, decay: 0.18, sustain: 0, release: 0.05 },
				filterEnvelope: {
					attack: 0.001,
					decay: 0.15,
					sustain: 0,
					release: 0.1,
					baseFrequency: 80,
					octaves: 2
				}
			}).connect(filter);

			const lead = new Tone.PolySynth(Tone.Synth, {
				oscillator: { type: 'sawtooth' },
				envelope: { attack: 0.01, decay: 0.12, sustain: 0.4, release: 0.2 }
			});
			lead.volume.value = -8;
			lead.connect(filter);

			const pad = new Tone.PolySynth(Tone.Synth, {
				oscillator: { type: 'triangle' },
				envelope: { attack: 1.5, decay: 1, sustain: 0.5, release: 1 }
			});
			pad.volume.value = -16;
			pad.connect(filter);

			lfo.start(0);

			// 10 bass hits at 120 BPM (one per 0.5 s) — motorik pulse.
			for (let i = 0; i < 10; i += 1) {
				bass.triggerAttackRelease('A1', '8n', i * 0.5);
			}
			// Ascending Am-pentatonic arpeggio. 32 notes × 0.125 s = 4 s.
			const arp = ['A3', 'C4', 'E4', 'A4'];
			for (let i = 0; i < 32; i += 1) {
				lead.triggerAttackRelease(arp[i % arp.length], '16n', i * 0.125, 0.5);
			}
			// Sustained pad chord — Am for first 2.5 s, lifts to C-major for resolve.
			pad.triggerAttackRelease(['A2', 'C3', 'E3'], 2.5, 0);
			pad.triggerAttackRelease(['C3', 'E3', 'G3'], 2.5, 2.5);
		}, durationSec);

		// `buffer` is a Tone.ToneAudioBuffer. `.get()` returns the underlying
		// AudioBuffer. Extract channel data + sample rate to ship back to Node.
		const ab = buffer.get();
		const left = Array.from(ab.getChannelData(0));
		const right = ab.numberOfChannels > 1 ? Array.from(ab.getChannelData(1)) : left;
		return {
			sampleRate: ab.sampleRate,
			left,
			right
		};
	}, CINEMATIC_DURATION_SEC);

	return result;
}

async function main() {
	console.log('=== Baking intro cinematic ===');
	console.log(`Duration:  ${CINEMATIC_DURATION_SEC} s`);
	console.log(`Output:    ${OUTPUT_OPUS}`);
	console.log('');

	// Prefer the system-installed Chrome (`channel: 'chrome'`) to avoid the
	// Playwright-bundled Chromium download, which can fail behind corporate
	// proxies / SSL inspection setups. Falls back to bundled Chromium if Chrome
	// isn't found on the system.
	let browser;
	try {
		browser = await chromium.launch({ headless: true, channel: 'chrome' });
	} catch (err) {
		console.log(`  Chrome channel unavailable (${err.message}). Trying bundled Chromium...`);
		browser = await chromium.launch({ headless: true });
	}
	try {
		const page = await browser.newPage();
		console.log('Rendering Tone.js cinematic in headless Chromium...');
		const { sampleRate, left, right } = await bakeInBrowser(page);
		console.log(`  Rendered ${left.length} samples at ${sampleRate} Hz`);

		console.log('Writing WAV...');
		mkdirSync(dirname(TEMP_WAV), { recursive: true });
		const wavBytes = float32StereoToWav(
			new Float32Array(left),
			new Float32Array(right),
			sampleRate
		);
		writeFileSync(TEMP_WAV, wavBytes);
		console.log(`  Temp WAV: ${TEMP_WAV} (${(wavBytes.length / 1024).toFixed(1)} KiB)`);

		console.log('Encoding Opus...');
		mkdirSync(dirname(OUTPUT_OPUS), { recursive: true });
		await encodeOpus(TEMP_WAV, OUTPUT_OPUS);
		console.log('  Encoded.');

		console.log('Cleaning up temp WAV...');
		if (existsSync(TEMP_WAV)) unlinkSync(TEMP_WAV);

		console.log('');
		console.log(`Done. Static intro cinematic at ${OUTPUT_OPUS}`);
	} finally {
		await browser.close();
	}
}

main().catch((err) => {
	console.error('Fatal:', err);
	if (existsSync(TEMP_WAV)) {
		try {
			unlinkSync(TEMP_WAV);
		} catch {
			/* ignore */
		}
	}
	process.exit(1);
});
