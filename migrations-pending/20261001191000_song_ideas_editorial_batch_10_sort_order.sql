-- Keep the accepted editorial batch after all pre-existing cards without
-- renumbering any existing record. This also handles legacy local imports.
WITH batch AS (
  SELECT i.id, row_number() OVER (ORDER BY i.title) AS position
  FROM public.song_ideas i
  JOIN public.song_idea_sources s ON s.idea_id = i.id
  WHERE s.original_key IN (
    'james-thomas-fields|ballad-of-the-tempest',
    'james-russell-lowell|the-courtin',
    'a-b-paterson|mulga-bills-bicycle',
    'a-b-paterson|the-man-from-snowy-river',
    'oliver-wendell-holmes|the-deacons-masterpiece',
    'leigh-hunt|the-glove-and-the-lions',
    'robert-southey|the-inchcape-rock',
    'oliver-wendell-holmes|the-ballad-of-the-oysterman',
    'lewis-carroll|the-hunting-of-the-snark',
    'g-k-chesterton|the-donkey'
  )
), base AS (
  SELECT COALESCE(max(i.sort_order), 0) AS max_sort_order
  FROM public.song_ideas i
  WHERE NOT EXISTS (
    SELECT 1 FROM batch b WHERE b.id = i.id
  )
)
UPDATE public.song_ideas i
SET sort_order = base.max_sort_order + batch.position
FROM batch CROSS JOIN base
WHERE i.id = batch.id;
