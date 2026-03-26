alter table public.tracks
  add column if not exists is_sent_to_release boolean not null default false;

comment on column public.tracks.is_sent_to_release is
  'Пользователь вручную отмечает, что трек уже реально отправлен в релиз.';

create index if not exists idx_tracks_user_release_sent
  on public.tracks (user_id, is_sent_to_release)
  where is_sent_to_release = true;
