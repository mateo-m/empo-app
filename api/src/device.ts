import { fromBase64, toHex } from "./pass";

// The app sends a P-256 public key as an uncompressed point (CryptoKit
// `x963Representation`) and signatures as r and s (`rawRepresentation`).
// Web Crypto takes both formats as they are.

async function importDeviceKey(publicKey: string): Promise<CryptoKey | null> {
  try {
    return await crypto.subtle.importKey("raw", fromBase64(publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, [
      "verify",
    ]);
  } catch {
    return null;
  }
}

export async function isDeviceKey(publicKey: string): Promise<boolean> {
  return (await importDeviceKey(publicKey)) !== null;
}

export async function deviceId(publicKey: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", fromBase64(publicKey)));
}

export async function signedByDevice(publicKey: string, message: string, signature: string): Promise<boolean> {
  const key = await importDeviceKey(publicKey);
  if (!key) return false;
  try {
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      fromBase64(signature),
      new TextEncoder().encode(message),
    );
  } catch {
    return false;
  }
}
