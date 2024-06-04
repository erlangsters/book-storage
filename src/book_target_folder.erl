%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(book_target_folder).
-moduledoc """
Directory-owned book-storage backend.

It is the production persistent target. One `page-NNNNNNNN.bin` file per page
plus a listing-wins `BOOK` cache. Discard unlinks completed page files, then
rewrites `BOOK`.
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

-record(folder, {
    dir :: string(),
    sync :: book_storage:sync_mode(),
    pages = #{} :: #{pos_integer() => string()},
    active = 1 :: pos_integer(),
    device :: file:io_device(),
    next_page = 2 :: pos_integer()
}).

-spec open(file:filename_all(), book_target:open_info()) ->
    {ok, book_target:target_state(), book_target:recovered()} |
    {error, book_storage:reason()}.
open(Dir0, #{sync := Sync}) ->
    Dir = filename_to_list(Dir0),
    case filelib:ensure_dir(filename:join(Dir, "x")) of
        ok ->
            case file:make_dir(Dir) of
                ok ->
                    init_empty(Dir, Sync);
                {error, eexist} ->
                    recover(Dir, Sync);
                {error, Reason} ->
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

-spec close(book_target:target_state()) -> ok | {error, book_storage:reason()}.
close(#folder{device = Device, sync = Sync} = State) ->
    _ = maybe_fsync(Device, Sync, close),
    case file:close(Device) of
        ok ->
            rewrite_book(State);
        {error, Reason} ->
            {error, {io, Reason}}
    end.

-spec write_line(
    book_target:target_state(),
    book_storage:time(),
    book_storage:value(),
    book_storage:tags()
) -> {ok, book_target:target_state()} | {error, book_storage:reason()}.
write_line(#folder{device = Device, sync = Sync} = State, Time, Value, Tags) ->
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
     {page, pos_integer(), string()}} |
    {error, book_storage:reason()}.
turn_page(
    #folder{
        dir = Dir,
        device = Device,
        sync = Sync,
        pages = Pages,
        active = Active,
        next_page = Next
    } = State,
    Table
) ->
    HeaderOff = book_storage_codec:file_header_size(),
    case file:position(Device, eof) of
        {ok, Eof} ->
            TrailerOffset = Eof - HeaderOff,
            Trailer = trailer_from_table(Table),
            case file:write(Device, Trailer) of
                ok ->
                    case file:position(Device, HeaderOff) of
                        {ok, _} ->
                            Header = book_storage_codec:encode_page_header(1, TrailerOffset),
                            case file:write(Device, Header) of
                                ok ->
                                    _ = maybe_fsync(Device, Sync, turn),
                                    ok = file:close(Device),
                                    NewName = book_storage_codec:page_filename(Next),
                                    NewPath = filename:join(Dir, NewName),
                                    case create_page_file(NewPath) of
                                        {ok, NewDevice} ->
                                            Completed = completed_from_table(
                                                {page, Active, maps:get(Active, Pages)},
                                                Active,
                                                Table
                                            ),
                                            NewState = State#folder{
                                                pages = Pages#{Next => NewName},
                                                active = Next,
                                                device = NewDevice,
                                                next_page = Next + 1
                                            },
                                            case rewrite_book(NewState) of
                                                ok ->
                                                    {ok, NewState, Completed, {page, Next, NewName}};
                                                Error ->
                                                    Error
                                            end;
                                        Error ->
                                            Error
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
    {page, pos_integer(), string()},
    pos_integer(),
    pos_integer()
) -> {ok, [book_storage:line()]} | {error, book_storage:reason()}.
read_lines(#folder{dir = Dir, device = ActiveDev, active = Active}, {page, N, Name}, From, To) ->
    case N =:= Active of
        true ->
            slice_lines(read_page_file_device(ActiveDev, Name), From, To);
        false ->
            Path = filename:join(Dir, Name),
            case file:open(Path, [raw, binary, read]) of
                {ok, Dev} ->
                    Result = read_page_file_device(Dev, Name),
                    file:close(Dev),
                    slice_lines(Result, From, To);
                {error, Reason} ->
                    {error, {io, Reason}}
            end
    end.

-spec discard_pages(book_target:target_state(), [{page, pos_integer(), string()}]) ->
    {ok, book_target:target_state()} | {error, book_storage:reason()}.
discard_pages(#folder{dir = Dir, pages = Pages, active = Active} = State, Handles) ->
    case unlink_completed(Dir, Handles, Active) of
        {ok, Dropped} ->
            NewPages = lists:foldl(fun(N, Acc) -> maps:remove(N, Acc) end, Pages, Dropped),
            NewState = State#folder{pages = NewPages},
            case rewrite_book(NewState) of
                ok ->
                    {ok, NewState};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec supports_discard(book_target:target_state()) -> true.
supports_discard(_State) ->
    true.

-spec sync(book_target:target_state()) -> ok | {error, book_storage:reason()}.
sync(#folder{device = _Device, sync = none}) ->
    ok;
sync(#folder{device = Device}) ->
    case file:sync(Device) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

filename_to_list(P) when is_binary(P) ->
    binary_to_list(P);
filename_to_list(P) when is_list(P) ->
    P.

init_empty(Dir, Sync) ->
    Name = book_storage_codec:page_filename(1),
    Path = filename:join(Dir, Name),
    case create_page_file(Path) of
        {ok, Device} ->
            State = #folder{
                dir = Dir,
                sync = Sync,
                pages = #{1 => Name},
                active = 1,
                device = Device,
                next_page = 2
            },
            case rewrite_book(State) of
                ok ->
                    Recovered = #{
                        completed => [],
                        active => empty_table(),
                        active_handle => {page, 1, Name},
                        next_page => 2
                    },
                    {ok, State, Recovered};
                Error ->
                    file:close(Device),
                    Error
            end;
        Error ->
            Error
    end.

recover(Dir, Sync) ->
    case list_page_files(Dir) of
        {ok, []} ->
            init_empty(Dir, Sync);
        {ok, Files} ->
            case load_pages(Dir, Files) of
                {ok, Completed, ActiveInfo, PageMap, Next} ->
                    finish_recover(Dir, Sync, Completed, ActiveInfo, PageMap, Next);
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

list_page_files(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            Parsed = lists:filtermap(
                fun(Name) ->
                    case book_storage_codec:parse_page_filename(Name) of
                        {ok, N} ->
                            {true, {N, Name}};
                        error ->
                            false
                    end
                end,
                Names
            ),
            {ok, lists:keysort(1, Parsed)};
        {error, Reason} ->
            {error, Reason}
    end.

load_pages(Dir, Files) ->
    load_pages(Dir, Files, [], undefined, #{}, 1).

load_pages(_Dir, [], Completed, Active, PageMap, Next) ->
    {ok, lists:reverse(Completed), Active, PageMap, Next};
load_pages(Dir, [{N, Name} | Rest], Completed, Active, PageMap, _Next) ->
    Path = filename:join(Dir, Name),
    case inspect_page_file(Path, Name, N) of
        {ok, complete, Page} ->
            load_pages(
                Dir, Rest, [Page | Completed], Active,
                PageMap#{N => Name}, N + 1
            );
        {ok, active, Table} ->
            load_pages(
                Dir, Rest, Completed, {N, Name, Table},
                PageMap#{N => Name}, N + 1
            );
        {error, {not_a_book, _}} ->
            {error, {corrupt, {page, Name, bad_magic}}};
        Error ->
            Error
    end.

finish_recover(Dir, Sync, Completed, undefined, PageMap, Next) ->
    Name = book_storage_codec:page_filename(Next),
    Path = filename:join(Dir, Name),
    case create_page_file(Path) of
        {ok, Device} ->
            State = #folder{
                dir = Dir,
                sync = Sync,
                pages = PageMap#{Next => Name},
                active = Next,
                device = Device,
                next_page = Next + 1
            },
            case rewrite_book(State) of
                ok ->
                    Recovered = #{
                        completed => Completed,
                        active => empty_table(),
                        active_handle => {page, Next, Name},
                        next_page => Next + 1
                    },
                    {ok, State, Recovered};
                Error ->
                    file:close(Device),
                    Error
            end;
        Error ->
            Error
    end;
finish_recover(Dir, Sync, Completed, {N, Name, Table}, PageMap, Next) ->
    Path = filename:join(Dir, Name),
    case file:open(Path, [raw, binary, read, write]) of
        {ok, Device} ->
            State = #folder{
                dir = Dir,
                sync = Sync,
                pages = PageMap,
                active = N,
                device = Device,
                next_page = Next
            },
            case rewrite_book(State) of
                ok ->
                    Recovered = #{
                        completed => Completed,
                        active => Table,
                        active_handle => {page, N, Name},
                        next_page => Next
                    },
                    {ok, State, Recovered};
                Error ->
                    file:close(Device),
                    Error
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

inspect_page_file(Path, Name, N) ->
    case file:open(Path, [raw, binary, read]) of
        {ok, Device} ->
            Result = inspect_open_page(Device, Path, Name, N),
            file:close(Device),
            Result;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

inspect_open_page(Device, Path, Name, N) ->
    case file:read(Device, 8) of
        {ok, Header} ->
            case book_storage_codec:decode_file_header(Header) of
                ok ->
                    case file:read(Device, book_storage_codec:page_header_size()) of
                        {ok, PageHeader} ->
                            case book_storage_codec:decode_page_header(PageHeader) of
                                {ok, 1, TrailerOffset} ->
                                    TrailerPos = 8 + TrailerOffset,
                                    case file:position(Device, TrailerPos) of
                                        {ok, _} ->
                                            case read_trailer(Device) of
                                                {ok, TrailerMap, _} ->
                                                    Page = #{
                                                        handle => {page, N, Name},
                                                        page => N,
                                                        first_time => maps:get(first_time, TrailerMap),
                                                        last_time => maps:get(last_time, TrailerMap),
                                                        line_count => maps:get(line_count, TrailerMap),
                                                        tag_values => maps:get(tag_index, TrailerMap)
                                                    },
                                                    {ok, complete, Page};
                                                {error, Reason} ->
                                                    {error, {corrupt, {page, Name, Reason}}}
                                            end;
                                        {error, Reason} ->
                                            {error, {io, Reason}}
                                    end;
                                {ok, 0, _} ->
                                    {ok, FileSize} = file:position(Device, eof),
                                    file:position(Device, 8 + book_storage_codec:page_header_size()),
                                    case scan_to_end(Device, FileSize) of
                                        {ok, Table} ->
                                            {ok, active, Table};
                                        {error, truncated_line} ->
                                            {error, {corrupt, {active_page, truncated_line}}};
                                        {error, Reason} ->
                                            {error, {io, Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, {corrupt, {page, Name, Reason}}}
                            end;
                        _ ->
                            {error, {corrupt, {page, Name, truncated_header}}}
                    end;
                {error, bad_magic} ->
                    {error, {not_a_book, Path}};
                {error, Reason} ->
                    {error, {corrupt, {page, Name, Reason}}}
            end;
        eof ->
            {error, {not_a_book, Path}};
        {error, Reason} ->
            {error, {io, Reason}}
    end.

create_page_file(Path) ->
    case file:open(Path, [raw, binary, read, write]) of
        {ok, Device} ->
            _ = file:change_mode(Path, 8#600),
            Header = book_storage_codec:encode_file_header(),
            PageHeader = book_storage_codec:encode_page_header(0, 0),
            case file:write(Device, <<Header/binary, PageHeader/binary>>) of
                ok ->
                    {ok, Device};
                {error, Reason} ->
                    file:close(Device),
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

rewrite_book(#folder{dir = Dir, pages = Pages, active = Active}) ->
    Entries = [
        begin
            Name = maps:get(N, Pages),
            Meta = page_book_meta(Dir, N, Name, N =:= Active),
            Meta#{filename => Name, page => N}
        end
     || N <- lists:sort(maps:keys(Pages))
    ],
    Bin = book_storage_codec:encode_book_index(Entries),
    BookPath = filename:join(Dir, "BOOK"),
    Tmp = BookPath ++ ".tmp",
    case file:write_file(Tmp, Bin) of
        ok ->
            _ = file:change_mode(Tmp, 8#600),
            case file:rename(Tmp, BookPath) of
                ok ->
                    _ = file:change_mode(BookPath, 8#600),
                    ok;
                {error, Reason} ->
                    {error, {io, Reason}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

page_book_meta(_Dir, _N, _Name, true) ->
    #{line_count => 0, first_time => empty, last_time => empty};
page_book_meta(Dir, _N, Name, false) ->
    Path = filename:join(Dir, Name),
    case inspect_page_file(Path, Name, 0) of
        {ok, complete, Page} ->
            #{
                line_count => maps:get(line_count, Page),
                first_time => maps:get(first_time, Page),
                last_time => maps:get(last_time, Page)
            };
        _ ->
            #{line_count => 0, first_time => empty, last_time => empty}
    end.

unlink_completed(Dir, Handles, Active) ->
    unlink_completed(Dir, Handles, Active, []).

unlink_completed(_Dir, [], _Active, Dropped) ->
    {ok, lists:reverse(Dropped)};
unlink_completed(Dir, [{page, N, Name} | Rest], Active, Dropped) when N =/= Active ->
    Path = filename:join(Dir, Name),
    case file:delete(Path) of
        ok ->
            unlink_completed(Dir, Rest, Active, [N | Dropped]);
        {error, enoent} ->
            unlink_completed(Dir, Rest, Active, [N | Dropped]);
        {error, Reason} ->
            {error, {io, Reason}}
    end;
unlink_completed(_Dir, [{page, Active, _} | _], Active, _Dropped) ->
    {error, {io, {refuse_discard_active, Active}}}.

read_page_file_device(Device, Name) ->
    case file:position(Device, bof) of
        {ok, _} ->
            case file:read(Device, 8) of
                {ok, Header} ->
                    case book_storage_codec:decode_file_header(Header) of
                        ok ->
                            case file:read(Device, book_storage_codec:page_header_size()) of
                                {ok, PageHeader} ->
                                    case book_storage_codec:decode_page_header(PageHeader) of
                                        {ok, 1, TrailerOffset} ->
                                            End = 8 + TrailerOffset,
                                            read_line_range(Device, 8 + book_storage_codec:page_header_size(), End);
                                        {ok, 0, _} ->
                                            {ok, FileSize} = file:position(Device, eof),
                                            read_line_range(
                                                Device,
                                                8 + book_storage_codec:page_header_size(),
                                                FileSize
                                            );
                                        {error, Reason} ->
                                            {error, {corrupt, {page, Name, Reason}}}
                                    end;
                                _ ->
                                    {error, {corrupt, {page, Name, truncated_header}}}
                            end;
                        {error, Reason} ->
                            {error, {corrupt, {page, Name, Reason}}}
                    end;
                _ ->
                    {error, {corrupt, {page, Name, truncated_header}}}
            end;
        {error, Reason} ->
            {error, {io, Reason}}
    end.

slice_lines({ok, Lines}, From, To) ->
    Len = length(Lines),
    if
        From < 1 orelse To < From orelse To > Len ->
            {error, {invalid_option, {range, From, To}}};
        true ->
            {ok, lists:sublist(Lines, From, To - From + 1)}
    end;
slice_lines(Error, _From, _To) ->
    Error.

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
maybe_fsync(Device, delayed, _) ->
    file:sync(Device);
maybe_fsync(Device, every_write, _) ->
    file:sync(Device).

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
