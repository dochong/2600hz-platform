%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2012, VoIP INC
%%% @doc
%%% Handles authentication requests, responses, queue bindings
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(wapi_authn).

-compile({no_auto_import, [error/1]}).

-export([req/1, req_v/1
         ,resp/1, resp_v/1
         ,error/1, error_v/1
         ,bind_q/2, unbind_q/1, unbind_q/2
         ,publish_req/1, publish_req/2
         ,publish_resp/2, publish_resp/3
         ,publish_error/2, publish_error/3
         ,get_auth_user/1, get_auth_realm/1
         ,req_event_type/0
        ]).

-include("../wh_api.hrl").

-define(KEY_AUTHN_REQ, <<"authn.req">>). %% corresponds to the authn_req/1 api call

-define(EVENT_CATEGORY, <<"directory">>).
-define(AUTHN_REQ_EVENT_NAME, <<"authn_req">>).

-define(AUTHN_REQ_HEADERS, [<<"Msg-ID">>, <<"To">>, <<"From">>, <<"Orig-IP">>
                                , <<"Auth-User">>, <<"Auth-Realm">>]).
-define(OPTIONAL_AUTHN_REQ_HEADERS, [<<"Method">>, <<"Switch-Hostname">>]).
-define(AUTHN_REQ_VALUES, [{<<"Event-Category">>, ?EVENT_CATEGORY}
                           ,{<<"Event-Name">>, ?AUTHN_REQ_EVENT_NAME}
                          ]).
-define(AUTHN_REQ_TYPES, [{<<"Msg-ID">>, fun is_binary/1}
                          ,{<<"To">>, fun is_binary/1}
                          ,{<<"From">>, fun is_binary/1}
                          ,{<<"Orig-IP">>, fun is_binary/1}
                          ,{<<"Auth-User">>, fun is_binary/1}
                          ,{<<"Auth-Realm">>, fun is_binary/1}
                         ]).

%% Authentication Responses
-define(AUTHN_RESP_HEADERS, [<<"Msg-ID">>, <<"Auth-Method">>, <<"Auth-Password">>]).
-define(OPTIONAL_AUTHN_RESP_HEADERS, [<<"Tenant-ID">>, <<"Access-Group">>, <<"Custom-Channel-Vars">>]).
-define(AUTHN_RESP_VALUES, [{<<"Event-Category">>, <<"directory">>}
                           ,{<<"Event-Name">>, <<"authn_resp">>}
                           ,{<<"Auth-Method">>, [<<"password">>, <<"ip">>, <<"a1-hash">>, <<"error">>]}
                         ]).
-define(AUTHN_RESP_TYPES, [{<<"Msg-ID">>, fun is_binary/1}
                          ,{<<"Auth-Password">>, fun is_binary/1}
                          ,{<<"Custom-Channel-Vars">>, ?IS_JSON_OBJECT}
                          ,{<<"Access-Group">>, fun is_binary/1}
                          ,{<<"Tenant-ID">>, fun is_binary/1}
                         ]).

%% Authentication Failure Response
-define(AUTHN_ERR_HEADERS, [<<"Msg-ID">>]).
-define(OPTIONAL_AUTHN_ERR_HEADERS, []).
-define(AUTHN_ERR_VALUES, [{<<"Event-Category">>, <<"directory">>}
                            ,{<<"Event-Name">>, <<"authn_err">>}
                         ]).
-define(AUTHN_ERR_TYPES, [{<<"Msg-ID">>, fun is_binary/1}
                         ]).

%%--------------------------------------------------------------------
%% @doc Authentication Request - see wiki
%% Takes proplist, creates JSON iolist or error
%% @end
%%--------------------------------------------------------------------
-spec req/1 :: (api_terms()) -> {'ok', iolist()} | {'error', string()}.
req(Prop) when is_list(Prop) ->
        case req_v(Prop) of
            true -> wh_api:build_message(Prop, ?AUTHN_REQ_HEADERS, ?OPTIONAL_AUTHN_REQ_HEADERS);
            false -> {error, "Proplist failed validation for authn_req"}
    end;
req(JObj) ->
    req(wh_json:to_proplist(JObj)).

-spec req_v/1 :: (api_terms()) -> boolean().
req_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AUTHN_REQ_HEADERS, ?AUTHN_REQ_VALUES, ?AUTHN_REQ_TYPES);
req_v(JObj) ->
    req_v(wh_json:to_proplist(JObj)).

-spec req_event_type/0 :: () -> {ne_binary(), ne_binary()}.
req_event_type() ->
    {?EVENT_CATEGORY, ?AUTHN_REQ_EVENT_NAME}.

%%--------------------------------------------------------------------
%% @doc Authentication Response - see wiki
%% Takes proplist, creates JSON iolist or error
%% @end
%%--------------------------------------------------------------------
-spec resp/1 :: (api_terms()) -> {'ok', iolist()} | {'error', string()}.
resp(Prop) when is_list(Prop) ->
    case resp_v(Prop) of
        true -> wh_api:build_message(Prop, ?AUTHN_RESP_HEADERS, ?OPTIONAL_AUTHN_RESP_HEADERS);
        false -> {error, "Proplist failed validation for authn_resp"}
    end;
resp(JObj) ->
    resp(wh_json:to_proplist(JObj)).

-spec resp_v/1 :: (api_terms()) -> boolean().
resp_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AUTHN_RESP_HEADERS, ?AUTHN_RESP_VALUES, ?AUTHN_RESP_TYPES);
resp_v(JObj) ->
    resp_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Authentication Error - see wiki
%% Takes proplist, creates JSON iolist or error
%% @end
%%--------------------------------------------------------------------
-spec error/1 :: (api_terms()) -> {'ok', iolist()} | {'error', string()}.
error(Prop) when is_list(Prop) ->
    case error_v(Prop) of
        true -> wh_api:build_message(Prop, ?AUTHN_ERR_HEADERS, ?OPTIONAL_AUTHN_ERR_HEADERS);
        false -> {error, "Proplist failed validation for authn_error"}
    end;
error(JObj) ->
    error(wh_json:to_proplist(JObj)).

-spec error_v/1 :: (api_terms()) -> boolean().
error_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AUTHN_ERR_HEADERS, ?AUTHN_ERR_VALUES, ?AUTHN_ERR_TYPES);
error_v(JObj) ->
    error_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Setup and tear down bindings for authn gen_listeners
%% @end
%%--------------------------------------------------------------------
-spec bind_q/2 :: (ne_binary(), proplist()) -> 'ok'.
bind_q(Q, Props) ->
    Realm = props:get_value(realm, Props, <<"*">>),

    amqp_util:callmgr_exchange(),
    amqp_util:bind_q_to_callmgr(Q, get_authn_req_routing(Realm)).

-spec unbind_q/1 :: (ne_binary()) -> 'ok'.
-spec unbind_q/2:: (ne_binary(), proplist()) -> 'ok'.
unbind_q(Q) ->
    unbind_q(Q, []).
unbind_q(Q, Props) ->
    Realm = props:get_value(realm, Props, <<"*">>),
    amqp_util:unbind_q_from_callmgr(Q, get_authn_req_routing(Realm)).

%%--------------------------------------------------------------------
%% @doc Publish the JSON iolist() to the proper Exchange
%% @end
%%--------------------------------------------------------------------
-spec publish_req/1 :: (api_terms()) -> 'ok'.
-spec publish_req/2 :: (api_terms(), binary()) -> 'ok'.
publish_req(JObj) ->
    publish_req(JObj, ?DEFAULT_CONTENT_TYPE).
publish_req(Req, ContentType) ->
    {ok, Payload} = wh_api:prepare_api_payload(Req, ?AUTHN_REQ_VALUES, fun ?MODULE:req/1),
    amqp_util:callmgr_publish(Payload, ContentType, get_authn_req_routing(Req)).

-spec publish_resp/2 :: (ne_binary(), api_terms()) -> 'ok'.
-spec publish_resp/3 :: (ne_binary(), api_terms(), binary()) -> 'ok'.
publish_resp(Queue, JObj) ->
    publish_resp(Queue, JObj, ?DEFAULT_CONTENT_TYPE).
publish_resp(Queue, Resp, ContentType) ->
    {ok, Payload} = wh_api:prepare_api_payload(Resp, ?AUTHN_RESP_VALUES, fun resp/1),
    amqp_util:targeted_publish(Queue, Payload, ContentType).

-spec publish_error/2 :: (ne_binary(), api_terms()) -> 'ok'.
-spec publish_error/3 :: (ne_binary(), api_terms(), binary()) -> 'ok'.
publish_error(Queue, JObj) ->
    publish_error(Queue, JObj, ?DEFAULT_CONTENT_TYPE).
publish_error(Queue, Resp, ContentType) ->
    {ok, Payload} = wh_api:prepare_api_payload(Resp, ?AUTHN_ERR_VALUES, fun ?MODULE:error/1),
    amqp_util:targeted_publish(Queue, Payload, ContentType).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% creating the routing key for either binding queues or publishing messages
%% @end
%%-----------------------------------------------------------------------------
-spec get_authn_req_routing/1 :: (ne_binary() | api_terms()) -> ne_binary().
get_authn_req_routing(Realm) when is_binary(Realm) ->
    list_to_binary([?KEY_AUTHN_REQ, ".", amqp_util:encode(Realm)]);
get_authn_req_routing(Req) ->
    get_authn_req_routing(get_auth_realm(Req)).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% extract the auth user from the API request
%% @end
%%-----------------------------------------------------------------------------
-spec get_auth_user/1  :: (wh_json:json_object()) -> ne_binary() | 'undefined'.
get_auth_user(ApiJObj) ->
    wh_json:get_value(<<"Auth-User">>, ApiJObj).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% extract the auth realm from the API request, using the requests to domain
%% when provided with an IP
%% @end
%%-----------------------------------------------------------------------------
-spec get_auth_realm/1  :: (wh_json:json_object() | proplist()) -> ne_binary().
get_auth_realm(ApiProp) when is_list(ApiProp) ->
    AuthRealm = props:get_value(<<"Auth-Realm">>, ApiProp, <<"missing.realm">>),
    case wh_util:is_ipv4(AuthRealm) orelse wh_util:is_ipv6(AuthRealm) of
        true ->
            [_ToUser, ToDomain] = binary:split(props:get_value(<<"To">>, ApiProp), <<"@">>),
            ToDomain;
        false ->
            AuthRealm
    end;
get_auth_realm(ApiJObj) ->
    get_auth_realm(wh_json:to_proplist(ApiJObj)).
