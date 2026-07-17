import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, ALLOWED_ACTIONS } from "./constants.ts";
import { sha256 } from "./utils.ts";
import { executeAction } from "./executeAction.ts";

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });

    const { data: claims, error: claimsError } = await userClient.auth.getClaims(token);
    if (claimsError || !claims?.claims) {
      console.error('Claims error:', claimsError);
      return new Response(
        JSON.stringify({ error: 'Invalid token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const adminUserId = claims.claims.sub as string;

    const adminClient = createClient(supabaseUrl, supabaseServiceKey);

    const { data: userRole } = await adminClient
      .from('user_roles')
      .select('role')
      .eq('user_id', adminUserId)
      .single();

    if (!userRole || userRole.role !== 'super_admin') {
      console.warn(`Impersonation denied for user ${adminUserId}, role: ${userRole?.role}`);
      return new Response(
        JSON.stringify({ error: 'Доступ запрещён. Только для super_admin.' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const body = await req.json();
    const { pin, target_user_id, action, payload } = body;

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

    if (!target_user_id) {
      return new Response(
        JSON.stringify({ error: 'target_user_id обязателен' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data: targetProfile } = await adminClient
      .from('profiles')
      .select('user_id, username, balance')
      .eq('user_id', target_user_id)
      .single();

    if (!targetProfile) {
      return new Response(
        JSON.stringify({ error: 'Целевой пользователь не найден' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Full impersonation uses a real, short-lived Supabase session for the
    // target account. This makes auth.uid(), RLS, RPCs, realtime and every
    // existing/new frontend hook consistently operate as that user.
    if (action === 'start_session') {
      const { data: targetAuth, error: targetAuthError } = await adminClient.auth.admin.getUserById(target_user_id);
      const targetEmail = targetAuth.user?.email;

      if (targetAuthError || !targetEmail) {
        return new Response(
          JSON.stringify({ error: 'У целевого пользователя не найден auth-аккаунт или email' }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // AIMUZA uses its own auth server. Ask its service-role-only endpoint for
      // a normal target-user JWT after the admin and PIN checks above.
      const sessionResponse = await fetch(`${supabaseUrl}/auth/v1/admin/impersonation-session`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${supabaseServiceKey}`,
          apikey: supabaseServiceKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ user_id: target_user_id }),
      });
      const sessionPayload = await sessionResponse.json().catch(() => ({}));
      const targetSession = sessionResponse.ok
        && sessionPayload?.access_token
        && sessionPayload?.refresh_token
        ? {
            access_token: sessionPayload.access_token,
            refresh_token: sessionPayload.refresh_token,
          }
        : null;

      // Compatibility fallback for environments backed by standard GoTrue.
      let linkResponse: Response | null = null;
      let linkPayload: Record<string, any> = {};
      if (!targetSession) {
        linkResponse = await fetch(`${supabaseUrl}/auth/v1/admin/generate_link`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${supabaseServiceKey}`,
            apikey: supabaseServiceKey,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ type: 'magiclink', email: targetEmail }),
        });
        linkPayload = await linkResponse.json().catch(() => ({}));
      }
      const linkProperties = linkPayload?.properties || linkPayload?.data?.properties || {};
      const actionLink = typeof linkProperties.action_link === 'string'
        ? linkProperties.action_link
        : '';
      let actionLinkUrl: URL | null = null;
      try {
        if (actionLink) actionLinkUrl = new URL(actionLink);
      } catch {
        actionLinkUrl = null;
      }
      const hashedToken = linkProperties.hashed_token
        || actionLinkUrl?.searchParams.get('token_hash')
        || actionLinkUrl?.searchParams.get('token');
      const verificationType = linkProperties.verification_type
        || actionLinkUrl?.searchParams.get('type')
        || 'magiclink';

      if (!targetSession && (!linkResponse?.ok || !hashedToken)) {
        console.error('Failed to generate impersonation session:', {
          sessionStatus: sessionResponse.status,
          status: linkResponse?.status || null,
          hasActionLink: !!actionLink,
          responseError: linkPayload?.error || linkPayload?.message || null,
        });
        return new Response(
          JSON.stringify({
            error: linkPayload?.error_description
              || linkPayload?.message
              || 'Не удалось создать временную сессию пользователя',
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      await Promise.all([
        adminClient.from('impersonation_action_logs').insert({
          admin_user_id: adminUserId,
          target_user_id,
          action_type: 'start_session',
          action_payload: {},
          result_status: 'success',
          error_message: null,
        }),
        adminClient.from('role_change_logs').insert({
          user_id: target_user_id,
          changed_by: adminUserId,
          action: 'impersonation_started',
          metadata: { username: targetProfile.username, session_mode: true },
        }),
      ]);

      return new Response(
        JSON.stringify({
          success: true,
          target_session: targetSession,
          hashed_token: targetSession ? null : hashedToken,
          verification_type: targetSession ? null : verificationType,
          target_user: {
            id: targetProfile.user_id,
            username: targetProfile.username,
            balance: targetProfile.balance || 0,
          },
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!action || !ALLOWED_ACTIONS[action]) {
      return new Response(
        JSON.stringify({ error: `Действие '${action}' не разрешено`, allowed: Object.keys(ALLOWED_ACTIONS) }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const actionConfig = ALLOWED_ACTIONS[action];

    for (const field of actionConfig.requiredFields) {
      if (!payload || payload[field] === undefined) {
        return new Response(
          JSON.stringify({ error: `Поле '${field}' обязательно для действия '${action}'` }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    if (action === 'create_forum_topic' || action === 'create_forum_post') {
      const rateLimitType = action === 'create_forum_topic' ? 'topic' : 'post';
      const configField = action === 'create_forum_topic' ? 'max_topics_per_day' : 'max_posts_per_day';

      const { data: userStats } = await adminClient
        .from('forum_user_stats')
        .select('trust_level')
        .eq('user_id', target_user_id)
        .maybeSingle();

      const trustLevel = Math.min(userStats?.trust_level ?? 0, 4);

      const { data: configRow } = await adminClient
        .from('forum_reputation_config')
        .select(configField)
        .eq('trust_level', trustLevel)
        .maybeSingle();

      const maxPerDay = configRow ? (configRow as Record<string, number | null>)[configField] : null;

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

    console.log(`Impersonation action: ${action} by admin ${adminUserId} as user ${target_user_id}`);

    const result = await executeAction(adminClient, target_user_id, action, payload || {});

    if (result.error && (result.error as { message?: string }).message === 'Неизвестное действие') {
      return new Response(
        JSON.stringify({ error: 'Неизвестное действие' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

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
