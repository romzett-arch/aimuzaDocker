export async function generateACRCloudSignature(
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
