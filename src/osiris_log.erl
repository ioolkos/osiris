-module(osiris_log).

-include_lib("kernel/include/file.hrl").
-include("osiris.hrl").

-export([
         init/1,
         init_acceptor/2,
         write/2,
         write/3,
         accept_chunk/2,
         next_offset/1,
         tail_info/1,
         send_file/2,
         send_file/3,

         init_data_reader/2,
         init_offset_reader/2,
         read_chunk/1,
         read_chunk_parsed/1,
         committed_offset/1,
         get_current_epoch/1,
         get_directory/1,
         get_name/1,
         counters_ref/1,
         close/1,
         overview/1,
         evaluate_retention/2,

         directory/1,
         delete_directory/1
         ]).

-define(IDX_VERSION, 1).
-define(LOG_VERSION, 1).
-define(IDX_HEADER, <<"OSII", ?IDX_VERSION:32/unsigned>>).
-define(LOG_HEADER, <<"OSIL", ?LOG_VERSION:32/unsigned>>).
-define(IDX_HEADER_SIZE, 8).
-define(LOG_HEADER_SIZE, 8).

-define(DEFAULT_MAX_SEGMENT_SIZE_B, 500 * 1000 * 1000).
-define(INDEX_RECORD_SIZE_B, 28).
-define(MAGIC, 5).
%% chunk format version
-define(VERSION, 0).
-define(HEADER_SIZE_B, 39).
-define(FILE_OPTS_WRITE, [raw, binary, write, read]).

-define(COUNTER_FIELDS,
        [offset,
         first_offset,
         chunks
         ]).

-define(C_OFFSET, 1).
-define(C_FIRST_OFFSET, 2).
-define(C_CHUNKS, 3).

%% Data format
%% Write in "chunks" which are batches of blobs
%%
%% <<
%%   Magic=5:4/unsigned,
%%   ProtoVersion:4/unsigned,
%%   NumEntries:16/unsigned, %% need some kind of limit on chunk sizes 64k is a good start
%%   NumRecords:32/unsigned, %% total including all sub batch entries
%%   Timestamp:64/signed, %% millisecond posix (ish) timestamp
%%   Epoch:64/unsigned,
%%   ChunkFirstOffset:64/unsigned,
%%   ChunkCrc:32/integer, %% crc32 checksum for the records portion of the data
%%   DataLength:32/unsigned, %% length until end of chunk
%%   [Entry]
%%   ...>>
%%
%%   Entry Format
%%   <<0=SimpleEntryType:1,
%%     Size:31/unsigned,
%%     Data:Size/binary>> |
%%
%%   <<1=SubBatchEntryType:1,
%%     CompressionType:3,
%%     Reserved:4,
%%     NumRecords:16/unsigned,
%%     Size:32/unsigned,
%%     Data:Size/binary>>
%%
%%   Chunks is the unit of replication and read
%%
%%   Index format:
%%   Maps each chunk to an offset
%%   | Offset | FileOffset

-type offset() :: osiris:offset().
-type epoch() :: osiris:epoch().
-type range() :: {From :: offset(), To :: offset()}.

-type config() :: osiris:config() |
                  #{dir := file:filename(),
                    epoch => non_neg_integer(),
                    max_segment_size => non_neg_integer(),
                    counter_spec => {Tag :: atom(), Fields :: [atom()]}}.

-type record() :: {offset(), iodata()}.
-type offset_spec() :: osiris:offset_spec().
-type retention_spec() :: osiris:retention_spec().

%% holds static or rarely changing fields
-record(cfg, {directory :: file:filename(),
              name :: string(),
              max_segment_size = ?DEFAULT_MAX_SEGMENT_SIZE_B :: non_neg_integer(),
              retention = [] :: [osiris:retention_spec()],
              counter :: counters:counters_ref(),
              counter_id :: term()
             }).


-record(read, {type :: data | offset,
               offset_ref :: undefined | atomics:atomics_ref(),
               next_offset = 0 :: offset()
              }).

-record(write, {segment_size = 0 :: non_neg_integer(),
                current_epoch :: non_neg_integer(),
                tail_info = {0, undefined} :: osiris:tail_info()
               }).

-record(?MODULE, {cfg :: #cfg{},
                  mode :: #read{} | #write{},
                  fd :: undefined | file:io_device(),
                  index_fd :: undefined | file:io_device()}).

-record(chunk_info, {epoch :: epoch(),
                     timestamp :: non_neg_integer(),
                     id :: offset(),
                     num :: non_neg_integer()}).

-record(seg_info, {file :: file:filename(),
                   size = 0 :: non_neg_integer(),
                   index :: file:filename(),
                   first :: undefined | #chunk_info{},
                   last :: undefined | #chunk_info{}}).

-opaque state() :: #?MODULE{}.

-export_type([
              state/0,
              range/0,
              % record/0,
              config/0
              ]).

-spec directory(osiris:config()) -> file:filename().
directory(#{name := Name} = Config) ->
    Dir = case Config of
              #{dir := D} -> D;
              _ ->
                  {ok, D} = application:get_env(osiris, data_dir),
                  D
          end,
    filename:join(Dir, Name).

-spec init(config()) -> state().
init(#{dir := Dir,
       name := Name,
       epoch := Epoch} = Config) ->
    %% scan directory for segments if in write mode
    MaxSize = maps:get(max_segment_size, Config, ?DEFAULT_MAX_SEGMENT_SIZE_B),
    Retention = maps:get(retention, Config, []),
    ?INFO("osiris_log:init/1 max_segment_size: ~b, retention ~w",
          [MaxSize, Retention]),
    ok = filelib:ensure_dir(Dir),
    case file:make_dir(Dir) of
        ok -> ok;
        {error, eexist} -> ok;
        Err -> throw(Err)
    end,

    Cnt = make_counter(Config),
    %% initialise offset counter to -1 as 0 is the first offset in the log and
    %% it hasn't necessarily been written yet, for an empty log the first offset
    %% is initialised to 0 however and will be updated after each retention run.
    counters:put(Cnt, ?C_OFFSET, -1),
    Cfg = #cfg{directory = Dir,
               name = Name,
               max_segment_size = MaxSize,
               retention = Retention,
               counter = Cnt,
               counter_id = counter_id(Config)},
    case lists:reverse(build_log_overview(Dir)) of
        [] ->
            open_new_segment(#?MODULE{cfg = Cfg,
                                      mode = #write{tail_info = {0, empty},
                                                    current_epoch = Epoch}});
        [#seg_info{file = Filename,
                   index = IdxFilename,
                   first = #chunk_info{id = FstChId},
                   last = #chunk_info{epoch = E,
                                      id = ChId,
                                      num = N}} | _] ->
            %% assert epoch is same or larger
            %% than last known epoch
            case E > Epoch of
                true ->
                    exit(invalid_epoch);
                _ -> ok
            end,
            TailInfo = {ChId + N, {E, ChId}},

            counters:put(Cnt, ?C_FIRST_OFFSET, FstChId),
            counters:put(Cnt, ?C_OFFSET, ChId + N - 1),
            ?INFO("~s:~s/~b: next offset ~b",
                  [?MODULE, ?FUNCTION_NAME,
                   ?FUNCTION_ARITY, element(1, TailInfo)]),
            {ok, Fd} = open(Filename, ?FILE_OPTS_WRITE),
            {ok, IdxFd} = open(IdxFilename, ?FILE_OPTS_WRITE),
            {ok, _} = file:position(Fd, eof),
            {ok, _} = file:position(IdxFd, eof),
            #?MODULE{cfg = Cfg,
                     mode = #write{tail_info = TailInfo,
                                   current_epoch = Epoch},
                     fd = Fd,
                     index_fd = IdxFd};
        [#seg_info{file = Filename,
                   index = IdxFilename,
                   last = undefined} | _] ->
            %% the empty log case
            {ok, Fd} = open(Filename, ?FILE_OPTS_WRITE),
            {ok, IdxFd} = open(IdxFilename, ?FILE_OPTS_WRITE),
            {ok, _} = file:position(Fd, eof),
            {ok, _} = file:position(IdxFd, eof),
            #?MODULE{cfg = Cfg,
                     mode = #write{tail_info = {0, empty},
                                   current_epoch = Epoch},
                     fd = Fd,
                     index_fd = IdxFd}
    end.

-spec write([iodata() | {batch, non_neg_integer(), 0, iodata()}], state()) ->
    state().
write(Entries, State) ->
    Timestamp = erlang:system_time(millisecond),
    write(Entries, Timestamp, State).

-spec write([iodata() | {batch, non_neg_integer(), 0, iodata()}], 
            integer(), state()) -> state().
write([], _Now, #?MODULE{mode = #write{}} = State) ->
    State;
write(Entries, Now, #?MODULE{cfg = #cfg{},
                             mode = #write{current_epoch = Epoch,
                                           tail_info = {Next, _}}} = State) ->
    {ChunkData, NumRecords} = make_chunk(Entries, Now, Epoch, Next),
    write_chunk(ChunkData, Now, Epoch, NumRecords, State).

-spec accept_chunk(iodata(), state()) -> state().
accept_chunk([<<?MAGIC:4/unsigned,
                ?VERSION:4/unsigned,
                _NumEntries:16/unsigned,
                NumRecords:32/unsigned,
                Timestamp:64/signed,
                Epoch:64/unsigned,
                Next:64/unsigned,
                Crc:32/integer,
                _DataSize:32/unsigned,
                Data/binary>> | DataParts] = Chunk,
             #?MODULE{cfg = #cfg{},
                      mode = #write{tail_info = {Next, _}}} = State) ->
    validate_crc(Next, Crc, [Data | DataParts]),
    write_chunk(Chunk, Timestamp, Epoch, NumRecords, State);
accept_chunk(Binary, State)
  when is_binary(Binary) ->
    accept_chunk([Binary], State);
accept_chunk([<<?MAGIC:4/unsigned,
                ?VERSION:4/unsigned,
                _NumEntries:16/unsigned,
                _NumRecords:32/unsigned,
                _Timestamp:64/signed,
                _Epoch:64/unsigned,
                Next:64/unsigned,
                _Crc:32/integer,
                _DataSize:32/unsigned,
                _/binary>>
              | _] = _Chunk,
             #?MODULE{cfg = #cfg{},
                      mode = #write{tail_info = {ExpectedNext, _}}}) ->
    exit({accept_chunk_out_of_order, Next, ExpectedNext}).


-spec next_offset(state()) -> offset().
next_offset(#?MODULE{mode = #write{tail_info = {Next, _}}}) ->
    Next;
next_offset(#?MODULE{mode = #read{next_offset = Next}}) ->
    Next.

-spec tail_info(state()) -> osiris:tail_info().
tail_info(#?MODULE{mode = #write{tail_info = TailInfo}}) ->
    TailInfo.

% -spec
init_acceptor(EpochOffsets0, #{name := Name,
                               dir := Dir} = Conf) ->
    %% truncate to first common last epoch offset
    %% * if the last local chunk offset has the same epoch but is lower
    %% than the last chunk offset then just attach at next offset.
    %% * if it is higher - truncate to last epoch offset
    %% * if it has a higher epoch than last provided - truncate to last offset
    %% of previous 
    %% sort them so that the highest epochs go first
    EpochOffsets = lists:reverse(lists:sort(EpochOffsets0)),

    %% then truncate to
    SegInfos = build_log_overview(Dir),
    ok = truncate_to(Name, EpochOffsets, SegInfos),
    %% after truncation we can do normal init
    init(Conf).

chunk_id_index_scan(IdxFile, ChunkId) when is_list(IdxFile) ->
    Fd = open_index_read(IdxFile),
    chunk_id_index_scan0(Fd, ChunkId).

chunk_id_index_scan0(Fd, ChunkId) ->
    {ok, IdxPos} = file:position(Fd, cur),
    case file:read(Fd, ?INDEX_RECORD_SIZE_B) of
        {ok, <<ChunkId:64/unsigned,
               _Timestamp:64/signed,
               Epoch:64/unsigned,
               FilePos:32/unsigned>>} ->
            ok = file:close(Fd),
            {ChunkId, Epoch, FilePos, IdxPos};
        {ok, _} ->
            chunk_id_index_scan0(Fd, ChunkId);
        eof ->
            ok = file:close(Fd),
            eof
    end.

delete_segment(#seg_info{file = File,
                         index = Index}) ->
    ?INFO("deleting segment ~s in ~s",
          [filename:basename(File),
           filename:dirname(File)]),
    ok = file:delete(File),
    ok = file:delete(Index),
    ok.

truncate_to(_Name, [], SegInfos) ->
    %% ?????  this means the entire log is out
    [begin
         ok = delete_segment(I)
     end || I <- SegInfos],
    ok;
truncate_to(Name, [{E, ChId} | NextEOs], SegInfos) ->
    case find_segment_for_offset(ChId, SegInfos) of
        not_found ->
            truncate_to(Name, NextEOs, SegInfos);
        {end_of_log, _Info} ->
            ok;
        {found, #seg_info{file = File,
                          index = Idx}} ->
            ?INFO("osiris_log: ~s on node ~s truncating to chunk id ~b in epoch ~b",
                  [Name, node(), ChId, E]),
            %% this is the inclusive case
            %% next offset needs to be a chunk offset
            %% if it is not found we know the offset requested isn't a chunk
            %% id and thus isn't valid
            case chunk_id_index_scan(Idx, ChId) of
                {ChId, E, Pos, IdxPos} when is_integer(Pos) ->
                    %% the  Chunk id was found and has the right epoch
                    %% lets truncate to this point
                    %% FilePos could be eof here which means the next offset
                    {ok, Fd} = file:open(File, [read, write, binary, raw]),
                    {ok, IdxFd} = file:open(Idx, [read, write, binary, raw]),

                    {ChId, E, _Num, Size} = header_info(Fd, Pos),
                    %% position at end of chunk
                    {ok, _Pos} = file:position(Fd, {cur, Size}),
                    ok = file:truncate(Fd),

                    {ok, _} = file:position(IdxFd, IdxPos + ?INDEX_RECORD_SIZE_B),
                    ok = file:truncate(IdxFd),
                    ok = file:close(Fd),
                    ok = file:close(IdxFd),
                    %% delete all segments with a first offset larger then ChId
                    [begin
                         ok = delete_segment(I)
                     end || I <- SegInfos,
                            I#seg_info.first#chunk_info.id > ChId],
                    ok;
                _ ->
                    truncate_to(Name, NextEOs, SegInfos)
            end
    end.

-spec init_data_reader(osiris:tail_info(), config()) ->
    {ok, state()} |
    {error, {offset_out_of_range, empty | {offset(), offset()}}} |
    {error, {invalid_last_offset_epoch, offset(), offset()}}.
init_data_reader({StartOffset, PrevEO}, #{dir := Dir} = Config) ->
    SegInfos = build_log_overview(Dir),
    Range = range_from_segment_infos(SegInfos),
    ?INFO("osiris_segment:init_data_reader/2 at ~b prev ~w range: ~w",
          [StartOffset, PrevEO, Range]),
    %% Invariant:  there is always at least one segment left on disk
    case Range of
        {F, _L} when StartOffset < F ->
            %% if a lower than exisiting is request simply forward
            %% it to the first offset of the log
            %% in this case we cannot validate PrevEO - instead
            %% the replica should truncate all of it's exisiting log
            case find_segment_for_offset(F, SegInfos) of
                not_found ->
                    %% this is unexpected and thus an error
                    exit({segment_not_found, F, SegInfos});
                {_, StartSegmentInfo} ->
                    {ok, init_data_reader_from_segment(Config, StartSegmentInfo, F)}
            end;
        empty when StartOffset > 0 ->
            {error, {offset_out_of_range, Range}};
        {_F, L} when StartOffset > L + 1 ->
            %% if we are trying to attach to anything larger than
            %% the next offset (i.e last +1) this is in out of range
            %% error
            {error, {offset_out_of_range, Range}};
        _ ->
            %% this assumes the offset is in range
            %% first we need to validate PrevEO
            case PrevEO of
                empty when StartOffset == 0 ->
                    case find_segment_for_offset(StartOffset, SegInfos) of
                        not_found ->
                            %% this is unexpected and thus an error
                            exit({segment_not_found, StartOffset, SegInfos});
                        {_, StartSegmentInfo} ->
                            {ok, init_data_reader_from_segment(Config,
                                                               StartSegmentInfo,
                                                               StartOffset)}
                    end;
                {PrevE, PrevO} ->
                    case find_segment_for_offset(PrevO, SegInfos) of
                        not_found ->
                            %% this is unexpected and thus an error
                            {error, {invalid_last_offset_epoch, PrevE, unknown}};
                        {_, #seg_info{file = PrevSeg,
                                      index = PrevIdxFile}} ->
                            %% prev segment exists, does it have the correct
                            %% epoch?
                            {ok, Fd} = file:open(PrevSeg, [raw, binary, read]),
                            %% TODO: next offset needs to be a chunk offset
                            {_, FilePos} = scan_index(PrevIdxFile, Fd, PrevO),
                            {ok, FilePos} = file:position(Fd, FilePos),
                            case file:read(Fd, ?HEADER_SIZE_B) of
                                {ok, <<?MAGIC:4/unsigned,
                                       ?VERSION:4/unsigned,
                                       _NumEntries:16/unsigned,
                                       _NumRecords:32/unsigned,
                                       _Timestamp:64/signed,
                                       PrevE:64/unsigned,
                                       PrevO:64/unsigned,
                                       _Crc:32/integer,
                                       _DataSize:32/unsigned>>} ->
                                    ok = file:close(Fd),
                                    {ok, init_data_reader_from_segment(
                                           Config, element(2, find_segment_for_offset(StartOffset, SegInfos)),
                                           StartOffset)};
                                {ok, <<?MAGIC:4/unsigned,
                                       ?VERSION:4/unsigned,
                                       _NumEntries:16/unsigned,
                                       _NumRecords:32/unsigned,
                                       _Timestamp:64/signed,
                                       OtherE:64/unsigned,
                                       PrevO:64/unsigned,
                                       _Crc:32/integer,
                                       _DataSize:32/unsigned>>} ->
                                    ok = file:close(Fd),
                                    {error, {invalid_last_offset_epoch, PrevE, OtherE}}
                            end
                    end
            end
    end.

init_data_reader_from_segment(#{dir := Dir,
                                name := Name} = Config,
                              #seg_info{file = StartSegment,
                                        index = IndexFile}, NextOffs) ->
    {ok, Fd} = file:open(StartSegment, [raw, binary, read]),
    %% TODO: next offset needs to be a chunk offset
    {_, FilePos} = scan_index(IndexFile, Fd, NextOffs),
    {ok, _Pos} = file:position(Fd, FilePos),
    #?MODULE{cfg = #cfg{directory = Dir,
                        counter = make_counter(Config),
                        name = Name},
             mode = #read{type = data,
                          offset_ref = maps:get(offset_ref, Config, undefined),
                          next_offset = NextOffs},
             fd = Fd}.


%% @doc Initialise a new offset reader
%% @param OffsetSpec specifies where in the log to attach the reader
%% `first': Attach at first available offset.
%% `last': Attach at the last available chunk offset or the next available offset
%% if the log is empty.
%% `next': Attach to the next chunk offset to be written.
%% `{abs, offset()}': Attach at the provided offset. If this offset does not exist
%% in the log it will error with `{error, {offset_out_of_range, Range}}'
%% `offset()': Like `{abs, offset()}' but instead of erroring it will fall back
%% to `first' (if lower than first offset in log) or `nextl if higher than
%% last offset in log.
%% @param Config The configuration. Requires the `dir' key.
%% @returns `{ok, state()} | {error, Error}' when error can be
%% `{offset_out_of_range, empty | {From :: offset(), To :: offset()}}'
%% @end
-spec init_offset_reader(OffsetSpec :: offset_spec(),
                         Config :: config()) ->
    {ok, state()} |
    {error, {offset_out_of_range,
             empty | {From :: offset(), To :: offset()}}}.
init_offset_reader({abs, Offs}, #{dir := Dir} = Conf) ->
    %% TODO: some unnecessary computation here
    Range = range_from_segment_infos(build_log_overview(Dir)),
    case Range of
        empty ->
            {error, {offset_out_of_range, Range}};
        {S, E} when Offs < S orelse Offs > E ->
            {error, {offset_out_of_range, Range}};
        _ ->
            %% it is in range, convert to standard offset
            init_offset_reader(Offs, Conf)
    end;
init_offset_reader({timestamp, Ts}, #{dir := Dir} = Conf) ->
    case build_log_overview(Dir) of
        [] ->
            init_offset_reader(next, Conf);
        [#seg_info{first = #chunk_info{timestamp = Fst}} | _]
          when is_integer(Fst) andalso Fst > Ts ->
            %% timestamp is lower than the first timestamp available
            init_offset_reader(first, Conf);
        SegInfos ->
            case lists:search(
                   fun (#seg_info{first = #chunk_info{timestamp = F},
                                  last = #chunk_info{timestamp = L}})
                         when is_integer(F) andalso is_integer(L) ->
                           Ts >= F andalso Ts =< L;
                       (_) ->
                           false
                   end, SegInfos) of
                {value, Info} ->
                    %% segment was found, now we need to scan index to
                    %% find nearest offset
                    ChunkId = chunk_id_for_timestamp(Info, Ts),
                    init_offset_reader(ChunkId, Conf);
                false ->
                    %% segment was not found, attach next
                    init_offset_reader(next, Conf)
            end
    end;
init_offset_reader(OffsetSpec, #{dir := Dir,
                                 name := Name,
                                 offset_ref := OffsetRef} = Conf) ->
    SegInfo = build_log_overview(Dir),
    Range = range_from_segment_infos(SegInfo),
    ?INFO("osiris_log:init_offset_reader/2 spec ~w range ~w ",
          [OffsetSpec, Range]),
    StartOffset = case {OffsetSpec, Range} of
                      {_, empty} ->
                          0;
                      {first, {F, _}} ->
                          F;
                      {last, {_, L}}  ->
                          L;
                      {next, {_, L}}  ->
                          L + 1;
                      {Offset, {S, E}} when is_integer(Offset) ->
                          max(S, min(Offset, E + 1))
                  end,
    %% find the appopriate segment and scan the index to find the
    %% postition of the next chunk to read
    case find_segment_for_offset(StartOffset, SegInfo) of
        not_found ->
            {error, {offset_out_of_range, Range}};
        {_, #seg_info{file = StartSegment,
                      index = IndexFile}} ->
            try
                {ok, Fd} = open(StartSegment, [raw, binary, read]),
                {ChOffs, FilePos} = case scan_index(IndexFile, Fd, StartOffset) of
                                        eof ->
                                            {StartOffset, 0};
                                        IdxResult ->
                                            IdxResult
                                    end,
                {ok, _Pos} = file:position(Fd, FilePos),
                {ok, #?MODULE{cfg = #cfg{directory = Dir,
                                         counter = make_counter(Conf),
                                         name = Name},
                              mode = #read{type = offset,
                                           offset_ref = OffsetRef,
                                           next_offset = ChOffs},
                              fd = Fd}}
            catch
                missing_file ->
                    %% Retention policies are likely being applied, let's try again
                    %% TODO: should we limit the number of retries?
                    init_offset_reader(OffsetSpec, Conf)
            end
    end.

-spec committed_offset(state()) -> undefined | offset().
committed_offset(#?MODULE{mode = #read{offset_ref = undefined}}) ->
    undefined;
committed_offset(#?MODULE{mode = #read{offset_ref = Ref}}) ->
    atomics:get(Ref, 1).

-spec get_current_epoch(state()) -> non_neg_integer().
get_current_epoch(#?MODULE{mode = #write{current_epoch = Epoch}}) ->
    Epoch.

-spec get_directory(state()) -> file:filename().
get_directory(#?MODULE{cfg = #cfg{directory = Dir}}) ->
    Dir.

-spec get_name(state()) -> string().
get_name(#?MODULE{cfg = #cfg{name = Name}}) ->
    Name.

-spec counters_ref(state()) -> counters:counters_ref().
counters_ref(#?MODULE{cfg = #cfg{counter = C}}) ->
    C.

-spec read_chunk(state()) ->
    {ok, {offset(), epoch(),
          HeaderData :: iodata(),
          RecordData :: iodata()}, state()} |
    {end_of_stream, state()} |
    {error, {invalid_chunk_header, term()}}.
read_chunk(#?MODULE{cfg = #cfg{directory = Dir},
                    mode = #read{next_offset = Next} = Read,
                    fd = Fd
                   } = State) ->
    %% reads the next chunk of entries, parsed
    %% NB: this may return records before the requested index,
    %% that is fine - the reading process can do the appropriate filtering
    case can_read_next_offset(Read) of
        true ->
            case file:read(Fd, ?HEADER_SIZE_B) of
                {ok, <<?MAGIC:4/unsigned,
                       ?VERSION:4/unsigned,
                       _NumEntries:16/unsigned,
                       NumRecords:32/unsigned,
                       _Timestamp:64/signed,
                       Epoch:64/unsigned,
                       Offs:64/unsigned,
                       Crc:32/integer,
                       DataSize:32/unsigned>> = HeaderData} ->
                    {ok, BlobData} = file:read(Fd, DataSize),
                    validate_crc(Offs, Crc, BlobData),
                    {ok, {Offs, Epoch, HeaderData, BlobData},
                     State#?MODULE{mode = incr_next_offset(NumRecords, Read)}};
                {ok, _} ->
                    %% set the position back for the next read
                    {ok, _} = file:position(Fd, {cur, -?HEADER_SIZE_B}),
                    {end_of_stream, State};
                eof ->
                    %% open next segment file and start there if it exists
                    SegFile = make_file_name(Next, "segment"),

                    case file:open(filename:join(Dir, SegFile),
                                   [raw, binary, read]) of
                        {ok, Fd2} ->
                            ok = file:close(Fd),
                            {ok, _} = file:position(Fd2, ?LOG_HEADER_SIZE),
                            read_chunk_parsed(State#?MODULE{fd = Fd2});
                        {error, enoent} ->
                            {end_of_stream, State}
                    end;
                Invalid ->
                    {error, {invalid_chunk_header, Invalid}}
            end;
        false ->
            {end_of_stream, State}
    end.

-spec read_chunk_parsed(state()) ->
    {[record()], state()} |
    {end_of_stream, state()} |
    {error, {invalid_chunk_header, term()}}.
read_chunk_parsed(#?MODULE{} = State0) ->
    %% reads the next chunk of entries, parsed
    %% NB: this may return records before the requested index,
    %% that is fine - the reading process can do the appropriate filtering
    case read_chunk(State0) of
        {ok, {Offs, _Epoch, _Header, Data}, State} ->
            %% parse blob data into records
            Records = parse_records(Offs, Data, []),
            {Records, State};
        Ret ->
            Ret
    end.

-spec send_file(gen_tcp:socket(), state()) ->
    {ok, state()} | {end_of_stream, state()}.
send_file(Sock, State) ->
    send_file(Sock, State, fun empty_function/1).

-spec send_file(gen_tcp:socket(), state(),
                fun((non_neg_integer()) -> none())) ->
    {ok, state()} | {end_of_stream, state()}.
send_file(Sock, #?MODULE{cfg = #cfg{directory = Dir},
                         mode = #read{next_offset = NextOffs} = Read,
                         fd = Fd} = State, Callback) ->
    case can_read_next_offset(Read) of
        true ->
            {ok, Pos} = file:position(Fd, cur),
            case file:read(Fd, ?HEADER_SIZE_B) of
                {ok, <<?MAGIC:4/unsigned,
                       ?VERSION:4/unsigned,
                       _NumEntries:16/unsigned,
                       NumRecords:32/unsigned,
                       _Timestamp:64/integer,
                       _Epoch:64/unsigned,
                       NextOffs:64/unsigned,
                       _Crc:32/integer,
                       DataSize:32/unsigned>>} ->
                    %% read header
                    ToSend = DataSize + ?HEADER_SIZE_B,
                    %% used to write frame headers to socket
                    Callback(ToSend),
                    ok = sendfile(Fd, Sock, Pos, ToSend),
                    FilePos = Pos + ToSend,
                    %% sendfile doesn't increment the file descriptor position
                    {ok, FilePos} = file:position(Fd, FilePos),
                    {ok, State#?MODULE{mode = incr_next_offset(NumRecords, Read)}};
                {ok, B} when byte_size(B) < ?HEADER_SIZE_B ->
                    %% partial data available
                    %% reset and wait for update
                    {ok, Pos} = file:position(Fd, Pos),
                    {end_of_stream, State};
                eof ->
                    %% open next segment file and start there if it exists
                    SegFile = make_file_name(NextOffs, "segment"),
                    case file:open(filename:join(Dir, SegFile),
                                   [raw, binary, read]) of
                        {ok, Fd2} ->
                            {ok, _} = file:position(Fd2, ?IDX_HEADER_SIZE),
                            ok = file:close(Fd),
                            send_file(Sock, State#?MODULE{fd = Fd2}, Callback);
                        {error, enoent} ->
                            {end_of_stream, State}
                    end
            end;
        false ->
            {end_of_stream, State}
    end.


-spec close(state()) -> ok.
close(#?MODULE{cfg = #cfg{counter_id = CntId},
               fd = Fd}) ->
    _ = file:close(Fd),
    case CntId of
        undefined -> ok;
        _ ->
            osiris_counters:delete(CntId)
    end.

delete_directory(Config) ->
    Dir = directory(Config),
    case file:list_dir(Dir) of
        {ok, Files} ->
            [ok = file:delete(filename:join(Dir, F)) || F <- Files],
            ok = file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.

%% Internal

header_info(Fd, Pos) ->
    {ok, Pos} = file:position(Fd, Pos),
    {ok, <<?MAGIC:4/unsigned,
           ?VERSION:4/unsigned,
           _NumEntries:16/unsigned,
           Num:32/unsigned,
           _Timestamp:64/signed,
           Epoch:64/unsigned,
           Offset:64/unsigned,
           _Crc:32/integer,
           Size:32/unsigned>>} = file:read(Fd, ?HEADER_SIZE_B),
    {Offset, Epoch, Num, Size}.

scan_index(IdxFile, SegFd, Offs) when is_list(IdxFile) ->
    {ok, Fd} = file:open(IdxFile, [read, raw, binary, read_ahead]),
    case file:read(Fd, ?IDX_HEADER_SIZE) of
        {ok, ?IDX_HEADER} ->
            scan_index(file:read(Fd, ?INDEX_RECORD_SIZE_B * 2),
                                 Fd, SegFd, Offs);
        Err ->
            Err
    end.

scan_index(eof, IdxFd, _Fd, 0) ->
    ok = file:close(IdxFd),
    %% if the index is empty do we really know the offset will be next
    %% this relies on us always reducing the Offset to within the log range
    {0, ?LOG_HEADER_SIZE};
scan_index(eof, IdxFd, _Fd, _) ->
    ok = file:close(IdxFd),
    eof;
scan_index({ok, <<O:64/unsigned,
                  _T:64/signed,
                  E:64/unsigned,
                  Pos:32/unsigned>>}, IdxFd, Fd, Offset) ->
    ok = file:close(IdxFd),
    {O, E, Num, _} = header_info(Fd, Pos),
    case Offset >= O andalso Offset < (O + Num) of
        true ->
            {O, Pos};
        false ->
            {O + Num, eof}
    end;
scan_index({ok, <<O:64/unsigned,
                  _T:64/signed,
                  _E:64/unsigned,
                  Pos:32/unsigned,
                  ONext:64/unsigned,
                  _:64/signed,
                  _:64/unsigned,
                  _:32/unsigned>>},
           IdxFd, Fd, Offset)  ->
     case Offset >= O andalso Offset < ONext of
         true ->
             {O, Pos};
         false ->
             {ok, _} = file:position(IdxFd, {cur, -?INDEX_RECORD_SIZE_B}),
             scan_index(file:read(IdxFd, ?INDEX_RECORD_SIZE_B * 2),
                                  IdxFd, Fd, Offset)
     end.

parse_records(_Offs, <<>>, Acc) ->
    %% TODO: this could probably be changed to body recursive
    lists:reverse(Acc);
parse_records(Offs, <<0:1, %% simple
                      Len:31/unsigned,
                      Data:Len/binary,
                      Rem/binary>>, Acc) ->
    parse_records(Offs+1, Rem, [{Offs, Data} | Acc]);
parse_records(Offs, <<1:1, %% simple
                      0:3/unsigned, %% compression type
                      _:4/unsigned, %% reserved
                      NumRecs:16/unsigned,
                      Len:32/unsigned,
                      Data:Len/binary,
                      Rem/binary>>, Acc) ->
    Recs = parse_records(Offs, Data, []),
    parse_records(Offs+NumRecs, Rem, lists:reverse(Recs) ++ Acc).

build_log_overview(Dir) when is_list(Dir) ->
    try
        IdxFiles = lists:sort(filelib:wildcard(
                                filename:join(Dir, "*.index"))),
        build_log_overview0(IdxFiles, [])
    catch
        missing_file ->
            build_log_overview(Dir)
    end.

build_log_overview0([], Acc) ->
    lists:reverse(Acc);
build_log_overview0([IdxFile | IdxFiles], Acc0) ->
    IdxFd = open_index_read(IdxFile),
    case file:position(IdxFd, {eof, -?INDEX_RECORD_SIZE_B}) of
        {error, einval} when IdxFiles == [] andalso Acc0 == [] ->
            %% this would happen if the file only contained a header
            ok = file:close(IdxFd),
            SegFile = segment_from_index_file(IdxFile),
            [#seg_info{file = SegFile,
                       index = IdxFile}];
        {error, einval} ->
            ok = file:close(IdxFd),
            build_log_overview0(IdxFiles, Acc0);
        {ok, Pos} ->
            %% ASSERTION: ensure we don't have rubbish data at end of idex
            0 = (Pos - ?IDX_HEADER_SIZE) rem ?INDEX_RECORD_SIZE_B,
            case file:read(IdxFd, ?INDEX_RECORD_SIZE_B) of
                {ok, <<_Offset:64/unsigned,
                       _Timestamp:64/signed,
                      _Epoch:64/unsigned,
                      LastChunkPos:32/unsigned>>} ->
                    ok = file:close(IdxFd),
                    SegFile = segment_from_index_file(IdxFile),
                    Acc = build_segment_info(SegFile, LastChunkPos, IdxFile, Acc0),
                    build_log_overview0(IdxFiles, Acc);
                {error, enoent} ->
                    %% The retention policy could have just been applied
                    ok = file:close(IdxFd),
                    build_log_overview0(IdxFiles, Acc0)
            end
    end.

build_segment_info(SegFile, LastChunkPos, IdxFile, Acc0) ->
    try
        {ok, Fd} = open(SegFile, [read, binary, raw]),
        %% skip header,
        {ok, ?LOG_HEADER_SIZE} = file:position(Fd, ?LOG_HEADER_SIZE),
        case file:read(Fd, ?HEADER_SIZE_B) of
            eof ->
                Acc0;
            {ok, <<?MAGIC:4/unsigned,
                   ?VERSION:4/unsigned,
                   _NumEntries:16/unsigned,
                   FirstNumRecords:32/unsigned,
                   FirstTs:64/signed,
                   FirstEpoch:64/unsigned,
                   FirstChId:64/unsigned,
                   _/binary>>} ->
                {ok, LastChunkPos} = file:position(Fd, LastChunkPos),
                {ok, <<?MAGIC:4/unsigned,
                       ?VERSION:4/unsigned,
                       _LastNumEntries:16/unsigned,
                       LastNumRecords:32/unsigned,
                       LastTs:64/signed,
                       LastEpoch:64/unsigned,
                       LastChId:64/unsigned,
                       _/binary>>} = file:read(Fd, ?HEADER_SIZE_B),
                {ok, Size} = file:position(Fd, eof),
                _ = file:close(Fd),
                [#seg_info{file = SegFile,
                           index = IdxFile,
                           size = Size,
                           first = #chunk_info{epoch = FirstEpoch,
                                               timestamp = FirstTs,
                                               id = FirstChId,
                                               num = FirstNumRecords},
                           last = #chunk_info{epoch = LastEpoch,
                                              timestamp = LastTs,
                                              id = LastChId,
                                              num = LastNumRecords}}
                 | Acc0]
        end
    catch
        missing_file ->
            %% Indexes and segments could be deleted by retention policies while
            %% the log overview is being built. Ignore those segments and keep going
            Acc0
    end.

-spec overview(term()) -> {range(), [{offset(), epoch()}]}.
overview(Dir) ->
    SegInfos = build_log_overview(Dir),
    Range = range_from_segment_infos(SegInfos),
    OffsEpochs = last_offset_epochs(SegInfos),
    {Range, OffsEpochs}.

-spec evaluate_retention(file:filename(), [retention_spec()]) -> range().
evaluate_retention(Dir, Specs) ->
    SegInfos = build_log_overview(Dir),
    range_from_segment_infos(evaluate_retention0(SegInfos, Specs)).

evaluate_retention0(Infos, []) ->
    %% we should never hit empty infos as one should always be left
    Infos;
evaluate_retention0(Infos, [{max_bytes, MaxSize} | Specs]) ->
    RemSegs = eval_max_bytes(Infos, MaxSize),
    evaluate_retention0(RemSegs, Specs);
evaluate_retention0(Infos, [{max_age, Age} | Specs]) ->
    RemSegs = eval_age(Infos, Age),
    evaluate_retention0(RemSegs, Specs).

eval_age([#seg_info{first = #chunk_info{timestamp = Ts},
                    size = Size} = Old
          | Rem] = Infos, Age) ->
    Now = erlang:system_time(millisecond),
    case Ts < Now - Age andalso
         length(Rem) > 0 andalso
         Size > ?LOG_HEADER_SIZE of
        true ->
            %% the oldest timestamp is older than retention
            %% and there are other segments available
            %% we can delete
            ok = delete_segment(Old),
            eval_age(Rem, Age);
        false ->
            Infos
    end;
eval_age(Infos, _Age) ->
    Infos.

eval_max_bytes(SegInfos, MaxSize) ->
    TotalSize = lists:foldl(
                  fun (#seg_info{size = Size}, Acc) ->
                          Acc + Size
                  end, 0, SegInfos),
    case SegInfos of
        _ when length(SegInfos) =< 1 ->
            SegInfos;
        [_, #seg_info{size = 0}] ->
            SegInfos;
        _ ->
            case TotalSize > MaxSize of
                true ->
                    %% we can delete at least one segment segment
                    [Old | Rem] = SegInfos,
                    ok = delete_segment(Old),
                    eval_max_bytes(Rem, MaxSize);
                false  ->
                    SegInfos
            end
    end.

last_offset_epochs([#seg_info{first = undefined,
                              last = undefined}]) ->
    [];
last_offset_epochs([#seg_info{index = IdxFile,
                              first = #chunk_info{epoch = FstE,
                                                  id = FstChId}}
                    | SegInfos]) ->
    FstFd = open_index_read(IdxFile),
    {LastE, LastO, Res} =
        lists:foldl(
          fun (#seg_info{index = I}, Acc) ->
                  Fd = open_index_read(I),
                  last_offset_epoch(
                    file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd, Acc)
          end, last_offset_epoch(
                 file:read(FstFd, ?INDEX_RECORD_SIZE_B), FstFd,
                 {FstE, FstChId, []}), SegInfos),
    lists:reverse([{LastE, LastO} | Res]).

%% aggregates the chunk offsets for each epoch
last_offset_epoch(eof, Fd, Acc) ->
    ok = file:close(Fd),
    Acc;
last_offset_epoch({ok, <<O:64/unsigned,
                         _T:64/signed,
                         CurEpoch:64/unsigned,
                         _:32/unsigned>>},
                  Fd, {CurEpoch, _LastOffs, Acc})  ->
    %% epoch is unchanged
    last_offset_epoch(file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd,
                      {CurEpoch, O, Acc});
last_offset_epoch({ok, <<O:64/unsigned,
                         _T:64/signed,
                         Epoch:64/unsigned,
                         _:32/unsigned>>}, Fd, {CurEpoch, LastOffs, Acc})
  when Epoch > CurEpoch ->
    last_offset_epoch(file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd,
                      {Epoch, O, [{CurEpoch, LastOffs} |  Acc]}).

segment_from_index_file(IdxFile) ->
    Basename = filename:basename(IdxFile, ".index"),
    BaseDir = filename:dirname(IdxFile),
    SegFile0 = filename:join([BaseDir, Basename]),
    SegFile0 ++ ".segment".

make_chunk(Blobs, Timestamp, Epoch, Next) ->
    {NumRecords, IoList} =
    lists:foldr(fun ({batch, NumRecords, CompType, B}, {Count, Acc}) ->
                        Data = [<<1:1, %% batch record type
                                  CompType:3/unsigned,
                                  0:4/unsigned,
                                  NumRecords:16/unsigned,
                                  (iolist_size(B)):32/unsigned>>, B],
                        {Count+NumRecords, [Data | Acc]};
                    (B, {Count, Acc}) ->
                        Data = [<<0:1, %% simple record type
                                  (iolist_size(B)):31/unsigned>>, B],
                        {Count+1, [Data | Acc]}
                end, {0, []}, Blobs),
    Bin = IoList,
    Size = erlang:iolist_size(Bin),
    Crc = erlang:crc32(Bin),
    {[<<?MAGIC:4/unsigned,
        ?VERSION:4/unsigned,
        (length(Blobs)):16/unsigned,
        NumRecords:32/unsigned,
        Timestamp:64/signed,
        Epoch:64/unsigned,
        Next:64/unsigned,
        Crc:32/integer,
        Size:32/unsigned>>,
      Bin], NumRecords}.

write_chunk(Chunk, Timestamp, Epoch, NumRecords,
            #?MODULE{fd = undefined} = State) ->
    write_chunk(Chunk, Timestamp, Epoch, NumRecords, open_new_segment(State));
write_chunk(Chunk, Timestamp, Epoch, NumRecords,
            #?MODULE{cfg = #cfg{max_segment_size = MaxSize,
                                counter = CntRef},
                     fd = Fd,
                     index_fd = IdxFd,
                     mode = #write{segment_size = SegSize,
                                   tail_info = {Next, _}} = Write} = State) ->
    NextOffset = Next + NumRecords,
    Size = iolist_size(Chunk),
    {ok, Cur} = file:position(Fd, cur),
    ok = file:write(Fd, Chunk),
    ok = file:write(IdxFd, <<Next:64/unsigned,
                             Timestamp:64/signed,
                             Epoch:64/unsigned,
                             Cur:32/unsigned>>),
    %% update counters
    counters:put(CntRef, ?C_OFFSET, NextOffset - 1),
    counters:add(CntRef, ?C_CHUNKS, 1),
    case file:position(Fd, cur) of
        {ok, After} when After >= MaxSize ->
            %% close the current file
            ok = file:close(Fd),
            ok = file:close(IdxFd),
            State#?MODULE{fd = undefined,
                          index_fd = undefined,
                          mode = Write#write{
                                   tail_info = {NextOffset, {Epoch, Next}},
                                   segment_size = 0}};
        {ok, _} ->
            State#?MODULE{mode = Write#write{tail_info = {NextOffset, {Epoch, Next}},
                                             segment_size = SegSize + Size}}
    end.


sendfile(_Fd, _Sock, _Pos, 0) ->
    ok;
sendfile(Fd, Sock, Pos, ToSend) ->
    case file:sendfile(Fd, Sock, Pos, ToSend, []) of
        {ok, 0} ->
            %% TODO add counter for this?
            sendfile(Fd, Sock, Pos, ToSend);
        {ok, BytesSent} ->
           sendfile(Fd, Sock, Pos + BytesSent, ToSend - BytesSent)
    end.

range_from_segment_infos([#seg_info{first = undefined,
                                    last = undefined}]) ->
    empty;
range_from_segment_infos([#seg_info{first = #chunk_info{id = FirstChId},
                                    last = #chunk_info{id = LastChId,
                                                       num = LastNumRecs}}]) ->
    {FirstChId, LastChId + LastNumRecs - 1};
range_from_segment_infos([#seg_info{first = #chunk_info{id = FirstChId}}
                          | Rem]) ->
    #seg_info{last = #chunk_info{id = LastChId,
                                 num = LastNumRecs}} = lists:last(Rem),
    {FirstChId, LastChId + LastNumRecs - 1}.

%% find the segment the offset is in _or_ if the offset is the very next
%% chunk offset it will return the last segment
find_segment_for_offset(0, [#seg_info{first = undefined,
                                      last = undefined} = Info]) ->
    {end_of_log, Info};
find_segment_for_offset(Offset,
                        [#seg_info{last =
                                   #chunk_info{id = LastChId,
                                               num = LastNumRecs}} = Info])
  when Offset == LastChId + LastNumRecs ->
    %% the last segment and offset is the next offset
    {end_of_log, Info};
find_segment_for_offset(Offset,
                        [#seg_info{first = #chunk_info{id = FirstChId},
                                   last = #chunk_info{id = LastChId,
                                                      num = LastNumRecs}} = Info
                         | Rem]) ->
    NextChId = LastChId + LastNumRecs,
    case Offset >= FirstChId andalso Offset < NextChId  of
        true ->
            %% we found it
            {found, Info};
        false ->
            find_segment_for_offset(Offset, Rem)
    end;
find_segment_for_offset(_Offset, _) ->
    not_found.

empty_function(_) ->
  ok.

can_read_next_offset(#read{type = offset,
                           next_offset = NextOffset,
                           offset_ref = Ref}) ->
    atomics:get(Ref, 1) >= NextOffset;
can_read_next_offset(#read{type = data}) ->
    true.

incr_next_offset(Num, #read{next_offset = NextOffset} = Read) ->
    Read#read{next_offset = NextOffset + Num}.

make_file_name(N, Suff) ->
    lists:flatten(io_lib:format("~20..0B.~s", [N, Suff])).

open_new_segment(#?MODULE{cfg = #cfg{directory = Dir,
                                     counter = Cnt,
                                     retention = RetentionSpec},
                          fd = undefined,
                          index_fd = undefined,
                          mode = #write{segment_size = _SegSize,
                                        tail_info = {NextOffset, _}}}
                 = State) ->
    Filename = make_file_name(NextOffset, "segment"),
    IdxFilename = make_file_name(NextOffset, "index"),
    {ok, Fd} = file:open(filename:join(Dir, Filename), ?FILE_OPTS_WRITE),
    ok = file:write(Fd, ?LOG_HEADER),
    {ok, IdxFd} = file:open(filename:join(Dir, IdxFilename), ?FILE_OPTS_WRITE),
    ok = file:write(IdxFd, ?IDX_HEADER),
    %% we always move to the end of the file
    {ok, _} = file:position(Fd, eof),
    {ok, _} = file:position(IdxFd, eof),
    %% ask to evaluate retention
    ok = osiris_retention:eval(Dir, RetentionSpec,
                               %% updates the first offset after retention has
                               %% been evaluated
                               fun({Fst, _}) when is_integer(Fst) ->
                                       counters:put(Cnt, ?C_FIRST_OFFSET, Fst);
                                  (_) ->
                                       ok
                               end),
    State#?MODULE{fd = Fd, index_fd = IdxFd}.

open_index_read(File) ->
    {ok, Fd} = open(File, [read, raw, binary, read_ahead]),
    %% We can't use the assertion that index header is correct because of a
    %% race condition between opening the file and writing the header
    %% It seems to happen when retention policies are applied
    %% {ok, ?IDX_HEADER} = file:read(Fd, ?IDX_HEADER_SIZE)
    _ = file:read(Fd, ?IDX_HEADER_SIZE),
    Fd.

throw_missing({error, enoent}) ->
    throw(missing_file);
throw_missing(Any) ->
    Any.

open(SegFile, Options) ->
    throw_missing(file:open(SegFile, Options)).

chunk_id_for_timestamp(#seg_info{index = Idx}, Ts) ->
    Fd = open_index_read(Idx),
    %% scan index file for nearest timestamp
    {ChunkId, _Timestamp, _Epoch, _FilePos} = timestamp_idx_scan(Fd, Ts),
    ChunkId.

timestamp_idx_scan(Fd, Ts) ->
    case file:read(Fd, ?INDEX_RECORD_SIZE_B) of
        {ok, <<ChunkId:64/unsigned,
               Timestamp:64/signed,
               Epoch:64/unsigned,
               FilePos:32/unsigned>>} ->
            case Ts =< Timestamp of
                true ->
                    ok = file:close(Fd),
                    {ChunkId, Timestamp, Epoch, FilePos};
                false ->
                    timestamp_idx_scan(Fd, Ts)
            end;
        eof ->
            ok = file:close(Fd),
            eof
    end.

validate_crc(ChunkId, Crc, IOData) ->
    case erlang:crc32(IOData) of
        Crc -> ok;
        _ ->
            ?ERROR("crc validation failure at chunk id ~b"
                   "data size ~b:~b", [ChunkId, iolist_size(IOData)]),
            exit({crc_validation_failure, {chunk_id, ChunkId}})
    end.

make_counter(#{counter_spec := {Name, Fields}}) ->
    %% create a registered counter
    osiris_counters:new(Name, ?COUNTER_FIELDS ++ Fields);
make_counter(_) ->
    %% if no spec is provided we create a local counter only
    counters:new(?C_NUM_LOG_FIELDS, []).

counter_id(#{counter_spec := {Name, _}}) ->
    Name;
counter_id(_) ->
    undefined.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
