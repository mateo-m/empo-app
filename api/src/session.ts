import { type Env, SignedOut, token } from "./patreon";
import { open, renewalKeys, seal } from "./renewal";

const unusedLifetimeMs = 90 * 24 * 60 * 60 * 1000;
const refreshTokenKey = "refreshToken";

export type SessionRequest =
  | { action: "start"; renewal: string; refreshToken: string }
  | { action: "renew"; renewal: string }
  | { action: "end" };

export interface SessionState {
  storage: {
    get<T>(key: string): Promise<T | undefined>;
    put(key: string, value: unknown): Promise<void>;
    deleteAll(): Promise<void>;
    setAlarm(time: number): Promise<void>;
    deleteAlarm(): Promise<void>;
  };
  blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T>;
}

// One Durable Object per signed-in device. It keeps the newest Patreon
// refresh token, sealed with a key from the device's renewal.
export class PatreonSession {
  constructor(
    private readonly state: SessionState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const body = (await request.json()) as SessionRequest;
    switch (body.action) {
      case "start":
        await this.store(body.refreshToken, body.renewal);
        return new Response(null, { status: 204 });
      case "renew":
        // Patreon refresh tokens are single use. This holds every other
        // request to this object until the new token is stored.
        return this.state.blockConcurrencyWhile(() => this.renew(body.renewal));
      case "end":
        await this.end();
        return new Response(null, { status: 204 });
    }
  }

  async alarm(): Promise<void> {
    await this.state.storage.deleteAll();
  }

  // A throw inside `blockConcurrencyWhile` resets the object, so this
  // answers every failure.
  private async renew(renewal: string): Promise<Response> {
    try {
      const keys = await renewalKeys(renewal);
      const sealed = await this.state.storage.get<string>(refreshTokenKey);
      const refreshToken = keys && sealed ? await open(sealed, keys.seal) : null;
      if (!refreshToken) return signedOut();
      const tokens = await token(this.env, { grant_type: "refresh_token", refresh_token: refreshToken });
      await this.store(tokens.refresh_token, renewal);
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

  private async store(refreshToken: string, renewal: string): Promise<void> {
    const keys = await renewalKeys(renewal);
    if (!keys) throw new Error("A session needs a valid renewal");
    await this.state.storage.put(refreshTokenKey, await seal(refreshToken, keys.seal));
    await this.state.storage.setAlarm(Date.now() + unusedLifetimeMs);
  }

  private async end(): Promise<void> {
    await this.state.storage.deleteAlarm();
    await this.state.storage.deleteAll();
  }
}

function signedOut(): Response {
  return Response.json({ error: "signed_out" }, { status: 401 });
}
