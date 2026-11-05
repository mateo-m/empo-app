const passLifetimeSeconds = 7 * 24 * 60 * 60;

export interface PassClaims {
  sub: string;
  plus: boolean;
}

export async function signPass(
  claims: PassClaims,
  signingKeyPkcs8: string,
  now = Date.now(),
): Promise<string> {
  const issuedAt = Math.floor(now / 1000);
  const payload = new TextEncoder().encode(
    JSON.stringify({ v: 1, ...claims, iat: issuedAt, exp: issuedAt + passLifetimeSeconds }),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    fromBase64(signingKeyPkcs8),
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, key, payload);
  return `${toBase64Url(payload)}.${toBase64Url(new Uint8Array(signature))}`;
}

export function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

export function fromBase64(text: string): Uint8Array<ArrayBuffer> {
  const standard = text.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(atob(standard), (char) => char.charCodeAt(0));
}
