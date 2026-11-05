import { Elysia, ElysiaError, t } from "elysia";
import { WebStandardAdapter } from "elysia/adapter/web-standard";
import { parseMembership } from "./membership";
import { signPass } from "./pass";
import { type Env, patreon, token, userAgent } from "./patreon";
import { newRenewal, renewalKeys } from "./renewal";
import type { SessionRequest } from "./session";

export { PatreonSession } from "./session";

// Workers pass the same bindings to every request of an isolate.
let env: Env;
const callbackPath = "/patreon/callback";
const appCallback = "empo://patreon";

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
        const tokens = await token(env, {
          grant_type: "authorization_code",
          code: query.code,
          redirect_uri: callbackUrl(request),
        });
        const pass = await issue(tokens.access_token);
        const renewal = newRenewal();
        const started = await session(renewal, { action: "start", renewal, refreshToken: tokens.refresh_token });
        if (!started.ok) throw new Error(`The session did not start: ${started.status}`);
        back.searchParams.set("pass", pass);
        back.searchParams.set("renewal", renewal);
      } catch (error) {
        console.error(error);
        back.searchParams.set("error", "server");
      }
      return redirect(back.toString(), 302);
    },
  )
  .post("/patreon/renew", { body: t.Object({ renewal: t.String() }) }, async ({ body, status }) => {
    const answer = await session(body.renewal, { action: "renew", renewal: body.renewal });
    if (answer.status === 401) return status(401, { error: "signed_out" });
    if (!answer.ok) throw new Error(`The session did not renew: ${answer.status}`);
    const { accessToken } = (await answer.json()) as { accessToken: string };
    return { pass: await issue(accessToken) };
  })
  .post("/patreon/sign-out", { body: t.Object({ renewal: t.String() }) }, async ({ body }) => {
    await session(body.renewal, { action: "end" });
    return new Response(null, { status: 204 });
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

async function session(renewal: string, request: SessionRequest): Promise<Response> {
  const keys = await renewalKeys(renewal);
  if (!keys) return Response.json({ error: "signed_out" }, { status: 401 });
  const stub = env.SESSIONS.get(env.SESSIONS.idFromName(keys.id));
  return stub.fetch(new Request("https://session", { method: "POST", body: JSON.stringify(request) }));
}

async function issue(accessToken: string): Promise<string> {
  const identity = new URL(`${patreon}/api/oauth2/v2/identity`);
  identity.search = new URLSearchParams({
    include: "memberships.campaign",
    "fields[member]": "patron_status,currently_entitled_amount_cents",
  }).toString();
  const response = await fetch(identity, {
    headers: { authorization: `Bearer ${accessToken}`, "user-agent": userAgent },
  });
  if (!response.ok) throw new Error(`Patreon identity call failed: ${response.status}`);
  const membership = parseMembership(await response.json(), env.PATREON_CAMPAIGN_ID, env.PATREON_OWNER_USER_ID);
  return signPass({ sub: membership.userId, plus: membership.plus }, env.PASS_SIGNING_KEY);
}
