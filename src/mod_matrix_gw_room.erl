%%%-------------------------------------------------------------------
%%% File    : mod_matrix_gw_room.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Matrix rooms
%%% Created :  1 May 2022 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2024   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(mod_matrix_gw_room).

-ifndef(OTP_BELOW_24).
-behaviour(gen_statem).

%% API
-export([start_link/2, supervisor/1, create_db/0,
         get_room_pid/2, join/5, process_pdu/3,
         get_missing_events/7, get_state_ids/4,
         get_rooms_list/0, get_event/3,
         make_join/4, send_join/5,
         binary_to_room_version/1,
         escape/1, unescape/1,
         route/1]).

%% gen_statem callbacks
-export([init/1, terminate/3, code_change/4, callback_mode/0]).
-export([handle_event/4]).

-define(SERVER, ?MODULE).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("mod_matrix_gw.hrl").

-record(matrix_room,
        {room_id  :: binary(),
         pid :: pid()}).

-record(matrix_direct,
        {local_remote,
         room_id :: binary()}).

-record(event,
        {id :: binary(),
         room_version :: #room_version{},
         room_id :: binary(),
         type :: binary(),
         state_key :: binary() | undefined,
         depth :: integer(),
         auth_events :: [binary()],
         sender :: binary(),
         prev_events :: [binary()],
         origin_server_ts :: integer(),
         json :: jiffy:json_object(),
         state_map}).

-record(data,
        {host :: binary(),
         local_user :: jid() | undefined,
         remote_user :: binary() | undefined,
         remote_servers = #{},
         room_id :: binary(),
         room_version :: #room_version{},
         events = #{},
         latest_events = sets:new([{version, 2}]),
         nonlatest_events = sets:new([{version, 2}]),
         outgoing_txns = #{},
         client_state}).

-define(ROOM_CREATE, <<"m.room.create">>).
-define(ROOM_MEMBER, <<"m.room.member">>).
-define(ROOM_JOIN_RULES, <<"m.room.join_rules">>).
-define(ROOM_POWER_LEVELS, <<"m.room.power_levels">>).
-define(ROOM_3PI, <<"m.room.third_party_invite">>).
-define(ROOM_MESSAGE, <<"m.room.message">>).
-define(ROOM_HISTORY_VISIBILITY, <<"m.room.history_visibility">>).

-define(MAX_DEPTH, 16#7FFFFFFFFFFFFFFF).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(binary(), binary()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Host, RoomID) ->
    gen_statem:start_link(?MODULE, [Host, RoomID],
                          ejabberd_config:fsm_limit_opts([])).

-spec supervisor(binary()) -> atom().
supervisor(Host) ->
    gen_mod:get_module_proc(Host, mod_matrix_gw_room_sup).

create_db() ->
    ejabberd_mnesia:create(
      ?MODULE, matrix_room,
      [{ram_copies, [node()]},
       {type, set},
       {attributes, record_info(fields, matrix_room)}]),
    ejabberd_mnesia:create(
      ?MODULE, matrix_direct,
      [{ram_copies, [node()]},
       {type, set},
       {attributes, record_info(fields, matrix_direct)}]),
    ok.

get_room_pid(Host, RoomID) ->
    case get_existing_room_pid(Host, RoomID) of
        {error, not_found} ->
            case supervisor:start_child(supervisor(Host),
                                        [Host, RoomID]) of
                {ok, undefined} -> {error, ignored};
                Res -> Res
            end;
        {ok, Pid} ->
            {ok, Pid}
    end.

get_existing_room_pid(_Host, RoomID) ->
    case mnesia:dirty_read(matrix_room, RoomID) of
        [] ->
            {error, not_found};
        [#matrix_room{pid = Pid}] ->
            {ok, Pid}
    end.

join(Host, MatrixServer, RoomID, Sender, UserID) ->
    case get_room_pid(Host, RoomID) of
        {ok, Pid} ->
            gen_statem:cast(Pid, {join, MatrixServer, RoomID, Sender, UserID});
        {error, _} = Error ->
            Error
    end.

route(#message{from = From, to = To, body = Body} = _Pkt) ->
    case binary:split(To#jid.luser, <<"%">>) of
        [EscU, EscS] ->
            U = unescape(EscU),
            S = unescape(EscS),
            ToMatrixID = <<$@, U/binary, $:, S/binary>>,
            Key = {{From#jid.luser, From#jid.lserver}, ToMatrixID},
            Text = xmpp:get_text(Body),
            Host = ejabberd_config:get_myname(),
            case mnesia:dirty_read(matrix_direct, Key) of
                [#matrix_direct{room_id = RoomID}] ->
                    ?DEBUG("msg ~p~n", [{RoomID, From, ToMatrixID, Text}]),
                    case get_existing_room_pid(Host, RoomID) of
                        {ok, Pid} ->
                            MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
                            FromMatrixID =
                                <<$@, (From#jid.luser)/binary, $:, MatrixServer/binary>>,
                            JSON =
                                #{<<"content">> =>
                                      #{<<"body">> => Text,
                                        <<"msgtype">> => <<"m.text">>},
                                  <<"sender">> => FromMatrixID,
                                  <<"type">> => ?ROOM_MESSAGE},
                            gen_statem:cast(Pid, {add_event, JSON}),
                            ok;
                        {error, _} ->
                            %%TODO
                            ok
                    end;
                _ ->
                    RoomID = new_room_id(),
                    ?DEBUG("new room id ~p~n", [RoomID]),
                    case get_room_pid(Host, RoomID) of
                        {ok, Pid} ->
                            MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
                            FromMatrixID =
                                <<$@, (From#jid.luser)/binary, $:, MatrixServer/binary>>,
                            gen_statem:cast(Pid, {create, MatrixServer, RoomID,
                                                  FromMatrixID, ToMatrixID}),
                            JSONs =
                                [#{<<"content">> =>
                                       #{<<"creator">> => FromMatrixID,
                                         <<"room_version">> => <<"9">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => <<"">>,
                                   <<"type">> => ?ROOM_CREATE},
                                 #{<<"content">> =>
                                       #{<<"membership">> => <<"join">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => FromMatrixID,
                                   <<"type">> => ?ROOM_MEMBER},
                                 #{<<"content">> =>
                                       #{<<"ban">> => 50,
                                         <<"events">> =>
                                             #{<<"m.room.avatar">> => 50,
                                               <<"m.room.canonical_alias">> => 50,
                                               <<"m.room.encryption">> => 100,
                                               <<"m.room.history_visibility">> => 100,
                                               <<"m.room.name">> => 50,
                                               <<"m.room.power_levels">> => 100,
                                               <<"m.room.server_acl">> => 100,
                                               <<"m.room.tombstone">> => 100},
                                         <<"events_default">> => 0,
                                         <<"historical">> => 100,
                                         <<"invite">> => 0,
                                         <<"kick">> => 50,
                                         <<"redact">> => 50,
                                         <<"state_default">> => 50,
                                         <<"users">> =>
                                             #{FromMatrixID => 100,
                                               ToMatrixID => 100},
                                         <<"users_default">> => 0},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => <<"">>,
                                   <<"type">> => ?ROOM_POWER_LEVELS},
                                 #{<<"content">> => #{<<"join_rule">> => <<"invite">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => <<"">>,
                                   <<"type">> => ?ROOM_JOIN_RULES},
                                 #{<<"content">> => #{<<"history_visibility">> => <<"shared">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => <<"">>,
                                   <<"type">> => ?ROOM_HISTORY_VISIBILITY},
                                 #{<<"content">> => #{<<"guest_access">> => <<"can_join">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => <<"">>,
                                   <<"type">> => <<"m.room.guest_access">>},
                                 #{<<"content">> =>
                                       #{<<"is_direct">> => true,
                                         <<"membership">> => <<"invite">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"state_key">> => ToMatrixID,
                                   <<"type">> => ?ROOM_MEMBER},
                                 #{<<"content">> =>
                                       #{<<"body">> => Text,
                                         <<"msgtype">> => <<"m.text">>},
                                   <<"sender">> => FromMatrixID,
                                   <<"type">> => ?ROOM_MESSAGE}
                                ],
                            lists:foreach(fun(JSON) ->
                                                  gen_statem:cast(Pid, {add_event, JSON})
                                          end, JSONs),
                            ok;
                        {error, _} ->
                            %%TODO
                            ok
                    end
            end;
        _ ->
            ok
    end;
route(_) ->
    ok.

get_missing_events(Host, Origin, RoomID, EarliestEvents, LatestEvents, Limit, MinDepth) ->
    case get_existing_room_pid(Host, RoomID) of
        {ok, Pid} ->
            Events = gen_statem:call(
                       Pid, {get_missing_events, Origin, EarliestEvents, LatestEvents,
                             Limit, MinDepth}),
            [E#event.json || E <- Events];
        {error, _} ->
            %%TODO
            []
    end.

get_state_ids(Host, Origin, RoomID, EventID) ->
    case get_existing_room_pid(Host, RoomID) of
        {ok, Pid} ->
            gen_statem:call(
              Pid, {get_state_ids, Origin, EventID});
        {error, _} ->
            %%TODO
            {error, room_not_found}
    end.

get_rooms_list() ->
    mnesia:dirty_all_keys(matrix_room).

get_event(Host, RoomID, EventID) ->
    case get_existing_room_pid(Host, RoomID) of
        {ok, Pid} ->
            gen_statem:call(Pid, {get_event, EventID});
        {error, _} ->
            %%TODO
            {error, room_not_found}
    end.

make_join(Host, RoomID, UserID, Params) ->
    case get_existing_room_pid(Host, RoomID) of
        {ok, Pid} ->
            gen_statem:call(Pid, {make_join, UserID, Params});
        {error, _} ->
            {error, room_not_found}
    end.

send_join(Host, Origin, RoomID, EventID, JSON) ->
    case process_pdu(Host, Origin, JSON) of
        {ok, EventID} ->
            {ok, EventJSON} = get_event(Host, RoomID, EventID),
            {ok, AuthChain, StateMap} = get_state_ids(Host, Origin, RoomID, EventID),
            AuthChainJSON =
                lists:map(fun(EID) -> {ok, E} = get_event(Host, RoomID, EID), E end, AuthChain),
            StateMapJSON =
                lists:map(fun(EID) -> {ok, E} = get_event(Host, RoomID, EID), E end, StateMap),
            MyOrigin = mod_matrix_gw_opt:matrix_domain(Host),
            Res = #{<<"event">> => EventJSON,
                    <<"state">> => StateMapJSON,
                    <<"auth_chain">> => AuthChainJSON,
                    <<"origin">> => MyOrigin},
            {ok, Res};
        {ok, _} ->
            {error, <<"Bad event id">>};
        {error, _} = Error ->
            Error
    end.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> gen_statem:init_result(term()).
init([Host, RoomID]) ->
    mnesia:dirty_write(
      #matrix_room{room_id = RoomID,
                   pid = self()}),
    {ok, state_name,
     #data{host = Host,
           room_id = RoomID,
           room_version = binary_to_room_version(<<"9">>)}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If the gen_statem runs with CallbackMode =:= handle_event_function
%% this function is called for every event a gen_statem receives.
%% @end
%%--------------------------------------------------------------------
-spec handle_event(
        gen_statem:event_type(), Msg :: term(),
        State :: term(), Data :: term()) ->
                          gen_statem:handle_event_result().
handle_event({call, From}, get_room_version, _State, Data) ->
    {keep_state, Data, [{reply, From, Data#data.room_version}]};
handle_event({call, From}, get_latest_events, _State, Data) ->
    {keep_state, Data, [{reply, From, Data#data.latest_events}]};
%% set_latest_events is for debugging only
handle_event({call, From}, {set_latest_events, LE}, _State, Data) ->
    {keep_state, Data#data{latest_events = LE}, [{reply, From, ok}]};
handle_event({call, From}, {find_event, EventID}, _State, Data) ->
    Res = maps:find(EventID, Data#data.events),
    {keep_state, Data, [{reply, From, Res}]};
handle_event({call, From}, {partition_missed_events, EventIDs}, _State, Data) ->
    Res = lists:partition(
            fun(EventID) ->
                    maps:is_key(EventID, Data#data.events)
            end, EventIDs),
    {keep_state, Data, [{reply, From, Res}]};
handle_event({call, From}, {partition_events_with_statemap, EventIDs}, _State, Data) ->
    Res = lists:partition(
            fun(EventID) ->
                    case maps:find(EventID, Data#data.events) of
                        {ok, #event{state_map = undefined}} -> false;
                        {ok, _} -> true;
                        error -> false
                    end
            end, EventIDs),
    {keep_state, Data, [{reply, From, Res}]};
handle_event({call, From}, {auth_and_store_external_events, EventList}, _State, Data) ->
    try
        Data2 = do_auth_and_store_external_events(EventList, Data),
        {keep_state, Data2, [{reply, From, ok}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed auth_and_store_external_events: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, [{reply, From, {error, Reason}},
                                {next_event, internal, update_client}]}
    end;
handle_event({call, From}, {resolve_auth_store_event, Event}, _State, Data) ->
    try
        Data2 = do_resolve_auth_store_event(Event, Data),
        {keep_state, Data2, [{reply, From, ok},
                             {next_event, internal, update_client}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed resolve_auth_store_event: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, [{reply, From, {error, Reason}},
                                {next_event, internal, update_client}]}
    end;
handle_event({call, From},
             {get_missing_events, Origin, EarliestEvents, LatestEvents, Limit, MinDepth},
             _State, Data) ->
    try
        PDUs = do_get_missing_events(Origin, EarliestEvents, LatestEvents, Limit, MinDepth, Data),
        {keep_state_and_data, [{reply, From, PDUs}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed get_missing_events: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From},
             {get_state_ids, Origin, EventID},
             _State, Data) ->
    try
        Reply = do_get_state_ids(Origin, EventID, Data),
        {keep_state_and_data, [{reply, From, Reply}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed get_state_ids: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From},
             {get_event, EventID},
             _State, Data) ->
    try
        Reply =
            case maps:find(EventID, Data#data.events) of
                {ok, Event} ->
                    {ok, Event#event.json};
                _ ->
                    {error, event_not_found}
            end,
        {keep_state_and_data, [{reply, From, Reply}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed get_event: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From},
             {make_join, UserID, Params},
             _State, Data) ->
    try
        Ver = (Data#data.room_version)#room_version.id,
        Reply =
            case lists:member({<<"ver">>, Ver}, Params) of
                true ->
                    JSON = #{<<"content">> =>
                                 #{<<"membership">> => <<"join">>},
                             <<"sender">> => UserID,
                             <<"state_key">> => UserID,
                             <<"type">> => ?ROOM_MEMBER},
                    {JSON2, _} = fill_event(JSON, Data),
                    Event = json_to_event(JSON2, Data#data.room_version),
                    case check_event_auth(Event, Data) of
                        true ->
                            Res = #{<<"event">> => JSON2,
                                    <<"room_version">> => Ver},
                            {ok, Res};
                        false ->
                            {error, not_invited}
                    end;
                false ->
                    {error, {incompatible_version, Ver}}
            end,
        {keep_state_and_data, [{reply, From, Reply}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed make_join: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
handle_event(cast, {join, MatrixServer, RoomID, Sender, UserID}, State, Data) ->
    Host = Data#data.host,
    %% TODO: check if there is another solution to "You are not invited to this room" and not receiving the first messages in the room
    timer:sleep(1000),
    case user_id_to_jid(UserID, Data) of
        #jid{lserver = Host} = UserJID ->
            mnesia:dirty_write(
              #matrix_direct{local_remote = {{UserJID#jid.luser, UserJID#jid.lserver}, Sender},
                             room_id = RoomID}),
            MakeJoinRes =
                mod_matrix_gw:send_request(
                  Host, get, MatrixServer,
                  [<<"_matrix">>, <<"federation">>, <<"v1">>, <<"make_join">>,
                   RoomID, UserID],
                  [{<<"ver">>, <<"9">>},
                   {<<"ver">>, <<"10">>},
                   {<<"ver">>, <<"11">>}],
                  none,
                  [{timeout, 5000}],
                  [{sync, true},
                   {body_format, binary}]),
            ?DEBUG("make_join ~p~n", [MakeJoinRes]),
            case MakeJoinRes of
                {ok, {{_, 200, _}, _Headers, Body}} ->
                    try jiffy:decode(Body, [return_maps]) of
                        #{<<"event">> := Event,
                          <<"room_version">> := SRoomVersion} ->
                            case binary_to_room_version(SRoomVersion) of
                                false ->
                                    ?DEBUG("unsupported room version on make_join: ~p", [MakeJoinRes]),
                                    {keep_state, Data, []};
                                #room_version{} = RoomVersion ->
                                    Origin = mod_matrix_gw_opt:matrix_domain(Host),
                                    Event2 =
                                        Event#{<<"origin">> => Origin,
                                               <<"origin_server_ts">> =>
                                                   erlang:system_time(millisecond)},
                                    CHash = mod_matrix_gw:content_hash(Event2),
                                    Event3 =
                                        Event2#{<<"hashes">> =>
                                                    #{<<"sha256">> =>
                                                          mod_matrix_gw:base64_encode(CHash)}},
                                    Event4 = mod_matrix_gw:sign_event(Host, Event3, RoomVersion),
                                    EventID = mod_matrix_gw:get_event_id(Event4, RoomVersion),
                                    SendJoinRes =
                                        mod_matrix_gw:send_request(
                                          Data#data.host, put, MatrixServer,
                                          [<<"_matrix">>, <<"federation">>,
                                           <<"v2">>, <<"send_join">>,
                                           RoomID, EventID],
                                          [],
                                          Event4,
                                          [{timeout, 5000}],
                                          [{sync, true},
                                           {body_format, binary}]),
                                    ?DEBUG("send_join ~p~n", [SendJoinRes]),
                                    process_send_join_res(MatrixServer, SendJoinRes, RoomVersion,
                                                          Data#data{local_user = UserJID,
                                                                    remote_user = Sender,
                                                                    room_version = RoomVersion})
                            end;
                        _JSON ->
                            ?DEBUG("received bad JSON on make_join: ~p", [MakeJoinRes]),
                            {next_state, State, Data, []}
                    catch
                        _:_ ->
                            ?DEBUG("received bad JSON on make_join: ~p", [MakeJoinRes]),
                            {next_state, State, Data, []}
                    end;
                _ ->
                    ?DEBUG("failed make_join: ~p", [MakeJoinRes]),
                    {next_state, State, Data, []}
            end;
        UserJID ->
            ?INFO_MSG("bad join user id: ~p", [{UserID, UserJID}]),
            {stop, normal}
    end;
handle_event(cast, {create, _MatrixServer, RoomID, LocalUserID, RemoteUserID}, _State, Data) ->
    Host = Data#data.host,
    case user_id_to_jid(LocalUserID, Data) of
        #jid{lserver = Host} = UserJID ->
            mnesia:dirty_write(
              #matrix_direct{local_remote = {{UserJID#jid.luser, UserJID#jid.lserver}, RemoteUserID},
                             room_id = RoomID}),
            {keep_state, Data#data{local_user = UserJID,
                                   remote_user = RemoteUserID}, []};
        UserJID ->
            ?INFO_MSG("bad create user id: ~p", [{LocalUserID, UserJID}]),
            {stop, normal}
    end;
handle_event(cast, {add_event, JSON}, _State, Data) ->
    try
        Data2 = add_event(JSON, Data),
        {keep_state, Data2, [{next_event, internal, update_client}]}
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed add_event: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, []}
    end;
handle_event(cast, Msg, State, Data) ->
    ?WARNING_MSG("Unexpected cast: ~p", [Msg]),
    {next_state, State, Data, []};
handle_event(internal, update_client, _State, Data) ->
    try
        case update_client(Data) of
            {ok, Data2} ->
                {keep_state, Data2, []};
            {leave, LeaveReason, Data2} ->
                ?INFO_MSG("leaving ~p: ~p", [Data#data.room_id, LeaveReason]),
                Host = Data#data.host,
                MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
                JID = Data#data.local_user,
                LocalUserID = <<$@, (JID#jid.luser)/binary, $:, MatrixServer/binary>>,
                JSON = #{<<"content">> =>
                             #{<<"membership">> => <<"leave">>},
                         <<"sender">> => LocalUserID,
                         <<"state_key">> => LocalUserID,
                         <<"type">> => ?ROOM_MEMBER},
                {keep_state, Data2, [{next_event, cast, {add_event, JSON}}]};
            stop ->
                {stop, normal}
        end
    catch
        Class:Reason:ST ->
            ?INFO_MSG("failed update_client: ~p", [{Class, Reason, ST}]),
            {keep_state, Data, []}
    end;
handle_event(info, {send_txn_res, RequestID, TxnID, Server, Res}, _State, Data) ->
    case Data#data.outgoing_txns of
        #{Server := {{RequestID, TxnID, _Events}, Queue}} ->
            case Res of
                {{_, 200, _}, _Headers, _Body} ->
                    Data2 =
                        case Queue of
                            [] ->
                                Data#data{outgoing_txns =
                                              maps:remove(Server, Data#data.outgoing_txns)};
                            _ ->
                                send_new_txn(lists:reverse(Queue), Server, Data)
                        end,
                    {keep_state, Data2, []};
                _ ->
                    %% TODO
                    erlang:send_after(30000, self(), {resend_txn, Server}),
                    {keep_state, Data, []}
            end;
        _ ->
            {keep_state, Data, []}
    end;
handle_event(info, {resend_txn, Server}, _State, Data) ->
    case Data#data.outgoing_txns of
        #{Server := {{_RequestID, TxnID, Events}, Queue}} ->
            Data2 = send_txn(TxnID, Events, Server, Queue, Data),
            {keep_state, Data2, []};
        _ ->
            {keep_state, Data, []}
    end;
handle_event(info, Info, State, Data) ->
    ?WARNING_MSG("Unexpected info: ~p", [Info]),
    {next_state, State, Data, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: term(), State :: term(), Data :: term()) ->
                       any().
terminate(Reason, _State, Data) ->
    mnesia:dirty_delete_object(
      #matrix_room{room_id = Data#data.room_id,
                   pid = self()}),
    %% TODO: wait for messages
    case Data#data.local_user of
        #jid{} = LocalUserJID ->
            mnesia:dirty_delete_object(
              #matrix_direct{local_remote = {{LocalUserJID#jid.luser, LocalUserJID#jid.lserver},
                                             Data#data.remote_user},
                             room_id = Data#data.room_id});
        _ ->
            ok
    end,
    ?INFO_MSG("terminated ~p: ~p", [Data#data.room_id, Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(
        OldVsn :: term() | {down,term()},
        State :: term(), Data :: term(), Extra :: term()) ->
                         {ok, NewState :: term(), NewData :: term()}.
code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    handle_event_function.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_event_exn(EventID, Data) ->
    maps:get(EventID, Data#data.events).

process_send_join_res(MatrixServer, SendJoinRes, RoomVersion, Data) ->
    case SendJoinRes of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            try
                case jiffy:decode(Body, [return_maps]) of
                    #{<<"auth_chain">> := JSONAuthChain,
                      <<"event">> := JSONEvent,
                      <<"state">> := JSONState} = JSON when is_list(JSONAuthChain),
                                                            is_list(JSONState) ->
                        AuthChain =
                            lists:map(fun(J) -> json_to_event(J, RoomVersion) end,
                                      JSONAuthChain),
                        State =
                            lists:map(fun(J) -> json_to_event(J, RoomVersion) end,
                                      JSONState),
                        Event = json_to_event(JSONEvent, RoomVersion),
                        ?DEBUG("send_join res: ~p~n", [JSON]),
                        lists:foreach(
                          fun(E) ->
                                  case check_event_sig_and_hash(Data#data.host, E) of
                                      {ok, _} -> ok;
                                      {error, Error} -> error(Error)
                                  end
                          end, [Event] ++ AuthChain ++ State),
                        CreateEvents =
                            lists:filter(
                              fun(#event{type = ?ROOM_CREATE,
                                         state_key = <<"">>}) -> true;
                                 (_) -> false
                              end, State),
                        RoomVersionID = RoomVersion#room_version.id,
                        case CreateEvents of
                            [#event{
                                id = CreateEventID,
                                json =
                                    #{<<"content">> :=
                                          #{<<"room_version">> :=
                                                RoomVersionID}}} =
                                 CreateEvent] ->
                                ?DEBUG("create event: ~p~n", [CreateEvent]),
                                AuthCreateEvents =
                                    lists:filtermap(
                                      fun(#event{id = ID,
                                                 type = ?ROOM_CREATE,
                                                 state_key = <<"">>}) ->
                                              {true, ID};
                                         (_) -> false
                                      end, AuthChain),
                                case AuthCreateEvents of
                                    [CreateEventID] ->
                                        Data2 = process_send_join_res2(
                                                  MatrixServer, AuthChain, Event, State,
                                                  Data),
                                        {keep_state, Data2, []};
                                    _ ->
                                        ?DEBUG("bad auth create events: ~p, expected: ~p", [AuthCreateEvents, [CreateEventID]]),
                                        {keep_state, Data, []}
                                end;
                            _ ->
                                ?DEBUG("bad create event: ~p", [CreateEvents]),
                                {keep_state, Data, []}
                        end
                end
            catch
                error:{invalid_signature, EventID} ->
                    ?INFO_MSG("failed signature check on event ~p", [EventID]),
                    {keep_state, Data, []};
                Class:Reason:ST ->
                    ?INFO_MSG("failed send_join: ~p", [{Class, Reason, ST}]),
                    {keep_state, Data, []}
            end;
        _ ->
            ?DEBUG("failed send_join: ~p", [SendJoinRes]),
            {keep_state, Data, []}
    end.

process_send_join_res2(MatrixServer, AuthChain, Event, State, Data) ->
    Data2 = do_auth_and_store_external_events(AuthChain ++ State, Data),
    StateMap =
        lists:foldl(
          fun(E, Acc) ->
                  Acc#{{E#event.type, E#event.state_key} => E#event.id}
          end, #{}, State),
    StateMap2 =
        case Event#event.state_key of
            undefined ->
                StateMap;
            _ ->
                StateMap#{{Event#event.type, Event#event.state_key} => Event#event.id}
        end,
    Event2 = Event#event{state_map = StateMap2},
    Data3 =
        case check_event_auth(Event2, Data2) of
            true ->
                store_event(Event2, Data2);
            false ->
                error({event_auth_error, Event2#event.id})
        end,
    MissingEventsQuery =
        #{<<"earliest_events">> => [],
          <<"latest_events">> => [Event#event.id],
          <<"limit">> => 10},
    Host = Data3#data.host,
    Pid = self(),
    RoomID = Data3#data.room_id,
    RoomVersion = Data3#data.room_version,
    mod_matrix_gw:send_request(
      Host, post, MatrixServer,
      [<<"_matrix">>, <<"federation">>, <<"v1">>,
       <<"get_missing_events">>, RoomID],
      [],
      MissingEventsQuery,
      [{timeout, 60000}],
      [{sync, false},
       {body_format, binary},
       {receiver,
        fun({_, Res}) ->
                process_missing_events_res(Host, MatrixServer, Pid, RoomID, RoomVersion,
                                           {ok, Res})
        end}]),
    Data3.

do_auth_and_store_external_events(EventList, Data) ->
    Events = maps:from_list(lists:map(fun(E) -> {E#event.id, E} end,
                                      EventList)),
    SortedEvents = simple_toposort(Events),
    ?DEBUG("topo ~p~n", [SortedEvents]),
    %% TODO: add more checks
    Data2 =
        lists:foldl(
          fun(E, Acc) ->
                  Ev = maps:get(E, Events),
                  case check_event_auth(Ev, Acc) of
                      true ->
                          store_event(Ev, Acc);
                      false ->
                          error({event_auth_error, E})
                  end
          end, Data, SortedEvents),
    Data2.

auth_and_store_external_events(Pid, EventList) ->
    gen_statem:call(Pid, {auth_and_store_external_events, EventList}).

check_event_auth(Event, Data) ->
    StateMap =
        maps:from_list(
          lists:map(
            fun(EID) ->
                    E = get_event_exn(EID, Data),
                    {{E#event.type, E#event.state_key}, E}
            end, Event#event.auth_events)),
    check_event_auth(Event, StateMap, Data).

check_event_auth(Event, StateMap, Data) ->
    RoomVersion = Data#data.room_version,
    case Event#event.type of
        ?ROOM_CREATE ->
            case maps:size(StateMap) of
                0 ->
                    RDomain = mod_matrix_gw:get_id_domain_exn(Data#data.room_id),
                    SDomain = mod_matrix_gw:get_id_domain_exn(Event#event.sender),
                    if
                        RDomain == SDomain ->
                            %% TODO: check version
                            case RoomVersion#room_version.implicit_room_creator of
                                false ->
                                    case Event#event.json of
                                        #{<<"content">> :=
                                              #{<<"creator">> := _}} ->
                                            true;
                                        _ ->
                                            false
                                    end;
                                true ->
                                    true
                            end;
                        true ->
                            false
                    end;
                _ ->
                    false
            end;
        _ ->
            case StateMap of
                #{{?ROOM_CREATE, <<"">>} := _} ->
                    case Event#event.type of
                        ?ROOM_MEMBER ->
                            case Event#event.json of
                                #{<<"content">> :=
                                      #{<<"membership">> := Membership}} ->
                                    %% TODO: join_authorised_via_users_server
                                    case Membership of
                                        <<"join">> ->
                                            check_event_auth_join(
                                              Event, StateMap, Data);
                                        <<"invite">> ->
                                            check_event_auth_invite(
                                              Event, StateMap, Data);
                                        <<"leave">> ->
                                            check_event_auth_leave(
                                              Event, StateMap, Data);
                                        <<"ban">> ->
                                            check_event_auth_ban(
                                              Event, StateMap, Data);
                                        <<"knock">> ->
                                            check_event_auth_knock(
                                              Event, StateMap, Data);
                                        _ ->
                                            false
                                    end;
                                _ ->
                                    false
                            end;
                        _ ->
                            Sender = Event#event.sender,
                            case maps:find({?ROOM_MEMBER, Sender}, StateMap) of
                                {ok, #event{
                                        json = #{<<"content">> :=
                                                     #{<<"membership">> :=
                                                           <<"join">>}}}} ->
                                    case Event#event.type of
                                        ?ROOM_3PI ->
                                            %% TODO
                                            {todo, Event};
                                        _ ->
                                            case check_event_power_level(
                                                   Event, StateMap, Data) of
                                                true ->
                                                    case Event#event.type of
                                                        ?ROOM_POWER_LEVELS ->
                                                            check_event_auth_power_levels(
                                                              Event, StateMap, Data);
                                                        _ ->
                                                            true
                                                    end;
                                                false ->
                                                    false
                                            end
                                    end;
                                _ ->
                                    false
                            end
                    end;
                _ ->
                    false
            end
    end.

check_event_auth_join(Event, StateMap, Data) ->
    RoomVersion = Data#data.room_version,
    StateKey = Event#event.state_key,
    case {length(Event#event.auth_events),
          RoomVersion#room_version.implicit_room_creator,
          maps:get({?ROOM_CREATE, <<"">>}, StateMap, undefined)} of
        {1, false, #event{json = #{<<"content">> := #{<<"creator">> := StateKey}}}} ->
            ?DEBUG("creator join ~p~n", [Event]),
            true;
        {1, true, #event{sender = StateKey}} ->
            ?DEBUG("creator join ~p~n", [Event]),
            true;
        _ ->
            case Event#event.sender of
                StateKey ->
                    JoinRule =
                        case maps:find({?ROOM_JOIN_RULES, <<"">>}, StateMap) of
                            {ok, #event{
                                    json = #{<<"content">> :=
                                                 #{<<"join_rule">> := JR}}}} ->
                                JR;
                            _ ->
                                <<"invite">>
                        end,
                    case maps:find({?ROOM_MEMBER, StateKey}, StateMap) of
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   <<"ban">>}}}} ->
                            false;
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   <<"join">>}}}} ->
                            true;
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   SenderMembership}}}} ->
                            case {JoinRule, SenderMembership} of
                                {<<"public">>, _} -> true;
                                {<<"invite">>, <<"invite">>} -> true;
                                {<<"knock">>, <<"invite">>} -> true;
                                {<<"restricted">>, <<"invite">>} ->
                                    %% TODO
                                    true;
                                {<<"knock_restricted">>, <<"invite">>}
                                  when (Data#data.room_version)#room_version.knock_restricted_join_rule ->
                                    %% TODO
                                    true;
                                _ -> false
                            end;
                        error ->
                            case JoinRule of
                                <<"public">> -> true;
                                _ -> false
                            end
                    end;
                _ ->
                    false
            end
    end.

check_event_auth_invite(Event, StateMap, Data) ->
    StateKey = Event#event.state_key,
    case Event#event.json of
        #{<<"content">> := #{<<"third_party_invite">> := _}} ->
            %% TODO
            {todo, Event};
        _ ->
            case maps:find({?ROOM_MEMBER, Event#event.sender}, StateMap) of
                {ok, #event{
                        json = #{<<"content">> :=
                                     #{<<"membership">> :=
                                           <<"join">>}}}} ->
                    case maps:find({?ROOM_MEMBER, StateKey}, StateMap) of
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   <<"ban">>}}}} ->
                            false;
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   <<"join">>}}}} ->
                            false;
                        _ ->
                            UserLevel = get_user_power_level(Event#event.sender, StateMap, Data),
                            InviteLevel =
                                case maps:find({?ROOM_POWER_LEVELS, <<"">>}, StateMap) of
                                    {ok, #event{json = #{<<"content">> := #{<<"invite">> := S}}}} ->
                                        get_int(S);
                                    _ -> 0
                                end,
                            UserLevel >= InviteLevel
                    end;
                _ ->
                    false
            end
    end.

check_event_auth_leave(Event, StateMap, Data) ->
    StateKey = Event#event.state_key,
    case maps:find({?ROOM_MEMBER, Event#event.sender}, StateMap) of
        {ok, #event{
                json = #{<<"content">> :=
                             #{<<"membership">> := SenderMembership}}}} ->
            case Event#event.sender of
                StateKey ->
                    case SenderMembership of
                        <<"invite">> -> true;
                        <<"join">> -> true;
                        <<"knock">> -> true;
                        _ -> false
                    end;
                _ ->
                    case SenderMembership of
                        <<"join">> ->
                            SenderLevel = get_user_power_level(Event#event.sender, StateMap, Data),
                            CheckBan =
                                case maps:find({?ROOM_MEMBER, StateKey}, StateMap) of
                                    {ok, #event{
                                            json = #{<<"content">> :=
                                                         #{<<"membership">> :=
                                                               <<"ban">>}}}} ->
                                        BanLevel =
                                            case maps:find({?ROOM_POWER_LEVELS, <<"">>}, StateMap) of
                                                {ok, #event{json = #{<<"content">> := #{<<"ban">> := S}}}} ->
                                                    get_int(S);
                                                _ -> 50
                                            end,
                                        SenderLevel >= BanLevel;
                                    _ ->
                                        true
                                end,
                            if
                                CheckBan ->
                                    KickLevel =
                                        case maps:find({?ROOM_POWER_LEVELS, <<"">>}, StateMap) of
                                            {ok, #event{json = #{<<"content">> := #{<<"kick">> := S1}}}} ->
                                                get_int(S1);
                                            _ -> 50
                                        end,
                                    TargetLevel = get_user_power_level(StateKey, StateMap, Data),
                                    SenderLevel >= KickLevel andalso SenderLevel > TargetLevel;
                                true ->
                                    false
                            end;
                        _ ->
                            false
                    end
            end;
        _ ->
            false
    end.

check_event_auth_ban(Event, StateMap, Data) ->
    StateKey = Event#event.state_key,
    case maps:find({?ROOM_MEMBER, Event#event.sender}, StateMap) of
        {ok, #event{
                json = #{<<"content">> :=
                             #{<<"membership">> := SenderMembership}}}} ->
            case SenderMembership of
                <<"join">> ->
                    SenderLevel = get_user_power_level(Event#event.sender, StateMap, Data),
                    BanLevel =
                        case maps:find({?ROOM_POWER_LEVELS, <<"">>}, StateMap) of
                            {ok, #event{json = #{<<"content">> := #{<<"ban">> := S}}}} ->
                                get_int(S);
                            _ -> 50
                        end,
                    TargetLevel = get_user_power_level(StateKey, StateMap, Data),
                    SenderLevel >= BanLevel andalso SenderLevel > TargetLevel;
                _ ->
                    false
            end;
        _ ->
            false
    end.

check_event_auth_knock(Event, StateMap, Data) ->
    StateKey = Event#event.state_key,
    case Event#event.sender of
        StateKey ->
            JoinRule =
                case maps:find({?ROOM_JOIN_RULES, <<"">>}, StateMap) of
                    {ok, #event{
                            json = #{<<"content">> :=
                                         #{<<"join_rule">> := JR}}}} ->
                        JR;
                    _ ->
                        <<"invite">>
                end,
            IsKnock =
                case JoinRule of
                    <<"knock">> ->
                        true;
                    <<"knock_restricted">> when (Data#data.room_version)#room_version.knock_restricted_join_rule ->
                        true;
                    _ ->
                        false
                end,
            case IsKnock of
                true ->
                    case maps:find({?ROOM_MEMBER, StateKey}, StateMap) of
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   <<"ban">>}}}} ->
                            false;
                        {ok, #event{
                                json = #{<<"content">> :=
                                             #{<<"membership">> :=
                                                   <<"join">>}}}} ->
                            false;
                        _ ->
                            true
                    end;
                false ->
                    false
            end;
        _ ->
            false
    end.

check_event_power_level(Event, StateMap, Data) ->
    PLContent =
        case maps:find({?ROOM_POWER_LEVELS, <<"">>}, StateMap) of
            {ok, #event{json = #{<<"content">> := C}}} -> C;
            _ -> #{}
        end,
    RequiredLevel = get_event_power_level(Event#event.type, PLContent),
    UserLevel = get_user_power_level(Event#event.sender, StateMap, Data),
    if
        UserLevel >= RequiredLevel ->
            Sender = Event#event.sender,
            case Event#event.state_key of
                Sender -> true;
                <<$@, _/binary>> -> false;
                _ -> true
            end;
        true ->
            false
    end.

get_event_power_level(Type, PL) ->
    case PL of
        #{Type := Level} -> get_int(Level);
        #{<<"events_default">> := Level} -> get_int(Level);
        _ -> 0
    end.

get_user_power_level(User, StateMap, Data) ->
    RoomVersion = Data#data.room_version,
    PL =
        case maps:find({?ROOM_POWER_LEVELS, <<"">>}, StateMap) of
            {ok, #event{json = #{<<"content">> := C}}} -> C;
            _ -> #{}
        end,
    case PL of
        #{<<"users">> := #{User := Level}} -> get_int(Level);
        #{<<"users_default">> := Level} -> get_int(Level);
        _ ->
            case {RoomVersion#room_version.implicit_room_creator, StateMap} of
                {false,
                 #{{?ROOM_CREATE, <<"">>} :=
                       #event{json = #{<<"content">> := #{<<"creator">> := User}}}}} ->
                    100;
                {true, #{{?ROOM_CREATE, <<"">>} := #event{sender = User}}} ->
                    100;
                _ ->
                    0
            end
    end.

check_event_auth_power_levels(Event, StateMap, Data) ->
    try
        case Event#event.json of
            #{<<"content">> := NewPL = #{<<"users">> := Users}} when is_map(Users) ->
                case (Data#data.room_version)#room_version.enforce_int_power_levels of
                    true ->
                        lists:foreach(
                          fun(Field) ->
                                  case NewPL of
                                      #{Field := V} when is_integer(V) -> ok;
                                      #{Field := _V} -> error(not_allowed);
                                      _ -> ok
                                  end
                          end,
                          [<<"users_default">>, <<"events_default">>, <<"state_default">>,
                           <<"ban">>, <<"redact">>, <<"kick">>, <<"invite">>]),
                        lists:foreach(
                          fun(Key) ->
                                  NewMap = maps:get(Key, NewPL, #{}),
                                  maps:fold(
                                    fun(_Field, V, _) ->
                                            if
                                                is_integer(V) -> ok;
                                                true -> error(not_allowed)
                                            end
                                    end, [], NewMap)
                          end,
                          [<<"events">>, <<"users">>, <<"notifications">>]);
                    false ->
                        ok
                end,
                maps:fold(
                  fun(K, _V, _) ->
                          case check_user_id(K) of
                              true -> ok;
                              false -> error(not_allowed)
                          end
                  end, ok, Users),
                StateKey = Event#event.state_key,
                case StateMap of
                    #{{?ROOM_POWER_LEVELS, StateKey} :=
                          #event{json = #{<<"content">> := OldPL}}} ->
                        UserLevel = get_user_power_level(Event#event.sender, StateMap, Data),
                        lists:foreach(
                          fun(Field) ->
                                  case check_event_auth_power_levels_aux(
                                         Field, OldPL, NewPL, UserLevel, none) of
                                      true -> ok;
                                      false -> error(not_allowed)
                                  end
                          end,
                          [<<"users_default">>, <<"events_default">>, <<"state_default">>,
                           <<"ban">>, <<"redact">>, <<"kick">>, <<"invite">>]),
                        lists:foreach(
                          fun(Key) ->
                                  OldMap = maps:get(Key, OldPL, #{}),
                                  NewMap = maps:get(Key, NewPL, #{}),
                                  UserID =
                                      case Key of
                                          <<"users">> ->
                                              {some, Event#event.sender};
                                          _ -> none
                                      end,
                                  maps:fold(
                                    fun(Field, _, _) ->
                                            case check_event_auth_power_levels_aux(
                                                   Field, OldMap, NewMap, UserLevel, UserID) of
                                                true -> ok;
                                                false -> error(not_allowed)
                                            end
                                    end, [], maps:merge(OldMap, NewMap))
                          end,
                          [<<"events">>, <<"users">>, <<"notifications">>]),
                        true;
                    _ ->
                        true
                end;
            _ ->
                false
        end
    catch
        error:not_allowed ->
            false
    end.

check_event_auth_power_levels_aux(Field, OldDict, NewDict, UserLevel, UserID) ->
    UserLevel2 =
        case UserID of
            none -> UserLevel;
            {some, Field} -> UserLevel;
            {some, _} -> UserLevel - 1
        end,
    case {maps:find(Field, OldDict), maps:find(Field, NewDict)} of
        {error, error} -> true;
        {error, {ok, S}} ->
            get_int(S) =< UserLevel;
        {{ok, S}, error} ->
            get_int(S) =< UserLevel2;
        {{ok, S1}, {ok, S2}} ->
            OldLevel = get_int(S1),
            NewLevel = get_int(S2),
            if
                OldLevel == NewLevel -> true;
                true ->
                    OldLevel =< UserLevel2 andalso NewLevel =< UserLevel
            end
    end.

check_user_id(S) ->
    case S of
        <<$@, Parts/binary>> ->
            case binary:split(Parts, <<":">>) of
                [_, _] -> true;
                _ -> false
            end;
        _ ->
            false
    end.

parse_user_id(Str) ->
    case Str of
        <<$@, Parts/binary>> ->
            case binary:split(Parts, <<":">>) of
                [U, S] -> {ok, U, S};
                _ -> error
            end;
        _ ->
            error
    end.

get_int(I) when is_integer(I) -> I;
get_int(S) when is_binary(S) -> binary_to_integer(S).

fill_event(JSON, Data) ->
    Host = Data#data.host,
    MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
    PrevEvents = sets:to_list(Data#data.latest_events),
    Depth =
        lists:max(
          [0 | lists:map(
                 fun(EID) ->
                         (maps:get(EID, Data#data.events))#event.depth
                 end, PrevEvents)]),
    Depth2 = min(Depth + 1, ?MAX_DEPTH),
    StateMaps =
        lists:map(
          fun(EID) ->
                  case Data#data.events of
                      #{EID := #event{state_map = undefined}} ->
                          error({missed_state_map, EID});
                      #{EID := #event{state_map = SM}} ->
                          SM;
                      _ ->
                          error({missed_prev_event, EID})
                  end
          end, PrevEvents),
    StateMap = resolve_state_maps(StateMaps, Data),
    AuthEvents =
        lists:usort(
          lists:flatmap(
            fun(Key) ->
                    case StateMap of
                        #{Key := E} -> [E];
                        _ -> []
                    end
            end,
            compute_event_auth_keys(JSON))),
    {JSON#{<<"auth_events">> => AuthEvents,
           <<"depth">> => Depth2,
           <<"origin">> => MatrixServer,
           <<"origin_server_ts">> => erlang:system_time(millisecond),
           <<"prev_events">> => PrevEvents,
           <<"room_id">> => Data#data.room_id},
     StateMap}.

add_event(JSON, Data) ->
    Host = Data#data.host,
    {Msg, StateMap} = fill_event(JSON, Data),
    CHash = mod_matrix_gw:content_hash(Msg),
    Msg2 =
        Msg#{<<"hashes">> =>
                 #{<<"sha256">> =>
                       mod_matrix_gw:base64_encode(CHash)}},
    Msg3 = mod_matrix_gw:sign_event(Host, Msg2, Data#data.room_version),
    Event = json_to_event(Msg3, Data#data.room_version),
    StateMap2 =
        case Event#event.state_key of
            undefined ->
                StateMap;
            _ ->
                StateMap#{{Event#event.type, Event#event.state_key} => Event#event.id}
        end,
    Event2 = Event#event{state_map = StateMap2},
    ?DEBUG("add_event ~p~n", [Event2]),
    case check_event_auth(Event2, Data) of
        true ->
            %%TODO: soft fail
            store_event(Event2, Data);
        false ->
            error({event_auth_error, Event2#event.id})
    end.


store_event(Event, Data) ->
    %% TODO
    Events = Data#data.events,
    case maps:find(Event#event.id, Events) of
        {ok, #event{state_map = undefined}} when Event#event.state_map /= undefined ->
            Data#data{events = Events#{Event#event.id => Event}};
        {ok, _} ->
            Data;
        error ->
            ?DEBUG("store ~p~n", [Event#event.id]),
            Data2 = notify_event(Event, Data),
            LatestEvents =
                lists:foldl(fun(E, Acc) -> sets:del_element(E, Acc) end, Data2#data.latest_events,
                            Event#event.prev_events),
            NonLatestEvents =
                lists:foldl(fun(E, Acc) -> sets:add_element(E, Acc) end, Data2#data.nonlatest_events,
                            Event#event.prev_events),
            LatestEvents2 =
                case maps:is_key(Event#event.id, NonLatestEvents) of
                    true ->
                        LatestEvents;
                    false ->
                        LatestEvents#{Event#event.id => []}
                end,
            ?DEBUG("latest ~p~n", [{LatestEvents2, NonLatestEvents}]),
            Data2#data{events = Events#{Event#event.id => Event},
                       latest_events = LatestEvents2,
                       nonlatest_events = NonLatestEvents}
    end.

simple_toposort(Events) ->
    {Res, _Used} =
        lists:foldl(
          fun(E, {_Res, Used} = Acc) ->
                  EventID = E#event.id,
                  case maps:is_key(EventID, Used) of
                      false ->
                          simple_toposort_dfs(EventID, Acc, Events);
                      true ->
                          Acc
                  end
          end, {[], #{}}, maps:values(Events)),
    lists:reverse(Res).

simple_toposort_dfs(EventID, {Res, Used}, Events) ->
    case maps:find(EventID, Events) of
        error ->
            error({unknown_event, EventID});
        {ok, Event} ->
            Used2 = Used#{EventID => gray},
            {Res8, Used8} =
                lists:foldl(
                  fun(ID, {_Res3, Used3} = Acc) ->
                          case maps:get(ID, Used3, white) of
                              white ->
                                  simple_toposort_dfs(ID, Acc, Events);
                              gray ->
                                  error(loop_in_auth_chain);
                              black ->
                                  Acc
                          end
                  end, {Res, Used2}, Event#event.auth_events),
            Used9 = Used8#{EventID => black},
            Res9 = [EventID | Res8],
            {Res9, Used9}
    end.

check_event_sig_and_hash(Host, Event) ->
    case check_event_signature(Host, Event) of
        true ->
            case check_event_content_hash(Event) of
                true ->
                    {ok, Event};
                false ->
                    ?DEBUG("mismatched content hash: ~p", [Event#event.id]),
                    PrunedJSON = mod_matrix_gw:prune_event(
                                   Event#event.json, Event#event.room_version),
                    {ok, Event#event{json = PrunedJSON}}
            end;
        false ->
            {error, {invalid_signature, Event#event.id}}
    end.

get_room_version(Pid) ->
    gen_statem:call(Pid, get_room_version).

partition_missed_events(Pid, EventIDs) ->
    gen_statem:call(Pid, {partition_missed_events, EventIDs}).

partition_events_with_statemap(Pid, EventIDs) ->
    gen_statem:call(Pid, {partition_events_with_statemap, EventIDs}).

get_latest_events(Pid) ->
    gen_statem:call(Pid, get_latest_events).

check_event_signature(Host, Event) ->
    PrunedEvent = mod_matrix_gw:prune_event(Event#event.json,
                                            Event#event.room_version),
    mod_matrix_gw_s2s:check_signature(Host, PrunedEvent).

find_event(Pid, EventID) ->
    gen_statem:call(Pid, {find_event, EventID}).

resolve_auth_store_event(Pid, Event) ->
    gen_statem:call(Pid, {resolve_auth_store_event, Event}).

process_pdu(Host, Origin, PDU) ->
    %% TODO: error handling
    #{<<"room_id">> := RoomID} = PDU,
    case get_existing_room_pid(Host, RoomID) of
        {ok, Pid} ->
            RoomVersion = get_room_version(Pid),
            Event = json_to_event(PDU, RoomVersion),
            case check_event_signature(Host, Event) of
                true ->
                    {SeenEvents, MissedEvents} =
                         partition_missed_events(Pid, Event#event.prev_events),
                    ?DEBUG("seen/missed: ~p~n", [{SeenEvents, MissedEvents}]),
                    case MissedEvents of
                        [] ->
                            ok;
                        _ ->
                            LatestEvents = get_latest_events(Pid),
                            EarliestEvents =
                                lists:foldl(
                                  fun(E, Acc) ->
                                          Acc#{E => []}
                                  end, LatestEvents, SeenEvents),
                            ?DEBUG("earliest ~p~n", [EarliestEvents]),
                            MissingEventsQuery =
                                #{<<"earliest_events">> => maps:keys(EarliestEvents),
                                  <<"latest_events">> => [Event#event.id],
                                  <<"limit">> => 10},
                            MissingEventsRes =
                                mod_matrix_gw:send_request(
                                  Host, post, Origin,
                                  [<<"_matrix">>, <<"federation">>, <<"v1">>,
                                   <<"get_missing_events">>, RoomID],
                                  [],
                                  MissingEventsQuery,
                                  [{timeout, 60000}],
                                  [{sync, true},
                                   {body_format, binary}]),
                            ?DEBUG("missing res ~p~n", [MissingEventsRes]),
                            process_missing_events_res(Host, Origin, Pid, RoomID, RoomVersion,
                                                       MissingEventsRes),
                            ok
                    end,
                    resolve_auth_store_event(Pid, Event),
                    {ok, Event#event.id};
                false ->
                    {error, <<"Signature check failed">>}
            end;
        {error, not_found} ->
            {error, <<"Room doesn't exist">>}
    end.

process_missing_events_res(Host, Origin, Pid, RoomID, RoomVersion,
                           {ok, {{_, 200, _}, _Headers, Body}}) ->
    try
        case jiffy:decode(Body, [return_maps]) of
            #{<<"events">> := JSONEvents} when is_list(JSONEvents) ->
                process_missing_events(Host, Origin, Pid, RoomID, RoomVersion, JSONEvents)
        end
    catch
        Class:Reason:ST ->
            ?DEBUG("failed process_missing_events_res: ~p", [{Class, Reason, ST}]),
            ok
    end;
process_missing_events_res(_Host, _Origin, _Pid, _RoomID, _RoomVersion, _) ->
    ok.

process_missing_events(Host, Origin, Pid, RoomID, RoomVersion, JSONEvents) ->
    Events = lists:map(fun(J) -> json_to_event(J, RoomVersion) end, JSONEvents),
    SortedEvents = lists:keysort(#event.depth, Events),
    ?DEBUG("sevents ~p~n", [SortedEvents]),
    lists:foreach(
      fun(Event) ->
              case check_event_sig_and_hash(Host, Event) of
                  {ok, _} ->
                      ShouldProcess =
                          case find_event(Pid, Event#event.id) of
                              {ok, #event{state_map = undefined}} ->
                                  true;
                              {ok, _} ->
                                  false;
                              error ->
                                  true
                          end,
                      case ShouldProcess of
                          true ->
                              fetch_prev_statemaps(Host, Origin, Pid,
                                                   RoomID, RoomVersion, Event),
                              resolve_auth_store_event(Pid, Event),
                              ok;
                          false ->
                              ok
                      end;
                  {error, Reason} ->
                      error(Reason)
              end
      end, SortedEvents),
    ok.

fetch_prev_statemaps(Host, Origin, Pid, RoomID, RoomVersion, Event) ->
    ?DEBUG("fetch_prev_statemaps ~p~n", [Event#event.id]),
    {SeenEvents, MissedEvents} =
        partition_events_with_statemap(Pid, Event#event.prev_events),
    ?DEBUG("s/m ~p~n", [{SeenEvents, MissedEvents}]),
    lists:foreach(
      fun(MissedEventID) ->
              case request_event(Host, Origin, Pid, RoomID, RoomVersion, MissedEventID) of
                  {ok, MissedEvent} ->
                      case request_room_state(Host, Origin, Pid, RoomID, RoomVersion, MissedEvent) of
                          {ok, AuthChain, State} ->
                              auth_and_store_external_events(Pid, AuthChain ++ State),
                              StateMap =
                                  lists:foldl(
                                    fun(E, Acc) ->
                                            Acc#{{E#event.type, E#event.state_key} => E#event.id}
                                    end, #{}, State),
                              auth_and_store_external_events(
                                Pid, [MissedEvent#event{state_map = StateMap}]),
                              ok;
                          {error, Reason} ->
                              ?INFO_MSG("failed request_room_state: ~p", [{RoomID, Event#event.id, Reason}]),
                              ok
                      end;
                  {error, Error} ->
                      error(Error)
              end
      end, MissedEvents).

request_room_state(Host, Origin, _Pid, RoomID, RoomVersion, Event) ->
    Res =
        mod_matrix_gw:send_request(
          Host, get, Origin,
          [<<"_matrix">>, <<"federation">>,
           <<"v1">>, <<"state">>,
           RoomID],
          [{<<"event_id">>, Event#event.id}],
          none,
          [{timeout, 5000}],
          [{sync, true},
           {body_format, binary}]),
    case Res of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            try
                case jiffy:decode(Body, [return_maps]) of
                    #{<<"auth_chain">> := JSONAuthChain,
                      <<"pdus">> := JSONState} = _JSON when is_list(JSONAuthChain),
                                                            is_list(JSONState) ->
                        AuthChain =
                            lists:map(fun(J) -> json_to_event(J, RoomVersion) end,
                                      JSONAuthChain),
                        State =
                            lists:map(fun(J) -> json_to_event(J, RoomVersion) end,
                                      JSONState),
                        lists:foreach(
                          fun(E) ->
                                  case check_event_sig_and_hash(Host, E) of
                                      {ok, _} ->
                                          case E#event.room_id of
                                              RoomID ->
                                                  case E#event.state_key of
                                                      undefined ->
                                                          error({missed_state_key, E#event.id});
                                                      _ ->
                                                          ok
                                                  end;
                                              RoomID2 ->
                                                  error({mismatched_room_id, E#event.id, RoomID, RoomID2})
                                          end;
                                      {error, Error} -> error(Error)
                                  end
                          end, AuthChain ++ State),
                        ?DEBUG("req state ~p~n",
                               [{[E#event.id || E <- AuthChain],
                                 [E#event.id || E <- State]}]),
                        {ok, AuthChain, State}
                end
            catch
                Class:Reason:ST ->
                    ?INFO_MSG("failed request_room_state: ~p", [{Class, Reason, ST}]),
                    {error, Reason}
            end;
        {ok, {{_, _Status, Reason}, _Headers, _Body}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

request_event(Host, Origin, _Pid, RoomID, RoomVersion, EventID) ->
    Res =
        mod_matrix_gw:send_request(
          Host, get, Origin,
          [<<"_matrix">>, <<"federation">>,
           <<"v1">>, <<"event">>,
           EventID],
          [],
          none,
          [{timeout, 5000}],
          [{sync, true},
           {body_format, binary}]),
    case Res of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            try
                case jiffy:decode(Body, [return_maps]) of
                    #{<<"pdus">> := [PDU]} ->
                        Event = json_to_event(PDU, RoomVersion),
                        case check_event_sig_and_hash(Host, Event) of
                            {ok, _} ->
                                case Event#event.room_id of
                                    RoomID ->
                                        ok;
                                    RoomID2 ->
                                        error({mismatched_room_id, Event#event.id, RoomID, RoomID2})
                                end;
                            {error, Error} -> error(Error)
                        end,
                        {ok, Event}
                end
            catch
                Class:Reason:ST ->
                    ?INFO_MSG("failed request_event: ~p", [{Class, Reason, ST}]),
                    {error, Reason}
            end;
        {ok, {{_, _Status, Reason}, _Headers, _Body}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

get_event_prev_state_map(Event, Data) ->
    StateMaps =
        lists:map(
          fun(EID) ->
                  case Data#data.events of
                      #{EID := #event{state_map = undefined}} ->
                          error({missed_state_map, EID});
                      #{EID := #event{state_map = SM}} ->
                          SM;
                      _ ->
                          error({missed_prev_event, EID})
                  end
          end, Event#event.prev_events),
    resolve_state_maps(StateMaps, Data).

do_resolve_auth_store_event(Event, Data) ->
    StateMap = get_event_prev_state_map(Event, Data),
    StateMap2 =
        case Event#event.state_key of
            undefined ->
                StateMap;
            _ ->
                StateMap#{{Event#event.type, Event#event.state_key} => Event#event.id}
        end,
    Event2 = Event#event{state_map = StateMap2},
    case check_event_auth(Event2, Data) of
        true ->
            %TODO: soft fail
            store_event(Event2, Data);
        false ->
            error({event_auth_error, Event2#event.id})
    end.

resolve_state_maps([], _Data) ->
    #{};
resolve_state_maps([StateMap], _Data) ->
    StateMap;
resolve_state_maps(StateMaps, Data) ->
    {Unconflicted, Conflicted} = calculate_conflict(StateMaps),
    ?DEBUG("confl ~p~n", [{Unconflicted, Conflicted}]),
    case maps:size(Conflicted) of
        0 ->
            Unconflicted;
        _ ->
            AuthDiff = calculate_auth_diff(StateMaps, Data),
            ?DEBUG("auth diff ~p~n", [AuthDiff]),
            FullConflictedSet =
                maps:from_list([{E, []} || E <- lists:append([AuthDiff | maps:values(Conflicted)])]),
            ?DEBUG("fcs ~p~n", [FullConflictedSet]),
            %% TODO: test
            PowerEvents =
                lists:filter(
                  fun(EventID) ->
                          Event = maps:get(EventID, Data#data.events),
                          is_power_event(Event)
                  end, maps:keys(FullConflictedSet)),
            SortedPowerEvents = lexicographic_toposort(PowerEvents, FullConflictedSet, Data),
            ?DEBUG("spe ~p~n", [SortedPowerEvents]),
            StateMap = iterative_auth_checks(SortedPowerEvents, Unconflicted, Data),
            PowerEventsSet = maps:from_list([{E, []} || E <- SortedPowerEvents]),
            OtherEvents = lists:filter(fun(E) -> not maps:is_key(E, PowerEventsSet) end,
                                       maps:keys(FullConflictedSet)),
            PLID = maps:get({?ROOM_POWER_LEVELS, <<"">>}, StateMap, undefined),
            SortedOtherEvents = mainline_sort(OtherEvents, PLID, Data),
            ?DEBUG("mainline ~p~n", [SortedOtherEvents]),
            StateMap2 = iterative_auth_checks(SortedOtherEvents, StateMap, Data),
            Resolved = maps:merge(StateMap2, Unconflicted),
            ?DEBUG("resolved ~p~n", [Resolved]),
            Resolved
    end.

calculate_conflict(StateMaps) ->
    Keys = lists:usort(lists:flatmap(fun maps:keys/1, StateMaps)),
    lists:foldl(
      fun(Key, {Unconflicted, Conflicted}) ->
              EventIDs =
                  lists:usort(
                    lists:map(fun(StateMap) ->
                                      maps:find(Key, StateMap)
                              end, StateMaps)),
              case EventIDs of
                  [{ok, EventID}] ->
                      {Unconflicted#{Key => EventID}, Conflicted};
                  _ ->
                      EventIDs2 =
                          lists:flatmap(
                            fun(error) -> [];
                               ({ok, EventID}) -> [EventID]
                            end, EventIDs),
                      {Unconflicted, Conflicted#{Key => EventIDs2}}
              end
      end, {#{}, #{}}, Keys).

%% TODO: not optimal
calculate_auth_diff(StateMaps, Data) ->
    N = length(StateMaps),
    Queue =
        lists:foldl(
          fun({K, StateMap}, Q) ->
                  maps:fold(
                    fun(_, EID, Q2) ->
                            Depth = (maps:get(EID, Data#data.events))#event.depth,
                            Set =
                                case gb_trees:lookup({Depth, EID}, Q2) of
                                    none ->
                                        1 bsl N - 1;
                                    {value, S} ->
                                        S
                                end,
                            Set2 = Set band bnot (1 bsl K),
                            gb_trees:enter({Depth, EID}, Set2, Q2)
                    end, Q, StateMap)
          end, gb_trees:empty(),
          lists:zip(lists:seq(0, N - 1), StateMaps)),
    Count = lists:sum(gb_trees:values(Queue)),
    calculate_auth_diff_bfs(Queue, Count, [], Data).

calculate_auth_diff_bfs(_Queue, 0, Res, _Data) ->
    Res;
calculate_auth_diff_bfs(Queue, Count, Res, Data) ->
    %?DEBUG("authdiff bfs ~p~n", [{gb_trees:to_list(Queue), Count, Res}]),
    case gb_trees:is_empty(Queue) of
        true ->
            error(internal_error);
        false ->
            {{_, EventID}, Set, Queue2} = gb_trees:take_largest(Queue),
            Res2 = case Set of
                       0 -> Res;
                       _ -> [EventID | Res]
                   end,
            Event = maps:get(EventID, Data#data.events),
            calculate_auth_diff_bfs2(Event#event.auth_events, Set, Queue2, Count - Set, Res2, Data)
    end.

calculate_auth_diff_bfs2([], _Set, Queue, Count, Res, Data) ->
    calculate_auth_diff_bfs(Queue, Count, Res, Data);
calculate_auth_diff_bfs2([EID | Events], Set, Queue, Count, Res, Data) ->
    Event = maps:get(EID, Data#data.events),
    case gb_trees:lookup({Event#event.depth, EID}, Queue) of
        none ->
            Queue2 = gb_trees:insert({Event#event.depth, EID}, Set, Queue),
            calculate_auth_diff_bfs2(Events, Set, Queue2, Count + Set, Res, Data);
        {value, Set2} ->
            Set3 = Set band Set2,
            Queue2 = gb_trees:enter({Event#event.depth, EID}, Set3, Queue),
            calculate_auth_diff_bfs2(Events, Set, Queue2, Count - Set2 + Set3, Res, Data)
    end.

is_power_event(#event{type = ?ROOM_POWER_LEVELS, state_key = <<"">>}) ->
    true;
is_power_event(#event{type = ?ROOM_JOIN_RULES, state_key = <<"">>}) ->
    true;
is_power_event(#event{type = ?ROOM_MEMBER, state_key = StateKey, sender = Sender,
                      json = #{<<"content">> := #{<<"membership">> := <<"leave">>}}}) ->
    StateKey /= Sender;
is_power_event(#event{type = ?ROOM_MEMBER, state_key = StateKey, sender = Sender,
                      json = #{<<"content">> := #{<<"membership">> := <<"ban">>}}}) ->
    StateKey /= Sender;
is_power_event(_) ->
    false.

lexicographic_toposort(EventIDs, EventSet, Data) ->
    Used =
        lists:foldl(
          fun(EventID, Used) ->
                  case maps:is_key(EventID, EventSet) of
                      true ->
                          case maps:is_key(EventID, Used) of
                              false ->
                                  lexicographic_toposort_prepare(EventID, Used, EventSet, Data);
                              true ->
                                  Used
                          end;
                      false ->
                          Used
                  end
          end, #{}, EventIDs),
    IncomingCnt =
        maps:fold(
          fun(EventID, _, Acc) ->
                  Event = maps:get(EventID, Data#data.events),
                  lists:foldl(
                    fun(EID, Acc2) ->
                            case maps:is_key(EID, Acc2) of
                                true ->
                                    C = maps:get(EID, Acc2),
                                    maps:put(EID, C + 1, Acc2);
                                false ->
                                    Acc2
                            end
                    end, Acc, Event#event.auth_events)
          end, maps:map(fun(_, _) -> 0 end, Used), Used),
    Current =
        maps:fold(
          fun(EventID, 0, Acc) ->
                  Event = maps:get(EventID, Data#data.events),
                  PowerLevel = get_sender_power_level(EventID, Data),
                  gb_trees:enter({-PowerLevel, Event#event.origin_server_ts, EventID}, [], Acc);
             (_, _, Acc) ->
                  Acc
          end, gb_trees:empty(), IncomingCnt),
    IncomingCnt2 = maps:filter(fun(_, 0) -> false; (_, _) -> true end, IncomingCnt),
    lexicographic_toposort_loop(Current, IncomingCnt2, [], Data).

lexicographic_toposort_prepare(EventID, Used, EventSet, Data) ->
    Event = maps:get(EventID, Data#data.events),
    Used2 = Used#{EventID => []},
    Used4 =
        lists:foldl(
          fun(EID, Used3) ->
                  case maps:is_key(EID, EventSet) of
                      true ->
                          case maps:is_key(EID, Used3) of
                              false ->
                                  lexicographic_toposort_prepare(EID, Used3, EventSet, Data);
                              true ->
                                  Used3
                          end;
                      false ->
                          Used3
                  end
          end, Used2, Event#event.auth_events),
    Used4.

lexicographic_toposort_loop(Current, IncomingCnt, Res, Data) ->
    case gb_trees:is_empty(Current) of
        true ->
            case maps:size(IncomingCnt) of
                0 ->
                    Res;
                _ ->
                    error(loop_in_auth_chain)
            end;
        false ->
            {{_, _, EventID}, _, Current2} = gb_trees:take_smallest(Current),
            Event = maps:get(EventID, Data#data.events),
            IncomingCnt2 =
                lists:foldl(
                  fun(EID, Acc) ->
                          case maps:is_key(EID, Acc) of
                              true ->
                                  C = maps:get(EID, Acc) - 1,
                                  case C of
                                      0 ->
                                          maps:remove(EID, Acc);
                                      _ ->
                                          maps:put(EID, C, Acc)
                                  end;
                              false ->
                                  Acc
                          end
                  end, IncomingCnt, Event#event.auth_events),
            lexicographic_toposort_loop(Current2, IncomingCnt2, [EventID | Res], Data)
    end.

get_sender_power_level(EventID, Data) ->
    RoomVersion = Data#data.room_version,
    Event = maps:get(EventID, Data#data.events),
    PowerEventID = find_power_level_event(EventID, Data),
    PowerEvent =
        case PowerEventID of
            undefined -> undefined;
            _ -> maps:get(PowerEventID, Data#data.events)
        end,
    Sender = Event#event.sender,
    case PowerEvent of
        undefined ->
            lists:foldl(
              fun(EID, Acc) ->
                      E = maps:get(EID, Data#data.events),
                      case {RoomVersion#room_version.implicit_room_creator, E} of
                          {false,
                           #event{type = ?ROOM_CREATE, state_key = <<"">>,
                                  json = #{<<"content">> :=
                                               #{<<"creator">> := Sender}}}} ->
                              100;
                          {true,
                           #event{type = ?ROOM_CREATE, state_key = <<"">>,
                                  sender = Sender}} ->
                              100;
                          _ ->
                              Acc
                      end
              end, 0, Event#event.auth_events);
        #event{json = #{<<"content">> := #{<<"users">> := #{Sender := Level}}}} ->
            get_int(Level);
        #event{json = #{<<"content">> := #{<<"users_default">> := Level}}} ->
            get_int(Level);
        _ ->
            0
    end.

iterative_auth_checks(Events, StateMap, Data) ->
    lists:foldl(
      fun(EventID, StateMap2) ->
              Event = maps:get(EventID, Data#data.events),
              StateMap3 =
                  lists:foldl(
                    fun(EID, SM) ->
                            E = maps:get(EID, Data#data.events),
                            case maps:is_key({E#event.type, E#event.state_key}, SM) of
                                true ->
                                    SM;
                                false ->
                                    SM#{{E#event.type, E#event.state_key} => E#event.id}
                            end
                    end, StateMap2, Event#event.auth_events),
              %% TODO: not optimal
              StateMap4 =
                  maps:map(fun(_, EID) -> maps:get(EID, Data#data.events) end, StateMap3),
              case check_event_auth(Event, StateMap4, Data) of
                  true ->
                      StateMap2#{{Event#event.type, Event#event.state_key} => EventID};
                  false ->
                      StateMap2
              end
      end, StateMap, Events).

mainline_sort(OtherEvents, PLID, Data) ->
    IdxMap = mainline_sort_init(PLID, -1, #{}, Data),
    {OtherEvents2, _} =
        lists:foldl(
          fun(EventID, {Events, IMap}) ->
                  Event = maps:get(EventID, Data#data.events),
                  {Idx, IMap2} = mainline_sort_find(EventID, IMap, Data),
                  {[{Idx, Event#event.origin_server_ts, EventID} | Events], IMap2}
          end, {[], IdxMap}, OtherEvents),
    lists:map(fun({_, _, EID}) -> EID end, lists:sort(OtherEvents2)).

mainline_sort_init(undefined, _Idx, IdxMap, _Data) ->
    IdxMap;
mainline_sort_init(PLID, Idx, IdxMap, Data) when is_binary(PLID) ->
    IdxMap2 = maps:put(PLID, Idx, IdxMap),
    PLID2 = find_power_level_event(PLID, Data),
    mainline_sort_init(PLID2, Idx - 1, IdxMap2, Data).

mainline_sort_find(undefined, IdxMap, _Data) ->
    {0, IdxMap};
mainline_sort_find(EventID, IdxMap, Data) ->
    case maps:find(EventID, IdxMap) of
        {ok, Idx} -> {Idx, IdxMap};
        error ->
            PLID = find_power_level_event(EventID, Data),
            {Idx, IdxMap2} = mainline_sort_find(PLID, IdxMap, Data),
            IdxMap3 = maps:put(EventID, Idx, IdxMap2),
            {Idx, IdxMap3}
    end.

find_power_level_event(EventID, Data) ->
    Event = maps:get(EventID, Data#data.events),
    lists:foldl(
      fun(EID, undefined) ->
              E = maps:get(EID, Data#data.events),
              case E of
                  #event{type = ?ROOM_POWER_LEVELS, state_key = <<"">>} -> EID;
                  _ -> undefined
              end;
         (_, PLID) ->
              PLID
      end, undefined, Event#event.auth_events).


binary_to_room_version(<<"9">>) ->
    #room_version{id = <<"9">>,
                  knock_restricted_join_rule = false,
                  enforce_int_power_levels = false,
                  implicit_room_creator = false,
                  updated_redaction_rules = false
                 };
binary_to_room_version(<<"10">>) ->
    #room_version{id = <<"10">>,
                  knock_restricted_join_rule = true,
                  enforce_int_power_levels = true,
                  implicit_room_creator = false,
                  updated_redaction_rules = false
                 };
binary_to_room_version(<<"11">>) ->
    #room_version{id = <<"11">>,
                  knock_restricted_join_rule = true,
                  enforce_int_power_levels = true,
                  implicit_room_creator = true,
                  updated_redaction_rules = true
                 };
binary_to_room_version(_) ->
    false.

json_to_event(#{<<"type">> := Type,
                <<"room_id">> := RoomID,
                <<"depth">> := Depth,
                <<"auth_events">> := AuthEvents,
                <<"sender">> := Sender,
                <<"prev_events">> := PrevEvents,
                <<"origin_server_ts">> := OriginServerTS} = JSON, RoomVersion)
  when is_binary(Type),
       is_integer(Depth),
       is_list(AuthEvents) ->
    StateKey = maps:get(<<"state_key">>, JSON, undefined),
    EventID = mod_matrix_gw:get_event_id(JSON, RoomVersion),
    #event{id = EventID,
           room_version = RoomVersion,
           room_id = RoomID,
           type = Type,
           state_key = StateKey,
           depth = Depth,
           auth_events = AuthEvents,
           sender = Sender,
           prev_events = PrevEvents,
           origin_server_ts = OriginServerTS,
           json = JSON}.

check_event_content_hash(Event) ->
    JSON = Event#event.json,
    case JSON of
        #{<<"hashes">> := #{<<"sha256">> := S}} ->
            Hash = mod_matrix_gw:content_hash(JSON),
            mod_matrix_gw:base64_decode(S) == Hash;
        _ ->
            false
    end.

notify_event(#event{sender = Sender,
                    json = #{<<"test">> := true}} = Event,
             Data) ->
    case user_id_to_jid(Sender, Data) of
        #jid{} = SenderJID ->
            LSenderServer = SenderJID#jid.lserver,
            UserJID = Data#data.local_user,
            LUserServer = UserJID#jid.lserver,
            case LSenderServer of
                LUserServer ->
                    %RemoteServers = maps:keys(Data#data.remote_servers),
                    RemoteServers = get_remote_servers(Data),
                    lists:foldl(
                      fun(Server, DataAcc) ->
                              case DataAcc#data.outgoing_txns of
                                  #{Server := {T, Queue}} ->
                                      Queue2 = [Event | Queue],
                                      DataAcc#data{outgoing_txns =
                                                       maps:put(Server, {T, Queue2},
                                                                DataAcc#data.outgoing_txns)};
                                  _ ->
                                      send_new_txn([Event], Server, DataAcc)
                              end
                      end, Data, RemoteServers);
                _ ->
                    Data
            end;
        error ->
            Data
    end;
notify_event(#event{type = ?ROOM_MESSAGE, sender = Sender,
                    json = #{<<"content">> := #{<<"msgtype">> := <<"m.text">>,
                                                <<"body">> := Body}}} = Event,
             Data) ->
    case user_id_to_jid(Sender, Data) of
        #jid{} = SenderJID ->
            LSenderJID = jid:tolower(SenderJID),
            UserJID = Data#data.local_user,
            LUserJID = jid:tolower(UserJID),
            case LSenderJID of
                LUserJID ->
                    %RemoteServers = maps:keys(Data#data.remote_servers),
                    RemoteServers = get_remote_servers(Data),
                    lists:foldl(
                      fun(Server, DataAcc) ->
                              case DataAcc#data.outgoing_txns of
                                  #{Server := {T, Queue}} ->
                                      Queue2 = [Event | Queue],
                                      DataAcc#data{outgoing_txns =
                                                       maps:put(Server, {T, Queue2},
                                                                DataAcc#data.outgoing_txns)};
                                  _ ->
                                      send_new_txn([Event], Server, DataAcc)
                              end
                      end, Data, RemoteServers);
                _ ->
                    RoomID = Data#data.room_id,
                    Msg = #message{from = SenderJID,
                                   to = UserJID,
                                   type = chat,
                                   body = [#text{data = Body}],
                                   sub_els = [#xmlel{name = <<"x">>,
                                                     attrs = [{<<"xmlns">>, <<"p1:matrix">>},
                                                              {<<"room_id">>, RoomID}]}]
                                  },
                    ejabberd_router:route(Msg),
                    Data
            end;
        error ->
            Data
    end;
notify_event(#event{type = ?ROOM_MEMBER,
                    state_key = StateKey,
                    sender = Sender,
                    json = #{<<"content">> := #{<<"membership">> := <<"invite">>}}} = Event,
             Data) ->
    Host = Data#data.host,
    MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
    case mod_matrix_gw:get_id_domain_exn(StateKey) of
        MatrixServer ->
            Data;
        RemoteServer ->
            StrippedState =
                maps:with([{?ROOM_CREATE, <<"">>}, {?ROOM_JOIN_RULES, <<"">>},
                           {?ROOM_MEMBER, Sender}],
                          Event#event.state_map),
            StrippedState2 =
                maps:map(
                  fun(_, EID) ->
                          E = maps:get(EID, Data#data.events),
                          maps:with([<<"sender">>, <<"type">>, <<"state_key">>, <<"content">>],
                                    E#event.json)
                  end, StrippedState),
            JSON = #{<<"event">> => Event#event.json,
                     <<"room_version">> => (Event#event.room_version)#room_version.id,
                     <<"invite_room_state">> => maps:values(StrippedState2)},
            InviteRes =
                mod_matrix_gw:send_request(
                  Data#data.host, put, RemoteServer,
                  [<<"_matrix">>, <<"federation">>,
                   <<"v2">>, <<"invite">>,
                   Data#data.room_id, Event#event.id],
                  [],
                  JSON,
                  [{timeout, 5000}],
                  [{sync, true},
                   {body_format, binary}]),
            ?DEBUG("send invite ~p~n", [InviteRes]),
            Data
    end;
notify_event(_Event, Data) ->
    Data.

send_new_txn(Events, Server, Data) ->
    TxnID = p1_rand:get_string(),
    send_txn(TxnID, Events, Server, [], Data).

send_txn(TxnID, Events, Server, Queue, Data) ->
    ?DEBUG("send txn ~p~n", [TxnID]),
    Host = Data#data.host,
    Origin = mod_matrix_gw_opt:matrix_domain(Host),
    PDUs =
        lists:map(fun(E) -> E#event.json end, Events),
    Body =
        #{<<"origin">> => Origin,
          <<"origin_server_ts">> =>
              erlang:system_time(millisecond),
          <<"pdus">> => PDUs},
    Self = self(),
    Receiver =
        fun({RequestID, Res}) ->
                Self ! {send_txn_res, RequestID, TxnID, Server, Res}
        end,
    {ok, RequestID} =
        mod_matrix_gw:send_request(
          Host, put, Server,
          [<<"_matrix">>, <<"federation">>,
           <<"v1">>, <<"send">>,
           TxnID],
          [],
          Body,
          [{timeout, 5000}],
          [{sync, false},
           {receiver, Receiver}]),
    Data#data{outgoing_txns =
                  maps:put(Server, {{RequestID, TxnID, Events}, Queue},
                           Data#data.outgoing_txns)}.

do_get_missing_events(Origin, EarliestEvents, LatestEvents, Limit, MinDepth, Data) ->
    case is_server_joined(Origin, Data) of
        true ->
            Visited = maps:from_list([{E, []} || E <- EarliestEvents]),
            Queue = queue:from_list(LatestEvents),
            Limit2 = min(max(Limit, 0), 20),
            do_get_missing_events_bfs(Queue, Visited, Limit2, MinDepth, [], Data);
        false ->
            []
    end.

do_get_missing_events_bfs(_Queue, _Visited, 0, _MinDepth, Res, _Data) ->
    Res;
do_get_missing_events_bfs(Queue, Visited, Limit, MinDepth, Res, Data) ->
    case queue:out(Queue) of
        {{value, EventID}, Queue2} ->
            case maps:find(EventID, Data#data.events) of
                {ok, #event{prev_events = PrevEvents}} ->
                    do_get_missing_events_bfs2(
                      PrevEvents, Queue2, Visited, Limit, MinDepth, Res, Data);
                _ ->
                    do_get_missing_events_bfs(Queue2, Visited, Limit, MinDepth, Res, Data)
            end;
        {empty, _} ->
            Res
    end.

do_get_missing_events_bfs2(_PrevEvents, _Queue, _Visited, 0, _MinDepth, Res, _Data) ->
    Res;
do_get_missing_events_bfs2([], Queue, Visited, Limit, MinDepth, Res, Data) ->
    do_get_missing_events_bfs(Queue, Visited, Limit, MinDepth, Res, Data);
do_get_missing_events_bfs2([EventID | PrevEvents], Queue, Visited, Limit, MinDepth, Res, Data) ->
    case maps:is_key(EventID, Visited) of
        true ->
            do_get_missing_events_bfs2(PrevEvents, Queue, Visited, Limit, MinDepth, Res, Data);
        false ->
            case maps:find(EventID, Data#data.events) of
                {ok, #event{depth = Depth} = Event} when Depth >= MinDepth ->
                    Queue2 = queue:in(EventID, Queue),
                    Visited2 = Visited#{EventID => []},
                    Res2 = [Event | Res],
                    do_get_missing_events_bfs2(
                      PrevEvents, Queue2, Visited2, Limit - 1, MinDepth, Res2, Data);
                _ ->
                    do_get_missing_events_bfs2(PrevEvents, Queue, Visited, Limit, MinDepth, Res, Data)
            end
    end.

do_get_state_ids(Origin, EventID, Data) ->
    case is_server_joined(Origin, Data) of
        true ->
            case maps:find(EventID, Data#data.events) of
                {ok, #event{state_map = StateMap} = Event} when is_map(StateMap) ->
                    PrevStateMap = get_event_prev_state_map(Event, Data),
                    PDUs = maps:values(PrevStateMap),
                    AuthChain = do_get_state_ids_dfs(PDUs, #{}, [], Data),
                    {ok, AuthChain, PDUs};
                error ->
                    {error, event_not_found}
            end;
        false ->
            {error, not_allowed}
    end.

do_get_state_ids_dfs([], _Visited, Res, _Data) ->
    Res;
do_get_state_ids_dfs([EventID | Queue], Visited, Res, Data) ->
    case maps:is_key(EventID, Visited) of
        true ->
            do_get_state_ids_dfs(Queue, Visited, Res, Data);
        false ->
            case maps:find(EventID, Data#data.events) of
                {ok, Event} ->
                    Visited2 = Visited#{EventID => []},
                    do_get_state_ids_dfs(
                      Event#event.auth_events ++ Queue, Visited2, [EventID | Res], Data);
                error ->
                    do_get_state_ids_dfs(Queue, Visited, Res, Data)
            end
    end.


is_server_joined(Server, Data) ->
    try
        sets:fold(
          fun(EventID, ok) ->
                  case maps:find(EventID, Data#data.events) of
                      {ok, Event} ->
                          maps:fold(
                            fun({?ROOM_MEMBER, UserID}, EID, ok) ->
                                    case mod_matrix_gw:get_id_domain_exn(UserID) of
                                        Server ->
                                            case maps:find(EID, Data#data.events) of
                                                {ok, #event{
                                                        json = #{<<"content">> :=
                                                                     #{<<"membership">> :=
                                                                           <<"join">>}}}} ->
                                                    throw(found);
                                                _ ->
                                                    ok
                                            end;
                                        _ ->
                                            ok
                                    end;
                               (_, _, ok) ->
                                    ok
                            end, ok, Event#event.state_map),
                          ok;
                      _ ->
                          ok
                  end
          end, ok, Data#data.latest_events),
        false
    catch
        throw:found ->
            true
    end.

get_remote_servers(Data) ->
    Servers =
        maps:fold(
          fun(EventID, _, Acc) ->
                  case maps:find(EventID, Data#data.events) of
                      {ok, Event} ->
                          maps:fold(
                            fun({?ROOM_MEMBER, UserID}, EID, Acc2) ->
                                    Server = mod_matrix_gw:get_id_domain_exn(UserID),
                                    case maps:find(EID, Data#data.events) of
                                        {ok, #event{
                                                json = #{<<"content">> :=
                                                             #{<<"membership">> :=
                                                                   <<"join">>}}}} ->
                                            maps:put(Server, [], Acc2);
                                        _ ->
                                            Acc2
                                    end;
                               (_, _, Acc2) ->
                                    Acc2
                            end, Acc, Event#event.state_map);
                      _ ->
                          Acc
                  end
          end, #{}, Data#data.latest_events),
    MatrixServer = mod_matrix_gw_opt:matrix_domain(Data#data.host),
    Servers2 = maps:remove(MatrixServer, Servers),
    maps:keys(Servers2).

get_joined_users(Data) ->
    Users =
        maps:fold(
          fun(EventID, _, Acc) ->
                  case maps:find(EventID, Data#data.events) of
                      {ok, Event} when is_map(Event#event.state_map) ->
                          maps:fold(
                            fun({?ROOM_MEMBER, UserID}, EID, Acc2) ->
                                    case maps:find(EID, Data#data.events) of
                                        {ok, #event{
                                                json = #{<<"content">> :=
                                                             #{<<"membership">> :=
                                                                   <<"join">>}}}} ->
                                            maps:put(UserID, [], Acc2);
                                        _ ->
                                            Acc2
                                    end;
                               (_, _, Acc2) ->
                                    Acc2
                            end, Acc, Event#event.state_map);
                      _ ->
                          Acc
                  end
          end, #{}, Data#data.latest_events),
    maps:keys(Users).

user_id_to_jid(Str, Data) ->
    Host = Data#data.host,
    ServerName = mod_matrix_gw_opt:matrix_domain(Host),
    case parse_user_id(Str) of
        {ok, U, ServerName} ->
            jid:make(U, Host);
        {ok, U, S} ->
            ServiceHost = mod_matrix_gw_opt:host(Host),
            EscU = escape(U),
            EscS = escape(S),
            jid:make(<<EscU/binary, $%, EscS/binary>>, ServiceHost);
        error ->
            error
    end.

new_room_id() ->
    Host = ejabberd_config:get_myname(),
    Letters = <<"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ">>,
    N = size(Letters),
    S = << <<(binary:at(Letters, X rem N))>> ||
            <<X>> <= crypto:strong_rand_bytes(18)>>,
    MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
    <<$!, S/binary, $:, MatrixServer/binary>>.

compute_event_auth_keys(#{<<"type">> := ?ROOM_CREATE}) ->
    [];
compute_event_auth_keys(#{<<"type">> := ?ROOM_MEMBER,
                          <<"sender">> := Sender,
                          <<"content">> := #{<<"membership">> := Membership} = Content,
                          <<"state_key">> := StateKey}) ->
    Common = [{?ROOM_CREATE, <<"">>},
              {?ROOM_POWER_LEVELS, <<"">>},
              {?ROOM_MEMBER, Sender},
              {?ROOM_MEMBER, StateKey}],
    case Membership of
        <<"join">> ->
            case Content of
                #{<<"join_authorised_via_users_server">> := AuthUser} ->
                    [{?ROOM_MEMBER, AuthUser}, {?ROOM_JOIN_RULES, <<"">>} | Common];
                _ ->
                    [{?ROOM_JOIN_RULES, <<"">>} | Common]
            end;
        <<"invite">> ->
            case Content of
                #{<<"third_party_invite">> := #{<<"signed">> := #{<<"token">> := Token}}} ->
                    [{?ROOM_3PI, Token}, {?ROOM_JOIN_RULES, <<"">>} | Common];
                _ ->
                    [{?ROOM_JOIN_RULES, <<"">>} | Common]
            end;
        <<"knock">> ->
            [{?ROOM_JOIN_RULES, <<"">>} | Common];
        _ ->
            Common
    end;
compute_event_auth_keys(#{<<"type">> := _, <<"sender">> := Sender}) ->
    [{?ROOM_CREATE, <<"">>},
     {?ROOM_POWER_LEVELS, <<"">>},
     {?ROOM_MEMBER, Sender}].


update_client(#data{client_state = undefined,
                    remote_user = RemoteUserID} = Data) ->
    Host = Data#data.host,
    MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
    JID = Data#data.local_user,
    LocalUserID = <<$@, (JID#jid.luser)/binary, $:, MatrixServer/binary>>,
    Users = get_joined_users(Data),
    case lists:member(LocalUserID, Users) of
        true ->
            case lists:delete(LocalUserID, Users) of
                [RemoteUserID] ->
                    {ok, Data#data{client_state = established}};
                [_] ->
                    {leave, unknown_remote_user, Data#data{client_state = leave}};
                [] ->
                    {ok, Data};
                _ ->
                    {leave, too_many_users, Data#data{client_state = leave}}
            end;
        false ->
            {ok, Data}
    end;
update_client(#data{client_state = established,
                    remote_user = RemoteUserID} = Data) ->
    Host = Data#data.host,
    MatrixServer = mod_matrix_gw_opt:matrix_domain(Host),
    JID = Data#data.local_user,
    LocalUserID = <<$@, (JID#jid.luser)/binary, $:, MatrixServer/binary>>,
    Users = get_joined_users(Data),
    case lists:member(LocalUserID, Users) of
        true ->
            case lists:member(RemoteUserID, Users) of
                true ->
                    {ok, Data};
                false ->
                    {leave, remote_user_left, Data#data{client_state = leave}}
            end;
        false ->
            stop
    end;
update_client(#data{client_state = leave}) ->
    stop.

escape(S) ->
    escape(S, <<>>).

escape(<<>>, Res) ->
    Res;
escape(<<C, S/binary>>, Res) ->
    Res2 =
        case C of
            $\s -> <<Res/binary, "\\20">>;
            $"  -> <<Res/binary, "\\22">>;
            $%  -> <<Res/binary, "\\25">>;
            $&  -> <<Res/binary, "\\26">>;
            $'  -> <<Res/binary, "\\27">>;
            $/  -> <<Res/binary, "\\2f">>;
            $:  -> <<Res/binary, "\\3a">>;
            $<  -> <<Res/binary, "\\3c">>;
            $>  -> <<Res/binary, "\\3e">>;
            $@  -> <<Res/binary, "\\40">>;
            $\\ -> <<Res/binary, "\\5c">>;
            _ -> <<Res/binary, C>>
        end,
    escape(S, Res2).

unescape(S) ->
    unescape(S, <<>>).

unescape(<<>>, Res) -> Res;
unescape(<<"\\20", S/binary>>, Res) -> unescape(S, <<Res/binary, $\s>>);
unescape(<<"\\22", S/binary>>, Res) -> unescape(S, <<Res/binary, $\">>);
unescape(<<"\\25", S/binary>>, Res) -> unescape(S, <<Res/binary, $%>>);
unescape(<<"\\26", S/binary>>, Res) -> unescape(S, <<Res/binary, $&>>);
unescape(<<"\\27", S/binary>>, Res) -> unescape(S, <<Res/binary, $\'>>);
unescape(<<"\\2f", S/binary>>, Res) -> unescape(S, <<Res/binary, $/>>);
unescape(<<"\\3a", S/binary>>, Res) -> unescape(S, <<Res/binary, $:>>);
unescape(<<"\\3c", S/binary>>, Res) -> unescape(S, <<Res/binary, $<>>);
unescape(<<"\\3e", S/binary>>, Res) -> unescape(S, <<Res/binary, $>>>);
unescape(<<"\\40", S/binary>>, Res) -> unescape(S, <<Res/binary, $@>>);
unescape(<<"\\5c", S/binary>>, Res) -> unescape(S, <<Res/binary, $\\>>);
unescape(<<C, S/binary>>, Res) -> unescape(S, <<Res/binary, C>>).

-endif.
