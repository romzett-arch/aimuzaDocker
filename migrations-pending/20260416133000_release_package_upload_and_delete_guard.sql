create or replace function public.trg_prevent_release_candidate_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(OLD.is_release_candidate, false) then
    raise exception 'release_candidate_delete_forbidden';
  end if;

  return OLD;
end;
$$;

drop trigger if exists prevent_release_candidate_delete on public.tracks;
create trigger prevent_release_candidate_delete
before delete on public.tracks
for each row
execute function public.trg_prevent_release_candidate_delete();

grant insert, update on public.release_packages to authenticated;

drop policy if exists "Users can insert own release packages" on public.release_packages;
create policy "Users can insert own release packages"
  on public.release_packages
  for insert
  to authenticated
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from public.tracks
      where tracks.id = track_id
        and tracks.user_id = auth.uid()
    )
  );

drop policy if exists "Users can update own release packages" on public.release_packages;
create policy "Users can update own release packages"
  on public.release_packages
  for update
  to authenticated
  using (
    auth.uid() = user_id
    and exists (
      select 1
      from public.tracks
      where tracks.id = track_id
        and tracks.user_id = auth.uid()
    )
  )
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from public.tracks
      where tracks.id = track_id
        and tracks.user_id = auth.uid()
    )
  );
