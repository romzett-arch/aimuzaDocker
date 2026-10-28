-- End-user feature tables previously relied on the API owner's unrestricted
-- connection. Keep feature checks in the API and add a database row boundary.
CREATE OR REPLACE FUNCTION public.security_feature_row_access(p_table text,p_row jsonb,p_write boolean)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid:=auth.uid(); owner_id text; parent jsonb; visible boolean:=false; owned boolean;
BEGIN
 IF actor IS NOT NULL AND EXISTS(SELECT 1 FROM user_roles WHERE user_id=actor AND role::text IN ('admin','super_admin')) THEN RETURN true; END IF;
 IF actor IS NOT NULL AND p_table IN ('forum_topics','forum_posts','bug_reports','comment_reports','track_comments','copyright_requests','track_health_reports')
   AND EXISTS(SELECT 1 FROM user_roles WHERE user_id=actor AND role::text='moderator') THEN RETURN true; END IF;
 owner_id:=CASE p_table
   WHEN 'user_follows' THEN p_row->>'follower_id'
   WHEN 'comment_mentions' THEN p_row->>'mentioned_user_id'
   ELSE COALESCE(p_row->>'user_id',p_row->>'author_id',p_row->>'created_by') END;
 owned:=actor IS NOT NULL AND owner_id=actor::text;

 IF p_table IN ('copyright_requests','track_health_reports','track_daily_stats','track_deposits') THEN
   IF p_write THEN RETURN false; END IF;
   RETURN COALESCE(owned,false) OR EXISTS(SELECT 1 FROM tracks WHERE id=NULLIF(p_row->>'track_id','')::uuid AND user_id=actor);
 END IF;
 IF p_table IN ('audio_separations','generation_logs','generation_queue','track_promotions','user_subscriptions','forum_promo_slots','contest_asset_downloads') THEN
   RETURN NOT p_write AND COALESCE(owned,false);
 END IF;
 IF p_table IN ('announcement_dismissals','bug_reports','forum_activity_log','forum_bookmarks','forum_category_subscriptions','forum_drafts','forum_topic_subscriptions','forum_user_reads','generated_lyrics','promo_videos','comment_reports','track_votes') THEN
   RETURN COALESCE(owned,false);
 END IF;
 IF p_table='admin_announcements' THEN
   RETURN NOT p_write AND COALESCE((p_row->>'is_published')::boolean,false)
    AND (p_row->>'publish_at' IS NULL OR (p_row->>'publish_at')::timestamptz<=now())
    AND (p_row->>'expires_at' IS NULL OR (p_row->>'expires_at')::timestamptz>=now());
 END IF;
 IF p_table='user_follows' THEN RETURN NOT p_write OR COALESCE(owned,false); END IF;
 IF p_table='playlist_tracks' THEN
   RETURN EXISTS(SELECT 1 FROM playlists WHERE id=NULLIF(p_row->>'playlist_id','')::uuid
    AND (user_id=actor OR (NOT p_write AND is_public IS TRUE)));
 END IF;
 IF p_table IN ('forum_categories','forum_tags') THEN
   RETURN NOT p_write AND (p_table='forum_tags' OR (COALESCE((p_row->>'is_active')::boolean,true) AND NOT COALESCE((p_row->>'is_hidden')::boolean,false)));
 END IF;
 IF p_table='forum_topics' THEN
   SELECT to_jsonb(c) INTO parent FROM forum_categories c WHERE id=NULLIF(p_row->>'category_id','')::uuid;
   visible:=parent IS NOT NULL AND NOT COALESCE((p_row->>'is_hidden')::boolean,false)
    AND security_feature_row_access('forum_categories',parent,false);
   RETURN visible AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 IF p_table IN ('forum_posts','forum_polls','forum_topic_tags') THEN
   SELECT to_jsonb(t) INTO parent FROM forum_topics t WHERE id=NULLIF(p_row->>'topic_id','')::uuid;
   visible:=parent IS NOT NULL AND security_feature_row_access('forum_topics',parent,false)
    AND NOT COALESCE((p_row->>'is_hidden')::boolean,false);
   IF p_write AND p_table IN ('forum_polls','forum_topic_tags') THEN owned:=parent->>'user_id'=actor::text; END IF;
   RETURN visible AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 IF p_table IN ('forum_poll_options','forum_poll_votes') THEN
   SELECT to_jsonb(p) INTO parent FROM forum_polls p WHERE id=NULLIF(p_row->>'poll_id','')::uuid;
   visible:=parent IS NOT NULL AND security_feature_row_access('forum_polls',parent,false);
   IF p_write AND p_table='forum_poll_options' THEN
    SELECT user_id=actor INTO owned FROM forum_topics WHERE id=NULLIF(parent->>'topic_id','')::uuid;
   END IF;
   RETURN visible AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 IF p_table='track_comments' THEN
   visible:=EXISTS(SELECT 1 FROM tracks WHERE id=NULLIF(p_row->>'track_id','')::uuid
     AND (user_id=actor OR (is_public IS TRUE AND status='completed' AND moderation_status='approved')))
     AND NOT COALESCE((p_row->>'is_hidden')::boolean,false);
   RETURN visible AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 IF p_table IN ('comment_likes','comment_reactions','comment_mentions') THEN
   SELECT to_jsonb(c) INTO parent FROM track_comments c WHERE id=NULLIF(p_row->>'comment_id','')::uuid;
   visible:=parent IS NOT NULL AND security_feature_row_access('track_comments',parent,false);
   IF p_write AND p_table='comment_mentions' THEN owned:=parent->>'user_id'=actor::text; END IF;
   RETURN visible AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 IF p_table='contests' THEN RETURN NOT p_write AND p_row->>'status' IN ('active','voting','completed'); END IF;
 IF p_table='contest_jury' THEN RETURN NOT p_write AND COALESCE(owned,false); END IF;
 IF p_table='contest_jury_scores' THEN
   RETURN EXISTS(SELECT 1 FROM contest_jury j JOIN contest_entries e ON e.contest_id=j.contest_id
    WHERE j.id=NULLIF(p_row->>'jury_id','')::uuid AND j.user_id=actor
    AND e.id=NULLIF(p_row->>'entry_id','')::uuid AND j.contest_id=NULLIF(p_row->>'contest_id','')::uuid);
 END IF;
 IF p_table IN ('contest_entries','contest_winners','contest_votes','contest_entry_comments') THEN
   SELECT to_jsonb(c) INTO parent FROM contests c WHERE id=NULLIF(p_row->>'contest_id','')::uuid;
   IF parent IS NULL AND p_row->>'entry_id' IS NOT NULL THEN
    SELECT to_jsonb(c) INTO parent FROM contests c JOIN contest_entries e ON e.contest_id=c.id WHERE e.id=(p_row->>'entry_id')::uuid;
   END IF;
   visible:=parent IS NOT NULL AND security_feature_row_access('contests',parent,false);
   IF p_table IN ('contest_entries','contest_winners') AND p_write THEN RETURN false; END IF;
   IF p_table='contest_votes' AND NOT p_write THEN RETURN COALESCE(owned,false); END IF;
   RETURN (visible OR (NOT p_write AND COALESCE(owned,false))) AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 IF p_table='contest_comment_likes' THEN
   SELECT to_jsonb(c) INTO parent FROM contest_entry_comments c WHERE id=NULLIF(p_row->>'comment_id','')::uuid;
   RETURN parent IS NOT NULL AND security_feature_row_access('contest_entry_comments',parent,false) AND (NOT p_write OR COALESCE(owned,false));
 END IF;
 RETURN false;
EXCEPTION WHEN invalid_text_representation THEN RETURN false;
END $$;

REVOKE ALL ON FUNCTION public.security_feature_row_access(text,jsonb,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.security_feature_row_access(text,jsonb,boolean) TO anon,authenticated,service_role;
