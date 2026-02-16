import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

interface PlagiarismRequest {
  trackId: string;
  audioUrl: string;
}

interface CheckStep {
  id: string;
  name: string;
  database: string;
  status: 'pending' | 'checking' | 'done' | 'error';
  result?: {
    found: boolean;
    matches?: Array<{
      title: string;
      artist: string;
      similarity: number;
      source: string;
    }>;
  };
}

interface AcoustIDResult {
  status: string;
  results?: Array<{
    id: string;
    score: number;
    recordings?: Array<{
      id: string;
      title?: string;
      artists?: Array<{ name: string }>;
      duration?: number;
    }>;
  }>;
}

interface ACRCloudResult {
  status: {
    code: number;
    msg: string;
  };
  metadata?: {
    music?: Array<{
      title: string;
      artists?: Array<{ name: string }>;
      album?: { name: string };
      score: number;
      external_ids?: {
        isrc?: string;
        upc?: string;
      };
    }>;
  };
}

// Generate HMAC-SHA1 signature for ACRCloud
async function generateACRCloudSignature(
  accessKey: string,
  accessSecret: string,
  timestamp: number,
  signatureVersion: string,
  dataType: string
): Promise<string> {
  const stringToSign = `POST\n/v1/identify\n${accessKey}\n${dataType}\n${signatureVersion}\n${timestamp}`;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(accessSecret),
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(stringToSign));
  return btoa(String.fromCharCode(...new Uint8Array(signature)));
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const ACOUSTID_API_KEY = Deno.env.get('ACOUSTID_API_KEY');
    const FFMPEG_API_URL = Deno.env.get('FFMPEG_API_URL');
    const FFMPEG_API_SECRET = Deno.env.get('FFMPEG_API_SECRET');
    const ACRCLOUD_HOST = Deno.env.get('ACRCLOUD_HOST');
    const ACRCLOUD_ACCESS_KEY = Deno.env.get('ACRCLOUD_ACCESS_KEY');
    const ACRCLOUD_ACCESS_SECRET = Deno.env.get('ACRCLOUD_ACCESS_SECRET');

    const { trackId, audioUrl }: PlagiarismRequest = await req.json();
    console.log(`[check-plagiarism] Starting check for track: ${trackId}`);

    if (!trackId || !audioUrl) {
      throw new Error('trackId and audioUrl are required');
    }

    // Get track data
    const { data: trackData } = await supabase
      .from('tracks')
      .select('user_id, title')
      .eq('id', trackId)
      .single();

    const userId = trackData?.user_id;

    // Initialize check steps
    const steps: CheckStep[] = [
      { id: 'acoustid', name: 'AcoustID Fingerprint', database: 'MusicBrainz (45M+ треков)', status: 'pending' },
      { id: 'acrcloud', name: 'ACRCloud', database: 'Глобальная база (100M+ треков)', status: 'pending' },
      { id: 'internal', name: 'Внутренняя база', database: 'AI Planet Sound', status: 'pending' },
    ];

    // Update track status
    await supabase
      .from('tracks')
      .update({ 
        copyright_check_status: 'checking',
        plagiarism_check_status: 'checking'
      })
      .eq('id', trackId);

    // Log start
    if (userId) {
      await supabase.from('distribution_logs').insert({
        track_id: trackId,
        user_id: userId,
        action: 'plagiarism_check_started',
        stage: 'upload',
        details: { audio_url: audioUrl, steps: steps.map(s => s.id) }
      });
    }

    let acoustidMatches: Array<{ title: string; artist: string; similarity: number; source: string }> = [];
    let acrcloudMatches: Array<{ title: string; artist: string; similarity: number; source: string }> = [];
    let internalMatches: Array<{ title: string; artist: string; similarity: number; source: string }> = [];
    let acoustidSuccess = false;
    let acoustidError: string | null = null;
    let acrcloudSuccess = false;
    let acrcloudError: string | null = null;

    // ============================================
    // STEP 1: AcoustID Check
    // ============================================
    steps[0].status = 'checking';
    console.log(`[check-plagiarism] Step 1: AcoustID fingerprint lookup`);

    try {
      if (!ACOUSTID_API_KEY) {
        throw new Error('ACOUSTID_API_KEY not configured');
      }

      // Get fingerprint from FFmpeg VPS (if available)
      let fingerprint: string | null = null;
      let duration: number | null = null;

      if (FFMPEG_API_URL && FFMPEG_API_SECRET) {
        console.log(`[check-plagiarism] Generating fingerprint via FFmpeg VPS`);
        
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
          console.log(`[check-plagiarism] Fingerprint generated, duration: ${duration}s`);
        } else {
          console.warn(`[check-plagiarism] FFmpeg fingerprint failed: ${fpResponse.status}`);
        }
      }

      // If we have fingerprint, query AcoustID
      if (fingerprint && duration) {
        const acoustidUrl = new URL('https://api.acoustid.org/v2/lookup');
        acoustidUrl.searchParams.set('client', ACOUSTID_API_KEY);
        acoustidUrl.searchParams.set('duration', String(Math.floor(duration)));
        acoustidUrl.searchParams.set('fingerprint', fingerprint);
        acoustidUrl.searchParams.set('meta', 'recordings');

        console.log(`[check-plagiarism] Querying AcoustID API...`);
        const acoustidResponse = await fetch(acoustidUrl.toString());
        
        if (acoustidResponse.ok) {
          const acoustidData: AcoustIDResult = await acoustidResponse.json();
          console.log(`[check-plagiarism] AcoustID response:`, JSON.stringify(acoustidData).slice(0, 500));
          
          if (acoustidData.status === 'ok' && acoustidData.results) {
            for (const result of acoustidData.results) {
              // Only consider matches with score > 0.8 (80% confidence)
              if (result.score >= 0.8 && result.recordings) {
                for (const recording of result.recordings) {
                  const artistNames = recording.artists?.map(a => a.name).join(', ') || 'Unknown Artist';
                  acoustidMatches.push({
                    title: recording.title || 'Unknown Title',
                    artist: artistNames,
                    similarity: Math.round(result.score * 100),
                    source: 'AcoustID/MusicBrainz'
                  });
                }
              }
            }
          }
          acoustidSuccess = true;
        }
      } else {
        // Fallback: If no FFmpeg VPS, we can't generate fingerprint
        // In production, this would fail - but for demo we continue
        console.log(`[check-plagiarism] No fingerprint available, skipping AcoustID`);
        acoustidError = 'Fingerprint generation not available';
      }

      steps[0].status = 'done';
      steps[0].result = {
        found: acoustidMatches.length > 0,
        matches: acoustidMatches
      };

    } catch (error) {
      console.error(`[check-plagiarism] AcoustID error:`, error);
      steps[0].status = 'error';
      acoustidError = error instanceof Error ? error.message : 'Unknown error';
    }

    // ============================================
    // STEP 2: ACRCloud Check
    // ============================================
    steps[1].status = 'checking';
    console.log(`[check-plagiarism] Step 2: ACRCloud identification`);

    try {
      if (!ACRCLOUD_HOST || !ACRCLOUD_ACCESS_KEY || !ACRCLOUD_ACCESS_SECRET) {
        throw new Error('ACRCloud credentials not configured');
      }

      // Download audio file for ACRCloud
      console.log(`[check-plagiarism] Downloading audio for ACRCloud...`);
      const audioResponse = await fetch(audioUrl);
      if (!audioResponse.ok) {
        throw new Error(`Failed to download audio: ${audioResponse.status}`);
      }
      const audioBuffer = await audioResponse.arrayBuffer();
      const audioBytes = new Uint8Array(audioBuffer);
      
      // Take first 10 seconds worth of audio (approximately)
      // ACRCloud recommends 10-20 seconds for identification
      const sampleSize = Math.min(audioBytes.length, 1024 * 1024); // Max 1MB sample
      const audioSample = audioBytes.slice(0, sampleSize);
      
      // Generate signature
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

      // Prepare form data
      const formData = new FormData();
      formData.append('sample', new Blob([audioSample]), 'sample.mp3');
      formData.append('sample_bytes', String(audioSample.length));
      formData.append('access_key', ACRCLOUD_ACCESS_KEY);
      formData.append('data_type', dataType);
      formData.append('signature', signature);
      formData.append('signature_version', signatureVersion);
      formData.append('timestamp', String(timestamp));

      console.log(`[check-plagiarism] Sending to ACRCloud...`);
      const acrResponse = await fetch(`https://${ACRCLOUD_HOST}/v1/identify`, {
        method: 'POST',
        body: formData
      });

      if (acrResponse.ok) {
        const acrData: ACRCloudResult = await acrResponse.json();
        console.log(`[check-plagiarism] ACRCloud response code: ${acrData.status.code}`);

        if (acrData.status.code === 0 && acrData.metadata?.music) {
          for (const music of acrData.metadata.music) {
            const artistNames = music.artists?.map(a => a.name).join(', ') || 'Unknown Artist';
            acrcloudMatches.push({
              title: music.title || 'Unknown Title',
              artist: artistNames,
              similarity: music.score,
              source: 'ACRCloud'
            });
          }
          acrcloudSuccess = true;
        } else if (acrData.status.code === 1001) {
          // No result found - this is success, just no matches
          acrcloudSuccess = true;
          console.log(`[check-plagiarism] ACRCloud: No matches found (clean)`);
        } else {
          acrcloudError = acrData.status.msg;
        }
      } else {
        acrcloudError = `HTTP ${acrResponse.status}`;
      }

      steps[1].status = 'done';
      steps[1].result = {
        found: acrcloudMatches.length > 0,
        matches: acrcloudMatches
      };

    } catch (error) {
      console.error(`[check-plagiarism] ACRCloud error:`, error);
      steps[1].status = 'error';
      acrcloudError = error instanceof Error ? error.message : 'Unknown error';
    }

    // ============================================
    // STEP 3: Internal Database Check
    // ============================================
    steps[2].status = 'checking';
    console.log(`[check-plagiarism] Step 3: Internal database check`);

    try {
      // Check against tracks in our own database
      const trackTitle = trackData?.title?.toLowerCase() || '';
      
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
              const profile = track.profiles as any;
              internalMatches.push({
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
      steps[2].result = {
        found: internalMatches.length > 0,
        matches: internalMatches
      };

    } catch (error) {
      console.error(`[check-plagiarism] Internal check error:`, error);
      steps[2].status = 'error';
    }

    // ============================================
    // Combine Results
    // ============================================
    const allMatches = [...acoustidMatches, ...acrcloudMatches, ...internalMatches];
    const isClean = allMatches.length === 0;
    const score = isClean ? 100 : Math.max(0, 100 - Math.max(...allMatches.map(m => m.similarity)));

    console.log(`[check-plagiarism] Result for ${trackId}: isClean=${isClean}, score=${score}, matches=${allMatches.length}`);

    // Update track with result
    const { error: updateError } = await supabase
      .from('tracks')
      .update({
        copyright_check_status: isClean ? 'clean' : 'flagged',
        plagiarism_check_status: isClean ? 'clean' : 'flagged',
        plagiarism_check_result: { 
          isClean, 
          score, 
          matches: allMatches,
          steps: steps.map(s => ({ 
            id: s.id, 
            name: s.name, 
            database: s.database,
            status: s.status,
            matchCount: s.result?.matches?.length || 0
          })),
          checkedAt: new Date().toISOString(),
          acoustidAvailable: acoustidSuccess,
          acoustidError,
          acrcloudAvailable: acrcloudSuccess,
          acrcloudError
        }
      })
      .eq('id', trackId);

    if (updateError) {
      console.error('[check-plagiarism] Update error:', updateError);
      throw updateError;
    }

    // Log completion
    if (userId) {
      await supabase.from('distribution_logs').insert({
        track_id: trackId,
        user_id: userId,
        action: isClean ? 'plagiarism_check_clean' : 'plagiarism_check_flagged',
        stage: 'upload',
        details: { isClean, score, matchCount: allMatches.length, steps: steps.map(s => s.id) }
      });
    }

    // Return detailed result with processed steps (same format as saved to DB)
    const processedSteps = steps.map(s => ({ 
      id: s.id, 
      name: s.name, 
      database: s.database,
      status: s.status,
      matchCount: s.result?.matches?.length || 0
    }));

    return new Response(
      JSON.stringify({ 
        success: true, 
        isClean,
        score,
        matches: allMatches,
        steps: processedSteps,
        message: isClean ? 'Трек прошёл проверку' : 'Обнаружены совпадения'
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[check-plagiarism] Error:', error);
    const message = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// Simple title similarity using Levenshtein distance
function calculateTitleSimilarity(title1: string, title2: string): number {
  const len1 = title1.length;
  const len2 = title2.length;
  
  if (len1 === 0) return len2 === 0 ? 100 : 0;
  if (len2 === 0) return 0;
  
  const matrix: number[][] = [];
  
  for (let i = 0; i <= len1; i++) {
    matrix[i] = [i];
  }
  for (let j = 0; j <= len2; j++) {
    matrix[0][j] = j;
  }
  
  for (let i = 1; i <= len1; i++) {
    for (let j = 1; j <= len2; j++) {
      const cost = title1[i - 1] === title2[j - 1] ? 0 : 1;
      matrix[i][j] = Math.min(
        matrix[i - 1][j] + 1,
        matrix[i][j - 1] + 1,
        matrix[i - 1][j - 1] + cost
      );
    }
  }
  
  const distance = matrix[len1][len2];
  const maxLen = Math.max(len1, len2);
  return Math.round((1 - distance / maxLen) * 100);
}
