import { getGenerationVariantIndex } from './track-generation-metadata.ts';

// Persist the provider's per-song text before any audio download/status update.
// Never replace the exact text the author submitted in custom mode.
export async function saveMusicLyrics(client: any, taskId: string, records: any[]) {
  if (!Array.isArray(records) || !records.length) return;
  const escaped = taskId.replace(/[\\%_]/g, '\\$&');
  const { data: tracks, error } = await client.from('tracks').select('id,title,description,lyrics')
    .ilike('description', `%[task_id: ${escaped}]%`).order('created_at').limit(4);
  if (error) throw error;
  if (!tracks?.length) return;
  const { data: logs, error: logsError } = await client.from('generation_logs').select('track_id,generation_params').in('track_id', tracks.map((track: any) => track.id));
  if (logsError) throw logsError;
  const instrumental = new Set((logs || []).filter((log: any) => log.generation_params?.instrumental === true).map((log: any) => log.track_id));
  for (const track of tracks || []) {
    if (instrumental.has(track.id) || track.lyrics?.trim()) continue;
    const record = records[getGenerationVariantIndex(track.description, track.title)];
    const text = record?.lyrics ?? record?.text ?? record?.prompt;
    if (typeof text !== 'string' || !text.trim()) continue;
    const { error: saveError } = await client.from('tracks').update({ lyrics: text.trim() }).eq('id', track.id).is('lyrics', null);
    if (saveError) throw saveError;
  }
}
