-- Allow admins to delete radio_ad_placements
CREATE POLICY "Admins can delete radio_ad_placements"
ON public.radio_ad_placements FOR DELETE
TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);
