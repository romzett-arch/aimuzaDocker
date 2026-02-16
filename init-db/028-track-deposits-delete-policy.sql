-- Пользователь может удалять свои незавершённые депонирования (для повторной попытки)
DROP POLICY IF EXISTS "Users can delete own non-completed deposits" ON public.track_deposits;
CREATE POLICY "Users can delete own non-completed deposits"
ON public.track_deposits FOR DELETE
USING (
  auth.uid() = user_id AND
  status IN ('pending', 'processing', 'failed')
);
