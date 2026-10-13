# Http client (`Extensions/Http`)

## What it is

A small HTTP/1.1 client for fibers: typed JSON calls, a general `send`, a per-scheduler connection pool, timeouts and redirects. Plain `http://` only; `https://` returns an `.UNSUPPORTED` error that says TLS is not there yet. It shares `#import "Extensions/Http"` with the [server](http-server.md) and the [codec](http-codec.md) and is a jaic extension. Not available on wasm.

```jai
Io :: #import "Extensions/Io";

demo :: () {
    user, error := get_json(User, "http://localhost:8080/users/1");

    if error.kind != .NONE {
        print("%\n", error_text(error));      // "404 Not Found: No user with id 1"
        return;
    }

    created, error2 := post_json(User, "http://localhost:8080/users", New_User.{ name = "Ada" });
    free_json(*created);
    free_json(*user);
}

main :: () { Io.io_run(demo); }
```

Everything runs on the calling fiber, so the calls work inside `Io.io_run` (or a handler or a spawned fiber) and only that fiber waits. `examples/http/client.jai` is a complete program.

## How it works

**Calls.**

| Call | What it does |
| --- | --- |
| `get_json(T, url, headers)` | GET, decode the body as `T` |
| `post_json(T, url, value, headers)`, `put_json`, `patch_json` | encode `value` as JSON, send it, decode the answer as `T` |
| `post_json(url, value)` | the same without a response type (any 2xx is fine) |
| `delete_request(url)` | DELETE; the error only |
| `get_text(url)` | GET, the body as a string (free it with `free`) |
| `send(.{ method, url, headers, body, timeout, follow_redirects, max_redirects, max_response_size })` | everything else; returns a `Client_Response` for any status |

`send` returns a `Client_Response` (`status`, `reason`, `headers`, `body`) for every answer, so a 404 is a response, not an error; free it with `free_response`. The typed calls treat a status outside 2xx as an error: `.STATUS` with `status`, `title` and `detail` taken from an RFC 9457 problem body (the one the server sends) when there is one, and `body` holding the raw text. Release an error's strings with `free_error`. `header(*response, "Content-Type")` and `body_text(*response)` read a response.

**Errors.** `Http_Error.kind`: `.STATUS` (not 2xx), `.TRANSPORT` (connect, send or receive failed; `transport` is the `Io_Error`, such as `.CONNECTION_REFUSED`), `.TIMEOUT`, `.INVALID_URL`, `.UNSUPPORTED` (https), `.DECODE` (the body was not the JSON asked for; the detail has the path), `.REDIRECTS` (too many). `error_text(error)` makes one line from any of them.

**The pool.** Idle connections wait in a pool owned by the scheduler (it uses Io's scheduler-local storage, so each thread has its own and nothing is locked). A request takes the newest idle connection to the same host and port, or opens one; after a clean response with keep-alive framing the connection goes back. Connections older than `idle_timeout` are closed when the pool is next used, and at most `max_idle_per_host` are kept per host. A connection that dies while idle is only noticed on use: if it fails before any answer byte arrived and the method is idempotent (GET, HEAD, PUT, DELETE, OPTIONS), the request is retried once on a new connection; a POST is not repeated, you get the error. `idle_connection_count()`, `connections_opened()` and `close_idle_connections()` expose the pool for tests and shutdown. The pool is released when the scheduler ends.

**Redirects.** 301, 302, 303, 307 and 308 are followed up to `max_redirects` (10); `follow_redirects = false` returns the 3xx. 301 and 302 on a POST and 303 on anything but HEAD become a GET without a body; 307 and 308 repeat the method and body. A `Location` may be absolute or relative. `Authorization` and `Cookie` headers are dropped when the host or port changes.

**Timeouts.** `timeout` (30 s default, 0 for none) is the whole call, redirects included, and uses Io's deadlines, so the fiber stops waiting and the connection is closed (never pooled after a timeout, because a late answer would be read as the next one). DNS goes through Io's resolver, on helper threads, so a slow lookup does not block the scheduler.

**What it adds to a request.** `Host`, `User-Agent` (`client_settings.user_agent`, default `jaic-http`), `Content-Length`, and for the JSON calls `Content-Type: application/json` and `Accept: application/json`. A header you pass wins. Headers that set the framing yourself (`Content-Length`, `Transfer-Encoding`) or are malformed are refused before anything is sent. Responses are read through the codec: Content-Length, chunked (trailers dropped), read-until-close, `100 Continue` skipped, HEAD and 204/304 without bodies. A response body over `max_response_size` (64 MiB) is an error.

## How to change it

- HTTPS: `exchange` in `client.jai` is the one place that parses the URL and opens the stream; a TLS stream would replace `Io.connect` in `checkout` and the reads and writes in `converse`. The `.UNSUPPORTED` branch is in `exchange`.
- New pooled settings: add to `Client_Settings` and read them in `checkout`/`checkin`.
- Strings in a `Client_Response` are one allocation (`build_response`); keep it that way so `free_response` stays one `free`.
- Errors that hold strings (`owned`) must go through `free_error`; the server's `Http_Error`s do not own theirs.
- `client_settings` is a plain global read by every scheduler. Set it before starting threads.

## Configuration

`client_settings` (`Client_Settings`): `max_idle_per_host` (8), `idle_timeout` (30000 ms), `user_agent` (`"jaic-http"`). Per request: `timeout` (30000 ms), `follow_redirects` (true), `max_redirects` (10), `max_response_size` (64 MiB).

## Dependencies

[Io](io-engine.md) (TCP, `resolve`, deadlines, scheduler-local storage), [Json](json.md), the [codec](http-codec.md) and `url.jai` for URL parsing and percent encoding.

## Tests

`stdlib/Extensions/Http/tests/client.jai` runs the client against the in-process server and against scripted servers: pool reuse (five requests, one connection), the idle cap and eviction, concurrent requests, the typed calls and their errors, `send` with every part of a request, redirects of each status, credential stripping across hosts (`localhost` against `127.0.0.1`), redirect loops, timeouts, a refused connection, URL errors, https, a stale pooled connection (retried for GET, not for POST), and chunked, read-until-close, `100 Continue`, short and garbage responses.
