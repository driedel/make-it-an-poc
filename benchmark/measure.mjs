// Benchmark: dynamic WordPress (Apache) vs static site (nginx preview).
// Runs inside the mcr.microsoft.com/playwright container — no host Node required.
//
// For each target × page × profile: 1 warmup + N measured runs, each in a fresh
// browser context (cold cache). Collects, per run:
//   - requests: total and by resource type (CDP Network domain)
//   - bytes transferred: encodedDataLength (wire size, gzip included), total and by type
//   - TTFB (responseStart), DOMContentLoaded, Load (Navigation Timing)
//   - FCP and LCP (PerformanceObserver, buffered; LCP may be null)
// Writes one JSON per target × profile into benchmark/results/.

import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);

// The official image ships playwright globally; resolve it robustly.
let chromium = null;
for (const candidate of [
  'playwright',
  '/usr/lib/node_modules/playwright',
  '/usr/local/lib/node_modules/playwright',
  process.env.PLAYWRIGHT_MODULE || '',
].filter(Boolean)) {
  try {
    chromium = require(candidate).chromium;
    break;
  } catch {
    // try next candidate
  }
}
if (!chromium) {
  console.error('Could not resolve the playwright module. Set PLAYWRIGHT_MODULE or NODE_PATH.');
  process.exit(1);
}

const RUNS_PER_PAGE = 5;
const PAGES = ['/', '/block-gallery/', '/markup-image-alignment/', '/category/block/', '/media-category-blocks/'];
const PROFILES = {
  unthrottled: null,
  throttled: {
    // ~1.6 Mbps down / 750 Kbps up / 150 ms RTT + 4x CPU slowdown (Fast 3G-ish).
    network: {
      latency: 150,
      downloadThroughput: Math.floor((1.6 * 1e6) / 8),
      uploadThroughput: Math.floor((750 * 1e3) / 8),
    },
    cpuSlowdownRate: 4,
  },
};

const RESULTS_DIR = path.resolve(process.cwd(), 'benchmark/results');

function median(values) {
  const nums = values.filter((v) => typeof v === 'number' && !Number.isNaN(v)).sort((a, b) => a - b);
  if (nums.length === 0) return null;
  const mid = Math.floor(nums.length / 2);
  return nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
}

async function resolveBaseHost() {
  // host.docker.internal is mapped via --add-host on docker run; fall back to the
  // default gateway if it does not answer.
  const candidates = ['host.docker.internal'];
  try {
    const gw = execSync("ip route | awk '/default/ {print $3; exit}'").toString().trim();
    if (gw) candidates.push(gw);
  } catch {
    // no `ip` in the image — ignore
  }
  for (const host of candidates) {
    for (const port of [8300, 8301]) {
      try {
        const res = await fetch(`http://${host}:${port}/`, { signal: AbortSignal.timeout(4000) });
        if (res.ok) {
          console.log(`[setup] reachable host: ${host} (validated on :${port})`);
          return host;
        }
      } catch {
        // try next
      }
    }
  }
  throw new Error(`Neither ${candidates.join(', ')} answered on 8300/8301`);
}

async function measureRun(browser, url, profile) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);

  const requests = { total: 0, byType: {} };
  const bytes = { total: 0, byType: {} };
  const typeOf = {};
  const pending = new Map();

  await cdp.send('Network.enable');
  cdp.on('Network.requestWillBeSent', (e) => {
    const type = (e.type || 'other').toLowerCase();
    typeOf[e.requestId] = type;
    requests.total += 1;
    requests.byType[type] = (requests.byType[type] || 0) + 1;
    pending.set(e.requestId, type);
  });
  cdp.on('Network.loadingFinished', (e) => {
    const type = pending.get(e.requestId) || typeOf[e.requestId] || 'other';
    bytes.total += e.encodedDataLength || 0;
    bytes.byType[type] = (bytes.byType[type] || 0) + (e.encodedDataLength || 0);
    pending.delete(e.requestId);
  });

  if (profile && profile.network) {
    await cdp.send('Network.emulateNetworkConditions', {
      offline: false,
      latency: profile.network.latency,
      downloadThroughput: profile.network.downloadThroughput,
      uploadThroughput: profile.network.uploadThroughput,
    });
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: profile.cpuSlowdownRate });
  }

  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  // Let LCP settle (buffered entries are read right after).
  await page.waitForTimeout(600);

  const timing = await page.evaluate(() => {
    const nav = performance.getEntriesByType('navigation')[0] || {};
    const paints = performance.getEntriesByType('paint');
    const fcp = paints.find((p) => p.name === 'first-contentful-paint');
    return {
      ttfb: nav.responseStart ?? null,
      domContentLoaded: nav.domContentLoadedEventEnd ?? null,
      load: nav.loadEventEnd ?? null,
      fcp: fcp ? fcp.startTime : null,
    };
  });

  const lcp = await page.evaluate(
    () =>
      new Promise((resolve) => {
        let value = null;
        try {
          new PerformanceObserver((list) => {
            const entries = list.getEntries();
            if (entries.length) value = entries[entries.length - 1].startTime;
          }).observe({ type: 'largest-contentful-paint', buffered: true });
        } catch {
          resolve(null);
        }
        setTimeout(() => resolve(value), 300);
      }),
  );

  await context.close();
  return {
    requests,
    bytes,
    ttfb: timing.ttfb,
    domContentLoaded: timing.domContentLoaded,
    load: timing.load,
    fcp: timing.fcp,
    lcp,
  };
}

function summarizeRuns(runs) {
  const med = (pick) => median(runs.map(pick));
  const byTypeMedian = (group) => {
    const types = new Set(runs.flatMap((r) => Object.keys(r[group].byType)));
    const out = {};
    for (const t of types) out[t] = median(runs.map((r) => r[group].byType[t] || 0));
    return out;
  };
  return {
    requests: { total: med((r) => r.requests.total), byType: byTypeMedian('requests') },
    bytes: { total: med((r) => r.bytes.total), byType: byTypeMedian('bytes') },
    ttfb: med((r) => r.ttfb),
    domContentLoaded: med((r) => r.domContentLoaded),
    load: med((r) => r.load),
    fcp: med((r) => r.fcp),
    lcp: med((r) => r.lcp),
  };
}

function summarizeTarget(pages) {
  // Median of the per-page medians (the "overall" row of the report).
  const pageMedians = Object.values(pages).map((p) => p.median);
  const med = (pick) => median(pageMedians.map(pick));
  const byTypeMedian = (group) => {
    const types = new Set(pageMedians.flatMap((m) => Object.keys(m[group].byType)));
    const out = {};
    for (const t of types) out[t] = median(pageMedians.map((m) => m[group].byType[t] || 0));
    return out;
  };
  return {
    requests: { total: med((m) => m.requests.total), byType: byTypeMedian('requests') },
    bytes: { total: med((m) => m.bytes.total), byType: byTypeMedian('bytes') },
    ttfb: med((m) => m.ttfb),
    domContentLoaded: med((m) => m.domContentLoaded),
    load: med((m) => m.load),
    fcp: med((m) => m.fcp),
    lcp: med((m) => m.lcp),
  };
}

async function main() {
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const host = await resolveBaseHost();
  const targets = {
    wp: `http://${host}:8300`,
    static: `http://${host}:8301`,
  };

  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const startedAt = new Date().toISOString();

  for (const [targetName, baseUrl] of Object.entries(targets)) {
    for (const [profileName, profile] of Object.entries(PROFILES)) {
      const out = {
        target: targetName,
        baseUrl,
        profile: profileName,
        startedAt,
        runsPerPage: RUNS_PER_PAGE,
        pages: {},
      };
      for (const pagePath of PAGES) {
        const url = baseUrl + pagePath;
        // Warmup (not measured).
        await measureRun(browser, url, profile);
        const runs = [];
        for (let i = 0; i < RUNS_PER_PAGE; i += 1) {
          runs.push(await measureRun(browser, url, profile));
        }
        out.pages[pagePath] = { runs, median: summarizeRuns(runs) };
        console.log(
          `[${targetName}/${profileName}] ${pagePath} — median: ${out.pages[pagePath].median.requests.total} req, ` +
            `${out.pages[pagePath].median.bytes.total} B, load ${Math.round(out.pages[pagePath].median.load)} ms`,
        );
      }
      out.summary = summarizeTarget(out.pages);
      const file = path.join(RESULTS_DIR, `${targetName}-${profileName}.json`);
      fs.writeFileSync(file, JSON.stringify(out, null, 2));
      console.log(`[done] ${file}`);
    }
  }

  await browser.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
