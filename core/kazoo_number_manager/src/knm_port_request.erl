%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors:
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(knm_port_request).

-export([init/0
         ,current_state/1
         ,public_fields/1
         ,get/1
         ,normalize_attachments/1
         ,normalize_numbers/1
         ,transition_to_complete/1
         ,maybe_transition/2
         ,charge_for_port/1, charge_for_port/2
         ,send_submitted_requests/0
         ,migrate/0
        ]).

-compile({'no_auto_import', [get/1]}).

-include("knm.hrl").
-include_lib("kazoo_number_manager/include/knm_port_request.hrl").

-define(VIEW_LISTING_SUBMITTED, <<"port_requests/listing_submitted">>).

-type transition_response() :: {'ok', wh_json:object()} |
                               {'error', 'invalid_state_transition'}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec init() -> any().
init() ->
    _ = kz_datamgr:db_create(?KZ_PORT_REQUESTS_DB),
    kz_datamgr:revise_doc_from_file(?KZ_PORT_REQUESTS_DB, 'crossbar', <<"views/port_requests.json">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec current_state(wh_json:object()) -> api_binary().
current_state(JObj) ->
    wh_json:get_value(?PORT_PVT_STATE, JObj, ?PORT_WAITING).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec public_fields(wh_json:object()) -> wh_json:object().
public_fields(JObj) ->
    As = wh_doc:attachments(JObj, wh_json:new()),

    wh_json:set_values([{<<"id">>, wh_doc:id(JObj)}
                        ,{<<"created">>, wh_doc:created(JObj)}
                        ,{<<"updated">>, wh_doc:modified(JObj)}
                        ,{<<"uploads">>, normalize_attachments(As)}
                        ,{<<"port_state">>, wh_json:get_value(?PORT_PVT_STATE, JObj, ?PORT_WAITING)}
                        ,{<<"sent">>, wh_json:get_value(?PVT_SENT, JObj, 'false')}
                       ]
                       ,wh_doc:public_fields(JObj)
                      ).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get(ne_binary() | knm_phone_number:knm_phone_number()) ->
                 {'ok', wh_json:object()} |
                 {'error', 'not_found'}.
get(DID)
  when is_binary(DID) ->
    ViewOptions = [{'key', DID}, 'include_docs'],
    case
        kz_datamgr:get_results(
          ?KZ_PORT_REQUESTS_DB
          ,<<"port_requests/port_in_numbers">>
          ,ViewOptions
         )
    of
        {'ok', []} -> {'error', 'not_found'};
        {'ok', [Port]} -> {'ok', wh_json:get_value(<<"doc">>, Port)};
        {'error', _E} ->
            lager:debug("failed to query for port number '~s': ~p", [DID, _E]),
            {'error', 'not_found'}
    end;
get(Number) ->
    ?MODULE:get(knm_phone_number:number(Number)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec normalize_attachments(wh_json:object()) -> wh_json:object().
normalize_attachments(Attachments) ->
    wh_json:map(fun normalize_attachments_map/2, Attachments).

%% @private
-spec normalize_attachments_map(wh_json:key(), wh_json:json_term()) ->
                                       {wh_json:key(), wh_json:json_term()}.
normalize_attachments_map(K, V) ->
    {K, wh_json:delete_keys([<<"digest">>, <<"revpos">>, <<"stub">>], V)}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec normalize_numbers(wh_json:object()) -> wh_json:object().
normalize_numbers(JObj) ->
    Numbers = wh_json:get_value(<<"numbers">>, JObj, wh_json:new()),
    Normalized = wh_json:map(fun normalize_number_map/2, Numbers),
    wh_json:set_value(<<"numbers">>, Normalized, JObj).

%% @private
-spec normalize_number_map(wh_json:key(), wh_json:json_term()) ->
                                  {wh_json:key(), wh_json:json_term()}.
normalize_number_map(N, Meta) ->
    {knm_converters:normalize(N), Meta}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec transition_to_submitted(wh_json:object()) -> transition_response().
-spec transition_to_pending(wh_json:object()) -> transition_response().
-spec transition_to_scheduled(wh_json:object()) -> transition_response().
-spec transition_to_complete(wh_json:object()) -> transition_response().
-spec transition_to_rejected(wh_json:object()) -> transition_response().
-spec transition_to_canceled(wh_json:object()) -> transition_response().

transition_to_submitted(JObj) ->
    transition(JObj, [?PORT_WAITING, ?PORT_REJECT], ?PORT_SUBMITTED).

transition_to_pending(JObj) ->
    transition(JObj, [?PORT_SUBMITTED], ?PORT_PENDING).

transition_to_scheduled(JObj) ->
    transition(JObj, [?PORT_PENDING], ?PORT_SCHEDULED).

transition_to_complete(JObj) ->
    case transition(JObj, [?PORT_PENDING, ?PORT_SCHEDULED, ?PORT_REJECT], ?PORT_COMPLETE) of
        {'error', _}=E -> E;
        {'ok', Transitioned} -> completed_port(Transitioned)
    end.

transition_to_rejected(JObj) ->
    transition(JObj, [?PORT_SUBMITTED, ?PORT_PENDING, ?PORT_SCHEDULED], ?PORT_REJECT).

transition_to_canceled(JObj) ->
    transition(JObj, [?PORT_WAITING, ?PORT_SUBMITTED, ?PORT_PENDING, ?PORT_SCHEDULED, ?PORT_REJECT], ?PORT_CANCELED).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_transition(wh_json:object(), ne_binary()) -> transition_response().
maybe_transition(PortReq, ?PORT_SUBMITTED) ->
    transition_to_submitted(PortReq);
maybe_transition(PortReq, ?PORT_PENDING) ->
    transition_to_pending(PortReq);
maybe_transition(PortReq, ?PORT_SCHEDULED) ->
    transition_to_scheduled(PortReq);
maybe_transition(PortReq, ?PORT_COMPLETE) ->
    transition_to_complete(PortReq);
maybe_transition(PortReq, ?PORT_REJECT) ->
    transition_to_rejected(PortReq);
maybe_transition(PortReq, ?PORT_CANCELED) ->
    transition_to_canceled(PortReq).

-spec transition(wh_json:object(), ne_binaries(), ne_binary()) ->
                        transition_response().
-spec transition(wh_json:object(), ne_binaries(), ne_binary(), ne_binary()) ->
                        transition_response().
transition(JObj, FromStates, ToState) ->
    transition(JObj, FromStates, ToState, current_state(JObj)).
transition(_JObj, [], _ToState, _CurrentState) ->
    lager:debug("cant go from ~s to ~s", [_CurrentState, _ToState]),
    {'error', 'invalid_state_transition'};
transition(JObj, [CurrentState | _], ToState, CurrentState) ->
    lager:debug("going from ~s to ~s", [CurrentState, ToState]),
    {'ok', wh_json:set_value(?PORT_PVT_STATE, ToState, JObj)};
transition(JObj, [_FromState | FromStates], ToState, CurrentState) ->
    lager:debug("skipping from ~s to ~s c ~p", [_FromState, ToState, CurrentState]),
    transition(JObj, FromStates, ToState, CurrentState).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec charge_for_port(wh_json:object()) -> 'ok' | 'error'.
-spec charge_for_port(wh_json:object(), ne_binary()) -> 'ok' | 'error'.
charge_for_port(JObj) ->
    charge_for_port(JObj, wh_doc:account_id(JObj)).
charge_for_port(_JObj, AccountId) ->
    Services = wh_services:fetch(AccountId),
    Cost = wh_services:activation_charges(<<"number_services">>, <<"port">>, Services),
    Transaction = wh_transaction:debit(AccountId, wht_util:dollars_to_units(Cost)),
    wh_services:commit_transactions(Services, [Transaction]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_submitted_requests() -> 'ok'.
send_submitted_requests() ->
    case kz_datamgr:get_results(?KZ_PORT_REQUESTS_DB
                               ,?VIEW_LISTING_SUBMITTED
                               ,['include_docs']
                              )
    of
        {'error', _R} ->
            lager:error("failed to open view ~s ~p", [?VIEW_LISTING_SUBMITTED, _R]);
        {'ok', []} -> 'ok';
        {'ok', JObjs} ->
            _ = [maybe_send_request(wh_json:get_value(<<"doc">>, JObj)) || JObj <- JObjs],
            lager:debug("sent requests")
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec migrate() -> 'ok'.
migrate() ->
    wh_util:put_callid(<<"port_request_migration">>),
    lager:debug("migrating port request documents, if necessary"),
    migrate(<<>>, 10),
    lager:debug("finished migrating port request documents").

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec completed_port(wh_json:object()) -> transition_response().
completed_port(PortReq) ->
    case charge_for_port(PortReq) of
        'ok' ->
            lager:debug("successfully charged for port, transitioning numbers to active"),
            transition_numbers(PortReq);
        'error' ->
            throw({'error', 'failed_to_charge'})
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec transition_numbers(wh_json:object()) -> transition_response().
transition_numbers(PortReq) ->
    Numbers = wh_json:get_keys(<<"numbers">>, PortReq),
    PortOps = [enable_number(N) || N <- Numbers],
    case lists:all(fun wh_util:is_true/1, PortOps) of
        'true' ->
            lager:debug("all numbers ported, removing from port request"),
            ClearedPortRequest = clear_numbers_from_port(PortReq),
            {'ok', ClearedPortRequest};
        'false' ->
            lager:debug("failed to transition numbers: ~p", [PortOps]),
            {'error', PortReq}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec clear_numbers_from_port(wh_json:object()) -> wh_json:object().
clear_numbers_from_port(PortReq) ->
    Cleared = wh_json:set_value(<<"numbers">>, wh_json:new(), PortReq),
    case kz_datamgr:save_doc(?KZ_PORT_REQUESTS_DB, Cleared) of
        {'ok', PortReq1} -> lager:debug("port numbers cleared"), PortReq1;
        {'error', 'conflict'} ->
            lager:debug("port request doc was updated before we could re-save"),
            PortReq;
        {'error', _E} ->
            lager:debug("failed to clear numbers: ~p", [_E]),
            PortReq
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec enable_number(ne_binary()) -> boolean().
enable_number(Num) ->
    try knm_number_states:to_state(Num, ?NUMBER_STATE_IN_SERVICE) of
        _Number -> 'true'
    catch
        'throw':_R ->
            lager:error("failed to enable number ~s : ~p", [Num, _R]),
            'false'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_send_request(wh_json:object()) -> 'ok'.
-spec maybe_send_request(wh_json:object(), api_binary()) -> 'ok'.
maybe_send_request(JObj) ->
    wh_util:put_callid(wh_doc:id(JObj)),
    AccountId = wh_doc:account_id(JObj),
    case kz_account:fetch(AccountId) of
        {'ok', AccountDoc} ->
            Url = wh_json:get_value(<<"submitted_port_requests_url">>, AccountDoc),
            maybe_send_request(JObj, Url);
        {'error', _R} ->
            lager:error("failed to open account ~s:~p", [AccountId, _R])
    end.

maybe_send_request(JObj, 'undefined')->
    lager:debug("'submitted_port_requests_url' is not set for account ~s"
                ,[wh_doc:account_id(JObj)]);
maybe_send_request(JObj, Url)->
    case send_request(JObj, Url) of
        'error' -> 'ok';
        'ok' ->
            case send_attachements(Url, JObj) of
                'error' -> 'ok';
                'ok' -> set_flag(JObj)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_request(wh_json:object(), ne_binary()) -> 'error' | 'ok'.
send_request(JObj, Url) ->
    Headers = [{"Content-Type", "application/json"}
               ,{"User-Agent", wh_util:to_list(erlang:node())}
              ],

    Uri = wh_util:to_list(<<Url/binary, "/", (wh_doc:id(JObj))/binary>>),

    Remove = [<<"_rev">>
              ,<<"ui_metadata">>
              ,<<"_attachments">>
              ,<<"pvt_request_id">>
              ,<<"pvt_type">>
              ,<<"pvt_vsn">>
              ,<<"pvt_account_db">>
             ],
    Replace = [{<<"_id">>, <<"id">>}
               ,{<<"pvt_port_state">>, <<"port_state">>}
               ,{<<"pvt_account_id">>, <<"account_id">>}
               ,{<<"pvt_created">>, <<"created">>}
               ,{<<"pvt_modified">>, <<"modified">>}
              ],
    Data = wh_json:encode(wh_json:normalize_jobj(JObj, Remove, Replace)),

    case kz_http:post(Uri, Headers, Data) of
        {'ok', 200, _Headers, _Resp} ->
            lager:debug("submitted_port_request successfully sent");
        _Other ->
            lager:error("failed to send submitted_port_request ~p", [_Other]),
            'error'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_attachements(ne_binary(), wh_json:object()) -> 'error' | 'ok'.
send_attachements(Url, JObj) ->
    try fetch_and_send(Url, JObj) of
        'ok' -> 'ok'
    catch
        'throw':'error' -> 'error'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec fetch_and_send(ne_binary(), wh_json:object()) -> 'ok'.
fetch_and_send(Url, JObj) ->
    Id = wh_doc:id(JObj),
    Attachments = wh_doc:attachments(JObj, wh_json:new()),

    wh_json:foldl(
      fun(Key, Value, 'ok') ->
              case kz_datamgr:fetch_attachment(?KZ_PORT_REQUESTS_DB, Id, Key) of
                  {'error', _R} ->
                      lager:error("failed to fetch attachment ~s : ~p", [Key, _R]),
                      throw('error');
                  {'ok', Attachment} ->
                      send_attachment(Url, Id, Key, Value, Attachment)
              end
      end
      ,'ok'
      ,Attachments
     ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_attachment(ne_binary(), ne_binary(), ne_binary(), wh_json:object(), binary()) ->
                              'error' | 'ok'.
send_attachment(Url, Id, Name, Options, Attachment) ->
    ContentType = wh_json:get_value(<<"content_type">>, Options),

    Headers = [{"Content-Type", wh_util:to_list(ContentType)}
               ,{"User-Agent", wh_util:to_list(erlang:node())}
              ],

    Uri = wh_util:to_list(<<Url/binary, "/", Id/binary, "/", Name/binary>>),

    case kz_http:post(Uri, Headers, Attachment) of
        {'ok', 200, _Headers, _Resp} ->
            lager:debug("attachment ~s for submitted_port_request successfully sent", [Name]);
        _Other ->
            lager:error("failed to send attachment ~s for submitted_port_request ~p", [Name, _Other]),
            'error'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec set_flag(wh_json:object()) -> 'ok'.
set_flag(JObj) ->
    Doc = wh_json:set_value(?PVT_SENT, 'true', JObj),
    case kz_datamgr:save_doc(?KZ_PORT_REQUESTS_DB, Doc) of
        {'ok', _} ->
            lager:debug("flag for submitted_port_request successfully set");
        {'error', _R} ->
            lager:debug("failed to set flag for submitted_port_request: ~p", [_R])
    end.


-spec migrate(binary(), pos_integer()) -> 'ok'.
migrate(StartKey, Limit) ->
    {'ok', Docs} = fetch_docs(StartKey, Limit),
    try lists:split(Limit, Docs) of
        {Results, []} ->
            migrate_docs(Results);
        {Results, [NextResult]} ->
            migrate_docs(Results),
            lager:debug("migrated batch of ~p port requests", [Limit]),
            timer:sleep(5000),
            migrate(wh_json:get_value(<<"key">>, NextResult), Limit)
    catch
        'error':'badarg' ->
            migrate_docs(Docs)
    end.

-spec migrate_docs(wh_json:objects()) -> 'ok'.
migrate_docs([]) -> 'ok';
migrate_docs(Docs) ->
    case prepare_docs_for_migrate(Docs) of
        [] -> 'ok';
        UpdatedDocs ->
            {'ok', _} = kz_datamgr:save_docs(?KZ_PORT_REQUESTS_DB, UpdatedDocs),
            'ok'
    end.

-spec prepare_docs_for_migrate(wh_json:objects()) -> wh_json:objects().
prepare_docs_for_migrate(Docs) ->
    [UpdatedDoc || Doc <- Docs,
            (UpdatedDoc = migrate_doc(wh_json:get_value(<<"doc">>, Doc))) =/= 'undefined'
    ].

-spec migrate_doc(wh_json:object()) -> api_object().
migrate_doc(PortRequest) ->
    case wh_json:get_value(<<"pvt_tree">>, PortRequest) of
        'undefined' -> update_doc(PortRequest);
        _Tree -> 'undefined'
    end.

-spec update_doc(wh_json:object()) -> api_object().
-spec update_doc(wh_json:object(), api_binary()) -> api_object().
update_doc(PortRequest) ->
    update_doc(PortRequest, wh_doc:account_id(PortRequest)).

update_doc(_Doc, 'undefined') ->
    lager:debug("no account id in doc ~s", [wh_doc:id(_Doc)]),
    'undefined';
update_doc(PortRequest, AccountId) ->
    {'ok', AccountDoc} = kz_account:fetch(AccountId),
    wh_json:set_value(<<"pvt_tree">>, kz_account:tree(AccountDoc), PortRequest).

-spec fetch_docs(binary(), pos_integer()) -> {'ok', wh_json:objects()}.
fetch_docs(StartKey, Limit) ->
    ViewOptions = [{'startkey', StartKey}
                   ,{'limit', Limit + 1}
                   ,'include_docs'
                  ],
    kz_datamgr:all_docs(?KZ_PORT_REQUESTS_DB, ViewOptions).
