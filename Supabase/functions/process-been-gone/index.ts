import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  handleCronList,
  handleCronSetup,
  PROCESS_BEEN_GONE_CRON,
} from "../_shared/cron-jobs.ts";
import { generateLocationMessage } from "../_shared/location-message.ts";
import { sendSilentPetMessagePush, userNotificationsEnabled } from "../_shared/onesignal.ts";

// ============================================================
// process-been-gone
// Cron: */15 * * * *  (register via ?setup_cron=1)
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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
  departed_at: string;
}

type BeenGoneEvent = "been_gone_2h" | "been_gone_6h";

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  // Part 5.2 — register pg_cron job (run once after migration 005)
  if (url.searchParams.get("setup_cron") === "1") {
    return handleCronSetup(supabase, PROCESS_BEEN_GONE_CRON, req);
  }

  // Part 5.3 — verify cron jobs
  if (url.searchParams.get("list_cron") === "1") {
    return handleCronList(supabase, req);
  }

  console.log("process-been-gone triggered");

  try {
    const { data: pets, error } = await supabase
      .from("pets")
      .select("*")
      .not("departed_at", "is", null);

    if (error) throw error;
    if (!pets?.length) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    let processed = 0;
    for (const pet of pets as Pet[]) {
      try {
        const sent = await processPetIfNeeded(pet);
        if (sent) processed++;
      } catch (err) {
        console.error(`Failed been-gone for pet ${pet.id}:`, err);
      }
    }

    return new Response(JSON.stringify({ processed }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("process-been-gone error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

async function processPetIfNeeded(pet: Pet): Promise<boolean> {
  const departedAt = new Date(pet.departed_at);
  const hoursAway = (Date.now() - departedAt.getTime()) / (1000 * 60 * 60);

  let event: BeenGoneEvent | null = null;
  if (hoursAway >= 6) {
    event = "been_gone_6h";
  } else if (hoursAway >= 2) {
    event = "been_gone_2h";
  }

  if (!event) return false;

  const alreadySent = await hasBeenGoneMessageSinceDeparture(pet.id, event, pet.departed_at);
  if (alreadySent) return false;

  if (!(await userNotificationsEnabled(supabase, pet.user_id))) {
    return false;
  }

  const { data: recentMessages } = await supabase
    .from("messages")
    .select("content")
    .eq("pet_id", pet.id)
    .not("sent_at", "is", null)
    .order("sent_at", { ascending: false })
    .limit(10);

  const recentContent = (recentMessages ?? [])
    .map((m: { content: string }) => `- ${m.content}`)
    .join("\n");

  const response = await generateLocationMessage(pet, event, recentContent);
  const now = new Date();

  const { data: message, error: insertError } = await supabase
    .from("messages")
    .insert({
      pet_id: pet.id,
      content: response.message,
      expression: response.expression,
      trigger_type: event,
      scheduled_for: now.toISOString(),
      sent_at: now.toISOString(),
    })
    .select()
    .single();

  if (insertError) throw insertError;

  try {
    await sendSilentPetMessagePush(
      pet.user_id,
      {
        pet_id: pet.id,
        message_id: message.id,
        trigger: event,
      },
      { title: pet.name, body: response.message },
    );
  } catch (err) {
    console.warn("Push failed (non-fatal):", err);
  }

  console.log(`Been-gone message for pet ${pet.id} (${event}): "${response.message}"`);
  return true;
}

async function hasBeenGoneMessageSinceDeparture(
  petId: string,
  event: BeenGoneEvent,
  departedAt: string,
): Promise<boolean> {
  const { count } = await supabase
    .from("messages")
    .select("*", { count: "exact", head: true })
    .eq("pet_id", petId)
    .eq("trigger_type", event)
    .gte("sent_at", departedAt);

  return (count ?? 0) > 0;
}
