import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { generateLocationMessage } from "../_shared/location-message.ts";
import { sendSilentPetMessagePush, userNotificationsEnabled } from "../_shared/onesignal.ts";

// ============================================================
// location-event
// Called by iOS app on geofence trigger (left_home | returned)
// Immediately generates and stores a priority message
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

interface LocationRequest {
  pet_id: string;
  event: "left_home" | "returned" | "been_gone_2h" | "been_gone_6h";
}

interface Pet {
  user_id: string;
  name: string;
  species: string;
  personality_traits: string[];
  energy_level: number;
  biggest_enemy: string;
  base_mood: string;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const body: LocationRequest = await req.json();
    const { pet_id, event } = body;

    if (!pet_id || !event) {
      return new Response(JSON.stringify({ error: "pet_id and event required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: pet, error: petError } = await supabase
      .from("pets")
      .select("*")
      .eq("id", pet_id)
      .single();

    if (petError || !pet) {
      return new Response(JSON.stringify({ error: "Pet not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: recentMessages } = await supabase
      .from("messages")
      .select("content")
      .eq("pet_id", pet_id)
      .not("sent_at", "is", null)
      .order("sent_at", { ascending: false })
      .limit(10);

    const recentContent = (recentMessages ?? [])
      .map((m: { content: string }) => `- ${m.content}`)
      .join("\n");

    const response = await generateLocationMessage(pet as Pet, event, recentContent);

    const now = new Date();

    const { data: message, error: insertError } = await supabase
      .from("messages")
      .insert({
        pet_id,
        content: response.message,
        expression: response.expression,
        trigger_type: event,
        scheduled_for: now.toISOString(),
        sent_at: now.toISOString(),
      })
      .select()
      .single();

    if (insertError) throw insertError;

    if (event === "left_home") {
      await supabase
        .from("pets")
        .update({ departed_at: now.toISOString() })
        .eq("id", pet_id);
    } else if (event === "returned") {
      await supabase
        .from("pets")
        .update({ departed_at: null })
        .eq("id", pet_id);
    }

    const petRow = pet as Pet;
    if (await userNotificationsEnabled(supabase, petRow.user_id)) {
      try {
        await sendSilentPetMessagePush(
          petRow.user_id,
          {
            pet_id,
            message_id: message.id,
            trigger: event,
          },
          { title: petRow.name, body: response.message },
        );
      } catch (err) {
        console.warn("Push failed (non-fatal):", err);
      }
    }

    console.log(`Location message for pet ${pet_id} (${event}): "${response.message}"`);

    return new Response(JSON.stringify(message), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("location-event error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
