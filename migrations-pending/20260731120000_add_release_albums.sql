alter table public.tracks
  add column if not exists release_album_id uuid,
  add column if not exists release_album_name text;

comment on column public.tracks.release_album_id is
  'Идентификатор пользовательской группы треков, отправляемых как один альбом.';

comment on column public.tracks.release_album_name is
  'Название альбома в разделе Мои релизы.';

create index if not exists idx_tracks_user_release_album
  on public.tracks (user_id, release_album_id)
  where is_in_my_releases = true and release_album_id is not null;
