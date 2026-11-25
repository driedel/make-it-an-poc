<picture>
  <source srcset="docs/make-it-an-poc-dark.svg" media="(prefers-color-scheme: dark)">
  <source srcset="docs/make-it-an-poc-light.svg" media="(prefers-color-scheme: light)">
  <img src="docs/make-it-an-poc-light.svg" width="300" alt="Make it an POC">
</picture>

End-to-end proof of concept, **100% Docker**, for the communication between the **Make it Static** WordPress plugin (HTTP client) and the **Make it Static** service (FastAPI API + RQ worker + Redis + S3 via LocalStack + preview nginx). Covered flow: publishing a post in WordPress fires a **signed** `POST /publish` (HMAC-SHA256 of the raw body + `X-Timestamp` header) to the API; a WP-Cron poller checks the job status every 30s; the worker scrapes the site over the internal network with `wget`, optimizes the assets, and uploads the static site to the S3 bucket, which the preview nginx serves on port 8301.

```
                 POST /publish (HMAC-SHA256 of raw body + X-Timestamp)
┌──────────────┐ ─────────────────────────────────▶ ┌────────────┐
│              │                                    │ API        │
│  WordPress   │ ◀───────────────────────────────── │ (FastAPI)  │
│  + Make it   │   GET /jobs/{id} — 30s poller      └─────┬──────┘
│  Static      │        (via the `cron` sidecar)          │ enqueue
│  plugin      │                                          ▼
└──────┬───────┘                                    ┌────────────┐
       │                                            │   Redis    │
       │                                            └─────┬──────┘
       │                                                  │ dequeue
       │   scrape: wget http://wordpress                  ▼
       │   (internal network) ◀──────────────────── ┌────────────┐
       │                                           │ RQ worker  │
       │                                           │ scrape +   │
       │                                           │ optimize   │
       │                                           └─────┬──────┘
       │                                                 │ optimized upload
       │                                                 │ bucket my-static-site
       │                                                 │ prefix wordpress/
       │                                                 ▼
       │                                           ┌────────────┐     ┌────────────┐
       │   http://localhost:8301                   │ LocalStack │ ──▶ │ nginx      │
       └──────────────────────────────────────────▶│ (S3)       │     │ preview    │
                                                   └────────────┘     └────────────┘

The `cron` sidecar runs `wp cron event run --due-now` in a 30s loop. It fires both
the debounced publish (15s) and the status poller — containers without HTTP traffic
do not trigger WP-Cron on their own.
```

- - -

## Prerequisites

- **Docker Desktop** installed and running (with `docker compose` v2).
- **Sibling clone of the plugin** in the same parent directory as this POC: `../make-it-static-wp-plugin` — the plugin is bind-mounted into WordPress.
- **Service images on Docker Hub** (public, `driedel` namespace): the API and worker use `driedel/make-it-static-api` and `driedel/make-it-static-worker`, tagged via `MIS_VERSION` in `.env` (default `0.2.2`; tags do **not** carry the `v` prefix). `make up` pulls them automatically; `make pull` updates them manually. The `../make-it-static` clone is **no longer required to run** — it remains useful for developing the service (local build commented in `docker-compose.yml`).
- **Ports 8300–8304 free** on the host (`make up` validates them and reports which one is taken).
- **make-it-static dev stack stopped**, to avoid port and `make-it-static-network` conflicts.

## Quickstart

```bash
# 1. Create the .env and generate the HMAC secret
cp .env.example .env
openssl rand -hex 32        # copy the generated value into HMAC_SECRET in .env

# 2. Start the stack (ensures the network, validates .env and ports, pulls the images)
make up

# 3. Wait until everything is up (db healthy, wordpress running)
make ps

# 4. Populate WordPress with test content (takes a few minutes)
make seed

# 5. Open the site in the browser
open http://localhost:8300
```

`make seed` imports the **WordPress Theme Unit Test Data**, removes posts containing **Query Loop blocks** (`wp:query`) — their `?query-N-page=M` pagination is an infinite crawl trap for the worker's `wget --level=0` (the `scrape.sh` reject-regex covers `/page/N/` but not query vars, and the job would blow the 300s scrape timeout) — and **trims the content to the 25 most recent posts and 8 pages** (the full test data generates ~500 scrape requests, ~97% of the 300s budget; the trim keeps scrape at ~40% while keeping ≥20 posts and ≥5 pages). It then downloads featured images, sets `/%postname%/` permalinks and `posts_per_page=25` (the scrape rejects `/page/N/`), creates the primary menu with Home + pages, activates a twenty* theme (twentytwentyone), activates the Make it Static plugin, and writes the settings (`mis_settings`) pointing to the internal API — including `extra_cdn=wpthemetestdata.files.wordpress.com`, the domain of the Theme Unit Test external images the importer does not download: with it in the list, the worker downloads those assets and postprocess rewrites them to relative paths. **The database is not modified**: the imported `post_content` keeps the absolute `http://localhost:8300/...` URLs written by the importer — exactly like a real WordPress database (see "Absolute URLs in content" below).

---

## Test credentials

| Service | Credential | Where |
|---|---|---|
| WordPress admin | user `admin` / password `mis-poc-2026` (email `poc@example.com`) | http://localhost:8300/wp-admin/ |
| MariaDB | db `wordpress`, user `wordpress`, password `wordpress`; root: `rootpassword` | external host `localhost:8304` |
| LocalStack (S3) | accepts **any** credential (compose uses `test`/`test`) | http://localhost:8303 |
| HMAC secret | generated by you in `.env` with `openssl rand -hex 32` | **never commit `.env`** — it is already in `.gitignore` |

## URLs

| What | URL |
|---|---|
| WP site / admin | http://localhost:8300 (admin at `/wp-admin`) |
| Static site preview | http://localhost:8301 |
| API | http://localhost:8302 (`/health` → `{"ok":true,"redis":true}`) |
| LocalStack S3 | http://localhost:8303 (day to day: `make bucket-ls`) |
| MariaDB | `localhost:8304` |

---

## How it works

1. When a **published post** is created/updated, the plugin schedules the publish with a **15s debounce** (WP-Cron event `mis_run_publish`).
2. The event fires the signed `POST /publish` to the API and inserts a row into the `wp_mis_jobs` table.
3. The **poller** (`mis_poll_jobs`, every 30s) checks the status until a terminal state: `queued` → `started` → `finished` (or `failed`/`expired`; a job result expires server-side after ~1h).
4. The **`cron` sidecar** runs `wp cron event run --due-now` in a 30s loop — containers without HTTP traffic do not trigger WP-Cron on their own, so it wakes both the scheduled publish and the poller.
5. The **worker** consumes the job from the RQ queue, scrapes the site at `http://wordpress` (internal `make-it-static-network`) with `wget`, optimizes (CSS/JS bundling, image and HTML compression, font conversion), and uploads everything to the `my-static-site` bucket on LocalStack, under the `wordpress/` prefix.
6. The **preview nginx** serves the bucket at http://localhost:8301.

Three important configuration decisions:

- **Dynamic `WP_HOME`/`WP_SITEURL`**: `WORDPRESS_CONFIG_EXTRA` (the `wordpress` service) defines these constants from the request's `HTTP_HOST`. Without it, the HTML scraped by the worker would carry `http://localhost:8300/...` URLs — unreachable from inside the Docker network — and `wget` would not download the assets. With the dynamic host, scraping `http://wordpress` produces HTML with `wordpress` URLs (downloaded same-host and rewritten to relative in postprocess), while the browser at `localhost:8300` keeps seeing `localhost:8300` URLs.
- **Core auto-update disabled**: the same `WORDPRESS_CONFIG_EXTRA` sets `WP_AUTO_UPDATE_CORE` to `false`. Without it, the volume's WP auto-updated (6.9.4 → 7.1.5) between publishes, changing the scraped HTML with no content change.
- **HMAC secret outside the database**: the seed writes the `MAKE_IT_STATIC_HMAC_SECRET` constant into `wp-config.php` with the value of the `HMAC_SECRET` env var (`wp config set`). The secret is **never** written to the `mis_settings` option or the database — and because it is a literal define (not a `getenv()` via `WORDPRESS_CONFIG_EXTRA`), the `make break-secret`/`make fix-secret` targets can overwrite it for failure scenario 1.

### Absolute URLs in content (no database doctoring)

Real WordPress databases carry absolute public-host URLs in `post_content` (the Theme Unit Test importer writes `http://localhost:8300/wp-content/uploads/...`, since the CLI has no `HTTP_HOST`). The POC does **not** rewrite those URLs in the database — it handles them through the flow, as production would:

1. **Realistic content, untouched database**: `post_content` keeps the absolute public-host URLs. Proof: `SELECT COUNT(*) FROM wp_posts WHERE post_content LIKE '%localhost:8300%'` returns > 0 before and after any publish.
2. **The plugin automatically adds the `home_url()` host to `extra_cdn`** when it differs from the scrape base host (fix in `MIS_Publisher::publish_now()`): since real content has absolute public-host URLs and the service already downloads + rewrites `extra_cdn` hosts end to end, adding `localhost:8300` to the list is enough — the payload goes out with `extra_cdn: ["wpthemetestdata.files.wordpress.com", "localhost:8300"]`.
3. **`extra_hosts: ["localhost:host-gateway"]` shim on the worker** (compose): in production the site's public host is reachable by the worker; in the POC the "public host" is the machine's `localhost:8300`, so this shim makes the worker reach it — emulating the real condition without doctoring anything. It is what allows `wget` to download the `localhost:8300` assets as page requisites.
4. **Dynamic `WP_HOME`/`WP_SITEURL` remains as a wp-config recipe** for internal scraping (not a database change): the URLs *generated* by WP (menus, theme assets) carry the scrape host and are rewritten to relative in postprocess.

> **Known image state (0.2.2)**: the `driedel/make-it-static-*:0.2.2` images **contain every fix** — postprocess (host strip with boundary, which keeps `https://wordpress.org/...` links intact, and removal of the modern emoji markup) **and** `host:port` in the wget `--domains` list (the list is built without ports — wget matches the URL host without the port — while postprocess receives the original `host:port` list to rewrite the URLs). Evidence measured in this POC: the scrape log shows `[scrape] wget --domains: wordpress,...,localhost` (no port) and wget downloads the **35 content media files** referenced as `http://localhost:8300/...` (35 request lines), relying neither on the `jobs.py` literal-URL fallback (0 fallback downloads in this publish) nor on "hitchhiking" via the internal host.

Plugin screens in wp-admin:

- **Settings → Make it Static** — http://localhost:8300/wp-admin/options-general.php?page=make-it-static (**Test connection** button → `GET /health` **without signature**).
- **Make it Static** (side menu) — http://localhost:8300/wp-admin/admin.php?page=mis-jobs (job list, **Cancel**/**Retry** buttons, log hint on failure).

---

## Benchmark

Local head-to-head: the dynamic WordPress (Apache + PHP + MariaDB, `:8300`) vs the static site generated by the pipeline (nginx preview, `:8301`). Measured with Playwright (Chromium) running in Docker — see `docs/benchmark/` and reproduce with `make benchmark`.

**Methodology.** Pages: `/`, `/block-gallery/`, `/markup-image-alignment/`, `/category/block/`, `/media-category-blocks/` (the video page). Per target × page × profile: 1 warmup + 5 measured runs, each in a fresh browser context (cold cache); values are **medians**. Two profiles: `unthrottled` and `throttled` (~1.6 Mbps down / 750 Kbps up / 150 ms RTT + 4× CPU slowdown). Both sides serve **gzip** (the preview nginx gzips for parity with CloudFront edge compression in production). Bytes = `encodedDataLength` (wire size). Full per-page detail: [`docs/benchmark/results/results.md`](docs/benchmark/results/results.md).

**Overall (median of the 5 page medians):**

| Metric | Profile | WordPress (dynamic) | Static | Δ% |
|---|---|---|---|---|
| Requests | unthrottled | 13 | 9 | **−30.8%** |
| Requests | throttled | 13 | 8 | **−38.5%** |
| Bytes (wire) | both | 681.9 KB | 667.5 KB | −2.0% |
| TTFB | unthrottled | 38 ms | 5 ms | **−85.9%** |
| TTFB | throttled | 38 ms | 6 ms | **−83.0%** |
| FCP | unthrottled | 80 ms | 48 ms | **−40.0%** |
| LCP | unthrottled | 80 ms | 48 ms | **−40.0%** |
| DOMContentLoaded | unthrottled | 79 ms | 31 ms | **−60.1%** |
| Load | unthrottled | 79 ms | 36 ms | **−53.9%** |
| Load | throttled | 3701 ms | 3639 ms | −1.7% |

**What the numbers say.** The static site wins on every structural metric: **−86% TTFB** (no PHP/DB on the request path), **~−33% requests** (bundled CSS/JS), and roughly **halved render times** unthrottled. The **payload gain is content-dependent**: the overall −2% is dominated by the home/category pages, whose large featured images are already well-compressed JPEGs (AVIF saves little on those, e.g. 238.7 KB → 234.9 KB); image-heavy pages gain far more (`/block-gallery/` −33.8%, `/markup-image-alignment/` −42.6%).

**Video page (`/media-category-blocks/`).** The measured page delta is large — **−45.1% bytes / −16.1% requests / −40.1% load** unthrottled (−46.8% / −18.5% / −33.4% throttled) — but it is driven by the page's **images** (AVIF: 1.12 MB → 647 KB), **not** by the video. On a cold, non-interacting load the browser transfers **~0 video bytes on both sides**: the WP `.mov` is unplayable in Chromium (QuickTime) — and, in the containerized harness, its absolute `localhost:8300` URL resolves to the browser container itself, so it is not even fetched — while the static `.webm` is only probed (`preload="metadata"`: the 206 responses are aborted before the body). The video's real payload delta is **file-level** (bucket/build report): **29,881,426 B → 11,241,397 B (−62.4%)**, realized only when a visitor presses play — and then only the static can play it at all, since Chromium does not decode `.mov`. So the conversion is both a **−62.4% payload** win and a **compatibility** win (the video now plays in any modern browser).

**Honest caveats.**

- The dynamic WP here is a **local Docker** install — faster than typical shared hosting. Payload and request-count gains are exact; server-time gains (TTFB, Load) are **indicative**, and would be *larger* against a real hosted WP.
- Under throttling, static FCP/DCL came out marginally **behind** on some pages (+5.3%/+4.9% overall, ~50 ms): the bundled JS loses the `defer` attribute during bundling and ships render-blocking at the end of `<head>`, while the theme's scripts are deferred. Load (−1.7%) and LCP (−12.2%) still favor static. Keeping `defer` on the bundle is a candidate service-side improvement.

---

## Day to day

| Command | What it does |
|---|---|
| `make help` | Lists the available targets (default target) |
| `make up` | Starts the full stack (ensures the network, requires `.env`, validates ports 8300–8304, pulls the service images) |
| `make pull` | Updates the service images (`driedel/make-it-static-*:${MIS_VERSION}`) |
| `make down` | Stops and removes the containers (keeps volumes/data) |
| `make clean` | **Deletes everything**, including volumes (database, S3 bucket, uploads) |
| `make ps` | Container status |
| `make seed` | Populates WP with test content (`make seed FORCE=1` to run again) |
| `make health` | API `GET /health` |
| `make logs-api` | API logs (follow) |
| `make logs-worker` | Worker logs (follow) |
| `make logs-cron` | WP-Cron sidecar logs (follow) |
| `make publish` | Creates and publishes a dated post → fires the real flow (15s debounce) |
| `make publish-site` | Publishes the whole site now (`MIS_Publisher::publish_now(0)`); prints the job row id or `WP_Error` |
| `make jobs` | Last 10 jobs from the `wp_mis_jobs` table |
| `make bucket-ls` | Recursively lists the `my-static-site` bucket on LocalStack |
| `make preview` | Preview HTTP status (`:8301`) + hint to open in the browser |
| `make benchmark` | Runs the WP vs static benchmark (Playwright in Docker) and regenerates `docs/benchmark/results/results.md` |
| `make cron-run` | Forces `wp cron event run --due-now` now |
| `make break-secret` | Writes a wrong HMAC secret into `wp-config.php` (scenario 1) |
| `make fix-secret` | Restores the correct HMAC secret (read from `.env`) |
| `make stop-api` | Stops the API (scenario 2) |
| `make start-api` | Starts the API again |

Typical flow: `make publish` → wait ~1 min → `make jobs` (status `finished`) → `make bucket-ls` → `make preview`.

---

## Failure scenarios

### 1. Wrong HMAC secret (401 `bad signature`)

```bash
make break-secret    # writes MAKE_IT_STATIC_HMAC_SECRET=poc-wrong-secret into wp-config.php
make publish-site    # must print a WP_Error with 'bad signature' (the plugin handles the 401)
make fix-secret      # restores the correct secret, read from .env
```

> **Note:** the **Test connection** button uses `GET /health` **without signature**, so it passes even with the wrong secret — the 401 only shows up on publish.

### 2. API down

```bash
make stop-api
```

- On the **Settings → Make it Static** screen (http://localhost:8300/wp-admin/options-general.php?page=make-it-static), click **Test connection**: a friendly `Connection failed: ...` message must appear.
- `make publish-site` must return a connection `WP_Error`.

```bash
make start-api       # brings the service back
```

### 3. Failed job + retry

Break the scrape by pointing `scrape_url_base` at a dead port and zero out the retries:

```bash
docker compose exec -T wpcli wp --allow-root --path=/var/www/html option update mis_settings --format=json '{"api_base_url":"http://make-it-static-api:8000","scrape_url_base":"http://wordpress:9999","cloudfront_distribution_id":"","extra_cdn":"wpthemetestdata.files.wordpress.com","options":{"bundle_css":true,"bundle_js":true,"compress_images":true,"compress_html":true,"convert_fonts":true},"retry_count":0,"debounce_interval":15,"post_types":["post","page"],"hmac_secret":""}'
```

Fire and follow until `failed`:

```bash
make publish-site    # note the printed ROW_ID
make jobs            # repeat until the status becomes 'failed'
```

The jobs screen (http://localhost:8300/wp-admin/admin.php?page=mis-jobs) shows the failure with a **log hint**. Restore the correct settings:

```bash
docker compose exec -T wpcli wp --allow-root --path=/var/www/html option update mis_settings --format=json '{"api_base_url":"http://make-it-static-api:8000","scrape_url_base":"http://wordpress","cloudfront_distribution_id":"","extra_cdn":"wpthemetestdata.files.wordpress.com","options":{"bundle_css":true,"bundle_js":true,"compress_images":true,"compress_html":true,"convert_fonts":true},"retry_count":3,"debounce_interval":15,"post_types":["post","page"],"hmac_secret":""}'
```

> **Warning — Retry re-uses the stored payload:** `MIS_Publisher::republish_row()` re-POSTs the payload **stored in the row** (with the broken `http://wordpress:9999/` URL), so retrying a failure caused by the *payload* fails again — retry was designed for *transient* failures (unstable worker/S3), where the payload remains valid. For the row to fail again and then reach `finished`, fix the stored payload before retrying:

```bash
# Fixes the URL in the row's stored payload and fires the retry (replace <ROW_ID>)
docker compose exec -T wpcli wp --allow-root --path=/var/www/html eval '
$row = MIS_Job_Store::get(<ROW_ID>);
$payload = $row["payload"];
$payload["url"] = "http://wordpress/";
MIS_Job_Store::update(<ROW_ID>, array("url" => "http://wordpress/", "payload" => $payload));
var_dump(MIS_Publisher::republish_row(MIS_Job_Store::get(<ROW_ID>)));
'
```

Follow `make jobs` until `finished` (or click **Retry** on the jobs screen after fixing the payload).

---

## Repository structure

```
make-it-an-poc/
├── docker-compose.yml          # stack: wordpress, wpcli, cron, db, redis, api, worker, localstack, preview
├── .env                        # local secrets/config — do NOT commit (in .gitignore)
├── .env.example                # .env template (HMAC_SECRET with placeholder)
├── Makefile                    # day-to-day automation — make help
├── README.md                   # this file
├── AGENTS.md                   # guide for AI coding agents
├── config/
│   ├── seed/
│   │   └── seed.sh             # populates WP: imports content, activates the plugin, writes mis_settings
│   ├── localstack/
│   │   └── init-s3.sh          # creates the my-static-site bucket at LocalStack boot
│   └── nginx/
│       └── default.conf.template # preview nginx template (:8301 → S3)
└── docs/
    ├── make-it-an-poc-*.svg    # logos (light/dark) used at the top of this README
    ├── benchmark-article.pt-BR.md  # DRAFT blog post about the benchmark + the E2E-found bugs
    └── benchmark/
        ├── measure.mjs         # Playwright/CDP measurement (runs in the mcr.microsoft.com/playwright container)
        ├── report.mjs          # generates results/results.md from the JSONs
        ├── package.json        # playwright pinned to the image version (node_modules is gitignored)
        └── results/            # one JSON per target×profile + results.md (committed evidence)
```

`config/localstack/init-s3.sh` and `config/nginx/default.conf.template` were **copied from the service clone** (`../make-it-static`) so the POC is self-contained.

## Troubleshooting

- **Port in use**: `make up` validates ports 8300–8304 and tells you which one is taken. Stop the conflicting process (including the `make-it-static` dev stack) and try again.
- **Running a different service version**: set `MIS_VERSION` in `.env` and run `make pull && docker compose up -d`.
- **Local service build (development)**: uncomment the `build:` lines of `make-it-static-api`/`make-it-static-worker` in `docker-compose.yml` (and comment out `image:`), which requires the `../make-it-static` clone; then `docker compose up --build -d`.
- **View logs**: `make logs-worker` (scrape/upload), `make logs-api`, `make logs-cron`.
- **Full reset**: `make clean && make up && make seed`.
- **Where the jobs live**: in wp-admin, side menu **Make it Static** (http://localhost:8300/wp-admin/admin.php?page=mis-jobs); in the database, table `wp_mis_jobs` (shortcut: `make jobs`).
- **Cron looks stuck**: WP-Cron only fires via the `cron` sidecar (30s loop) or manually with `make cron-run`.
