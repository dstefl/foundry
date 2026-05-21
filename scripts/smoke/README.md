# Smoke scripts

Production health-check runners. Used as the final CI step after a Vercel
(or similar) deploy lands — verifies the live endpoint is up before the
workflow reports green.

## `smoke-health.mjs`

GET `$HEALTH_URL` (default `https://pulsarops.com/api/health`), expect a JSON
response with `{ "status": "ok" | "degraded" }`. Retries up to 12× with
5 s between attempts to handle Vercel's deploy-propagation lag.

```bash
node scripts/smoke/smoke-health.mjs
# or with a custom URL:
HEALTH_URL=https://staging.example.com/api/health node scripts/smoke/smoke-health.mjs
```

Exit 0 on `ok` or `degraded`, exit 1 on `down` or persistent unreachability.

## Consumer health endpoint shape

The script expects a JSON body with at least:

```json
{
	"status": "ok" | "degraded" | "down",
	"timestamp": "<ISO 8601 UTC>",
	"checks": [
		{ "name": "...", "status": "ok" | "degraded" | "down", "critical": true | false, "detail": "..." }
	]
}
```

Critical-check failures cascade `status: "down"`; non-critical failures
cascade `degraded`. See lunarpowerpulse `src/routes/api/health/+server.ts`
for a reference implementation.
