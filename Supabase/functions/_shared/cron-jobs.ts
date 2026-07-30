import { type SupabaseClient } from "jsr:@supabase/supabase-js@2";

export interface CronJobDefinition {
  jobName: string;
  schedule: string;
  functionName: string;
  description: string;
}

/** Part 5.1 — scheduled check-ins (per-pet timezone windows inside the function) */
export const GENERATE_MESSAGES_CRON: CronJobDefinition = {
  jobName: "generate-pet-messages",
  schedule: "0 7,9,12,15,17,19,21,23 * * *",
  functionName: "generate-messages",
  description: "Scheduled pet check-in messages every 2 hours (7am–11pm slots)",
};

/** Part 5.2 — been-gone 2h / 6h follow-ups */
export const PROCESS_BEEN_GONE_CRON: CronJobDefinition = {
  jobName: "process-been-gone",
  schedule: "*/15 * * * *",
  functionName: "process-been-gone",
  description: "Been-gone messages for pets with departed_at set",
};

function bearerToken(req: Request): string | null {
  const auth = req.headers.get("Authorization")?.trim();
  if (!auth?.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

/** Accept service_role JWT (gateway already verified the signature). */
export function verifyServiceRole(req: Request): boolean {
  const token = bearerToken(req);
  if (!token) return false;

  const envKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (envKey && token === envKey) return true;

  try {
    const payload = JSON.parse(atob(token.split(".")[1]));
    return payload.role === "service_role";
  } catch {
    return false;
  }
}

/** Register this function's pg_cron job. Requires migration 005_cron_jobs.sql. */
export async function handleCronSetup(
  supabase: SupabaseClient,
  job: CronJobDefinition,
  req: Request,
): Promise<Response> {
  if (!verifyServiceRole(req)) {
    return jsonResponse({ error: "Unauthorized — service role Bearer token required" }, 401);
  }

  const projectUrl = Deno.env.get("SUPABASE_URL");
  const invokeKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!projectUrl || !invokeKey) {
    return jsonResponse({ error: "SUPABASE_URL or SUPABASE_ANON_KEY not configured" }, 500);
  }

  const { data, error } = await supabase.rpc("setup_edge_function_cron", {
    p_job_name: job.jobName,
    p_cron_schedule: job.schedule,
    p_function_name: job.functionName,
    p_project_url: projectUrl,
    p_invoke_key: invokeKey,
  });

  if (error) {
    console.error(`cron setup failed for ${job.jobName}:`, error);
    return jsonResponse({ error: error.message, job }, 500);
  }

  console.log(`cron registered: ${job.jobName} (${job.schedule}) → job_id ${data}`);
  return jsonResponse({ ok: true, job_id: data, ...job });
}

/** Part 5.3 — list registered Petmoji cron jobs */
export async function handleCronList(
  supabase: SupabaseClient,
  req: Request,
): Promise<Response> {
  if (!verifyServiceRole(req)) {
    return jsonResponse({ error: "Unauthorized — service role Bearer token required" }, 401);
  }

  const { data, error } = await supabase.rpc("list_edge_function_cron_jobs");

  if (error) {
    return jsonResponse({ error: error.message }, 500);
  }

  return jsonResponse({ jobs: data ?? [] });
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
