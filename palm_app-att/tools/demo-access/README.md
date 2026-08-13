# Staff demo access — open and close

Opening the attendance flow for a demo takes **two locks**. Both must be closed
again afterwards.

| # | Lock | Where | Effect if left open |
|---|---|---|---|
| 1 | `AppMode.staffDemoOpen` | `lib/config/app_mode.dart` (client) | Enrollment + attendance screens reachable by anyone |
| 2 | `config/pilot.sections` | production Firestore (server) | `submitAttendance` accepts the demo sections indefinitely |

Opening only #1 demos nothing — every submission still bounces with
`section_not_in_pilot`. Opening only #2 changes nothing visible — the screens
are still gated.

---

## Open

```bash
cd tools/demo-access
npm install                                    # once
node demo.js --open --sections "AIML-A"        # server lock
```

Then the client lock: set `staffDemoOpen = true` in
[`lib/config/app_mode.dart`](../../lib/config/app_mode.dart) and rebuild.

`--open` **merges** rather than replaces, so sections legitimately in the pilot
are not dropped, and it saves the exact pre-demo list to
`config/pilot.demo_backup`. It refuses to run twice, because a second run would
overwrite that saved value — the only record of what to restore.

## Close — do this immediately after the demo

```bash
node demo.js --close                           # restores the saved list exactly
```

Then set `staffDemoOpen = false` and rebuild.

## Check

```bash
node demo.js --status
```

Prints the current allowlist and warns loudly if a `demo_backup` is present,
which means demo access is still open.

---

## No production service-account key?

`config/pilot` is protected by the catch-all deny in `firestore.rules`
(no client can read or write it), so this needs Admin SDK credentials or the
console. To generate a key: Firebase console → Project settings → Service
accounts → Generate new private key, for project **`attcit-52e7d`**. Store it
outside the repo or under a gitignored `secrets/` folder — it is a full-access
production credential.

By hand in the console instead:

1. Firestore → `config` → `pilot`
2. Note the current `sections` value **somewhere you will not lose it**
3. Add the demo section(s) to the array
4. After the demo, set `sections` back to the noted value

The script exists mainly so step 2 cannot be skipped.

---

## Why the app shows a red banner during the demo

While `staffDemoOpen` is true, every screen carries a red
`DEMO MODE · recognition pipeline demonstration — not a secure system
(~14% false accepts)` bar.

It is deliberately unmissable, for two reasons:

- **Honesty.** The v4 model lets the wrong person through roughly one time in
  seven. Presenting that as working attendance security would misrepresent it.
  The framing stays on screen rather than being said once in an intro.
- **It is the real revert mechanism.** A code comment does not stop a temporary
  flag surviving a term. A red bar that whoever next opens the app cannot avoid
  seeing does.

Do not suppress it for the demo.
