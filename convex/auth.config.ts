// Convex Auth issues the JWTs; this deployment verifies them against its own JWKS.
export default {
  providers: [
    {
      domain: process.env.CONVEX_SITE_URL,
      applicationID: "convex",
    },
  ],
};
