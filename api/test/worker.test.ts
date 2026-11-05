import { describe, expect, test } from "bun:test";
import { parseMembership } from "../src/membership";
import { openRenewal, sealRenewal, signPass } from "../src/pass";

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
        attributes: { patron_status: member.status },
        relationships: {
          campaign: { data: { id: member.campaign, type: "campaign" } },
          currently_entitled_tiers: { data: [{ id: "t-1", type: "tier" }] },
        },
      },
      { id: "t-1", type: "tier", attributes: { amount_cents: member.cents } },
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
