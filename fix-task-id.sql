UPDATE public.tracks
SET description = description || E'\n\n[task_id: 568cf5a858bb31a3d613b43db31a0041]'
WHERE id IN ('219028eb-1c39-4b20-adf6-66713e2ae742', '7ff67760-b0dd-4bf4-904a-1519904337c6')
  AND description NOT LIKE '%[task_id:%';
