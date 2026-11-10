import { type CloudflareOptions, captureConsoleIntegration } from "@sentry/cloudflare";

export function sentryOptions(): CloudflareOptions {
  return {
    integrations: [captureConsoleIntegration({ levels: ["error"] })],
    // The query and the body carry Patreon codes, renewal codes, and
    // device signatures. The SDK also sets the caller's IP address, and
    // the time zone from Cloudflare's location data.
    beforeSend(event) {
      delete event.user;
      delete event.contexts?.culture;
      if (event.request) {
        event.request = { method: event.request.method, url: event.request.url?.split("?")[0] };
      }
      return event;
    },
  };
}
