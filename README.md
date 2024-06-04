# Book Storage

[![Erlangsters Repository](https://img.shields.io/badge/erlangsters-book--storage-%23a90432)](https://github.com/erlangsters/book-storage)
![Supported Erlang/OTP Versions](https://img.shields.io/badge/erlang%2Fotp-27%7C28%7C29-%23a90432)
![Current Version](https://img.shields.io/badge/version-0.0.1-%23354052)
![License](https://img.shields.io/github/license/erlangsters/book-storage)
[![Build Status](https://img.shields.io/github/actions/workflow/status/erlangsters/book-storage/build.yml)](https://github.com/erlangsters/book-storage/actions/workflows/build.yml)
[![Documentation Link](https://img.shields.io/badge/documentation-available-yellow)](http://erlangsters.github.io/book-storage/)

This 0.0.1 is a candidate implementation. The API may change in 0.0.2.

The book storage is an embeddable time series database for the BEAM.

It stores timestamped opaque binaries with tags, locally, next to the application. Writes are append-only and chronological. Query is a time window plus exact tag match. Production persistence is a folder of page files; a single file is debug / simple persist; `memory` is for tests.

```erlang
{ok, Book0} = book_storage:open({folder, "data"}),
{ok, Book1} = book_storage:write(Book0, erlang:system_time(millisecond), <<"event">>, #{k => <<"v">>}),
{ok, Lines} = book_storage:query(Book1, #{last => 10}),
ok = book_storage:close(Book1).
```

Written by the Erlangsters [community](https://about.erlangsters.org/) and released under the MIT [license](https://opensource.org/license/mit).

## Getting started

Open a book with `book_storage:open/1` or `open/2`. Use `{folder, Path}` when the data should survive restart and stay bounded with `{max_pages, N}`. Use `{file, Path}` only as unbounded debug persist (any `{max_pages, _}` is rejected). Use `memory` in tests.

```erlang
{ok, Book0} = book_storage:open({folder, "metrics-data"}, [{max_pages, 32}]),
{ok, Book1} = book_storage:write(Book0, 1, <<"a">>, #{kind => <<"counter">>}),
{ok, Book2} = book_storage:write(Book1, 2, <<"b">>, #{kind => <<"counter">>}),
{ok, [#{time := 1}, #{time := 2}]} = book_storage:query(Book2, #{}),
{ok, #{page_count := _, line_count := 2}} = book_storage:info(Book2),
ok = book_storage:close(Book2).
```

`query(Book, #{})` is the oldest 10_000 lines, not a whole-book dump. Pass an explicit `last` or `limit` when you need a different window.

A book is a sequence of pages of lines. When the next write would not fit (1000 lines or 1 MiB by default), the page turns. On a folder or memory book, occupancy above `max_pages` drops the oldest completed page. Values are opaque binaries; storage never looks inside them.

There is no process. Every `write/4` returns a new handle that must be used next. Concurrent writers must be serialized by the caller. The logs and metrics facades are the intended later wrappers; they are not part of this 0.0.1.

## Installing the library

To use book-storage in a rebar3 project, add it to your rebar.config.

```erlang
{deps, [
  {book_storage, {git, "https://github.com/erlangsters/book-storage.git", {tag, "0.0.1"}}}
]}.
```
