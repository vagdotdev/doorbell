/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as admin from "../admin.js";
import type * as apiKeyMgmt from "../apiKeyMgmt.js";
import type * as apiKeys from "../apiKeys.js";
import type * as auth from "../auth.js";
import type * as calls from "../calls.js";
import type * as doorActions from "../doorActions.js";
import type * as doors from "../doors.js";
import type * as graph from "../graph.js";
import type * as http from "../http.js";
import type * as lib from "../lib.js";
import type * as notes from "../notes.js";
import type * as notify from "../notify.js";
import type * as profiles from "../profiles.js";
import type * as seed from "../seed.js";
import type * as status from "../status.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  admin: typeof admin;
  apiKeyMgmt: typeof apiKeyMgmt;
  apiKeys: typeof apiKeys;
  auth: typeof auth;
  calls: typeof calls;
  doorActions: typeof doorActions;
  doors: typeof doors;
  graph: typeof graph;
  http: typeof http;
  lib: typeof lib;
  notes: typeof notes;
  notify: typeof notify;
  profiles: typeof profiles;
  seed: typeof seed;
  status: typeof status;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {
  apiKeys: import("convex-api-keys/_generated/component.js").ComponentApi<"apiKeys">;
};
