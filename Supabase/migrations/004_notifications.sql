-- ============================================================
-- Push notifications: user preference + server-side departure tracking
-- ============================================================

alter table public.profiles
  add column if not exists notifications_enabled boolean not null default true;

alter table public.pets
  add column if not exists departed_at timestamptz;

create index if not exists pets_departed_at_idx
  on public.pets (departed_at)
  where departed_at is not null;
