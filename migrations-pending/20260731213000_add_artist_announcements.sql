create table if not exists public.artist_announcements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  title text not null check (char_length(title) between 1 and 120),
  body text not null default '' check (char_length(body) <= 2000),
  published_at timestamptz,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_artist_announcements_public
  on public.artist_announcements (user_id, sort_order, published_at desc)
  where published_at is not null;

create index if not exists idx_artist_announcements_owner
  on public.artist_announcements (user_id, sort_order, created_at desc);

alter table public.artist_announcements enable row level security;

drop policy if exists "Public can view published artist announcements" on public.artist_announcements;
create policy "Public can view published artist announcements"
  on public.artist_announcements
  for select
  using (published_at is not null and published_at <= now());

drop policy if exists "Owners can view own artist announcements" on public.artist_announcements;
create policy "Owners can view own artist announcements"
  on public.artist_announcements
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Owners can insert artist announcements" on public.artist_announcements;
create policy "Owners can insert artist announcements"
  on public.artist_announcements
  for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Owners can update artist announcements" on public.artist_announcements;
create policy "Owners can update artist announcements"
  on public.artist_announcements
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Owners can delete artist announcements" on public.artist_announcements;
create policy "Owners can delete artist announcements"
  on public.artist_announcements
  for delete
  to authenticated
  using (auth.uid() = user_id);

grant select on public.artist_announcements to anon;
grant select, insert, update, delete on public.artist_announcements to authenticated;

drop trigger if exists update_artist_announcements_updated_at on public.artist_announcements;
create trigger update_artist_announcements_updated_at
  before update on public.artist_announcements
  for each row execute function public.update_updated_at_column();

comment on table public.artist_announcements is
  'Публичные анонсы артистов АИМУЗЫ и их черновики.';
