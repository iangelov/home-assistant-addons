import assert from "node:assert/strict";
import test from "node:test";
import { assertImageTagsAvailable } from "../scripts/verify-image-tags.mjs";

test("allows a release only when both architecture tags are absent", async () => {
  const requested = [];
  await assertImageTagsAvailable("2.0.0", async (url) => {
    requested.push(url);
    return new Response(null, { status: 404 });
  });

  assert.deepEqual(requested, [
    "https://ghcr.io/v2/iangelov/aarch64-app-tailscale/manifests/2.0.0",
    "https://ghcr.io/v2/iangelov/amd64-app-tailscale/manifests/2.0.0",
  ]);
});

test("refuses to overwrite an existing architecture tag", async () => {
  await assert.rejects(
    assertImageTagsAvailable("2.0.0", async () =>
      new Response(null, { status: 200 }),
    ),
    /overwrite existing/,
  );
});

test("authenticates the GHCR pull-token exchange when credentials are available", async () => {
  const calls = [];
  await assertImageTagsAvailable("2.0.0", async (url, options = {}) => {
    calls.push({ url, authorization: options.headers?.Authorization });
    if (url.startsWith("https://ghcr.io/token")) {
      return Response.json({ token: "registry-token" });
    }
    if (options.headers?.Authorization === "Bearer registry-token") {
      return new Response(null, { status: 404 });
    }
    return new Response(null, {
      status: 401,
      headers: {
        "www-authenticate":
          'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:iangelov/app:pull"',
      },
    });
  }, { username: "github-actions", token: "github-token" });

  assert.equal(
    calls.filter(({ authorization }) => authorization?.startsWith("Bearer ")).length,
    2,
  );
  assert.equal(
    calls.find(({ url }) => url.startsWith("https://ghcr.io/token")).authorization,
    `Basic ${Buffer.from("github-actions:github-token").toString("base64")}`,
  );
});

test("fails closed when GHCR cannot determine whether a tag exists", async () => {
  await assert.rejects(
    assertImageTagsAvailable("2.0.0", async () =>
      new Response(null, { status: 503 }),
    ),
    /Unexpected GHCR response: 503/,
  );
});
