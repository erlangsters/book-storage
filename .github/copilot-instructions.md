# Book Storage Copilot Guidelines

- `book-storage` is a `pure-erlang-library` repository in the `observability` family.
- Build with `rebar3`. Do not reintroduce Erlang.mk or Makefile-based usage.
- It is a process-free embeddable store. `open` returns an opaque handle; every `write/4` returns a new handle that must be used next.
- Production persistence is `{folder, Path}` with `{max_pages, N}`. `{file, Path}` is unbounded debug persist and rejects any `{max_pages, _}`. `memory` is for tests.
- `book_storage_codec` is internal, not a public API. File and folder backends must share it rather than copying the on-disk layout.
- Keep the design local-first and simple. No high write volume, compression, NIFs, or distributed storage.
- Keep examples and API shaping Erlang-first. Prefer BEAM-neutral public one-liners.
