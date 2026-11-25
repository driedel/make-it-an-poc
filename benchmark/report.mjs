// Reads benchmark/results/*.json and writes benchmark/results/results.md with
// comparative tables (WP vs static, Δ% per metric) per profile plus an overall
// summary table (median of the page medians).

import fs from 'node:fs';
import path from 'node:path';

const RESULTS_DIR = path.resolve(process.cwd(), 'benchmark/results');
const PAGES = ['/', '/block-gallery/', '/markup-image-alignment/', '/category/block/', '/media-category-blocks/'];
const PROFILES = ['unthrottled', 'throttled'];

function fmtBytes(n) {
  if (n == null) return '—';
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)} MB`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`;
  return `${Math.round(n)} B`;
}

function fmtMs(n) {
  if (n == null) return '—';
  return `${Math.round(n)} ms`;
}

function fmtInt(n) {
  if (n == null) return '—';
  return String(Math.round(n));
}

// Δ% of static vs wp (negative = static is better/smaller).
function delta(wp, stat) {
  if (wp == null || stat == null || wp === 0) return '—';
  const pct = ((stat - wp) / wp) * 100;
  const sign = pct > 0 ? '+' : '';
  return `${sign}${pct.toFixed(1)}%`;
}

function load(target, profile) {
  const file = path.join(RESULTS_DIR, `${target}-${profile}.json`);
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

const METRICS = [
  ['Requests (total)', (m) => m.requests.total, fmtInt],
  ['Bytes (total, wire)', (m) => m.bytes.total, fmtBytes],
  ['TTFB', (m) => m.ttfb, fmtMs],
  ['FCP', (m) => m.fcp, fmtMs],
  ['LCP', (m) => m.lcp, fmtMs],
  ['DOMContentLoaded', (m) => m.domContentLoaded, fmtMs],
  ['Load', (m) => m.load, fmtMs],
];

const TYPE_ORDER = ['document', 'script', 'stylesheet', 'image', 'font', 'other'];

function typeRows(wp, stat, group, fmt) {
  const types = new Set([...Object.keys(wp[group].byType), ...Object.keys(stat[group].byType)]);
  const ordered = [...TYPE_ORDER.filter((t) => types.has(t)), ...[...types].filter((t) => !TYPE_ORDER.includes(t))];
  return ordered.map((t) => {
    const w = wp[group].byType[t] || 0;
    const s = stat[group].byType[t] || 0;
    return `| ${t} | ${fmt(w)} | ${fmt(s)} | ${delta(w, s)} |`;
  });
}

function main() {
  const lines = [];
  lines.push('# Benchmark results — dynamic WordPress vs static site');
  lines.push('');
  lines.push(`Generated: ${new Date().toISOString()}`);
  lines.push('');
  lines.push('Method: 1 warmup + 5 measured runs per target × page × profile, each run in a fresh');
  lines.push('browser context (cold cache). Values are medians. Bytes = `encodedDataLength` (wire');
  lines.push('size, gzip on both sides). Δ% = static vs WP (negative = static is smaller/faster).');
  lines.push('');

  for (const profile of PROFILES) {
    const wp = load('wp', profile);
    const stat = load('static', profile);
    if (!wp || !stat) {
      lines.push(`## Profile: ${profile}`);
      lines.push('');
      lines.push('_missing data_');
      lines.push('');
      continue;
    }

    lines.push(`## Profile: ${profile}`);
    lines.push('');
    lines.push(`### Overall (median of the ${PAGES.length} page medians)`);
    lines.push('');
    lines.push('| Metric | WordPress (dynamic) | Static | Δ% |');
    lines.push('|---|---|---|---|');
    for (const [label, pick, fmt] of METRICS) {
      const w = pick(wp.summary);
      const s = pick(stat.summary);
      lines.push(`| ${label} | ${fmt(w)} | ${fmt(s)} | ${delta(w, s)} |`);
    }
    lines.push('');
    lines.push('#### Requests by type (overall)');
    lines.push('');
    lines.push('| Type | WP | Static | Δ% |');
    lines.push('|---|---|---|---|');
    lines.push(...typeRows(wp.summary, stat.summary, 'requests', fmtInt));
    lines.push('');
    lines.push('#### Bytes by type (overall)');
    lines.push('');
    lines.push('| Type | WP | Static | Δ% |');
    lines.push('|---|---|---|---|');
    lines.push(...typeRows(wp.summary, stat.summary, 'bytes', fmtBytes));
    lines.push('');

    lines.push('### Per page (medians)');
    lines.push('');
    lines.push('| Page | Metric | WP | Static | Δ% |');
    lines.push('|---|---|---|---|---|');
    for (const page of PAGES) {
      const w = wp.pages[page]?.median;
      const s = stat.pages[page]?.median;
      if (!w || !s) continue;
      for (const [label, pick, fmt] of METRICS) {
        lines.push(`| ${page} | ${label} | ${fmt(pick(w))} | ${fmt(pick(s))} | ${delta(pick(w), pick(s))} |`);
      }
    }
    lines.push('');
  }

  const out = path.join(RESULTS_DIR, 'results.md');
  fs.writeFileSync(out, lines.join('\n'));
  console.log(`[done] ${out}`);
}

main();
