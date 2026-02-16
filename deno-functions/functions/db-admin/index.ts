import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// SHA-256 hash function
async function sha256(message: string): Promise<string> {
  const msgBuffer = new TextEncoder().encode(message);
  const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

// Verify super_admin and PIN
async function verifySuperAdminAndPin(
  authHeader: string,
  pin: string,
  supabaseUrl: string,
  supabaseServiceKey: string,
  supabaseAnonKey: string
): Promise<{ success: boolean; error?: string; userId?: string }> {
  if (!authHeader?.startsWith('Bearer ')) {
    return { success: false, error: 'Unauthorized' };
  }

  if (!pin || typeof pin !== 'string' || pin.length !== 6) {
    return { success: false, error: 'Требуется 6-значный PIN-код' };
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } }
  });

  const token = authHeader.replace('Bearer ', '');
  const { data: claims, error: claimsError } = await userClient.auth.getClaims(token);
  
  if (claimsError || !claims?.claims) {
    return { success: false, error: 'Invalid token' };
  }

  const userId = claims.claims.sub as string;
  const adminClient = createClient(supabaseUrl, supabaseServiceKey);

  // Check super_admin role
  const { data: userRole } = await adminClient
    .from('user_roles')
    .select('role')
    .eq('user_id', userId)
    .single();

  if (!userRole || userRole.role !== 'super_admin') {
    return { success: false, error: 'Доступ запрещён. Только для super_admin.' };
  }

  // Verify PIN
  const { data: pinSetting } = await adminClient
    .from('settings')
    .select('value')
    .eq('key', 'backup_pin_hash')
    .single();

  if (!pinSetting?.value) {
    return { success: false, error: 'PIN-код не настроен' };
  }

  const pinHash = await sha256(pin);
  if (pinHash !== pinSetting.value) {
    return { success: false, error: 'Неверный PIN-код' };
  }

  return { success: true, userId };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    const body = await req.json().catch(() => ({}));
    const { pin, action, table, data, id, query, limit = 100, offset = 0 } = body;

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

    // Verify access
    const verification = await verifySuperAdminAndPin(
      authHeader || '',
      pin,
      supabaseUrl,
      supabaseServiceKey,
      supabaseAnonKey
    );

    if (!verification.success) {
      return new Response(
        JSON.stringify({ error: verification.error }),
        { status: verification.error === 'Unauthorized' ? 401 : 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const adminClient = createClient(supabaseUrl, supabaseServiceKey);
    console.log(`DB Admin action: ${action} by super_admin: ${verification.userId}`);

    switch (action) {
      case 'list_tables': {
        // Get list of public tables
        const { data: tables, error } = await adminClient
          .from('information_schema.tables' as any)
          .select('table_name')
          .eq('table_schema', 'public')
          .eq('table_type', 'BASE TABLE');

        if (error) {
          // Fallback: return predefined list
          const knownTables = [
            'profiles', 'tracks', 'genres', 'genre_categories', 'ai_models',
            'vocal_types', 'templates', 'artist_styles', 'addon_services',
            'user_prompts', 'generated_lyrics', 'lyrics_items', 'playlists',
            'playlist_tracks', 'track_likes', 'track_comments', 'user_follows',
            'payments', 'subscriptions', 'subscription_plans', 'user_roles',
            'settings', 'notifications', 'contests', 'contest_entries',
            'achievements', 'user_achievements', 'referral_codes', 'referrals',
            'store_items', 'item_purchases', 'support_tickets', 'ticket_messages',
            'conversations', 'messages', 'user_blocks', 'error_logs',
            'performance_alerts', 'role_change_logs', 'security_audit_log'
          ];
          return new Response(
            JSON.stringify({ tables: knownTables }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({ tables: tables?.map((t: any) => t.table_name) || [] }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'get_table_data': {
        if (!table) {
          return new Response(
            JSON.stringify({ error: 'Table name required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Get count
        const { count } = await adminClient
          .from(table)
          .select('*', { count: 'exact', head: true });

        // Get data with pagination
        const { data: rows, error } = await adminClient
          .from(table)
          .select('*')
          .range(offset, offset + limit - 1)
          .order('created_at', { ascending: false, nullsFirst: false });

        if (error) {
          return new Response(
            JSON.stringify({ error: error.message }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({ data: rows || [], count: count || 0, limit, offset }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'update_row': {
        if (!table || !id || !data) {
          return new Response(
            JSON.stringify({ error: 'Table, id, and data required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { error } = await adminClient
          .from(table)
          .update(data)
          .eq('id', id);

        if (error) {
          return new Response(
            JSON.stringify({ error: error.message }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log(`Updated row ${id} in ${table}`);
        return new Response(
          JSON.stringify({ success: true }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'delete_row': {
        if (!table || !id) {
          return new Response(
            JSON.stringify({ error: 'Table and id required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { error } = await adminClient
          .from(table)
          .delete()
          .eq('id', id);

        if (error) {
          return new Response(
            JSON.stringify({ error: error.message }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log(`Deleted row ${id} from ${table}`);
        return new Response(
          JSON.stringify({ success: true }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'insert_row': {
        if (!table || !data) {
          return new Response(
            JSON.stringify({ error: 'Table and data required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { data: inserted, error } = await adminClient
          .from(table)
          .insert(data)
          .select()
          .single();

        if (error) {
          return new Response(
            JSON.stringify({ error: error.message }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log(`Inserted row in ${table}`);
        return new Response(
          JSON.stringify({ success: true, data: inserted }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'export_table': {
        if (!table) {
          return new Response(
            JSON.stringify({ error: 'Table name required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { data: rows, error } = await adminClient
          .from(table)
          .select('*')
          .limit(50000);

        if (error) {
          return new Response(
            JSON.stringify({ error: error.message }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({ table, count: rows?.length || 0, data: rows || [] }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'export_all': {
        const knownTables = [
          'profiles', 'tracks', 'genres', 'genre_categories', 'ai_models',
          'vocal_types', 'templates', 'artist_styles', 'addon_services',
          'user_prompts', 'generated_lyrics', 'lyrics_items', 'playlists',
          'playlist_tracks', 'track_likes', 'track_comments', 'user_follows',
          'payments', 'subscriptions', 'subscription_plans', 'user_roles',
          'settings', 'notifications', 'contests', 'contest_entries',
          'achievements', 'user_achievements', 'referral_codes', 'referrals',
          'store_items', 'item_purchases'
        ];

        const exportData: Record<string, unknown> = {
          exported_at: new Date().toISOString(),
          exported_by: verification.userId,
          tables: {}
        };

        for (const tableName of knownTables) {
          try {
            const { data: rows } = await adminClient
              .from(tableName)
              .select('*')
              .limit(10000);
            
            (exportData.tables as Record<string, unknown>)[tableName] = {
              count: rows?.length || 0,
              data: rows || []
            };
          } catch {
            (exportData.tables as Record<string, unknown>)[tableName] = { error: 'Failed to export', count: 0 };
          }
        }

        return new Response(
          JSON.stringify(exportData, null, 2),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      default:
        return new Response(
          JSON.stringify({ error: 'Unknown action' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
    }

  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error('DB Admin error:', errorMessage);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
