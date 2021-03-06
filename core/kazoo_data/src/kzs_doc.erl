%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2016, 2600Hz
%%% @doc
%%% data adapter behaviour
%%% @end
%%% @contributors
%%%-----------------------------------------------------------------------------
-module(kzs_doc).

%% Doc related
-export([open_doc/4
         ,lookup_doc_rev/3
         ,save_doc/4
         ,save_docs/4
         ,del_doc/4
         ,del_docs/4
         ,ensure_saved/4
         ,copy_doc/3
         ,move_doc/3
        ]).


-include("kz_data.hrl").

-type copy_function() :: fun((map(), ne_binary(), wh_json:object(), wh_proplist()) ->
                              {'ok', wh_json:object()} | data_error()).
-export_type([copy_function/0]).
-define(COPY_DOC_OVERRIDE_PROPERTY, 'override_existing_document').


%% Document related functions --------------------------------------------------

-spec open_doc(map(), ne_binary(), ne_binary(), wh_proplist()) ->
                      {'ok', wh_json:object()} |
                      data_error().
open_doc(#{server := {App, Conn}}, DbName, DocId, Options) ->
    App:open_doc(Conn, DbName, DocId, Options).

-spec save_doc(map(), ne_binary(), wh_json:object(), wh_proplist()) ->
                      {'ok', wh_json:object()} |
                      data_error().
save_doc(#{server := {App, Conn}}, DbName, Doc, Options) ->
    {PreparedDoc, PublishDoc} = prepare_doc_for_save(DbName, Doc),
    try App:save_doc(Conn, DbName, PreparedDoc, Options) of
        {'ok', JObj}=Ok -> kzs_publish:maybe_publish_doc(DbName, PublishDoc, JObj),
                           Ok;
        Else -> Else
    catch
        Ex:Er -> lager:error("exception ~p : ~p", [Ex, Er]),
                 'failed'
    end.



-spec save_docs(map(), ne_binary(), wh_json:objects(), wh_proplist()) ->
                       {'ok', wh_json:objects()} |
                       data_error().
save_docs(#{server := {App, Conn}}, DbName, Docs, Options) ->
    {PreparedDocs, Publish} = lists:unzip([prepare_doc_for_save(DbName, D) || D <- Docs]),
    try App:save_docs(Conn, DbName, PreparedDocs, Options) of
        {'ok', JObjs}=Ok -> kzs_publish:maybe_publish_docs(DbName, Publish, JObjs),
                           Ok;
        Else -> Else
    catch
        _Ex:Er -> {'error', {_Ex, Er}}
    end.

-spec lookup_doc_rev(map(), ne_binary(), ne_binary()) ->
                            {'ok', ne_binary()} |
                            data_error().
lookup_doc_rev(#{server := {App, Conn}}, DbName, DocId) ->
    App:lookup_doc_rev(Conn, DbName, DocId).

-spec ensure_saved(map(), ne_binary(), wh_json:object(), wh_proplist()) ->
                          {'ok', wh_json:object()} |
                          data_error().
ensure_saved(#{server := {App, Conn}}, DbName, Doc, Options) ->
    {PreparedDoc, PublishDoc} = prepare_doc_for_save(DbName, Doc),
    try App:ensure_saved(Conn, DbName, PreparedDoc, Options) of
        {'ok', JObj}=Ok -> kzs_publish:maybe_publish_doc(DbName, PublishDoc, JObj),
                           Ok;
        Else -> Else
    catch
        Ex:Er -> lager:error("exception ~p : ~p", [Ex, Er]),
                 'failed'
    end.

-spec del_doc(map(), ne_binary(), wh_json:object() | ne_binary(), wh_proplist()) ->
                     {'ok', wh_json:objects()} |
                     data_error().
del_doc(Server, DbName, DocId, Options)
  when is_binary(DocId) ->
    case lookup_doc_rev(Server, DbName, DocId) of
        {'error', _}=Err -> Err;
        {'ok', Rev} ->
            JObj = wh_json:from_list([{<<"_id">>, DocId}
                                      ,{<<"_rev">>, Rev}
                                     ]),
            del_doc(Server, DbName, JObj, Options)
    end;
del_doc(#{server := {App, Conn}}, DbName, Doc, Options) ->
    {PreparedDoc, PublishDoc} = prepare_doc_for_save(DbName, Doc),
    try App:del_doc(Conn, DbName, PreparedDoc, Options) of
        {'ok', JObj}=Ok -> kzs_publish:maybe_publish_doc(DbName, PublishDoc, JObj),
                           kzs_cache:flush_cache_doc(DbName, JObj),
                           Ok;
        Else -> Else
    catch
        Ex:Er -> lager:error("exception ~p : ~p", [Ex, Er]),
                 'failed'
    end.

-spec del_docs(map(), ne_binary(), wh_json:objects() | ne_binaries(), wh_proplist()) ->
                      {'ok', wh_json:objects()} |
                      data_error().
del_docs(#{server := {App, Conn}}=Server, DbName, Docs, Options) ->
    DelDocs = [prepare_doc_for_del(Server,DbName, D) || D <- Docs],
    {PreparedDocs, Publish} = lists:unzip([prepare_doc_for_save(DbName, D) || D <- DelDocs]),
    try App:del_docs(Conn, DbName, PreparedDocs, Options) of
        {'ok', JObjs}=Ok -> kzs_publish:maybe_publish_docs(DbName, Publish, JObjs),
                            kzs_cache:flush_cache_docs(DbName, JObjs),
                           Ok;
        Else -> Else
    catch
        _Ex:Er -> {'error', {_Ex, Er}}
    end.

-spec copy_doc(map(), copy_doc(), wh_proplist()) ->
                      {'ok', wh_json:object()} |
                      data_error().
copy_doc(Server, #copy_doc{source_dbname = SourceDb
                                      ,dest_dbname='undefined'
                                     }=CopySpec, Options) ->
    copy_doc(Server, CopySpec#copy_doc{dest_dbname=SourceDb
                                        ,dest_doc_id=wh_util:rand_hex_binary(16)
                                       }, Options);
copy_doc(Server, #copy_doc{dest_doc_id='undefined'}=CopySpec, Options) ->
    copy_doc(Server, CopySpec#copy_doc{dest_doc_id=wh_util:rand_hex_binary(16)}, Options);
copy_doc(#{server := {App, Conn}}, CopySpec, Options) ->
    App:copy_doc(Conn, CopySpec, Options).

-spec move_doc(map(), copy_doc(), wh_proplist()) ->
                      {'ok', wh_json:object()} |
                      data_error().
move_doc(#{server := {App, Conn}}, CopySpec, Options) ->
    App:move_doc(Conn, CopySpec, Options).

-spec prepare_doc_for_del(map(), ne_binary(), wh_json:object() | ne_binary()) ->
                                 wh_json:object().
prepare_doc_for_del(Server, Db, <<_/binary>> = DocId) ->
    prepare_doc_for_del(Server, Db, wh_json:from_list([{<<"_id">>, DocId}]));
prepare_doc_for_del(Server, DbName, Doc) ->
    Id = wh_doc:id(Doc),
    DocRev = case wh_doc:revision(Doc) of
                 'undefined' ->
                     {'ok', Rev} = lookup_doc_rev(Server, DbName, Id),
                     Rev;
                 Rev -> Rev
             end,
    wh_json:from_list(
      props:filter_undefined(
        [{<<"_id">>, Id}
         ,{<<"_rev">>, DocRev}
         ,{<<"_deleted">>, 'true'}
         | kzs_publish:publish_fields(Doc)
        ])).

-spec prepare_doc_for_save(ne_binary(), wh_json:object()) -> {wh_json:object(), wh_json:object()}.
-spec prepare_doc_for_save(ne_binary(), wh_json:object(), boolean()) -> {wh_json:object(), wh_json:object()}.
prepare_doc_for_save(Db, JObj) ->
    prepare_doc_for_save(Db, JObj, wh_util:is_empty(wh_doc:id(JObj))).

prepare_doc_for_save(_Db, JObj, 'true') ->
    prepare_publish(maybe_set_docid(JObj));
prepare_doc_for_save(Db, JObj, 'false') ->
    kzs_cache:flush_cache_doc(Db, JObj),
    prepare_publish(JObj).

-spec prepare_publish(wh_json:object()) -> {wh_json:object(), wh_json:object()}.
prepare_publish(JObj) ->
    {maybe_tombstone(JObj), wh_json:from_list(kzs_publish:publish_fields(JObj))}.

-spec maybe_tombstone(wh_json:object()) -> wh_json:object().
-spec maybe_tombstone(wh_json:object(), boolean()) -> wh_json:object().
maybe_tombstone(JObj) ->
    maybe_tombstone(JObj, wh_json:is_true(<<"_deleted">>, JObj, 'false')).

maybe_tombstone(JObj, 'true') ->
    wh_json:from_list(
      props:filter_undefined(
        [{<<"_id">>, wh_doc:id(JObj)}
        ,{<<"_rev">>, wh_doc:revision(JObj)}
        ,{<<"_deleted">>, 'true'}
        ]
       )
     );
maybe_tombstone(JObj, 'false') -> JObj.

-spec maybe_set_docid(wh_json:object()) -> wh_json:object().
maybe_set_docid(Doc) ->
    case wh_doc:id(Doc) of
        'undefined' -> wh_doc:set_id(Doc, kz_datamgr:get_uuid());
        _ -> Doc
    end.

