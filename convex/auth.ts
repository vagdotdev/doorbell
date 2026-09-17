import { Password } from "@convex-dev/auth/providers/Password";
import { convexAuth } from "@convex-dev/auth/server";
import { ConvexError } from "convex/values";

// Email + password. The Mac app calls `auth:signIn` with
// { provider: "password", params: { email, password, flow } } and refreshes with
// { refreshToken }. Nothing else is configured: no OAuth, no magic links yet.
export const { auth, signIn, signOut, store, isAuthenticated } = convexAuth({
  providers: [
    Password({
      profile(params) {
        const email = typeof params.email === "string" ? params.email.trim().toLowerCase() : "";
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
          throw new ConvexError("That doesn't look like an email address.");
        }
        return { email };
      },
      validatePasswordRequirements(password) {
        if (password.length < 8) {
          throw new ConvexError("Use at least 8 characters.");
        }
      },
    }),
  ],
});
