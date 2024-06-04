%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_storage_tests).
-include_lib("eunit/include/eunit.hrl").

open_write_query_close_test() ->
    lists:foreach(
        fun(Target) ->
            {ok, B0} = book_storage:open(Target),
            {ok, B1} = book_storage:write(B0, 1, <<"a">>, #{k => <<"v">>}),
            {ok, B2} = book_storage:write(B1, 2, <<"b">>, #{k => <<"w">>}),
            {ok, Lines} = book_storage:query(B2, #{}),
            [#{time := 1, value := <<"a">>, tags := #{k := <<"v">>}},
             #{time := 2, value := <<"b">>, tags := #{k := <<"w">>}}] = Lines,
            ok = book_storage:close(B2)
        end,
        [memory, {file, tmp_file()}, {folder, tmp_dir()}]
    ).

equal_timestamps_and_out_of_order_test() ->
    {ok, B0} = book_storage:open(memory),
    {ok, B1} = book_storage:write(B0, 5, <<"a">>),
    {ok, B2} = book_storage:write(B1, 5, <<"b">>),
    {error, {out_of_order, 4, 5}, B2} = book_storage:write(B2, 4, <<"c">>),
    {ok, [#{value := <<"a">>}, #{value := <<"b">>}]} = book_storage:query(B2, #{}),
    ok = book_storage:close(B2).

empty_book_info_test() ->
    {ok, B} = book_storage:open(memory),
    {ok, []} = book_storage:query(B, #{}),
    {ok, Info} = book_storage:info(B),
    1 = maps:get(page_count, Info),
    [] = maps:get(pages, Info),
    0 = maps:get(line_count, Info),
    empty = maps:get(first_time, Info),
    empty = maps:get(last_time, Info),
    ok = book_storage:close(B).

tag_and_or_test() ->
    {ok, B0} = book_storage:open(memory),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>, #{k => <<"a">>, extra => <<"x">>}),
    {ok, B2} = book_storage:write(B1, 2, <<"b">>, #{k => <<"b">>}),
    {ok, Both} = book_storage:query(B2, #{tags => #{k => [<<"a">>, <<"b">>]}}),
    2 = length(Both),
    {ok, [#{value := <<"a">>}]} = book_storage:query(B2, #{tags => #{k => <<"a">>}}),
    {ok, []} = book_storage:query(B2, #{tags => #{missing => <<"z">>}}),
    {ok, []} = book_storage:query(B2, #{tags => #{k => []}}),
    {ok, [#{value := <<"a">>}]} = book_storage:query(B2, #{tags => #{k => <<"a">>, extra => <<"x">>}}),
    ok = book_storage:close(B2).

opaque_values_test() ->
    {ok, B0} = book_storage:open(memory),
    {ok, B1} = book_storage:write(B0, 1, <<>>),
    {ok, B2} = book_storage:write(B1, 2, <<0, 1, 255, 9>>),
    {ok, [#{value := <<>>}, #{value := <<0, 1, 255, 9>>}]} = book_storage:query(B2, #{}),
    ok = book_storage:close(B2).

page_turn_lines_test() ->
    lists:foreach(
        fun(Target) ->
            {ok, B0} = book_storage:open(Target, [{page_lines, 2}]),
            {ok, B1} = book_storage:write(B0, 1, <<"a">>),
            {ok, B2} = book_storage:write(B1, 2, <<"b">>),
            {ok, Info1} = book_storage:info(B2),
            1 = maps:get(page_count, Info1),
            {ok, B3} = book_storage:write(B2, 3, <<"c">>),
            {ok, Info2} = book_storage:info(B3),
            2 = maps:get(page_count, Info2),
            [#{line_count := 2}, #{line_count := 1}] = maps:get(pages, Info2),
            {ok, Three} = book_storage:query(B3, #{}),
            3 = length(Three),
            ok = book_storage:close(B3)
        end,
        [memory, {file, tmp_file()}, {folder, tmp_dir()}]
    ).

byte_turn_test() ->
    T = 1,
    V = <<"a">>,
    Tags = #{},
    Size = book_storage_codec:line_size(T, V, Tags),
    lists:foreach(
        fun(Target) ->
            {ok, B0} = book_storage:open(Target, [{page_bytes, Size}]),
            {ok, B1} = book_storage:write(B0, T, V, Tags),
            {ok, Info1} = book_storage:info(B1),
            1 = maps:get(page_count, Info1),
            {ok, B2} = book_storage:write(B1, T + 1, V, Tags),
            {ok, Info2} = book_storage:info(B2),
            2 = maps:get(page_count, Info2),
            {error, {line_too_large, _, Size}, B2} =
                book_storage:write(B2, T + 2, <<"aa">>, Tags),
            ok = book_storage:close(B2)
        end,
        [memory, {file, tmp_file()}, {folder, tmp_dir()}]
    ).

line_too_large_test() ->
    {ok, B0} = book_storage:open(memory, [{page_bytes, 16}]),
    {error, {line_too_large, Size, 16}, B0} =
        book_storage:write(B0, 1, binary:copy(<<"x">>, 100)),
    true = Size > 16,
    {ok, []} = book_storage:query(B0, #{}),
    ok = book_storage:close(B0).

retention_memory_folder_test() ->
    lists:foreach(
        fun(Target) ->
            {ok, B0} = book_storage:open(Target, [{max_pages, 2}, {page_lines, 1}]),
            {ok, B1} = book_storage:write(B0, 1, <<"a">>),
            {ok, B2} = book_storage:write(B1, 2, <<"b">>),
            {ok, B3} = book_storage:write(B2, 3, <<"c">>),
            {ok, Lines} = book_storage:query(B3, #{}),
            [#{value := <<"b">>}, #{value := <<"c">>}] = Lines,
            {ok, Info} = book_storage:info(B3),
            2 = maps:get(page_count, Info),
            ok = book_storage:close(B3)
        end,
        [memory, {folder, tmp_dir()}]
    ),
    {ok, B0} = book_storage:open(memory, [{max_pages, 1}, {page_lines, 1}]),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    {ok, B2} = book_storage:write(B1, 2, <<"b">>),
    {ok, [#{value := <<"b">>}]} = book_storage:query(B2, #{}),
    ok = book_storage:close(B2).

file_rejects_max_pages_test() ->
    File = tmp_file(),
    {error, {unsupported, max_pages, file}} =
        book_storage:open({file, File}, [{max_pages, 2}]),
    {error, {unsupported, max_pages, file}} =
        book_storage:open({file, File}, [{max_pages, infinity}]),
    {ok, B} = book_storage:open({file, File}, []),
    ok = book_storage:close(B).

reopen_file_folder_test() ->
    lists:foreach(
        fun({Kind, Path}) ->
            Target = {Kind, Path},
            {ok, B0} = book_storage:open(Target),
            {ok, B1} = book_storage:write(B0, 10, <<"a">>, #{t => <<"x">>}),
            {ok, B2} = book_storage:write(B1, 20, <<"b">>),
            ok = book_storage:close(B2),
            {ok, B3} = book_storage:open(Target),
            {ok, [#{value := <<"a">>}, #{value := <<"b">>}]} = book_storage:query(B3, #{}),
            {ok, B4} = book_storage:write(B3, 30, <<"c">>),
            {error, {out_of_order, 15, 30}, B4} = book_storage:write(B4, 15, <<"z">>),
            {ok, Three} = book_storage:query(B4, #{}),
            3 = length(Three),
            ok = book_storage:close(B4)
        end,
        [{file, tmp_file()}, {folder, tmp_dir()}]
    ).

reopen_after_page_turn_test() ->
    lists:foreach(
        fun({Kind, Path}) ->
            Target = {Kind, Path},
            {ok, B0} = book_storage:open(Target, [{page_lines, 1}]),
            {ok, B1} = book_storage:write(B0, 1, <<"a">>),
            {ok, B2} = book_storage:write(B1, 2, <<"b">>),
            ok = book_storage:close(B2),
            {ok, B3} = book_storage:open(Target),
            {ok, [#{value := <<"a">>}, #{value := <<"b">>}]} = book_storage:query(B3, #{}),
            {ok, Info} = book_storage:info(B3),
            true = maps:get(page_count, Info) >= 2,
            ok = book_storage:close(B3)
        end,
        [{file, tmp_file()}, {folder, tmp_dir()}]
    ).

wrong_magic_test() ->
    File = tmp_file(),
    ok = file:write_file(File, <<"notabook">>),
    {error, {not_a_book, File}} = book_storage:open({file, File}).

truncated_active_line_test() ->
    File = tmp_file(),
    {ok, B0} = book_storage:open({file, File}, [{sync, every_write}]),
    {ok, B1} = book_storage:write(B0, 1, <<"hello-world">>),
    ok = book_storage:close(B1),
    {ok, Bin} = file:read_file(File),
    Trunc = binary:part(Bin, 0, byte_size(Bin) - 3),
    ok = file:write_file(File, Trunc),
    {error, {corrupt, {active_page, truncated_line}}} = book_storage:open({file, File}).

close_then_write_test() ->
    {ok, B0} = book_storage:open(memory),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    ok = book_storage:close(B1),
    {error, closed, B1} = book_storage:write(B1, 2, <<"b">>),
    {error, closed} = book_storage:query(B1, #{}),
    ok = book_storage:close(B1).

last_and_limit_test() ->
    {ok, B0} = book_storage:open(memory),
    {ok, B1} = write_n(B0, 5),
    {ok, Last2} = book_storage:query(B1, #{last => 2}),
    [#{time := 4}, #{time := 5}] = Last2,
    {ok, []} = book_storage:query(B1, #{last => 0}),
    {ok, Min} = book_storage:query(B1, #{last => 4, limit => 2}),
    [#{time := 4}, #{time := 5}] = Min,
    {error, {invalid_option, {last, 1000001}}} =
        book_storage:query(B1, #{last => 1000001}),
    {error, {invalid_option, {limit, 1000001}}} =
        book_storage:query(B1, #{limit => 1000001}),
    ok = book_storage:close(B1).

time_window_test() ->
    {ok, B0} = book_storage:open(memory),
    {ok, B1} = write_n(B0, 5),
    {ok, Mid} = book_storage:query(B1, #{from => 2, to => 4}),
    [#{time := 2}, #{time := 3}, #{time := 4}] = Mid,
    ok = book_storage:close(B1).

sync_memory_and_file_test() ->
    {ok, M} = book_storage:open(memory),
    ok = book_storage:sync(M),
    ok = book_storage:close(M),
    File = tmp_file(),
    {ok, F0} = book_storage:open({file, File}),
    {ok, F1} = book_storage:write(F0, 1, <<"a">>),
    ok = book_storage:sync(F1),
    ok = book_storage:close(F1).

complete_page_no_active_header_test() ->
    File = tmp_file(),
    {ok, B0} = book_storage:open({file, File}, [{page_lines, 1}, {sync, every_write}]),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    {ok, B2} = book_storage:write(B1, 2, <<"b">>),
    ok = book_storage:close(B2),
    {ok, Bin} = file:read_file(File),
    HeaderSize = book_storage_codec:page_header_size(),
    Trunc = binary:part(Bin, 0, find_second_page_offset(Bin)),
    true = byte_size(Trunc) < byte_size(Bin),
    true = byte_size(Trunc) >= 8 + HeaderSize,
    ok = file:write_file(File, Trunc),
    {ok, B3} = book_storage:open({file, File}),
    {ok, [#{value := <<"a">>}]} = book_storage:query(B3, #{}),
    {ok, Info} = book_storage:info(B3),
    true = maps:get(page_count, Info) >= 1,
    ok = book_storage:close(B3).

folder_listing_wins_test() ->
    Dir = tmp_dir(),
    {ok, B0} = book_storage:open({folder, Dir}, [{page_lines, 1}]),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    {ok, B2} = book_storage:write(B1, 2, <<"b">>),
    ok = book_storage:close(B2),
    BookPath = filename:join(Dir, "BOOK"),
    ok = file:delete(BookPath),
    {ok, B3} = book_storage:open({folder, Dir}),
    {ok, Two} = book_storage:query(B3, #{}),
    2 = length(Two),
    true = filelib:is_file(BookPath),
    ok = book_storage:close(B3),
    Dir2 = tmp_dir(),
    {ok, C0} = book_storage:open({folder, Dir2}, [{max_pages, 1}, {page_lines, 1}]),
    {ok, C1} = book_storage:write(C0, 1, <<"a">>),
    {ok, C2} = book_storage:write(C1, 2, <<"b">>),
    ok = book_storage:close(C2),
    {ok, Names} = file:list_dir(Dir2),
    PageFiles = [N || N <- Names, book_storage_codec:parse_page_filename(N) =/= error],
    Stale = filename:join(Dir2, "BOOK"),
    ok = file:write_file(Stale, <<"stale">>),
    {ok, C3} = book_storage:open({folder, Dir2}),
    {ok, [#{value := <<"b">>}]} = book_storage:query(C3, #{}),
    1 = length(PageFiles),
    ok = book_storage:close(C3).

folder_extra_page_recovered_test() ->
    Dir = tmp_dir(),
    {ok, B0} = book_storage:open({folder, Dir}, [{page_lines, 1}]),
    {ok, B1} = book_storage:write(B0, 1, <<"a">>),
    ok = book_storage:close(B1),
    Src = filename:join(Dir, book_storage_codec:page_filename(1)),
    {ok, Bin} = file:read_file(Src),
    Dst = filename:join(Dir, book_storage_codec:page_filename(3)),
    ok = file:write_file(Dst, Bin),
    {ok, B2} = book_storage:open({folder, Dir}),
    {ok, Lines} = book_storage:query(B2, #{}),
    true = length(Lines) >= 1,
    ok = book_storage:close(B2).

write_n(Book, 0) ->
    {ok, Book};
write_n(Book, N) ->
    {ok, Book1} = write_n(Book, N - 1),
    book_storage:write(Book1, N, <<(N)>>).

tmp_file() ->
    Dir = tmp_dir(),
    filename:join(Dir, "book.bin").

tmp_dir() ->
    string:chomp(os:cmd("mktemp -d")).

find_second_page_offset(Bin) ->
    <<_Hdr:8/binary, Rest/binary>> = Bin,
    find_second_page_offset(Rest, 8).

find_second_page_offset(<<1:8, _:24, TrailerOffset:64/big, _/binary>> = Rest, Base) ->
    TrailerPos = TrailerOffset,
    <<_Skip:TrailerPos/binary, Trailer/binary>> = Rest,
    case book_storage_codec:decode_trailer(Trailer) of
        {ok, _Map, After} ->
            Base + TrailerPos + (byte_size(Trailer) - byte_size(After));
        _ ->
            Base + byte_size(Rest)
    end;
find_second_page_offset(_, Base) ->
    Base.
