create or replace function public.notify_artist_collaboration_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  track_title text;
begin
  select coalesce(username, 'Артист АИМУЗЫ') into actor_name
  from public.profiles
  where user_id = new.initiator_user_id;

  select coalesce(title, 'Без названия') into track_title
  from public.tracks
  where id = new.track_id;

  if tg_op = 'INSERT' then
    insert into public.notifications (
      user_id, type, title, message, actor_id, target_type, target_id, link, metadata
    ) values (
      new.collaborator_user_id,
      'artist_collaboration_invite',
      'Приглашение к совместной работе',
      actor_name || ' приглашает вас подтвердить участие в треке «' || track_title || '»',
      new.initiator_user_id,
      'artist_collaboration',
      new.id,
      '/artist-studio?section=collaborations',
      jsonb_build_object('track_id', new.track_id, 'status', new.status)
    );
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
    insert into public.notifications (
      user_id, type, title, message, actor_id, target_type, target_id, link, metadata
    ) values (
      new.initiator_user_id,
      'artist_collaboration_accepted',
      'Совместная работа подтверждена',
      coalesce((select username from public.profiles where user_id = new.collaborator_user_id), 'Артист АИМУЗЫ')
        || ' подтвердил(а) участие в треке «' || track_title || '»',
      new.collaborator_user_id,
      'artist_collaboration',
      new.id,
      '/artist-studio?section=collaborations',
      jsonb_build_object('track_id', new.track_id, 'status', new.status)
    );
  end if;

  return new;
end;
$$;

drop trigger if exists notify_artist_collaboration_event on public.artist_collaborations;
create trigger notify_artist_collaboration_event
  after insert or update of status on public.artist_collaborations
  for each row execute function public.notify_artist_collaboration_event();

insert into public.notifications (
  user_id, type, title, message, actor_id, target_type, target_id, link, metadata
)
select
  collaboration.collaborator_user_id,
  'artist_collaboration_invite',
  'Приглашение к совместной работе',
  coalesce(profile.username, 'Артист АИМУЗЫ') || ' приглашает вас подтвердить участие в треке «'
    || coalesce(track.title, 'Без названия') || '»',
  collaboration.initiator_user_id,
  'artist_collaboration',
  collaboration.id,
  '/artist-studio?section=collaborations',
  jsonb_build_object('track_id', collaboration.track_id, 'status', collaboration.status)
from public.artist_collaborations collaboration
join public.tracks track on track.id = collaboration.track_id
left join public.profiles profile on profile.user_id = collaboration.initiator_user_id
where collaboration.status = 'pending'
  and not exists (
    select 1 from public.notifications notification
    where notification.target_type = 'artist_collaboration'
      and notification.target_id = collaboration.id
      and notification.type = 'artist_collaboration_invite'
  );
