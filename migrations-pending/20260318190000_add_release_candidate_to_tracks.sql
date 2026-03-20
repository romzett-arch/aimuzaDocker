alter table public.tracks
  add column if not exists is_release_candidate boolean not null default false;

comment on column public.tracks.is_release_candidate is
  'Ручная метка пользователя для отбора трека в будущий релиз.';

create index if not exists idx_tracks_user_release_candidate
  on public.tracks (user_id, is_release_candidate)
  where is_release_candidate = true;
