# AI Message Generation & Scheduling

How Petmoji decides *when* a pet messages you, *what* it says, and *how* that message reaches the app, widget, and a push notification.

> Companion to HIL-32 (document the logic) and HIL-33 (cap scheduled messages). If you change any behavior below, update this doc.

---

## 1. Message types (triggers)

Every row in the `messages` table has a `trigger_type` ([`Petmoji/Models/PetMessage.swift`](../Petmoji/Models/PetMessage.swift)):

| `trigger_type` | Source | Cadence | Counts toward daily cap? |
|----------------|--------|---------|--------------------------|
| `scheduled`    | `generate-messages` edge fn (cron) | A few times/day, within time windows | **Yes** |
| `left_home`    | Geofence exit → `location-event` | Event-driven | No |
| `returned`     | Geofence enter → `location-event` | Event-driven | No |
| `been_gone_2h` | `BGAppRefreshTask` 2h after leaving → `location-event` | Once per departure | No |
| `been_gone_6h` | `BGAppRefreshTask` 6h after leaving → `location-event` | Once per departure | No |
| `chat_reply`   | User opens or sends in chat → `chat-reply` | On demand | No |

Only **`scheduled`** messages are rate-limited. Location and chat messages are user/context-driven and intentionally uncapped.

---

## 2. Scheduled messages — the "ambient" path

File: [`Supabase/functions/generate-messages/index.ts`](../Supabase/functions/generate-messages/index.ts)

### Invocation (cron)
A pg_cron job hits the function on a fixed hourly list (see [`Supabase/README.md`](../Supabase/README.md)):

```
0 7,9,12,15,17,19,21,23 * * *
```

Each run loops over **all** pets and calls `processOnePet`.

### Per-pet decision flow
1. **Daily cap.** Count today's `sent` rows with `trigger_type = 'scheduled'`. If `>= MAX_MESSAGES_PER_DAY` (default **2**, env-tunable — see §6), skip.
2. **Time window.** `getScheduledTrigger(localHour)` maps the pet's *local* hour (from `pet.timezone`) to a window, or `null` (skip):

   | Window | Local hours |
   |--------|-------------|
   | morning   | 07:00–08:59 |
   | midday    | 12:00–13:59 |
   | afternoon | 15:00–16:59 |
   | evening   | 19:00–20:59 |
   | night     | 22:00–00:59 |

3. **Weather (optional).** If the pet has a home lat/lng, fetch OpenWeather; only *notable* weather (rain/snow/storm/extreme, or <32°F / >90°F) is surfaced to the prompt.
4. **Anti-repetition context.** Fetch the last 10 sent messages and pass them to Claude with "do NOT repeat."
5. **Generate.** Call Claude (`claude-haiku-4-5`) with the pet's personality/energy/enemy/mood + time + weather + recent messages. Expect strict JSON `{ message, expression }`, message clamped to 80 chars.
6. **Store.** Insert into `messages` with `trigger_type = 'scheduled'`, `sent_at = now`.
7. **Push.** If APNs is configured, send a user-visible push (see §5).

### Why it felt "random" (findings for HIL-32)
- **Cron / window misalignment.** The cron fires at `7,9,12,15,17,19,21,23`, but the windows are half-open `[start, start+2)`. Hours **9, 17, 21** fall *outside* every window, so those three runs generate nothing. Effective send slots were only `07, 12, 15, 19, 23` → up to **5/day**.
- **The old cap was effectively inert.** The previous hardcoded cap was `6/day`, but only ~5 windows can ever fire, so the cap never actually limited anything — pets could send ~5 messages daily. That's the spammy feeling. HIL-33 lowers the default to **2** and makes it tunable.
- **Dedup is soft.** Repetition avoidance is just the "last 10 messages" prompt hint — there's no hard uniqueness check. Claude usually complies but can still echo.
- **Per-window timing depends on cron alignment, not randomness.** Within a day the slots are deterministic; the variability comes from which windows the cron happens to hit and Claude's content.

> Optional follow-up (not done here, it's a tuning decision): align the cron hours to window starts (`7,12,15,19,22`) so no run is wasted. Left as-is to keep this change scoped to the cap.

---

## 3. Location messages — the "reactive" path

Files: [`Petmoji/Services/LocationService.swift`](../Petmoji/Services/LocationService.swift), [`Petmoji/Services/BeenGoneBackgroundScheduler.swift`](../Petmoji/Services/BeenGoneBackgroundScheduler.swift), [`Supabase/functions/location-event/index.ts`](../Supabase/functions/location-event/index.ts)

- Requires **location tracking on** + **Always** authorization + a saved **home** geofence.
- Home is set from a **user-confirmed address** (MapKit search / optional current-location prefill), geocoded to lat/lng — not from raw GPS at the moment tracking is enabled.
- **Geofence exit** (`didExitRegion`) → store `departure_time`, schedule been-gone follow-ups, call `location-event` with `left_home`.
- **Geofence enter** (`didEnterRegion`) → clear `departure_time`, cancel follow-ups, call `location-event` with `returned`.
- **Been-gone follow-ups**: two `BGAppRefreshTask`s scheduled ~2h and ~6h after leaving (`com.petmoji.been-gone-2h/6h`). When the OS runs them, they call `location-event` with `been_gone_2h` / `been_gone_6h`. These are best-effort — iOS decides when (or whether) background refresh runs.
- `location-event` generates the message with event-specific context (e.g. "owner just left", "been gone 6h, be dramatic") and stores it. The app then delivers it locally (§4). **Not capped.**

---

## 4. Delivery: app, chat history, widget

File: [`Petmoji/Services/PetMessageDelivery.swift`](../Petmoji/Services/PetMessageDelivery.swift)

`PetMessageDelivery.deliver(pet:message:)` (called for in-app/foreground + background-task delivery):
1. Appends to local chat history ([`ChatHistoryStore`](../Petmoji/Services/ChatHistoryStore.swift)).
2. Writes the widget snapshot to the App Group + reloads the widget ([`WidgetSnapshotSync`](../Petmoji/Services/WidgetSnapshotSync.swift)) — see HIL-29.
3. Posts a **local** notification (communication-style, with the pet's sprite avatar).
4. Broadcasts `.petMessageDelivered` so open screens (home/chat) refresh.

`refreshWidgetFromServer()` pulls the latest server message for the widget pet on app foreground / push.

---

## 5. Push notifications (server → device)

For **scheduled** messages the app isn't running, so the push must come from the server. See HIL-28 / HIL-36 for setup. Summary:
- Edge functions call OneSignal with a **visible** alert (title = pet name, body = message) plus `content_available` so chat/widget can refresh when the app wakes.
- Targeting uses `external_id` = Supabase user UUID (`OneSignal.login` on sign-in).
- Requires Supabase secrets `ONESIGNAL_APP_ID` + `ONESIGNAL_REST_API_KEY`. OneSignal iOS platform must use bundle id `com.hilollc.petmoji.app` and a production APNs `.p8`.

---

## 6. Configuration knobs (env / Supabase secrets)

| Variable | Where | Default | Purpose |
|----------|-------|---------|---------|
| `MAX_MESSAGES_PER_DAY` | `generate-messages` | `2` | Max **scheduled** messages per pet per day (HIL-33). Tune without code changes. |
| `ONESIGNAL_APP_ID` | edge functions + iOS | — | OneSignal app id (also baked into Xcode Release/Debug). |
| `ONESIGNAL_REST_API_KEY` | edge functions | — | OneSignal REST key (server only). |
| `OPENWEATHER_API_KEY` | `generate-messages` | — | Optional weather context. |
| cron schedule | pg_cron | `0 7,9,12,15,17,19,21,23 * * *` | When the scheduler runs. |

To change the cap:

```bash
supabase secrets set MAX_MESSAGES_PER_DAY=3
supabase functions deploy generate-messages
```

---

## 7. What's deterministic vs AI-driven

- **Deterministic:** whether to send (cap + window + cron), which trigger type, weather notability threshold, expression fallback per event.
- **AI-driven (Claude):** the message text and the chosen `expression`, constrained by the system prompt (persona, ≤80 chars, first person) and the "don't repeat" hint.
