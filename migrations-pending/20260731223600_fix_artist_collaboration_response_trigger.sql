create or replace function public.protect_artist_collaboration_response()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.initiator_user_id <> new.initiator_user_id
    or old.collaborator_user_id <> new.collaborator_user_id
    or old.track_id <> new.track_id
    or old.created_at <> new.created_at then
    raise exception 'Collaboration participants and track cannot be changed';
  end if;

  if old.status <> 'pending' or new.status not in ('accepted', 'declined') then
    raise exception 'Invalid collaboration status transition';
  end if;

  new.responded_at := now();
  return new;
end;
$$;
