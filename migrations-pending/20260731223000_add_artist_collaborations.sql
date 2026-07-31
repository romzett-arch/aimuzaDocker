create table if not exists public.artist_collaborations (
  id uuid primary key default gen_random_uuid(),
  initiator_user_id uuid not null references public.profiles(user_id) on delete cascade,
  collaborator_user_id uuid not null references public.profiles(user_id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint artist_collaborations_distinct_users check (initiator_user_id <> collaborator_user_id),
  constraint artist_collaborations_unique_invite unique (track_id, collaborator_user_id)
);

create index if not exists idx_artist_collaborations_initiator
  on public.artist_collaborations (initiator_user_id, status, created_at desc);

create index if not exists idx_artist_collaborations_collaborator
  on public.artist_collaborations (collaborator_user_id, status, created_at desc);

alter table public.artist_collaborations enable row level security;

drop policy if exists "Public can view accepted artist collaborations" on public.artist_collaborations;
create policy "Public can view accepted artist collaborations"
  on public.artist_collaborations
  for select
  using (
    status = 'accepted'
    and exists (
      select 1 from public.tracks
      where tracks.id = artist_collaborations.track_id
        and tracks.is_public = true
        and tracks.status = 'completed'
    )
  );

drop policy if exists "Participants can view artist collaborations" on public.artist_collaborations;
create policy "Participants can view artist collaborations"
  on public.artist_collaborations
  for select
  to authenticated
  using (auth.uid() in (initiator_user_id, collaborator_user_id));

drop policy if exists "Track owners can invite artist collaborators" on public.artist_collaborations;
create policy "Track owners can invite artist collaborators"
  on public.artist_collaborations
  for insert
  to authenticated
  with check (
    auth.uid() = initiator_user_id
    and status = 'pending'
    and exists (
      select 1 from public.tracks
      where tracks.id = artist_collaborations.track_id
        and tracks.user_id = auth.uid()
        and tracks.is_public = true
        and tracks.status = 'completed'
    )
  );

drop policy if exists "Invited artists can respond to collaborations" on public.artist_collaborations;
create policy "Invited artists can respond to collaborations"
  on public.artist_collaborations
  for update
  to authenticated
  using (auth.uid() = collaborator_user_id and status = 'pending')
  with check (auth.uid() = collaborator_user_id and status in ('accepted', 'declined'));

drop policy if exists "Participants can delete artist collaborations" on public.artist_collaborations;
create policy "Participants can delete artist collaborations"
  on public.artist_collaborations
  for delete
  to authenticated
  using (auth.uid() in (initiator_user_id, collaborator_user_id));

create or replace function public.protect_artist_collaboration_response()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if auth.uid() is not null then
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
  end if;
  return new;
end;
$$;

drop trigger if exists protect_artist_collaboration_response on public.artist_collaborations;
create trigger protect_artist_collaboration_response
  before update on public.artist_collaborations
  for each row execute function public.protect_artist_collaboration_response();

drop trigger if exists update_artist_collaborations_updated_at on public.artist_collaborations;
create trigger update_artist_collaborations_updated_at
  before update on public.artist_collaborations
  for each row execute function public.update_updated_at_column();

grant select on public.artist_collaborations to anon;
grant select, insert, update, delete on public.artist_collaborations to authenticated;

comment on table public.artist_collaborations is
  'Подтверждённые совместные работы артистов АИМУЗЫ и ожидающие приглашения.';
