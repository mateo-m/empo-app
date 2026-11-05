import { describe, expect, test } from "bun:test";
import { parseMembership } from "../src/membership";
import { openRenewal, sealRenewal, signPass } from "../src/pass";
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

  test("a renewal opens with its key and not with another key", async () => {
    const key = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64");
    const other = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64");
    const sealed = await sealRenewal("refresh-token", key);
    expect(await openRenewal(sealed, key)).toBe("refresh-token");
    expect(await openRenewal(sealed, other)).toBeNull();
    expect(await openRenewal("not-a-renewal", key)).toBeNull();
  });
});

describe("routes", () => {
  const renewalKey = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64");
  const env = {
    PATREON_CLIENT_ID: "client",
    PATREON_CLIENT_SECRET: "secret",
    PATREON_CAMPAIGN_ID: "c-1",
    PATREON_OWNER_USER_ID: "owner",
    PASS_SIGNING_KEY: "",
    RENEWAL_KEY: renewalKey,
  };

  async function renewWhilePatreonAnswers(status: number, body: object) {
    const original = globalThis.fetch;
    globalThis.fetch = (async () => Response.json(body, { status })) as unknown as typeof fetch;
    try {
      const request = new Request("https://api.test/patreon/renew", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ renewal: await sealRenewal("refresh-token", renewalKey) }),
      });
      return await worker.fetch(request, env);
    } finally {
      globalThis.fetch = original;
    }
  }

  test("a refused refresh token signs the user out", async () => {
    const response = await renewWhilePatreonAnswers(400, { error: "invalid_grant" });
    expect(response.status).toBe(401);
  });

  test("a refused client is a server fault and keeps the user signed in", async () => {
    expect((await renewWhilePatreonAnswers(401, { error: "invalid_client" })).status).toBe(502);
    expect((await renewWhilePatreonAnswers(400, { error: "invalid_request" })).status).toBe(502);
  });

  test("a denied sign-in goes back to the app with its state", async () => {
    const response = await worker.fetch(
      new Request("https://api.test/patreon/callback?state=s-1&error=access_denied"),
      env,
    );
    const location = new URL(response.headers.get("location")!);
    expect(location.protocol).toBe("empo:");
    expect(location.searchParams.get("state")).toBe("s-1");
    expect(location.searchParams.get("error")).toBe("access_denied");
  });
});
