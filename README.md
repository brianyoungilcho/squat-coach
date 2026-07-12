# Squat Coach

A private macOS menu-bar coach for short movement breaks. Apple Vision counts squats on-device; optional social Packs share finished-set totals with verified members.

## What it does

- Offers configurable 30–120 minute movement reminders with Start, Snooze, and Skip actions.
- Opens the camera only after the user starts a workout.
- Counts reps locally with Apple Vision and gives depth/tracking feedback.
- Records completed sets, streaks, and explicitly saved partial effort.
- Creates private Packs with expiring, revocable invite links.
- Shows member activity and reactions in a dedicated Pack window.
- Queues completed Pack events on disk and retries idempotently after network failures.
- Uses Supabase anonymous auth with sessions stored in macOS Keychain.

Slack webhooks and bearer-code Packs were removed. Existing Pack codes cannot be migrated safely; users create a new Pack or join with a fresh invite. Local workout history is unaffected.

## Privacy and security

- Camera frames are processed on the Mac and are never recorded or uploaded.
- Packs share the chosen display name, finished-set reps, daily set count, streak, and event time.
- Pack access is authorized by Supabase user identity and database membership, not possession of a permanent Pack code.
- Invite tokens are shown only to the creator, stored server-side as SHA-256 hashes, and expire after seven days.
- Every exposed table has row-level security. Members can only read their own Packs and can only write as themselves.
- The publishable Supabase key in the app is public by design. The service-role key exists only in Edge Function secrets.
- Update checks open the signed GitHub release page; the app no longer replaces its own bundle from an unauthenticated download.
- The privacy manifest is in `Assets/PrivacyInfo.xcprivacy`.

Anonymous accounts are intentionally invisible. Removing the app’s Keychain item creates a new identity, so the user will need a fresh Pack invite.

## Build and test

Requirements:

- macOS 13 or newer
- Swift 6.1 or newer
- Docker Desktop for local Supabase tests

```bash
./build.sh --test
swift build --only-use-versions-from-resolved-file
./build.sh
```

`./build.sh` creates a universal arm64/x86_64 app with SwiftPM, stages and validates the bundle, ad-hoc signs it for local use, and installs it to `/Applications/Squat Coach.app`. Override the destination with `SQUAT_COACH_APP`.

The logic suite covers reminder cadence, squat/dropout regressions, history retention, invite parsing, update URL validation, and durable/idempotent outbox behavior.

## Local social backend

The backend source lives under `supabase/`.

```bash
npx supabase start
npx supabase db reset --local --no-seed --yes
npx supabase test db --local supabase/tests/social_packs.sql
SUPABASE_BIN="$(pwd)/node_modules/.bin/supabase" ./supabase/tests/e2e.sh
```

If Supabase is run through `npx` rather than a local package, set `SUPABASE_BIN` to that executable. The E2E script creates three anonymous users and verifies create, invite, join, member/nonmember reads, idempotent event delivery, leave, and delete.

To point a development build at the local stack:

```bash
SQUAT_COACH_SUPABASE_URL=http://127.0.0.1:54321 \
SQUAT_COACH_SUPABASE_KEY='<local publishable key>' \
swift run SquatCoach
```

## Production rollout

1. Link the intended Supabase project.
2. Enable anonymous sign-ins and keep the configured anonymous-user rate limit.
3. Apply `supabase/migrations/20260712043000_secure_social_packs.sql`.
4. Deploy `create-pack`, `join-pack`, `rotate-invite`, `leave-pack`, and `delete-pack` with JWT verification enabled.
5. Run Supabase security and performance advisors.
6. Replace `SocialBackend.defaultBaseURL` and `defaultPublishableKey` if the production project differs.
7. Build, notarize, and publish a signed release.

The current migration revokes the legacy `pack_fetch` and `pack_upsert` RPCs as part of the clean reset.

## Project layout

- `Sources/` — AppKit/SwiftUI app, pose counter, scheduler, social client, Pack UI.
- `Tests/LogicTests.swift` — deterministic headless regression runner.
- `supabase/migrations/` — Pack schema, RLS, helpers, and legacy shutdown.
- `supabase/functions/` — authenticated Pack lifecycle Edge Functions.
- `supabase/tests/` — adversarial SQL and local API E2E tests.
- `.github/workflows/ci.yml` — build and test gates.

## Diagnostics

Set `SQUAT_POSE_LOG=1` before launching to write pose diagnostics to:

`~/Library/Application Support/SquatCoach/pose-diagnostics.log`

The file is created with user-only permissions and contains pose/depth values, not video.
