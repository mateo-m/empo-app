import { signedByDevice } from "./device";
import { type Env, SignedOut, token } from "./patreon";
import { open, renewalKeys, seal } from "./renewal";

const unusedLifetimeMs = 90 * 24 * 60 * 60 * 1000;
const heldLifetimeMs = 10 * 60 * 1000;
// A worker that stops in the middle of a finish sends no release, so
// a claim lapses after this time and the next finish can take it.
const claimLifetimeMs = 30 * 1000;

export interface Signed {
  renewal: string;
  // Milliseconds since 1970 on the device. Each call must send a later
  // time than the last one, so a copied call can't run twice.
  time: number;
  signature: string;
}

export interface Held {
  userId: string;
  pass: string;
  replace: boolean;
}

export interface Finish {
  code: string;
  signature: string;
}

// held: a sign-in code waits for the app to finish it.
// claimed: a finish took the code and did not end yet.
// started: a new session waits for the device list to add it.
// signed-in: the device list has the session.
type Phase = "held" | "claimed" | "started" | "signed-in";

export type SessionRequest =
  | { action: "start"; renewal: string; refreshToken: string; device: string }
  | ({ action: "hold"; code: string; refreshToken: string; device: string } & Held)
  | ({ action: "finish" } & Finish)
  | { action: "release"; claim: string }
  | { action: "confirm" }
  | ({ action: "renew" } & Signed)
  | ({ action: "sign-out" } & Signed)
  | { action: "evict" }
  | { action: "alive" };

export interface SessionState {
  storage: {
    get<T>(key: string): Promise<T | undefined>;
    put(entries: Record<string, unknown>): Promise<void>;
    deleteAll(): Promise<void>;
    setAlarm(time: number): Promise<void>;
    deleteAlarm(): Promise<void>;
  };
  blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T>;
}

// One Durable Object per signed-in device. It keeps the newest Patreon
// refresh token, sealed with a key from the device's renewal, and the
// public key of the device.
export class PatreonSession {
  constructor(
    private readonly state: SessionState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const body = (await request.json()) as SessionRequest;
    switch (body.action) {
      case "start":
        await this.store(
          body.refreshToken,
          body.renewal,
          { phase: "started", device: body.device, time: 0 },
          heldLifetimeMs,
        );
        return new Response(null, { status: 204 });
      case "hold": {
        const held: Held = { userId: body.userId, pass: body.pass, replace: body.replace };
        await this.store(
          body.refreshToken,
          body.code,
          { phase: "held", device: body.device, held, expires: Date.now() + heldLifetimeMs },
          heldLifetimeMs,
        );
        return new Response(null, { status: 204 });
      }
      case "finish":
        return this.state.blockConcurrencyWhile(() => this.finish(body));
      case "release":
        return this.state.blockConcurrencyWhile(() => this.release(body.claim));
      case "confirm":
        return this.state.blockConcurrencyWhile(() => this.move("started", "signed-in", unusedLifetimeMs));
      case "renew":
      case "sign-out":
        // Patreon refresh tokens are single use. This holds every other
        // request to this object until the new token is stored.
        return this.state.blockConcurrencyWhile(() => this.signed(body));
      case "evict":
        await this.end();
        return new Response(null, { status: 204 });
      case "alive": {
        const phase = await this.phase();
        return new Response(null, { status: phase === "started" || phase === "signed-in" ? 204 : 404 });
      }
    }
  }

  async alarm(): Promise<void> {
    await this.state.storage.deleteAll();
  }

  // A throw inside `blockConcurrencyWhile` resets the object, so this
  // answers every failure.
  private async signed(request: ({ action: "renew" } | { action: "sign-out" }) & Signed): Promise<Response> {
    try {
      const device = await this.state.storage.get<string>("device");
      const lastTime = (await this.state.storage.get<number>("time")) ?? 0;
      if ((await this.phase()) !== "signed-in" || !device || !(await signedByDevice(device, `${request.action} ${request.time}`, request.signature))) {
        return signedOut();
      }
      // An old time is a repeated call, or a device clock that went
      // back. Neither is a reason to sign the device out.
      if (!(request.time > lastTime)) return Response.json({ error: "old_time" }, { status: 409 });
      if (request.action === "sign-out") {
        await this.end();
        return new Response(null, { status: 204 });
      }
      const keys = await renewalKeys(request.renewal);
      const sealed = await this.state.storage.get<string>("refreshToken");
      const refreshToken = keys && sealed ? await open(sealed, keys.seal) : null;
      if (!refreshToken) return signedOut();
      const tokens = await token(this.env, { grant_type: "refresh_token", refresh_token: refreshToken });
      await this.store(tokens.refresh_token, request.renewal, { time: request.time });
      return Response.json({ accessToken: tokens.access_token });
    } catch (error) {
      if (error instanceof SignedOut) {
        await this.end();
        return signedOut();
      }
      console.error(error);
      return Response.json({ error: "server" }, { status: 502 });
    }
  }

  private async finish(request: Finish): Promise<Response> {
    try {
      const device = await this.state.storage.get<string>("device");
      const held = await this.state.storage.get<Held>("held");
      // An alarm can run late, so the alarm alone does not end the code.
      const expires = (await this.state.storage.get<number>("expires")) ?? 0;
      const phase = await this.phase();
      const claimLapsed = phase === "claimed" && Date.now() >= ((await this.state.storage.get<number>("claimedUntil")) ?? 0);
      if ((phase !== "held" && !claimLapsed) || !held || !device || !(await signedByDevice(device, `finish ${request.code}`, request.signature))) {
        return signedOut();
      }
      if (Date.now() >= expires) {
        await this.end();
        return signedOut();
      }
      const keys = await renewalKeys(request.code);
      const sealed = await this.state.storage.get<string>("refreshToken");
      const refreshToken = keys && sealed ? await open(sealed, keys.seal) : null;
      if (!refreshToken) {
        await this.end();
        return signedOut();
      }
      // The code stays until the device list has the new session, so a
      // failed step can release the code for one more finish.
      const claim = crypto.randomUUID();
      await this.state.storage.put({ phase: "claimed", claim, claimedUntil: Date.now() + claimLifetimeMs });
      return Response.json({ ...held, device, refreshToken, claim });
    } catch (error) {
      console.error(error);
      return Response.json({ error: "server" }, { status: 502 });
    }
  }

  private async release(claim: string): Promise<Response> {
    if ((await this.state.storage.get<string>("claim")) !== claim) return new Response(null, { status: 404 });
    return this.move("claimed", "held");
  }

  private async move(from: Phase, to: Phase, lifetimeMs?: number): Promise<Response> {
    if ((await this.phase()) !== from) return new Response(null, { status: 404 });
    await this.state.storage.put({ phase: to });
    if (lifetimeMs) await this.state.storage.setAlarm(Date.now() + lifetimeMs);
    return new Response(null, { status: 204 });
  }

  // A session that an older version stored has no phase key.
  private async phase(): Promise<Phase | undefined> {
    const phase = await this.state.storage.get<Phase>("phase");
    if (phase) return phase;
    if (await this.state.storage.get<Held>("held")) return "held";
    if (await this.state.storage.get<string>("device")) return "signed-in";
    return undefined;
  }

  private async store(
    refreshToken: string,
    secret: string,
    more: Record<string, unknown>,
    lifetimeMs = unusedLifetimeMs,
  ): Promise<void> {
    const keys = await renewalKeys(secret);
    if (!keys) throw new Error("A session needs a valid renewal");
    await this.state.storage.put({ refreshToken: await seal(refreshToken, keys.seal), ...more });
    await this.state.storage.setAlarm(Date.now() + lifetimeMs);
  }

  private async end(): Promise<void> {
    await this.state.storage.deleteAlarm();
    await this.state.storage.deleteAll();
  }
}

export function callSession(env: Env, id: string, request: SessionRequest): Promise<Response> {
  const stub = env.SESSIONS.get(env.SESSIONS.idFromName(id));
  return stub.fetch(new Request("https://session", { method: "POST", body: JSON.stringify(request) }));
}

function signedOut(): Response {
  return Response.json({ error: "signed_out" }, { status: 401 });
}
