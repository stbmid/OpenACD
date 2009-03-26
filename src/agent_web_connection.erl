%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Handles the internal (cpx interaction) part of an agent web connection.
%% (2008 12 09 : marking this for a refactoring.  Micah)
%% @see agent_web_listener
-module(agent_web_connection).
-author("Micah").

-behaviour(gen_server).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-define(TICK_LENGTH, 5000000000).
-else.
-define(TICK_LENGTH, 10000).
-endif.

-include("call.hrl").
-include("agent.hrl").

%% API
-export([start_link/2, start/2, stop/1, api/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	salt :: any(),
	ref :: ref() | 'undefined',
	agent_fsm :: pid() | 'undefined',
	ack_queue = dict:new(), % key = counter, value is {when_qed, tries, pollitem} so that a message can be resent
	poll_queue = [] :: [{struct, [{binary(), any()}]}],
		% list of json structs to be sent to the client on poll.
		% struct MUST contain a counter, used to handle acks/errs
	missed_polls = 0 :: non_neg_integer(),
	counter = 1 :: non_neg_integer(),
	table :: atom() | 'undefined',
	ack_timer,
	securitylevel = agent :: 'agent' | 'supervisor' | 'admin'
}).


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Agent, Security) ->
	gen_server:start_link(?MODULE, [Agent, Security], [{timeout, 10000}]).
	
start(Agent, Security) ->
	gen_server:start(?MODULE, [Agent, Security], [{timeout, 10000}]).

stop(Pid) ->
	gen_server:call(Pid, stop).

api(Pid, Apicall) ->
	gen_server:call(Pid, Apicall).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Agent, Security]) ->
	?CONSOLE("web_connection init ~p", [Agent]),
	{ok, Apid} = agent_manager:start_agent(Agent),
	case agent:set_connection(Apid, self()) of
		error ->
			{stop, "Agent could not be started"};
		_Else ->
			{ok, Tref} = timer:send_interval(?TICK_LENGTH, check_acks),
			{ok, #state{agent_fsm = Apid, ack_timer = Tref, securitylevel = Security}}
	end.


%	case Post of
%		[{"username", User},{"password", Passwrd}] -> 
%			% io:format("seems like a well formed post~n"),
%			Self = self(),
%			% TODO add salt support
%			case agent_auth:auth(User, Passwrd, "replacethiswithpropersalt") of
%				deny -> 
%					{stop, "Login Denied"};
%				{allow, Skills, Security} ->
%					Agent = #agent{login=User, skills=Skills},
%			
%					% io:format("if they are already logged in, update the reference~n"),
%					Result = ets:match(Table, {'$1', '$2', User}),
%					%io:format("restults:~p~n", [Result]),
%					lists:map(fun([_R, P]) -> ?MODULE:stop(P) end, Result),
%					ets:insert(Table, {erlang:ref_to_list(Ref), Self, User}),
%					
%					% start the agent and associate it with self
%					{_Reply, Apid} = agent_manager:start_agent(Agent),
%					case agent:set_connection(Apid, Self) of
%						error -> 
%							{stop, "User could not be started"};
%						_Otherwise -> 
%							% start the ack timer
%							{ok, Tref} = timer:send_interval(?TICK_LENGTH, check_acks),
%							{ok, #state{agent_fsm = Apid, ref = Ref, table = Table, ack_timer = Tref, securitylevel = Security}}
%					end%;
%				%_Other ->
%				%	{stop, "500 internal server error"}
%			end;
%		_Other -> 
%			% io:format("all other posts~n"),
%			{stop, "Invalid Post data"}
%	end.


%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
	{stop, shutdown, ok, State};
handle_call(poll, _From, #state{poll_queue = Pollq} = State) ->
	State2 = State#state{poll_queue=[], missed_polls = 0, ack_queue = build_acks(State#state.poll_queue, State#state.ack_queue)},
	Json2 = {struct, [{success, true}, {message, <<"Poll successful">>}, {data, Pollq}]},
	{reply, {200, [], mochijson2:encode(Json2)}, State2};
handle_call(logout, _From, State) ->
	{stop, normal, {200, [{"Set-Cookie", [{"cpx_id=dead"}]}], mochijson2:encode({struct, [{success, true}]})}, State};
handle_call({set_state, Statename}, _From, #state{agent_fsm = Apid} = State) ->
	case agent:set_state(Apid, agent:list_to_state(Statename)) of
		ok ->
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"status">>, ok}]})}, State};
		invalid ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"status">>, invalid}]})}, State}
	end;
handle_call({set_state, Statename, Statedata}, _From, #state{agent_fsm = Apid} = State) ->
	case agent:set_state(Apid, agent:list_to_state(Statename), Statedata) of
		invalid ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"status">>, invalid}]})}, State};
		Status ->
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"status">>, Status}]})}, State}
	end;
handle_call({ack, Counter}, _From, State) ->
	{reply, ok, State};
handle_call({err, Counter}, _From, State) ->
	{reply, ok, State};
handle_call({err, Counter, Message}, _From, State) ->
	{reply, ok, State};
handle_call(Allothers, _From, State) ->
	{reply, {unknown_call, Allothers}, State}.
	
	
	
	
	%
%handle_call({request, {"/logout", _Post, _Cookie}}, _From, State) -> 
%	{stop, normal, {200, [{"Set-Cookie", "cpx_id=0"}], mochijson2:encode({struct, [{success, true}, {message, <<"Logout completed">>}]})}, State};
%handle_call({request, {"/poll", _Post, _Cookie}}, _From, State) -> 
%	?CONSOLE("poll called",[]),
%	State2 = State#state{poll_queue=[], missed_polls = 0, ack_queue = build_acks(State#state.poll_queue, State#state.ack_queue)},
%	Pollq = State#state.poll_queue,
%	Json = [{struct, [{counter, Counter}, {tried, Tried}, {type, Type}, {data, Data}]} || {Counter, Tried, Type, Data} <- Pollq],
%	Json2 = {struct, [{success, true}, {message, <<"Poll successful">>}, {data, Json}]},
%	%io:format("json:  ~p~n", [Json]),
%	{reply, cpx_json:encode_trap(Json2), State2};
%handle_call({request, {Path, Post, Cookie}}, _From, State) -> 
%	%io:format("all other requests~n"),
%	case util:string_split(Path, "/") of 
%		["", "state", Statename] -> 
%			?CONSOLE("trying to change to ~p", [Statename]),
%			case agent:set_state(State#state.agent_fsm, list_to_existing_atom(Statename)) of
%				ok -> 
%					Data = {struct, [{success, true}, {state, list_to_existing_atom(Statename)}]},
%					{reply, cpx_json:encode_trap(Data), State};
%				_Else -> 
%					{reply, {200, [], mochijson2:encode({struct, [{success, false}]})}, State}
%			end;
%		["", "state", Statename, Statedata] -> 
%			?CONSOLE("trying to change to ~p with data ~p", [Statename, Statedata]),
%			case agent:set_state(State#state.agent_fsm, list_to_atom(Statename), Statedata) of 
%				ok -> 
%					{reply, cpx_json:encode_trap({struct, [{success, true}, {state, list_to_existing_atom(Statename)}, {data, Statedata}]}), State};
%				_Else -> 
%					{reply, cpx_json:encode_trap({struct, [{success, false}, {message, <<"Invalid state">>}]}), State}
%			end;
%		["", "ack", Counter] -> 
%			?CONSOLE("you are acking~p", [Counter]),
%			Ackq = dict:erase(list_to_integer(Counter), State#state.ack_queue),
%			State2 = State#state{ack_queue = Ackq},
%			{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State2};
%		["", "err", Counter] -> 
%			?CONSOLE("you are erroring~p", [Counter]),
%			Ackq = dict:erase(list_to_integer(Counter), State#state.ack_queue),
%			State2 = State#state{ack_queue = Ackq},
%			{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State2};
%		["", "err", Counter, Message] -> 
%			?CONSOLE("you are erroring ~p with message ~p", [Counter, Message]),
%			Ackq = dict:erase(list_to_integer(Counter), State#state.ack_queue),
%			State2 = State#state{ack_queue = Ackq},
%			{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State2};
%		_Allelse -> 
%			?CONSOLE("I have no idea what you are talking about.", []),
%			{reply, {501, [], io_lib:format("Cannot handle request of Path ~p, Post ~p, with Cookie: ~p\", path:\"~p\", post:\"~p\", cookie:\"~p", [Path, Post, Cookie, Path, Post, Cookie])}, State}
%	end.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------

handle_cast({change_state, ringing, #call{client = Clientrec} = Call}, #state{poll_queue = Pollq, counter = Counter} = State) ->
	Newqueue = 
		[{struct, [
			{<<"counter">>, Counter},
			{<<"command">>, <<"astate">>},
			{<<"state">>, ringing},
			{<<"callerid">>, list_to_binary(Call#call.callerid)},
			{<<"brandname">>, list_to_binary(Clientrec#client.label)}
		]} | Pollq],
	{noreply, State#state{counter = Counter + 1, poll_queue = Newqueue}};
handle_cast({change_state, AgState, Data}, #state{poll_queue = Pollq, counter = Counter} = State) ->
	Newqueue =
		[{struct, [
			{<<"counter">>, Counter},
			{<<"command">>, <<"astate">>},
			{<<"state">>, AgState},
			{<<"stateinfo">>, <<"NYI">>}
		]} | Pollq],
	{noreply, State#state{counter = Counter + 1, poll_queue = Newqueue}};
handle_cast({change_state, AgState}, #state{poll_queue = Pollq, counter = Counter} = State) ->
	Newqueue =
		[{struct, [
			{<<"counter">>, Counter},
			{<<"command">>, <<"astate">>},
			{<<"state">>, AgState}
		]} | Pollq],
	{noreply, State#state{counter = Counter + 1, poll_queue = Newqueue}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(check_acks, #state{missed_polls = Missedpolls} = State) when Missedpolls < 4 -> 	
	{noreply, State#state{missed_polls = Missedpolls + 1}};
handle_info(check_acks, State) -> 
	?CONSOLE("too many missed polls.",[]),
	{stop, "Client timeout", ok, State};
handle_info(Info, State) ->
	?CONSOLE("info I can't handle:  ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, State) ->
	?CONSOLE("terminated ~p", [Reason]),
	%ets:delete(State#state.table, erlang:ref_to_list(State#state.ref)),
	agent:stop(State#state.agent_fsm),
	timer:cancel(State#state.ack_timer),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
	
build_acks([], Acks) -> 
	Acks;
build_acks([{struct, Pollprops} | Pollqueue], Acks) -> 
	%[{Counter, Tried, Type, Data} | Pollqueue]
	Counter = proplists:get_value(<<"counter">>, Pollprops),
	case dict:find(Counter, Acks) of
		error ->
			Acks2 = dict:store(Counter, {now(), 0, {struct, Pollprops}}, Acks);
		{Time, Tried, _Struct} ->
			Acks2 = dict:store(Counter, {Time, Tried+1, {struct, Pollprops}}, Acks)
	end,
	build_acks(Pollqueue, Acks2).
	
build_poll([], Pollqueue, Runningcount) -> 
	{Pollqueue, Runningcount};
build_poll([{_Counter, {Tried, Type, Data}} | Ackqueue], Pollqueue, Runningcount) -> 
	build_poll(Ackqueue, lists:append(Pollqueue, [{Runningcount+1, Tried+1, Type, Data}]), Runningcount+1).

-ifdef(TEST).

set_state_test_() ->
	{
		foreach,
		fun() ->
			agent_manager:start([node()]),
			{ok, Connpid} = agent_web_connection:start(#agent{login = "testagent", skills = [english]}, agent),
			{Connpid}
		end,
		fun({Connpid}) ->
			stop(Connpid),
			agent_manager:stop()
		end,
		[
			fun({Connpid}) ->
				{"Set state valid",
				fun() ->
					Reply = gen_server:call(Connpid, {set_state, "idle"}),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"true">>, 44, [34,<<"status">>, 34], 58, [34,"ok", 34], 125]}, Reply),
					Reply2 = gen_server:call(Connpid, {set_state, "released", "default"}),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"true">>, 44, [34,<<"status">>, 34], 58, [34,"ok", 34], 125]}, Reply2)
				end}
			end,
			fun({Connpid}) ->
				{"Set state invalid",
				fun() ->
					Reply = gen_server:call(Connpid, {set_state, "wrapup"}),
					?CONSOLE("~p", [Reply]),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"false">>, 44, [34,<<"status">>, 34], 58, [34,"invalid", 34], 125]}, Reply),
					Reply2 = gen_server:call(Connpid, {set_state, "wrapup", "garbage"}),
					?CONSOLE("~p", [Reply2]),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"false">>, 44, [34,<<"status">>, 34], 58, [34,"invalid", 34], 125]}, Reply2)
				end}
			end
		]
	}.

-define(MYSERVERFUNC, 
	fun() ->
		["testpx", _Host] = string:tokens(atom_to_list(node()), "@"),
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		Passwd = util:bin_to_hexstr(erlang:md5("Password123")),
		Saltedpasswd = util:bin_to_hexstr(erlang:md5(string:concat("12345", Passwd))),
		Agent = #agent{login = "agent", skills = [english]},
		agent_manager:start([node()]),
		agent_auth:start(),
		{ok, Pid} = start_link(Agent, agent),
		Stopfun = fun() ->
			stop(Pid),
			agent_auth:stop(),
			agent_manager:stop(),
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		{Pid, Stopfun}
	end
).

-include("gen_server_test.hrl").


-endif.