export interface Env {
  PATREON_CLIENT_ID: string;
  PATREON_CLIENT_SECRET: string;
  PATREON_CAMPAIGN_ID: string;
  PATREON_OWNER_USER_ID: string;
  PASS_SIGNING_KEY: string;
  SENTRY_DSN?: string;
  SESSIONS: Namespace;
  MEMBERS: Namespace;
}

export interface Namespace {
  idFromName(name: string): unknown;
  get(id: unknown): { fetch(request: Request): Promise<Response> };
}

export const patreon = "https://www.patreon.com";
// Patreon drops calls without a User-Agent with a 403.
export const userAgent = "Empo API (+https://github.com/mateo-m/empo-app)";

export class SignedOut extends Error {}

export interface Tokens {
  access_token: string;
  refresh_token: string;
}

export async function token(env: Env, grant: Record<string, string>): Promise<Tokens> {
  const response = await fetch(`${patreon}/api/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "user-agent": userAgent },
    body: new URLSearchParams({
      ...grant,
      client_id: env.PATREON_CLIENT_ID,
      client_secret: env.PATREON_CLIENT_SECRET,
    }),
  });
  if (!response.ok) {
    const body = await response.text();
    const error = (JSON.parse(body || "{}") as { error?: string }).error;
    // Only `invalid_grant` is about the user. The other errors, such
    // as `invalid_client`, are a fault in this server.
    throw new (error === "invalid_grant" ? SignedOut : Error)(`Patreon token call failed: ${response.status} ${body}`);
  }
  return (await response.json()) as Tokens;
}
