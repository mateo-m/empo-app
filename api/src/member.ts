import type { Env } from "./patreon";
import { callSession, type SessionState } from "./session";

export const deviceLimit = 3;
const checkAgainMs = 90 * 24 * 60 * 60 * 1000;

export type MemberRequest = { action: "add"; device: string; session: string; replace: boolean };

// One Durable Object per Patreon account. It maps the ID of each signed-in
// device to the ID of its session.
export class PatreonMember {
  constructor(
    private readonly state: SessionState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const body = (await request.json()) as MemberRequest;
    return this.state.blockConcurrencyWhile(() => this.add(body));
  }

  async alarm(): Promise<void> {
    await this.state.blockConcurrencyWhile(async () => {
      const devices = await this.liveDevices();
      if (Object.keys(devices).length === 0) return this.state.storage.deleteAll();
      await this.state.storage.put({ devices });
      await this.state.storage.setAlarm(Date.now() + checkAgainMs);
    });
  }

  // A throw inside `blockConcurrencyWhile` resets the object, so this
  // answers every failure.
  private async add({ device, session, replace }: MemberRequest): Promise<Response> {
    try {
      const devices = await this.liveDevices();
      const previous = devices[device];
      delete devices[device];
      if (previous && previous !== session) await callSession(this.env, previous, { action: "evict" });
      if (Object.keys(devices).length >= deviceLimit) {
        if (!replace) return Response.json({ error: "too_many_devices" }, { status: 409 });
        for (const other of Object.values(devices)) await callSession(this.env, other, { action: "evict" });
        for (const other of Object.keys(devices)) delete devices[other];
      }
      devices[device] = session;
      await this.state.storage.put({ devices });
      await this.state.storage.setAlarm(Date.now() + checkAgainMs);
      return new Response(null, { status: 204 });
    } catch (error) {
      console.error(error);
      return Response.json({ error: "server" }, { status: 502 });
    }
  }

  // A session ends without telling this object: on a sign-out, when
  // Patreon refuses it, or after 90 days without use.
  private async liveDevices(): Promise<Record<string, string>> {
    const devices = (await this.state.storage.get<Record<string, string>>("devices")) ?? {};
    const live: Record<string, string> = {};
    for (const [device, session] of Object.entries(devices)) {
      if ((await callSession(this.env, session, { action: "alive" })).status === 204) live[device] = session;
    }
    return live;
  }
}
