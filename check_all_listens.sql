SELECT user_id, COUNT(*) as total_listens, SUM(xp_earned) as total_xp, MAX(created_at) as last_listen FROM radio_listens WHERE user_id = '17129225-7a09-409b-91b2-05d9c473a920' GROUP BY user_id;
