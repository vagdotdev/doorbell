import { defineApp } from "convex/server";
import apiKeys from "convex-api-keys/convex.config.js";

const app = defineApp();
app.use(apiKeys);

export default app;
