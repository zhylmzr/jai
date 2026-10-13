# Io: the completion engine, TCP and files (`Extensions/Io`)

## What it is

The IO half of `Extensions/Io`: blocking-style `tcp_listen`, `accept`, `connect`, `read`, `write`, `close`, file calls, `resolve`, deadlines and cancellation for [fibers](io-fibers.md) (the common `Reader`/`Writer` over files, TCP and pipes is in [io-streams.md](io-streams.md)), on top of an internal completion engine with five backends (io_uring and epoll on Linux, kqueue on macOS, completion ports with or without an IoRing for files on Windows) and a worker thread pool for files on epoll and kqueue. Milestones 3 and 7 of [the async IO plan](../plans/async-io.md).

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
| Listening | `tcp_listen(text or Address, backlog, reuse_port)`, `accept`, `local_address`, `close(listener, now := false)` |
| Streams | `connect(Address / "host:port")`, `read` (0 is end of stream), `read_full` (`.END_OF_FILE`), `wait_readable` (returns when a `read` would not wait, takes no buffer), `write` (all of it), `write_some`, `shutdown_write`, `peer_address`, `close(stream, now := false)`; `reader_of`/`writer_of` give an `Io.Reader`/`Io.Writer` ([io-streams.md](io-streams.md)) |
| Files | `open_file(path, File_Mode)` with `.READ .WRITE .APPEND .READ_WRITE`; on a `*Io_File` (it has a position, so by pointer): `read` / `read_full` / `write` / `write_some` (advance `position`), `read_at` / `write_at`, `file_size`, `close`; whole-file `read_file` (built on a reader) / `write_file` |
| Time | `sleep`, `with_deadline(ms, #code { ... })` (the one deadline primitive), `cancel(fiber)`, `is_canceled` |
| Threads | `io_run_threads(count, proc [, data])` (one scheduler per thread, no stealing), `processor_count` |
| Introspection | `backend()` (`.IO_URING .EPOLL .KQUEUE .IOCP .IORING .NONE`), `backend_name()`, `backend_reason()`, `capabilities()`, `last_platform_code()` |

- **Errors.** `Io_Error` is `NONE`, `CANCELED`, `CLOSED`, `TIMED_OUT`, `END_OF_FILE`, `CONNECTION_RESET`, `CONNECTION_REFUSED`, `CONNECTION_ABORTED`, `BROKEN_PIPE`, `NOT_CONNECTED`, `ADDRESS_IN_USE`, `ADDRESS_UNAVAILABLE`, `NETWORK_UNREACHABLE`, `HOST_UNREACHABLE`, `NOT_FOUND`, `ALREADY_EXISTS`, `PERMISSION_DENIED`, `INVALID`, `NO_SPACE`, `TOO_MANY_OPEN_FILES`, `IS_A_DIRECTORY`, `UNSUPPORTED`, `RESOLVE_FAILED` and `OTHER`. The enum only grows. `last_platform_code()` is the system's error number behind the running fiber's last failed call (the errno, or `getaddrinfo`'s code for `RESOLVE_FAILED`), so `OTHER` stays diagnosable and new kernel errors never break callers.
- **`close`** works for a canceled fiber (so `defer close(conn)` always cleans up) and wakes every fiber waiting on that handle with `.CLOSED`. `close(x, now = true)` closes at once without waiting, for code that cannot block (it replaces the old `close_now`).
- **Cancellation.** `cancel(fiber)` ends the fiber's current IO with `.CANCELED`, and all later IO of that fiber fails the same way (it is sticky, as for `sleep`). The fiber stays blocked until the engine reports the canceled operation, so a buffer is never written after the call returns.
- **Deadlines.** `with_deadline(ms, #code { ... })` limits every IO call and `sleep` in the block; the earlier deadline wins when they nest; an expired deadline fails the call before it starts, even when data is waiting (also on a pipe). A timed out call affects only itself. `NO_DEADLINE` (-1) adds no limit. `set_deadline`/`restore_deadline` are gone. jaic does not accept a trailing block after the call, so the block goes in as a `#code` argument. Channel and lock operations ignore deadlines.
- **`resolve`.** Address literals never leave the process. Names go to `getaddrinfo` on helper threads of the scheduler: one is started at the first lookup, another whenever a lookup is queued and every helper already has a job (up to `RESOLVER_MAX_THREADS`, 8), and all are joined when `io_run` ends (helpers are not retired earlier). Only the asking fiber waits. Lookups for the same name (exact text) that are queued or running share one job: later fibers join its waiter list and each gets the answer with its own port, so a fan-out to one origin makes one `getaddrinfo` call. There is no cache beyond that: once the answer is collected, the next lookup asks again. IPv4 is preferred when a name has both. A cancel or a deadline stops that fiber's wait at once and only takes it off the job; the lookup itself cannot be interrupted, so the job is freed when its answer is collected, whoever is still waiting. `resolver_statistics()` (jobs made, helpers started on this scheduler) exists for tests.
- **Files.** On io_uring the kernel does reads and writes, on Windows completion ports or an IoRing do, and only the fiber waits. epoll and kqueue cannot report a regular file as not ready, so those backends send reads and writes longer than 32 KiB to a [thread pool](#file-thread-pool) and run shorter ones at once on the scheduler's thread. `.APPEND` always writes at the end, whatever the offset, because systems disagree on `pwrite` with `O_APPEND`. `open_file` is always a plain call. Paths are UTF-8 (converted to UTF-16 on Windows).
- **Several schedulers.** `io_run_threads(4, proc)` starts four threads, each with its own scheduler and engine, and runs `proc` on a fiber of each. Listen with `reuse_port = true` in each and the kernel spreads connections between the listeners (Linux balances by hash; macOS does not balance, but delivers every connection to some listener). Fibers never move between threads, and a `Channel` or `Wait_Group` must stay on one thread.

## How it works

Files: `platform.jai` (libc calls and per-OS numbers), `engine.jai` (types, backend choice, `await_op`), `engine_poll.jai` (epoll and kqueue), `engine_uring.jai`, `engine_iocp.jai` and `engine_ioring.jai` (Windows), `win32.jai` (Win32 declarations and the Windows `sys_*` calls), `files_pool.jai` (file thread pool), `net.jai`, `files.jai`, `stream.jai` (readers and writers), `json.jai` (`read_json`), `resolver.jai` (helper threads), `runtime.jai` (deadlines, threads, introspection).

**The engine.** A fiber describes an operation (`Op`: kind, `Handle`, buffer, offset, address), calls `engine_submit` and parks. The engine finishes it now (`engine_submit` returns true, nothing parks) or later (`finish_op` records result, flags, `more` and buffer id, and wakes the fiber). Kinds: accept, connect, recv, send, read and write (with an offset for files), close, and wait-readable, which completes when a `recv` would not wait and consumes nothing (it is `wait_readable`; a server uses it to keep an idle connection without a read buffer). A `Handle` is an opaque descriptor plus a kind tag (`SOCKET`, `FILE`, `STREAM`), so a SOCKET or HANDLE fits later. Results are a byte count or the negative platform errno; `error_from_code` makes them portable. The rules of the plan hold: buffers and addresses belong to an operation until its completion arrives, even after a cancel; a missing feature is a fallback, never an error.

**Scheduler hook.** `wait_step` (fibers have nothing ready) computes the time to the next timer and calls `engine_wait(timeout)`, which submits what is queued, waits for completions up to the timeout and wakes fibers; it replaced the old OS sleep. Every 64 switches a busy scheduler also polls the engine without waiting. The timer heap serves `sleep` and deadlines: a deadline is a timer on a fiber blocked in an operation, and when it fires the scheduler cancels the operation with cause `TIMED_OUT`. (There is no separate engine "timeout" operation: the wait timeout carries io_uring's `EXT_ARG`, `epoll_wait`'s milliseconds or kevent's timespec.) Nothing ready, no timers and nothing in flight is the old deadlock report.

**io_uring** (Linux with the 6.1 floor, on [Extensions/Io_Uring](io-uring.md)). One ring per scheduler thread, 512 entries, created on the scheduler's thread with `SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN`, retrying with `COOP_TASKRUN` and then with no flags when the kernel answers `EINVAL`. A denial (`ENOSYS`, `EPERM`, `EACCES`, `ENOMEM`: old kernels, seccomp in containers, `kernel.io_uring_disabled`) ends the ladder, and the engine uses epoll and records why in `backend_reason()`. After setup it probes the opcodes it uses plus `SENDMSG_ZC` (the 6.1 marker) and needs `IORING_FEAT_EXT_ARG`; otherwise it falls back too. Submission only fills an entry (`user_data` is the `Op` address); entries reach the kernel in batches when the scheduler waits, polls, or the queue is full. The wait is one `io_uring_enter` with `GETEVENTS` and a timeout; completions are reaped straight from the ring. Sockets stay blocking (io_uring waits for them itself) and `accept` takes `SOCK_CLOEXEC` only. Cancel is `ASYNC_CANCEL` by `user_data`; close is a hard-linked `ASYNC_CANCEL` by descriptor followed by `CLOSE`, so fibers waiting on that descriptor wake (a closed fd alone would not end an in-flight receive). `wait_readable` is `IORING_OP_POLL_ADD` with `POLLIN`, one shot; a hang-up or an error also completes it, and the `read` that follows reports which. Cancel results (`-ECANCELED`) are mapped to `.CANCELED`, `.TIMED_OUT` or `.CLOSED` by who asked.

**epoll and kqueue** share `engine_poll.jai`. A readiness API does not do IO, so an operation is tried at once without blocking (accept, `connect` returning `EINPROGRESS`, recv, send, pread); on `EAGAIN` it waits in a queue on its descriptor (one list of readers and one of writers, in `Fd_State`) and the descriptor is armed for one notification: kqueue `EV_ADD | EV_ONESHOT` per direction, epoll `EPOLLONESHOT` for the whole descriptor (re-armed with the mask of the remaining waiters). When it fires, the queue is served in order until an operation would block again. Two fibers on one descriptor therefore cannot lose each other's wake-up. kqueue changes are batched into the wait call. `connect` waits for writability and reads `SO_ERROR`. `wait_readable` is tried at once with a one-byte `recv(MSG_PEEK)`, which only looks, and waits in the reader queue like a `recv` when there is nothing; when the descriptor is reported readable the first waiter in line is completed without looking again. Closing a descriptor fails everything waiting on it first. Sockets are non-blocking, close-on-exec and `SO_NOSIGPIPE` (macOS) or `MSG_NOSIGNAL` (Linux).

**Resolver and wake-ups.** Helper threads cannot call into a backend, so they hand finished jobs to the scheduler through a pipe: the scheduler keeps an ordinary internal `READ` on the pipe armed while lookups are out (so every backend wakes the same way), a helper appends its job to a mutex-protected list and writes a byte, and the completion wakes the fibers. `engine_stop` waits for outstanding lookups first (jobs, shared or abandoned, until every helper has answered), then joins every helper that was started, so a late answer never reaches freed memory.

**Windows** (`engine_iocp.jai`, `engine_ioring.jai`, `win32.jai`; x64 and arm64). One completion port per scheduler thread. Every operation is an overlapped call carrying its `Op`: `Op` starts with the `OVERLAPPED`, so the pointer a packet brings back is the operation. Calls never use "skip the packet on success", so a call that returns success or `ERROR_IO_PENDING` always finishes with a packet in `iocp_wait`, and one that fails at once finishes in `iocp_submit`.

| Operation | Call |
|---|---|
| accept | `AcceptEx` on a socket made ahead of time (so `getsockname`/`getpeername` work after `SO_UPDATE_ACCEPT_CONTEXT`) |
| connect | `ConnectEx` after a bind to the wildcard address, then `SO_UPDATE_CONNECT_CONTEXT` |
| recv, send | `WSARecv`, `WSASend` (at most 64 KiB per send, so a canceled `write` can report what went out) |
| wait-readable | `WSARecv` with a zero-length buffer, which completes when data, the end of the stream or an error is there; any error but the cancel counts as readable |
| read, write | `ReadFile`/`WriteFile` with the offset in the OVERLAPPED (end of file offset for appends), or the IoRing |
| cancel | `CancelIoEx`; the operation still completes, as `ERROR_OPERATION_ABORTED` |
| close | `CancelIoEx` on the whole handle, then `closesocket`/`CloseHandle`; fibers waiting on it wake with `.CLOSED` |

`AcceptEx` and `ConnectEx` are fetched with `WSAIoctl` at startup. The wait is `GetQueuedCompletionStatusEx` with the scheduler's timeout in milliseconds, rounded up; a timeout is reported as `WAIT_TIMEOUT` (258) or `ERROR_TIMEOUT` (1460) depending on the Windows version, and both mean no completions. A packet's result is the NTSTATUS in `OVERLAPPED.Internal`, taken from the dequeued entry (the handle may be closed by then) and turned into a Win32 error with `RtlNtStatusToDosError`; on Windows the `E_*` numbers are the Win32 and Winsock numbers themselves, so `last_platform_code()` is the real error, and `windows_error` maps the extra ones (`ERROR_NETNAME_DELETED` is a reset, `ERROR_CONNECTION_REFUSED` a refusal, ...). Gotchas: `bytes > 0` with an abort status counts as a short success; `ERROR_HANDLE_EOF` is a read of 0; Windows has no `SO_REUSEPORT`, so a plain listener uses `SO_EXCLUSIVEADDRUSE` (the opposite of `SO_REUSEADDR` there, which would let another program take the port) and `reuse_port = true` uses `SO_REUSEADDR`, which shares the port but hands connections to one listener rather than balancing them; timeouts are as fine as the system timer (about 15 ms unless something raised its resolution); a connect to a closed local port reports the refusal after a second or two.

Name lookups (`resolve`) use `getaddrinfo` on the same helper threads; a helper wakes the scheduler by posting a packet with no OVERLAPPED and `KEY_WAKE` to the port, instead of writing a pipe.

**IoRing** (`.IORING`, Windows 11 22H2+; `ioringapi.h`). It is for files only: sockets, `wait_readable` included, go through the completion port in this mode too. The API is loaded from KernelBase.dll with `GetProcAddress`, so older Windows still runs. A one-time probe checks that all the functions exist, that `QueryIoRingCapabilities` offers at least version 2, and then runs a self test for each version it knows, newest first (`IORING_VERSION_3`, which is 300 in `ioringapi.h`, then 2): it creates a throwaway ring of that version, reads two bytes of the program's own executable through it, waits for the completion event, checks for "MZ" and builds (without submitting) a write entry, which a ring version without file writes refuses (`0x80004021`). The first version that passes is the one every engine ring is created with. Anything that fails sends files to the completion port and records the step in `backend_reason()`. With a ring: reads and writes become submission entries (`BuildIoRingReadFile`/`BuildIoRingWriteFile`, the `Op` as user data) that `SubmitIoRing` hands over in a batch whenever the scheduler waits; completions are popped in user space. The ring's completion event is waited on by a small helper thread (started at the first file operation) that posts `KEY_RING` to the port; while operations are in the ring the scheduler never sleeps longer than 50 ms, so a lost event delays instead of hangs. The ring holds 128 operations and more wait in a list. Operations in a ring cannot be canceled (a file read ends in disk time), and `close` of a file waits for the ring to go idle. Files are not attached to the completion port in this mode. The by-value `IORING_HANDLE_REF`/`IORING_BUFFER_REF` structs rely on jaic's Win64 and Windows arm64 struct passing.

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

## Who may wake a fiber

`wake` asserts that its target is `BLOCKED`. So whoever calls it must know the fiber is parked and that nothing else will wake that park. A fiber parks at once after it queues itself somewhere, and wakes once; calls the running fiber makes before it parks (`engine_submit`, `wake_arm`, `uring_cancel`) can finish other fibers' work, never its own.

- **`finish_op`** (all backends) wakes the fiber of a finished operation. The operation is taken off its queue (or its ring entry is consumed) first, so it finishes once. A fiber has an operation outstanding only after its submit returned false, so it is parked when the completion comes. A submit that fails or finishes inline returns true and reports through `op.result`; `poll_submit` does this too when the kernel refuses to watch the descriptor, and it does not go through `finish_op` for its own operation.
- **Cancel and deadline of an operation** (`cancel_op`) only ask the engine to end it. The fiber wakes in `finish_op` when the canceled operation completes, so a completion racing a cancel is still one wake. A pool or IoRing operation ignores the cancel and wakes when it completes.
- **`poll_fail` and `poll_close`** finish the operations queued on a descriptor. Those belong to parked fibers; the fiber that closes has no operation queued.
- **File pool and IoRing completions** (`pool_collect`, `ring_drain`) finish operations that parked fibers hold. `pool_arm` runs before the new operation reaches a worker, so an inline `pool_collect` cannot find it.
- **Resolver** (`wake_fiber`): a job is collected once. The fiber that queued it is still running when `wake_arm` collects an answer that is already there, so `wake_fiber` clears `fiber.job` and leaves it; `resolve_with_helper` parks only while `fiber.job` is set. A job has a list of waiters (`Resolve_Waiter`, on each fiber's stack); `wake_collect` removes the job from the in-flight list, copies the answer into every waiter and wakes each once. A canceled or timed-out fiber leaves the list first (`abandon_job`), so a late answer wakes nobody and a shared job still answers the others.
- **`cancel_fiber`** does nothing unless the fiber is `BLOCKED`. The fiber then has either an operation (it wakes in `finish_op`), a lookup (`abandon_job` takes it off the job's waiter list, then one wake), or a wait list entry and maybe a timer (both removed, then one wake). A fiber that is `READY` or `RUNNING` only gets `canceled` set.
- **`fire_timers`** removes the timer before it acts, so one timer is one wake. For an operation it cancels (wake in `finish_op`), for a lookup it abandons the job and wakes, otherwise it takes the fiber off its wait list and wakes it. Leaving it on the list would let a producer wake it again before it runs.
- **`wake`** removes a timer the fiber still has, so a completion after a timer (or the reverse) never leaves a stale timer behind.
- **Pipes** (`pipe_wake`) and **channels, wait groups and mutexes** (`hand_to_receiver`, `take_ready`, `close`, `wake_all`, `unlock`): the waiter is popped from the list before its fiber is woken, so a waiter wakes once. A fiber is on a list only while parked, and the caller is running, so it never wakes itself. Cancel and deadline take a fiber off the list before they wake it.

A new `wake` caller has to answer three questions: can the target be the running fiber, can it be woken twice for one park (completion plus cancel, completion plus timer, two completions), can it be `READY`. `tests/pipe.jai` (`test_write_between_deadline_and_wakeup`) and `tests/backends.jai` (`test_epoll_refuses_a_descriptor`) are the regressions for the last two bugs; `test_cancel_resolve` covers the lookup that is answered early.

## How to change it

- **A new operation:** add an `Op_Kind` (`WAIT_READABLE` is the smallest example: `sys_peek` in `platform.jai`, a case in `poll_attempt`, `POLL_ADD` in `uring_submit`, the zero-byte receive in `iocp_submit`, and `wait_readable` in `net.jai`), a case in `poll_attempt` (poll backends) and in `uring_submit`, then a public procedure in `net.jai` or `files.jai` that fills an `Op` and calls `await_op`.
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
| `RING_ENTRIES` (512), `RESOLVER_MIN_THREADS` (1), `RESOLVER_MAX_THREADS` (8), `MAX_POLLED_FDS`, `RING_SUBMISSION` (128), `SEND_CHUNK` (64 KiB) | constants in `engine_uring.jai`, `resolver.jai`, `engine_poll.jai`, `engine_ioring.jai`, `win32.jai` |

## Dependencies

libc (`socket`, `kevent`/`epoll`, `eventfd`, `pread`, `getaddrinfo`, ...), [`Extensions/Io_Uring`](io-uring.md) on Linux, kernel32, ws2_32 and KernelBase (loaded at run time) on Windows, [`Atomics`](atomics.md), and `Thread` for the resolver, the file pool and `io_run_threads`. The Win32 declarations are private to `win32.jai`. Not available on wasm.

## Tests and numbers

`stdlib/Extensions/Io/tests/` (run by the [stdlib runtime tests](../tools/stdlib-runtime-tests.md) in `interp` and `native` on Linux, macOS and Windows; skipped on wasm): `tcp.jai` (addresses, 40 client fibers against an echo server, a 600 KB transfer, end of stream, reset, refused, address in use, close under a reader, name lookups, `wait_readable`: a deadline, data arriving, nothing consumed, the end of the stream, cancel, close, and a deadline racing the data), `streams.jai` (the [reader/writer](io-streams.md) operations over each source, `read_json`), `timeouts.jai` (deadlines, nesting, cancel during accept, read, write and lookup, a scheduler that ends with blocked fibers), `files.jai` (which includes a large read that is canceled or whose file is closed while it is out) and `backends.jai`, which sets `JAI_IO_BACKEND` for each backend the system offers (io_uring and epoll on Linux, kqueue on macOS, iocp and ioring on Windows) and runs every check on it, skipping a backend the system refuses and printing the engine's reason. On epoll and kqueue it also runs the file tests with every operation on the pool and with the pool off. The shared checks are in `tests/lib/suite.jai`. With a release `jaic run` each program takes about a second on macOS.

*What was verified where.* macOS (kqueue, the file pool): all tests, interp and native. Windows x64 and arm64, and Linux x64 and arm64: `jaic check stdlib/Extensions/Io/tests/backends.jai -no_dce -os windows -cpu x64|arm64` (and `-os linux`) type-check; nothing of the Windows backends has run yet, so the first run is the `windows native` workflow.

`bench/bench.jai` (`jaic build -O2 stdlib/Extensions/Io/bench/bench.jai -o /tmp/io-bench`; `JAI_IO_BACKEND` forces a backend; a thread count argument runs the connection test on several schedulers) measures echo round trips on 64 connections and connections per second, server and clients on one scheduler. Apple silicon, kqueue, native `-O2`: about 140,000 echo round trips per second (64-byte messages), about 43,000 connections per second on one thread. Linux numbers are in [Numbers](#numbers).

### Numbers

Linux baseline for milestone 9 of the [plan](../plans/async-io.md). Machine: 4 vCPUs of an Intel Xeon @ 2.10GHz in a VM (Firecracker), Linux 6.18.44, jaic `-O2`, loopback. Load generators run on the same cores as the server, so these are floors, and the run-to-run spread is about 10%. Medians of 5 runs, requests (or operations) per second; `JAI_IO_BACKEND` picks the backend.

```
jaic build stdlib/Extensions/Http/bench/server_bench.jai -O2 -o /tmp/http-bench
JAI_IO_BACKEND=io_uring /tmp/http-bench 4 3000      # threads, ms per route; also epoll, and 1 thread
jaic build stdlib/Extensions/Http/bench/idle_bench.jai -O2 -o /tmp/http-idle
JAI_IO_BACKEND=io_uring /tmp/http-idle 1000
jaic build stdlib/Extensions/Io/bench/bench.jai -O2 -o /tmp/io-bench
JAI_IO_BACKEND=io_uring /tmp/io-bench 4             # also 1 thread (no argument), and epoll
```

| Benchmark | io_uring | epoll | io_uring vs epoll |
|---|---|---|---|
| HTTP hello, 1 thread (5 runs of 3 s) | 99.4k | 84.0k | +18% |
| HTTP JSON, 1 thread | 83.1k | 69.8k | +19% |
| HTTP hello, 4 threads | 375k | 310k | +21% |
| HTTP JSON, 4 threads | 335k | 281k | +19% |
| Idle server RSS, 1,000 connections | 16.3 KB each | 16.2 KB each | same |
| Io echo round trips, 1 thread (64 connections, 64 bytes) | 148k | 126k | +18% |
| Io connections per second, 1 thread | 27.7k | 25.3k | +10% |
| Io connections per second, 4 threads | 47.2k | 37.7k | +25% |

io_uring is ahead of epoll by about a fifth on every request-shaped benchmark, one thread or four, and by about a tenth to a quarter on connection churn; memory is the same, because it is the fiber stacks. Four threads give 3.7 to 4.0 times one thread on four cores that also run the load generator, so the engine is not the limit there. The benchmarks do not measure latency percentiles; that is still open.

## Not done yet

UDP, multishot accept and provided buffers, zero-copy send, a stat call, a DNS timeout of our own, cancellation of IoRing file operations (`BuildIoRingCancelRequest`), registered files and buffers for IoRing, `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS` to save a packet per immediate completion on Windows, and a timer resolution request on Windows.
