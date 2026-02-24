import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export async function copyFileToStorage(
  supabaseAdmin: SupabaseClient,
  externalUrl: string,
  bucket: string,
  filePath: string
): Promise<string | null> {
  try {
    console.log(`Downloading file from: ${externalUrl}`);

    const response = await fetch(externalUrl);
    if (!response.ok) {
      console.error(`Failed to download: ${response.status} ${response.statusText}`);
      return null;
    }

    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("text/html")) {
      console.error(`Downloaded HTML instead of audio (content-type: ${contentType}), URL may be invalid`);
      return null;
    }

    const blob = await response.blob();
    const arrayBuffer = await blob.arrayBuffer();
    const uint8Array = new Uint8Array(arrayBuffer);

    const isAudio = filePath.endsWith(".mp3");
    const minSize = isAudio ? 10000 : 1000;
    if (uint8Array.length < minSize) {
      console.error(`File too small (${uint8Array.length} bytes, min ${minSize}), likely not valid audio`);
      return null;
    }

    if (isAudio && uint8Array.length > 3) {
      const isId3 = uint8Array[0] === 0x49 && uint8Array[1] === 0x44 && uint8Array[2] === 0x33;
      const isMpeg = uint8Array[0] === 0xff && (uint8Array[1] & 0xe0) === 0xe0;
      if (!isId3 && !isMpeg) {
        console.error(`File does not start with ID3 or MPEG sync (first bytes: ${uint8Array[0].toString(16)} ${uint8Array[1].toString(16)} ${uint8Array[2].toString(16)})`);
        return null;
      }
    }

    console.log(`Downloaded ${uint8Array.length} bytes, uploading to ${bucket}/${filePath}`);

    const { error: uploadError } = await supabaseAdmin.storage
      .from(bucket)
      .upload(filePath, uint8Array, {
        contentType: blob.type || "application/octet-stream",
        upsert: true,
      });

    if (uploadError) {
      console.error(`Upload error:`, uploadError);
      return null;
    }

    const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    const publicUrl = `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`;

    console.log(`File uploaded successfully: ${publicUrl}`);
    return publicUrl;
  } catch (err) {
    console.error(`Error copying file to storage:`, err);
    return null;
  }
}
