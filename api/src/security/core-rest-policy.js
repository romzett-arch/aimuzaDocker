// A default-deny boundary independent of individual feature policies and RLS.
import tables from './rest-table-manifest.json' with { type: 'json' };
const KNOWN = new Set(tables);
const INTERNAL = new Set(['email_verifications', 'schema_migration_history']);
const SERVER_WRITES = new Set(['payments','balance_transactions','track_addons','audio_separations','generation_logs','generation_queue','release_packages','lyrics_deposits','track_deposits','seller_earnings','track_royalties','user_subscriptions']);
const PRIVATE = new Set([...SERVER_WRITES,'notifications','generated_lyrics','personas','user_listened_tracks','user_prompts','payout_requests']);
const STAFF = new Set(['api_keys','ai_provider_settings','email_templates','error_logs','performance_alerts','maintenance_whitelist','feed_config','seo_ai_config','seo_bot_visits','song_idea_sources','song_idea_admin_stats','distribution_logs','voting_snapshots','impersonation_action_logs']);
export const PUBLIC_SETTING_KEYS = ['generation_price','max_lyrics_length','max_prompt_length','min_topup_amount','max_topup_amount','commission_percent','deposit_price','site_name','site_description','maintenance_enabled','cover_generation_price','platform_commission_percent','label_commission_percent','subscriber_discount_percent','forum_voting_category_id','price_per_image'];
const PUBLIC_SERVICE_COLUMNS=new Set(['id','name','name_ru','description','description_ru','price_rub','price_aipci','is_active','sort_order','category','icon','created_at','updated_at']);
const PRIVATE_MESSAGE_TABLES = new Set(['messages','conversations','conversation_participants','message_reactions']);
const PUBLIC_PROFILE_COLUMNS = new Set(['id','user_id','username','display_name','avatar_url','bio','created_at','role','is_verified','verification_type']);
export function isCoreAdmin(user) { return user?.role === 'service_role' || ['admin','super_admin','superadmin'].includes(user?.app_role); }
export function accessError(status=403, message='Access denied') {
  return Object.assign(new Error(message), {status,code:'REST_ACCESS_DENIED'});
}
function assertPublicFilters(query,allowed) {
  for(const [key,value] of Object.entries(query)) {
    if(['select','limit','offset','head','on_conflict','columns'].includes(key)) continue;
    if(key==='order') {if(String(value).split(',').some(v=>!allowed.has(v.split('.')[0]))) throw accessError();continue;}
    if(key==='and'||key==='or') {
      for(const match of String(value).matchAll(/(?:^|[,\(])([a-zA-Z_]\w*)\.(?:not\.)?(?:eq|neq|gt|gte|lt|lte|is|like|ilike|in|cs|cd|ov|fts|plfts|phfts|wfts)\./g)) if(!allowed.has(match[1])) throw accessError();
    } else if(!allowed.has(key)) throw accessError();
  }
}
export async function assertCoreRestAccess(table,user,operation,client) {
  if (user?.role === 'service_role') return;
  if (!KNOWN.has(table) || INTERNAL.has(table)) throw accessError();
  if (operation !== 'read' && !user?.id) throw accessError(401,'Authentication required');
  if (STAFF.has(table) && !isCoreAdmin(user)) throw accessError();
  if (SERVER_WRITES.has(table) && operation !== 'read') throw accessError(403,'Server-owned resource');
  if ((PRIVATE.has(table) || PRIVATE_MESSAGE_TABLES.has(table)) && !user?.id) throw accessError(401,'Authentication required');
  if (table === 'settings' && operation !== 'read' && !isCoreAdmin(user)) throw accessError();
  if (PRIVATE_MESSAGE_TABLES.has(table) && operation !== 'read') throw accessError(403,'Use the authorized messaging RPC');
  if (!isCoreAdmin(user) && table !== 'settings') {
    const {rows} = await client.query("SELECT c.relrowsecurity,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname=$1",[table]);
    if (!rows[0]?.relrowsecurity && !['profiles_public'].includes(table)) throw accessError(403,'Resource has no end-user row policy');
  }
}
export function coreScope(table,user,start=1) {
  if (user?.role === 'service_role') return {sql:'',params:[]};
  if(['addon_services','subscription_plans'].includes(table)&&!isCoreAdmin(user)) return {sql:'"is_active" IS TRUE',params:[]};
  if (table === 'settings' && !isCoreAdmin(user)) return {sql:'"key" = ANY($'+start+'::text[])',params:[PUBLIC_SETTING_KEYS]};
  if (PRIVATE_MESSAGE_TABLES.has(table)) {
    const id = table === 'conversations' ? '"id"' : '"conversation_id"';
    if (table === 'message_reactions') return {sql:`EXISTS (SELECT 1 FROM public.messages m JOIN public.conversation_participants cp ON cp.conversation_id=m.conversation_id WHERE m.id=message_reactions.message_id AND cp.user_id=$${start})`,params:[user.id]};
    return {sql:`${id} IN (SELECT conversation_id FROM public.conversation_participants WHERE user_id=$${start})`,params:[user.id]};
  }
  if (PRIVATE.has(table) && !isCoreAdmin(user)) return {sql:`"user_id"=$${start}`,params:[user.id]};
  return {sql:'',params:[]};
}
export function coreReadColumns(table,user,query,columns) {
  if(table==='addon_services'&&!isCoreAdmin(user)) {
    assertPublicFilters(query,PUBLIC_SERVICE_COLUMNS);
    if(columns==='*')return [...PUBLIC_SERVICE_COLUMNS].map(c=>`"${c}"`).join(',');
    for(const name of columns.matchAll(/"([a-zA-Z_][a-zA-Z0-9_]*)"/g))if(!PUBLIC_SERVICE_COLUMNS.has(name[1]))throw accessError();
    return columns;
  }
  if (table !== 'profiles' || user?.role==='service_role' || isCoreAdmin(user) || (user?.id && query.user_id === `eq.${user.id}`)) return columns;
  assertPublicFilters(query,PUBLIC_PROFILE_COLUMNS);
  if (columns === '*') return [...PUBLIC_PROFILE_COLUMNS].map(c=>`"${c}"`).join(',');
  // Embeds are already separately restricted by parseSelect.
  for (const name of columns.matchAll(/"([a-zA-Z_][a-zA-Z0-9_]*)"/g)) if (!PUBLIC_PROFILE_COLUMNS.has(name[1])) throw accessError();
  return columns;
}
export function assertJoinColumns(table,columns,user) {
  if (user?.role==='service_role') return;
  if (table==='profiles' || table==='profiles_public') {
    if (columns.every(c=>PUBLIC_PROFILE_COLUMNS.has(c))) return;
  } else if (['genres','genre_categories','vocal_types','artist_styles'].includes(table) && columns.every(c=>['id','name','name_ru','slug','icon','color','description','category_id'].includes(c))) return;
  throw accessError(403,'Embedded selection is not public');
}
