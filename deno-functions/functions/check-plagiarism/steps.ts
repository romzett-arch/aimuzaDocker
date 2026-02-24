import type { CheckStep, AcoustIDResult, ACRCloudResult, PlagiarismMatch } from "./types.ts";
import { generateACRCloudSignature } from "./acrcloud.ts";
import { calculateTitleSimilarity } from "./similarity.ts";

export async function runAcoustidStep(
  steps: CheckStep[],
  audioUrl: string,
  ACOUSTID_API_KEY: string | undefined,
  FFMPEG_API_URL: string | undefined,
  FFMPEG_API_SECRET: string | undefined
): Promise<{ matches: PlagiarismMatch[]; success: boolean; error: string | null }> {
  const matches: PlagiarismMatch[] = [];
  steps[0].status = 'checking';

  try {
    if (!ACOUSTID_API_KEY) {
      throw new Error('ACOUSTID_API_KEY not configured');
    }

    let fingerprint: string | null = null;
    let duration: number | null = null;

    if (FFMPEG_API_URL && FFMPEG_API_SECRET) {
      const fpResponse = await fetch(`${FFMPEG_API_URL}/fingerprint`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${FFMPEG_API_SECRET}`
        },
        body: JSON.stringify({ audioUrl })
      });

      if (fpResponse.ok) {
        const fpData = await fpResponse.json();
        fingerprint = fpData.fingerprint;
        duration = fpData.duration;
      }
    }

    if (fingerprint && duration) {
      const acoustidUrl = new URL('https://api.acoustid.org/v2/lookup');
      acoustidUrl.searchParams.set('client', ACOUSTID_API_KEY);
      acoustidUrl.searchParams.set('duration', String(Math.floor(duration)));
      acoustidUrl.searchParams.set('fingerprint', fingerprint);
      acoustidUrl.searchParams.set('meta', 'recordings');

      const acoustidResponse = await fetch(acoustidUrl.toString());

      if (acoustidResponse.ok) {
        const acoustidData: AcoustIDResult = await acoustidResponse.json();

        if (acoustidData.status === 'ok' && acoustidData.results) {
          for (const result of acoustidData.results) {
            if (result.score >= 0.8 && result.recordings) {
              for (const recording of result.recordings) {
                const artistNames = recording.artists?.map(a => a.name).join(', ') || 'Unknown Artist';
                matches.push({
                  title: recording.title || 'Unknown Title',
                  artist: artistNames,
                  similarity: Math.round(result.score * 100),
                  source: 'AcoustID/MusicBrainz'
                });
              }
            }
          }
        }
        steps[0].status = 'done';
        steps[0].result = { found: matches.length > 0, matches };
        return { matches, success: true, error: null };
      }
    }

    steps[0].status = 'done';
    steps[0].result = { found: false, matches };
    return { matches, success: false, error: 'Fingerprint generation not available' };
  } catch (error) {
    steps[0].status = 'error';
    steps[0].result = { found: false, matches };
    return {
      matches,
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    };
  }
}

export async function runAcrcloudStep(
  steps: CheckStep[],
  audioUrl: string,
  ACRCLOUD_HOST: string | undefined,
  ACRCLOUD_ACCESS_KEY: string | undefined,
  ACRCLOUD_ACCESS_SECRET: string | undefined
): Promise<{ matches: PlagiarismMatch[]; success: boolean; error: string | null }> {
  const matches: PlagiarismMatch[] = [];
  steps[1].status = 'checking';

  try {
    if (!ACRCLOUD_HOST || !ACRCLOUD_ACCESS_KEY || !ACRCLOUD_ACCESS_SECRET) {
      throw new Error('ACRCloud credentials not configured');
    }

    const audioResponse = await fetch(audioUrl);
    if (!audioResponse.ok) {
      throw new Error(`Failed to download audio: ${audioResponse.status}`);
    }
    const audioBuffer = await audioResponse.arrayBuffer();
    const audioBytes = new Uint8Array(audioBuffer);
    const sampleSize = Math.min(audioBytes.length, 1024 * 1024);
    const audioSample = audioBytes.slice(0, sampleSize);

    const timestamp = Math.floor(Date.now() / 1000);
    const dataType = 'audio';
    const signatureVersion = '1';
    const signature = await generateACRCloudSignature(
      ACRCLOUD_ACCESS_KEY,
      ACRCLOUD_ACCESS_SECRET,
      timestamp,
      signatureVersion,
      dataType
    );

    const formData = new FormData();
    formData.append('sample', new Blob([audioSample]), 'sample.mp3');
    formData.append('sample_bytes', String(audioSample.length));
    formData.append('access_key', ACRCLOUD_ACCESS_KEY);
    formData.append('data_type', dataType);
    formData.append('signature', signature);
    formData.append('signature_version', signatureVersion);
    formData.append('timestamp', String(timestamp));

    const acrResponse = await fetch(`https://${ACRCLOUD_HOST}/v1/identify`, {
      method: 'POST',
      body: formData
    });

    if (acrResponse.ok) {
      const acrData: ACRCloudResult = await acrResponse.json();

      if (acrData.status.code === 0 && acrData.metadata?.music) {
        for (const music of acrData.metadata.music) {
          const artistNames = music.artists?.map(a => a.name).join(', ') || 'Unknown Artist';
          matches.push({
            title: music.title || 'Unknown Title',
            artist: artistNames,
            similarity: music.score,
            source: 'ACRCloud'
          });
        }
        steps[1].status = 'done';
        steps[1].result = { found: matches.length > 0, matches };
        return { matches, success: true, error: null };
      } else if (acrData.status.code === 1001) {
        steps[1].status = 'done';
        steps[1].result = { found: false, matches };
        return { matches, success: true, error: null };
      } else {
        steps[1].status = 'done';
        steps[1].result = { found: false, matches };
        return { matches, success: false, error: acrData.status.msg };
      }
    }

    steps[1].status = 'done';
    steps[1].result = { found: false, matches };
    return { matches, success: false, error: `HTTP ${acrResponse.status}` };
  } catch (error) {
    steps[1].status = 'error';
    steps[1].result = { found: false, matches };
    return {
      matches,
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    };
  }
}

export async function runInternalStep(
  steps: CheckStep[],
  supabase: { from: (table: string) => { select: (cols: string) => { neq: (col: string, val: string) => { neq: (col: string, val: string | undefined) => { ilike: (col: string, pattern: string) => { limit: (n: number) => Promise<{ data: Array<{ title?: string; profiles?: { username?: string } }> | null }> } } } } } } },
  trackId: string,
  trackTitle: string,
  userId: string | undefined
): Promise<{ matches: PlagiarismMatch[] }> {
  const matches: PlagiarismMatch[] = [];
  steps[2].status = 'checking';

  try {
    if (trackTitle) {
      const { data: similarTracks } = await supabase
        .from('tracks')
        .select('id, title, user_id, profiles:user_id(username)')
        .neq('id', trackId)
        .neq('user_id', userId)
        .ilike('title', `%${trackTitle.slice(0, 20)}%`)
        .limit(5);

      if (similarTracks && similarTracks.length > 0) {
        for (const track of similarTracks) {
          const similarity = calculateTitleSimilarity(trackTitle, track.title?.toLowerCase() || '');
          if (similarity > 70) {
            const profile = track.profiles;
            matches.push({
              title: track.title || 'Untitled',
              artist: profile?.username || 'Unknown',
              similarity: similarity,
              source: 'AI Planet Sound'
            });
          }
        }
      }
    }

    steps[2].status = 'done';
    steps[2].result = { found: matches.length > 0, matches };
    return { matches };
  } catch (error) {
    console.error(`[check-plagiarism] Internal check error:`, error);
    steps[2].status = 'error';
    steps[2].result = { found: false, matches };
    return { matches };
  }
}
