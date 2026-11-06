import { fromBase64, toBase64Url, toHex } from "./pass";

// The device keeps the renewal. The server keeps only what it derives
// from it, so the stored Patreon token opens only with the device's copy.

export function newRenewal(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function renewalKeys(renewal: string): Promise<{ id: string; seal: CryptoKey } | null> {
  let bytes: Uint8Array<ArrayBuffer>;
  try {
    bytes = fromBase64(renewal);
  } catch {
    return null;
  }
  if (bytes.length !== 32) return null;
  const base = await crypto.subtle.importKey("raw", bytes, "HKDF", false, ["deriveBits", "deriveKey"]);
  const derive = (info: string) => ({
    name: "HKDF",
    hash: "SHA-256",
    salt: new Uint8Array(),
    info: new TextEncoder().encode(info),
  });
  const id = await crypto.subtle.deriveBits(derive("empo session id"), base, 256);
  const seal = await crypto.subtle.deriveKey(derive("empo session seal"), base, { name: "AES-GCM", length: 256 }, false, [
    "encrypt",
    "decrypt",
  ]);
  return { id: toHex(id), seal };
}

export async function seal(text: string, key: CryptoKey): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(text));
  const out = new Uint8Array(iv.length + sealed.byteLength);
  out.set(iv);
  out.set(new Uint8Array(sealed), iv.length);
  return toBase64Url(out);
}

export async function open(sealed: string, key: CryptoKey): Promise<string | null> {
  try {
    const bytes = fromBase64(sealed);
    const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
    return new TextDecoder().decode(opened);
  } catch {
    return null;
  }
}
