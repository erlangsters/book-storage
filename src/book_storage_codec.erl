%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_storage_codec).
-moduledoc false.

-export([
    magic/0,
    format_version/0,
    file_header_size/0,
    page_header_size/0,
    encode_term/1,
    decode_term/1,
    encode_line/3,
    decode_line/1,
    line_size/3,
    encode_file_header/0,
    decode_file_header/1,
    encode_page_header/2,
    decode_page_header/1,
    encode_trailer/1,
    decode_trailer/1,
    trailer_size/1,
    read_line/1,
    write_line/4,
    encode_book_index/1,
    decode_book_index/1,
    page_filename/1,
    parse_page_filename/1
]).

-define(MAGIC, 16#A1B2C3D4).
-define(VERSION, 1).
-define(FILE_HEADER_SIZE, 8).
-define(PAGE_HEADER_SIZE, 12).
-define(TRAILER_FIXED, 28).

-spec magic() -> integer().
magic() ->
    ?MAGIC.

-spec format_version() -> integer().
format_version() ->
    ?VERSION.

-spec file_header_size() -> 8.
file_header_size() ->
    ?FILE_HEADER_SIZE.

-spec page_header_size() -> 12.
page_header_size() ->
    ?PAGE_HEADER_SIZE.

-spec encode_term(term()) -> binary().
encode_term(Term) ->
    term_to_binary(Term, [{minor_version, 1}]).

-spec decode_term(binary()) -> {ok, term()} | {error, term()}.
decode_term(Bin) when is_binary(Bin) ->
    try binary_to_term(Bin) of
        Term ->
            {ok, Term}
    catch
        _:_ ->
            {error, bad_term}
    end.

-spec encode_line(book_storage:time(), book_storage:value(), book_storage:tags()) ->
    binary().
encode_line(Time, Value, Tags) ->
    TagsBin = encode_term(Tags),
    <<Time:64/big, (byte_size(Value)):32/big, Value/binary,
      (byte_size(TagsBin)):32/big, TagsBin/binary>>.

-spec line_size(book_storage:time(), book_storage:value(), book_storage:tags()) ->
    pos_integer().
line_size(Time, Value, Tags) ->
    byte_size(encode_line(Time, Value, Tags)).

-spec decode_line(binary()) ->
    {ok, book_storage:line(), binary()} | {error, term()}.
decode_line(<<Time:64/big, ValueLen:32/big, Value:ValueLen/binary,
              TagsLen:32/big, TagsBin:TagsLen/binary, Rest/binary>>) ->
    case decode_term(TagsBin) of
        {ok, Tags} when is_map(Tags) ->
            {ok, #{time => Time, value => Value, tags => Tags}, Rest};
        Other ->
            {error, Other}
    end;
decode_line(_) ->
    {error, truncated}.

-spec encode_file_header() -> binary().
encode_file_header() ->
    <<?MAGIC:32/big, ?VERSION:8, 0:24>>.

-spec decode_file_header(binary()) -> ok | {error, term()}.
decode_file_header(<<?MAGIC:32/big, ?VERSION:8, _:24>>) ->
    ok;
decode_file_header(<<?MAGIC:32/big, Version:8, _:24>>) ->
    {error, {unsupported_version, Version}};
decode_file_header(_) ->
    {error, bad_magic}.

-spec encode_page_header(0 | 1, non_neg_integer()) -> binary().
encode_page_header(Status, TrailerOffset) ->
    <<Status:8, 0:24, TrailerOffset:64/big>>.

-spec decode_page_header(binary()) ->
    {ok, 0 | 1, non_neg_integer()} | {error, term()}.
decode_page_header(<<Status:8, _:24, TrailerOffset:64/big>>)
  when Status =:= 0; Status =:= 1 ->
    {ok, Status, TrailerOffset};
decode_page_header(_) ->
    {error, bad_page_header}.

-spec encode_trailer(#{
    line_count := non_neg_integer(),
    byte_size := non_neg_integer(),
    first_time := book_storage:time() | empty,
    last_time := book_storage:time() | empty,
    tag_index := #{book_storage:tag_key() => [book_storage:tag_value()]}
}) -> binary().
encode_trailer(#{
    line_count := LineCount,
    byte_size := ByteSize,
    first_time := First,
    last_time := Last,
    tag_index := TagIndex
}) ->
    IndexBin = encode_term(TagIndex),
    First64 = time_or_zero(First),
    Last64 = time_or_zero(Last),
    <<LineCount:32/big, ByteSize:32/big, First64:64/big, Last64:64/big,
      (byte_size(IndexBin)):32/big, IndexBin/binary>>.

-spec trailer_size(binary()) -> pos_integer().
trailer_size(TrailerBin) ->
    byte_size(TrailerBin).

-spec decode_trailer(binary()) -> {ok, map(), binary()} | {error, term()}.
decode_trailer(<<LineCount:32/big, ByteSize:32/big, First:64/big, Last:64/big,
                 IndexLen:32/big, IndexBin:IndexLen/binary, Rest/binary>>) ->
    case decode_term(IndexBin) of
        {ok, TagIndex} when is_map(TagIndex) ->
            {ok, #{
                line_count => LineCount,
                byte_size => ByteSize,
                first_time => First,
                last_time => Last,
                tag_index => TagIndex
            }, Rest};
        Other ->
            {error, Other}
    end;
decode_trailer(_) ->
    {error, truncated_trailer}.

-spec read_line(file:io_device()) ->
    {ok, book_storage:line()} | eof | {error, truncated_line | term()}.
read_line(Device) ->
    case file:read(Device, 12) of
        eof ->
            eof;
        {ok, <<Time:64/big, ValueLen:32/big>>} ->
            case read_exact(Device, ValueLen) of
                {ok, Value} ->
                    case file:read(Device, 4) of
                        {ok, <<TagsLen:32/big>>} ->
                            case read_exact(Device, TagsLen) of
                                {ok, TagsBin} ->
                                    case decode_term(TagsBin) of
                                        {ok, Tags} when is_map(Tags) ->
                                            {ok, #{
                                                time => Time,
                                                value => Value,
                                                tags => Tags
                                            }};
                                        _ ->
                                            {error, truncated_line}
                                    end;
                                eof ->
                                    {error, truncated_line};
                                {error, _} ->
                                    {error, truncated_line}
                            end;
                        eof ->
                            {error, truncated_line};
                        {ok, _} ->
                            {error, truncated_line};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                eof ->
                    {error, truncated_line};
                {error, truncated_line} ->
                    {error, truncated_line};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _} ->
            {error, truncated_line};
        {error, Reason} ->
            {error, Reason}
    end.

-spec write_line(
    file:io_device(),
    book_storage:time(),
    book_storage:value(),
    book_storage:tags()
) -> ok | {error, term()}.
write_line(Device, Time, Value, Tags) ->
    file:write(Device, encode_line(Time, Value, Tags)).

-spec encode_book_index([map()]) -> binary().
encode_book_index(Entries) when is_list(Entries) ->
    Body = << <<(encode_book_entry(E))/binary>> || E <- Entries >>,
    <<(encode_file_header())/binary, (length(Entries)):32/big, Body/binary>>.

-spec decode_book_index(binary()) -> {ok, [map()]} | {error, term()}.
decode_book_index(<<Header:8/binary, Count:32/big, Rest/binary>>) ->
    case decode_file_header(Header) of
        ok ->
            decode_book_entries(Rest, Count, []);
        Error ->
            Error
    end;
decode_book_index(_) ->
    {error, bad_index}.

-spec page_filename(pos_integer()) -> string().
page_filename(N) when is_integer(N), N > 0 ->
    lists:flatten(io_lib:format("page-~8..0B.bin", [N])).

-spec parse_page_filename(string() | binary()) ->
    {ok, pos_integer()} | error.
parse_page_filename(Name) when is_binary(Name) ->
    parse_page_filename(binary_to_list(Name));
parse_page_filename("page-" ++ Rest) ->
    case lists:splitwith(fun(C) -> C >= $0 andalso C =< $9 end, Rest) of
        {Digits, ".bin"} when length(Digits) =:= 8 ->
            {ok, list_to_integer(Digits)};
        _ ->
            error
    end;
parse_page_filename(_) ->
    error.

time_or_zero(empty) ->
    0;
time_or_zero(T) when is_integer(T), T >= 0 ->
    T.

read_exact(_Device, 0) ->
    {ok, <<>>};
read_exact(Device, N) when N > 0 ->
    case file:read(Device, N) of
        {ok, Bin} when byte_size(Bin) =:= N ->
            {ok, Bin};
        {ok, _} ->
            {error, truncated_line};
        eof ->
            eof;
        {error, Reason} ->
            {error, Reason}
    end.

encode_book_entry(#{
    page := Page,
    line_count := LineCount,
    first_time := First,
    last_time := Last,
    filename := Filename
}) ->
    NameBin = iolist_to_binary(Filename),
    <<Page:32/big, LineCount:32/big,
      (time_or_zero(First)):64/big, (time_or_zero(Last)):64/big,
      (byte_size(NameBin)):16/big, NameBin/binary>>.

decode_book_entries(<<>>, 0, Acc) ->
    {ok, lists:reverse(Acc)};
decode_book_entries(<<Page:32/big, LineCount:32/big, First:64/big, Last:64/big,
                      NameLen:16/big, Name:NameLen/binary, Rest/binary>>, N, Acc)
  when N > 0 ->
    Entry = #{
        page => Page,
        line_count => LineCount,
        first_time => First,
        last_time => Last,
        filename => binary_to_list(Name)
    },
    decode_book_entries(Rest, N - 1, [Entry | Acc]);
decode_book_entries(_, _, _) ->
    {error, bad_index}.
