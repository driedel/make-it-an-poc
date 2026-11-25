# AGENTS.md — Make it Static · E2E POC

Guide for AI coding agents working in this repository. Project language: **English** for documentation (README, AGENTS.md), following the `make-it-static` repo standard. Makefile target descriptions and seed script messages are currently in Portuguese.

## Project overview

This repository contains **no application source code** (no `package.json`, `pyproject.toml`, `Cargo.toml` etc.). It is a **100% Docker end-to-end test POC** that orchestrates — via `docker-compose.yml` + `Makefile` + seed scripts — the communication between:

- the **Make it Static** WordPress plugin (HTTP client, bind-mounted from a sibling clone at `../make-it-static-wp-plugin`);
- and the **Make it Static** service (FastAPI API + RQ worker + Redis + S3 via LocalStack + preview nginx), consumed as **pre-built Docker Hub images** (`driedel/make-it-static-api` and `driedel/make-it-static-worker`, tag `MIS_VERSION` from `.env`, default `0.2.2` — tags do **not** carry the `v` prefix).

Covered E2E flow: publishing a post in WordPress fires a **signed** `POST /publish` (HMAC-SHA256 of the raw body + `X-Timestamp` header) to the API; a WP-Cron poller checks the status every 30s; the worker scrapes the site over the internal network with `wget`, optimizes the assets, and uploads the static site to the S3 bucket (`my-static-site`, prefix `wordpress/`), served by the preview nginx on port 8301.

## Runtime stack and architecture

Services in `docker-compose.yml` (compose project name: `mis-poc`):

| Service | Image | Host port | Role |
|---|---|---|---|
| `db` | `mariadb:11` | 8304→3306 | WordPress database |
| `wordpress` | `wordpress:6-apache` | 8300→80 | WP site + plugin via bind mount |
| `wpcli` | `wordpress:cli` | — | Idle container (`sleep infinity`) for WP-CLI |
| `cron` | `wordpress:cli` | — | Sidecar: 30s loop with `wp cron event run --due-now` |
| `redis` | `redis:7-alpine` | — | RQ queue |
| `make-it-static-api` | `driedel/make-it-static-api:${MIS_VERSION}` | 8302→8000 | FastAPI (`/health` → `{"ok":true,"redis":true}`) |
| `make-it-static-worker` | `driedel/make-it-static-worker:${MIS_VERSION}` | — | Scrape (wget) + optimize + S3 upload |
| `localstack` | `localstack/localstack:4.6.0` | 8303→4566 | Local S3 |
| `preview` | `nginx:1.30-alpine` | 8301→80 | Serves the S3 bucket |

Important structural points:

- **External network `make-it-static-network`**: shared with the Make it Static ecosystem; must exist before `up` (`make up` creates it automatically). `wordpress`, `api` and `worker` join it.
- **`cron` sidecar**: containers without HTTP traffic do not trigger WP-Cron on their own; the sidecar wakes both the debounced publish (15s) and the status poller (30s).
- **`wpcli` and `cron` run as `user: "33:33"`**: the `wp_data` volume is created by the Debian image (`www-data`=33); in the Alpine `wordpress:cli` image `www-data` is 82 and would not be able to write to the volume.
- **Dynamic `WORDPRESS_CONFIG_EXTRA`**: `WP_HOME`/`WP_SITEURL` derived from the request's `HTTP_HOST` (the worker scrapes `http://wordpress` and the HTML carries the `wordpress` host; the browser at `localhost:8300` sees `localhost:8300`), plus `WP_AUTO_UPDATE_CORE=false`. The YAML block (`x-wordpress-config-extra`) is shared by anchor across `wordpress`, `wpcli` and `cron` — in the CLI containers it is required for the WP-CLI context.
- **`extra_hosts: ["localhost:host-gateway"]` shim on the worker**: in production the public host is reachable by the worker; in the POC the "public host" is the machine's `localhost:8300`, and this shim emulates that condition (the `post_content` keeps absolute `http://localhost:8300/...` URLs like a real WordPress — the database is **not** rewritten).
- **`localstack/init-s3.sh`** creates the `my-static-site` bucket and allows anonymous reads at boot; **`nginx/default.conf.template`** rewrites `/path/` → `/{bucket}/{ORIGIN_HOST}/path/index.html` via `envsubst`. Both were copied from the service repo so the POC is self-contained.

## Prerequisites to run

- Docker Desktop with `docker compose` v2.
- **Sibling clone of the plugin** at `../make-it-static-wp-plugin` (bind-mounted at `wp-content/plugins/make-it-static`).
- Ports **8300–8304 free**; `make-it-static` dev stack stopped (port and network conflicts).
- `.env` created from `.env.example`, with `HMAC_SECRET` generated via `openssl rand -hex 32`.

## Commands (build, test and operation)

There is no build and no automated test suite — "verification" is the manual E2E flow via the Makefile. Default target: `make help`.

| Command | What it does |
|---|---|
| `make up` | Starts the stack (creates the network, requires `.env`, validates ports 8300–8304) |
| `make pull` | Updates the service images (`driedel/make-it-static-*:${MIS_VERSION}`) and recreates |
| `make down` / `make clean` | Stops containers / **also deletes volumes** (database, bucket, uploads) |
| `make ps` | Container status |
| `make seed` | Populates WP with test content (idempotent; `make seed FORCE=1` rebuilds from scratch) |
| `make health` | API `GET /health` |
| `make publish` | Creates and publishes a dated post → fires the real flow (15s debounce) |
| `make publish-site` | Publishes the whole site now (`MIS_Publisher::publish_now(0)`); prints the row id or `WP_Error` |
| `make jobs` | Last 10 jobs from the `wp_mis_jobs` table |
| `make bucket-ls` | Lists the `my-static-site` bucket on LocalStack |
| `make preview` | Preview HTTP status (`:8301`) |
| `make cron-run` | Forces `wp cron event run --due-now` now |
| `make logs-api` / `logs-worker` / `logs-cron` | Follows service logs |
| `make break-secret` / `fix-secret` | Failure scenario 1: wrong HMAC secret (401 `bad signature`) / restore |
| `make stop-api` / `start-api` | Failure scenario 2: API down / recovery |

Typical validation flow: `make up` → `make seed` → `make publish` → wait ~1 min → `make jobs` (status `finished`) → `make bucket-ls` → `make preview`.

## Project conventions

- **Language**: English in docs (README, AGENTS.md); Makefile/seed user-facing messages are currently in Portuguese.
- **`.env` is never committed** (it is in `.gitignore`); `.env.example` is the template. The `HMAC_SECRET` never appears in the `mis_settings` option or the database: the seed writes the `MAKE_IT_STATIC_HMAC_SECRET` constant as a **literal define** in `wp-config.php` (`wp config set`) — not via `WORDPRESS_CONFIG_EXTRA` eval — so that `make break-secret`/`fix-secret` can overwrite it.
- **Compose**: `$$` escapes to a literal `$` (expanded by the container shell or the wp-config `eval()`); the `x-wordpress-config-extra` block is a shared YAML anchor; `env_file: .env` only on the Make it Static service containers + localstack/preview (the WordPress containers receive `HMAC_SECRET` only via `environment`, to avoid exposing the whole `.env`).
- **Seed (`seed/seed.sh`)**: runs inside the `wpcli` container; idempotent via the `mis_poc_seeded` option; **deliberately no `set -e`** (network/download failures are tolerated; critical steps use `die()`). Imports the WordPress Theme Unit Test Data, **removes posts with Query Loop blocks** (`wp:query` — their `?query-N-page=M` pagination is an infinite crawl trap for the worker's `wget --level=0`) and **trims to the 25 most recent posts / 8 pages** (the full test data would blow the worker's 300s scrape timeout). Configures `/%postname%/` permalinks, `posts_per_page=25`, twentytwentyone theme, primary menu, and the `mis_settings` option pointing to the internal API (with `extra_cdn=wpthemetestdata.files.wordpress.com`).
- **Service versions**: controlled by `MIS_VERSION` in `.env`; changing the version = `make pull && docker compose up -d`. A local service build (development) is possible by uncommenting the commented `build:` lines in the compose file (requires the `../make-it-static` clone).

## Testing

There is no test framework. Validation is the manual E2E described above, plus the **failure scenarios documented in the README**:

1. **Wrong HMAC secret** — `make break-secret` → `make publish-site` must return a `WP_Error` with `bad signature` (HTTP 401) → `make fix-secret`. Note: the **Test connection** button uses `GET /health` without signature, so it passes even with the wrong secret.
2. **API down** — `make stop-api`; Test connection must fail with a friendly message; `make publish-site` returns a connection `WP_Error`.
3. **Failed job + retry** — break `scrape_url_base` in the settings; **Retry re-uses the payload stored in the row** (`MIS_Publisher::republish_row()`), so retrying a payload-caused failure fails again — the stored payload must be fixed before retrying (`wp eval` snippet in the README).

Where to observe: jobs screen at `http://localhost:8300/wp-admin/admin.php?page=mis-jobs`, `wp_mis_jobs` table, logs via `make logs-*`.

## Security

- `.env` contains the HMAC secret and local credentials — **never commit it** (already in `.gitignore`).
- Test credentials (do not use outside the POC): WP admin `admin` / `mis-poc-2026`; MariaDB `wordpress`/`wordpress` (root: `rootpassword`); LocalStack accepts any credential.
- The `/publish` signature is HMAC-SHA256 of the raw body + `X-Timestamp` header (`HMAC_MAX_SKEW=300`); the S3 bucket has anonymous read only so the local preview works — **dev-only** configuration.

## Repository structure

```
make-it-an-poc/
├── docker-compose.yml          # full stack (9 services)
├── .env / .env.example         # local config / template (never commit .env)
├── Makefile                    # day-to-day automation — make help
├── README.md                   # detailed documentation (flow, failure scenarios, troubleshooting)
├── AGENTS.md                   # this file
├── seed/
│   └── seed.sh                 # populates WP: imports content, activates the plugin, writes mis_settings
├── localstack/
│   └── init-s3.sh              # creates the my-static-site bucket at LocalStack boot
└── nginx/
    └── default.conf.template   # preview nginx template (:8301 → S3)
```

Related repositories (sibling clones in the same parent directory): `../make-it-static-wp-plugin` (the plugin, **required** to run) and `../make-it-static` (the service, optional — only for developing/locally building the images).

## Known pitfalls (do not "fix" without understanding why)

- **Do not rewrite URLs in the database**: `post_content` deliberately keeps absolute `http://localhost:8300/...` URLs — that is real WordPress behavior, and the flow (plugin adds the `home_url()` host to `extra_cdn`; `host-gateway` shim on the worker) handles it end to end.
- **Do not reintroduce `wp:query` posts** in the seed: they blow the scrape timeout.
- **Do not move `MAKE_IT_STATIC_HMAC_SECRET` into `WORDPRESS_CONFIG_EXTRA`**: the literal define in `wp-config.php` is a requirement of the `break-secret`/`fix-secret` targets.
- **Do not change `user: "33:33"`** on `wpcli`/`cron`: it breaks writes to the `wp_data` volume.
- A job result **expires after ~1h** server-side (`expired` status); the poller runs every 30s and the publish has a 15s debounce — when debugging, wait ~1 min before concluding something failed.
