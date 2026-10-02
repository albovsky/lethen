# Website

Plain HTML and CSS for the Lethen website at lethen.dev. It is served by a Cloudflare Worker with static assets: `wrangler.jsonc` at the repository root names the Worker `lethen`, serves this directory, and attaches `lethen.dev` and `www.lethen.dev`. Cloudflare Workers Builds deploys it from `master` with `npx wrangler deploy`. Preview locally with `python3 -m http.server -d site`.

Keep claims on the page in line with the repository: the precision figure and table come from `docs/validation/precision-corpus.md`, and the Periphery comparison is the 2026-10-02 measurement. Update both together.
