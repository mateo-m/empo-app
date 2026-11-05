import { signedByDevice } from "./device";
import { type Env, SignedOut, token } from "./patreon";
import { open, renewalKeys, seal } from "./renewal";

const unusedLifetimeMs = 90 * 24 * 60 * 60 * 1000;

export interface Signed {
  renewal: string;
  // Milliseconds since 1970 on the device. Each call must send a later
  // time than the last one, so a copied call can't run twice.
  time: number;
  signature: string;
}

export type SessionRequest =
  | { action: "start"; renewal: string; refreshToken: string; device: string }
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
        await this.store(body.refreshToken, body.renewal, { device: body.device, time: 0 });
        return new Response(null, { status: 204 });
      case "renew":
      case "sign-out":
        // Patreon refresh tokens are single use. This holds every other
        // request to this object until the new token is stored.
        return this.state.blockConcurrencyWhile(() => this.signed(body));
      case "evict":
        await this.end();
        return new Response(null, { status: 204 });
      case "alive":
        return new Response(null, { status: (await this.state.storage.get("device")) ? 204 : 404 });
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
      if (!device || !(await signedByDevice(device, `${request.action} ${request.time}`, request.signature))) {
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

  private async store(refreshToken: string, renewal: string, more: Record<string, unknown>): Promise<void> {
    const keys = await renewalKeys(renewal);
    if (!keys) throw new Error("A session needs a valid renewal");
    await this.state.storage.put({ refreshToken: await seal(refreshToken, keys.seal), ...more });
    await this.state.storage.setAlarm(Date.now() + unusedLifetimeMs);
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
