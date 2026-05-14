CREATE OR REPLACE FUNCTION forum_prevent_self_report()
RETURNS TRIGGER AS $$
DECLARE
  target_user_id UUID;
BEGIN
  IF NEW.post_id IS NOT NULL THEN
    SELECT user_id INTO target_user_id FROM forum_posts WHERE id = NEW.post_id;
  ELSIF NEW.topic_id IS NOT NULL THEN
    SELECT user_id INTO target_user_id FROM forum_topics WHERE id = NEW.topic_id;
  END IF;

  IF target_user_id = NEW.reporter_id THEN
    RAISE EXCEPTION 'Нельзя пожаловаться на свой контент';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;