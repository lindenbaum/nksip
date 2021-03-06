%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Call Proxy Management
-module(nksip_call_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([route/4, response_stateless/2]).
-export([normalize_uriset/1]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Tries to route a request to set of uris, serially and/or in parallel.
-spec route(nksip:uri_set(), nksip:optslist(), nksip_call:trans(), nksip_call:call()) -> 
    {fork, nksip_call:trans(), nksip:uri_set()} | noreply | 
    {reply, nksip:sipreply(), nksip_call:call()}.

route(UriList, ProxyOpts, UAS, Call) ->
    try
        #call{app_id=AppId} = Call,
        UriSet = case normalize_uriset(UriList) of
            [[]] -> throw({reply, temporarily_unavailable});
            UriSet0 -> UriSet0
        end,
        % error_logger:warning_msg("URISET: ~p", [UriList]),
        #trans{method=Method} = UAS,
        case AppId:nkcb_route(UriSet, ProxyOpts, UAS, Call) of
            {continue, [UriSet1, ProxyOpts1, UAS1, Call1]} ->
                ok;
            {reply, Reply, Call1} ->
                UriSet1=ProxyOpts1=UAS1=throw({reply, Reply, Call1})
        end,
        Req1 = check_request(UAS1#trans.request, ProxyOpts1),
        Stateless = lists:member(stateless, ProxyOpts1),
        case Method of
            'ACK' when Stateless ->
                [[First|_]|_] = UriSet1,
                route_stateless(Req1, First, ProxyOpts1, Call1);
            'ACK' ->
                {fork, UAS1#trans{request=Req1}, UriSet1, ProxyOpts1};
            _ ->
                case nksip_sipmsg:header(<<"proxy-require">>, Req1, tokens) of
                    [] -> 
                        ok;
                    PR ->
                        Text = nksip_lib:bjoin([T || {T, _} <- PR]),
                        throw({reply, {bad_extension, Text}})
                end,
                case Stateless of
                    true -> 
                        [[First|_]|_] = UriSet1,
                        route_stateless(Req1, First, ProxyOpts1, Call1);
                    false ->
                        {fork, UAS1#trans{request=Req1}, UriSet1, ProxyOpts1}
                end
        end
    catch
        throw:{reply, TReply} -> {reply, TReply, Call};
        throw:{reply, TReply, TCall} -> {reply, TReply, TCall}
    end.


%% @private
-spec route_stateless(nksip:request(), nksip:uri(), nksip:optslist(), nksip_call:call()) -> 
    noreply.

route_stateless(Req, Uri, ProxyOpts, _Call) ->
    #sipmsg{class={req, Method}} = Req,
    Req1 = Req#sipmsg{ruri=Uri},
    case nksip_call_uac_make:proxy_make(Req1, ProxyOpts) of
        {ok, Req2, ProxyOpts2} ->
            SendOpts = [stateless_via | ProxyOpts2],
            case nksip_call_uac_transp:send_request(Req2, SendOpts) of
                {ok, _} ->  
                    ?call_debug("Stateless proxy routing ~p to ~s", 
                                [Method, nksip_unparse:uri(Uri)]);
                {error, Error} -> 
                    ?call_notice("Stateless proxy could not route ~p to ~s: ~p",
                                 [Method, nksip_unparse:uri(Uri), Error])
            end,
           noreply;
        {reply, Reply} ->
            throw({reply, Reply});
        {error, Error} ->
            ?call_warning("Error procesing proxy opts: ~p, ~p: ~p", 
                          [Uri, ProxyOpts, Error]),
            throw({reply, {internal_error, "Proxy Options"}})
    end.
    

%% @doc Called from {@link nksip_call} when a stateless request is received.
-spec response_stateless(nksip:response(), nksip_call:call()) -> 
    nksip_call:call().

response_stateless(#sipmsg{class={resp, Code, _}}, Call) when Code < 101 ->
    Call;

response_stateless(#sipmsg{vias=[_, Via|RestVias], transport=Transp}=Resp, Call) ->
    #sipmsg{cseq={_, Method}, class={resp, Code, _}} = Resp,
    #via{proto=ViaProto, port=ViaPort, opts=ViaOpts} = Via,
    {ok, RIp} = nksip_lib:to_ip(nksip_lib:get_value(<<"received">>, ViaOpts)),
    RPort = case nksip_lib:get_integer(<<"rport">>, ViaOpts) of
        0 -> ViaPort;
        RPort0 -> RPort0
    end,
    Transp1 = Transp#transport{proto=ViaProto, remote_ip=RIp, remote_port=RPort},
    Resp1 = Resp#sipmsg{vias=[Via|RestVias], transport=Transp1},
    case nksip_call_uas_transp:send_response(Resp1, []) of
        {ok, _} -> 
            ?call_debug("Stateless proxy sent ~p ~p response", [Method, Code]);
        error -> 
            ?call_notice("Stateless proxy could not send ~p ~p response", 
                         [Method, Code])
    end,
    Call;

response_stateless(_, Call) ->
    ?call_notice("Stateless proxy could not send response: no Via", []),
    Call.




%%====================================================================
%% Internal 
%%====================================================================


%% @private
-spec check_request(nksip:request(), nksip:optslist()) ->
    nksip:request().

check_request(#sipmsg{class={req, Method}, forwards=Forwards}=Req, Opts) ->
    if
        is_integer(Forwards), Forwards > 0 ->   
            ok;
        Forwards==0, Method=='OPTIONS' ->
            throw({reply, {ok, [supported, accept, allow, 
                                {reason_phrase, <<"Max Forwards">>}]}});
        Forwards==0 ->
            throw({reply, too_many_hops});
        true -> 
            throw({reply, invalid_request})
    end,
    case lists:member(path, Opts) of     
        true ->
            case nksip_sipmsg:supported(<<"path">>, Req) of
                true -> ok;
                false -> throw({reply, {extension_required, <<"path">>}})
            end;
        false ->
            ok
    end,
    Req#sipmsg{forwards=Forwards-1}.


%% @doc Process a UriSet generating a standard `[[nksip:uri()]]'.
%% See test code for examples.
-spec normalize_uriset(nksip:uri_set()) ->
    [[nksip:uri()]].

normalize_uriset(#uri{}=Uri) ->
    [[uri2ruri(Uri)]];

normalize_uriset(UriSet) when is_binary(UriSet) ->
    [pruris(UriSet)];

normalize_uriset(UriSet) when is_list(UriSet) ->
    case nksip_lib:is_string(UriSet) of
        true -> [pruris(UriSet)];
        false -> normalize_uriset(single, UriSet, [], [])
    end;

normalize_uriset(_) ->
    [[]].


normalize_uriset(single, [#uri{}=Uri|R], Acc1, Acc2) -> 
    normalize_uriset(single, R, Acc1++[uri2ruri(Uri)], Acc2);

normalize_uriset(multi, [#uri{}=Uri|R], Acc1, Acc2) -> 
    case Acc1 of
        [] -> normalize_uriset(multi, R, [], Acc2++[[uri2ruri(Uri)]]);
        _ -> normalize_uriset(multi, R, [], Acc2++[Acc1]++[[uri2ruri(Uri)]])
    end;

normalize_uriset(single, [Bin|R], Acc1, Acc2) when is_binary(Bin) -> 
    normalize_uriset(single, R, Acc1++pruris(Bin), Acc2);

normalize_uriset(multi, [Bin|R], Acc1, Acc2) when is_binary(Bin) -> 
    case Acc1 of
        [] -> normalize_uriset(multi, R, [], Acc2++[pruris(Bin)]);
        _ -> normalize_uriset(multi, R, [], Acc2++[Acc1]++[pruris(Bin)])
    end;

normalize_uriset(single, [List|R], Acc1, Acc2) when is_list(List) -> 
    case nksip_lib:is_string(List) of
        true -> normalize_uriset(single, R, Acc1++pruris(List), Acc2);
        false -> normalize_uriset(multi, [List|R], Acc1, Acc2)
    end;

normalize_uriset(multi, [List|R], Acc1, Acc2) when is_list(List) -> 
    case nksip_lib:is_string(List) of
        true when Acc1==[] ->
            normalize_uriset(multi, R, [], Acc2++[pruris(List)]);
        true ->
            normalize_uriset(multi, R, [], Acc2++[Acc1]++[pruris(List)]);
        false when Acc1==[] ->  
            normalize_uriset(multi, R, [], Acc2++[pruris(List)]);
        false ->
            normalize_uriset(multi, R, [], Acc2++[Acc1]++[pruris(List)])
    end;

normalize_uriset(Type, [_|R], Acc1, Acc2) ->
    normalize_uriset(Type, R, Acc1, Acc2);

normalize_uriset(_Type, [], [], []) ->
    [[]];

normalize_uriset(_Type, [], [], Acc2) ->
    Acc2;

normalize_uriset(_Type, [], Acc1, Acc2) ->
    Acc2++[Acc1].


uri2ruri(Uri) ->
    Uri#uri{ext_opts=[], ext_headers=[]}.

pruris(RUri) ->
    case nksip_parse:uris(RUri) of
        error -> [];
        RUris -> [uri2ruri(Uri) || Uri <- RUris]
    end.



%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


normalize_test() ->
    UriA = #uri{domain=(<<"a">>)},
    UriB = #uri{domain=(<<"b">>)},
    UriC = #uri{domain=(<<"c">>)},
    UriD = #uri{domain=(<<"d">>)},
    UriE = #uri{domain=(<<"e">>)},

    ?assert(normalize_uriset([]) == [[]]),
    ?assert(normalize_uriset(a) == [[]]),
    ?assert(normalize_uriset([a,b]) == [[]]),
    ?assert(normalize_uriset("sip:a") == [[UriA]]),
    ?assert(normalize_uriset(<<"sip:b">>) == [[UriB]]),
    ?assert(normalize_uriset("other") == [[]]),
    ?assert(normalize_uriset(UriC) == [[UriC]]),
    ?assert(normalize_uriset([UriD]) == [[UriD]]),
    ?assert(normalize_uriset(["sip:a", "sip:b", UriC, <<"sip:d">>, "sip:e"]) 
                                            == [[UriA, UriB, UriC, UriD, UriE]]),
    ?assert(normalize_uriset(["sip:a", ["sip:b", UriC], <<"sip:d">>, ["sip:e"]]) 
                                            == [[UriA], [UriB, UriC], [UriD], [UriE]]),
    ?assert(normalize_uriset([["sip:a", "sip:b", UriC], <<"sip:d">>, "sip:e"]) 
                                            == [[UriA, UriB, UriC], [UriD], [UriE]]),
    ok.

-endif.



