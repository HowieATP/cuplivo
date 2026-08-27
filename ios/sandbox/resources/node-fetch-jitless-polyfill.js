"use strict";
// Adapted from OpenMinis/ish-arm64 RootfsPatch (GPL-3.0-or-later; see
// ios/sandbox/NOTICE). This is intentionally small: iSH cannot expose
// WebAssembly while Node runs with --jitless, so Node's undici fetch crashes
// while lazily loading its llhttp WASM parser.

if (typeof globalThis.WebAssembly === "undefined") {
  let implementation = null;

  function lazyImplementation() {
    if (implementation) return implementation;

    const http = require("http");
    const https = require("https");
    const {URL} = require("url");
    const zlib = require("zlib");

    class Response {
      constructor(body, status, statusText, headers, url) {
        this._body = body;
        this.status = status;
        this.statusText = statusText;
        this.ok = status >= 200 && status < 300;
        this.url = url;
        this._headers = headers;
        this.headers = {
          get: (key) => headers[key.toLowerCase()] || null,
          has: (key) => key.toLowerCase() in headers,
          entries: () => Object.entries(headers),
          forEach: (callback) =>
            Object.entries(headers).forEach(([key, value]) => callback(value, key)),
        };
      }

      async text() {
        return this._body.toString("utf8");
      }

      async json() {
        return JSON.parse(this._body.toString("utf8"));
      }

      async arrayBuffer() {
        return this._body.buffer.slice(
          this._body.byteOffset,
          this._body.byteOffset + this._body.byteLength,
        );
      }

      clone() {
        return new Response(
          this._body,
          this.status,
          this.statusText,
          this._headers,
          this.url,
        );
      }
    }

    implementation = function fetch(input, init) {
      return new Promise((resolve, reject) => {
        const url =
          typeof input === "string" ? new URL(input) : new URL(input.url || input);
        const options = Object.assign({}, init || {});
        const protocol = url.protocol === "https:" ? https : http;
        const requestOptions = {
          hostname: url.hostname,
          port: url.port || (url.protocol === "https:" ? 443 : 80),
          path: url.pathname + url.search,
          method: (options.method || "GET").toUpperCase(),
          headers: Object.assign({}, options.headers || {}),
        };
        const request = protocol.request(requestOptions, (response) => {
          if (
            response.statusCode >= 301 &&
            response.statusCode <= 308 &&
            response.headers.location
          ) {
            implementation(new URL(response.headers.location, url).href, init).then(
              resolve,
              reject,
            );
            return;
          }

          const chunks = [];
          let stream = response;
          const encoding = response.headers["content-encoding"];
          if (encoding === "gzip") stream = response.pipe(zlib.createGunzip());
          else if (encoding === "deflate") stream = response.pipe(zlib.createInflate());
          else if (encoding === "br") stream = response.pipe(zlib.createBrotliDecompress());
          stream.on("data", (chunk) => chunks.push(chunk));
          stream.on("end", () => {
            resolve(
              new Response(
                Buffer.concat(chunks),
                response.statusCode,
                response.statusMessage,
                response.headers,
                url.href,
              ),
            );
          });
          stream.on("error", reject);
        });
        request.on("error", reject);
        if (options.body) {
          request.write(
            typeof options.body === "string" ? options.body : JSON.stringify(options.body),
          );
        }
        request.end();
      });
    };
    return implementation;
  }

  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    get() {
      const fetch = lazyImplementation();
      Object.defineProperty(globalThis, "fetch", {
        value: fetch,
        writable: true,
        configurable: true,
      });
      return fetch;
    },
  });
}
