SELECT user_id, COUNT(*) as listens_today, SUM(xp_earned) as xp_today FROM radio_listens WHERE user_id = '17129225-7a09-409b-91b2-05d9c473a920' AND created_at >= CURRENT_DATE GROUP BY user_id;
