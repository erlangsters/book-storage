%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_target_mock).
-behaviour(book_target).

-export([
    open/2,
    close/1,
    write_line/4,
    turn_page/2,
    read_lines/4,
    discard_pages/2,
    supports_discard/1,
    sync/1,
    calls/1
]).

-record(mock, {
    log :: pid(),
    pages = #{} :: #{pos_integer() => [book_storage:line()]},
    active = 1 :: pos_integer(),
    next_page = 2 :: pos_integer(),
    fail_discard :: atomics:atomics_ref()
}).

open({Log, FailDiscard}, _Info) ->
    Log ! {call, open},
    FailA = atomics:new(1, []),
    atomics:put(FailA, 1, FailDiscard),
    State = #mock{
        log = Log,
        pages = #{1 => []},
        active = 1,
        next_page = 2,
        fail_discard = FailA
    },
    Recovered = #{
        completed => [],
        active => #{times => [], tags => #{}, bytes => 0},
        active_handle => 1,
        next_page => 2
    },
    {ok, State, Recovered};
open(Log, Info) when is_pid(Log) ->
    open({Log, 0}, Info).

close(#mock{log = Log}) ->
    Log ! {call, close},
    ok.

write_line(#mock{log = Log, pages = Pages, active = Active} = State, Time, Value, Tags) ->
    Log ! {call, write_line},
    Line = #{time => Time, value => Value, tags => Tags},
    ActiveLines = maps:get(Active, Pages),
    {ok, State#mock{pages = Pages#{Active => ActiveLines ++ [Line]}}}.

turn_page(#mock{log = Log, pages = Pages, active = Active, next_page = Next} = State, Table) ->
    Log ! {call, turn_page},
    Times = maps:get(times, Table),
    Tags = maps:get(tags, Table),
    Completed = #{
        handle => Active,
        page => Active,
        first_time => hd(Times),
        last_time => lists:last(Times),
        line_count => length(Times),
        tag_values => maps:map(fun(_K, Inner) -> maps:keys(Inner) end, Tags)
    },
    NewState = State#mock{
        pages = Pages#{Next => []},
        active = Next,
        next_page = Next + 1
    },
    {ok, NewState, Completed, Next}.

read_lines(#mock{log = Log, pages = Pages}, Handle, From, To) ->
    Log ! {call, read_lines},
    Lines = maps:get(Handle, Pages),
    {ok, lists:sublist(Lines, From, To - From + 1)}.

discard_pages(#mock{log = Log, fail_discard = FailA, pages = Pages} = State, Handles) ->
    Log ! {call, discard_pages},
    case atomics:get(FailA, 1) of
        N when N > 0 ->
            atomics:sub(FailA, 1, 1),
            {error, {io, eacces}};
        _ ->
            NewPages = lists:foldl(fun(H, Acc) -> maps:remove(H, Acc) end, Pages, Handles),
            {ok, State#mock{pages = NewPages}}
    end.

supports_discard(#mock{}) ->
    true.

sync(#mock{log = Log}) ->
    Log ! {call, sync},
    ok.

calls(Log) ->
    calls(Log, []).

calls(Log, Acc) ->
    receive
        {call, Name} ->
            calls(Log, [Name | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
