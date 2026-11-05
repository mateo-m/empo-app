import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { parseMembership } from "../src/membership";
import { signPass } from "../src/pass";
import { newRenewal, open, renewalKeys, seal } from "../src/renewal";
import { PatreonSession, type SessionState } from "../src/session";
import worker from "../src/worker";

function identity(member: { status: string; campaign: string; cents: number }) {
  return {
    data: {
      id: "user-1",
      type: "user",
      relationships: { memberships: { data: [{ id: "m-1", type: "member" }] } },
    },
    included: [
      {
        id: "m-1",
        type: "member",
        attributes: { patron_status: member.status, currently_entitled_amount_cents: member.cents },
        relationships: { campaign: { data: { id: member.campaign, type: "campaign" } } },
      },
    ],
  };
}

describe("parseMembership", () => {
  test("an active patron of a paid tier on the campaign has Plus", () => {
    const result = parseMembership(identity({ status: "active_patron", campaign: "c-1", cents: 300 }), "c-1", "owner");
    expect(result).toEqual({ userId: "user-1", plus: true });
  });

  test("a free member does not have Plus", () => {
    expect(parseMembership(identity({ status: "active_patron", campaign: "c-1", cents: 0 }), "c-1", "owner").plus).toBe(false);
  });

  test("a declined or former patron does not have Plus", () => {
    for (const status of ["declined_patron", "former_patron"]) {
      expect(parseMembership(identity({ status, campaign: "c-1", cents: 300 }), "c-1", "owner").plus).toBe(false);
    }
  });

  test("a patron of another campaign does not have Plus", () => {
    expect(parseMembership(identity({ status: "active_patron", campaign: "c-2", cents: 300 }), "c-1", "owner").plus).toBe(false);
  });

  test("the owner of the campaign has Plus without a membership", () => {
    const document = { data: { id: "owner", type: "user", relationships: { memberships: { data: [] } } } };
    expect(parseMembership(document, "c-1", "owner")).toEqual({ userId: "owner", plus: true });
  });

  test("a member with no amount does not have Plus", () => {
    const document = identity({ status: "active_patron", campaign: "c-1", cents: 0 });
    document.included[0]!.attributes.currently_entitled_amount_cents = null as unknown as number;
    expect(parseMembership(document, "c-1", "owner").plus).toBe(false);
  });

  test("a user with no memberships does not have Plus", () => {
    const document = { data: { id: "user-1", type: "user", relationships: { memberships: { data: [] } } } };
    expect(parseMembership(document, "c-1", "owner")).toEqual({ userId: "user-1", plus: false });
  });
});

function base64(bytes: ArrayBuffer) {
  return Buffer.from(bytes).toString("base64");
}

describe("pass", () => {
  test("the public key verifies a signed pass, and the pass ends after 7 days", async () => {
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const signingKey = base64(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    const now = Date.UTC(2026, 10, 5);
    const pass = await signPass({ sub: "user-1", plus: true }, signingKey, now);

    const [payload, signature] = pass.split(".").map((part) => Buffer.from(part, "base64url"));
    expect(await crypto.subtle.verify({ name: "Ed25519" }, pair.publicKey, signature!, payload!)).toBe(true);
    const claims = JSON.parse(payload!.toString());
    expect(claims).toEqual({ v: 1, sub: "user-1", plus: true, iat: now / 1000, exp: now / 1000 + 604800 });
  });

});

describe("renewal", () => {
  test("a sealed token opens only with the key of its own renewal", async () => {
    const keys = (await renewalKeys(newRenewal()))!;
    const other = (await renewalKeys(newRenewal()))!;
    const sealed = await seal("refresh-token", keys.seal);
    expect(await open(sealed, keys.seal)).toBe("refresh-token");
    expect(await open(sealed, other.seal)).toBeNull();
    expect(await open("not-sealed", keys.seal)).toBeNull();
    expect(keys.id).not.toBe(other.id);
  });

  test("a renewal that is not 32 bytes has no keys", async () => {
    for (const renewal of ["", "short", "%%%", "a".repeat(100)]) {
      expect(await renewalKeys(renewal)).toBeNull();
    }
  });
});

class MemoryState implements SessionState {
  readonly values = new Map<string, unknown>();
  alarm: number | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  storage = {
    get: async <T>(key: string) => this.values.get(key) as T | undefined,
    put: async (key: string, value: unknown) => void this.values.set(key, value),
    deleteAll: async () => this.values.clear(),
    setAlarm: async (time: number) => void (this.alarm = time),
    deleteAlarm: async () => void (this.alarm = null),
  };

  blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T> {
    const run = this.queue.then(callback);
    this.queue = run.catch(() => {});
    return run;
  }
}

// Patreon refresh tokens are single use: a spent one gets `invalid_grant`.
class FakePatreon {
  live = new Set<string>();
  answer: { status: number; body: object } | null = null;
  refreshedWith: string[] = [];
  private count = 0;

  issue(): { access_token: string; refresh_token: string } {
    const refresh = `refresh-${++this.count}`;
    this.live.add(refresh);
    return { access_token: `access-${this.count}`, refresh_token: refresh };
  }

  async fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const url = new URL(input instanceof Request ? input.url : input.toString());
    if (url.pathname === "/api/oauth2/v2/identity") return Response.json(identity({ status: "active_patron", campaign: "c-1", cents: 300 }));
    const form = new URLSearchParams(init!.body as URLSearchParams);
    if (this.answer) return Response.json(this.answer.body, { status: this.answer.status });
    if (form.get("grant_type") === "authorization_code") return Response.json(this.issue());
    const refresh = form.get("refresh_token")!;
    this.refreshedWith.push(refresh);
    // A real call takes time, so a second renewal can start meanwhile.
    await new Promise((resolve) => setTimeout(resolve, 5));
    if (!this.live.delete(refresh)) return Response.json({ error: "invalid_grant" }, { status: 400 });
    return Response.json(this.issue());
  }
}

describe("routes", () => {
  let patreon: FakePatreon;
  let states: Map<string, MemoryState>;
  let env: ConstructorParameters<typeof PatreonSession>[1];
  const original = globalThis.fetch;

  beforeEach(async () => {
    patreon = new FakePatreon();
    states = new Map();
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    env = {
      PATREON_CLIENT_ID: "client",
      PATREON_CLIENT_SECRET: "secret",
      PATREON_CAMPAIGN_ID: "c-1",
      PATREON_OWNER_USER_ID: "owner",
      PASS_SIGNING_KEY: base64(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      SESSIONS: {
        idFromName: (name: string) => name,
        get: (id: unknown) => {
          const name = id as string;
          if (!states.has(name)) states.set(name, new MemoryState());
          return new PatreonSession(states.get(name)!, env);
        },
      },
    };
    globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => patreon.fetch(input, init)) as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = original;
  });

  async function signIn(): Promise<{ pass: string; renewal: string }> {
    const response = await worker.fetch(new Request("https://api.test/patreon/callback?state=s-1&code=code-1"), env);
    const location = new URL(response.headers.get("location")!);
    expect(location.searchParams.get("error")).toBeNull();
    return { pass: location.searchParams.get("pass")!, renewal: location.searchParams.get("renewal")! };
  }

  function post(path: string, body: object) {
    return worker.fetch(
      new Request(`https://api.test${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
      env,
    );
  }

  function stored(): string {
    const values = [...states.values()].flatMap((state) => [...state.values.values()]);
    return JSON.stringify(values);
  }

  test("the server stores the Patreon token sealed, and never the renewal", async () => {
    const { renewal } = await signIn();
    expect(stored()).not.toContain("refresh-1");
    expect(stored()).not.toContain(renewal);
    expect([...states.keys()]).not.toContain(renewal);
  });

  test("a renewal whose answer got lost still works the next time", async () => {
    const { renewal } = await signIn();
    expect((await post("/patreon/renew", { renewal })).status).toBe(200);
    const again = await post("/patreon/renew", { renewal });
    expect(again.status).toBe(200);
    expect(((await again.json()) as { pass: string }).pass).toContain(".");
    expect(patreon.refreshedWith).toEqual(["refresh-1", "refresh-2"]);
  });

  test("two renewals at the same time never send the same token", async () => {
    const { renewal } = await signIn();
    const answers = await Promise.all([1, 2, 3].map(() => post("/patreon/renew", { renewal })));
    expect(answers.map((answer) => answer.status)).toEqual([200, 200, 200]);
    expect(new Set(patreon.refreshedWith).size).toBe(3);
  });

  test("a refused token signs the user out and deletes the stored token", async () => {
    const { renewal } = await signIn();
    patreon.answer = { status: 400, body: { error: "invalid_grant" } };
    expect((await post("/patreon/renew", { renewal })).status).toBe(401);
    expect(stored()).toBe("[]");
    patreon.answer = null;
    expect((await post("/patreon/renew", { renewal })).status).toBe(401);
  });

  test("a refused client is a server fault and keeps the user signed in", async () => {
    const { renewal } = await signIn();
    patreon.answer = { status: 401, body: { error: "invalid_client" } };
    expect((await post("/patreon/renew", { renewal })).status).toBe(502);
    patreon.answer = { status: 400, body: { error: "invalid_request" } };
    expect((await post("/patreon/renew", { renewal })).status).toBe(502);
    patreon.answer = null;
    expect((await post("/patreon/renew", { renewal })).status).toBe(200);
  });

  test("an unknown or broken renewal is signed out", async () => {
    await signIn();
    expect((await post("/patreon/renew", { renewal: newRenewal() })).status).toBe(401);
    expect((await post("/patreon/renew", { renewal: "broken" })).status).toBe(401);
    expect(patreon.refreshedWith).toEqual([]);
  });

  test("a sign-out deletes the stored token", async () => {
    const { renewal } = await signIn();
    expect((await post("/patreon/sign-out", { renewal })).status).toBe(204);
    expect(stored()).toBe("[]");
    expect((await post("/patreon/renew", { renewal })).status).toBe(401);
  });

  test("a session that nobody renews deletes itself", async () => {
    const { renewal } = await signIn();
    const state = [...states.values()][0]!;
    expect(state.alarm).toBeGreaterThan(Date.now() + 89 * 24 * 60 * 60 * 1000);
    await env.SESSIONS.get([...states.keys()][0]).alarm();
    expect(stored()).toBe("[]");
    expect((await post("/patreon/renew", { renewal })).status).toBe(401);
  });

  test("a denied sign-in goes back to the app with its state", async () => {
    const response = await worker.fetch(new Request("https://api.test/patreon/callback?state=s-1&error=access_denied"), env);
    const location = new URL(response.headers.get("location")!);
    expect(location.protocol).toBe("empo:");
    expect(location.searchParams.get("state")).toBe("s-1");
    expect(location.searchParams.get("error")).toBe("access_denied");
  });
});
