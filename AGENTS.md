# book-storage

- Pure Erlang library in the `observability` family.
- OTP 27, 28, and 29. `rebar3` is the build. Library app: `kernel` / `stdlib` only, no `{mod, ...}`.
- Process-free opaque `book()` handle. Every `write/4` returns `{ok, Book} | {error, Reason, Book}`; the returned handle is the only one that may be used next.
- Targets: `memory`, `{file, Path}` (unbounded debug persist; any `{max_pages, _}` is rejected), `{folder, Path}` (production ring), `{Module, Args}`.
- `book_storage_codec` is internal. Do not document it as a public API.
- No stream at this layer. Historical read is `query/2`.
