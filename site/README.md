# omcp.app

The static landing page for [omcp.app](https://omcp.app).

Cloudflare Pages should publish `site/public/`. The site is intentionally one hand-written HTML
file with inline CSS: no build step, package manager, framework, analytics, cookies, forms, or
runtime service.

The page uses the product screenshots already tracked in this repository. Deployments do not need
environment variables or additional configuration.

Cloudflare Pages settings:

- Framework preset: `None`
- Build command: leave blank
- Build output directory: `site/public`
- Root directory: repository root
