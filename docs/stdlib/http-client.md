# Http client (`Extensions/Http`)

## What it is

A small HTTP/1.1 client for fibers. A request returns a response that holds the status and headers; the body stays on the connection and is read from the response afterwards (`read_text`, `read_bytes`, `read_json`, `read_some`). There is a per-scheduler connection pool, timeouts and redirects. Plain `http://` only; `https://` returns an `.UNSUPPORTED` error that says TLS is not there yet. It shares `#import "Extensions/Http"` with the [server](http-server.md) and the [codec](http-codec.md) and is a jaic extension. Not available on wasm. A client can also be wired to an `App` in memory for [tests](http-testing.md).

```jai
main :: () {
    api: Client;
    api.base_url = "http://localhost:8080";

    response, error := get(*api, "/users/1");
    if error.kind != .NONE { print("%\n", error_text(error)); return; }     // could not get a response at all
    defer close(*response);

    if response.status != 200 { print("status %\n", response.status); return; }

    user, error2 := read_json(*response, User);                              // the body, once
    if error2.kind != .NONE { print("%\n", error_text(error2)); return; }
    free_json(*user);

    created := post(*api, "/users", New_User.{ name = "Ada" });               // a struct body is sent as JSON
    text, _ := read_text(*created);
    free(text.data);
    close(*created);
}
```

A `Client` holds what requests have in common (`base_url`, default `headers`, `timeout`, `max_redirects`, the `transport`). Every call takes the client it goes through. A zeroed `Client` works (no base URL, TCP, 30 seconds), so a one-off script writes `api: Client;` and passes `*api`; absolute URLs need no `base_url`. `examples/http/client.jai` is a complete program.

## How it works

**Making a request.** One shape: `send(client, .{ method, url, headers, body, timeout, max_redirects, max_response_size })`, or a verb that fills in the request: `get`, `head`, `options`, `delete` `(client, url, headers)` and `post`, `put`, `patch` `(client, url, [value], headers)`, where `value` is sent as JSON (`Content-Type: application/json`). Any other body is a `send` with `body` set; `bytes_of(text)` turns a string into one. The verbs share their names with the server's route registration; the first argument, a `*Client` or an `*App`, tells them apart. They all return `(Client_Response, Client_Error)` as soon as the status line and headers have arrived. A 404 is a response, not an error; the error is only about not getting one (URL, connection, timeout, a reply that is not HTTP, too many redirects). When there is no response the call still returns one, with `status` 0 and `reason` holding the error text, so code that keeps only the response can still name the request; it has no body.

**Reading the body.** The response has `status`, `reason`, `headers` (read one with `header(*response, "Content-Type")`) and the request it answers (`method`, `url`, the start of `request_body`). Its body is read through the response, and only once:

| Call | Returns |
| --- | --- |
| `read_text(*response)` | the whole body as a string (release with `free`) |
| `read_bytes(*response)` | the whole body as `[] u8` (release with `free(bytes.data)`) |
| `read_json(*response, T)` | the body decoded as a `T`; `free_json` releases it |
| `read_some(*response, buffer)` | the next part of the body in `buffer`, `(count, error)`; 0 when the body has ended, and on every call after that |
| `error_for_status(*response)` | `.NONE` for 2xx, else a `.STATUS` error with `status`, `title`, `detail` (from a problem+json body when there is one) and the `body`; reads the body |

The readers handle Content-Length, chunked (trailers dropped) and read-until-close framing. The whole-body readers refuse a body longer than the request's `max_response_size` (64 MiB) with `.TOO_LARGE`, early when Content-Length says so; `read_some` has no such limit, because the caller never holds the body: that is how a large download is streamed. Reading a body a second time (after any whole-body reader, or after `read_some` ended it) is a `.BODY` error, not an empty result, and so is reading a response after `close`. A read that fails (connection lost, timeout, malformed chunk) closes the connection and returns the error; reading again says the earlier read failed. `read_json` decodes whatever the status; check `response.status` first, or use `error_for_status`. A failed decode is `.DECODE` with the `Json_Error` in `error.json`.

**Connection lifetime (the one rule).** A response holds its connection until its body has been read to the end, or `close(*response)` is called, whichever is first.

- Reading to the end (any whole-body reader, or `read_some` returning data of a body of known length / 0) returns the connection to the pool at once, when the framing allows another request on it (not for read-until-close, `Connection: close`, or leftover bytes).
- `close(*response)` releases whatever is still held and frees the response (it leaves `response` empty). It is safe at any time and more than once, so `defer close(*response)` is always right. If the body was not read, `close` reads and drops a short rest (at most 64 KiB, for at most 500 ms) so the connection can be reused; a longer or unknown rest, an error or a timeout closes the connection instead. Do not use a response, or a copy of it, after closing it.
- Answers with no body (HEAD, 204, 304, `Content-Length: 0`) and small ones that arrived with their head (up to what one 16 KiB read holds, and within `max_response_size`) are taken into memory at once and the connection is released at once; they are still read with the same calls. So the common case, a dropped small response, costs nothing.
- A larger response that is dropped unread keeps its connection checked out, so it can never be mistaken for an idle one; it does not block the pool (the next request opens another connection). Such connections are listed per scheduler and bounded by `client_settings.max_open_responses` (64): past it the oldest is closed and reading it returns a `.BODY` error that names the setting. They are also closed when the scheduler ends. `open_response_count()` shows the number, for tests.
- Redirects close the intermediate answers the same way, so a chain reuses one connection and holds nothing but the final response.

Why this rule: it is the same lifetime as Go's `http.Response.Body` and reqwest's `Response` (the body is a stream owned by the response, `close`/drop frees it), without a finalizer, which Jai does not have. Reading to the end releases by itself so the common program needs no cleanup call for its connections, while the stored headers still need `close` to free their memory.

**Calls outside a scheduler.** Inside `Io.io_run` (or a handler or a spawned fiber) a call runs on the calling fiber and only that fiber waits; the body is read later, on demand, by whichever fiber calls `read_*`. Outside a scheduler `send` runs one for that call, and the connection cannot outlive it, so the whole body is read inside it (up to `max_response_size`; a failure is returned by the first `read_*`). Streaming with `read_some` therefore wants a scheduler. Connections are not kept between such calls.

**Errors.** `Client_Error` (separate from the server's status-based `Http_Error`): `kind` is `.TRANSPORT` (connect, send or receive failed; `transport` is the `Io_Error`, such as `.CONNECTION_REFUSED`), `.TIMEOUT`, `.INVALID_URL`, `.UNSUPPORTED` (https), `.REDIRECTS` (too many), `.DECODE` (the body was not the JSON asked for; `json` says where and why), `.BODY` (already read, closed or evicted), `.TOO_LARGE`, `.STATUS` (from `error_for_status`). `error_text(error)` makes one line from any of them and `free_error(*error)` releases its strings.

**The pool.** Idle connections wait in a pool owned by the scheduler (it uses Io's scheduler-local storage, so each thread has its own and nothing is locked). A request takes the newest idle connection to the same host and port, or opens one. Connections older than `idle_timeout` are closed when the pool is next used, and at most `max_idle_per_host` are kept per host. A connection that dies while idle is only noticed on use: if it fails before any answer byte arrived and the method is idempotent (GET, HEAD, PUT, DELETE, OPTIONS), the request is retried once on a new connection; a POST is not repeated, you get the error. `idle_connection_count()`, `connections_opened()`, `open_response_count()` and `close_idle_connections()` expose the pool for tests and shutdown. The pool is released when the scheduler ends.

**Redirects.** 301, 302, 303, 307 and 308 are followed up to `max_redirects` (the request's, else the client's, 10 by default); 0 returns the 3xx. 301 and 302 on a POST and 303 on anything but HEAD become a GET without a body; 307 and 308 repeat the method and body. A `Location` may be absolute or relative. `Authorization` and `Cookie` headers are dropped when the host or port changes.

**Transport.** `client.transport` decides how a connection is made: `open(data, url)` returns a `Stream` (a TCP stream or an in-memory pipe end) and `base(data)` gives the URL a relative one is joined to. The default, with both null, connects over TCP and needs a `base_url` for relative URLs. [`test_client`](http-testing.md) sets a transport that connects to an `App` in memory. Pooled connections are only reused by the transport that opened them.

**Timeouts.** `timeout` (the request's, else the client's 30 s, 0 for none) covers the whole exchange: the request, the redirects and reading the body, however many `read_*` calls that takes. It uses Io's deadlines, so the fiber stops waiting and the connection is closed (never pooled after a timeout, because a late answer would be read as the next one). For a body that is streamed for longer than that, set `timeout = 0` on the request. DNS goes through Io's resolver, on helper threads, so a slow lookup does not block the scheduler.

**What it adds to a request.** `Host`, `User-Agent` (`client_settings.user_agent`, default `jaic-http`), `Content-Length`, and for `post`/`put`/`patch` with a value `Content-Type: application/json`. It sends no `Accept`; pass one in `headers` if the server needs it. A header you pass wins. Headers that set the framing yourself (`Content-Length`, `Transfer-Encoding`) or are malformed are refused before anything is sent. Responses are read through the codec: Content-Length, chunked, read-until-close, `100 Continue` skipped, HEAD and 204/304 without bodies.

## How to change it

- HTTPS: `exchange` in `client.jai` is the one place that parses the URL and opens the stream; a TLS transport would be a `Transport.open` that returns a new `Stream` kind (`stream.jai`), or `checkout` would pick one by scheme. The `.UNSUPPORTED` branch is in `exchange`.
- The body side is `Body_Source` in `client.jai`: the connection, the parser positioned at the start of the body, the bytes read past the head, and where the reader is. It touches the connection only through `stream_read`/`stream_close` and `read_within`, so moving to a shared reader/writer abstraction means replacing those calls. `fill_pending` is the one place that reads and parses; every reader (`read_all`, `read_some`, the drain in `release_source`) goes through it.
- A new reader (a file download, a line reader): write it over `fill_pending` (it leaves body bytes in `source.pending`), call `readable(response)` first and set `source.done` at the end. Keep `source.reading` set while a call can block, so eviction skips the body.
- A response is shared by value: `Client_Response` copies point at one `Body_Source`. The expectations in `expect.jai` rely on that and on `peek_body`, which buffers the body without using it up.
- New pooled settings: add to `Client_Settings` and read them in `checkout`/`checkin`.
- Strings in a `Client_Response` are one allocation (`build_response`); `close` frees it with the `Body_Source`.
- Errors that hold strings (`owned`) must go through `free_error`.
- Request bodies are not streamed: `Client_Request.body` is a buffer. A streaming upload would add a body callback to the request and write it in `converse`.
- `client_settings` is a plain global read by every scheduler. Set it before starting threads.

## Configuration

`client_settings` (`Client_Settings`): `max_idle_per_host` (8), `idle_timeout` (30000 ms), `user_agent` (`"jaic-http"`), `max_open_responses` (64). `Client`: `base_url`, `headers` (`set_header(client, name, value)`, `remove_header`), `timeout` (30000 ms), `max_redirects` (10), `transport`. Per request, where -1 means the client's: `timeout`, `max_redirects`; and `max_response_size` (64 MiB, whole-body readers only). Compile-time constants in `client.jai`: `DRAIN_LIMIT` (64 KiB) and `DRAIN_TIMEOUT` (500 ms) for `close`.

## Dependencies

[Io](io-engine.md) (TCP, `resolve`, deadlines, scheduler-local storage, pipes), [Json](json.md), the [codec](http-codec.md) and `url.jai` for URL parsing and percent encoding.

## Tests

`stdlib/Extensions/Http/tests/client.jai` runs the client against the in-process server and against hand-made servers: each reader (`read_text`, `read_bytes`, `read_json`, `read_some` in small pieces) over Content-Length, chunked and read-until-close bodies, the read-once errors, `close` before, after and twice, pool reuse per framing, `error_for_status`, a body larger than `max_response_size` (refused by `read_bytes`, streamed by `read_some`), an unread response followed by another request on the same client, `close` of short and long unread bodies, the open-response cap, redirects of each status (and that the chain holds nothing), credential stripping across hosts, redirect loops, timeouts, a refused connection, URL errors, https, a stale pooled connection (retried for GET, not for POST), and short, garbage and ambiguous responses.
