#!/usr/bin/env node
/**
 * Encode Suno-generated music sources into the 24 stem files the HiFi stem mixer
 * expects under `static/audio/music/<mood>/<layer>-<variant>.opus`.
 *
 * Pipeline (per source file):
 *   1. Run `demucs` (CPU-only htdemucs model) → splits into drums/bass/other/vocals.
 *   2. Drop vocals.wav (Suno is instrumental but Demucs always emits a vocals stem).
 *   3. ffmpeg-encode drums/bass/other into Opus 96 kbps stereo at the final paths.
 *
 * Layer mapping (Demucs → mixer):
 *   drums.wav  → drums-<variant>.opus
 *   bass.wav   → bass-<variant>.opus
 *   other.wav  → melodyPad-<variant>.opus   (melody + pad collapsed into one layer)
 *
 * Naming convention for source files:
 *   <moodNum>_<moodName>[any descriptor text]_<variantLetter>_<sunoTrackIdx>.<ext>
 *
 *   * `moodNum` ∈ {1, 2, 3, 4} — sanity-check prefix mirroring `moodName`.
 *   * `moodName` ∈ {calm_day, surplus_day, tense_night, dawn_relief}.
 *   * any descriptor text — free-form (Suno often appends key/tempo/mood). Ignored
 *     by the parser; useful for the human's listening notes.
 *   * `variantLetter` ∈ {A, B} (capital) — maps to `-a` / `-b` in the stem filename.
 *   * `sunoTrackIdx` ∈ {1, 2} — Suno always returns two candidates per prompt.
 *   * Extension: .wav / .mp3 / .flac / .m4a — Demucs handles all four.
 *
 *   Example (verbatim from Suno's "Download" button):
 *     1_calm_day (110 BPM, A Aeolian) — early colony, meditative_A_1.mp3
 *     1_calm_day (110 BPM, A Aeolian) — early colony, meditative_A_2.mp3
 *     1_calm_day_B_1.mp3
 *
 * Picking between two Suno takes per prompt:
 *   When both `_A_1` and `_A_2` exist for the same (mood, variant), the script
 *   defaults to take 1. Flags:
 *     --prefer-suno=2          use take 2 instead (consistent across all moods)
 *     --takes-as-variants      treat `_A_1` as variant A and `_A_2` as variant B
 *                              within the same prompt (B prompts not needed).
 *                              Errors if any `_B_*` files exist alongside.
 *
 * Prerequisites:
 *   * Python 3 + `pip install demucs` (or `pipx install demucs`)
 *   * ffmpeg on PATH (winget install Gyan.FFmpeg / brew install ffmpeg)
 *
 * Usage:
 *   node scripts/encode-music-stems.mjs <source-dir>
 *   node scripts/encode-music-stems.mjs ./.suno-tracks                  # default scan
 *   node scripts/encode-music-stems.mjs ./.suno-tracks --dry-run        # report only
 *   node scripts/encode-music-stems.mjs ./.suno-tracks --mood=calm_day  # one mood at a time
 *   node scripts/encode-music-stems.mjs ./.suno-tracks --prefer-suno=2  # take 2 preferred
 *
 * Long clips: Suno v4 returns 1–4 minute clips by default. The mixer loops the buffer,
 * so long clips become long loop windows (more variability). 96 kbps Opus stereo at
 * 4 min = ~2.8 MB per stem → ~68 MB for 24 stems → fits Vercel's 100 MB cap; ~72 MB
 * decoded in RAM if every mood activates simultaneously (per-mood activation usually
 * keeps it lower). Sweet spot: 60–120 seconds.
 *
 * The script is idempotent — already-encoded targets that match by mtime are skipped.
 * Re-run as new Suno tracks land without re-encoding the ones you've already done.
 *
 * NOTE: this is a one-shot tooling script, NOT a CI gate. Runs locally on the dev's
 * machine where Demucs + ffmpeg live. Tests + lint are happy if you never run it.
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, parse, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '..');
const STEMS_OUT_ROOT = resolve(REPO_ROOT, 'static/audio/music');
const DEMUCS_WORK_DIR = resolve(REPO_ROOT, '.demucs-work');

const MOODS = ['calm_day', 'surplus_day', 'tense_night', 'dawn_relief'];
const ACCEPTED_EXTS = ['.wav', '.mp3', '.flac', '.m4a'];

/**
 * Canonical mood-number → mood-name mapping. The filename prefix `<moodNum>_` is a
 * human aide and a sanity check; the script keys off the substring mood NAME after it.
 * Misaligned numbers (e.g. `2_calm_day_A_1.mp3`) emit a warning but still process —
 * the user's listening intent is clear from the name, not the digit.
 */
const MOOD_NUM_TO_NAME = {
	1: 'calm_day',
	2: 'surplus_day',
	3: 'tense_night',
	4: 'dawn_relief'
};

// Demucs layer name → mixer layer name. `other` collapses the melody + pad layers
// into a single `melodyPad` stem because the htdemucs model doesn't separate them
// further. The mixer's 3-layer design (drums/bass/melodyPad) was picked with this
// 4-stem source in mind.
const LAYER_MAP = {
	drums: 'drums',
	bass: 'bass',
	other: 'melodyPad'
};

// ── CLI parsing ──────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
let sourceDir = null;
let dryRun = false;
let moodFilter = null;
/** 1 or 2 — which Suno take to use when both `_A_1` and `_A_2` exist for the same variant. */
let preferSuno = 1;
/** When set, `_A_1` → variant A and `_A_2` → variant B (single-prompt-per-mood workflow). */
let takesAsVariants = false;

for (const arg of args) {
	if (arg === '--dry-run' || arg === '-n') {
		dryRun = true;
	} else if (arg.startsWith('--mood=')) {
		moodFilter = arg.slice('--mood='.length);
		if (!MOODS.includes(moodFilter)) {
			console.error(`Unknown mood: ${moodFilter}. Valid: ${MOODS.join(', ')}`);
			process.exit(2);
		}
	} else if (arg.startsWith('--prefer-suno=')) {
		const v = Number.parseInt(arg.slice('--prefer-suno='.length), 10);
		if (v !== 1 && v !== 2) {
			console.error(`--prefer-suno must be 1 or 2 (got: ${arg.slice('--prefer-suno='.length)}).`);
			process.exit(2);
		}
		preferSuno = v;
	} else if (arg === '--takes-as-variants') {
		takesAsVariants = true;
	} else if (arg.startsWith('-')) {
		console.error(`Unknown flag: ${arg}`);
		printUsageAndExit(2);
	} else if (sourceDir === null) {
		sourceDir = resolve(process.cwd(), arg);
	} else {
		console.error(`Unexpected positional argument: ${arg}`);
		printUsageAndExit(2);
	}
}

if (sourceDir === null) {
	printUsageAndExit(2);
}

if (!existsSync(sourceDir) || !statSync(sourceDir).isDirectory()) {
	console.error(`Source dir doesn't exist or isn't a directory: ${sourceDir}`);
	process.exit(2);
}

function printUsageAndExit(code) {
	console.error(
		'Usage: node scripts/encode-music-stems.mjs <source-dir> [--mood=<mood>] [--prefer-suno=1|2] [--takes-as-variants] [--dry-run]'
	);
	console.error('');
	console.error(
		'Filename convention: <moodNum>_<moodName>[descriptor]_<variantLetter>_<sunoTrackIdx>.<ext>'
	);
	console.error('  moodNum:      1 (calm_day), 2 (surplus_day), 3 (tense_night), 4 (dawn_relief)');
	console.error('  moodName:     calm_day | surplus_day | tense_night | dawn_relief');
	console.error('  variantLetter: A | B (capital)');
	console.error('  sunoTrackIdx: 1 | 2');
	console.error('  ext:          .wav | .mp3 | .flac | .m4a');
	process.exit(code);
}

// ── Discovery ────────────────────────────────────────────────────────────────────
/**
 * Parse a filename into (moodNum, moodName, descriptor, variantLetter, sunoTrackIdx).
 *
 * The format is intentionally tolerant: Suno's "Download" button gives you names like
 *
 *   `1_calm_day (110 BPM, A Aeolian) — early colony, meditative_A_1.mp3`
 *   `1 — calm_day (110 BPM, A Aeolian) — early colony, meditative_B_1.wav`
 *
 * The parser keys off ANCHORS:
 *
 *   - `^(\d+)[\W_]+` — opening mood digit (1..4) followed by any combination of
 *     non-letter delimiter chars: `_`, space, hyphen `-`, em-dash `—`, en-dash `–`.
 *     This matches both the canonical `1_calm_day` underscore and Suno's natural
 *     `1 — calm_day` (space-em-dash-space) export style.
 *   - `_([AB])_([12])$` — trailing variant + Suno take. Anchors the (variant, take) pair.
 *
 * Between the two anchors lies the mood name (canonical, snake_case) plus arbitrary
 * descriptor text. The mood NAME is detected by substring match against the canonical
 * list — robust to Suno's parentheses, em-dashes, commas, etc.
 *
 * Returns null when the filename doesn't fit (caller emits a [skip] warning).
 */
function parseFilename(basename) {
	// `[\W_]+` matches one or more non-word characters or underscores. `\W` excludes
	// underscores by JS default (underscore is in `\w`), so we add it explicitly. This
	// covers `1_`, `1 — ` (space + em-dash + space), `1 - `, `1--`, etc.
	const headMatch = basename.match(/^(\d+)[\W_]+/);
	if (!headMatch) return null;
	const moodNumStr = headMatch[1];
	const moodNum = Number.parseInt(moodNumStr, 10);

	const tailMatch = basename.match(/_([AB])_([12])$/);
	if (!tailMatch) return null;
	const variantLetter = tailMatch[1];
	const sunoTrackIdx = Number.parseInt(tailMatch[2], 10);

	// Mood name: the canonical mood name that appears as a substring between the anchors.
	// We don't require it to be IMMEDIATELY after the digit (Suno may insert spaces),
	// but it must be present somewhere in the middle.
	const middle = basename.slice(headMatch[0].length, basename.length - tailMatch[0].length);
	const moodName = MOODS.find((m) => middle.includes(m)) ?? null;
	if (!moodName) return null;

	return {
		moodNum,
		moodName,
		variantLetter,
		sunoTrackIdx
	};
}

/**
 * Discover and select source files.
 *
 * Two-pass walk:
 *   1. Parse every accepted file into a record. Collect candidates per (mood, variantLetter).
 *   2. Apply selection: --prefer-suno picks 1 or 2 within a single variant; --takes-as-variants
 *      remaps `_A_1` → variant A and `_A_2` → variant B (requires no `_B_*` files present).
 *
 * Returns the final list of (source, mood, variant) tuples to process. Each (mood, variant)
 * appears exactly once.
 */
function discoverSources(dir) {
	const entries = readdirSync(dir);
	/** Map: `${mood}_${VARIANT_LETTER}_${sunoIdx}` → source path. */
	const candidates = new Map();
	const hasBPrompt = new Set(); // moods with any `_B_*` files seen — informs --takes-as-variants validation

	for (const name of entries) {
		const parsed = parse(name);
		if (!ACCEPTED_EXTS.includes(parsed.ext.toLowerCase())) continue;
		const meta = parseFilename(parsed.name);
		if (!meta) {
			console.warn(`  [skip] ${name} — doesn't match <moodNum>_<moodName>..._<A|B>_<1|2>`);
			continue;
		}
		// Sanity check: mood digit prefix should match the mood name. Misalignment is a
		// hint that the user copy-pasted across moods; warn but still process.
		const expectedNum = Object.entries(MOOD_NUM_TO_NAME).find(
			([, name2]) => name2 === meta.moodName
		)?.[0];
		if (expectedNum != null && Number.parseInt(expectedNum, 10) !== meta.moodNum) {
			console.warn(
				`  [warn] ${name} — moodNum=${meta.moodNum} but moodName=${meta.moodName} (expected ${expectedNum}). Processing anyway.`
			);
		}
		if (moodFilter && meta.moodName !== moodFilter) continue;
		const key = `${meta.moodName}_${meta.variantLetter}_${meta.sunoTrackIdx}`;
		if (candidates.has(key)) {
			console.warn(
				`  [skip] ${name} — duplicate (mood=${meta.moodName} variant=${meta.variantLetter} suno=${meta.sunoTrackIdx}). Keeping first.`
			);
			continue;
		}
		candidates.set(key, join(dir, name));
		if (meta.variantLetter === 'B') hasBPrompt.add(meta.moodName);
	}

	// Selection pass.
	const finalList = [];

	if (takesAsVariants) {
		// Validate: no `_B_*` files should be present (the flag's contract is that the user
		// generated ONE prompt per mood and wants Suno's two takes as A/B).
		if (hasBPrompt.size > 0) {
			throw new Error(
				`--takes-as-variants conflicts with explicit _B_* files for: ${[...hasBPrompt].join(', ')}. Remove the B files or drop the flag.`
			);
		}
		// For each mood, _A_1 → variant a, _A_2 → variant b.
		for (const mood of MOODS) {
			const a1 = candidates.get(`${mood}_A_1`);
			const a2 = candidates.get(`${mood}_A_2`);
			if (a1) finalList.push({ source: a1, mood, variant: 'a' });
			else console.warn(`  [miss] ${mood} variant a (_A_1) not found`);
			if (a2) finalList.push({ source: a2, mood, variant: 'b' });
			else console.warn(`  [miss] ${mood} variant b (_A_2) not found`);
		}
	} else {
		// Standard mode: separate prompts for A and B. --prefer-suno picks 1 or 2 within each.
		const fallback = preferSuno === 1 ? 2 : 1;
		for (const mood of MOODS) {
			for (const letter of ['A', 'B']) {
				const primary = candidates.get(`${mood}_${letter}_${preferSuno}`);
				const fallbackTake = candidates.get(`${mood}_${letter}_${fallback}`);
				const picked = primary ?? fallbackTake;
				if (!picked) continue;
				if (!primary && fallbackTake) {
					console.warn(
						`  [info] ${mood} variant ${letter.toLowerCase()}: preferred Suno take ${preferSuno} missing; using take ${fallback}.`
					);
				}
				finalList.push({ source: picked, mood, variant: letter.toLowerCase() });
			}
		}
	}

	return finalList;
}

// ── Demucs ───────────────────────────────────────────────────────────────────────
/**
 * Run demucs on a single source file. Outputs to `.demucs-work/<model>/<basename>/`.
 * Demucs is CPU-only by default — fine for 30 s tracks (~30 s per source on a
 * modern desktop).
 */
function runDemucs(sourceFile) {
	return new Promise((resolvePromise, rejectPromise) => {
		// `--filename '{track}/{stem}.{ext}'` places each source's stems in its OWN
		// subdirectory, so processing N sources doesn't have each overwrite the previous's
		// `drums.wav` etc. Demucs's default pattern is exactly this, but being explicit
		// guards against the upstream default changing. {track} resolves to the source
		// basename without extension, matching what the retrieve step (below) expects via
		// `parse(source).name`.
		const args = [
			'-m',
			'demucs',
			'-n',
			'htdemucs',
			'-o',
			DEMUCS_WORK_DIR,
			'--filename',
			'{track}/{stem}.{ext}',
			sourceFile
		];
		// Force UTF-8 stdio in the spawned python so demucs's `print(f"Separating track {track}")`
		// doesn't crash on filenames containing characters absent from Windows' default cp1252
		// codec — typically the en/em dash and arrows (U+2192) we get from Suno's descriptors.
		// Without this, a file like `4 — dawn_relief (... C Ionian → F Lydian) ..._B_1.wav`
		// throws `UnicodeEncodeError: 'charmap' codec can't encode character '→'`.
		const env = { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' };
		const child = spawn('python', args, { stdio: 'inherit', env });
		child.on('exit', (code) => {
			if (code === 0) resolvePromise();
			else rejectPromise(new Error(`demucs exited ${code} for ${sourceFile}`));
		});
		child.on('error', (err) => {
			rejectPromise(
				new Error(`Failed to spawn demucs: ${err.message}. Install: pip install demucs`)
			);
		});
	});
}

// ── ffmpeg encode ────────────────────────────────────────────────────────────────
function encodeOpus(inputWav, outputOpus) {
	return new Promise((resolvePromise, rejectPromise) => {
		// Opus 96 kbps stereo: the sweet spot for ambient loops — transparent enough that
		// listeners can't ABX it against the source, small enough that 24 stems × ~360 KB
		// = ~9 MB on disk + ~9 MB decoded in RAM. Higher bitrates don't help; lower start
		// to muddy the high-end pads.
		const args = [
			'-y',
			'-i',
			inputWav,
			'-c:a',
			'libopus',
			'-b:a',
			'96k',
			'-ac',
			'2',
			'-application',
			'audio',
			outputOpus
		];
		const child = spawn('ffmpeg', args, { stdio: ['ignore', 'inherit', 'inherit'] });
		child.on('exit', (code) => {
			if (code === 0) resolvePromise();
			else rejectPromise(new Error(`ffmpeg exited ${code} for ${inputWav}`));
		});
		child.on('error', (err) => {
			rejectPromise(
				new Error(`Failed to spawn ffmpeg: ${err.message}. Install: winget install Gyan.FFmpeg`)
			);
		});
	});
}

// ── Idempotency check ────────────────────────────────────────────────────────────
/**
 * Skip a source if all 3 of its output files exist AND are newer than the source.
 * If the source got modified (new generation, re-export), re-encode.
 */
function shouldSkip(sourceFile, mood, variant) {
	const sourceMtime = statSync(sourceFile).mtimeMs;
	for (const layer of Object.values(LAYER_MAP)) {
		const outPath = join(STEMS_OUT_ROOT, mood, `${layer}-${variant}.opus`);
		if (!existsSync(outPath)) return false;
		if (statSync(outPath).mtimeMs < sourceMtime) return false;
	}
	return true;
}

// ── Main ─────────────────────────────────────────────────────────────────────────
async function processOne({ source, mood, variant }) {
	const label = `${mood}_${variant}`;
	if (shouldSkip(source, mood, variant)) {
		console.log(`  [skip] ${label} — outputs already up-to-date`);
		return { mood, variant, status: 'skipped' };
	}
	if (dryRun) {
		console.log(
			`  [dry] ${label} — would Demucs + encode → ${mood}/{drums,bass,melodyPad}-${variant}.opus`
		);
		return { mood, variant, status: 'dry' };
	}

	console.log(`  [demucs] ${label}`);
	await runDemucs(source);

	const sourceBase = parse(source).name;
	const demucsOutDir = join(DEMUCS_WORK_DIR, 'htdemucs', sourceBase);

	mkdirSync(join(STEMS_OUT_ROOT, mood), { recursive: true });

	for (const [demucsLayer, mixerLayer] of Object.entries(LAYER_MAP)) {
		// Demucs emits the layer name + the source's original extension via --filename
		// `{stem}.{ext}`. Probe for both .wav and .mp3 to be tolerant of input format.
		let inputStem = null;
		for (const ext of ['.wav', '.mp3', '.flac', '.m4a']) {
			const candidate = join(demucsOutDir, `${demucsLayer}${ext}`);
			if (existsSync(candidate)) {
				inputStem = candidate;
				break;
			}
		}
		if (!inputStem) {
			throw new Error(`Demucs didn't produce ${demucsLayer}.* in ${demucsOutDir}`);
		}
		const outPath = join(STEMS_OUT_ROOT, mood, `${mixerLayer}-${variant}.opus`);
		console.log(`  [encode] ${demucsLayer} → ${mood}/${mixerLayer}-${variant}.opus`);
		await encodeOpus(inputStem, outPath);
	}
	return { mood, variant, status: 'encoded' };
}

async function main() {
	console.log(`Source dir:    ${sourceDir}`);
	console.log(`Output root:   ${STEMS_OUT_ROOT}`);
	console.log(`Demucs work:   ${DEMUCS_WORK_DIR}`);
	if (moodFilter) console.log(`Mood filter:   ${moodFilter}`);
	console.log(`Prefer Suno:   take ${preferSuno}`);
	if (takesAsVariants) console.log('Mode:          takes-as-variants (_A_1 → A, _A_2 → B)');
	if (dryRun) console.log(`Mode:          DRY RUN (nothing written)`);
	console.log('');

	let sources;
	try {
		sources = discoverSources(sourceDir);
	} catch (err) {
		console.error(`Discovery failed: ${err.message}`);
		process.exit(2);
	}
	if (sources.length === 0) {
		console.log('No matching source files found.');
		console.log('Expected: <moodNum>_<moodName>[descriptor]_<variantLetter>_<sunoTrackIdx>.<ext>');
		console.log(`Moods: ${MOODS.join(', ')}`);
		console.log(`Variant letters: A, B    Suno takes: 1, 2`);
		console.log('Example: 1_calm_day_A_1.mp3');
		process.exit(0);
	}
	console.log(`Found ${sources.length} source file(s) to process:`);
	for (const s of sources) console.log(`  - ${parse(s.source).base} → ${s.mood}/${s.variant}`);
	console.log('');

	const results = [];
	for (const item of sources) {
		try {
			const r = await processOne(item);
			results.push(r);
		} catch (err) {
			console.error(`  [FAIL] ${item.mood}_${item.variant}: ${err.message}`);
			results.push({
				mood: item.mood,
				variant: item.variant,
				status: 'failed',
				error: err.message
			});
		}
	}

	console.log('');
	console.log('Summary:');
	const counts = { encoded: 0, skipped: 0, dry: 0, failed: 0 };
	for (const r of results) counts[r.status] = (counts[r.status] || 0) + 1;
	for (const [status, n] of Object.entries(counts)) {
		if (n > 0) console.log(`  ${status}: ${n}`);
	}

	// Inventory of what's now on disk — useful for "do I have all 24?" question.
	console.log('');
	console.log('Stems on disk:');
	let totalOnDisk = 0;
	for (const mood of MOODS) {
		const moodDir = join(STEMS_OUT_ROOT, mood);
		if (!existsSync(moodDir)) {
			console.log(`  ${mood}: (no directory yet)`);
			continue;
		}
		const files = readdirSync(moodDir).filter((f) => f.endsWith('.opus'));
		console.log(`  ${mood}: ${files.length}/6 stems`);
		totalOnDisk += files.length;
	}
	console.log(`Total: ${totalOnDisk}/24 stems`);
	if (totalOnDisk === 24) {
		console.log('\n  All stems present. The mixer will activate every mood on next page load.');
	} else if (totalOnDisk > 0) {
		console.log(
			`\n  Partial coverage. Moods with all 6 stems will activate (per-mood activation, v0.5.1).`
		);
	}

	process.exit(counts.failed > 0 ? 1 : 0);
}

main().catch((err) => {
	console.error('Fatal:', err);
	process.exit(1);
});
