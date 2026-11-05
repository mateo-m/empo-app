import { Elysia, ElysiaError, t } from "elysia";
import { WebStandardAdapter } from "elysia/adapter/web-standard";
import { parseMembership } from "./membership";
import { openRenewal, sealRenewal, signPass } from "./pass";

interface Env {
  PATREON_CLIENT_ID: string;
  PATREON_CLIENT_SECRET: string;
  PATREON_CAMPAIGN_ID: string;
  PATREON_OWNER_USER_ID: string;
  PASS_SIGNING_KEY: string;
  RENEWAL_KEY: string;
}

// Workers pass the same bindings to every request of an isolate.
let env: Env;
const patreon = "https://www.patreon.com";
const callbackPath = "/patreon/callback";
const appCallback = "empo://patreon";
// Patreon drops calls without a User-Agent with a 403.
const userAgent = "Empo API (+https://github.com/mateo-m/empo-app)";

class SignedOut extends Error {}

export const app = new Elysia({ adapter: WebStandardAdapter })
  .onError(({ error }) => {
    if (error instanceof ElysiaError) return;
    console.error(error);
    return Response.json({ error: "server" }, { status: 502 });
  })
  .get(
    "/patreon/start",
    { query: t.Object({ state: t.Optional(t.String()) }) },
    ({ request, query, redirect }) => {
      const authorize = new URL(`${patreon}/oauth2/authorize`);
      authorize.search = new URLSearchParams({
        response_type: "code",
        client_id: env.PATREON_CLIENT_ID,
        redirect_uri: callbackUrl(request),
        // Without `identity.memberships`, Patreon returns only the
        // membership to this client's own campaign.
        scope: "identity",
        state: query.state ?? "",
      }).toString();
      return redirect(authorize.toString(), 302);
    },
  )
  .get(
    callbackPath,
    {
      query: t.Object({
        state: t.Optional(t.String()),
        code: t.Optional(t.String()),
        error: t.Optional(t.String()),
      }),
    },
    async ({ request, query, redirect }) => {
      const back = new URL(appCallback);
      back.searchParams.set("state", query.state ?? "");
      if (!query.code) {
        back.searchParams.set("error", query.error ?? "denied");
        return redirect(back.toString(), 302);
      }
      try {
        const tokens = await token({
          grant_type: "authorization_code",
          code: query.code,
          redirect_uri: callbackUrl(request),
        });
        const result = await issue(tokens);
        back.searchParams.set("pass", result.pass);
        back.searchParams.set("renewal", result.renewal);
      } catch (error) {
        console.error(error);
        back.searchParams.set("error", "server");
      }
      return redirect(back.toString(), 302);
    },
  )
  .post("/patreon/renew", { body: t.Object({ renewal: t.String() }) }, async ({ body, status }) => {
    const refreshToken = await openRenewal(body.renewal, env.RENEWAL_KEY);
    if (!refreshToken) return status(401, { error: "signed_out" });
    try {
      return await issue(await token({ grant_type: "refresh_token", refresh_token: refreshToken }));
    } catch (error) {
      if (error instanceof SignedOut) return status(401, { error: "signed_out" });
      throw error;
    }
  });

export default {
  fetch(request: Request, bindings: Env) {
    env = bindings;
    return app.fetch(request);
  },
};

function callbackUrl(request: Request): string {
  return `${new URL(request.url).origin}${callbackPath}`;
}

interface Tokens {
  access_token: string;
  refresh_token: string;
}

async function token(grant: Record<string, string>): Promise<Tokens> {
  const response = await fetch(`${patreon}/api/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "user-agent": userAgent },
    body: new URLSearchParams({
      ...grant,
      client_id: env.PATREON_CLIENT_ID,
      client_secret: env.PATREON_CLIENT_SECRET,
    }),
  });
  if (response.status === 400 || response.status === 401) {
    throw new SignedOut(`Patreon refused the grant: ${response.status} ${await response.text()}`);
  }
  if (!response.ok) throw new Error(`Patreon token call failed: ${response.status}`);
  return (await response.json()) as Tokens;
}

async function issue(tokens: Tokens): Promise<{ pass: string; renewal: string }> {
  const identity = new URL(`${patreon}/api/oauth2/v2/identity`);
  identity.search = new URLSearchParams({
    include: "memberships.campaign,memberships.currently_entitled_tiers",
    "fields[member]": "patron_status",
    "fields[tier]": "amount_cents",
  }).toString();
  const response = await fetch(identity, {
    headers: { authorization: `Bearer ${tokens.access_token}`, "user-agent": userAgent },
  });
  if (response.status === 401) throw new SignedOut("Patreon refused the access token");
  if (!response.ok) throw new Error(`Patreon identity call failed: ${response.status}`);
  const membership = parseMembership(
    await response.json(),
    env.PATREON_CAMPAIGN_ID,
    env.PATREON_OWNER_USER_ID,
  );
  return {
    pass: await signPass({ sub: membership.userId, plus: membership.plus }, env.PASS_SIGNING_KEY),
    // Patreon refresh tokens are single use, so each renewal hands
    // back the new one.
    renewal: await sealRenewal(tokens.refresh_token, env.RENEWAL_KEY),
  };
}
