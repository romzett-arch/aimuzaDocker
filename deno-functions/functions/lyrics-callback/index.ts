import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { extractLyricsResults, recoverLyricsJob } from "../_shared/lyrics-results.ts";

serve(async req => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  try {
    const url = new URL(req.url);
    const jobId = url.searchParams.get('job');
    const token = url.searchParams.get('token');
    if (!jobId || !token || !/^[\da-f-]{36}$/i.test(jobId)) return new Response('Unauthorized', { status: 401 });
    const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: job, error } = await client.from('lyrics_generation_jobs').select('*').eq('id', jobId).eq('callback_token', token).maybeSingle();
    if (error) throw error;
    if (!job) return new Response('Unauthorized', { status: 401 });
    const payload = await req.json();
    const taskId = payload?.data?.task_id ?? payload?.data?.taskId;
    if (taskId && job.provider_task_id && taskId !== job.provider_task_id) return new Response('Task mismatch', { status: 409 });
    // The per-job secret authenticates delivery. Persist directly: record-info
    // can lag behind callbacks. A failed write returns 500 so delivery is retried.
    const results = extractLyricsResults(payload);
    if (payload.code === 200 && results.length) {
      const { error: saveError } = await client.rpc('complete_lyrics_job', { p_job_id: job.id, p_results: JSON.stringify(results) });
      if (saveError) throw saveError;
    } else {
      if (!job.provider_task_id && taskId) {
        const { error: updateError } = await client.from('lyrics_generation_jobs').update({ provider_task_id: taskId }).eq('id', job.id);
        if (updateError) throw updateError;
        job.provider_task_id = taskId;
      }
      await recoverLyricsJob(client, job, Deno.env.get('SUNO_API_KEY')!);
    }
    return Response.json({ success: true });
  } catch (error) {
    console.error('Lyrics callback persistence failed', error);
    return Response.json({ error: 'Не удалось сохранить результат' }, { status: 500 });
  }
});
