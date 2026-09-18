import { Password } from "@convex-dev/auth/providers/Password";
import { convexAuth } from "@convex-dev/auth/server";

// Email + password. The Mac app calls `auth:signIn` with
// { provider: "password", params: { email, password, flow } } and refreshes with
// { refreshToken }. Join uses `{handle}@doorbell.local` + the group join secret.
export const { auth, signIn, signOut, store, isAuthenticated } = convexAuth({
  providers: [Password()],
});
