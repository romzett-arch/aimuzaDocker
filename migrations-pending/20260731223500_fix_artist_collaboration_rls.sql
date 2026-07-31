create or replace function public.is_public_completed_collaboration_track(_track_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tracks
    where id = _track_id
      and is_public = true
      and status = 'completed'
  );
$$;

create or replace function public.is_owned_public_collaboration_track(_track_id uuid, _user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tracks
    where id = _track_id
      and user_id = _user_id
      and is_public = true
      and status = 'completed'
  );
$$;

revoke all on function public.is_public_completed_collaboration_track(uuid) from public;
revoke all on function public.is_owned_public_collaboration_track(uuid, uuid) from public;
grant execute on function public.is_public_completed_collaboration_track(uuid) to anon, authenticated;
grant execute on function public.is_owned_public_collaboration_track(uuid, uuid) to authenticated;

drop policy if exists "Public can view accepted artist collaborations" on public.artist_collaborations;
create policy "Public can view accepted artist collaborations"
  on public.artist_collaborations
  for select
  using (
    status = 'accepted'
    and public.is_public_completed_collaboration_track(track_id)
  );

drop policy if exists "Track owners can invite artist collaborators" on public.artist_collaborations;
create policy "Track owners can invite artist collaborators"
  on public.artist_collaborations
  for insert
  to authenticated
  with check (
    auth.uid() = initiator_user_id
    and status = 'pending'
    and public.is_owned_public_collaboration_track(track_id, auth.uid())
  );
