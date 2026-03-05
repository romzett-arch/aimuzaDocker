-- Fix radio FK constraints: NO ACTION → CASCADE/SET NULL
-- radio_bids, radio_predictions, radio_slots reference tracks without CASCADE,
-- which blocks track deletion when related radio records exist.

-- radio_bids.track_id → ON DELETE CASCADE
ALTER TABLE public.radio_bids
  DROP CONSTRAINT radio_bids_track_id_fkey,
  ADD CONSTRAINT radio_bids_track_id_fkey
    FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;

-- radio_predictions.track_id → ON DELETE CASCADE
ALTER TABLE public.radio_predictions
  DROP CONSTRAINT radio_predictions_track_id_fkey,
  ADD CONSTRAINT radio_predictions_track_id_fkey
    FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;

-- radio_slots.winner_track_id → ON DELETE SET NULL (slot should survive track deletion)
ALTER TABLE public.radio_slots
  ALTER COLUMN winner_track_id DROP NOT NULL;

ALTER TABLE public.radio_slots
  DROP CONSTRAINT radio_slots_winner_track_id_fkey,
  ADD CONSTRAINT radio_slots_winner_track_id_fkey
    FOREIGN KEY (winner_track_id) REFERENCES public.tracks(id) ON DELETE SET NULL;
