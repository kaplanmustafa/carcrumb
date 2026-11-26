#!/usr/bin/env node
/**
 * Anonymises a CarCrumb debug sensor trace (JSON Lines) BEFORE it leaves your computer —
 * e.g. before giving it to an AI assistant or turning it into a test fixture.
 * Runs locally, makes no network calls.
 *
 *   node scripts/anonymize-trace.js <input.jsonl> <output.jsonl>
 *
 * What it does:
 * - Coordinates: every object with numeric `latitude` + `longitude` is converted to local
 *   metres around the first coordinate of the file, rotated by a random angle, and placed
 *   around the synthetic point 41.0 / -40.0 (open Atlantic). Distances between points are
 *   kept (to well under a metre over a city-sized area), so the state machine replays the
 *   same way; the real place and the real road shape's orientation are gone.
 * - Time: every epoch-seconds value (1e9..1e10) is shifted by a random whole number of days
 *   (30..400), so intervals and time of day stay, the real date does not.
 * - Everything else (speed, accuracy, motion activity, car link) is copied unchanged.
 *
 * Limits: the route's *shape* survives rotation; a long, distinctive route could in theory be
 * matched to a road network. Share the shortest segment that shows the problem.
 */
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');

const EARTH_RADIUS = 6_371_000;
const SYNTHETIC = { latitude: 41.0, longitude: -40.0 };
const SYNTHETIC_BOX = 0.1; // CI fixture box (CLAUDE.md); larger outputs must be cut before use as fixtures
const DAY = 86_400;

const rad = (d) => (d * Math.PI) / 180;
const deg = (r) => (r * 180) / Math.PI;

function isEpochSeconds(key, value) {
  return typeof value === 'number' && value >= 1e9 && value <= 1e10 && key !== 'latitude' && key !== 'longitude';
}

function findOrigin(value) {
  if (Array.isArray(value)) {
    for (const v of value) {
      const o = findOrigin(v);
      if (o) return o;
    }
  } else if (value && typeof value === 'object') {
    if (typeof value.latitude === 'number' && typeof value.longitude === 'number') {
      return { latitude: value.latitude, longitude: value.longitude };
    }
    for (const v of Object.values(value)) {
      const o = findOrigin(v);
      if (o) return o;
    }
  }
  return null;
}

/** Equirectangular local projection: exact enough (< 0.1 %) within tens of kilometres. */
function makeTransform(origin, angle) {
  const cosOrigin = Math.cos(rad(origin.latitude));
  const cosTarget = Math.cos(rad(SYNTHETIC.latitude));
  const cosA = Math.cos(angle);
  const sinA = Math.sin(angle);
  return ({ latitude, longitude }) => {
    const east = rad(longitude - origin.longitude) * EARTH_RADIUS * cosOrigin;
    const north = rad(latitude - origin.latitude) * EARTH_RADIUS;
    const e2 = east * cosA - north * sinA;
    const n2 = east * sinA + north * cosA;
    return {
      latitude: SYNTHETIC.latitude + deg(n2 / EARTH_RADIUS),
      longitude: SYNTHETIC.longitude + deg(e2 / (EARTH_RADIUS * cosTarget)),
    };
  };
}

function rewrite(value, transform, timeShift) {
  if (Array.isArray(value)) return value.map((v) => rewrite(v, transform, timeShift));
  if (!value || typeof value !== 'object') return value;
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = isEpochSeconds(k, v) ? v + timeShift : rewrite(v, transform, timeShift);
  }
  if (typeof value.latitude === 'number' && typeof value.longitude === 'number') {
    Object.assign(out, transform(value));
  }
  return out;
}

/**
 * Anonymises the lines of a trace. `random` is injectable for tests; defaults to crypto.
 * Returns the new lines and the largest distance (degrees) from the synthetic point.
 */
function anonymizeLines(lines, random = () => crypto.randomInt(0, 1_000_000) / 1_000_000) {
  const records = lines.filter((l) => l.trim() !== '').map((l, i) => {
    try {
      return JSON.parse(l);
    } catch {
      throw new Error(`line ${i + 1}: invalid JSON`); // never echo the line: it may hold coordinates
    }
  });
  const origin = records.map(findOrigin).find(Boolean) ?? SYNTHETIC;
  const transform = makeTransform(origin, random() * 2 * Math.PI);
  const timeShift = -(30 + Math.floor(random() * 371)) * DAY;
  let extent = 0;
  const out = records.map((r) => {
    const rewritten = rewrite(r, transform, timeShift);
    const visit = (v) => {
      if (Array.isArray(v)) return v.forEach(visit);
      if (!v || typeof v !== 'object') return;
      if (typeof v.latitude === 'number' && typeof v.longitude === 'number') {
        extent = Math.max(extent, Math.abs(v.latitude - SYNTHETIC.latitude), Math.abs(v.longitude - SYNTHETIC.longitude));
      }
      Object.values(v).forEach(visit);
    };
    visit(rewritten);
    return JSON.stringify(rewritten);
  });
  return { lines: out, extent };
}

module.exports = { anonymizeLines, SYNTHETIC, SYNTHETIC_BOX };

if (require.main === module) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) {
    console.error('usage: node scripts/anonymize-trace.js <input.jsonl> <output.jsonl>');
    process.exit(2);
  }
  if (input === output) {
    console.error('output must be a different file');
    process.exit(2);
  }
  try {
    const { lines, extent } = anonymizeLines(fs.readFileSync(input, 'utf8').split(/\r?\n/));
    fs.writeFileSync(output, lines.join('\n') + '\n');
    console.log(`anonymised ${lines.length} records → ${output}`);
    if (extent > SYNTHETIC_BOX) {
      console.log(`note: route spans ±${extent.toFixed(3)}° (> ±${SYNTHETIC_BOX}°); cut it to the relevant part before using it as a fixture`);
    }
  } catch (e) {
    console.error(`failed: ${e instanceof Error ? e.message : 'unknown error'}`);
    process.exit(1);
  }
}
