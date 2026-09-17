import { httpRouter } from "convex/server";
import { auth } from "./auth";

const http = httpRouter();

// /.well-known/openid-configuration and /.well-known/jwks.json, so the deployment
// can verify the tokens it issued.
auth.addHttpRoutes(http);

export default http;
