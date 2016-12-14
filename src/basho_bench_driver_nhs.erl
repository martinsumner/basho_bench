%% -------------------------------------------------------------------
%%
%% basho_bench_driver_2i_nhs: Driver for NHS-like workloads
%%
%% Copyright (c) 2009 Basho Techonologies
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(basho_bench_driver_nhs).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

-record(state, {
          pb_pid,
          http_host,
          http_port,
          recordBucket,
          documentBucket,
          pb_timeout,
          http_timeout
         }).

-define(POSTCODE_AREAS,
                [{1, "AB"}, {2, "AL"}, {3, "B"}, {4, "BA"}, {5, "BB"}, 
                {6, "BD"}, {7, "BH"}, {8, "BL"}, {9, "BN"}, {10, "BR"}, 
                {11, "BS"}, {12, "BT"}, {13, "CA"}, {14, "CB"}, {15, "CF"}, 
                {16, "CH"}, {17, "CM"}, {18, "CO"}, {19, "CR"}, {20, "CT"}, 
                {21, "CV"}, {22, "CW"}, {23, "DA"}, {24, "DD"}, {25, "DE"}, 
                {26, "DG"}, {27, "DH"}, {28, "DL"}, {29, "DN"}, {30, "DT"}, 
                {31, "DU"}, {32, "E"}, {33, "EC"}, {34, "EH"}, {35, "EN"}, 
                {36, "EX"}, {37, "FK"}, {38, "FY"}, {39, "G"}, {40, "GL"}, 
                {41, "GU"}, {42, "HA"}, {43, "HD"}, {44, "HG"}, {45, "HP"}, 
                {46, "HR"}, {47, "HS"}, {48, "HU"}, {49, "HX"}, {50, "IG"}, 
                {51, "IP"}, {52, "IV"}, {53, "KA"}, {54, "KT"}, {55, "KW"}, 
                {56, "KY"}, {57, "L"}, {58, "LA"}, {59, "LD"}, {60, "LE"}, 
                {61, "LL"}, {62, "LS"}, {63, "LU"}, {64, "M"}, {65, "ME"}, 
                {66, "MK"}, {67, "ML"}, {68, "N"}, {69, "NE"}, {70, "NG"}, 
                {71, "MM"}, {72, "NP"}, {73, "NR"}, {74, "NW"}, {75, "OL"}, 
                {76, "OX"}]).
-define(DATETIME_FORMAT, "~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w").
-define(DATE_FORMAT, "~b-~2..0b-~2..0b").

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->
    %% Ensure that ibrowse is started...
    application:start(ibrowse),

    %% Ensure that riakc library is in the path...
    ensure_module(riakc_pb_socket),
    ensure_module(mochijson2),

    %% Read config settings...
    PBIPs  = basho_bench_config:get(pb_ips, ["127.0.0.1"]),
    PBPort  = basho_bench_config:get(pb_port, 8087),
    HTTPIPs = basho_bench_config:get(http_ips, ["127.0.0.1"]),
    HTTPPort =  basho_bench_config:get(http_port, 8098),

    PBTimeout = basho_bench_config:get(pb_timeout_general, 30*1000),
    HTTPTimeout = basho_bench_config:get(http_timeout_general, 30*1000),

    %% Choose the target node using our ID as a modulus
    HTTPTargets = basho_bench_config:normalize_ips(HTTPIPs, HTTPPort),
    {HTTPTargetIp,
        HTTPTargetPort} = lists:nth((Id rem length(HTTPTargets) + 1),
                                    HTTPTargets),
    ?INFO("Using http target ~p:~p for worker ~p\n", [HTTPTargetIp,
                                                        HTTPTargetPort,
                                                        Id]),

    %% Choose the target node using our ID as a modulus
    PBTargets = basho_bench_config:normalize_ips(PBIPs, PBPort),
    {PBTargetIp,
        PBTargetPort} = lists:nth((Id rem length(PBTargets) + 1),
                                    PBTargets),
    ?INFO("Using pb target ~p:~p for worker ~p\n", [PBTargetIp,
                                                    PBTargetPort,
                                                    Id]),
    
    case riakc_pb_socket:start_link(PBTargetIp, PBTargetPort) of
        {ok, Pid} ->
            {ok, #state {
               pb_pid = Pid,
               http_host = HTTPTargetIp,
               http_port = HTTPTargetPort,
               recordBucket = <<"domainRecord">>,
               documentBucket = <<"domainDocument">>,
               pb_timeout = PBTimeout,
               http_timeout = HTTPTimeout}};
        {error, Reason2} ->
            ?FAIL_MSG("Failed to connect riakc_pb_socket to ~p port ~p: ~p\n",
                      [PBTargetIp, PBTargetPort, Reason2])
    end.

%% Get a single object.
run(get_pb, KeyGen, _ValueGen, State) ->
    Pid = State#state.pb_pid,
    Bucket = State#state.recordBucket,
    Key = to_binary(KeyGen()),
    case riakc_pb_socket:get(Pid, Bucket, Key, State#state.pb_timeout) of
        {ok, _Obj} ->
            {ok, State};
        {error, notfound} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end;

%% Update an object with secondary indexes.
run(update_with2i, KeyGen, ValueGen, State) ->
    Pid = State#state.pb_pid,
    Bucket = State#state.recordBucket,
    Key = to_binary(KeyGen()),
    Value = ValueGen(),
    
    Robj0 =
        case riakc_pb_socket:get(Pid, Bucket, Key, State#state.pb_timeout) of
            {ok, Robj} ->
                Robj;
            {error, notfound} ->
                riak_object:new(Bucket, Key)
        end,
    
    MD0 = riakc_obj:get_update_metadata(Robj0),
    MD1 = riakc_obj:clear_scondary_indexes(MD0),
    MD2 = riakc_obj:set_secondary_index(MD1, generate_binary_indexes()),
    Robj1 = riakc_obj:update_value(Robj0, Value),
    Robj2 = riakc_obj:update_metadata(Robj1, MD2),

    %% Write the object...
    case riakc_pb_socket:put(Pid, Robj2, State#state.pb_timeout) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end;
%% Put an object with a unique key and a non-compressable value
run(put_unique, _KeyGen, _ValueGen, State) ->
    Pid = State#state.pb_pid,
    Bucket = State#state.recordBucket,
    
    Key = generate_uniquekey(),
    Value = non_compressible_value(6000),
    
    Robj0 = riak_object:new(Bucket, Key),
    MD1 = riakc_obj:get_update_metadata(Robj0),
    MD2 = riakc_obj:set_secondary_index(MD1, generate_binary_indexes()),
    Robj1 = riakc_obj:update_value(Robj0, Value),
    Robj2 = riakc_obj:update_metadata(Robj1, MD2),

    %% Write the object...
    case riakc_pb_socket:put(Pid, Robj2, State#state.pb_timeout) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end;

%% Query results via the HTTP interface.
run(postcodequery_http, _KeyGen, _ValueGen, State) ->
    Host = State#state.http_host,
    Port = State#state.http_port,
    Bucket = State#state.recordBucket,
    
    L = length(?POSTCODE_AREAS),
    Area = lists:keyfind(random:uniform(L), 1, ?POSTCODE_AREAS),
    District = Area ++ integer_to_list(random:uniform(26)),
    StartKey = District ++ "|" ++ "a",
    EndKey = District ++ "|" ++ "b",
    URL = io_lib:format("http://~s:~p/buckets/~s/index/postcode_bin/~s/~s", 
                    [Host, Port, Bucket, StartKey, EndKey]),

    case json_get(URL, State) of
        {ok, {struct, Proplist}} ->
            Results = proplists:get_value(<<"keys">>, Proplist),
            io:format("PostC query results of length ~w~n", length(Results)),
            {ok, State};
        {error, Reason} ->
            io:format("[~s:~p] ERROR - Reason: ~p~n",
                        [?MODULE, ?LINE, Reason]),
            {error, Reason, State}
    end;

%% Query results via the HTTP interface.
run(dobquery_http, _KeyGen, _ValueGen, State) ->
    Host = State#state.http_host,
    Port = State#state.http_port,
    Bucket = State#state.recordBucket,
    
    RandYear = random:uniform(70) + 1950,
    DoBStart = integer_to_list(RandYear) ++ "0101",
    DoBEnd = integer_to_list(RandYear) ++ "0110",
    
    URLSrc = "http://~s:~p/buckets/~s/index/postcode_bin/~s/~s?term_regex=~s",
    URL = io_lib:format(URLSrc, 
                        [Host, Port, Bucket, DoBStart, DoBEnd, "[0-9]{8}\|a"]),

    case json_get(URL, State) of
        {ok, {struct, Proplist}} ->
            Results = proplists:get_value(<<"keys">>, Proplist),
            io:format("DoB query results of length ~w~n", length(Results)),
            {ok, State};
        {error, Reason} ->
            io:format("[~s:~p] ERROR - Reason: ~p~n",
                        [?MODULE, ?LINE, Reason]),
            {error, Reason, State}
    end;

run(Other, _, _, _) ->
    throw({unknown_operation, Other}).

%% ====================================================================
%% Internal functions
%% ====================================================================

json_get(Url, State) ->
    Response = ibrowse:send_req(lists:flatten(Url), [], get,
                                [], [], State#state.pb_timeout),
    case Response of
        {ok, "200", _, Body} ->
            {ok, mochijson2:decode(Body)};
        Other ->
            {error, Other}
    end.

to_binary(B) when is_binary(B) ->
    B;
to_binary(I) when is_integer(I) ->
    list_to_binary(integer_to_list(I));
to_binary(L) when is_list(L) ->
    list_to_binary(L).

ensure_module(Module) ->
    case code:which(Module) of
        non_existing ->
            ?FAIL_MSG("~s requires " ++ atom_to_list(Module) ++ 
                            " module to be available on code path.\n", 
                        [?MODULE]);
        _ ->
            ok
    end.

%% ====================================================================
%% Index seeds
%% ====================================================================

generate_binary_indexes() ->
    [{{binary_index, "postcode"}, postcode_index()},
        {{binary_index, "dateofbirth"}, dateofbirth_index()},
        {{binary_index, "lastmodified"}, lastmodified_index()}].

postcode_index() ->
    NotVeryNameLikeThing = base64:encode_to_string(crypto:rand_bytes(4)),
    lists:map(fun(_X) -> 
                    L = length(?POSTCODE_AREAS),
                    Area = lists:keyfind(random:uniform(L), 1, ?POSTCODE_AREAS),
                    District = Area ++ integer_to_list(random:uniform(26)),
                    F = District ++ "|" ++ NotVeryNameLikeThing,
                    list_to_binary(F) end,
                lists:seq(1, random:uniform(3))).

dateofbirth_index() ->
    Delta = random:uniform(2500000000),
    {{Y, M, D},
        _} = calendar:gregorian_seconds_to_datetime(Delta + 61000000000),
    F = lists:flatten(io_lib:format(?DATE_FORMAT, [Y, M, D])) ++ "|" ++
            base64:encode_to_string(crypto:rand_bytes(4)),
    [list_to_binary(F)].

lastmodified_index() ->
    {{Year, Month, Day},
        {Hr, Min, Sec}} = calendar:now_to_datetime(os:timestamp()),
    F = lists:flatten(io_lib:format(?DATETIME_FORMAT,
                                        [Year, Month, Day, Hr, Min, Sec])),
    [list_to_binary(F)].
    

generate_uniquekey() ->
    {{Year, Month, Day},
        {Hr, Min, Sec}} = calendar:now_to_datetime(os:timestamp()),
    F = lists:flatten(io_lib:format(?DATETIME_FORMAT,
                                        [Year, Month, Day, Hr, Min, Sec])),
    F ++ [base64:encode_to_string(crypto:rand_bytes(4))],
    list_to_binary(F).

non_compressible_value(Size) ->
    crypto:rand_bytes(Size).


