"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");

function startServer(handler) {
  const server = http.createServer(handler);
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server);
    });
  });
}

function stopServer(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function serverUrl(server, path) {
  const {port} = server.address();
  return `http://127.0.0.1:${port}${path}`;
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

async function testCrossOriginCredentialsAreStripped() {
  let targetHeaders;
  const target = await startServer((request, response) => {
    targetHeaders = request.headers;
    response.end("ok");
  });
  const source = await startServer((request, response) => {
    response.writeHead(302, {location: serverUrl(target, "/target")});
    response.end();
  });

  try {
    const response = await globalThis.fetch(serverUrl(source, "/start"), {
      headers: {
        Authorization: "Bearer review-secret",
        Cookie: "session=review-secret",
        Cookie2: "legacy=review-secret",
        Host: "stale-origin.example",
        "Proxy-Authorization": "Basic review-secret",
      },
    });
    assert.equal(await response.text(), "ok");
    assert.equal(targetHeaders.authorization, undefined);
    assert.equal(targetHeaders.cookie, undefined);
    assert.equal(targetHeaders.cookie2, undefined);
    assert.equal(targetHeaders.host, new URL(serverUrl(target, "/")).host);
    assert.equal(targetHeaders["proxy-authorization"], undefined);
  } finally {
    await stopServer(source);
    await stopServer(target);
  }
}

async function testSameOriginCredentialsAreRetained() {
  let targetHeaders;
  const server = await startServer((request, response) => {
    if (request.url === "/start") {
      response.writeHead(302, {location: "/target"});
      response.end();
      return;
    }

    targetHeaders = request.headers;
    response.end("ok");
  });

  try {
    const response = await globalThis.fetch(serverUrl(server, "/start"), {
      headers: {Authorization: "Bearer same-origin-secret"},
    });
    assert.equal(await response.text(), "ok");
    assert.equal(targetHeaders.authorization, "Bearer same-origin-secret");
  } finally {
    await stopServer(server);
  }
}

async function testPostRedirectBecomesGet(statusCode) {
  let targetRequest;
  const server = await startServer(async (request, response) => {
    if (request.url === "/start") {
      await readBody(request);
      response.writeHead(statusCode, {location: "/target"});
      response.end();
      return;
    }

    targetRequest = {
      body: await readBody(request),
      headers: request.headers,
      method: request.method,
    };
    response.end("ok");
  });

  try {
    const response = await globalThis.fetch(serverUrl(server, "/start"), {
      body: "payload",
      headers: {"Content-Type": "text/plain"},
      method: "POST",
    });
    assert.equal(await response.text(), "ok");
    assert.equal(targetRequest.method, "GET");
    assert.equal(targetRequest.body, "");
    assert.equal(targetRequest.headers["content-type"], undefined);
    assert.equal(targetRequest.headers["content-length"], undefined);
  } finally {
    await stopServer(server);
  }
}

async function testPostRedirectIsPreserved(statusCode) {
  let targetRequest;
  const server = await startServer(async (request, response) => {
    if (request.url === "/start") {
      await readBody(request);
      response.writeHead(statusCode, {location: "/target"});
      response.end();
      return;
    }

    targetRequest = {
      body: await readBody(request),
      headers: request.headers,
      method: request.method,
    };
    response.end("ok");
  });

  try {
    const response = await globalThis.fetch(serverUrl(server, "/start"), {
      body: "payload",
      headers: {"Content-Type": "text/plain"},
      method: "POST",
    });
    assert.equal(await response.text(), "ok");
    assert.equal(targetRequest.method, "POST");
    assert.equal(targetRequest.body, "payload");
    assert.equal(targetRequest.headers["content-type"], "text/plain");
  } finally {
    await stopServer(server);
  }
}

async function main() {
  assert.equal(typeof globalThis.WebAssembly, "undefined");
  assert.equal(typeof globalThis.fetch, "function");

  await testCrossOriginCredentialsAreStripped();
  await testSameOriginCredentialsAreRetained();
  await testPostRedirectBecomesGet(301);
  await testPostRedirectBecomesGet(302);
  await testPostRedirectBecomesGet(303);
  await testPostRedirectIsPreserved(307);
  await testPostRedirectIsPreserved(308);

  console.log("node fetch jitless polyfill regression tests passed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
