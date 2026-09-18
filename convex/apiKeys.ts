import { ApiKeys } from "convex-api-keys";
import { components } from "./_generated/api.js";

export const apiKeys = new ApiKeys<{ namespace: string }>(components.apiKeys);
