-- ============================================================
-- pg_cron helpers for Edge Function scheduling
-- Run migration, then register jobs via each function's ?setup_cron=1
-- ============================================================

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- Idempotently register a cron job that POSTs to an Edge Function.
-- Uses the anon/publishable key for invocation (stored in cron.job; not service_role).
create or replace function public.setup_edge_function_cron(
  p_job_name text,
  p_cron_schedule text,
  p_function_name text,
  p_project_url text,
  p_invoke_key text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_job_id bigint;
  v_command text;
begin
  if p_job_name is null or p_cron_schedule is null or p_function_name is null
     or p_project_url is null or p_invoke_key is null then
    raise exception 'All cron setup parameters are required';
  end if;

  -- Remove existing job with the same name (idempotent re-register)
  perform cron.unschedule(j.jobid)
  from cron.job j
  where j.jobname = p_job_name;

  v_command := format(
    $cmd$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Authorization', 'Bearer %s',
          'apikey', %L,
          'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb
      );
    $cmd$,
    rtrim(p_project_url, '/') || '/functions/v1/' || p_function_name,
    p_invoke_key,
    p_invoke_key
  );

  select cron.schedule(p_job_name, p_cron_schedule, v_command) into v_job_id;
  return v_job_id;
end;
$$;

revoke all on function public.setup_edge_function_cron(text, text, text, text, text) from public;
grant execute on function public.setup_edge_function_cron(text, text, text, text, text) to service_role;

-- List Petmoji cron jobs (for ?list_cron=1 verification)
create or replace function public.list_edge_function_cron_jobs()
returns table(jobid bigint, jobname text, schedule text, active boolean)
language sql
security definer
set search_path = public, extensions
as $$
  select jobid, jobname, schedule, active
  from cron.job
  where jobname in ('generate-pet-messages', 'process-been-gone')
  order by jobname;
$$;

revoke all on function public.list_edge_function_cron_jobs() from public;
grant execute on function public.list_edge_function_cron_jobs() to service_role;
