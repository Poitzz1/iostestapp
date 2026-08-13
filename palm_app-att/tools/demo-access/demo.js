#!/usr/bin/env node
/**
 * PalmPay — staff demo access, server-side lock.
 *
 * Opening the attendance flow for a demo takes TWO locks. This script owns the
 * second one; the first is a client flag.
 *
 *   1. CLIENT   lib/config/app_mode.dart -> AppMode.staffDemoOpen
 *   2. SERVER   config/pilot.sections in PRODUCTION Firestore  <- this script
 *
 * `submitAttendance` rejects any student whose section is not in that list
 * (`section_not_in_pilot`), so widening the client gate alone demos nothing —
 * every submission still bounces.
 *
 * ── THE REVERT IS THE POINT ───────────────────────────────────────────────
 * Before widening, the current value is saved to `config/pilot.demo_backup`
 * IN THE SAME DOCUMENT SET, so `--close` restores exactly what was there
 * rather than guessing at a "default". A demo left open for a term is the
 * failure mode this guards against; there is no way to close it that requires
 * remembering what the list used to be.
 *
 * ── USAGE ─────────────────────────────────────────────────────────────────
 *   node demo.js --status
 *   node demo.js --open --sections "AIML-A,AIML-B"
 *   node demo.js --close
 *
 * Credentials: a PRODUCTION service-account key (project attcit-52e7d), via
 *   --key <path>   or   env PRODUCTION_SERVICE_ACCOUNT
 *
 * If you do not have one, the same two edits can be made by hand in the
 * Firebase console — see README.md in this directory.
 */

const fs = require('node:fs');
const path = require('node:path');

const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const PRODUCTION_PROJECT = 'attcit-52e7d';
// This project's Firestore database is literally named `default`, NOT the
// conventional `(default)` — mirrors lib/services/firestore_ref.dart and the
// "database" key in firebase.json. A bare getFirestore() fails with NOT_FOUND.
const PRODUCTION_DATABASE = 'default';
const PILOT_DOC = 'config/pilot';

const argv = process.argv.slice(2);
const has = (f) => argv.includes(`--${f}`);
const val = (f, d) => {
  const i = argv.indexOf(`--${f}`);
  return i === -1 ? d : argv[i + 1];
};

const KEY_PATH = val('key') || process.env.PRODUCTION_SERVICE_ACCOUNT;

function die(msg) {
  console.error(msg);
  process.exit(1);
}

async function main() {
  if (!KEY_PATH || !fs.existsSync(KEY_PATH)) {
    die(
      'A PRODUCTION service-account key is required.\n' +
        '  --key <path>  or  PRODUCTION_SERVICE_ACCOUNT=<path>\n\n' +
        'Firebase console → Project settings → Service accounts →\n' +
        'Generate new private key (project ' + PRODUCTION_PROJECT + ').\n' +
        'Save it OUTSIDE the repo, or under a gitignored secrets/ folder.\n\n' +
        'No key? Do it by hand in the console — see README.md here.'
    );
  }

  const sa = JSON.parse(fs.readFileSync(path.resolve(KEY_PATH), 'utf8'));
  if (sa.project_id !== PRODUCTION_PROJECT) {
    die(
      `REFUSING TO RUN: key is for "${sa.project_id}", expected ` +
        `"${PRODUCTION_PROJECT}". This script edits the production pilot ` +
        `allowlist and must not be pointed anywhere else.`
    );
  }

  initializeApp({ credential: cert(sa) });
  const db = getFirestore(PRODUCTION_DATABASE);
  const ref = db.doc(PILOT_DOC);

  const snap = await ref.get();
  const data = snap.exists ? snap.data() : {};
  const sections = data.sections || [];
  const backup = data.demo_backup;

  const show = (label) =>
    console.log(
      `  ${label.padEnd(18)} ${JSON.stringify(sections)}` +
        (backup !== undefined ? `   [demo open — pre-demo value: ${JSON.stringify(backup)}]` : '')
    );

  // ── status ────────────────────────────────────────────────────────────────
  if (has('status') || (!has('open') && !has('close'))) {
    console.log(`\n${PILOT_DOC} in ${PRODUCTION_PROJECT}/${PRODUCTION_DATABASE}\n`);
    show('sections');
    console.log(
      backup !== undefined
        ? '\n  ⚠️  DEMO ACCESS IS CURRENTLY OPEN. Run --close to restore.\n'
        : '\n  Pilot lockdown is in force (no demo backup present).\n'
    );
    console.log('  Remember the CLIENT lock too: AppMode.staffDemoOpen\n');
    return;
  }

  // ── open ──────────────────────────────────────────────────────────────────
  if (has('open')) {
    const raw = val('sections');
    if (!raw) {
      die('--open requires --sections "SEC-A,SEC-B" (the demo section names).');
    }
    const wanted = raw.split(',').map((s) => s.trim()).filter(Boolean);
    if (wanted.length === 0) die('--sections parsed to an empty list.');

    if (backup !== undefined) {
      console.log(
        '\n  Demo access is ALREADY open. Refusing to overwrite the saved\n' +
          `  pre-demo value (${JSON.stringify(backup)}) — that is the only\n` +
          '  record of what to restore. Run --close first if you need to\n' +
          '  re-open with different sections.\n'
      );
      return;
    }

    // Union, not replace: a demo must not silently drop sections that were
    // legitimately in the pilot already.
    const merged = [...new Set([...sections, ...wanted])];

    await ref.set(
      {
        sections: merged,
        demo_backup: sections, // exact pre-demo value, for --close
        demo_opened_at: new Date().toISOString(),
      },
      { merge: true }
    );

    console.log(`\n  DEMO ACCESS OPENED in ${PRODUCTION_PROJECT}\n`);
    console.log(`  was      ${JSON.stringify(sections)}`);
    console.log(`  now      ${JSON.stringify(merged)}`);
    console.log(`  added    ${JSON.stringify(wanted.filter((s) => !sections.includes(s)))}`);
    console.log(
      '\n  STILL TO DO — the client lock:\n' +
        '    lib/config/app_mode.dart -> staffDemoOpen = true, then rebuild.\n' +
        '\n  AFTER THE DEMO — both locks:\n' +
        '    node demo.js --close\n' +
        '    staffDemoOpen = false\n'
    );
    return;
  }

  // ── close ─────────────────────────────────────────────────────────────────
  if (has('close')) {
    if (backup === undefined) {
      console.log(
        '\n  No demo backup found — the server lock is already in its\n' +
          `  pilot state: ${JSON.stringify(sections)}\n` +
          '\n  Check the CLIENT lock as well: staffDemoOpen must be false.\n'
      );
      return;
    }

    const { FieldValue } = require('firebase-admin/firestore');
    await ref.set(
      {
        sections: backup,
        demo_backup: FieldValue.delete(),
        demo_opened_at: FieldValue.delete(),
        demo_closed_at: new Date().toISOString(),
      },
      { merge: true }
    );

    console.log(`\n  DEMO ACCESS CLOSED in ${PRODUCTION_PROJECT}\n`);
    console.log(`  was      ${JSON.stringify(sections)}`);
    console.log(`  restored ${JSON.stringify(backup)}`);
    console.log(
      '\n  STILL TO DO — the client lock:\n' +
        '    lib/config/app_mode.dart -> staffDemoOpen = false, then rebuild.\n' +
        '    (While it is true, every screen shows the red DEMO MODE banner.)\n'
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
