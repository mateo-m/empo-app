import { Elysia, ElysiaError, t } from "elysia";
import { WebStandardAdapter } from "elysia/adapter/web-standard";
import { deviceId, isDeviceKey } from "./device";
import type { MemberRequest } from "./member";
import { parseMembership } from "./membership";
import { fromBase64, signPass, toBase64Url } from "./pass";
import { type Env, patreon, token, userAgent } from "./patreon";
import { newRenewal, renewalKeys } from "./renewal";
import { callSession, type Held, type SessionRequest } from "./session";

export { PatreonMember } from "./member";
export { PatreonSession } from "./session";

interface Trip {
  state: string;
  // The public key of the device that signs in.
  device: string;
  // Sign out the other devices when the account is at its limit.
  replace: boolean;
}

const signed = t.Object({ renewal: t.String(), time: t.Number(), signature: t.String() });
const finish = t.Object({ code: t.String(), signature: t.String() });

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
    {
      query: t.Object({
        state: t.Optional(t.String()),
        device: t.Optional(t.String()),
        replace: t.Optional(t.String()),
      }),
    },
    async ({ request, query, redirect }) => {
      if (!query.device || !(await isDeviceKey(query.device))) {
        return redirect(backToApp(query.state ?? "", "server"), 302);
      }
      const trip: Trip = { state: query.state ?? "", device: query.device, replace: query.replace === "true" };
      const authorize = new URL(`${patreon}/oauth2/authorize`);
      authorize.search = new URLSearchParams({
        response_type: "code",
        client_id: env.PATREON_CLIENT_ID,
        redirect_uri: callbackUrl(request),
        // Without `identity.memberships`, Patreon returns only the
        // membership to this client's own campaign.
        scope: "identity",
        // Patreon gives the state back to the callback unchanged.
        state: toBase64Url(new TextEncoder().encode(JSON.stringify(trip))),
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
      const trip = readTrip(query.state);
      if (!trip) return redirect(backToApp("", "server"), 302);
      if (!query.code) return redirect(backToApp(trip.state, query.error ?? "denied"), 302);
      try {
        const tokens = await token(env, {
          grant_type: "authorization_code",
          code: query.code,
          redirect_uri: callbackUrl(request),
        });
        const { pass, userId } = await issue(tokens.access_token);
        const code = newRenewal();
        const keys = (await renewalKeys(code))!;
        const held = await callSession(env, keys.id, {
          action: "hold",
          code,
          refreshToken: tokens.refresh_token,
          device: trip.device,
          userId,
          pass,
          replace: trip.replace,
        });
        if (!held.ok) throw new Error(`The sign-in was not kept: ${held.status}`);
        const back = new URL(backToApp(trip.state));
        back.searchParams.set("code", code);
        return redirect(back.toString(), 302);
      } catch (error) {
        console.error(error);
        return redirect(backToApp(trip.state, "server"), 302);
      }
    },
  )
  .post("/patreon/finish", { body: finish }, async ({ body, status }) => {
    const answer = await session(body.code, { ...body, action: "finish" });
    if (answer.status === 401) return status(401, { error: "signed_out" });
    if (!answer.ok) throw new Error(`The sign-in did not finish: ${answer.status}`);
    const held = (await answer.json()) as Held & { device: string; refreshToken: string };
    const renewal = newRenewal();
    const keys = (await renewalKeys(renewal))!;
    // The session starts before the device list counts it. A session
    // that has not started answers 404 to "alive", so a second sign-in
    // at the same moment would not count this one.
    const started = await callSession(env, keys.id, {
      action: "start",
      renewal,
      refreshToken: held.refreshToken,
      device: held.device,
    });
    if (!started.ok) throw new Error(`The session did not start: ${started.status}`);
    const added = await member(held.userId, {
      action: "add",
      device: await deviceId(held.device),
      session: keys.id,
      replace: held.replace,
    });
    if (!added.ok) await callSession(env, keys.id, { action: "evict" });
    if (added.status === 409) return status(409, { error: "too_many_devices" });
    if (!added.ok) throw new Error(`The device list did not answer: ${added.status}`);
    return { pass: held.pass, renewal };
  })
  .post("/patreon/renew", { body: signed }, async ({ body, status }) => {
    const answer = await session(body.renewal, { ...body, action: "renew" });
    if (answer.status === 401) return status(401, { error: "signed_out" });
    if (answer.status === 409) return status(409, { error: "old_time" });
    if (!answer.ok) throw new Error(`The session did not renew: ${answer.status}`);
    const { accessToken } = (await answer.json()) as { accessToken: string };
    return { pass: (await issue(accessToken)).pass };
  })
  .post("/patreon/sign-out", { body: signed }, async ({ body }) => {
    const answer = await session(body.renewal, { ...body, action: "sign-out" });
    return new Response(null, { status: answer.status });
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

function backToApp(state: string, error?: string): string {
  const back = new URL(appCallback);
  back.searchParams.set("state", state);
  if (error) back.searchParams.set("error", error);
  return back.toString();
}

function readTrip(state: string | undefined): Trip | null {
  try {
    const trip = JSON.parse(new TextDecoder().decode(fromBase64(state ?? ""))) as Trip;
    return typeof trip.state === "string" && typeof trip.device === "string" ? trip : null;
  } catch {
    return null;
  }
}

async function session(renewal: string, request: SessionRequest): Promise<Response> {
  const keys = await renewalKeys(renewal);
  if (!keys) return Response.json({ error: "signed_out" }, { status: 401 });
  return callSession(env, keys.id, request);
}

function member(userId: string, request: MemberRequest): Promise<Response> {
  const stub = env.MEMBERS.get(env.MEMBERS.idFromName(userId));
  return stub.fetch(new Request("https://member", { method: "POST", body: JSON.stringify(request) }));
}

async function issue(accessToken: string): Promise<{ pass: string; userId: string }> {
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
  const pass = await signPass({ sub: membership.userId, plus: membership.plus }, env.PASS_SIGNING_KEY);
  return { pass, userId: membership.userId };
}
