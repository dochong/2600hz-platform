%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(media_file).

-behaviour(gen_server).

%% API
-export([start_link/4
         ,single/1
         ,continuous/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("media.hrl").

-define(TIMEOUT_LIFETIME, 600000).

-record(state, {
          db :: ne_binary()
         ,doc :: ne_binary()
         ,attach :: ne_binary()
         ,meta :: wh_json:json_object()
         ,contents = <<>> :: binary()
         ,stream_ref :: reference()
         ,status :: 'streaming' | 'ready'
         ,reqs :: [{pid(), reference()},...] | []
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link/4 :: (ne_binary(), ne_binary(), ne_binary(), wh_json:json_object()) -> {'ok', pid()}.
start_link(Id, Doc, Attach, Meta) ->
    gen_server:start_link(?MODULE, [Id, Doc, Attach, Meta], []).

single(Srv) ->
    gen_server:call(Srv, single).

continuous(Srv) ->
    gen_server:call(Srv, continuous).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([<<"system_media">>|Rest]) ->
    init(<<"system_media">>, Rest);
init([Id|Rest]) ->
    init(wh_util:format_account_id(Id, encoded), Rest).

init(Db, [Doc, Attach, Meta]) ->
    put(callid, ?LOG_SYSTEM_ID),

    lager:debug("streaming ~s/~s/~s", [Db, Doc, Attach]),
    {ok, Ref} = couch_mgr:stream_attachment(Db, Doc, Attach),

    {ok
     ,#state{
       db=Db
       ,doc=Doc
       ,attach=Attach
       ,meta=Meta
       ,stream_ref=Ref
       ,status=streaming
       ,contents = <<>>
       ,reqs = [] %% buffer requests until file has completed streaming
      }
     ,?TIMEOUT_LIFETIME}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(single, _From, #state{meta=Meta, contents=Contents, status=ready}=State) ->
    %% doesn't currently check whether we're still streaming in from the DB
    lager:debug("returning media contents"),
    {reply, {Meta, Contents}, State, ?TIMEOUT_LIFETIME};
handle_call(single, From, #state{reqs=Reqs, status=streaming}=State) ->
    lager:debug("file not ready for ~p, queueing", [From]),
    {noreply, State#state{reqs=[From | Reqs]}};
handle_call(continuous, _From, #state{}=State) ->
    {reply, ok, State, ?TIMEOUT_LIFETIME}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    lager:debug("timeout expired, going down"),
    {stop, normal, State};
handle_info({Ref, done}, #state{stream_ref=Ref, reqs=Reqs, contents=Contents, meta=Meta}=State) ->
    Res = {Meta, Contents},
    _ = [gen_server:reply(From, Res) || From <- Reqs],

    lager:debug("finished receiving file contents"),
    {noreply, State#state{status=ready}, hibernate};
handle_info({Ref, {ok, Bin}}, #state{stream_ref=Ref, contents=Contents}=State) ->
    lager:debug("recv ~b bytes", [byte_size(Bin)]),
    {noreply, State#state{contents = <<Contents/binary, Bin/binary>>}};
handle_info({Ref, {error, E}}, #state{stream_ref=Ref}=State) ->
    lager:debug("recv stream error: ~p", [E]),
    {stop, normal, State};
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {noreply, State, hibernate}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
