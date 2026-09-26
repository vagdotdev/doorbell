import { v } from "convex/values";
import { internalAction } from "./_generated/server";

/// Ping the owner's phone when somebody claims a handle. One POST to ntfy.sh —
/// no account, no API key; the secret topic (NTFY_TOPIC, set by
/// scripts/admin-setup.sh) is the only credential. Unset topic means no ping,
/// so tests and fresh deployments stay silent. Scheduled from
/// profiles:claimHandle after the insert commits.
export const newAccount = internalAction({
  args: { handle: v.string(), displayName: v.string() },
  returns: v.null(),
  handler: async (_ctx, args) => {
    const topic = process.env.NTFY_TOPIC;
    if (!topic) {
      console.log("NTFY_TOPIC unset; skipping new-account ping");
      return null;
    }
    const res = await fetch(`https://ntfy.sh/${topic}`, {
      method: "POST",
      headers: { Title: "New door on Doorbell", Tags: "door", Priority: "4" },
      body: `${args.displayName} (@${args.handle}) just joined`,
    });
    if (!res.ok) console.warn(`ntfy publish failed: ${res.status}`);
    return null;
  },
});
