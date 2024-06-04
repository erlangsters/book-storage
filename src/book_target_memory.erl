%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_target_memory).
-moduledoc """
In-memory book-storage backend.

Pages are lists of `line()` terms. Byte accounting still uses the canonical
encoded line size so `{page_bytes, N}` matches file and folder.
""".
-behaviour(book_target).

-export([
    open/2,
    close/1,
    write_line/4,
    turn_page/2,
    read_lines/4,
    discard_pages/2,
    supports_discard/1,
    sync/1
]).

-record(mem, {
    pages = #{} :: #{pos_integer() => [book_storage:line()]},
    active = 1 :: pos_integer(),
    next_page = 2 :: pos_integer()
}).

-spec open(term(), book_target:open_info()) ->
    {ok, book_target:target_state(), book_target:recovered()}.
open(_Args, _Info) ->
    State = #mem{pages = #{1 => []}, active = 1, next_page = 2},
    Recovered = #{
        completed => [],
        active => empty_table(),
        active_handle => 1,
        next_page => 2
    },
    {ok, State, Recovered}.

-spec close(book_target:target_state()) -> ok.
close(_State) ->
    ok.

-spec write_line(
    book_target:target_state(),
    book_storage:time(),
    book_storage:value(),
    book_storage:tags()
) -> {ok, book_target:target_state()}.
write_line(#mem{pages = Pages, active = Active} = State, Time, Value, Tags) ->
    Line = #{time => Time, value => Value, tags => Tags},
    ActiveLines = maps:get(Active, Pages),
    {ok, State#mem{pages = Pages#{Active => ActiveLines ++ [Line]}}}.

-spec turn_page(book_target:target_state(), book_target:page_table()) ->
    {ok, book_target:target_state(), book_target:completed_page(), pos_integer()}.
turn_page(#mem{pages = Pages, active = Active, next_page = Next} = State, Table) ->
    Completed = completed_from_table(Active, Table),
    NewPages = Pages#{Next => []},
    NewState = State#mem{pages = NewPages, active = Next, next_page = Next + 1},
    {ok, NewState, Completed, Next}.

-spec read_lines(
    book_target:target_state(),
    pos_integer(),
    pos_integer(),
    pos_integer()
) -> {ok, [book_storage:line()]} | {error, book_storage:reason()}.
read_lines(#mem{pages = Pages}, Handle, From, To) ->
    case maps:find(Handle, Pages) of
        {ok, Lines} ->
            Len = length(Lines),
            if
                From < 1 orelse To < From orelse To > Len ->
                    {error, {invalid_option, {range, From, To}}};
                true ->
                    {ok, lists:sublist(Lines, From, To - From + 1)}
            end;
        error ->
            {error, {io, {unknown_page, Handle}}}
    end.

-spec discard_pages(book_target:target_state(), [pos_integer()]) ->
    {ok, book_target:target_state()}.
discard_pages(#mem{pages = Pages} = State, Handles) ->
    NewPages = lists:foldl(fun(H, Acc) -> maps:remove(H, Acc) end, Pages, Handles),
    {ok, State#mem{pages = NewPages}}.

-spec supports_discard(book_target:target_state()) -> true.
supports_discard(_State) ->
    true.

-spec sync(book_target:target_state()) -> ok.
sync(_State) ->
    ok.

empty_table() ->
    #{times => [], tags => #{}, bytes => 0}.

completed_from_table(Page, #{times := Times, tags := Tags}) ->
    #{
        handle => Page,
        page => Page,
        first_time => hd(Times),
        last_time => lists:last(Times),
        line_count => length(Times),
        tag_values => maps:map(fun(_K, Inner) -> maps:keys(Inner) end, Tags)
    }.
