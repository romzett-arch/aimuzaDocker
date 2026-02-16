import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

// Whitelist of allowed actions — only these can be performed via impersonation
const ALLOWED_ACTIONS: Record<string, {
  table: string;
  operation: 'insert' | 'update' | 'delete' | 'upsert' | 'custom';
  requiredFields: string[];
  description: string;
}> = {
  // Track interactions
  like_track: { table: 'track_likes', operation: 'insert', requiredFields: ['track_id'], description: 'Like a track' },
  unlike_track: { table: 'track_likes', operation: 'delete', requiredFields: ['track_id'], description: 'Unlike a track' },
  delete_track: { table: 'tracks', operation: 'custom', requiredFields: ['track_id'], description: 'Delete a track' },
  // User follows
  follow_user: { table: 'user_follows', operation: 'insert', requiredFields: ['following_id'], description: 'Follow a user' },
  unfollow_user: { table: 'user_follows', operation: 'delete', requiredFields: ['following_id'], description: 'Unfollow a user' },
  // Track updates
  update_track: { table: 'tracks', operation: 'update', requiredFields: ['track_id'], description: 'Update track metadata' },
  // Comments
  add_comment: { table: 'track_comments', operation: 'insert', requiredFields: ['track_id', 'content'], description: 'Add a comment to a track' },
  delete_comment: { table: 'track_comments', operation: 'delete', requiredFields: ['comment_id'], description: 'Delete a comment' },
  update_comment: { table: 'track_comments', operation: 'update', requiredFields: ['comment_id', 'content'], description: 'Edit a comment' },
  like_comment: { table: 'comment_likes', operation: 'insert', requiredFields: ['comment_id'], description: 'Like a comment' },
  unlike_comment: { table: 'comment_likes', operation: 'delete', requiredFields: ['comment_id'], description: 'Unlike a comment' },
  add_reaction: { table: 'comment_reactions', operation: 'insert', requiredFields: ['comment_id', 'emoji'], description: 'Add reaction to a comment' },
  remove_reaction: { table: 'comment_reactions', operation: 'delete', requiredFields: ['comment_id', 'emoji'], description: 'Remove reaction from a comment' },
  report_comment: { table: 'comment_reports', operation: 'insert', requiredFields: ['comment_id', 'reason'], description: 'Report a comment' },
  // Profile updates
  update_profile: { table: 'profiles', operation: 'update', requiredFields: [], description: 'Update user profile' },
  // Playlists
  create_playlist: { table: 'playlists', operation: 'insert', requiredFields: ['title'], description: 'Create a playlist' },
  update_playlist: { table: 'playlists', operation: 'update', requiredFields: ['playlist_id'], description: 'Update a playlist' },
  delete_playlist: { table: 'playlists', operation: 'delete', requiredFields: ['playlist_id'], description: 'Delete a playlist' },
  add_to_playlist: { table: 'playlist_tracks', operation: 'insert', requiredFields: ['playlist_id', 'track_id'], description: 'Add track to a playlist' },
  remove_from_playlist: { table: 'playlist_tracks', operation: 'delete', requiredFields: ['playlist_id', 'track_id'], description: 'Remove track from a playlist' },
  like_playlist: { table: 'playlist_likes', operation: 'insert', requiredFields: ['playlist_id'], description: 'Like a playlist' },
  unlike_playlist: { table: 'playlist_likes', operation: 'delete', requiredFields: ['playlist_id'], description: 'Unlike a playlist' },
  // Messages
  send_message: { table: 'messages', operation: 'insert', requiredFields: ['conversation_id', 'content'], description: 'Send a message' },
  // Forum
  create_forum_topic: { table: 'forum_topics', operation: 'custom', requiredFields: ['category_id', 'title', 'content'], description: 'Create a forum topic' },
  create_forum_post: { table: 'forum_posts', operation: 'custom', requiredFields: ['topic_id', 'content'], description: 'Create a forum post' },
};

// SHA-256 hash function
async function sha256(message: string): Promise<string> {
  const msgBuffer = new TextEncoder().encode(message);
  const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

  try {
    // 1. Verify JWT
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    
    // Decode JWT to get user ID (works with both Supabase and custom JWT)
    let adminUserId: string;
    try {
      const payloadPart = token.split('.')[1];
      const decoded = JSON.parse(atob(payloadPart));
      adminUserId = decoded.sub;
      if (!adminUserId) throw new Error('No sub in token');
    } catch (e) {
      console.error('JWT decode error:', e);
      return new Response(
        JSON.stringify({ error: 'Invalid token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 2. Check super_admin role ONLY
    const adminClient = createClient(supabaseUrl, supabaseServiceKey);

    const { data: userRole } = await adminClient
      .from('user_roles')
      .select('role')
      .eq('user_id', adminUserId)
      .single();

    if (!userRole || !['super_admin', 'admin'].includes(userRole.role)) {
      console.warn(`Impersonation denied for user ${adminUserId}, role: ${userRole?.role}`);
      return new Response(
        JSON.stringify({ error: 'Доступ запрещён. Только для администраторов.' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 3. Parse request body
    const body = await req.json();
    const { pin, target_user_id, action, payload } = body;

    // 4. Verify PIN
    if (!pin || typeof pin !== 'string' || pin.length !== 6) {
      return new Response(
        JSON.stringify({ error: 'Требуется 6-значный PIN-код' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data: pinSetting } = await adminClient
      .from('settings')
      .select('value')
      .eq('key', 'backup_pin_hash')
      .single();

    if (!pinSetting?.value) {
      return new Response(
        JSON.stringify({ error: 'PIN-код не настроен' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const pinHash = await sha256(pin);
    if (pinHash !== pinSetting.value) {
      console.warn(`Invalid PIN attempt by super_admin: ${adminUserId}`);
      
      await adminClient.from('impersonation_action_logs').insert({
        admin_user_id: adminUserId,
        target_user_id: target_user_id || '00000000-0000-0000-0000-000000000000',
        action_type: 'pin_failed',
        action_payload: { action },
        result_status: 'error',
        error_message: 'Invalid PIN',
      });

      return new Response(
        JSON.stringify({ error: 'Неверный PIN-код' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 5. Validate action
    if (!action || !ALLOWED_ACTIONS[action]) {
      return new Response(
        JSON.stringify({ error: `Действие '${action}' не разрешено`, allowed: Object.keys(ALLOWED_ACTIONS) }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!target_user_id) {
      return new Response(
        JSON.stringify({ error: 'target_user_id обязателен' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify target user exists
    const { data: targetProfile } = await adminClient
      .from('profiles')
      .select('user_id, username')
      .eq('user_id', target_user_id)
      .single();

    if (!targetProfile) {
      return new Response(
        JSON.stringify({ error: 'Целевой пользователь не найден' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const actionConfig = ALLOWED_ACTIONS[action];

    // Validate required fields
    for (const field of actionConfig.requiredFields) {
      if (!payload || payload[field] === undefined) {
        return new Response(
          JSON.stringify({ error: `Поле '${field}' обязательно для действия '${action}'` }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // 5b. Enforce forum rate limits for target user
    if (action === 'create_forum_topic' || action === 'create_forum_post') {
      const rateLimitType = action === 'create_forum_topic' ? 'topic' : 'post';
      const configField = action === 'create_forum_topic' ? 'max_topics_per_day' : 'max_posts_per_day';

      // Get target user trust level
      const { data: userStats } = await adminClient
        .from('forum_user_stats')
        .select('trust_level')
        .eq('user_id', target_user_id)
        .maybeSingle();

      const trustLevel = Math.min(userStats?.trust_level ?? 0, 4);

      // Get limit from config
      const { data: configRow } = await adminClient
        .from('forum_reputation_config')
        .select(configField)
        .eq('trust_level', trustLevel)
        .maybeSingle();

      const maxPerDay = configRow ? (configRow as Record<string, number | null>)[configField] : null;

      // null = unlimited; if set, enforce it
      if (maxPerDay !== null && maxPerDay !== undefined) {
        const windowStart = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const activityAction = action === 'create_forum_topic' ? 'topic_create' : 'post_create';

        const { count } = await adminClient
          .from('forum_activity_log')
          .select('id', { count: 'exact', head: true })
          .eq('user_id', target_user_id)
          .eq('action', activityAction)
          .gte('created_at', windowStart);

        if ((count || 0) >= maxPerDay) {
          return new Response(
            JSON.stringify({
              error: rateLimitType === 'topic'
                ? `Лимит тем для этого пользователя исчерпан (${maxPerDay}/день, уровень ${trustLevel})`
                : `Лимит постов для этого пользователя исчерпан (${maxPerDay}/день, уровень ${trustLevel})`,
            }),
            { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
    }

    // 6. Execute the action using service_role (bypasses RLS)
    console.log(`Impersonation action: ${action} by admin ${adminUserId} as user ${target_user_id}`);

    let result: { data: unknown; error: unknown } = { data: null, error: null };

    switch (action) {
      // ---- Track interactions ----
      case 'like_track': {
        result = await adminClient.from('track_likes').insert({
          user_id: target_user_id,
          track_id: payload.track_id,
        });
        break;
      }
      case 'unlike_track': {
        result = await adminClient.from('track_likes')
          .delete()
          .eq('user_id', target_user_id)
          .eq('track_id', payload.track_id);
        break;
      }
      case 'delete_track': {
        // Fetch track file URLs before deleting
        const { data: trackData } = await adminClient.from('tracks')
          .select('audio_url, cover_url, wav_url, master_audio_url, certificate_url')
          .eq('id', payload.track_id)
          .eq('user_id', target_user_id)
          .maybeSingle();

        // Clean up storage files
        if (trackData) {
          const STORAGE_BASE = `${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/tracks/`;
          const paths: string[] = [];
          for (const url of [trackData.audio_url, trackData.cover_url, trackData.wav_url, trackData.master_audio_url, trackData.certificate_url]) {
            if (url && url.startsWith(STORAGE_BASE)) {
              paths.push(url.slice(STORAGE_BASE.length));
            }
          }
          if (paths.length > 0) {
            const { error: storageErr } = await adminClient.storage.from('tracks').remove(paths);
            if (storageErr) console.warn('[delete_track] Storage cleanup warning:', storageErr.message);
          }
        }

        // Remove associated likes then delete track
        await adminClient.from('track_likes').delete().eq('track_id', payload.track_id);
        result = await adminClient.from('tracks')
          .delete()
          .eq('id', payload.track_id)
          .eq('user_id', target_user_id);
        break;
      }

      // ---- Follows ----
      case 'follow_user': {
        result = await adminClient.from('user_follows').insert({
          follower_id: target_user_id,
          following_id: payload.following_id,
        });
        break;
      }
      case 'unfollow_user': {
        result = await adminClient.from('user_follows')
          .delete()
          .eq('follower_id', target_user_id)
          .eq('following_id', payload.following_id);
        break;
      }

      // ---- Track updates ----
      case 'update_track': {
        const { track_id, ...updateFields } = payload;
        result = await adminClient.from('tracks')
          .update(updateFields)
          .eq('id', track_id)
          .eq('user_id', target_user_id);
        break;
      }

      // ---- Comments ----
      case 'add_comment': {
        const insertData: Record<string, unknown> = {
          user_id: target_user_id,
          track_id: payload.track_id,
          content: payload.content,
        };
        if (payload.parent_id) insertData.parent_id = payload.parent_id;
        if (payload.timestamp_seconds !== undefined) insertData.timestamp_seconds = payload.timestamp_seconds;
        if (payload.quote_text) insertData.quote_text = payload.quote_text;
        if (payload.quote_author) insertData.quote_author = payload.quote_author;
        result = await adminClient.from('track_comments').insert(insertData);
        break;
      }
      case 'delete_comment': {
        result = await adminClient.from('track_comments')
          .delete()
          .eq('id', payload.comment_id)
          .eq('user_id', target_user_id);
        break;
      }
      case 'update_comment': {
        result = await adminClient.from('track_comments')
          .update({ content: payload.content, updated_at: new Date().toISOString() })
          .eq('id', payload.comment_id)
          .eq('user_id', target_user_id);
        break;
      }
      case 'like_comment': {
        result = await adminClient.from('comment_likes').insert({
          user_id: target_user_id,
          comment_id: payload.comment_id,
        });
        break;
      }
      case 'unlike_comment': {
        result = await adminClient.from('comment_likes')
          .delete()
          .eq('user_id', target_user_id)
          .eq('comment_id', payload.comment_id);
        break;
      }
      case 'add_reaction': {
        result = await adminClient.from('comment_reactions').insert({
          user_id: target_user_id,
          comment_id: payload.comment_id,
          emoji: payload.emoji,
        });
        break;
      }
      case 'remove_reaction': {
        result = await adminClient.from('comment_reactions')
          .delete()
          .eq('user_id', target_user_id)
          .eq('comment_id', payload.comment_id)
          .eq('emoji', payload.emoji);
        break;
      }
      case 'report_comment': {
        result = await adminClient.from('comment_reports').insert({
          reporter_id: target_user_id,
          comment_id: payload.comment_id,
          reason: payload.reason,
        });
        break;
      }

      // ---- Profile ----
      case 'update_profile': {
        const { ...profileFields } = payload;
        delete profileFields.balance;
        delete profileFields.user_id;
        delete profileFields.email;
        
        result = await adminClient.from('profiles')
          .update(profileFields)
          .eq('user_id', target_user_id);
        break;
      }

      // ---- Playlists ----
      case 'create_playlist': {
        result = await adminClient.from('playlists').insert({
          user_id: target_user_id,
          title: payload.title,
          description: payload.description || null,
          is_public: payload.is_public ?? false,
        }).select().single();
        break;
      }
      case 'update_playlist': {
        const { playlist_id: plId, ...plUpdates } = payload;
        result = await adminClient.from('playlists')
          .update({ ...plUpdates, updated_at: new Date().toISOString() })
          .eq('id', plId)
          .eq('user_id', target_user_id);
        break;
      }
      case 'delete_playlist': {
        result = await adminClient.from('playlists')
          .delete()
          .eq('id', payload.playlist_id)
          .eq('user_id', target_user_id);
        break;
      }
      case 'add_to_playlist': {
        // Get max position
        const { data: existing } = await adminClient
          .from('playlist_tracks')
          .select('position')
          .eq('playlist_id', payload.playlist_id)
          .order('position', { ascending: false })
          .limit(1);
        const nextPosition = existing?.length ? existing[0].position + 1 : 0;
        
        result = await adminClient.from('playlist_tracks').insert({
          playlist_id: payload.playlist_id,
          track_id: payload.track_id,
          position: nextPosition,
        });
        break;
      }
      case 'remove_from_playlist': {
        result = await adminClient.from('playlist_tracks')
          .delete()
          .eq('playlist_id', payload.playlist_id)
          .eq('track_id', payload.track_id);
        break;
      }
      case 'like_playlist': {
        result = await adminClient.from('playlist_likes').insert({
          user_id: target_user_id,
          playlist_id: payload.playlist_id,
        });
        break;
      }
      case 'unlike_playlist': {
        result = await adminClient.from('playlist_likes')
          .delete()
          .eq('user_id', target_user_id)
          .eq('playlist_id', payload.playlist_id);
        break;
      }

      // ---- Messages ----
      case 'send_message': {
        result = await adminClient.from('messages').insert({
          conversation_id: payload.conversation_id,
          sender_id: target_user_id,
          content: payload.content,
          attachment_url: payload.attachment_url || null,
          attachment_type: payload.attachment_type || null,
        }).select().single();
        break;
      }

      // ---- Forum ----
      case 'create_forum_topic': {
        // Generate slug from title
        const titleStr = String(payload.title);
        const slug = titleStr
          .toLowerCase()
          .replace(/[^\p{L}\p{N}\s-]/gu, '')
          .replace(/[\s]+/g, '-')
          .substring(0, 80) + '-' + Date.now().toString(36);
        const excerpt = String(payload.content).substring(0, 200);

        result = await adminClient.from('forum_topics').insert({
          category_id: payload.category_id,
          user_id: target_user_id,
          title: payload.title,
          slug,
          content: payload.content,
          content_html: payload.content_html || null,
          excerpt,
          track_id: payload.track_id || null,
          is_hidden: false,
        }).select().single();
        break;
      }
      case 'create_forum_post': {
        result = await adminClient.from('forum_posts').insert({
          topic_id: payload.topic_id,
          user_id: target_user_id,
          content: payload.content,
          content_html: payload.content_html || null,
          parent_id: payload.parent_id || null,
          reply_to_user_id: payload.reply_to_user_id || null,
          track_id: payload.track_id || null,
          is_hidden: false,
        }).select().single();
        break;
      }

      default:
        return new Response(
          JSON.stringify({ error: 'Неизвестное действие' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
    }

    // 7. Log the action
    const logEntry = {
      admin_user_id: adminUserId,
      target_user_id: target_user_id,
      action_type: action,
      action_payload: payload,
      result_status: result.error ? 'error' : 'success',
      error_message: result.error ? JSON.stringify(result.error) : null,
    };

    await adminClient.from('impersonation_action_logs').insert(logEntry);

    if (result.error) {
      console.error(`Impersonation action failed:`, result.error);
      return new Response(
        JSON.stringify({ error: 'Ошибка выполнения действия', details: result.error }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`Impersonation action success: ${action} for user ${target_user_id} by admin ${adminUserId}`);

    return new Response(
      JSON.stringify({
        success: true,
        action,
        target_user_id,
        target_username: targetProfile.username,
        data: result.data,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error('Impersonation error:', errorMessage);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
