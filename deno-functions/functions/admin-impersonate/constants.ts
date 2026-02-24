export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

export const ALLOWED_ACTIONS: Record<string, {
  table: string;
  operation: 'insert' | 'update' | 'delete' | 'upsert' | 'custom';
  requiredFields: string[];
  description: string;
}> = {
  like_track: { table: 'track_likes', operation: 'insert', requiredFields: ['track_id'], description: 'Like a track' },
  unlike_track: { table: 'track_likes', operation: 'delete', requiredFields: ['track_id'], description: 'Unlike a track' },
  delete_track: { table: 'tracks', operation: 'custom', requiredFields: ['track_id'], description: 'Delete a track' },
  follow_user: { table: 'user_follows', operation: 'insert', requiredFields: ['following_id'], description: 'Follow a user' },
  unfollow_user: { table: 'user_follows', operation: 'delete', requiredFields: ['following_id'], description: 'Unfollow a user' },
  update_track: { table: 'tracks', operation: 'update', requiredFields: ['track_id'], description: 'Update track metadata' },
  add_comment: { table: 'track_comments', operation: 'insert', requiredFields: ['track_id', 'content'], description: 'Add a comment to a track' },
  delete_comment: { table: 'track_comments', operation: 'delete', requiredFields: ['comment_id'], description: 'Delete a comment' },
  update_comment: { table: 'track_comments', operation: 'update', requiredFields: ['comment_id', 'content'], description: 'Edit a comment' },
  like_comment: { table: 'comment_likes', operation: 'insert', requiredFields: ['comment_id'], description: 'Like a comment' },
  unlike_comment: { table: 'comment_likes', operation: 'delete', requiredFields: ['comment_id'], description: 'Unlike a comment' },
  add_reaction: { table: 'comment_reactions', operation: 'insert', requiredFields: ['comment_id', 'emoji'], description: 'Add reaction to a comment' },
  remove_reaction: { table: 'comment_reactions', operation: 'delete', requiredFields: ['comment_id', 'emoji'], description: 'Remove reaction from a comment' },
  report_comment: { table: 'comment_reports', operation: 'insert', requiredFields: ['comment_id', 'reason'], description: 'Report a comment' },
  update_profile: { table: 'profiles', operation: 'update', requiredFields: [], description: 'Update user profile' },
  create_playlist: { table: 'playlists', operation: 'insert', requiredFields: ['title'], description: 'Create a playlist' },
  update_playlist: { table: 'playlists', operation: 'update', requiredFields: ['playlist_id'], description: 'Update a playlist' },
  delete_playlist: { table: 'playlists', operation: 'delete', requiredFields: ['playlist_id'], description: 'Delete a playlist' },
  add_to_playlist: { table: 'playlist_tracks', operation: 'insert', requiredFields: ['playlist_id', 'track_id'], description: 'Add track to a playlist' },
  remove_from_playlist: { table: 'playlist_tracks', operation: 'delete', requiredFields: ['playlist_id', 'track_id'], description: 'Remove track from a playlist' },
  like_playlist: { table: 'playlist_likes', operation: 'insert', requiredFields: ['playlist_id'], description: 'Like a playlist' },
  unlike_playlist: { table: 'playlist_likes', operation: 'delete', requiredFields: ['playlist_id'], description: 'Unlike a playlist' },
  send_message: { table: 'messages', operation: 'insert', requiredFields: ['conversation_id', 'content'], description: 'Send a message' },
  create_forum_topic: { table: 'forum_topics', operation: 'custom', requiredFields: ['category_id', 'title', 'content'], description: 'Create a forum topic' },
  create_forum_post: { table: 'forum_posts', operation: 'custom', requiredFields: ['topic_id', 'content'], description: 'Create a forum post' },
};
