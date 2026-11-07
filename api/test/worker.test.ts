import { afterEach, beforeEach, describe, expect, setSystemTime, test } from "bun:test";
import { parseMembership } from "../src/membership";
import { signPass } from "../src/pass";
import { newRenewal, open, renewalKeys, seal } from "../src/renewal";
import { deviceLimit, PatreonMember } from "../src/member";
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
    put: async (entries: Record<string, unknown>) => {
      for (const [key, value] of Object.entries(entries)) this.values.set(key, value);
    },
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

// The app keeps a P-256 key on the device and signs each call with it.
class Device {
  private time = Date.now();

  private constructor(
    private readonly keys: CryptoKeyPair,
    readonly publicKey: string,
  ) {}

  static async make(): Promise<Device> {
    const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    return new Device(keys, Buffer.from(await crypto.subtle.exportKey("raw", keys.publicKey)).toString("base64url"));
  }

  async sign(action: string, renewal: string, time = ++this.time) {
    return { renewal, time, signature: await this.signature(`${action} ${time}`) };
  }

  async signFinish(code: string) {
    return { code, signature: await this.signature(`finish ${code}`) };
  }

  private async signature(message: string) {
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      this.keys.privateKey,
      new TextEncoder().encode(message),
    );
    return Buffer.from(signature).toString("base64url");
  }
}

describe("routes", () => {
  let patreon: FakePatreon;
  let sessions: Map<string, MemoryState>;
  let members: Map<string, MemoryState>;
  let env: ConstructorParameters<typeof PatreonSession>[1];
  let phone: Device;
  // Each action in this set fails once, as a lost call.
  let broken: Set<string>;
  const original = globalThis.fetch;

  function namespace(states: Map<string, MemoryState>, make: (state: MemoryState) => { fetch(request: Request): Promise<Response> }) {
    return {
      idFromName: (name: string) => name,
      get: (id: unknown) => {
        const name = id as string;
        if (!states.has(name)) states.set(name, new MemoryState());
        const target = make(states.get(name)!);
        return {
          fetch: async (request: Request) => {
            const { action } = (await request.clone().json()) as { action: string };
            if (broken.delete(action)) throw new Error(`The ${action} call did not arrive`);
            return target.fetch(request);
          },
        };
      },
    };
  }

  beforeEach(async () => {
    patreon = new FakePatreon();
    sessions = new Map();
    members = new Map();
    broken = new Set();
    phone = await Device.make();
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    env = {
      PATREON_CLIENT_ID: "client",
      PATREON_CLIENT_SECRET: "secret",
      PATREON_CAMPAIGN_ID: "c-1",
      PATREON_OWNER_USER_ID: "owner",
      PASS_SIGNING_KEY: base64(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      SESSIONS: namespace(sessions, (state) => new PatreonSession(state, env)),
      MEMBERS: namespace(members, (state) => new PatreonMember(state, env)),
    };
    globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => patreon.fetch(input, init)) as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = original;
  });

  // Goes through the start route, so the state carries the device as in the app.
  async function callback(device: Device, replace = false): Promise<URL> {
    const query = new URLSearchParams({ state: "s-1", device: device.publicKey, replace: String(replace) });
    const start = await worker.fetch(new Request(`https://api.test/patreon/start?${query}`), env);
    const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
    const response = await worker.fetch(new Request(`https://api.test/patreon/callback?state=${state}&code=code-1`), env);
    const location = new URL(response.headers.get("location")!);
    expect(location.searchParams.get("state")).toBe("s-1");
    return location;
  }

  async function finish(device = phone, replace = false): Promise<Response> {
    const location = await callback(device, replace);
    expect(location.searchParams.get("error")).toBeNull();
    return post("/patreon/finish", await device.signFinish(location.searchParams.get("code")!));
  }

  async function signIn(device = phone, replace = false): Promise<{ pass: string; renewal: string }> {
    const answer = await finish(device, replace);
    expect(answer.status).toBe(200);
    return (await answer.json()) as { pass: string; renewal: string };
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

  async function renew(renewal: string, device = phone) {
    return post("/patreon/renew", await device.sign("renew", renewal));
  }

  function stored(): string {
    const values = [...sessions.values()].flatMap((state) => [...state.values.values()]);
    return JSON.stringify(values);
  }

  test("the server stores the Patreon token sealed, and never the renewal", async () => {
    const code = (await callback(phone)).searchParams.get("code")!;
    expect(stored()).not.toContain("refresh-1");
    expect(stored()).not.toContain(code);
    const { renewal } = (await (await post("/patreon/finish", await phone.signFinish(code))).json()) as { renewal: string };
    expect(stored()).not.toContain("refresh-1");
    expect(stored()).not.toContain(renewal);
    expect([...sessions.keys()]).not.toContain(renewal);
  });

  test("a renewal whose answer got lost still works the next time", async () => {
    const { renewal } = await signIn();
    expect((await renew(renewal)).status).toBe(200);
    const again = await renew(renewal);
    expect(again.status).toBe(200);
    expect(((await again.json()) as { pass: string }).pass).toContain(".");
    expect(patreon.refreshedWith).toEqual(["refresh-1", "refresh-2"]);
  });

  test("two renewals at the same time never send the same token", async () => {
    const { renewal } = await signIn();
    const calls = await Promise.all([1, 2, 3].map(() => phone.sign("renew", renewal)));
    const answers = await Promise.all(calls.map((call) => post("/patreon/renew", call)));
    // A call that arrives after a later one gets 409, which the app retries.
    for (const answer of answers) expect([200, 409]).toContain(answer.status);
    expect(new Set(patreon.refreshedWith).size).toBe(patreon.refreshedWith.length);
    expect((await renew(renewal)).status).toBe(200);
  });

  test("a refused token signs the user out and deletes the stored token", async () => {
    const { renewal } = await signIn();
    patreon.answer = { status: 400, body: { error: "invalid_grant" } };
    expect((await renew(renewal)).status).toBe(401);
    expect(stored()).toBe("[]");
    patreon.answer = null;
    expect((await renew(renewal)).status).toBe(401);
  });

  test("a refused client is a server fault and keeps the user signed in", async () => {
    const { renewal } = await signIn();
    patreon.answer = { status: 401, body: { error: "invalid_client" } };
    expect((await renew(renewal)).status).toBe(502);
    patreon.answer = { status: 400, body: { error: "invalid_request" } };
    expect((await renew(renewal)).status).toBe(502);
    patreon.answer = null;
    expect((await renew(renewal)).status).toBe(200);
  });

  test("an unknown or broken renewal is signed out", async () => {
    await signIn();
    expect((await renew(newRenewal())).status).toBe(401);
    expect((await renew("broken")).status).toBe(401);
    expect(patreon.refreshedWith).toEqual([]);
  });

  test("a copied renewal does not work without the key of its device", async () => {
    const { renewal } = await signIn();
    const other = await Device.make();
    expect((await renew(renewal, other)).status).toBe(401);
    expect((await post("/patreon/sign-out", await other.sign("sign-out", renewal))).status).toBe(401);
    const signed = await phone.sign("renew", renewal);
    expect((await post("/patreon/renew", { ...signed, time: signed.time + 1 })).status).toBe(401);
    expect((await post("/patreon/renew", await phone.sign("sign-out", renewal))).status).toBe(401);
    expect(patreon.refreshedWith).toEqual([]);
    expect((await renew(renewal)).status).toBe(200);
  });

  test("a repeated call is refused and keeps the device signed in", async () => {
    const { renewal } = await signIn();
    const call = await phone.sign("renew", renewal);
    expect((await post("/patreon/renew", call)).status).toBe(200);
    expect((await post("/patreon/renew", call)).status).toBe(409);
    expect((await post("/patreon/sign-out", await phone.sign("sign-out", renewal, call.time))).status).toBe(409);
    expect((await renew(renewal)).status).toBe(200);
  });

  test("a sign-out deletes the stored token", async () => {
    const { renewal } = await signIn();
    expect((await post("/patreon/sign-out", await phone.sign("sign-out", renewal))).status).toBe(204);
    expect(stored()).toBe("[]");
    expect((await renew(renewal)).status).toBe(401);
  });

  test("a session that nobody renews deletes itself", async () => {
    const { renewal } = await signIn();
    const state = [...sessions.values()].find((session) => session.values.size > 0)!;
    expect(state.alarm).toBeGreaterThan(Date.now() + 89 * 24 * 60 * 60 * 1000);
    await new PatreonSession(state, env).alarm();
    expect(stored()).toBe("[]");
    expect((await renew(renewal)).status).toBe(401);
  });

  test("an account signs in on at most 3 devices", async () => {
    const devices = [phone, ...(await Promise.all([1, 2, 3].map(() => Device.make())))];
    const renewals = [];
    for (const device of devices.slice(0, deviceLimit)) renewals.push((await signIn(device)).renewal);
    const code = (await callback(devices[3]!)).searchParams.get("code")!;
    const call = await devices[3]!.signFinish(code);
    expect((await post("/patreon/finish", call)).status).toBe(409);
    expect((await post("/patreon/finish", call)).status).toBe(401);
    expect([...sessions.values()].filter((state) => state.values.size > 0).length).toBe(deviceLimit);
    for (const [index, renewal] of renewals.entries()) expect((await renew(renewal, devices[index])).status).toBe(200);
  });

  test("sign-ins at the same moment still stop at 3 devices", async () => {
    const devices = [phone, ...(await Promise.all([1, 2, 3].map(() => Device.make())))];
    const answers = await Promise.all(devices.map((device) => finish(device)));
    const refused = answers.filter((answer) => answer.status === 409);
    expect(refused.length).toBe(devices.length - deviceLimit);
    expect([...sessions.values()].filter((state) => state.values.size > 0).length).toBe(deviceLimit);
  });

  test("a sign-in that replaces the others signs them out", async () => {
    const devices = [phone, ...(await Promise.all([1, 2, 3].map(() => Device.make())))];
    const renewals = [];
    for (const device of devices.slice(0, deviceLimit)) renewals.push((await signIn(device)).renewal);
    const last = await signIn(devices[3], true);
    for (const [index, renewal] of renewals.entries()) expect((await renew(renewal, devices[index])).status).toBe(401);
    expect((await renew(last.renewal, devices[3])).status).toBe(200);
    expect((await finish(phone)).status).toBe(200);
  });

  test("a device that signs in again keeps one place and ends its old session", async () => {
    const first = await signIn();
    for (let count = 0; count < 4; count++) await signIn();
    const second = await Device.make();
    const third = await Device.make();
    await signIn(second);
    await signIn(third);
    expect((await renew(first.renewal)).status).toBe(401);
  });

  test("a device that signed out does not count", async () => {
    const devices = [phone, ...(await Promise.all([1, 2, 3].map(() => Device.make())))];
    const renewals = [];
    for (const device of devices.slice(0, deviceLimit)) renewals.push((await signIn(device)).renewal);
    await post("/patreon/sign-out", await phone.sign("sign-out", renewals[0]!));
    expect((await finish(devices[3]!)).status).toBe(200);
  });

  test("the device list deletes itself when no session is left", async () => {
    const { renewal } = await signIn();
    await post("/patreon/sign-out", await phone.sign("sign-out", renewal));
    const state = [...members.values()][0]!;
    await new PatreonMember(state, env).alarm();
    expect(state.values.size).toBe(0);
  });

  test("a sign-in link made for another device signs out no device", async () => {
    const devices = [phone, ...(await Promise.all([1, 2].map(() => Device.make())))];
    const renewals = [];
    for (const device of devices) renewals.push((await signIn(device)).renewal);
    const attacker = await Device.make();
    // The victim opens the link, so the code goes to the victim's app.
    const location = await callback(attacker, true);
    const code = location.searchParams.get("code")!;
    expect(location.searchParams.get("pass")).toBeNull();
    expect(location.searchParams.get("renewal")).toBeNull();
    expect((await post("/patreon/finish", await phone.signFinish(code))).status).toBe(401);
    for (const [index, renewal] of renewals.entries()) expect((await renew(renewal, devices[index])).status).toBe(200);
  });

  test("a sign-in finishes once, and only as a sign-in", async () => {
    const location = await callback(phone);
    const code = location.searchParams.get("code")!;
    expect((await post("/patreon/renew", await phone.sign("renew", code))).status).toBe(401);
    const other = (await callback(phone)).searchParams.get("code")!;
    const call = await phone.signFinish(code);
    expect((await post("/patreon/finish", { ...call, code: other })).status).toBe(401);
    expect((await post("/patreon/finish", call)).status).toBe(200);
    expect((await post("/patreon/finish", await phone.signFinish(code))).status).toBe(401);
    const { renewal } = await signIn();
    expect((await post("/patreon/finish", await phone.signFinish(renewal))).status).toBe(401);
  });

  test("many finishes of one sign-in at once keep one session", async () => {
    const code = (await callback(phone)).searchParams.get("code")!;
    const call = await phone.signFinish(code);
    const answers = await Promise.all([1, 2, 3, 4, 5].map(() => post("/patreon/finish", call)));
    expect(answers.map((answer) => answer.status).sort()).toEqual([200, 401, 401, 401, 401]);
    expect([...sessions.values()].filter((state) => state.values.size > 0)).toHaveLength(1);
  });

  test("a sign-in whose session did not start finishes on the next try", async () => {
    const call = await phone.signFinish((await callback(phone)).searchParams.get("code")!);
    broken.add("start");
    expect((await post("/patreon/finish", call)).status).toBe(502);
    const answer = await post("/patreon/finish", call);
    expect(answer.status).toBe(200);
    const { renewal } = (await answer.json()) as { renewal: string };
    expect((await renew(renewal)).status).toBe(200);
  });

  test("a session that the device list did not add ends after 10 minutes, and the sign-in finishes on the next try", async () => {
    const call = await phone.signFinish((await callback(phone)).searchParams.get("code")!);
    broken = new Set(["add", "evict"]);
    expect((await post("/patreon/finish", call)).status).toBe(502);
    for (const state of sessions.values()) {
      if (state.values.size > 0) expect(state.alarm).toBeLessThanOrEqual(Date.now() + 10 * 60 * 1000);
    }
    expect((await post("/patreon/finish", call)).status).toBe(200);
  });

  test("a sign-in whose finish could not release its claim finishes again after 30 seconds", async () => {
    const call = await phone.signFinish((await callback(phone)).searchParams.get("code")!);
    broken = new Set(["start", "release"]);
    expect((await post("/patreon/finish", call)).status).toBe(502);
    expect((await post("/patreon/finish", call)).status).toBe(401);
    try {
      setSystemTime(new Date(Date.now() + 30 * 1000));
      const answer = await post("/patreon/finish", call);
      expect(answer.status).toBe(200);
      const { renewal } = (await answer.json()) as { renewal: string };
      expect((await renew(renewal)).status).toBe(200);
    } finally {
      setSystemTime();
    }
  });

  test("a late release of an old claim does not free the claim of a newer finish", async () => {
    const state = new MemoryState();
    const session = new PatreonSession(state, env);
    await state.storage.put({ phase: "claimed", claim: "newer" });
    const release = (claim: string) =>
      session.fetch(new Request("https://session", { method: "POST", body: JSON.stringify({ action: "release", claim }) }));
    expect((await release("older")).status).toBe(404);
    expect(await state.storage.get("phase")).toBe("claimed");
    expect((await release("newer")).status).toBe(204);
    expect(await state.storage.get("phase")).toBe("held");
  });

  test("a session stored without a phase still renews", async () => {
    const { renewal } = await signIn();
    for (const state of sessions.values()) state.values.delete("phase");
    expect((await renew(renewal)).status).toBe(200);
  });

  test("a sign-in code stored without a phase still finishes", async () => {
    const code = (await callback(phone)).searchParams.get("code")!;
    for (const state of sessions.values()) state.values.delete("phase");
    const answer = await post("/patreon/finish", await phone.signFinish(code));
    expect(answer.status).toBe(200);
    const { renewal } = (await answer.json()) as { renewal: string };
    expect((await renew(renewal)).status).toBe(200);
  });

  test("sessions stored without a phase still count toward the device limit", async () => {
    const devices = [phone, ...(await Promise.all([1, 2, 3].map(() => Device.make())))];
    for (const device of devices.slice(0, deviceLimit)) await signIn(device);
    for (const state of sessions.values()) state.values.delete("phase");
    expect((await finish(devices[3]!)).status).toBe(409);
  });

  test("a sign-in that nobody finishes deletes itself after 10 minutes", async () => {
    await callback(phone);
    const state = [...sessions.values()][0]!;
    expect(state.alarm).toBeGreaterThan(Date.now() + 9 * 60 * 1000);
    expect(state.alarm).toBeLessThanOrEqual(Date.now() + 10 * 60 * 1000);
    await new PatreonSession(state, env).alarm();
    expect(stored()).toBe("[]");
  });

  test("a sign-in code does not work after 10 minutes, also when the alarm is late", async () => {
    const code = (await callback(phone)).searchParams.get("code")!;
    const call = await phone.signFinish(code);
    try {
      setSystemTime(new Date(Date.now() + 10 * 60 * 1000));
      expect((await post("/patreon/finish", call)).status).toBe(401);
    } finally {
      setSystemTime();
    }
    expect(stored()).toBe("[]");
  });

  test("a start without a device key goes back to the app", async () => {
    for (const query of ["state=s-1", "state=s-1&device=bad"]) {
      const response = await worker.fetch(new Request(`https://api.test/patreon/start?${query}`), env);
      const location = new URL(response.headers.get("location")!);
      expect(location.protocol).toBe("empo:");
      expect(location.searchParams.get("error")).toBe("server");
    }
  });

  test("a denied sign-in goes back to the app with its state", async () => {
    const query = new URLSearchParams({ state: "s-1", device: phone.publicKey });
    const start = await worker.fetch(new Request(`https://api.test/patreon/start?${query}`), env);
    const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
    const response = await worker.fetch(new Request(`https://api.test/patreon/callback?state=${state}&error=access_denied`), env);
    const location = new URL(response.headers.get("location")!);
    expect(location.protocol).toBe("empo:");
    expect(location.searchParams.get("state")).toBe("s-1");
    expect(location.searchParams.get("error")).toBe("access_denied");
  });
});
