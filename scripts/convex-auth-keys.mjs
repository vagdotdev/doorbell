// Give a Convex deployment the keys Convex Auth signs sessions with.
//
//   node scripts/convex-auth-keys.mjs            # the dev deployment in .env.local
//   node scripts/convex-auth-keys.mjs --prod     # production
//
// Sets JWT_PRIVATE_KEY, JWKS and SITE_URL. Skips a deployment that already has a key,
// because rotating it signs everyone out. Same output as `npx @convex-dev/auth`, without
// touching project files.
import { execFileSync } from "node:child_process";
import { exportJWK, exportPKCS8, generateKeyPair } from "jose";

const prod = process.argv.includes("--prod");
const scope = prod ? ["--prod"] : [];
const convex = (...args) =>
  execFileSync("npx", ["convex", ...args, ...scope], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();

const existing = convex("env", "list");
if (/^JWT_PRIVATE_KEY=/m.test(existing)) {
  console.log("JWT_PRIVATE_KEY already set; leaving keys alone.");
} else {
  const keys = await generateKeyPair("RS256", { extractable: true });
  const privateKey = await exportPKCS8(keys.privateKey);
  const publicKey = await exportJWK(keys.publicKey);
  const jwks = JSON.stringify({ keys: [{ use: "sig", ...publicKey }] });
  // NAME=value form: the PEM starts with dashes and would be read as a flag.
  convex("env", "set", `JWT_PRIVATE_KEY=${privateKey.trimEnd().replace(/\n/g, " ")}`);
  convex("env", "set", `JWKS=${jwks}`);
  console.log("JWT_PRIVATE_KEY and JWKS set.");
}
if (!/^SITE_URL=/m.test(existing)) {
  // Convex Auth wants one for redirects; the Mac app never follows a redirect.
  convex("env", "set", "SITE_URL=http://localhost");
  console.log("SITE_URL set.");
}
