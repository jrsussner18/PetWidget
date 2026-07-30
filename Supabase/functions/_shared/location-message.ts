const CLAUDE_API_KEY = Deno.env.get("CLAUDE_API_KEY")!;

export interface LocationPet {
  name: string;
  species: string;
  personality_traits: string[];
  energy_level: number;
  biggest_enemy: string;
  base_mood: string;
}

export type LocationEvent =
  | "left_home"
  | "returned"
  | "been_gone_2h"
  | "been_gone_6h";

function eventContext(event: string): string {
  switch (event) {
    case "left_home":
      return "The owner just left home. The pet is reacting to being left alone.";
    case "returned":
      return "The owner just came back home after being away. The pet is reacting to their return.";
    case "been_gone_2h":
      return "The owner has been away from home for about 2 hours. The pet is still alone at home.";
    case "been_gone_6h":
      return "The owner has been away from home for about 6 hours. The pet is dramatic about how long they've been gone.";
    default:
      return "The pet is reacting to the owner's absence.";
  }
}

function defaultExpressionForEvent(event: string): string {
  switch (event) {
    case "left_home":
    case "been_gone_2h":
    case "been_gone_6h":
      return "misses_you";
    case "returned":
      return "excited";
    default:
      return "happy";
  }
}

export async function generateLocationMessage(
  pet: LocationPet,
  event: string,
  recentMessages: string,
): Promise<{ message: string; expression: string }> {
  const systemPrompt =
    `You are ${pet.name}, a ${pet.species}. Personality: ${pet.personality_traits.join(", ")}. Energy: ${pet.energy_level}/10. Things that set you off: ${pet.biggest_enemy}. Vibe: ${pet.base_mood}. Speak in first person, short and dramatic. Max 80 characters.`;

  const userPrompt = `${eventContext(event)}

Recent messages (do NOT repeat):
${recentMessages || "(none)"}

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
  if (!jsonMatch) throw new Error(`Could not parse response: ${text}`);

  const parsed = JSON.parse(jsonMatch[0]);
  return {
    message: (parsed.message as string).slice(0, 80),
    expression: parsed.expression ?? defaultExpressionForEvent(event),
  };
}
