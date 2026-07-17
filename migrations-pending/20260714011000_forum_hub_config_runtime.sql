-- Make every exposed Forum Hub setting authoritative at runtime.

CREATE OR REPLACE FUNCTION public.forum_validate_hub_config()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_sum numeric;
BEGIN
  IF jsonb_typeof(NEW.value) <> 'object' THEN RAISE EXCEPTION 'Конфигурация % должна быть объектом', NEW.key; END IF;

  IF NEW.key = 'authority' THEN
    IF (NEW.value->>'reader_min')::numeric < 0
       OR (NEW.value->>'reader_min')::numeric > (NEW.value->>'contributor_min')::numeric
       OR (NEW.value->>'contributor_min')::numeric > (NEW.value->>'mentor_min')::numeric
       OR (NEW.value->>'mentor_min')::numeric > (NEW.value->>'moderator_min')::numeric THEN
      RAISE EXCEPTION 'Пороги Authority должны возрастать';
    END IF;
  ELSIF NEW.key = 'economy' THEN
    IF (NEW.value->>'boost_standard_cost')::integer < 1
       OR (NEW.value->>'boost_premium_cost')::integer < 1
       OR (NEW.value->>'boost_mega_cost')::integer < 1
       OR (NEW.value->>'boost_standard_hours')::integer < 1
       OR (NEW.value->>'boost_premium_hours')::integer < 1
       OR (NEW.value->>'boost_mega_hours')::integer < 1
       OR (NEW.value->>'author_revenue_share')::numeric NOT BETWEEN 0 AND 1 THEN
      RAISE EXCEPTION 'Некорректная экономика форума';
    END IF;
  ELSIF NEW.key = 'semantic' THEN
    IF (NEW.value->>'similarity_threshold')::numeric NOT BETWEEN 0 AND 1
       OR (NEW.value->>'max_similar_topics')::integer NOT BETWEEN 1 AND 20 THEN
      RAISE EXCEPTION 'Некорректные настройки похожих тем';
    END IF;
  ELSIF NEW.key = 'knowledge_base' THEN
    IF (NEW.value->>'auto_promote_quality_min')::numeric NOT BETWEEN 0 AND 10
       OR (NEW.value->>'min_word_count_article')::integer NOT BETWEEN 50 AND 5000 THEN
      RAISE EXCEPTION 'Некорректные настройки базы знаний';
    END IF;
  ELSIF NEW.key = 'quality' THEN
    IF (NEW.value->>'min_quality_for_kb')::numeric NOT BETWEEN 0 AND 10 THEN RAISE EXCEPTION 'Некорректный порог качества'; END IF;
    SELECT sum(value::numeric) INTO v_sum FROM jsonb_each_text(NEW.value->'quality_weights');
    IF abs(COALESCE(v_sum, 0) - 1) > 0.001 THEN RAISE EXCEPTION 'Сумма весов качества должна быть 1.0'; END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_validate_hub_config ON public.forum_hub_config;
CREATE TRIGGER trg_forum_validate_hub_config
BEFORE INSERT OR UPDATE OF value ON public.forum_hub_config
FOR EACH ROW EXECUTE FUNCTION public.forum_validate_hub_config();

CREATE OR REPLACE FUNCTION public.forum_validate_premium_content()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_topic_author uuid;
  v_min_authority numeric;
  v_authority numeric := 0;
  v_is_admin boolean := false;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  v_is_admin := public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin');
  IF NOT v_is_admin AND v_actor <> NEW.author_id THEN RAISE EXCEPTION 'Нельзя публиковать премиальный материал от имени другого автора'; END IF;

  SELECT user_id INTO v_topic_author FROM public.forum_topics WHERE id = NEW.topic_id;
  IF v_topic_author IS NULL THEN RAISE EXCEPTION 'Тема не найдена'; END IF;
  IF NEW.author_id <> v_topic_author THEN RAISE EXCEPTION 'Автор премиального материала должен совпадать с автором темы'; END IF;
  IF NEW.price_credits <= 0 THEN RAISE EXCEPTION 'Цена должна быть положительной'; END IF;

  SELECT COALESCE((value->>'premium_min_authority')::numeric, 50)
    INTO v_min_authority FROM public.forum_hub_config WHERE key = 'economy';
  SELECT COALESCE(authority_score, 0) INTO v_authority FROM public.forum_user_stats WHERE user_id = NEW.author_id;
  IF NOT v_is_admin AND COALESCE(v_authority, 0) < COALESCE(v_min_authority, 50) THEN
    RAISE EXCEPTION 'Недостаточный уровень Authority для премиального материала';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_validate_premium_content ON public.forum_premium_content;
CREATE TRIGGER trg_forum_validate_premium_content
BEFORE INSERT OR UPDATE OF topic_id, author_id, price_credits, is_active ON public.forum_premium_content
FOR EACH ROW EXECUTE FUNCTION public.forum_validate_premium_content();

CREATE OR REPLACE FUNCTION public.forum_recalculate_authority(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_cfg jsonb;
  v_quality_avg numeric := 0;
  v_solutions integer := 0;
  v_citations integer := 0;
  v_reputation numeric := 0;
  v_score numeric;
  v_tier text;
  v_expertise text[] := '{}';
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF v_actor <> p_user_id AND NOT (
    public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin') OR public.has_role(v_actor, 'moderator')
  ) THEN RAISE EXCEPTION 'Нельзя пересчитывать другого пользователя'; END IF;

  INSERT INTO public.forum_user_stats(user_id) VALUES(p_user_id) ON CONFLICT(user_id) DO NOTHING;
  SELECT value INTO v_cfg FROM public.forum_hub_config WHERE key='authority';
  SELECT COALESCE(avg(overall_quality),0) INTO v_quality_avg FROM public.forum_content_quality WHERE author_id=p_user_id;
  SELECT COALESCE(solutions_count,0), COALESCE(reputation_score,0) INTO v_solutions,v_reputation FROM public.forum_user_stats WHERE user_id=p_user_id;
  SELECT count(*) INTO v_citations FROM public.forum_citations c JOIN public.forum_knowledge_articles a ON a.id=c.article_id WHERE a.author_id=p_user_id;
  SELECT COALESCE(array_agg(tag_name ORDER BY avg_quality DESC), '{}') INTO v_expertise FROM (
    SELECT unnest(t.tags) tag_name, avg(q.overall_quality) avg_quality
    FROM public.forum_topics t JOIN public.forum_content_quality q ON q.content_type='topic' AND q.content_id=t.id
    WHERE t.user_id=p_user_id GROUP BY tag_name ORDER BY avg_quality DESC LIMIT 5
  ) ranked;

  v_score := round((v_quality_avg*10 + v_solutions*5 + v_citations*3 + v_reputation*0.1)::numeric,2);
  v_tier := CASE
    WHEN v_score >= (v_cfg->>'moderator_min')::numeric THEN 'moderator'
    WHEN v_score >= (v_cfg->>'mentor_min')::numeric THEN 'mentor'
    WHEN v_score >= (v_cfg->>'contributor_min')::numeric THEN 'contributor'
    ELSE 'reader' END;
  UPDATE public.forum_user_stats SET authority_score=v_score,authority_tier=v_tier,content_quality_avg=v_quality_avg,citations_received=v_citations,
    expertise_tags=v_expertise,can_create_articles=(v_score>=50),can_boost_topics=(v_score>=20),authority_updated_at=now() WHERE user_id=p_user_id;
  RETURN jsonb_build_object('score',v_score,'tier',v_tier,'quality_avg',v_quality_avg,'solutions',v_solutions,'citations',v_citations,'expertise',v_expertise);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_calculate_content_quality(p_content_type text, p_content_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid(); v_content text; v_html text; v_title text; v_author uuid; v_category uuid; v_tags text[];
  v_votes integer:=0; v_solution boolean:=false; v_words integer; v_depth numeric:=0; v_useful numeric:=0; v_engage numeric:=0; v_unique numeric:=0; v_overall numeric:=0; v_weighted numeric:=0;
  v_code boolean; v_images boolean; v_links boolean; v_cfg jsonb; v_kb jsonb; v_authority_cfg jsonb; v_weights jsonb; v_solution_bonus numeric; v_code_bonus numeric; v_image_bonus numeric; v_link_bonus numeric;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF p_content_type='topic' THEN
    SELECT content,content_html,title,user_id,category_id,tags,votes_score,is_solved INTO v_content,v_html,v_title,v_author,v_category,v_tags,v_votes,v_solution FROM public.forum_topics WHERE id=p_content_id;
  ELSIF p_content_type='post' THEN
    SELECT content,content_html,NULL,user_id,NULL,NULL,votes_score,is_solution INTO v_content,v_html,v_title,v_author,v_category,v_tags,v_votes,v_solution FROM public.forum_posts WHERE id=p_content_id;
  ELSE RAISE EXCEPTION 'Некорректный тип контента'; END IF;
  IF v_author IS NULL THEN RAISE EXCEPTION 'Контент не найден'; END IF;
  IF v_actor<>v_author AND NOT (public.has_role(v_actor,'admin') OR public.has_role(v_actor,'super_admin') OR public.has_role(v_actor,'moderator')) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;

  SELECT value INTO v_cfg FROM public.forum_hub_config WHERE key='quality'; SELECT value INTO v_kb FROM public.forum_hub_config WHERE key='knowledge_base'; SELECT value INTO v_authority_cfg FROM public.forum_hub_config WHERE key='authority';
  v_weights:=v_cfg->'quality_weights'; v_solution_bonus:=COALESCE((v_cfg->>'solution_bonus')::numeric,5); v_code_bonus:=COALESCE((v_cfg->>'code_block_bonus')::numeric,2);
  v_image_bonus:=COALESCE((v_cfg->>'image_bonus')::numeric,1.5); v_link_bonus:=COALESCE((v_cfg->>'link_bonus')::numeric,1);
  v_words:=COALESCE(array_length(regexp_split_to_array(trim(v_content),'\s+'),1),0); v_code:=v_content LIKE '%```%'; v_images:=v_content LIKE '%![%' OR COALESCE(v_html,'') LIKE '%<img%'; v_links:=v_content LIKE '%http%';
  v_depth:=LEAST(10,(v_words::numeric/50)*3 + CASE WHEN v_code THEN v_code_bonus ELSE 0 END + CASE WHEN v_images THEN v_image_bonus ELSE 0 END + CASE WHEN v_links THEN v_link_bonus ELSE 0 END + CASE WHEN v_words>200 THEN 2 ELSE 0 END);
  v_useful:=LEAST(10,GREATEST(0,v_votes)*2 + CASE WHEN v_solution THEN v_solution_bonus ELSE 0 END);
  IF p_content_type='post' THEN SELECT COALESCE(sum(CASE s.authority_tier WHEN 'moderator' THEN COALESCE((v_authority_cfg->>'vote_weight_moderator')::numeric,3) WHEN 'mentor' THEN COALESCE((v_authority_cfg->>'vote_weight_mentor')::numeric,2) WHEN 'contributor' THEN COALESCE((v_authority_cfg->>'vote_weight_contributor')::numeric,1.5) ELSE COALESCE((v_authority_cfg->>'vote_weight_reader')::numeric,1) END),0) INTO v_weighted FROM public.forum_post_votes pv LEFT JOIN public.forum_user_stats s ON s.user_id=pv.user_id WHERE pv.post_id=p_content_id AND pv.vote_type>0; ELSE v_weighted:=GREATEST(0,v_votes); END IF;
  v_engage:=LEAST(10,v_weighted*1.5); v_unique:=LEAST(10,v_depth*.5+CASE WHEN v_code THEN 2 ELSE 0 END);
  v_overall:=round((v_depth*COALESCE((v_weights->>'depth')::numeric,.3)+v_useful*COALESCE((v_weights->>'usefulness')::numeric,.35)+v_engage*COALESCE((v_weights->>'engagement')::numeric,.2)+v_unique*COALESCE((v_weights->>'uniqueness')::numeric,.15))::numeric,2);
  INSERT INTO public.forum_content_quality(content_type,content_id,author_id,depth_score,usefulness_score,engagement_score,uniqueness_score,overall_quality,word_count,has_code_blocks,has_images,has_links,weighted_votes,solution_bonus,computed_at)
  VALUES(p_content_type,p_content_id,v_author,v_depth,v_useful,v_engage,v_unique,v_overall,v_words,v_code,v_images,v_links,v_weighted,CASE WHEN v_solution THEN v_solution_bonus ELSE 0 END,now())
  ON CONFLICT(content_type,content_id) DO UPDATE SET depth_score=excluded.depth_score,usefulness_score=excluded.usefulness_score,engagement_score=excluded.engagement_score,uniqueness_score=excluded.uniqueness_score,overall_quality=excluded.overall_quality,word_count=excluded.word_count,has_code_blocks=excluded.has_code_blocks,has_images=excluded.has_images,has_links=excluded.has_links,weighted_votes=excluded.weighted_votes,solution_bonus=excluded.solution_bonus,computed_at=now();
  IF p_content_type='topic' AND v_words>=COALESCE((v_kb->>'min_word_count_article')::integer,200) AND v_overall>=GREATEST(COALESCE((v_kb->>'auto_promote_quality_min')::numeric,8),COALESCE((v_cfg->>'min_quality_for_kb')::numeric,7)) THEN
    INSERT INTO public.forum_knowledge_articles(source_topic_id,title,summary,content,content_html,tags,author_id,status,quality_score)
    VALUES(p_content_id,v_title,left(regexp_replace(v_content,'\s+',' ','g'),300),v_content,v_html,COALESCE(v_tags,'{}'),v_author,'draft',v_overall) ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_overall;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_boost_topic(p_topic_id uuid,p_boost_type text DEFAULT 'standard',p_duration_hours integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_user uuid:=auth.uid(); v_cfg jsonb; v_cost integer; v_hours integer; v_mult numeric; v_balance integer; v_allowed boolean;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF p_boost_type NOT IN ('standard','premium','mega') THEN RAISE EXCEPTION 'Неверный тип буста'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.forum_topics WHERE id=p_topic_id AND NOT is_hidden) THEN RAISE EXCEPTION 'Тема не найдена'; END IF;
  SELECT value INTO v_cfg FROM public.forum_hub_config WHERE key='economy';
  v_cost:=(v_cfg->>('boost_'||p_boost_type||'_cost'))::integer; v_hours:=(v_cfg->>('boost_'||p_boost_type||'_hours'))::integer;
  v_mult:=CASE p_boost_type WHEN 'standard' THEN 1.5 WHEN 'premium' THEN 3 ELSE 5 END;
  SELECT COALESCE(can_boost_topics,false) INTO v_allowed FROM public.forum_user_stats WHERE user_id=v_user;
  IF NOT COALESCE(v_allowed,false) THEN RAISE EXCEPTION 'Недостаточный уровень Authority для буста'; END IF;
  SELECT credits INTO v_balance FROM public.profiles WHERE user_id=v_user FOR UPDATE; IF COALESCE(v_balance,0)<v_cost THEN RETURN jsonb_build_object('success',false,'error','Insufficient credits','required',v_cost,'balance',COALESCE(v_balance,0)); END IF;
  UPDATE public.profiles SET credits=credits-v_cost WHERE user_id=v_user;
  INSERT INTO public.forum_topic_boosts(topic_id,boosted_by,boost_type,credits_spent,boost_multiplier,ends_at) VALUES(p_topic_id,v_user,p_boost_type,v_cost,v_mult,now()+make_interval(hours=>v_hours));
  UPDATE public.forum_topics SET bumped_at=now() WHERE id=p_topic_id;
  RETURN jsonb_build_object('success',true,'cost',v_cost,'multiplier',v_mult,'hours',v_hours);
END; $$;

CREATE OR REPLACE FUNCTION public.forum_find_similar_topics(p_title text,p_category_id uuid DEFAULT NULL,p_threshold numeric DEFAULT NULL,p_limit integer DEFAULT NULL)
RETURNS TABLE(id uuid,title text,slug text,category_id uuid,status text,votes_score integer,is_solved boolean,similarity numeric,created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cfg jsonb; v_threshold numeric; v_limit integer;
BEGIN
  SELECT value INTO v_cfg FROM public.forum_hub_config WHERE key='semantic';
  IF NOT COALESCE((v_cfg->>'auto_suggest_on_create')::boolean,true) THEN RETURN; END IF;
  v_threshold:=COALESCE(p_threshold,(v_cfg->>'similarity_threshold')::numeric,.25); v_limit:=LEAST(20,COALESCE(p_limit,(v_cfg->>'max_similar_topics')::integer,5));
  RETURN QUERY SELECT t.id,t.title,t.slug,t.category_id,CASE WHEN t.is_locked THEN 'locked' ELSE 'active' END,t.votes_score,t.is_solved,round(similarity(t.title,p_title)::numeric,3),t.created_at FROM public.forum_topics t
  WHERE similarity(t.title,p_title)>v_threshold AND NOT t.is_hidden AND (p_category_id IS NULL OR t.category_id=p_category_id) ORDER BY similarity(t.title,p_title) DESC LIMIT v_limit;
END; $$;

CREATE OR REPLACE FUNCTION public.forum_purchase_premium_content(p_topic_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_buyer uuid:=auth.uid(); v_content public.forum_premium_content%ROWTYPE; v_credits integer; v_cfg jsonb; v_share numeric; v_author_income integer;
BEGIN
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  SELECT * INTO v_content FROM public.forum_premium_content WHERE topic_id=p_topic_id AND is_active FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Премиальный материал не найден'; END IF;
  IF v_content.price_credits <= 0 THEN RAISE EXCEPTION 'Некорректная цена премиального материала'; END IF;
  IF v_content.author_id=v_buyer THEN RETURN jsonb_build_object('success',true,'already_purchased',true,'owner',true); END IF;
  IF EXISTS(SELECT 1 FROM public.forum_content_purchases WHERE topic_id=p_topic_id AND buyer_id=v_buyer) THEN RETURN jsonb_build_object('success',true,'already_purchased',true); END IF;
  SELECT credits INTO v_credits FROM public.profiles WHERE user_id=v_buyer FOR UPDATE; IF COALESCE(v_credits,0)<v_content.price_credits THEN RAISE EXCEPTION 'Недостаточно кредитов'; END IF;
  SELECT value INTO v_cfg FROM public.forum_hub_config WHERE key='economy'; v_share:=LEAST(1,GREATEST(0,COALESCE((v_cfg->>'author_revenue_share')::numeric,.7))); v_author_income:=floor(v_content.price_credits*v_share);
  UPDATE public.profiles SET credits=credits-v_content.price_credits WHERE user_id=v_buyer;
  UPDATE public.profiles SET credits=COALESCE(credits,0)+v_author_income WHERE user_id=v_content.author_id;
  INSERT INTO public.forum_content_purchases(topic_id,buyer_id,price_paid) VALUES(p_topic_id,v_buyer,v_content.price_credits);
  UPDATE public.forum_premium_content SET purchases_count=purchases_count+1,revenue_total=revenue_total+v_content.price_credits WHERE id=v_content.id;
  RETURN jsonb_build_object('success',true,'already_purchased',false,'price_paid',v_content.price_credits,'author_income',v_author_income);
END; $$;

CREATE OR REPLACE FUNCTION public.forum_get_hub_stats()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  RETURN jsonb_build_object(
    'total_articles', (SELECT count(*) FROM public.forum_knowledge_articles WHERE status = 'published'),
    'draft_articles', (SELECT count(*) FROM public.forum_knowledge_articles WHERE status = 'draft'),
    'total_citations', (SELECT count(*) FROM public.forum_citations),
    'active_boosts', (SELECT count(*) FROM public.forum_topic_boosts WHERE is_active AND ends_at > now()),
    'total_boost_revenue', (SELECT COALESCE(sum(credits_spent), 0) FROM public.forum_topic_boosts),
    'avg_content_quality', (SELECT round(COALESCE(avg(overall_quality), 0)::numeric, 2) FROM public.forum_content_quality),
    'high_quality_count', (SELECT count(*) FROM public.forum_content_quality WHERE overall_quality >= 7),
    'mentors_count', (SELECT count(*) FROM public.forum_user_stats WHERE authority_tier = 'mentor'),
    'moderators_count', (SELECT count(*) FROM public.forum_user_stats WHERE authority_tier = 'moderator'),
    'contributors_count', (SELECT count(*) FROM public.forum_user_stats WHERE authority_tier = 'contributor'),
    'clusters_count', (SELECT count(*) FROM public.forum_topic_clusters),
    'premium_content', (SELECT count(*) FROM public.forum_premium_content WHERE is_active)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.forum_recalculate_authority(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_calculate_content_quality(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_boost_topic(uuid,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_purchase_premium_content(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_get_hub_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_recalculate_authority(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_calculate_content_quality(text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_boost_topic(uuid,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_purchase_premium_content(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_get_hub_stats() TO authenticated;
