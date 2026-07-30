import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  GENERATE_MESSAGES_CRON,
  handleCronList,
  handleCronSetup,
} from "../_shared/cron-jobs.ts";
import { sendSilentPetMessagePush, userNotificationsEnabled } from "../_shared/onesignal.ts";

// ============================================================
// generate-messages
// Cron: 0 7,9,12,15,17,19,21,23 * * *  (register via ?setup_cron=1)
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLAUDE_API_KEY = Deno.env.get("CLAUDE_API_KEY")!;
const OPENWEATHER_API_KEY = Deno.env.get("OPENWEATHER_API_KEY")!;

// Max scheduled AI messages delivered per pet per local day. Tunable via env without a redeploy.
const MAX_MESSAGES_PER_DAY = (() => {
  const raw = parseInt(Deno.env.get("MAX_MESSAGES_PER_DAY") ?? "2", 10);
  return Number.isFinite(raw) && raw > 0 ? raw : 2;
})();

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

interface Pet {
  id: string;
  user_id: string;
  name: string;
  species: string;
  personality_traits: string[];
  energy_level: number;
  biggest_enemy: string;
  base_mood: string;
  home_lat?: number;
  home_lng?: number;
  timezone: string;
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  // Part 5.1 — register pg_cron job (run once after migration 005)
  if (url.searchParams.get("setup_cron") === "1") {
    return handleCronSetup(supabase, GENERATE_MESSAGES_CRON, req);
  }

  // Part 5.3 — verify cron jobs
  if (url.searchParams.get("list_cron") === "1") {
    return handleCronList(supabase, req);
  }

  console.log("generate-messages triggered");

  try {
    const { data: pets, error } = await supabase
      .from("pets")
      .select("*");

    if (error) throw error;
    if (!pets?.length) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    let processed = 0;
    for (const pet of pets as Pet[]) {
      try {
        await processOnePet(pet);
        processed++;
      } catch (err) {
        console.error(`Failed to process pet ${pet.id}:`, err);
      }
    }

    return new Response(JSON.stringify({ processed }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("generate-messages error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

async function processOnePet(pet: Pet): Promise<void> {
  if (!(await userNotificationsEnabled(supabase, pet.user_id))) {
    return;
  }

  // 1. Enforce the daily cap on scheduled messages
  const today = new Date().toISOString().split("T")[0];
  const { count } = await supabase
    .from("messages")
    .select("*", { count: "exact", head: true })
    .eq("pet_id", pet.id)
    .eq("trigger_type", "scheduled")
    .gte("scheduled_for", `${today}T00:00:00Z`)
    .not("sent_at", "is", null);

  if ((count ?? 0) >= MAX_MESSAGES_PER_DAY) {
    console.log(`Pet ${pet.id} hit daily cap (${MAX_MESSAGES_PER_DAY} scheduled), skipping`);
    return;
  }

  // 2. Determine time context
  const tz = pet.timezone || "UTC";
  const localTime = getLocalTimeContext(tz);
  const triggerType = getScheduledTrigger(localTime.hour);

  if (!triggerType) {
    return;
  }

  // 3. Fetch weather (if home location set)
  let weatherSummary: string | undefined;
  if (pet.home_lat && pet.home_lng) {
    try {
      weatherSummary = await fetchWeather(pet.home_lat, pet.home_lng);
    } catch {
      // Weather optional, don't fail
    }
  }

  // 4. Fetch last 10 sent messages to avoid repetition
  const { data: recentMessages } = await supabase
    .from("messages")
    .select("content")
    .eq("pet_id", pet.id)
    .not("sent_at", "is", null)
    .order("sent_at", { ascending: false })
    .limit(10);

  const recentContent = (recentMessages ?? []).map((m: { content: string }) => `- ${m.content}`).join("\n");

  // 5. Call Claude
  const response = await callClaude(pet, localTime.label, weatherSummary, triggerType, recentContent);

  // 6. Store message
  const now = new Date();
  const { data: message, error: insertError } = await supabase
    .from("messages")
    .insert({
      pet_id: pet.id,
      content: response.message,
      expression: response.expression,
      trigger_type: "scheduled",
      scheduled_for: now.toISOString(),
      sent_at: now.toISOString(),
    })
    .select()
    .single();

  if (insertError) throw insertError;

  // 7. Visible OneSignal push (also content-available for widget/chat refresh)
  try {
    await sendSilentPetMessagePush(
      pet.user_id,
      {
        pet_id: pet.id,
        message_id: message.id,
        trigger: "scheduled",
      },
      { title: pet.name, body: response.message },
    );
  } catch (err) {
    console.warn("Push failed (non-fatal):", err);
  }

  console.log(`Message sent for pet ${pet.id}: "${response.message}" [${response.expression}]`);
}

// ============================================================
// Time context
// ============================================================

function getLocalTimeContext(timezone: string): { hour: number; label: string } {
  try {
    const formatter = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      hour: "numeric",
      hour12: false,
    });
    const hour = parseInt(formatter.format(new Date()), 10);
    return { hour, label: getTimeLabel(hour) };
  } catch {
    const hour = new Date().getHours();
    return { hour, label: getTimeLabel(hour) };
  }
}

function getTimeLabel(hour: number): string {
  if (hour >= 7 && hour < 9) return "morning (7–9am)";
  if (hour >= 12 && hour < 14) return "midday (12–2pm)";
  if (hour >= 15 && hour < 17) return "afternoon (3–5pm)";
  if (hour >= 19 && hour < 21) return "evening (7–9pm)";
  if (hour >= 22 || hour < 5) return "late night (10pm+)";
  return `${hour}:00`;
}

function getScheduledTrigger(hour: number): string | null {
  if (hour >= 7 && hour < 9) return "morning";
  if (hour >= 12 && hour < 14) return "midday";
  if (hour >= 15 && hour < 17) return "afternoon";
  if (hour >= 19 && hour < 21) return "evening";
  if (hour >= 22 || hour < 1) return "night";
  return null;
}

// ============================================================
// Weather
// ============================================================

async function fetchWeather(lat: number, lng: number): Promise<string> {
  const url = `https://api.openweathermap.org/data/2.5/weather?lat=${lat}&lon=${lng}&appid=${OPENWEATHER_API_KEY}&units=imperial`;
  const res = await fetch(url);
  if (!res.ok) throw new Error("Weather API failed");
  const data = await res.json();

  const condition = data.weather?.[0]?.main ?? "Clear";
  const temp = Math.round(data.main?.temp ?? 70);
  const description = data.weather?.[0]?.description ?? "clear sky";

  const notable = ["Rain", "Snow", "Thunderstorm", "Extreme"].includes(condition) ||
    temp < 32 || temp > 90;

  if (!notable) return "";
  return `${condition} (${temp}°F, ${description})`;
}

// ============================================================
// Claude message generation
// ============================================================

async function callClaude(
  pet: Pet,
  timeLabel: string,
  weather: string | undefined,
  triggerType: string,
  recentMessages: string
): Promise<{ message: string; expression: string }> {
  const systemPrompt = `You are ${pet.name}, a ${pet.species}. Your personality: ${pet.personality_traits.join(", ")}. Energy level: ${pet.energy_level} out of 10. Things that set you off: ${pet.biggest_enemy}. Your general vibe: ${pet.base_mood}. Speak in first person. Be short, dry, and a little dramatic. Max 80 characters total. Never break character.`;

  const userPrompt = `Time of day: ${timeLabel}
${weather ? `Weather: ${weather}` : ""}
Trigger: scheduled ${triggerType} message

Recent messages you've already sent (do NOT repeat or closely echo these):
${recentMessages || "(none yet)"}

Return ONLY valid JSON: { "message": "string max 80 chars", "expression": "happy"|"sleepy"|"mad"|"excited"|"misses_you"|"judging" }`;

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": CLAUDE_API_KEY,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 150,
      system: systemPrompt,
      messages: [{ role: "user", content: userPrompt }],
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Claude API error: ${errText}`);
  }

  const data = await res.json();
  const text: string = data.content?.[0]?.text ?? "";

  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) throw new Error(`Could not parse Claude response: ${text}`);

  const parsed = JSON.parse(jsonMatch[0]);
  const message = (parsed.message as string).slice(0, 80);
  const expression = parsed.expression ?? "happy";

  return { message, expression };
}
