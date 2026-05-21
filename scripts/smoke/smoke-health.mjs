/**
 * Smoke test the deployed `/api/health` endpoint.
 *
 * Default target: `https://pulsarops.com/api/health`. Override with
 * `HEALTH_URL=...`. Exits 0 if status is `ok` or `degraded`, 1 if `down`
 * or unreachable.
 *
 * Retries up to `RETRY_ATTEMPTS` times (default 12) with `RETRY_DELAY_MS`
 * between attempts (default 5000) — handles the deploy-propagation lag where
 * Vercel reports the deployment ready but the endpoint takes another 10-30 s
 * to be reachable worldwide.
 *
 * CI wiring (after the Vercel deploy step):
 *
 *   - run: npm run smoke:health
 *
 * Locally, against the dev server:
 *
 *   HEALTH_URL=http://localhost:5173/api/health npm run smoke:health
 *
 * The endpoint itself: `src/routes/api/health/+server.ts`.
 */

const url = process.env.HEALTH_URL ?? 'https://pulsarops.com/api/health';
const requestTimeoutMs = Number(process.env.HEALTH_REQUEST_TIMEOUT_MS ?? 10_000);
const retryAttempts = Number(process.env.RETRY_ATTEMPTS ?? 12);
const retryDelayMs = Number(process.env.RETRY_DELAY_MS ?? 5000);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function attempt() {
	const started = Date.now();
	let r;
	try {
		r = await fetch(url, { signal: AbortSignal.timeout(requestTimeoutMs) });
	} catch (e) {
		return {
			ok: false,
			retryable: true,
			error: e instanceof Error ? e.message : String(e),
			elapsed: Date.now() - started
		};
	}
	const elapsed = Date.now() - started;
	const text = await r.text();
	let body;
	try {
		body = JSON.parse(text);
	} catch {
		return { ok: false, retryable: false, error: `non-JSON response: ${text.slice(0, 200)}` };
	}
	return { ok: true, retryable: false, response: r, body, elapsed };
}

console.log(`[smoke:health] target ${url} (${retryAttempts} attempts, ${retryDelayMs}ms delay)`);

let result;
for (let i = 1; i <= retryAttempts; i++) {
	result = await attempt();
	if (result.ok) {
		console.log(
			`[smoke:health] attempt ${i}/${retryAttempts} → HTTP ${result.response.status} in ${result.elapsed}ms`
		);
		break;
	}
	if (!result.retryable) {
		console.error(`[smoke:health] FAIL — ${result.error}`);
		process.exit(1);
	}
	console.log(
		`[smoke:health] attempt ${i}/${retryAttempts}: ${result.error}, retrying in ${retryDelayMs}ms...`
	);
	if (i < retryAttempts) await sleep(retryDelayMs);
}

if (!result.ok) {
	console.error(`[smoke:health] FAIL — exhausted ${retryAttempts} attempts: ${result.error}`);
	process.exit(1);
}

const { body } = result;
console.log(`[smoke:health] status: ${body.status}`);
for (const c of body.checks ?? []) {
	const sigil = c.status === 'ok' ? '✓' : c.status === 'degraded' ? '~' : '✗';
	const crit = c.critical ? ' (critical)' : '';
	console.log(`  ${sigil} ${c.name}: ${c.status}${crit}${c.detail ? ` — ${c.detail}` : ''}`);
}

if (body.status === 'down') {
	console.error(`[smoke:health] FAIL — overall status is 'down'`);
	process.exit(1);
}
if (body.status === 'degraded') {
	console.warn(`[smoke:health] WARN — overall status is 'degraded' (app still works)`);
}
process.exit(0);
