import { captureConsoleIntegration } from "@sentry/cloudflare";
import type { Env } from "./patreon";

export function sentryOptions(env: Env) {
  return {
    dsn: env.SENTRY_DSN,
    integrations: [captureConsoleIntegration({ levels: ["error"] })],
    // The query and the body carry Patreon codes, renewal codes, and
    // device signatures. The SDK also sets the caller's IP address.
    beforeSend<T extends { request?: { method?: string; url?: string }; user?: unknown }>(event: T): T {
      delete event.user;
      if (event.request) {
        event.request = { method: event.request.method, url: event.request.url?.split("?")[0] };
      }
      return event;
    },
  };
}
