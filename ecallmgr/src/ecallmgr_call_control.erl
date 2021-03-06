%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2012, VoIP INC
%%% @doc
%%% Created when a call hits a fetch_handler in ecallmgr_route.
%%% A Control Queue is created by the lookup_route function in the
%%% fetch_handler. On initialization, besides adding itself as the
%%% consumer for the AMQP messages, Call Control creates an empty queue
%%% object (not to be confused with AMQP queues), sets the current
%%% application running on the switch to the empty binary, and records
%%% the timestamp of when the initialization finishes. The process then
%%% enters its loop to wait.
%%%
%%% When receiving an AMQP message, after decoding the JSON into a proplist,
%%% we check if the application is "queue" or not; if it is "queue", we
%%% extract the default headers out, iterate through the Commands portion,
%%% and append the default headers to the application-specific portions, and
%%% insert these commands into the CmdQ. We then check whether the old CmdQ is
%%% empty AND the new CmdQ is not, and that the current App is the empty
%%% binary. If so, we dequeue the next command, execute it, and loop; otherwise
%%% we loop with the CmdQ.
%%% If just a single application is sent in the message, we check the CmdQ's
%%% size and the current App's status; if both are empty, we fire the command
%%% immediately; otherwise we add the command to the CmdQ and loop.
%%%
%%% When receiving an {execute_complete, CALLID, EvtName} tuple from
%%% the corresponding ecallmgr_call_events process tracking the call,
%%% we convert the CurrApp name from Whistle parlance to FS, matching
%%% it against what application name we got from FS via the events
%%% process. If CurrApp is empty, we just loop since the completed
%%% execution probably wasn't related to our stuff (perhaps FS internal);
%%% if the converted Whistle name matches the passed FS name, we know
%%% the CurrApp cmd has finished and can execute the next command in the
%%% queue. If there are no commands in the queue, set CurrApp to 'undefined' and
%%% loop; otherwise take the next command, execute it, and look with it as
%%% the CurrApp. If EvtName and the converted Whistle name don't match,
%%% something else executed that might have been related to the main
%%% application's execute (think set commands, like playback terminators);
%%% we can note the event happened, and continue looping as we were.
%%%
%%% @end
%%%
%%% @contributors
%%%   James Aimonetti <james@2600hz.org>
%%%   Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(ecallmgr_call_control).

-behaviour(gen_listener).

%% API
-export([start_link/3, stop/1]).
-export([handle_call_command/2, handle_conference_command/2, handle_call_events/2]).
-export([queue_name/1, callid/1, node/1, hostname/1]).
-export([event_execute_complete/3]).
-export([add_leg/1, rm_leg/1]).
-export([other_legs/1]).
-export([transferer/2, transferee/2]).

%% gen_listener callbacks
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).
-define(KEEP_ALIVE, 5000). %% after hangup, keep alive for 5 seconds

-type insert_at_options() :: 'now' | 'head' | 'tail' | 'flush'.

-record(state, {
          node = 'undefined' :: atom()
         ,callid :: ne_binary()
         ,self = 'undefined' :: 'undefined' | pid()
         ,controller_q = 'undefined' :: 'undefined' | ne_binary()
         ,evtpid = 'undefined' :: 'undefined' | pid()
         ,command_q = queue:new() :: queue()
         ,current_app = 'undefined' :: ne_binary() | 'undefined'
         ,current_cmd = 'undefined' :: wh_json:json_object() | 'undefined'
         ,start_time = erlang:now() :: wh_now()
         ,is_call_up = 'true' :: boolean()
         ,is_node_up = 'true' :: boolean()
         ,keep_alive_ref = 'undefined' :: 'undefined' | reference()
         ,other_legs = [] :: [] | [ne_binary(),...]
         ,last_removed_leg = 'undefined' :: 'undefined' | ne_binary()
         ,sanity_check_tref = 'undefined' :: 'undefined' | reference()
         ,msg_id = 'undefined' :: 'undefined' | ne_binary()
         }).

-define(RESPONDERS, [{{?MODULE, handle_call_command}, [{<<"call">>, <<"command">>}]}
                     ,{{?MODULE, handle_conference_command}, [{<<"conference">>, <<"command">>}]}
                     ,{{?MODULE, handle_call_events}, [{<<"call_event">>, <<"*">>}]}]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

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
start_link(Node, CallId, WhAppQ) ->
    %% We need to become completely decoupled from ecallmgr_call_events
    %% because the call_events process might have been spun up with A->B
    %% then transfered to A->D, but the route landed in a different 
    %% ecallmgr.  Since our call_events will get a bad session if we
    %% try to handlecall more than once on a UUID we had to leave the
    %% call_events running on another ecallmgr... fun fun
    Bindings = [{call, [{callid, CallId}
                        ,{restrict_to, [events]}
                       ]}
                ,{dialplan, []}
                ,{self, []}],
    gen_listener:start_link(?MODULE, [{responders, ?RESPONDERS}
                                      ,{bindings, Bindings}
                                      ,{queue_name, ?QUEUE_NAME}
                                      ,{queue_options, ?QUEUE_OPTIONS}
                                      ,{consume_options, ?CONSUME_OPTIONS}
                                     ], [Node, CallId, WhAppQ]).

stop(Srv) ->
    gen_listener:stop(Srv).

-spec callid/1 :: (pid()) -> ne_binary().
callid(Srv) ->
    gen_listener:call(Srv, {callid}, 1000).

-spec node/1 :: (pid()) -> ne_binary().
node(Srv) ->
    gen_listener:call(Srv, {node}, 1000).

-spec hostname/1 :: (pid()) -> binary().
hostname(Srv) ->
    Node = ?MODULE:node(Srv),
    [_, Hostname] = binary:split(wh_util:to_binary(Node), <<"@">>),
    Hostname.

-spec queue_name/1 :: (pid()) -> ne_binary().
queue_name(Srv) ->
    gen_listener:queue_name(Srv).

-spec other_legs/1 :: (pid()) -> [] | [ne_binary(),...].
other_legs(Srv) ->
    gen_listener:call(Srv, {other_legs}, 1000).

-spec event_execute_complete/3 :: (pid(), ne_binary(), ne_binary()) -> 'ok'.
event_execute_complete(Srv, CallId, App) ->
    gen_listener:cast(Srv, {event_execute_complete, CallId, App, wh_json:new()}).

-spec add_leg/1 :: (wh_proplist()) -> 'ok'.
add_leg(Props) ->
    %% if there is a Other-Leg-Unique-ID then that MAY refer to a leg managed
    %% by call_control, if so add the leg to it
    case props:get_value(<<"Other-Leg-Unique-ID">>, Props) of
        undefined -> ok;
        CallId ->
            _ = [gen_listener:cast(Srv, {add_leg, wh_json:from_list(Props)}) 
                 || Srv <- gproc:lookup_pids({p, l, {call_control, CallId}})
                ],
            ok
    end.

-spec rm_leg/1 :: (wh_proplist()) -> 'ok'.
rm_leg(Props) ->
    %% if there is a Other-Leg-Unique-ID then that MAY refer to a leg managed
    %% by call_control, if so remove the leg from it
    case props:get_value(<<"Other-Leg-Unique-ID">>, Props) of
        undefined -> ok;
        CallId ->
            _ = [gen_listener:cast(Srv, {rm_leg, wh_json:from_list(Props)}) 
                 || Srv <- gproc:lookup_pids({p, l, {call_control, CallId}})
                ],
            ok
    end.

-spec transferer/2 :: (pid(), proplist()) -> 'ok'.
transferer(Srv, Props) ->
    gen_listener:cast(Srv, {transferer, wh_json:from_list(Props)}).

-spec transferee/2 :: (pid(), proplist()) -> 'ok'.
transferee(Srv, Props) ->
    gen_listener:cast(Srv, {transferee, wh_json:from_list(Props)}).

-spec handle_call_command/2 :: (wh_json:json_object(), proplist()) -> 'ok'.
handle_call_command(JObj, Props) ->
    Srv = props:get_value(server, Props),
    gen_listener:cast(Srv, {dialplan, JObj}).

-spec handle_conference_command/2 :: (wh_json:json_object(), proplist()) -> 'ok'.
handle_conference_command(JObj, Props) ->
    Srv = props:get_value(server, Props),
    gen_listener:cast(Srv, {dialplan, JObj}).

-spec handle_call_events/2 :: (wh_json:json_object(), proplist()) -> 'ok'.
handle_call_events(JObj, Props) ->
    Srv = props:get_value(server, Props),
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    put(callid, CallId),
    case wh_json:get_value(<<"Event-Name">>, JObj) of
        <<"CHANNEL_EXECUTE_COMPLETE">> ->
            Application = wh_json:get_value(<<"Raw-Application-Name">>, JObj, wh_json:get_value(<<"Application-Name">>, JObj)),
            lager:debug("control queue ~p channel execute completion for '~s'", [Srv, Application]),
            gen_listener:cast(Srv, {event_execute_complete, CallId, Application, JObj});
        <<"RECORD_STOP">> ->
            Application = wh_json:get_value(<<"Raw-Application-Name">>, JObj, wh_json:get_value(<<"Application-Name">>, JObj)),
            lager:debug("control queue ~p channel execute completion for '~s'", [Srv, Application]),
            gen_listener:cast(Srv, {event_execute_complete, CallId, Application, JObj});
        <<"CHANNEL_DESTROY">> ->
            gen_listener:cast(Srv, {channel_destroyed, JObj});
        <<"CHANNEL_UNBRIDGE">> ->
            gen_listener:cast(Srv, {rm_leg, JObj});
        <<"CHANNEL_BRIDGE">> ->
            gen_listener:cast(Srv, {add_leg, JObj});
        <<"CHANNEL_EXECUTE">> ->
            case wh_json:get_value(<<"Raw-Application-Name">>, JObj) of
                <<"redirect">> -> gen_listener:cast(Srv, {channel_redirected, JObj});
                _Else -> ok
            end;
        <<"controller_queue">> ->
            ControllerQ = wh_json:get_value(<<"Controller-Queue">>, JObj),
            gen_listener:cast(Srv, {controller_queue, ControllerQ});
        <<"usurp_control">> ->
            Q = props:get_value(queue, Props),
            case wh_json:get_value(<<"Control-Queue">>, JObj) of
                Q -> ok;
                _Else -> gen_listener:cast(Srv, {usurp_control, JObj})
            end;
        _ ->
            ok
    end.

%%%===================================================================
%%% gen_listener callbacks
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
init([Node, CallId, WhAppQ]) ->
    put(callid, CallId),
    lager:debug("starting call control listener"),
    erlang:monitor_node(Node, true),
    gproc:reg({p, l, call_control}),
    gproc:reg({p, l, {call_control, CallId}}),
    TRef = erlang:send_after(?SANITY_CHECK_PERIOD, self(), {sanity_check}),
    {ok, #state{node=Node, callid=CallId, command_q=queue:new(), self=self()
                ,controller_q=WhAppQ, start_time=erlang:now(), sanity_check_tref=TRef}
    }.

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
handle_call({node}, _From, #state{node=Node}=State) ->
    {reply, Node, State};
handle_call({callid}, _From, #state{callid=CallId}=State) ->
    {reply, CallId, State};
handle_call({other_legs}, _From, #state{other_legs=Legs}=State) ->
    {reply, Legs, State};
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

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
handle_cast({controller_queue, ControllerQ}, State) ->
    lager:debug("updating controller queue to ~s", [ControllerQ]),
    {noreply, State#state{controller_q=ControllerQ}};
handle_cast({usurp_control, _}, State) ->
    lager:debug("the call has been usurped by an external process"),
    {stop, normal, State};
handle_cast({channel_redirected, _}, #state{callid=CallId, controller_q=ControllerQ}=State) ->
    lager:debug("call control has been redirected, shutting down immediately"),
    spawn(fun() -> publish_control_transfer(ControllerQ, CallId) end),
    {stop, normal, State};
handle_cast({transferer, _}, #state{last_removed_leg=undefined, other_legs=[]}=State) ->    
    %% if the callee preforms a blind transfer then sometimes the new control
    %% listener is built so quickly that it receives the transferer event ment
    %% to tear down the old one.  However, a new control listener will not have
    %% nor removed any legs. This is just pain hackish but its working...
    lager:debug("ignoring transferer as it is a residual event for the other control listener"),
    {noreply, State};
handle_cast({transferer, _}, #state{callid=CallId, controller_q=ControllerQ}=State) ->
    lager:debug("call control has been transfered"),
    spawn(fun() -> publish_control_transfer(ControllerQ, CallId) end),
    {stop, normal, State};
handle_cast({transferee, JObj}, #state{other_legs=Legs, node=Node, callid=PrevCallId, self=Self}=State) ->
    lager:debug("this call control process is a transferee, updating call id..."),
    NewCallId = case {wh_json:get_value(<<"Bridge-With">>, JObj), wh_json:get_value(<<"Transferee-UUID">>, JObj)} of
                    {undefined, CallId} -> CallId;
                    {CallId, _} -> CallId
                end,
    case NewCallId of
        undefined ->
            lager:debug("could not determin new call id"),
            {noreply, State};
        PrevCallId ->
            lager:debug("new callid is the same as the old callid"),
            {noreply, State};
        _Else ->            
            spawn(fun() -> publish_callid_update(PrevCallId, NewCallId, queue_name(Self)) end),
            lager:debug("updating callid from ~s to ~s", [PrevCallId, NewCallId]),
            put(callid, NewCallId),
            lager:debug("removing call event bindings for ~s", [PrevCallId]),
            gen_listener:rm_binding(self(), call, [{callid, PrevCallId}]),
            lager:debug("binding to new call events"),
            gen_listener:add_binding(self(), call, [{callid, NewCallId}]),
            lager:debug("ensuring event listener exists"),
            _ = ecallmgr_call_sup:start_event_process(Node, NewCallId),
            lager:debug("...call id updated, continuing post-transfer"),
            {noreply, State#state{callid=NewCallId, other_legs=lists:delete(NewCallId, Legs)}}
    end;
handle_cast({add_leg, JObj}, #state{other_legs=Legs, callid=CallId}=State) ->
    LegId = case wh_json:get_value(<<"Event-Name">>, JObj) of
                <<"CHANNEL_BRIDGE">> ->
                    wh_json:get_value(<<"Other-Leg-Unique-ID">>, JObj);
                _ ->
                    wh_json:get_value(<<"Caller-Unique-ID">>, JObj)
                end,
    case is_atom(LegId) orelse lists:member(LegId, Legs) of
        true -> {noreply, State};
        false ->
            lager:debug("added leg ~s to call", [LegId]),
            _ = spawn(fun() ->
                              _ = put(callid, CallId),
                              publish_leg_addition(JObj)
                      end),
            {noreply, State#state{other_legs=[LegId|Legs]}}
    end;
handle_cast({rm_leg, JObj}, #state{other_legs=Legs, callid=CallId}=State) ->
    LegId = case wh_json:get_value(<<"Event-Name">>, JObj) of
                <<"CHANNEL_UNBRIDGE">> ->
                    wh_json:get_value(<<"Other-Leg-Unique-ID">>, JObj);
                _ ->
                    wh_json:get_value(<<"Caller-Unique-ID">>, JObj)
            end,
    case lists:member(LegId, Legs) of
        false -> 
            {noreply, State};
        true ->
            lager:debug("removed leg ~s from call", [LegId]),
            _ = spawn(fun() ->
                              put(callid, CallId),
                              publish_leg_removal(JObj)
                      end),
            {noreply, State#state{other_legs=lists:delete(LegId, Legs), last_removed_leg=LegId}}
    end;
handle_cast({channel_destroyed, JObj},  #state{is_call_up=true, sanity_check_tref=SCTRef, current_app=CurrentApp
                                            ,current_cmd=CurrentCmd, callid=CallId, node=Node}=State) ->
    case wh_json:get_value(<<"Call-ID">>, JObj) =:= CallId of
        false -> {noreply, State};
        true ->
            lager:debug("our channel has been destroyed, executing any post-hangup commands"),
            %% if our sanity check timer is running stop it, it will always return false
            %% now that the channel is gone
            catch (erlang:cancel_timer(SCTRef)),
            %% since this is not attached to a call the node status doesnt matter anymore
            erlang:monitor_node(Node, false),
            %% if the current application can not be run without a channel and we have received the
            %% channel_destory (the last event we will ever receive from freeswitch for this call)
            %% then create an error and force advance. This will happen with dialplan actions that
            %% have not been executed on freeswitch but were already queued (for example in xferext). 
            %% Commonly events like masquerade, noop, ect
            _ = case CurrentApp =:= undefined orelse is_post_hangup_command(CurrentApp) of
                    true -> ok;
                    false -> 
                        send_error_resp(CallId, CurrentCmd),
                        self() ! {force_queue_advance, CallId}
                end,
            {noreply, State#state{keep_alive_ref=get_keep_alive_ref(State#state{is_call_up=false})
                                  ,is_call_up=false, is_node_up=true}, hibernate}
    end;
handle_cast({channel_destroyed, _},  #state{is_call_up=false}=State) ->
    {noreply, State};
handle_cast({dialplan, JObj}, #state{callid=CallId, is_node_up=INU, is_call_up=CallUp
                                     ,command_q=CmdQ, current_app=CurrApp}=State) ->
    NewCmdQ = try
                  insert_command(State, wh_util:to_atom(wh_json:get_value(<<"Insert-At">>, JObj, 'tail')), JObj)
              catch _T:_R ->
                      lager:debug("failed to insert command into control queue: ~p:~p", [_T, _R]),
                      CmdQ
              end,
    case INU andalso (not queue:is_empty(NewCmdQ)) andalso CurrApp =:= undefined of
        true ->
            {{value, Cmd}, NewCmdQ1} = queue:out(NewCmdQ),
            AppName = wh_json:get_value(<<"Application-Name">>, Cmd),
            _ = case CallUp orelse is_post_hangup_command(AppName) of
                    true -> execute_control_request(Cmd, State);
                    false ->
                        lager:debug("command '~s' is not valid after hangup, ignoring", [AppName]),
                        send_error_resp(CallId, Cmd),
                        self() ! {force_queue_advance, CallId}
                end,
            MsgId = wh_json:get_value(<<"Msg-ID">>, Cmd),
            {noreply, State#state{command_q=NewCmdQ1, current_app=AppName, current_cmd=Cmd
                                  ,keep_alive_ref=get_keep_alive_ref(State), msg_id=MsgId}, hibernate};
        false ->
            {noreply, State#state{command_q=NewCmdQ, keep_alive_ref=get_keep_alive_ref(State)}, hibernate}
    end;
handle_cast({event_execute_complete, CallId, EvtName, JObj}, #state{callid=CallId, is_node_up=INU, is_call_up=CallUp
                                                                    ,command_q=CmdQ, current_app=CurrApp, msg_id=CurrMsgId}=State) ->
    NoopId = wh_json:get_value(<<"Application-Response">>, JObj),
    case lists:member(EvtName, ecallmgr_util:convert_whistle_app_name(CurrApp)) of
        false ->
            lager:debug("evt ~s not app ~s", [EvtName, CurrApp]),
            {noreply, State};
        true when EvtName =:= <<"noop">>, NoopId =/= CurrMsgId ->
            lager:debug("recieved noop execute complete with incorrect id, ignoring"),
            {noreply, State};
        true ->
            lager:debug("execution complete '~s' for command '~s'", [EvtName, CurrApp]),
            case INU andalso queue:out(CmdQ) of
                false ->
                    %% if the node is down, don't inject the next FS event
                    lager:debug("not continuing until the media node becomes avaliable"),
                    {noreply, State#state{current_app=undefined}, hibernate};
                {empty, _} ->
                    lager:debug("no call commands remain queued, hibernating"),
                    {noreply, State#state{current_app=undefined}, hibernate};
                {{value, Cmd}, CmdQ1} ->
                    AppName = wh_json:get_value(<<"Application-Name">>, Cmd),
                    _ = case CallUp orelse is_post_hangup_command(AppName) of
                            true -> execute_control_request(Cmd, State);
                            false ->
                                lager:debug("command '~s' is not valid after hangup, skipping", [AppName]),
                                send_error_resp(CallId, Cmd),
                                self() ! {force_queue_advance, CallId}
                        end,
                    MsgId = wh_json:get_value(<<"Msg-ID">>, Cmd, <<>>),
                    {noreply, State#state{command_q = CmdQ1, current_app = AppName, current_cmd = Cmd, msg_id=MsgId}, hibernate}
            end
    end;
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
handle_info({nodedown, Node}, #state{node=Node, is_node_up=true}=State) ->
    lager:debug("lost connection to media node ~s, waiting for reconnection", [Node]),
    erlang:monitor_node(Node, false),
    _Ref = erlang:send_after(0, self(), {is_node_up, 100}),
    {noreply, State#state{is_node_up=false}, hibernate};
handle_info({is_node_up, Timeout}, #state{node=Node, is_node_up=false}=State) ->
    case ecallmgr_util:is_node_up(Node) of
        true ->
            erlang:monitor_node(Node, true),
            lager:debug("reconnected to node ~s", [Node]),
            {noreply, State#state{is_node_up=true}, hibernate};
        false ->
            _Ref = case Timeout >= ?MAX_TIMEOUT_FOR_NODE_RESTART of
                          true ->
                              lager:debug("node ~p down, waiting ~p to check again", [Node, ?MAX_TIMEOUT_FOR_NODE_RESTART]),
                              erlang:send_after(?MAX_TIMEOUT_FOR_NODE_RESTART, self(), {is_node_up, ?MAX_TIMEOUT_FOR_NODE_RESTART});
                          false ->
                              lager:debug("node ~p down, waiting ~p to check again", [Node, Timeout]),
                              erlang:send_after(Timeout, self(), {is_node_up, Timeout*2})
                      end,
            {noreply, State}
    end;
handle_info({force_queue_advance, CallId}, #state{callid=CallId, current_app=CurrApp, command_q=CmdQ
                                                  ,is_node_up=INU, is_call_up=CallUp}=State) ->
    lager:debug("received control queue unconditional advance, skipping wait for command completion of '~s'", [CurrApp]),
    case INU andalso queue:out(CmdQ) of
        false ->
            %% if the node is down, don't inject the next FS event
            lager:debug("not continuing until the media node becomes avaliable"),
            {noreply, State#state{current_app = undefined}, hibernate};
        {empty, _} ->
            lager:debug("no call commands remain queued, hibernating"),
            {noreply, State#state{current_app = undefined}, hibernate};
        {{value, Cmd}, CmdQ1} ->
            AppName = wh_json:get_value(<<"Application-Name">>, Cmd),
            _ = case CallUp orelse is_post_hangup_command(AppName) of
                    true ->
                        execute_control_request(Cmd, State);
                    false ->
                        lager:debug("command '~s' is not valid after hangup, skipping", [AppName]),
                        send_error_resp(CallId, Cmd),
                        self() ! {force_queue_advance, CallId}
                end,
            MsgId = wh_json:get_value(<<"Msg-ID">>, Cmd),
            {noreply, State#state{command_q=CmdQ1, current_app=AppName, current_cmd=Cmd
                                  ,keep_alive_ref=get_keep_alive_ref(State), msg_id=MsgId}, hibernate}
    end;
handle_info(keep_alive_expired, State) ->
    lager:debug("no new commands received after channel destruction, our job here is done"),
    {stop, normal, State};
handle_info({sanity_check}, #state{callid=CallId, keep_alive_ref=undefined}=State) ->
    case ecallmgr_fs_nodes:channel_exists(CallId) of
        true -> 
            lager:debug("listener passed sanity check, call is still up"),
            TRef = erlang:send_after(?SANITY_CHECK_PERIOD, self(), {sanity_check}),
            {'noreply', State#state{sanity_check_tref=TRef}};
        false ->
            lager:debug("call uuid does not exist, executing post-hangup events and terminating", []),
            gen_listener:cast(self(), {channel_destroyed, wh_json:new()}),
            {'noreply', State}
    end;
handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
handle_event(_JObj, _State) ->
    {reply, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_listener when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_listener terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{start_time=StartTime,  sanity_check_tref=SCTRef, keep_alive_ref=KATRef}) ->
    catch (erlang:cancel_timer(SCTRef)), 
    catch (erlang:cancel_timer(KATRef)), 
    lager:debug("control queue was up for ~p microseconds", [timer:now_diff(erlang:now(), StartTime)]),
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

%% execute all commands in JObj immediately, irregardless of what is running (if anything).
-spec insert_command/3 :: (#state{}, insert_at_options(), wh_json:json_object()) -> queue().
insert_command(#state{node=Node, callid=CallId, command_q=CommandQ, is_node_up=IsNodeUp}=State, now, JObj) ->
    AName = wh_json:get_value(<<"Application-Name">>, JObj),
    lager:debug("received immediate call command '~s'", [AName]),
    case IsNodeUp andalso AName of
        false ->
            lager:debug("node ~s is not avaliable", [Node]),
            lager:debug("sending execution error for command ~s", [AName]),
            {Mega,Sec,Micro} = erlang:now(),
            Props = [ {<<"Event-Name">>, <<"CHANNEL_EXECUTE_ERROR">>}
                     ,{<<"Event-Date-Timestamp">>, ( (Mega * 1000000 + Sec) * 1000000 + Micro )}
                     ,{<<"Call-ID">>, CallId}
                     ,{<<"Channel-Call-State">>, <<"ERROR">>}
                     ,{<<"Custom-Channel-Vars">>, JObj}
                   ],
            wapi_call:publish_event(CallId, Props),
            CommandQ;
        <<"queue">> ->
            true = wapi_dialplan:queue_v(JObj),
            DefJObj = wh_json:from_list(wh_api:extract_defaults(JObj)),
            #state{command_q=CommandQ1} = lists:foldl(fun(CmdJObj, StateAcc) ->
                                                              case wh_json:is_empty(CmdJObj) of
                                                                  true -> 'ok';
                                                                  false ->
                                                                      put(callid, CallId),
                                                                      AppCmd = wh_json:merge_jobjs(DefJObj, CmdJObj),
                                                                      true = wapi_dialplan:v(AppCmd),
                                                                      CmdQ = insert_command(StateAcc, now, AppCmd),
                                                                      State#state{command_q=CmdQ}
                                                              end
                                                      end, State, wh_json:get_value(<<"Commands">>, JObj)),
            CommandQ1;
        <<"noop">> ->
            execute_control_request(JObj, State),
            maybe_filter_queue(wh_json:get_value(<<"Filter-Applications">>, JObj), CommandQ);
        _ ->
            execute_control_request(JObj, State),
            CommandQ
    end;
insert_command(_State, flush, JObj) ->
    lager:debug("received control queue flush command, clearing all waiting commands"),
    insert_command_into_queue(queue:new(), tail, JObj);
insert_command(#state{command_q=CommandQ}, head, JObj) ->
    insert_command_into_queue(CommandQ, head, JObj);
insert_command(#state{command_q=CommandQ}, tail, JObj) ->
    insert_command_into_queue(CommandQ, tail, JObj);
insert_command(Q, Pos, _) ->
    lager:debug("received command for an unknown queue position: ~p", [Pos]),
    Q.

-spec insert_command_into_queue/3 :: (queue(), 'tail' | 'head', wh_json:json_object()) -> queue().
insert_command_into_queue(Q, Position, JObj) ->
    InsertFun = queue_insert_fun(Position),
    case wh_json:get_value(<<"Application-Name">>, JObj) of
        <<"queue">> -> %% list of commands that need to be added
            true = wapi_dialplan:queue_v(JObj),
            DefJObj = wh_json:from_list(wh_api:extract_defaults(JObj)), %% each command lacks the default headers
            lists:foldr(fun(CmdJObj, TmpQ) ->
                                case wh_json:is_empty(CmdJObj) of
                                    true -> TmpQ;
                                    false ->
                                        AppCmd = wh_json:merge_jobjs(DefJObj, CmdJObj),
                                        true = wapi_dialplan:v(AppCmd),
                                        lager:debug("inserting at the ~s of the control queue call command '~s'"
                                             ,[Position, wh_json:get_value(<<"Application-Name">>, AppCmd)]),
                                        InsertFun(AppCmd, TmpQ)
                                end
                        end, Q, wh_json:get_value(<<"Commands">>, JObj));
        AppName ->
            true = wapi_dialplan:v(JObj),
            lager:debug("inserting at the ~s of the control queue call command '~s'", [Position, AppName]),
            InsertFun(JObj, Q)
    end.

queue_insert_fun(tail) ->
    fun queue:in/2;
queue_insert_fun(head) ->
    fun queue:in_r/2.

%% See Noop documentation for Filter-Applications to get an idea of this function's purpose
-spec maybe_filter_queue/2 :: ('undefined' | list(), queue()) -> queue().
maybe_filter_queue(undefined, CommandQ) -> CommandQ;
maybe_filter_queue([], CommandQ) -> CommandQ;
maybe_filter_queue([AppName|T]=Apps, CommandQ) when is_binary(AppName) ->
    case queue:out(CommandQ) of
        {empty, _} -> CommandQ;
        {{value, NextJObj}, CommandQ1} ->
            case wh_json:get_value(<<"Application-Name">>, NextJObj) =:= AppName of
                false -> maybe_filter_queue(T, CommandQ);
                true ->
                    lager:debug("app ~s matched next command, popping off", [AppName]),
                    maybe_filter_queue(Apps, CommandQ1)
            end
    end;
maybe_filter_queue([AppJObj|T]=Apps, CommandQ) ->
    case queue:out(CommandQ) of
        {empty, _} -> CommandQ;
        {{value, NextJObj}, CommandQ1} ->
            case (AppName = wh_json:get_value(<<"Application-Name">>, NextJObj)) =:=
                wh_json:get_value(<<"Application-Name">>, AppJObj) of
                false -> maybe_filter_queue(T, CommandQ);
                true ->
                    lager:debug("app ~s matched next command, checking fields", [AppName]),
                    Fields = wh_json:get_value(<<"Fields">>, AppJObj),
                    case lists:all(fun({AppField, AppValue}) -> 
                                           wh_json:get_value(AppField, NextJObj) =:= AppValue
                                   end, wh_json:to_proplist(Fields)) of
                        false -> maybe_filter_queue(T, CommandQ);
                        true ->
                            lager:debug("all fields matched next command, popping it off"),
                            maybe_filter_queue(Apps, CommandQ1) % same app and all fields matched
                    end
            end
    end.

-spec is_post_hangup_command/1 :: (ne_binary()) -> boolean().
is_post_hangup_command(AppName) ->
    lists:member(AppName, ?POST_HANGUP_COMMANDS).

-spec execute_control_request/2 :: (wh_json:json_object(), #state{}) -> 'ok'.
execute_control_request(Cmd, #state{node=Node, callid=CallId, self=Srv}) ->
    put(callid, CallId),

    try
        lager:debug("executing call command '~s' ~s", [wh_json:get_value(<<"Application-Name">>, Cmd)
                                                       ,wh_json:get_value(<<"Msg-ID">>, Cmd, <<>>)
                                                      ]),
        Mod = wh_util:to_atom(<<"ecallmgr_"
                                     ,(wh_json:get_value(<<"Event-Category">>, Cmd, <<>>))/binary
                                     ,"_"
                                     ,(wh_json:get_value(<<"Event-Name">>, Cmd, <<>>))/binary
                                   >>),
        Mod:exec_cmd(Node, CallId, Cmd, self())
    catch
        _:{error,nosession} ->
            lager:debug("unable to execute command, no session"),
            send_error_resp(CallId, Cmd, <<"Session "
                                           ,CallId/binary
                                           ," not found for "
                                           ,(wh_json:get_value(<<"Application-Name">>, Cmd))/binary>>),
            Srv ! {force_queue_advance, CallId},
            ok;
        error:{badmatch, {error, nosession}} ->
            lager:debug("unable to execute command, no session"),
            send_error_resp(CallId, Cmd, <<"Session "
                                           ,CallId/binary
                                           ," not found for "
                                           ,(wh_json:get_value(<<"Application-Name">>, Cmd))/binary>>),
            Srv ! {force_queue_advance, CallId},
            ok;
        error:{badmatch, {error, ErrMsg}} ->
            ST = erlang:get_stacktrace(),
            lager:debug("invalid command ~s: ~p", [wh_json:get_value(<<"Application-Name">>, Cmd), ErrMsg]),
            lager:debug("stacktrace:"),
            _ = [lager:debug("~p", [Line]) || Line <- ST],
            send_error_resp(CallId, Cmd),
            Srv ! {force_queue_advance, CallId},
            ok;
        throw:{msg, ErrMsg} ->
            lager:debug("error while executing command ~s: ~p", [wh_json:get_value(<<"Application-Name">>, Cmd), ErrMsg]),
            send_error_resp(CallId, Cmd),
            Srv ! {force_queue_advance, CallId},
            ok;
        _A:_B ->
            ST = erlang:get_stacktrace(),
            lager:debug("exception (~s) while executing ~s: ~p", [_A, wh_json:get_value(<<"Application-Name">>, Cmd), _B]),
            lager:debug("stacktrace:"),
            _ = [lager:debug("~p", [Line]) || Line <- ST],
            send_error_resp(CallId, Cmd),
            Srv ! {force_queue_advance, CallId},
            ok
    end.

-spec send_error_resp/2 :: (ne_binary(), wh_json:json_object()) -> 'ok'.
send_error_resp(CallId, Cmd) ->
    send_error_resp(CallId, Cmd, <<"Could not execute dialplan action: ", (wh_json:get_value(<<"Application-Name">>, Cmd))/binary>>).

-spec send_error_resp/3 :: (ne_binary(), wh_json:json_object(), ne_binary()) -> 'ok'.
send_error_resp(CallId, Cmd, Msg) ->
    Resp = [{<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, Cmd, <<>>)}
            ,{<<"Error-Message">>, Msg}
            ,{<<"Request">>, Cmd}
            | wh_api:default_headers(<<>>, <<"error">>, <<"dialplan">>, ?APP_NAME, ?APP_VERSION)
           ],
    {ok, Payload} = wapi_dialplan:error(Resp),
    lager:debug("sending execution error: ~s", [Payload]),
    wapi_dialplan:publish_event(CallId, Payload).

-spec get_keep_alive_ref/1 :: (#state{}) -> 'undefined' | reference().
get_keep_alive_ref(#state{is_call_up=true}) -> 
    undefined;
get_keep_alive_ref(#state{keep_alive_ref=undefined, is_call_up=false}) -> 
    lager:debug("started post hangup keep alive timer for ~bms", [?KEEP_ALIVE]),
    erlang:send_after(?KEEP_ALIVE, self(), keep_alive_expired);
get_keep_alive_ref(#state{keep_alive_ref=TRef, is_call_up=false}) ->
    _ = case erlang:cancel_timer(TRef) of
            false -> ok;
            _ -> %% flush the receive buffer of expiration messages
                receive keep_alive_expired -> ok
                after 0 -> ok end
        end,
    lager:debug("reset post hangup keep alive timer"),
    erlang:send_after(?KEEP_ALIVE, self(), keep_alive_expired).

-spec publish_leg_addition/1 :: (wh_json:json_object()) -> 'ok'.
publish_leg_addition(JObj) ->
    Props = case wh_json:get_value(<<"Event-Name">>, JObj) of
                <<"CHANNEL_BRIDGE">> ->
                    wh_json:to_proplist(JObj);
                <<"CHANNEL_CREATE">> ->
                    ecallmgr_call_events:swap_call_legs(JObj)
            end,
    Event = ecallmgr_call_events:create_event(<<"LEG_CREATED">>, undefined, Props),
    case props:get_value(<<"Call-ID">>, Event) of
        undefined -> ok;
        _Else -> ecallmgr_call_events:publish_event(Event)
    end.

-spec publish_leg_removal/1 :: (wh_json:json_object()) -> 'ok'.
publish_leg_removal(JObj) ->
    Props = case wh_json:get_value(<<"Event-Name">>, JObj) of
                <<"CHANNEL_UNBRIDGE">> ->
                    wh_json:to_proplist(JObj);
                <<"CHANNEL_DESTROY">> ->
                    ecallmgr_call_events:swap_call_legs(JObj)
            end,
    Event = ecallmgr_call_events:create_event(<<"LEG_DESTROYED">>, undefined, Props),
    case props:get_value(<<"Call-ID">>, Event) of
        undefined ->
            ok;
        _Else ->
            ecallmgr_call_events:publish_event(Event)
    end.

-spec publish_callid_update/3 :: (ne_binary(), ne_binary(), ne_binary()) -> 'ok'.
publish_callid_update(PrevCallId, NewCallId, CtrlQ) -> 
    lager:debug("sending callid update to ~s instead of ~s", [NewCallId, PrevCallId]),
    Update = [{<<"Call-ID">>, NewCallId}
              ,{<<"Replaces-Call-ID">>, PrevCallId}
              ,{<<"Control-Queue">>, CtrlQ}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ],
    wapi_call:publish_callid_update(PrevCallId, Update).

-spec publish_control_transfer/2 :: (ne_binary(), ne_binary()) -> 'ok'.
publish_control_transfer(undefined, CallId) ->
    lager:debug("no whapp queue known for control transfer for ~s", [CallId]);
publish_control_transfer(ControllerQ, CallId) ->
    lager:debug("sending control transfer to queue ~s for ~s", [ControllerQ, CallId]),
    Transfer = [{<<"Call-ID">>, CallId}
                | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ],
    wapi_call:publish_control_transfer(ControllerQ, Transfer).
