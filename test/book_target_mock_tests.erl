%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_target_mock_tests).
-include_lib("eunit/include/eunit.hrl").

callback_order_retention_test() ->
    Log = self(),
    {ok, B0} = book_storage:open({book_target_mock, Log}, [{page_lines, 1}, {max_pages, 1}]),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    {ok, B2} = book_storage:write(B1, 2, <<"b">>),
    {ok, [#{value := <<"b">>}]} = book_storage:query(B2, #{}),
    ok = book_storage:close(B2),
    Calls = drain_calls(),
    [open, write_line, turn_page, discard_pages, write_line, read_lines, close] = Calls.

callback_order_no_retention_test() ->
    Log = self(),
    {ok, B0} = book_storage:open({book_target_mock, Log}, [{page_lines, 2}]),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    {ok, B2} = book_storage:write(B1, 2, <<"b">>),
    {ok, B3} = book_storage:write(B2, 3, <<"c">>),
    {ok, Three} = book_storage:query(B3, #{}),
    3 = length(Three),
    ok = book_storage:close(B3),
    Calls = drain_calls(),
    [open, write_line, write_line, turn_page, write_line, read_lines, read_lines, close] = Calls.

discard_retry_test() ->
    Log = self(),
    {ok, B0} = book_storage:open(
        {book_target_mock, {Log, 1}},
        [{page_lines, 1}, {max_pages, 1}]
    ),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    {error, {io, eacces}, B2} = book_storage:write(B1, 2, <<"b">>),
    {ok, B3} = book_storage:write(B2, 2, <<"b">>),
    {ok, [#{value := <<"b">>}]} = book_storage:query(B3, #{}),
    ok = book_storage:close(B3),
    Calls = drain_calls(),
    true = length([D || D <- Calls, D =:= discard_pages]) >= 2.

drain_calls() ->
    drain_calls([]).

drain_calls(Acc) ->
    receive
        {call, Name} ->
            drain_calls(Acc ++ [Name])
    after 0 ->
        Acc
    end.
