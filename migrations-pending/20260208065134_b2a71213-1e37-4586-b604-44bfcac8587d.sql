
CREATE OR REPLACE FUNCTION public.forum_notify_warning()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _link TEXT;
BEGIN
  -- Build specific link: prefer topic, fallback to /forum
  IF NEW.topic_id IS NOT NULL THEN
    _link := '/forum/t/' || NEW.topic_id;
  ELSE
    _link := '/forum';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, message, link, metadata)
  VALUES (
    NEW.user_id,
    'forum_warning',
    'Предупреждение на форуме',
    NEW.reason,
    _link,
    jsonb_build_object(
      'warning_id', NEW.id, 
      'severity', NEW.severity,
      'topic_id', NEW.topic_id,
      'post_id', NEW.post_id
    )
  );
  RETURN NEW;
END;
$function$;
