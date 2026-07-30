# Petmoji — Supabase Setup

## 1. Create Supabase Project

Go to [supabase.com](https://supabase.com) and create a new project.

## 2. Apply Database Schema

In the Supabase SQL editor, run the contents of:

```
migrations/001_initial_schema.sql
migrations/002_device_tokens.sql
migrations/003_profiles.sql
migrations/004_notifications.sql
migrations/005_cron_jobs.sql
```

This creates:
- `pets` table with RLS
- `messages` table with RLS
- `profiles` table with RLS (sign-up name, email, phone, notifications_enabled)
- Storage buckets (`pet-photos`, `pet-sprites`)

## 2b. Email OTP auth (Auth dashboard + Loops)

The iOS app uses **passwordless email OTP** (6-digit code) for both sign-up and sign-in via `signInWithOTP` and `verifyOTP`. Emails are delivered through **Loops SMTP**.

**Full setup:** follow [`CLAUDE.md`](../CLAUDE.md).

Quick checklist in **[Authentication → Providers → Email](https://supabase.com/dashboard/project/_/auth/providers?provider=Email)**:

- **Email provider**: enabled
- **OTP length**: **6** (must match `SignUpOTPConfig.length` in [`SignUpDraft.swift`](../Petmoji/SignUp/SignUpDraft.swift))
- **Confirm email**: **off** (verification happens in-app via OTP)
- **Custom SMTP**: Loops (`smtp.loops.so`, port 587) — see runbook
- **Email templates**: Magic Link + Confirm signup bodies must be **JSON payloads** from Loops (not HTML)

Optional: disable **Anonymous sign-ins** in production. Keep enabled if you use `-skipSignUp`.

## 3. Create Storage Buckets (UI Method)

If storage creation via SQL doesn't work, create them manually:

1. Go to **Storage** in your Supabase dashboard
2. Create bucket `pet-photos` — **Private**, 10MB limit, allow JPEG/PNG/WEBP/HEIC
3. Create bucket `pet-sprites` — **Public**, 5MB limit, allow PNG/WEBP

## 4. Deploy Edge Functions

Install the Supabase CLI and run:

```bash
supabase functions deploy generate-sprites
supabase functions deploy generate-messages
supabase functions deploy location-event
supabase functions deploy process-been-gone
supabase functions deploy chat-reply
supabase functions deploy delete-account
```

Set required secrets:

```bash
supabase secrets set REPLICATE_API_TOKEN=r8_...
supabase secrets set CLAUDE_API_KEY=sk-ant-...
supabase secrets set OPENWEATHER_API_KEY=...
supabase secrets set ONESIGNAL_APP_ID=...
supabase secrets set ONESIGNAL_REST_API_KEY=...
supabase secrets set MAX_MESSAGES_PER_DAY=2  # optional (default 2) — scheduled-message cap
```

> How messages are generated, scheduled, capped, and delivered is documented in [`docs/ai-message-logic.md`](../docs/ai-message-logic.md).

## 5. Set Up Cron Jobs

Cron jobs are registered via `pg_cron` (migration `005_cron_jobs.sql`) and each
Edge Function's `?setup_cron=1` endpoint.

### Step A — Run migration 005

In SQL Editor, run `migrations/005_cron_jobs.sql`. This enables `pg_cron` /
`pg_net` and creates helper RPCs.

### Step B — Deploy functions

```bash
supabase functions deploy generate-messages
supabase functions deploy process-been-gone
```

### Step C — Register cron jobs (one-time each)

```bash
# 5.1 — scheduled check-ins
curl -X POST "https://YOUR_PROJECT_REF.supabase.co/functions/v1/generate-messages?setup_cron=1" \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY"

# 5.2 — been-gone 2h / 6h
curl -X POST "https://YOUR_PROJECT_REF.supabase.co/functions/v1/process-been-gone?setup_cron=1" \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY"
```

### Step D — Verify (5.3)

```bash
curl "https://YOUR_PROJECT_REF.supabase.co/functions/v1/generate-messages?list_cron=1" \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY"
```

Or in SQL Editor:

```sql
select jobid, jobname, schedule, active from cron.job
where jobname in ('generate-pet-messages', 'process-been-gone');
```

Schedules (defined in `_shared/cron-jobs.ts`, wired in each `index.ts`):

| Job | Schedule | Function |
|-----|----------|----------|
| `generate-pet-messages` | `0 7,9,12,15,17,19,21,23 * * *` | `generate-messages` |
| `process-been-gone` | `*/15 * * * *` | `process-been-gone` |

## 6. Configure iOS App

In `SupabaseService.swift`, update:

```swift
private let supabaseURL = URL(string: "https://YOUR_PROJECT.supabase.co")!
private let supabaseKey = "YOUR_ANON_KEY"
```

Or set environment variables:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `ONESIGNAL_APP_ID` (OneSignal dashboard → Settings → Keys & IDs)

In Xcode, add `ONESIGNAL_APP_ID` to the Petmoji target **Build Settings** (or scheme environment) for local runs.

### OneSignal setup

1. Create an iOS app in [OneSignal](https://onesignal.com) with bundle ID `com.hilollc.petmoji.app` (Release / TestFlight)
2. Upload your APNs Auth Key (.p8) in OneSignal → Settings → Platforms → Apple iOS
3. Copy **App ID** → `ONESIGNAL_APP_ID` (iOS build setting + Supabase secret)
4. Copy **REST API Key** → `ONESIGNAL_REST_API_KEY` (Supabase secret only)
5. On sign-in, the app calls `OneSignal.login(supabaseUserId)` so pushes target `external_id`

Push flow: edge functions send a **visible** OneSignal push (title = pet name, body = message) plus `content_available` → iOS shows the banner even if the app is killed → when the app wakes it refreshes chat/widget from `pet_id` / `message_id` in the payload.

In `ClaudeService.swift`:
- `CLAUDE_API_KEY` (for on-device chat — consider proxying through your backend instead)

## Architecture Notes

- **generate-sprites**: Called once during onboarding. Generates 6 expression variants via Replicate API and stores in `pet-sprites` bucket.
- **generate-messages**: Cron function. Runs on schedule, generates Claude messages, stores in `messages` table, sends OneSignal silent push.
- **location-event**: Called by iOS app on geofence trigger. Generates priority message, syncs `departed_at`, sends push fallback.
- **process-been-gone**: Cron function. Sends 2h/6h been-gone messages for pets with `departed_at` set.
- Widget reads from Supabase via shared `UserDefaults` (App Group) populated by main app on message receipt.
