%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_storage).
-moduledoc """
Embeddable append-only time-series storage for the BEAM.

It models a book of pages of lines. A line is a timestamp, an opaque binary
value, and a tag map. Writes are chronological. Query is a time window plus
exact tag match.

```erlang
{ok, Book0} = book_storage:open(memory),
{ok, Book1} = book_storage:write(Book0, 1, <<"a">>, #{k => <<"v">>}),
{ok, [#{time := 1, value := <<"a">>}]} = book_storage:query(Book1, #{last => 10}),
ok = book_storage:close(Book1).
```

Production persistence is `{folder, Path}`. `{file, Path}` is debug / simple
persist and rejects any `{max_pages, _}`. There is no process: every `write/4`
returns a new handle that must be used next.
""".

-export_type([
    book/0,
    target/0,
    option/0,
    sync_mode/0,
    time/0,
    value/0,
    tag_key/0,
    tag_value/0,
    tags/0,
    tags_match/0,
    line/0,
    query/0,
    book_info/0,
    page_info/0,
    reason/0
]).

-export([
    open/1, open/2,
    close/1,
    write/3, write/4,
    query/2,
    info/1,
    sync/1
]).

-record(book, {
    meta :: ets:tid(),
    target_kind :: memory | file | folder | custom,
    target_mod :: module(),
    target_state :: term(),
    page_lines :: pos_integer(),
    page_bytes :: pos_integer(),
    max_pages :: pos_integer() | infinity,
    cache_pages :: pos_integer(),
    last_time :: empty | time(),
    first_time :: empty | time(),
    page_count :: non_neg_integer(),
    line_count :: non_neg_integer(),
    completed :: [book_target:completed_page()],
    active :: book_target:page_table(),
    active_handle :: term(),
    active_page :: pos_integer(),
    next_page :: pos_integer()
}).

-opaque book() :: #book{}.

-doc """
Unix time in milliseconds.

Callers that need 'now' should pass `erlang:system_time(millisecond)`.
The storage module never reads the clock.
""".
-type time() :: non_neg_integer().

-doc """
Opaque line payload.

Storage does not inspect or query inside it.
""".
-type value() :: binary().

-doc """
Tag key on a line.
""".
-type tag_key() :: atom().

-doc """
Tag value on a line.

It is always a binary. Facades canonicalize their own label types before write.
""".
-type tag_value() :: binary().

-doc """
Tags attached to a line.
""".
-type tags() :: #{tag_key() => tag_value()}.

-doc """
Tag filter.

Each key in the map must be present on the line. A binary value is exact
match. A list is OR of those values for that key. Distinct keys are AND.
An empty list matches nothing. An omitted key matches any value (including
absent).
""".
-type tags_match() :: #{tag_key() => tag_value() | [tag_value()]}.

-doc """
One stored line.
""".
-type line() :: #{
    time := time(),
    value := value(),
    tags := tags()
}.

-doc """
Where the book is stored.
""".
-type target() ::
    memory |
    {file, file:filename_all()} |
    {folder, file:filename_all()} |
    {module(), Args :: term()}.

-doc """
When the backend fsyncs.

`delayed` fsyncs on page turn, `sync/1`, and close. `every_write` also fsyncs
per line. `none` never fsyncs.
""".
-type sync_mode() :: none | delayed | every_write.

-doc """
Open option.
""".
-type option() ::
    {page_lines, pos_integer()} |
    {page_bytes, pos_integer()} |
    {max_pages, pos_integer() | infinity} |
    {sync, sync_mode()} |
    {cache_pages, pos_integer()}.

-doc """
Query map.

Defaults: `from => beginning`, `to => latest`, `tags => #{}`, `limit => 10000`.
`query(Book, #{})` is therefore the oldest 10_000 lines, not the whole book.
`last => N` selects the N most recent matches and returns them oldest-first.
""".
-type query() :: #{
    from => time() | beginning,
    to => time() | latest,
    tags => tags_match(),
    last => non_neg_integer(),
    limit => pos_integer()
}.

-doc """
One page in `info/1`.

Empty active pages are omitted. `line_count` is therefore at least 1.
""".
-type page_info() :: #{
    page := pos_integer(),
    first_time := time(),
    last_time := time(),
    line_count := pos_integer(),
    tag_values := #{tag_key() => [tag_value()]}
}.

-doc """
Snapshot of book occupancy.

`page_count` includes an empty active page. `pages` does not.
""".
-type book_info() :: #{
    target_kind := memory | file | folder | custom,
    page_count := non_neg_integer(),
    line_count := non_neg_integer(),
    first_time := time() | empty,
    last_time := time() | empty,
    pages := [page_info()]
}.

-doc """
Storage error reason.

Facade-specific reasons are not included.
""".
-type reason() ::
    closed |
    {out_of_order, time(), time()} |
    {invalid_time, term()} |
    {invalid_target, term()} |
    {invalid_option, term()} |
    {unknown_option, term()} |
    {unsupported, atom(), term()} |
    {line_too_large, non_neg_integer(), pos_integer()} |
    {not_a_book, file:filename_all()} |
    {corrupt, term()} |
    {io, term()}.

-doc """
Open a book with default options.

It is `open(Target, [])`.
""".
-spec open(target()) -> {ok, book()} | {error, reason()}.
open(Target) ->
    open(Target, []).

-doc """
Open a book.

Missing files and directories are created. After open, `page_count >= 1`
because an active page always exists.
""".
-spec open(target(), [option()]) -> {ok, book()} | {error, reason()}.
open(Target, Options) ->
    case parse_target(Target) of
        {ok, Kind, Mod, Args} ->
            case parse_options(Options) of
                {ok, OptMap} ->
                    open_parsed(Kind, Mod, Args, Target, OptMap);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Close a book.

It is idempotent: the second call returns `ok`. After close, `write` / `query`
/ `info` / `sync` return `{error, closed}`.
""".
-spec close(book()) -> ok | {error, reason()}.
close(#book{meta = Meta, target_mod = Mod, target_state = State}) ->
    case is_closed(Meta) of
        true ->
            ok;
        false ->
            case Mod:close(State) of
                ok ->
                    mark_closed(Meta),
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-doc """
Write a line with no tags.

It is `write(Book, Time, Value, #{})`.
""".
-spec write(book(), time(), value()) -> {ok, book()} | {error, reason(), book()}.
write(Book, Time, Value) ->
    write(Book, Time, Value, #{}).

-doc """
Append a line.

The returned book is the only handle that may be used next, including on
error. Equal timestamps are allowed. An earlier timestamp is
`{out_of_order, Time, Last}`.
""".
-spec write(book(), time(), value(), tags()) ->
    {ok, book()} | {error, reason(), book()}.
write(#book{meta = Meta} = Book, Time, Value, Tags)
  when is_integer(Time), Time >= 0, is_binary(Value) ->
    case is_closed(Meta) of
        true ->
            {error, closed, Book};
        false ->
            case is_tags(Tags) of
                false ->
                    error(function_clause);
                true ->
                    write_checked(Book, Time, Value, Tags)
            end
    end.

-doc """
Query lines.

Results are oldest-first. Equal timestamps stay in write order. The result
cap is 1_000_000 lines.
""".
-spec query(book(), query()) -> {ok, [line()]} | {error, reason()}.
query(#book{meta = Meta} = Book, Query) when is_map(Query) ->
    case is_closed(Meta) of
        true ->
            {error, closed};
        false ->
            query_open(Book, Query)
    end.

query_open(#book{} = Book, Query) when is_map(Query) ->
    case parse_query(Query) of
        {ok, Parsed} ->
            run_query(Book, Parsed);
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Return occupancy and per-page metadata.

`pages` is completed pages oldest-first, then the active page iff it has
lines. `page_count` includes an empty active page.
""".
-spec info(book()) -> {ok, book_info()} | {error, reason()}.
info(#book{meta = Meta} = Book) ->
    case is_closed(Meta) of
        true ->
            {error, closed};
        false ->
            {ok, book_info(Book)}
    end.

-doc """
Flush according to the book's sync mode.

Memory and `{sync, none}` are no-ops.
""".
-spec sync(book()) -> ok | {error, reason()}.
sync(#book{meta = Meta, target_mod = Mod, target_state = State}) ->
    case is_closed(Meta) of
        true ->
            {error, closed};
        false ->
            Mod:sync(State)
    end.

open_parsed(Kind, Mod, Args, Target, OptMap) ->
    MaxPages = maps:get(max_pages, OptMap),
    MaxSet = maps:get(max_pages_set, OptMap),
    case {Kind, MaxSet} of
        {file, true} ->
            {error, {unsupported, max_pages, file}};
        _ ->
            OpenInfo = #{
                page_lines => maps:get(page_lines, OptMap),
                page_bytes => maps:get(page_bytes, OptMap),
                sync => maps:get(sync, OptMap)
            },
            case Mod:open(Args, OpenInfo) of
                {ok, TState, Recovered} ->
                    after_backend_open(Kind, Mod, TState, Recovered, OptMap, MaxPages, Target);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

after_backend_open(Kind, Mod, TState, Recovered, OptMap, MaxPages, _Target) ->
    case {is_integer(MaxPages), Mod:supports_discard(TState)} of
        {true, false} ->
            _ = Mod:close(TState),
            {error, {unsupported, max_pages, Kind}};
        _ ->
            #{
                completed := Completed,
                active := Active,
                active_handle := ActiveHandle,
                next_page := Next
            } = Recovered,
            ActivePage = case Completed of
                [] ->
                    Next - 1;
                _ ->
                    Next - 1
            end,
            Book0 = #book{
                meta = new_meta(),
                target_kind = Kind,
                target_mod = Mod,
                target_state = TState,
                page_lines = maps:get(page_lines, OptMap),
                page_bytes = maps:get(page_bytes, OptMap),
                max_pages = MaxPages,
                cache_pages = maps:get(cache_pages, OptMap),
                last_time = empty,
                first_time = empty,
                page_count = 0,
                line_count = 0,
                completed = Completed,
                active = Active,
                active_handle = ActiveHandle,
                active_page = ActivePage,
                next_page = Next
            },
            {ok, recompute(Book0)}
    end.

write_checked(Book, Time, Value, Tags) ->
    case Book#book.last_time of
        empty ->
            write_sized(Book, Time, Value, Tags);
        Last when Time < Last ->
            {error, {out_of_order, Time, Last}, Book};
        _ ->
            write_sized(Book, Time, Value, Tags)
    end.

write_sized(Book, Time, Value, Tags) ->
    Size = book_storage_codec:line_size(Time, Value, Tags),
    PageBytes = Book#book.page_bytes,
    if
        Size > PageBytes ->
            {error, {line_too_large, Size, PageBytes}, Book};
        true ->
            write_flow(Book, Time, Value, Tags, Size)
    end.

write_flow(Book0, Time, Value, Tags, Size) ->
    case maybe_retry_discard(Book0) of
        {error, Reason, Book} ->
            {error, Reason, Book};
        {ok, Book1} ->
            case maybe_turn(Book1, Size) of
                {error, Reason, Book} ->
                    {error, Reason, Book};
                {ok, Book2} ->
                    case maybe_discard_after_turn(Book2) of
                        {error, Reason, Book} ->
                            {error, Reason, Book};
                        {ok, Book3} ->
                            do_write_line(Book3, Time, Value, Tags, Size)
                    end
            end
    end.

maybe_retry_discard(#book{target_mod = Mod, target_state = State, max_pages = Max} = Book) ->
    PageCount = Book#book.page_count,
    case Mod:supports_discard(State) andalso is_integer(Max) andalso PageCount > Max of
        true ->
            discard_until(Book, Max);
        false ->
            {ok, Book}
    end.

maybe_turn(#book{active = Active, page_lines = PageLines, page_bytes = PageBytes} = Book, Size) ->
    Times = maps:get(times, Active),
    Bytes = maps:get(bytes, Active),
    NonEmpty = Times =/= [],
    Full = length(Times) >= PageLines orelse Bytes + Size > PageBytes,
    case NonEmpty andalso Full of
        true ->
            do_turn(Book);
        false ->
            {ok, Book}
    end.

maybe_discard_after_turn(#book{target_mod = Mod, target_state = State, max_pages = Max} = Book) ->
    PageCount = Book#book.page_count,
    case Mod:supports_discard(State) andalso is_integer(Max) andalso PageCount > Max of
        true ->
            discard_until(Book, Max);
        false ->
            {ok, Book}
    end.

do_turn(#book{target_mod = Mod, target_state = State, active = Active, active_page = Page} = Book) ->
    case Mod:turn_page(State, Active) of
        {ok, NewState, Completed, NewHandle} ->
            Book2 = Book#book{
                target_state = NewState,
                completed = Book#book.completed ++ [Completed],
                active = empty_table(),
                active_handle = NewHandle,
                active_page = Page + 1,
                next_page = Book#book.next_page + 1
            },
            {ok, recompute(Book2)};
        {error, Reason} ->
            {error, Reason, Book}
    end.

discard_until(#book{completed = Completed, max_pages = Max} = Book, Max) ->
    Need = Book#book.page_count - Max,
    case Need > 0 of
        true ->
            {Drop, Keep} = lists:split(min(Need, length(Completed)), Completed),
            Handles = [maps:get(handle, P) || P <- Drop],
            Mod = Book#book.target_mod,
            case Mod:discard_pages(Book#book.target_state, Handles) of
                {ok, NewState} ->
                    DroppedLines = lists:sum([maps:get(line_count, P) || P <- Drop]),
                    cache_evict(Book#book.meta, Handles),
                    Book2 = Book#book{
                        target_state = NewState,
                        completed = Keep,
                        line_count = Book#book.line_count - DroppedLines
                    },
                    {ok, recompute(Book2)};
                {error, Reason} ->
                    {error, Reason, Book}
            end;
        false ->
            {ok, Book}
    end.

do_write_line(#book{target_mod = Mod, target_state = State, active = Active} = Book,
              Time, Value, Tags, Size) ->
    case Mod:write_line(State, Time, Value, Tags) of
        {ok, NewState} ->
            Book2 = Book#book{
                target_state = NewState,
                active = add_line(Active, Time, Value, Tags, Size),
                last_time = Time
            },
            {ok, recompute(Book2)};
        {error, Reason} ->
            {error, Reason, Book}
    end.

run_query(Book, #{from := From, to := To, tags := Match, last := Last, limit := Limit}) ->
    case collect_matches(Book, From, To, Match) of
        {ok, Lines} ->
            {ok, apply_last_limit(Lines, Last, Limit)};
        Error ->
            Error
    end.

collect_matches(Book, From, To, Match) ->
    Pages = candidate_pages(Book),
    collect_matches(Pages, Book, From, To, Match, []).

collect_matches([], _Book, _From, _To, _Match, Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
collect_matches([Page | Rest], Book, From, To, Match, Acc) ->
    case page_can_match(Page, From, To, Match) of
        false ->
            collect_matches(Rest, Book, From, To, Match, Acc);
        true ->
            case page_lines(Book, Page) of
                {ok, Lines} ->
                    Kept = [L || L <- Lines, line_matches(L, From, To, Match)],
                    collect_matches(Rest, Book, From, To, Match, [Kept | Acc]);
                Error ->
                    Error
            end
    end.

candidate_pages(#book{completed = Comp, active = Active, active_page = N, active_handle = Handle}) ->
    ActiveTimes = maps:get(times, Active),
    Comp ++ case ActiveTimes of
        [] ->
            [];
        _ ->
            [#{
                handle => Handle,
                page => N,
                first_time => hd(ActiveTimes),
                last_time => lists:last(ActiveTimes),
                line_count => length(ActiveTimes),
                tag_values => tag_values(Active),
                active => true
            }]
    end.

page_can_match(Page, From, To, Match) ->
    First = maps:get(first_time, Page),
    Last = maps:get(last_time, Page),
    TimeOk =
        (From =:= beginning orelse Last >= From) andalso
        (To =:= latest orelse First =< To),
    TimeOk andalso tags_can_match(maps:get(tag_values, Page), Match).

tags_can_match(_TagValues, Match) when map_size(Match) =:= 0 ->
    true;
tags_can_match(TagValues, Match) ->
    maps:fold(
        fun
            (_K, [], Acc) ->
                Acc andalso false;
            (K, Spec, Acc) when is_list(Spec) ->
                Acc andalso case maps:find(K, TagValues) of
                    {ok, Vs} ->
                        lists:any(fun(S) -> lists:member(S, Vs) end, Spec);
                    error ->
                        false
                end;
            (K, V, Acc) when is_binary(V) ->
                Acc andalso case maps:find(K, TagValues) of
                    {ok, Vs} ->
                        lists:member(V, Vs);
                    error ->
                        false
                end
        end,
        true,
        Match
    ).

line_matches(#{time := Time, tags := Tags}, From, To, Match) ->
    TimeOk =
        (From =:= beginning orelse Time >= From) andalso
        (To =:= latest orelse Time =< To),
    TimeOk andalso line_tags_match(Tags, Match).

line_tags_match(_Tags, Match) when map_size(Match) =:= 0 ->
    true;
line_tags_match(Tags, Match) ->
    maps:fold(
        fun
            (_K, [], Acc) ->
                Acc andalso false;
            (K, Spec, Acc) when is_list(Spec) ->
                Acc andalso case maps:find(K, Tags) of
                    {ok, V} ->
                        lists:member(V, Spec);
                    error ->
                        false
                end;
            (K, V, Acc) when is_binary(V) ->
                Acc andalso maps:get(K, Tags, undefined) =:= V
        end,
        true,
        Match
    ).

page_lines(#book{active_handle = AH, target_mod = Mod, target_state = State, meta = Meta} = Book, Page) ->
    Handle = maps:get(handle, Page),
    LineCount = maps:get(line_count, Page),
    case Handle =:= AH of
        true ->
            Mod:read_lines(State, Handle, 1, LineCount);
        false ->
            case cache_get(Meta, Handle) of
                {ok, Lines} ->
                    {ok, Lines};
                miss ->
                    case Mod:read_lines(State, Handle, 1, LineCount) of
                        {ok, Lines} ->
                            cache_put(Meta, Handle, Lines, Book#book.cache_pages),
                            {ok, Lines};
                        Error ->
                            Error
                    end
            end
    end.

apply_last_limit(_Lines, 0, _Limit) ->
    [];
apply_last_limit(Lines, undefined, Limit) ->
    lists:sublist(Lines, Limit);
apply_last_limit(Lines, Last, undefined) ->
    keep_last(Lines, Last);
apply_last_limit(Lines, Last, Limit) ->
    keep_last(Lines, min(Last, Limit)).

keep_last(Lines, N) ->
    Len = length(Lines),
    if
        Len =< N ->
            Lines;
        true ->
            lists:nthtail(Len - N, Lines)
    end.

book_info(#book{} = Book) ->
    Pages = [completed_info(P) || P <- Book#book.completed] ++ active_info_list(Book),
    #{
        target_kind => Book#book.target_kind,
        page_count => Book#book.page_count,
        line_count => Book#book.line_count,
        first_time => Book#book.first_time,
        last_time => Book#book.last_time,
        pages => Pages
    }.

completed_info(#{
    page := Page,
    first_time := First,
    last_time := Last,
    line_count := Count,
    tag_values := TV
}) ->
    #{
        page => Page,
        first_time => First,
        last_time => Last,
        line_count => Count,
        tag_values => TV
    }.

active_info_list(#book{active = Active, active_page = N}) ->
    Times = maps:get(times, Active),
    case Times of
        [] ->
            [];
        _ ->
            [#{
                page => N,
                first_time => hd(Times),
                last_time => lists:last(Times),
                line_count => length(Times),
                tag_values => tag_values(Active)
            }]
    end.

recompute(#book{completed = Comp, active = Active} = Book) ->
    ActiveN = length(maps:get(times, Active)),
    CompLines = lists:sum([maps:get(line_count, P) || P <- Comp]),
    LineCount = CompLines + ActiveN,
    PageCount = length(Comp) + 1,
    {First, Last} = case LineCount of
        0 ->
            {empty, empty};
        _ ->
            case Comp of
                [H | _] when ActiveN =:= 0 ->
                    {maps:get(first_time, H), maps:get(last_time, lists:last(Comp))};
                [H | _] ->
                    {maps:get(first_time, H), lists:last(maps:get(times, Active))};
                [] ->
                    Times = maps:get(times, Active),
                    {hd(Times), lists:last(Times)}
            end
    end,
    Book#book{
        page_count = PageCount,
        line_count = LineCount,
        first_time = First,
        last_time = Last
    }.

parse_target(memory) ->
    {ok, memory, book_target_memory, []};
parse_target({file, Path}) when is_list(Path); is_binary(Path) ->
    {ok, file, book_target_file, Path};
parse_target({folder, Path}) when is_list(Path); is_binary(Path) ->
    {ok, folder, book_target_folder, Path};
parse_target({Mod, Args}) when is_atom(Mod) ->
    {ok, custom, Mod, Args};
parse_target(Other) ->
    {error, {invalid_target, Other}}.

parse_options(Options) when is_list(Options) ->
    parse_options(
        Options,
        #{
            page_lines => 1000,
            page_bytes => 1048576,
            max_pages => infinity,
            cache_pages => 1,
            sync => delayed,
            max_pages_set => false
        }
    );
parse_options(Other) ->
    {error, {invalid_option, Other}}.

parse_options([], Acc) ->
    {ok, Acc};
parse_options([{page_lines, N} | Rest], Acc) when is_integer(N), N > 0 ->
    parse_options(Rest, Acc#{page_lines => N});
parse_options([{page_bytes, N} | Rest], Acc) when is_integer(N), N > 0 ->
    parse_options(Rest, Acc#{page_bytes => N});
parse_options([{max_pages, infinity} | Rest], Acc) ->
    parse_options(Rest, Acc#{max_pages => infinity, max_pages_set => true});
parse_options([{max_pages, N} | Rest], Acc) when is_integer(N), N > 0 ->
    parse_options(Rest, Acc#{max_pages => N, max_pages_set => true});
parse_options([{sync, Mode} | Rest], Acc)
  when Mode =:= none; Mode =:= delayed; Mode =:= every_write ->
    parse_options(Rest, Acc#{sync => Mode});
parse_options([{cache_pages, N} | Rest], Acc) when is_integer(N), N > 0 ->
    parse_options(Rest, Acc#{cache_pages => N});
parse_options([{Key, _} = Term | _], _Acc) when is_atom(Key) ->
    case known_option_key(Key) of
        true ->
            {error, {invalid_option, Term}};
        false ->
            {error, {unknown_option, Term}}
    end;
parse_options([Term | _], _Acc) ->
    {error, {unknown_option, Term}}.

known_option_key(page_lines) -> true;
known_option_key(page_bytes) -> true;
known_option_key(max_pages) -> true;
known_option_key(sync) -> true;
known_option_key(cache_pages) -> true;
known_option_key(_) -> false.

parse_query(Query) ->
    Last0 = maps:get(last, Query, undefined),
    Limit0 = maps:get(limit, Query, undefined),
    case {Last0, Limit0} of
        {L, _} when is_integer(L), L > 1000000 ->
            {error, {invalid_option, {last, L}}};
        {_, L} when is_integer(L), L > 1000000 ->
            {error, {invalid_option, {limit, L}}};
        {L, _} when L =/= undefined, not is_integer(L) orelse L < 0 ->
            {error, {invalid_option, {last, L}}};
        {_, L} when L =/= undefined, not (is_integer(L) andalso L > 0) ->
            {error, {invalid_option, {limit, L}}};
        _ ->
            From = maps:get(from, Query, beginning),
            To = maps:get(to, Query, latest),
            Tags = maps:get(tags, Query, #{}),
            case valid_from_to(From, To) andalso is_map(Tags) of
                false ->
                    {error, {invalid_option, Query}};
                true ->
                    Limit = case {Last0, Limit0} of
                        {undefined, undefined} ->
                            10000;
                        {0, undefined} ->
                            undefined;
                        {L, undefined} when is_integer(L) ->
                            L;
                        {_, L} ->
                            L
                    end,
                    {ok, #{from => From, to => To, tags => Tags, last => Last0, limit => Limit}}
            end
    end.

valid_from_to(beginning, _) ->
    true;
valid_from_to(latest, _) ->
    false;
valid_from_to(From, latest) when is_integer(From), From >= 0 ->
    true;
valid_from_to(From, To)
  when is_integer(From), From >= 0, is_integer(To), To >= 0 ->
    true;
valid_from_to(_, _) ->
    false.

is_tags(Tags) when is_map(Tags) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc andalso is_atom(K) andalso is_binary(V)
        end,
        true,
        Tags
    );
is_tags(_) ->
    false.

empty_table() ->
    #{times => [], tags => #{}, bytes => 0}.

add_line(Table, Time, _Value, Tags, Size) ->
    Times = maps:get(times, Table),
    LineNo = length(Times) + 1,
    TagMap = maps:fold(
        fun(K, V, Acc) ->
            Inner = maps:get(K, Acc, #{}),
            Ns = maps:get(V, Inner, []),
            Acc#{K => Inner#{V => Ns ++ [LineNo]}}
        end,
        maps:get(tags, Table),
        Tags
    ),
    Table#{
        times := Times ++ [Time],
        tags := TagMap,
        bytes := maps:get(bytes, Table) + Size
    }.

tag_values(#{tags := Tags}) ->
    maps:map(fun(_K, Inner) -> maps:keys(Inner) end, Tags).

new_meta() ->
    Tid = ets:new(?MODULE, [set, public]),
    ets:insert(Tid, {closed, false}),
    ets:insert(Tid, {cache, []}),
    Tid.

is_closed(Meta) ->
    try ets:lookup(Meta, closed) of
        [{closed, true}] ->
            true;
        [{closed, false}] ->
            false;
        [] ->
            true
    catch
        error:badarg ->
            true
    end.

mark_closed(Meta) ->
    try
        ets:insert(Meta, {closed, true}),
        ets:delete(Meta),
        ok
    catch
        error:badarg ->
            ok
    end.

cache_get(Meta, Handle) ->
    try ets:lookup(Meta, cache) of
        [{cache, Cache}] ->
            case lists:keyfind(Handle, 1, Cache) of
                {Handle, Lines} ->
                    {ok, Lines};
                false ->
                    miss
            end;
        _ ->
            miss
    catch
        error:badarg ->
            miss
    end.

cache_put(Meta, Handle, Lines, N) ->
    try ets:lookup(Meta, cache) of
        [{cache, Cache}] ->
            Cache1 = [{Handle, Lines} | lists:keydelete(Handle, 1, Cache)],
            ets:insert(Meta, {cache, lists:sublist(Cache1, N)}),
            ok;
        _ ->
            ok
    catch
        error:badarg ->
            ok
    end.

cache_evict(Meta, Handles) ->
    try ets:lookup(Meta, cache) of
        [{cache, Cache}] ->
            ets:insert(Meta, {cache, [E || {H, _} = E <- Cache, not lists:member(H, Handles)]}),
            ok;
        _ ->
            ok
    catch
        error:badarg ->
            ok
    end.
