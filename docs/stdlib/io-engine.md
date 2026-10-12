# Io: the completion engine, TCP and files (`Extensions/Io`)

## What it is

The IO half of `Extensions/Io`: blocking-style `tcp_listen`, `accept`, `connect`, `read`, `write`, `close`, file calls, `resolve`, deadlines and cancellation for [fibers](io-fibers.md), on top of an internal completion engine with five backends (io_uring and epoll on Linux, kqueue on macOS, completion ports with or without an IoRing for files on Windows) and a worker thread pool for files on epoll and kqueue. Milestones 3 and 7 of [the async IO plan](../plans/async-io.md).

```jai
Io :: #import "Extensions/Io";

handle :: (conn: Io.Tcp_Stream) {
    defer Io.close(conn);
    buffer: [4096] u8;

    while true {
        count, error := Io.read(conn, buffer);
        if error != .NONE || count == 0 return;      // 0 is the peer closing its end

        Io.write(conn, .{ count, buffer.data });      // sends all of it
    }
}

main :: () {
    Io.io_run(() {
        listener, error := Io.tcp_listen(":8080");
        while true {
            conn, error := Io.accept(listener);
            if error != .NONE break;
            Io.spawn(handle, conn);
        }
    });
}
```

## API

Everything that waits must run on a fiber inside `io_run`, blocks only that fiber, and returns its result plus an `Io_Error`.

| Area | Procedures |
|---|---|
| Addresses | `Address`, `address_v4`, `parse_address("1.2.3.4:80" / ":80" / "[::1]:80")`, `address_to_string`, `resolve(host, port)` |
| Listening | `tcp_listen(text or Address, backlog, reuse_port)`, `accept`, `local_address` |
| Streams | `connect(Address / host, port / "host:port")`, `read` (0 is end of stream), `read_full` (`.END_OF_FILE`), `write` (all of it), `write_some`, `shutdown_write`, `peer_address`, `close` |
| Files | `open_file(path, File_Mode)` with `.READ .WRITE .APPEND .READ_WRITE`, `read` / `write` (advance `position`), `read_at` / `write_at`, `file_size`, `close`, and whole-file `read_file` / `write_file` |
| Time | `sleep`, `with_deadline(ms, #code { ... })`, `set_deadline` / `restore_deadline`, `cancel(fiber)`, `is_canceled` |
| Threads | `io_run_threads(count, proc [, data])` (one scheduler per thread, no stealing), `processor_count` |
| Introspection | `backend()` (`.IO_URING .EPOLL .KQUEUE .IOCP .IORING .NONE`), `backend_name()`, `backend_reason()`, `capabilities()`, `last_platform_code()` |

- **Errors.** `Io_Error` is `NONE`, `CANCELED`, `CLOSED`, `TIMED_OUT`, `END_OF_FILE`, `CONNECTION_RESET`, `CONNECTION_REFUSED`, `CONNECTION_ABORTED`, `BROKEN_PIPE`, `NOT_CONNECTED`, `ADDRESS_IN_USE`, `ADDRESS_UNAVAILABLE`, `NETWORK_UNREACHABLE`, `HOST_UNREACHABLE`, `NOT_FOUND`, `ALREADY_EXISTS`, `PERMISSION_DENIED`, `INVALID`, `NO_SPACE`, `TOO_MANY_OPEN_FILES`, `IS_A_DIRECTORY`, `UNSUPPORTED`, `RESOLVE_FAILED` and `OTHER`. The enum only grows. `last_platform_code()` is the system's error number behind the running fiber's last failed call (the errno, or `getaddrinfo`'s code for `RESOLVE_FAILED`), so `OTHER` stays diagnosable and new kernel errors never break callers.
- **`close`** works for a canceled fiber (so `defer close(conn)` always cleans up) and wakes every fiber waiting on that handle with `.CLOSED`.
- **Cancellation.** `cancel(fiber)` ends the fiber's current IO with `.CANCELED`, and all later IO of that fiber fails the same way (it is sticky, as for `sleep`). The fiber stays blocked until the engine reports the canceled operation, so a buffer is never written after the call returns.
- **Deadlines.** `with_deadline(ms, #code { ... })` limits every IO call and `sleep` in the block; the earlier deadline wins when they nest; an expired deadline fails the call before it starts, even when data is waiting. A timed out call affects only itself. jaic does not accept a trailing block after the call, so the block goes in as a `#code` argument. Channel and lock operations ignore deadlines.
- **`resolve`.** Address literals never leave the process. Names go to `getaddrinfo` on a couple of helper threads that the scheduler starts at the first lookup and joins when `io_run` ends; only the asking fiber waits. IPv4 is preferred when a name has both. A cancel or a deadline stops the wait at once; the lookup itself cannot be interrupted, so its answer is dropped when it arrives.
- **Files.** On io_uring the kernel does reads and writes, on Windows completion ports or an IoRing do, and only the fiber waits. epoll and kqueue cannot report a regular file as not ready, so those backends send reads and writes longer than 32 KiB to a [thread pool](#file-thread-pool) and run shorter ones at once on the scheduler's thread. `.APPEND` always writes at the end, whatever the offset, because systems disagree on `pwrite` with `O_APPEND`. `open_file` is always a plain call. Paths are UTF-8 (converted to UTF-16 on Windows).
- **Several schedulers.** `io_run_threads(4, proc)` starts four threads, each with its own scheduler and engine, and runs `proc` on a fiber of each. Listen with `reuse_port = true` in each and the kernel spreads connections between the listeners (Linux balances by hash; macOS does not balance, but delivers every connection to some listener). Fibers never move between threads, and a `Channel` or `Wait_Group` must stay on one thread.

## How it works

Files: `platform.jai` (libc calls and per-OS numbers), `engine.jai` (types, backend choice, `await_op`), `engine_poll.jai` (epoll and kqueue), `engine_uring.jai`, `engine_iocp.jai` and `engine_ioring.jai` (Windows), `win32.jai` (Win32 declarations and the Windows `sys_*` calls), `files_pool.jai` (file thread pool), `net.jai`, `files.jai`, `resolver.jai` (helper threads), `runtime.jai` (deadlines, threads, introspection).

**The engine.** A fiber describes an operation (`Op`: kind, `Handle`, buffer, offset, address), calls `engine_submit` and parks. The engine finishes it now (`engine_submit` returns true, nothing parks) or later (`finish_op` records result, flags, `more` and buffer id, and wakes the fiber). Kinds: accept, connect, recv, send, read and write (with an offset for files), close. A `Handle` is an opaque descriptor plus a kind tag (`SOCKET`, `FILE`, `STREAM`), so a SOCKET or HANDLE fits later. Results are a byte count or the negative platform errno; `error_from_code` makes them portable. The rules of the plan hold: buffers and addresses belong to an operation until its completion arrives, even after a cancel; a missing feature is a fallback, never an error.

**Scheduler hook.** `wait_step` (fibers have nothing ready) computes the time to the next timer and calls `engine_wait(timeout)`, which submits what is queued, waits for completions up to the timeout and wakes fibers; it replaced the old OS sleep. Every 64 switches a busy scheduler also polls the engine without waiting. The timer heap serves `sleep` and deadlines: a deadline is a timer on a fiber blocked in an operation, and when it fires the scheduler cancels the operation with cause `TIMED_OUT`. (There is no separate engine "timeout" operation: the wait timeout carries io_uring's `EXT_ARG`, `epoll_wait`'s milliseconds or kevent's timespec.) Nothing ready, no timers and nothing in flight is the old deadlock report.

**io_uring** (Linux with the 6.1 floor, on [Extensions/Io_Uring](io-uring.md)). One ring per scheduler thread, 512 entries, created on the scheduler's thread with `SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN`, retrying with `COOP_TASKRUN` and then with no flags when the kernel answers `EINVAL`. A denial (`ENOSYS`, `EPERM`, `EACCES`, `ENOMEM`: old kernels, seccomp in containers, `kernel.io_uring_disabled`) ends the ladder, and the engine uses epoll and records why in `backend_reason()`. After setup it probes the opcodes it uses plus `SENDMSG_ZC` (the 6.1 marker) and needs `IORING_FEAT_EXT_ARG`; otherwise it falls back too. Submission only fills an entry (`user_data` is the `Op` address); entries reach the kernel in batches when the scheduler waits, polls, or the queue is full. The wait is one `io_uring_enter` with `GETEVENTS` and a timeout; completions are reaped straight from the ring. Sockets stay blocking (io_uring waits for them itself) and `accept` takes `SOCK_CLOEXEC` only. Cancel is `ASYNC_CANCEL` by `user_data`; close is a hard-linked `ASYNC_CANCEL` by descriptor followed by `CLOSE`, so fibers waiting on that descriptor wake (a closed fd alone would not end an in-flight receive). Cancel results (`-ECANCELED`) are mapped to `.CANCELED`, `.TIMED_OUT` or `.CLOSED` by who asked.

**epoll and kqueue** share `engine_poll.jai`. A readiness API does not do IO, so an operation is tried at once without blocking (accept, `connect` returning `EINPROGRESS`, recv, send, pread); on `EAGAIN` it waits in a queue on its descriptor (one list of readers and one of writers, in `Fd_State`) and the descriptor is armed for one notification: kqueue `EV_ADD | EV_ONESHOT` per direction, epoll `EPOLLONESHOT` for the whole descriptor (re-armed with the mask of the remaining waiters). When it fires, the queue is served in order until an operation would block again. Two fibers on one descriptor therefore cannot lose each other's wake-up. kqueue changes are batched into the wait call. `connect` waits for writability and reads `SO_ERROR`. Closing a descriptor fails everything waiting on it first. Sockets are non-blocking, close-on-exec and `SO_NOSIGPIPE` (macOS) or `MSG_NOSIGNAL` (Linux).

**Resolver and wake-ups.** Helper threads cannot call into a backend, so they hand finished jobs to the scheduler through a pipe: the scheduler keeps an ordinary internal `READ` on the pipe armed while lookups are out (so every backend wakes the same way), a helper appends its job to a mutex-protected list and writes a byte, and the completion wakes the fibers. `engine_stop` waits for outstanding lookups first, so a late answer never reaches freed memory.

**Windows** (`engine_iocp.jai`, `engine_ioring.jai`, `win32.jai`; x64 and arm64). One completion port per scheduler thread. Every operation is an overlapped call carrying its `Op`: `Op` starts with the `OVERLAPPED`, so the pointer a packet brings back is the operation. Calls never use "skip the packet on success", so a call that returns success or `ERROR_IO_PENDING` always finishes with a packet in `iocp_wait`, and one that fails at once finishes in `iocp_submit`.

| Operation | Call |
|---|---|
| accept | `AcceptEx` on a socket made ahead of time (so `getsockname`/`getpeername` work after `SO_UPDATE_ACCEPT_CONTEXT`) |
| connect | `ConnectEx` after a bind to the wildcard address, then `SO_UPDATE_CONNECT_CONTEXT` |
| recv, send | `WSARecv`, `WSASend` (at most 64 KiB per send, so a canceled `write` can report what went out) |
| read, write | `ReadFile`/`WriteFile` with the offset in the OVERLAPPED (end of file offset for appends), or the IoRing |
| cancel | `CancelIoEx`; the operation still completes, as `ERROR_OPERATION_ABORTED` |
| close | `CancelIoEx` on the whole handle, then `closesocket`/`CloseHandle`; fibers waiting on it wake with `.CLOSED` |

`AcceptEx` and `ConnectEx` are fetched with `WSAIoctl` at startup. The wait is `GetQueuedCompletionStatusEx` with the scheduler's timeout in milliseconds, rounded up. A packet's result is the NTSTATUS in `OVERLAPPED.Internal`, taken from the dequeued entry (the handle may be closed by then) and turned into a Win32 error with `RtlNtStatusToDosError`; on Windows the `E_*` numbers are the Win32 and Winsock numbers themselves, so `last_platform_code()` is the real error, and `windows_error` maps the extra ones (`ERROR_NETNAME_DELETED` is a reset, `ERROR_CONNECTION_REFUSED` a refusal, ...). Gotchas: `bytes > 0` with an abort status counts as a short success; `ERROR_HANDLE_EOF` is a read of 0; Windows has no `SO_REUSEPORT`, so a plain listener uses `SO_EXCLUSIVEADDRUSE` (the opposite of `SO_REUSEADDR` there, which would let another program take the port) and `reuse_port = true` uses `SO_REUSEADDR`, which shares the port but hands connections to one listener rather than balancing them; timeouts are as fine as the system timer (about 15 ms unless something raised its resolution); a connect to a closed local port reports the refusal after a second or two.

Name lookups (`resolve`) use `getaddrinfo` on the same helper threads; a helper wakes the scheduler by posting a packet with no OVERLAPPED and `KEY_WAKE` to the port, instead of writing a pipe.

**IoRing** (`.IORING`, Windows 11 22H2+; `ioringapi.h`). The API is loaded from KernelBase.dll with `GetProcAddress`, so older Windows still runs. A one-time probe checks that all the functions exist, that `QueryIoRingCapabilities` offers version 2 (the one with writes), and then runs a self test: it reads two bytes of the program's own executable through a throwaway ring, waits for the completion event and checks for "MZ". Anything that fails sends files to the completion port and records the step in `backend_reason()`. With a ring: reads and writes become submission entries (`BuildIoRingReadFile`/`BuildIoRingWriteFile`, the `Op` as user data) that `SubmitIoRing` hands over in a batch whenever the scheduler waits; completions are popped in user space. The ring's completion event is waited on by a small helper thread (started at the first file operation) that posts `KEY_RING` to the port; while operations are in the ring the scheduler never sleeps longer than 50 ms, so a lost event delays instead of hangs. The ring holds 128 operations and more wait in a list. Operations in a ring cannot be canceled (a file read ends in disk time), and `close` of a file waits for the ring to go idle. Files are not attached to the completion port in this mode. The by-value `IORING_HANDLE_REF`/`IORING_BUFFER_REF` structs rely on jaic's Win64 and Windows arm64 struct passing.

`JAI_IO_BACKEND=iocp` keeps files on the completion port; `ioring` asks for the ring but falls back (with a reason) when it is missing.

### File thread pool

`files_pool.jai`, for epoll and kqueue. One pool per process, shared by all schedulers: started when the first scheduler needs it, ended when the last one is done, so `io_run` can run any number of times and nothing outlives the program. The workers make plain `pread`/`pwrite` calls from one queue. Each scheduler has a `Pool_Link`: a mutex-protected list of finished operations, and the wake-up. A worker appends its operation and wakes the scheduler while holding the mutex; the scheduler collects under it, and takes it once more before freeing the link, so no worker touches freed memory. The wake-up is an `eventfd` on epoll, read by an internal READ that is armed while operations are out (the same device the resolver pipe uses, with `Internal_Tag.POOL_WAKE`), and an `EVFILT_USER` event (`EV_CLEAR` plus `NOTE_TRIGGER`) on kqueue. A pool operation cannot be interrupted: cancel and deadlines wait for it (`Op.uncancelable`), and `close` of a file waits until every operation out has come back.

*Inline or pool.* A hand-off to a worker and back costs about 3 to 5 microseconds when the data is in the page cache; a short read costs less than that, but a read that has to wait for the disk stalls every fiber of the thread. Page-cache reads on an Apple M-series Mac (kqueue, native `-O2`, `stdlib/Extensions/Io/bench/files.jai`, best of three, one scheduler thread):

| Read size | inline, 1 fiber | pool, 1 fiber | inline, 8 fibers | pool, 8 fibers |
|---|---|---|---|---|
| 512 B | 0.52 us | 4.9 us | 0.53 us | 3.1 us |
| 4 KiB | 0.78 us | 5.0 us | 0.78 us | 2.9 us |
| 16 KiB | 1.2 us | 5.6 us | 1.3 us | 3.3 us |
| 64 KiB | 3.6 us | 7.3 us | 4.0 us | 5.0 us |
| 256 KiB | 15.4 us | 18.6 us | 14.3 us | 9.4 us |
| 1 MiB | 57 us | 58 us | 56 us | 37 us |

Inline wins below about 128 KiB for a single fiber, and the pool wins from 256 KiB up once several reads overlap (27 GB/s against 18 GB/s at 1 MiB) and whenever the disk is cold, which these numbers do not show. The default threshold is 32 KiB: smaller operations (headers, small config and log files) stay inline at no cost, and anything a static file server reads in blocks goes to the pool. `JAI_IO_FILE_INLINE=0` sends everything to the pool, a huge value keeps everything inline.

## How to change it

- **A new operation:** add an `Op_Kind`, a case in `poll_attempt` (poll backends) and in `uring_submit`, then a public procedure in `net.jai` or `files.jai` that fills an `Op` and calls `await_op`.
- **File pool:** the threshold, thread count and wake-up live in `files_pool.jai`; `poll_submit` decides inline or pool per operation.
- **A new backend:** a `Backend` member, `*_start`, `engine_submit`/`engine_cancel`/`engine_wait` cases, and `finish_op` for each completion. Keep the rules above: nothing is abandoned while the kernel may still touch its buffer.
- **A new io_uring feature** (multishot accept, provided buffers, zero-copy send): extend `uring_submit` and `uring_reap` (`more` and `buffer_id` already travel with the completion), probe it in `uring_start`, and set a `Capabilities` flag; callers never see it.
- **Errors:** add the `E_*` number for both OSes in `platform.jai` and a case in `error_from_code`; append the `Io_Error` member at the end of the enum.
- Gotchas: `open` and `fcntl` are variadic in C and must be declared `args: ..Any` (Apple arm64 passes variadic arguments on the stack, so a fixed declaration silently passes garbage); `epoll_event` is packed on x86-64 only; `accept`ed sockets on macOS need `fcntl` to become non-blocking; the Fd table is indexed by descriptor, so any raw `close` of a descriptor that went through a poll backend must go through `discard_handle` or the stale state will hang the next descriptor with that number.

## Configuration

| Setting | Effect |
|---|---|
| `JAI_IO_BACKEND=io_uring \| epoll \| kqueue \| iocp \| ioring` | Ask for a backend before `io_run`. A backend the system cannot offer is replaced by the default one (`backend_reason()` says so); an unknown value is ignored |
| `JAI_IO_FILE_THREADS` | epoll, kqueue: worker threads of the file pool, started at the first use (default 4, at most 16; `0` runs every file operation inline), read when an `io_run` starts |
| `JAI_IO_FILE_INLINE` | epoll, kqueue: file reads and writes up to this many bytes run inline on the scheduler's thread (default 32768; `0` sends all to the pool) |
| Module parameters | `STACK_BYTES`, `POOL_LIMIT`, `TEMPORARY_BYTES` ([fibers](io-fibers.md)) |
| `RING_ENTRIES` (512), `RESOLVER_THREADS` (2), `MAX_POLLED_FDS`, `RING_SUBMISSION` (128), `SEND_CHUNK` (64 KiB) | constants in `engine_uring.jai`, `resolver.jai`, `engine_poll.jai`, `engine_ioring.jai`, `win32.jai` |

## Dependencies

libc (`socket`, `kevent`/`epoll`, `eventfd`, `pread`, `getaddrinfo`, ...), [`Extensions/Io_Uring`](io-uring.md) on Linux, kernel32, ws2_32 and KernelBase (loaded at run time) on Windows, [`Atomics`](atomics.md), and `Thread` for the resolver, the file pool and `io_run_threads`. The Win32 declarations are private to `win32.jai`. Not available on wasm.

## Tests and numbers

`stdlib/Extensions/Io/tests/` (run by the [stdlib runtime tests](../tools/stdlib-runtime-tests.md) in `interp` and `native` on Linux, macOS and Windows; skipped on wasm): `tcp.jai` (addresses, 40 client fibers against an echo server, a 600 KB transfer, end of stream, reset, refused, address in use, close under a reader, name lookups), `timeouts.jai` (deadlines, nesting, cancel during accept, read, write and lookup, a scheduler that ends with blocked fibers), `files.jai` (which includes a large read that is canceled or whose file is closed while it is out) and `backends.jai`, which sets `JAI_IO_BACKEND` for each backend the system offers (io_uring and epoll on Linux, kqueue on macOS, iocp and ioring on Windows) and runs every check on it, skipping a backend the system refuses and printing the engine's reason. On epoll and kqueue it also runs the file tests with every operation on the pool and with the pool off. The shared checks are in `tests/lib/suite.jai`. With a release `jaic run` each program takes about a second on macOS.

*What was verified where.* macOS (kqueue, the file pool): all tests, interp and native. Windows x64 and arm64, and Linux x64 and arm64: `jaic check stdlib/Extensions/Io/tests/backends.jai -no_dce -os windows -cpu x64|arm64` (and `-os linux`) type-check; nothing of the Windows backends has run yet, so the first run is the `windows native` workflow.

`bench/bench.jai` (`jaic build -O2 stdlib/Extensions/Io/bench/bench.jai -o /tmp/io-bench`; `JAI_IO_BACKEND` forces a backend; a thread count argument runs the connection test on several schedulers) measures echo round trips on 64 connections and connections per second, server and clients on one scheduler. Apple silicon, kqueue, native `-O2`: about 140,000 echo round trips per second (64-byte messages), about 43,000 connections per second on one thread. Linux numbers come from CI machines and are not recorded yet.

## Not done yet

UDP, multishot accept and provided buffers, zero-copy send, a stat call, a DNS timeout of our own, cancellation of IoRing file operations (`BuildIoRingCancelRequest`), registered files and buffers for IoRing, `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS` to save a packet per immediate completion on Windows, and a timer resolution request on Windows.
