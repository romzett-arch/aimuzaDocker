alter table public.release_packages
  add column if not exists requested_move_to_my_releases boolean not null default false;

comment on column public.release_packages.requested_move_to_my_releases is
  'После готовности релиз-пака автоматически перенести трек в Мои релизы.';
