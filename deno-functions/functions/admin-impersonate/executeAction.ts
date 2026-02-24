import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export async function executeAction(
  adminClient: SupabaseClient,
  target_user_id: string,
  action: string,
  payload: Record<string, unknown>
): Promise<{ data: unknown; error: unknown }> {
  let result: { data: unknown; error: unknown } = { data: null, error: null };

  switch (action) {
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
      const { data: trackData } = await adminClient.from('tracks')
        .select('audio_url, cover_url, wav_url, master_audio_url, certificate_url')
        .eq('id', payload.track_id)
        .eq('user_id', target_user_id)
        .maybeSingle();

      if (trackData) {
        const STORAGE_SUFFIX = '/storage/v1/object/public/tracks/';
        const paths: string[] = [];
        for (const url of [trackData.audio_url, trackData.cover_url, trackData.wav_url, trackData.master_audio_url, trackData.certificate_url]) {
          if (url) {
            const idx = url.indexOf(STORAGE_SUFFIX);
            if (idx !== -1) {
              paths.push(url.slice(idx + STORAGE_SUFFIX.length));
            }
          }
        }
        if (paths.length > 0) {
          const { error: storageErr } = await adminClient.storage.from('tracks').remove(paths);
          if (storageErr) console.warn('[delete_track] Storage cleanup warning:', storageErr.message);
        }
      }

      await adminClient.from('track_likes').delete().eq('track_id', payload.track_id);
      result = await adminClient.from('tracks')
        .delete()
        .eq('id', payload.track_id)
        .eq('user_id', target_user_id);
      break;
    }

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

    case 'update_track': {
      const { track_id, ...updateFields } = payload;
      result = await adminClient.from('tracks')
        .update(updateFields)
        .eq('id', track_id)
        .eq('user_id', target_user_id);
      break;
    }

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

    case 'create_forum_topic': {
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
      return { data: null, error: { message: 'Неизвестное действие' } };
  }

  return result;
}
