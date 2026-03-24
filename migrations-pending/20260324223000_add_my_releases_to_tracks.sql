alter table public.tracks
  add column if not exists is_in_my_releases boolean not null default false,
  add column if not exists moved_to_my_releases_at timestamptz;

comment on column public.tracks.is_in_my_releases is
  'Трек выведен из проекта и хранится только в разделе Мои релизы.';

comment on column public.tracks.moved_to_my_releases_at is
  'Дата и время переноса трека в раздел Мои релизы.';

create index if not exists idx_tracks_user_my_releases
  on public.tracks (user_id, is_in_my_releases)
  where is_in_my_releases = true;

drop policy if exists "Users can view public tracks" on public.tracks;
create policy "Users can view public tracks" on public.tracks
  for select
  using (is_public = true and is_in_my_releases = false);
