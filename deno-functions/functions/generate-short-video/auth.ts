import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface AuthResult {
  userId: string | null;
  isInternalCall: boolean;
}

export async function validateAuth(
  req: Request,
  supabaseUrl: string,
  supabaseServiceKey: string,
  supabaseAnonKey: string,
): Promise<AuthResult> {
  const authHeader = req.headers.get("Authorization");
  let userId: string | null = null;
  let isInternalCall = false;

  if (authHeader === `Bearer ${supabaseServiceKey}`) {
    isInternalCall = true;
    console.log("Internal service call detected");
  } else if (authHeader?.startsWith("Bearer ")) {
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await userClient.auth.getClaims(token);

    if (claimsError || !claimsData?.claims) {
      throw new AuthError("Unauthorized");
    }

    userId = claimsData.claims.sub as string;
    console.log(`User call from: ${userId}`);
  } else {
    throw new AuthError("Unauthorized - missing auth");
  }

  return { userId, isInternalCall };
}

export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}
