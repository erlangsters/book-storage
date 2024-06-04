%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_target).
-moduledoc """
Behaviour for a book-storage backend.

`book_storage` owns page-full policy, the in-memory index, and retention
decisions. A backend owns bytes, file descriptors, and crash recovery of its
own format. Callbacks are invoked sequentially on one handle.
""".

-export_type([
    target_state/0,
    page_handle/0,
    open_info/0,
    page_table/0,
    completed_page/0,
    recovered/0
]).

-doc """
Backend-private state threaded through every callback.
""".
-type target_state() :: term().

-doc """
Backend-private identifier of a page, completed or active.
""".
-type page_handle() :: term().

-doc """
Subset of open options the backend needs.

Retention (`max_pages`) is not included; `book_storage` owns that decision.
""".
-type open_info() :: #{
    page_lines := pos_integer(),
    page_bytes := pos_integer(),
    sync := book_storage:sync_mode()
}.

-doc """
In-memory table of one page.

`times` is write order (line number is the 1-based index). `tags` maps each
tag key and value to the line numbers that carry it. `bytes` is the sum of
canonical encoded line sizes for those lines.
""".
-type page_table() :: #{
    times := [book_storage:time()],
    tags := #{
        book_storage:tag_key() =>
            #{book_storage:tag_value() => [pos_integer()]}
    },
    bytes := non_neg_integer()
}.

-doc """
Page-level metadata for a completed page.

It is not a per-line index. Query rebuilds that from `read_lines/4`.
""".
-type completed_page() :: #{
    handle := page_handle(),
    page := pos_integer(),
    first_time := book_storage:time(),
    last_time := book_storage:time(),
    line_count := pos_integer(),
    tag_values := #{book_storage:tag_key() => [book_storage:tag_value()]}
}.

-doc """
Result of `open/2`.

`active` may have empty `times` on a brand-new book. `next_page` is one more
than the highest existing page number.
""".
-type recovered() :: #{
    completed := [completed_page()],
    active := page_table(),
    active_handle := page_handle(),
    next_page := pos_integer()
}.

-doc """
Open or recover the backing store.

Missing files and directories are created. Corrupt files fail; they are not
repaired except for the documented empty-active recovery after a clean turn.
""".
-callback open(Args :: term(), open_info()) ->
    {ok, target_state(), recovered()} | {error, book_storage:reason()}.

-doc """
Close file descriptors or drop memory.

It does not have to fsync unless the backend's sync mode says so at close.
""".
-callback close(target_state()) -> ok | {error, book_storage:reason()}.

-doc """
Append one line to the active page.

`book_storage` has already decided the line fits. File and folder encode with
`book_storage_codec`. Memory stores the `line()` term and ignores on-disk
layout.
""".
-callback write_line(
    target_state(),
    book_storage:time(),
    book_storage:value(),
    book_storage:tags()
) -> {ok, target_state()} | {error, book_storage:reason()}.

-doc """
Finalize the active page and start a new empty one.

The page table is passed in so the backend does not have to rebuild it.
""".
-callback turn_page(target_state(), page_table()) ->
    {ok, target_state(), completed_page(), NewActiveHandle :: page_handle()} |
    {error, book_storage:reason()}.

-doc """
Read an inclusive 1-based line range from a page.

The result reconstructs `line()` maps. It does not interpret the value blob.
""".
-callback read_lines(
    target_state(),
    page_handle(),
    FromLine :: pos_integer(),
    ToLine :: pos_integer()
) -> {ok, [book_storage:line()]} | {error, book_storage:reason()}.

-doc """
Drop completed pages.

Folder unlinks the files then rewrites `BOOK`. Memory drops the lists. The
active page is never in this list.
""".
-callback discard_pages(target_state(), [page_handle()]) ->
    {ok, target_state()} | {error, book_storage:reason()}.

-doc """
Whether this backend can drop completed pages.

File returns `false`. Memory and folder return `true`.
""".
-callback supports_discard(target_state()) -> boolean().

-doc """
Flush according to the backend's sync mode.

Memory is a no-op. `none` is a no-op on file backends.
""".
-callback sync(target_state()) -> ok | {error, book_storage:reason()}.
