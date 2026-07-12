import { createClient, SupabaseClient, User } from "npm:@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function optionsResponse(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response("ok", { headers: corsHeaders }) : null;
}

export function requirePost(req: Request): void {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");
}

export async function parseObject(req: Request): Promise<Record<string, unknown>> {
  let value: unknown;
  try {
    value = await req.json();
  } catch {
    throw new HttpError(400, "Invalid JSON");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "JSON body must be an object");
  }
  return value as Record<string, unknown>;
}

export function requireName(value: unknown, field: string): string {
  if (typeof value !== "string" || value !== value.trim() || value.length < 1 || value.length > 40) {
    throw new HttpError(400, `${field} must be 1-40 trimmed characters`);
  }
  if (/[\u0000-\u001f\u007f]/u.test(value)) {
    throw new HttpError(400, `${field} contains invalid characters`);
  }
  return value;
}

export function requireUuid(value: unknown, field: string): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value)
  ) {
    throw new HttpError(400, `${field} must be a UUID`);
  }
  return value.toLowerCase();
}

export function requireInviteToken(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new HttpError(400, "token is invalid");
  }
  return value;
}

export function optionalMaxMembers(value: unknown): number {
  if (value === undefined) return 20;
  if (!Number.isInteger(value) || (value as number) < 2 || (value as number) > 50) {
    throw new HttpError(400, "maxMembers must be an integer from 2 to 50");
  }
  return value as number;
}

export async function requireUser(req: Request): Promise<User> {
  const authorization = req.headers.get("Authorization");
  const match = authorization?.match(/^Bearer (.+)$/);
  if (!match) throw new HttpError(401, "Authentication required");

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) throw new Error("Supabase Auth environment is not configured");

  const client = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(match[1]);
  if (error || !data.user) throw new HttpError(401, "Invalid authentication");
  return data.user;
}

export function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) throw new Error("Service role environment is not configured");
  return createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function generateInviteToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export async function hashInviteToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `\\x${hex}`;
}

export function inviteExpiry(): string {
  return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
}

export function handleError(error: unknown): Response {
  if (error instanceof HttpError) return jsonResponse({ error: error.message }, error.status);
  console.error(error instanceof Error ? error.message : "Unknown error");
  return jsonResponse({ error: "Request failed" }, 500);
}
