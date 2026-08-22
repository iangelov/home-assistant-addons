import { pathToFileURL } from "node:url";

const architectures = ["aarch64", "amd64"];
const manifestAccept = [
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
].join(", ");

function parseChallenge(challenge) {
  const values = {};
  for (const match of challenge.matchAll(/(\w+)="([^"]+)"/g)) {
    values[match[1]] = match[2];
  }
  if (!values.realm) {
    throw new Error("GHCR authentication challenge did not include a realm");
  }
  return values;
}

async function fetchManifest(url, request, credentials) {
  const headers = { Accept: manifestAccept };
  let response = await request(url, { headers });
  if (response.status !== 401) {
    return response;
  }

  const challenge = parseChallenge(response.headers.get("www-authenticate") ?? "");
  const tokenUrl = new URL(challenge.realm);
  if (challenge.service) tokenUrl.searchParams.set("service", challenge.service);
  if (challenge.scope) tokenUrl.searchParams.set("scope", challenge.scope);

  const tokenHeaders = credentials?.username && credentials?.token
    ? {
        Authorization: `Basic ${Buffer.from(
          `${credentials.username}:${credentials.token}`,
        ).toString("base64")}`,
      }
    : undefined;
  const tokenResponse = await request(tokenUrl.toString(), { headers: tokenHeaders });
  if (!tokenResponse.ok) {
    throw new Error(`GHCR token request failed: ${tokenResponse.status}`);
  }
  const tokenPayload = await tokenResponse.json();
  const token = tokenPayload.token ?? tokenPayload.access_token;
  if (!token) {
    throw new Error("GHCR token response did not include a token");
  }

  response = await request(url, {
    headers: { ...headers, Authorization: `Bearer ${token}` },
  });
  return response;
}

export async function assertImageTagsAvailable(
  version,
  request = fetch,
  credentials = {
    username: process.env.GHCR_USERNAME,
    token: process.env.GHCR_TOKEN,
  },
) {
  for (const arch of architectures) {
    const image = `iangelov/${arch}-app-tailscale`;
    const url = `https://ghcr.io/v2/${image}/manifests/${version}`;
    const response = await fetchManifest(url, request, credentials);
    if (response.ok) {
      throw new Error(`Refusing to overwrite existing image tag: ${image}:${version}`);
    }
    if (response.status !== 404) {
      throw new Error(`Unexpected GHCR response: ${response.status}`);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await assertImageTagsAvailable(process.argv[2]);
}
