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

export async function sealRenewal(refreshToken: string, key: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await aesKey(key, "encrypt"),
    new TextEncoder().encode(refreshToken),
  );
  const out = new Uint8Array(iv.length + sealed.byteLength);
  out.set(iv);
  out.set(new Uint8Array(sealed), iv.length);
  return toBase64Url(out);
}

export async function openRenewal(renewal: string, key: string): Promise<string | null> {
  try {
    const bytes = fromBase64(renewal);
    const opened = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.slice(0, 12) },
      await aesKey(key, "decrypt"),
      bytes.slice(12),
    );
    return new TextDecoder().decode(opened);
  } catch {
    return null;
  }
}

function aesKey(key: string, use: "encrypt" | "decrypt"): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", fromBase64(key), { name: "AES-GCM" }, false, [use]);
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function fromBase64(text: string): Uint8Array<ArrayBuffer> {
  const standard = text.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(atob(standard), (char) => char.charCodeAt(0));
}
