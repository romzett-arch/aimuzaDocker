import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Основные таблицы для экспорта
const TABLES_TO_EXPORT = [
  'profiles',
  'tracks',
  'genres',
  'genre_categories',
  'ai_models',
  'vocal_types',
  'templates',
  'artist_styles',
  'addon_services',
  'user_prompts',
  'generated_lyrics',
  'lyrics_items',
  'playlists',
  'playlist_tracks',
  'track_likes',
  'track_comments',
  'user_follows',
  'payments',
  'subscriptions',
  'subscription_plans',
  'user_roles',
  'settings',
  'notifications',
  'contests',
  'contest_entries',
  'achievements',
  'user_achievements',
  'referral_codes',
  'referrals',
  'store_items',
  'item_purchases',
];

// SHA-256 hash function
async function sha256(message: string): Promise<string> {
  const msgBuffer = new TextEncoder().encode(message);
  const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  return hashHex;
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Get PIN from request body
    const body = await req.json().catch(() => ({}));
    const pin = body.pin;

    if (!pin || typeof pin !== 'string' || pin.length !== 6) {
      return new Response(
        JSON.stringify({ error: 'Требуется 6-значный PIN-код' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

    // Verify user is super_admin
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });

    const token = authHeader.replace('Bearer ', '');
    const { data: claims, error: claimsError } = await userClient.auth.getClaims(token);
    
    if (claimsError || !claims?.claims) {
      return new Response(
        JSON.stringify({ error: 'Invalid token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const userId = claims.claims.sub;

    // Use service role for checking role and PIN
    const adminClient = createClient(supabaseUrl, supabaseServiceKey);

    // Check if user is SUPER_ADMIN only
    const { data: userRole } = await adminClient
      .from('user_roles')
      .select('role')
      .eq('user_id', userId)
      .single();

    if (!userRole || userRole.role !== 'super_admin') {
      console.log('Access denied for user:', userId, 'Role:', userRole?.role);
      return new Response(
        JSON.stringify({ error: 'Доступ запрещён. Только для super_admin.' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify PIN
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
      console.log('Invalid PIN attempt by super_admin:', userId);
      return new Response(
        JSON.stringify({ error: 'Неверный PIN-код' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('Starting database export for super_admin:', userId);

    const exportData: Record<string, unknown> = {
      exported_at: new Date().toISOString(),
      exported_by: userId,
      tables: {}
    };

    const errors: string[] = [];

    // Export each table
    for (const tableName of TABLES_TO_EXPORT) {
      try {
        const { data, error } = await adminClient
          .from(tableName)
          .select('*')
          .limit(10000);

        if (error) {
          console.error(`Error exporting ${tableName}:`, error.message);
          errors.push(`${tableName}: ${error.message}`);
          (exportData.tables as Record<string, unknown>)[tableName] = { error: error.message, count: 0 };
        } else {
          (exportData.tables as Record<string, unknown>)[tableName] = {
            count: data?.length || 0,
            data: data || []
          };
          console.log(`Exported ${tableName}: ${data?.length || 0} rows`);
        }
      } catch (e: unknown) {
        const errorMessage = e instanceof Error ? e.message : String(e);
        console.error(`Exception exporting ${tableName}:`, errorMessage);
        errors.push(`${tableName}: ${errorMessage}`);
        (exportData.tables as Record<string, unknown>)[tableName] = { error: errorMessage, count: 0 };
      }
    }

    exportData.errors = errors;
    exportData.tables_count = Object.keys(exportData.tables as Record<string, unknown>).length;

    console.log('Export completed. Tables:', exportData.tables_count, 'Errors:', errors.length);

    return new Response(
      JSON.stringify(exportData, null, 2),
      { 
        headers: { 
          ...corsHeaders, 
          'Content-Type': 'application/json',
          'Content-Disposition': `attachment; filename="database-backup-${new Date().toISOString().split('T')[0]}.json"`
        } 
      }
    );

  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error('Export error:', errorMessage);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
