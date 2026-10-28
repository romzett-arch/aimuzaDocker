const PUBLIC_CATALOG = new Set(['genres','genre_categories','vocal_types','artist_styles']);
const TABLES = new Set([...PUBLIC_CATALOG,'tracks','profiles','messages','conversations','conversation_participants','message_reactions','notifications','payments','balance_transactions','user_roles','track_addons','audio_separations','user_subscriptions','lyrics_items','generated_lyrics','user_prompts','playlists','playlist_tracks','support_tickets','ticket_messages','qa_tickets','qa_comments','silk_releases','release_packages','forum_topics','forum_posts']);
const PUBLIC_TRACK_COLUMNS = new Set(['id','title','user_id','is_public','moderation_status','status','likes_count','plays_count','comments_count','updated_at']);
export function canSubscribe(table,schema,user) {
  return schema==='public' && TABLES.has(table) && (!!user?.id || PUBLIC_CATALOG.has(table) || table==='tracks');
}
export function publicRecord(table,record,user) {
  if (!record) return null;
  if (table==='tracks' && record.user_id !== user?.id) return Object.fromEntries(Object.entries(record).filter(([key])=>PUBLIC_TRACK_COLUMNS.has(key)));
  return record;
}
export function createRealtimeSecurity(pool,jwt,secret) {
  if (!jwt || !secret) throw new Error('Realtime requires JWT validation');
  async function validate(token) {
    const claims=jwt.verify(token,secret,{algorithms:['HS256']});
    if (claims.role==='anon') return null;
    if (!claims.sub || claims.role!=='authenticated') throw Error('Invalid identity');
    const {rows}=await pool.query(`SELECT id,COALESCE(raw_user_meta_data->>'session_version','0') AS version FROM auth.users WHERE id=$1 AND email_confirmed_at IS NOT NULL`,[claims.sub]);
    if (!rows.length || String(claims.session_version??0)!==rows[0].version) throw Error('Session revoked');
    return {id:claims.sub,exp:claims.exp,email:claims.email};
  }
  async function readable(ws,table,row) {
    if(ws.token && ws.user?.id) {
      try {ws.user=await validate(ws.token);} catch {ws.user=null;}
    }
    if (!row || !canSubscribe(table,'public',ws.user)) return false;
    if (PUBLIC_CATALOG.has(table)) return true;
    if (table==='tracks' && row.is_public===true && row.status==='completed' && row.moderation_status==='approved') return true;
    if (!ws.token || !ws.user?.id) return false;
    if (['messages','conversations','conversation_participants','message_reactions'].includes(table)) {
      const conversationId=table==='conversations' ? row.id : row.conversation_id;
      const sql=table==='message_reactions'
        ? 'SELECT 1 FROM public.conversation_participants cp JOIN public.messages m ON m.conversation_id=cp.conversation_id WHERE m.id=$1 AND cp.user_id=$2'
        : 'SELECT 1 FROM public.conversation_participants WHERE conversation_id=$1 AND user_id=$2';
      return (await pool.query(sql,[table==='message_reactions'?row.message_id:conversationId,ws.user.id])).rowCount>0;
    }
    return row.user_id===ws.user.id || row.recipient_id===ws.user.id;
  }
  async function presenceAllowed(user,topic) {
    if(!user?.id) return false;
    const name=String(topic).replace(/^realtime:/,'');
    if(name==='online-users') return true;
    const typing=name.match(/^typing:([a-f0-9-]{36})$/i);
    if(typing) return (await pool.query('SELECT 1 FROM public.conversation_participants WHERE conversation_id=$1 AND user_id=$2',[typing[1],user.id])).rowCount>0;
    const comments=name.match(/^comment_typing:([a-f0-9-]{36})$/i);
    if(comments) return (await pool.query("SELECT 1 FROM tracks WHERE id=$1 AND (user_id=$2 OR (is_public IS TRUE AND status='completed' AND moderation_status='approved'))",[comments[1],user.id])).rowCount>0;
    const forum=name.match(/^forum_presence:([a-f0-9-]{36})$/i);
    if(forum) return (await pool.query('SELECT 1 FROM forum_topics t JOIN forum_categories c ON c.id=t.category_id WHERE t.id=$1 AND t.is_hidden IS FALSE AND c.is_hidden IS FALSE AND c.is_active IS TRUE',[forum[1]])).rowCount>0;
    return false;
  }
  return {validate,readable,presenceAllowed};
}
