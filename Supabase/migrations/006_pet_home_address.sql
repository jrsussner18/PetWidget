-- Explicit home address label (lat/lng remain the geofence / weather anchors).
alter table public.pets
  add column if not exists home_address text;
