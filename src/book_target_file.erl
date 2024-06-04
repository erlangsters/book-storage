%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_target_file).
-moduledoc """
Single-file book-storage backend.

Pages are segments of one binary file. Retention is not supported: any
`{max_pages, _}` is rejected by `book_storage` before this module is used.
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

-record(file, {
    path :: file:filename_all(),
    device :: file:io_device(),
    sync :: book_storage:sync_mode(),
    pages = #{} :: #{pos_integer() => non_neg_integer()},
    active = 1 :: pos_integer(),
    active_offset = 8 :: non_neg_integer(),
    next_page = 2 :: pos_integer()
}).

-spec open(file:filename_all(), book_target:open_info()) ->
    {ok, book_target:target_state(), book_target:recovered()} |
    {error, book_storage:reason()}.
open(Path, #{sync := Sync}) ->
    case ensure_parent(Path) of
        ok ->
            case file:open(Path, [raw, binary, read, write]) of
                {ok, Device} ->
                    case file:change_mode(Path, 8#600) of
                        ok ->
                            recover_or_init(Path, Device, Sync);
                        {error, Reason} ->
                            file:close(Device),
                            {error, {io, Reason}}
                    end;
                {error, Reason} ->
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

-spec close(book_target:target_state()) -> ok | {error, book_storage:reason()}.
close(#file{device = Device, sync = Sync}) ->
    MaybeSync = case Sync of
        none ->
            ok;
        _ ->
            file:sync(Device)
    end,
    case MaybeSync of
        ok ->
            file:close(Device);
        {error, Reason} ->
            file:close(Device),
            {error, {io, Reason}}
    end.

-spec write_line(
    book_target:target_state(),
    book_storage:time(),
    book_storage:value(),
    book_storage:tags()
) -> {ok, book_target:target_state()} | {error, book_storage:reason()}.
write_line(#file{device = Device, sync = Sync} = State, Time, Value, Tags) ->
    case file:position(Device, eof) of
        {ok, _} ->
            case book_storage_codec:write_line(Device, Time, Value, Tags) of
                ok ->
                    case maybe_fsync(Device, Sync, write) of
                        ok ->
                            {ok, State};
                        {error, Reason} ->
                            {error, {io, Reason}}
                    end;
                {error, Reason} ->
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

-spec turn_page(book_target:target_state(), book_target:page_table()) ->
    {ok, book_target:target_state(), book_target:completed_page(),
     {page, pos_integer(), non_neg_integer()}} |
    {error, book_storage:reason()}.
turn_page(
    #file{
        device = Device,
        sync = Sync,
        pages = Pages,
        active = Active,
        active_offset = ActiveOffset,
        next_page = Next
    } = State,
    Table
) ->
    case file:position(Device, eof) of
        {ok, Eof} ->
            TrailerOffset = Eof - ActiveOffset,
            Trailer = trailer_from_table(Table),
            case file:write(Device, Trailer) of
                ok ->
                    case file:position(Device, ActiveOffset) of
                        {ok, _} ->
                            Header = book_storage_codec:encode_page_header(1, TrailerOffset),
                            case file:write(Device, Header) of
                                ok ->
                                    case file:position(Device, eof) of
                                        {ok, NewPageOffset} ->
                                            NewHeader = book_storage_codec:encode_page_header(0, 0),
                                            case file:write(Device, NewHeader) of
                                                ok ->
                                                    case maybe_fsync(Device, Sync, turn) of
                                                        ok ->
                                                            Completed = completed_from_table(
                                                                {page, Active, ActiveOffset},
                                                                Active,
                                                                Table
                                                            ),
                                                            NewState = State#file{
                                                                pages = Pages#{Active => ActiveOffset},
                                                                active = Next,
                                                                active_offset = NewPageOffset,
                                                                next_page = Next + 1
                                                            },
                                                            {ok, NewState, Completed,
                                                             {page, Next, NewPageOffset}};
                                                        {error, Reason} ->
                                                            {error, {io, Reason}}
                                                    end;
                                                {error, Reason} ->
                                                    {error, {io, Reason}}
                                            end;
                                        {error, Reason} ->
                                            {error, {io, Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, {io, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {io, Reason}}
                    end;
                {error, Reason} ->
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

-spec read_lines(
    book_target:target_state(),
    {page, pos_integer(), non_neg_integer()},
    pos_integer(),
    pos_integer()
) -> {ok, [book_storage:line()]} | {error, book_storage:reason()}.
read_lines(#file{device = Device, path = Path}, {page, _N, Offset}, From, To) ->
    case read_page_lines(Device, Path, Offset) of
        {ok, Lines} ->
            Len = length(Lines),
            if
                From < 1 orelse To < From orelse To > Len ->
                    {error, {invalid_option, {range, From, To}}};
                true ->
                    {ok, lists:sublist(Lines, From, To - From + 1)}
            end;
        Error ->
            Error
    end.

-spec discard_pages(book_target:target_state(), [term()]) ->
    {error, book_storage:reason()}.
discard_pages(_State, _Handles) ->
    {error, {unsupported, discard, file}}.

-spec supports_discard(book_target:target_state()) -> false.
supports_discard(_State) ->
    false.

-spec sync(book_target:target_state()) -> ok | {error, book_storage:reason()}.
sync(#file{device = Device, sync = none}) ->
    _ = Device,
    ok;
sync(#file{device = Device}) ->
    case file:sync(Device) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

ensure_parent(Path) ->
    case filelib:ensure_dir(Path) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

recover_or_init(Path, Device, Sync) ->
    case file:position(Device, eof) of
        {ok, 0} ->
            init_new(Path, Device, Sync);
        {ok, Size} when Size < 8 ->
            file:close(Device),
            {error, {not_a_book, Path}};
        {ok, Size} ->
            case file:position(Device, bof) of
                {ok, _} ->
                    case file:read(Device, 8) of
                        {ok, Header} ->
                            case book_storage_codec:decode_file_header(Header) of
                                ok ->
                                    walk(Path, Device, Sync, Size, 8, [], undefined, 1);
                                {error, bad_magic} ->
                                    file:close(Device),
                                    {error, {not_a_book, Path}};
                                {error, Reason} ->
                                    file:close(Device),
                                    {error, {corrupt, Reason}}
                            end;
                        eof ->
                            file:close(Device),
                            {error, {not_a_book, Path}};
                        {error, Reason} ->
                            file:close(Device),
                            {error, {io, Reason}}
                    end;
                {error, Reason} ->
                    file:close(Device),
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            file:close(Device),
            {error, {io, Reason}}
    end.

init_new(Path, Device, Sync) ->
    Header = book_storage_codec:encode_file_header(),
    PageHeader = book_storage_codec:encode_page_header(0, 0),
    case file:write(Device, <<Header/binary, PageHeader/binary>>) of
        ok ->
            State = #file{
                path = Path,
                device = Device,
                sync = Sync,
                pages = #{},
                active = 1,
                active_offset = 8,
                next_page = 2
            },
            Recovered = #{
                completed => [],
                active => empty_table(),
                active_handle => {page, 1, 8},
                next_page => 2
            },
            {ok, State, Recovered};
        {error, Reason} ->
            file:close(Device),
            {error, {io, Reason}}
    end.

walk(Path, Device, Sync, FileSize, Offset, Completed, Active, PageN)
  when Offset =:= FileSize ->
    finish_walk(Path, Device, Sync, Completed, Active, PageN, FileSize);
walk(_Path, Device, _Sync, FileSize, Offset, _Completed, _Active, _PageN)
  when Offset > FileSize ->
    file:close(Device),
    {error, {corrupt, {active_page, truncated_line}}};
walk(Path, Device, Sync, FileSize, Offset, Completed, Active, PageN) ->
    Remain = FileSize - Offset,
    HeaderSize = book_storage_codec:page_header_size(),
    if
        Remain < HeaderSize ->
            file:close(Device),
            {error, {corrupt, {active_page, truncated_line}}};
        true ->
            case file:position(Device, Offset) of
                {ok, _} ->
                    case file:read(Device, HeaderSize) of
                        {ok, HeaderBin} ->
                            case book_storage_codec:decode_page_header(HeaderBin) of
                                {ok, 1, TrailerOffset} ->
                                    read_complete_page(
                                        Path, Device, Sync, FileSize, Offset,
                                        Completed, Active, PageN, TrailerOffset
                                    );
                                {ok, 0, _} ->
                                    scan_active(
                                        Path, Device, Sync, FileSize, Offset,
                                        Completed, PageN
                                    );
                                {error, Reason} ->
                                    file:close(Device),
                                    {error, {corrupt, {page, Path, Reason}}}
                            end;
                        eof ->
                            finish_walk(Path, Device, Sync, Completed, Active, PageN, FileSize);
                        {error, Reason} ->
                            file:close(Device),
                            {error, {io, Reason}}
                    end;
                {error, Reason} ->
                    file:close(Device),
                    {error, {io, Reason}}
            end
    end.

read_complete_page(
    Path, Device, Sync, FileSize, Offset, Completed, Active, PageN, TrailerOffset
) ->
    TrailerPos = Offset + TrailerOffset,
    case file:position(Device, TrailerPos) of
        {ok, _} ->
            case read_trailer(Device) of
                {ok, TrailerMap, TrailerBin} ->
                    NextOffset = TrailerPos + byte_size(TrailerBin),
                    Page = #{
                        handle => {page, PageN, Offset},
                        page => PageN,
                        first_time => maps:get(first_time, TrailerMap),
                        last_time => maps:get(last_time, TrailerMap),
                        line_count => maps:get(line_count, TrailerMap),
                        tag_values => maps:get(tag_index, TrailerMap)
                    },
                    walk(
                        Path, Device, Sync, FileSize, NextOffset,
                        Completed ++ [Page], Active, PageN + 1
                    );
                {error, Reason} ->
                    file:close(Device),
                    {error, {corrupt, {page, Path, Reason}}}
            end;
        {error, Reason} ->
            file:close(Device),
            {error, {io, Reason}}
    end.

scan_active(Path, Device, Sync, FileSize, Offset, Completed, PageN) ->
    LineStart = Offset + book_storage_codec:page_header_size(),
    case file:position(Device, LineStart) of
        {ok, _} ->
            case scan_to_end(Device, FileSize) of
                {ok, Table} ->
                    finish_walk(
                        Path, Device, Sync, Completed,
                        {PageN, Offset, Table}, PageN + 1, FileSize
                    );
                {error, truncated_line} ->
                    file:close(Device),
                    {error, {corrupt, {active_page, truncated_line}}};
                {error, Reason} ->
                    file:close(Device),
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            file:close(Device),
            {error, {io, Reason}}
    end.

finish_walk(Path, Device, Sync, Completed, undefined, PageN, FileSize) ->
    case file:position(Device, FileSize) of
        {ok, _} ->
            Header = book_storage_codec:encode_page_header(0, 0),
            case file:write(Device, Header) of
                ok ->
                    State = #file{
                        path = Path,
                        device = Device,
                        sync = Sync,
                        pages = pages_map(Completed),
                        active = PageN,
                        active_offset = FileSize,
                        next_page = PageN + 1
                    },
                    Recovered = #{
                        completed => Completed,
                        active => empty_table(),
                        active_handle => {page, PageN, FileSize},
                        next_page => PageN + 1
                    },
                    {ok, State, Recovered};
                {error, Reason} ->
                    file:close(Device),
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            file:close(Device),
            {error, {io, Reason}}
    end;
finish_walk(Path, Device, Sync, Completed, {PageN, Offset, Table}, Next, _FileSize) ->
    State = #file{
        path = Path,
        device = Device,
        sync = Sync,
        pages = pages_map(Completed),
        active = PageN,
        active_offset = Offset,
        next_page = Next
    },
    Recovered = #{
        completed => Completed,
        active => Table,
        active_handle => {page, PageN, Offset},
        next_page => Next
    },
    {ok, State, Recovered}.

scan_to_end(Device, FileSize) ->
    scan_to_end(Device, FileSize, empty_table()).

scan_to_end(Device, FileSize, Table) ->
    {ok, Pos} = file:position(Device, cur),
    if
        Pos =:= FileSize ->
            {ok, Table};
        Pos > FileSize ->
            {error, truncated_line};
        true ->
            case book_storage_codec:read_line(Device) of
                {ok, Line} ->
                    scan_to_end(Device, FileSize, add_line(Table, Line));
                eof when Pos =:= FileSize ->
                    {ok, Table};
                eof ->
                    {error, truncated_line};
                {error, truncated_line} ->
                    {error, truncated_line};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

read_page_lines(Device, Path, Offset) ->
    case file:position(Device, Offset) of
        {ok, _} ->
            case file:read(Device, book_storage_codec:page_header_size()) of
                {ok, HeaderBin} ->
                    case book_storage_codec:decode_page_header(HeaderBin) of
                        {ok, 1, TrailerOffset} ->
                            End = Offset + TrailerOffset,
                            read_line_range(Device, Offset + book_storage_codec:page_header_size(), End);
                        {ok, 0, _} ->
                            {ok, FileSize} = file:position(Device, eof),
                            file:position(Device, Offset + book_storage_codec:page_header_size()),
                            read_line_range(
                                Device,
                                Offset + book_storage_codec:page_header_size(),
                                FileSize
                            );
                        {error, Reason} ->
                            {error, {corrupt, {page, Path, Reason}}}
                    end;
                Error ->
                    {error, {io, Error}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

read_line_range(Device, Start, End) ->
    file:position(Device, Start),
    read_line_range_acc(Device, End, []).

read_line_range_acc(Device, End, Acc) ->
    {ok, Pos} = file:position(Device, cur),
    if
        Pos >= End ->
            {ok, lists:reverse(Acc)};
        true ->
            case book_storage_codec:read_line(Device) of
                {ok, Line} ->
                    read_line_range_acc(Device, End, [Line | Acc]);
                eof ->
                    {ok, lists:reverse(Acc)};
                {error, Reason} ->
                    {error, {corrupt, {active_page, Reason}}}
            end
    end.

read_trailer(Device) ->
    case file:read(Device, 28) of
        {ok, <<LineCount:32/big, ByteSize:32/big, First:64/big, Last:64/big, IndexLen:32/big>>} ->
            case file:read(Device, IndexLen) of
                {ok, IndexBin} when byte_size(IndexBin) =:= IndexLen ->
                    TrailerBin = <<LineCount:32/big, ByteSize:32/big, First:64/big,
                                   Last:64/big, IndexLen:32/big, IndexBin/binary>>,
                    case book_storage_codec:decode_trailer(TrailerBin) of
                        {ok, Map, <<>>} ->
                            {ok, Map, TrailerBin};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _ ->
                    {error, truncated_trailer}
            end;
        _ ->
            {error, truncated_trailer}
    end.

maybe_fsync(_Device, none, _) ->
    ok;
maybe_fsync(_Device, delayed, write) ->
    ok;
maybe_fsync(Device, delayed, turn) ->
    file:sync(Device);
maybe_fsync(Device, every_write, _) ->
    file:sync(Device).

pages_map(Completed) ->
    maps:from_list([{maps:get(page, P), offset_of(P)} || P <- Completed]).

offset_of(#{handle := {page, _, Offset}}) ->
    Offset.

empty_table() ->
    #{times => [], tags => #{}, bytes => 0}.

add_line(Table, #{time := Time, value := Value, tags := Tags}) ->
    Size = book_storage_codec:line_size(Time, Value, Tags),
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

trailer_from_table(#{times := Times, tags := Tags, bytes := Bytes}) ->
    book_storage_codec:encode_trailer(#{
        line_count => length(Times),
        byte_size => Bytes,
        first_time => hd(Times),
        last_time => lists:last(Times),
        tag_index => maps:map(fun(_K, Inner) -> maps:keys(Inner) end, Tags)
    }).

completed_from_table(Handle, Page, #{times := Times, tags := Tags}) ->
    #{
        handle => Handle,
        page => Page,
        first_time => hd(Times),
        last_time => lists:last(Times),
        line_count => length(Times),
        tag_values => maps:map(fun(_K, Inner) -> maps:keys(Inner) end, Tags)
    }.
