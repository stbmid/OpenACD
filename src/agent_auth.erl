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

%% @doc Connection to the local authenication cache and integration to another module.
%% Authentication is first checked by the integration module (if any).  If that fails, 
%% this module will fall back to it's local cache in the mnesia 'agent_auth' table.
%% the cache table is both ram and disc copies on all nodes.

-module(agent_auth).

-behaviour(gen_server).

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-ifdef(EUNIT).
	-include_lib("eunit/include/eunit.hrl").
	-export([
		mock_auth_deny/5,
		mock_auth_success/5,
		mock_auth_error/5,
		mock_start_failure/2,
		mock_start_success/2
	]).
-endif.


%% API
-export([start_link/5, start/5, start_link/0, start/0, stop/0, auth/3]).
-export([
	cache/4,
	destroy/1,
	add_agent/5,
	set_agent/5,
	set_agent/6,
	get_agent/1,
	get_agents/0,
	get_agents/1
]).
-export([
	new_profile/2,
	set_profile/3,
	get_profile/1,
	get_profiles/0,
	destroy_profile/1
	]).
%% API for release options
-export([
	new_release/1,
	destroy_release/1,
	update_release/2,
	get_releases/0
	]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	integration = 'true' :: bool(), % set to 'false' if there's no integration, otherwise default ('undefined')
	mod :: atom(),
	start_func :: atom(),
	start_args :: [any()] | 'undefined',
	check_func :: atom(),
	check_args :: [any()] | 'undefined'
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Starts with no integration.  All authentication requests are done against the mnesia cache.
start() -> 
	gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @doc Starts with no integration linked to the calling process.  All authentication requests are done against the mnesia cache.
start_link() -> 
	gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @doc Starts with integration.  All authentication requests are done against the mnesia cache only if the integration fails.
%% When the agent_auth starts, `apply(Mod, StartFunc, StartArgs)' is called as the last step. When an authenticaiton request 
%% is made, `apply(Mod, CheckFunc, PrependedCheckArgs)' is called with the `Username', `Password', and `Salt' prepended to the `CheckArgs' list
%% to get `PrependedCheckArgs'.
%% The integration is expected to return either `{allow, PasswordToCache, Profile, SecurityLevel}' or `deny'.  If the tuple is returned, 
%% the passed username is cached using {@link cache/4}.
%% @see auth/3
-spec(start/5 :: (Mod :: atom(), StartFunc :: atom(), StartArgs :: [any()], CheckFunc :: atom(), CheckArgs :: [any()]) -> 'ok' | any()).
start(Mod, StartFunc, StartArgs, CheckFunc, CheckArgs) -> 
	gen_server:start({local, ?MODULE}, ?MODULE, [Mod, StartFunc, StartArgs, CheckFunc, CheckArgs], []).
	
%% @doc Starts linked to the calling process with integration.
%% @see start/5
-spec(start_link/5 :: (Mod :: atom(), StartFunc :: atom(), StartArgs :: [any()], CheckFunc :: atom(), CheckArgs :: [any()]) -> 'ok' | any()).
start_link(Mod, StartFunc, StartArgs, CheckFunc, CheckArgs) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [Mod, StartFunc, StartArgs, CheckFunc, CheckArgs], []).

new_release(Rec) when is_record(Rec, release_opt) ->
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

destroy_release(Label) when is_list(Label) ->
	F = fun() ->
		mnesia:delete({release_opt, Label})
	end,
	mnesia:transaction(F).

update_release(Label, Rec) when is_list(Label), is_record(Rec, release_opt) ->
	F = fun() ->
		mnesia:delete({release_opt, Label}),
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

get_releases() ->
	F = fun() ->
		Select = qlc:q([X || X <- mnesia:table(release_opt)]),
		qlc:e(Select)
	end,
	{atomic, Opts} = mnesia:transaction(F),
	lists:sort(Opts).

new_profile(Name, Skills) ->
	Rec = #agent_profile{name = Name, skills = Skills},
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

set_profile(Oldname, Oldname, Skills) ->
	Rec = #agent_profile{name = Oldname, skills = Skills},
	F = fun() ->
		mnesia:delete({agent_profile, Oldname}),
		mnesia:write(Rec)
	end,
	mnesia:transaction(F);
set_profile(Oldname, Newname, Skills) ->
	Rec = #agent_profile{name = Newname, skills = Skills},
	F = fun() ->
		mnesia:delete({agent_profile, Oldname}),
		mnesia:write(Rec),
		Agents = get_agents(Oldname),
		Update = fun(Arec) ->
			Newagent = Arec#agent_auth{profile = Newname},
			destroy(Arec#agent_auth.login),
			mnesia:write(Newagent)
		end,
		lists:map(Update, Agents),
		ok
	end,
	mnesia:transaction(F).

destroy_profile("Default") ->
	error;
destroy_profile(Name) ->
	F = fun() ->
		mnesia:delete({agent_profile, Name}),
		Agents = get_agents(Name),
		Update = fun(Arec) ->
			Newagent = Arec#agent_auth{profile = "Default"},
			destroy(Arec#agent_auth.login),
			mnesia:write(Newagent)
		end,
		lists:map(Update, Agents),
		ok
	end,
	mnesia:transaction(F).

get_profile(Name) ->
	F = fun() ->
		mnesia:read({agent_profile, Name})
	end,
	case mnesia:transaction(F) of
		{atomic, []} ->
			undefined;
		{atomic, [Profile]} ->
			{Profile#agent_profile.name, Profile#agent_profile.skills}
	end.

get_profiles() ->
	F = fun() ->
		QH = qlc:q([ X || X <- mnesia:table(agent_profile)]),
		qlc:e(QH)
	end,
	{atomic, Profiles} = mnesia:transaction(F),
	Convert = fun(Profile) ->
		{Profile#agent_profile.name, Profile#agent_profile.skills}
	end,
	Cprofs = lists:map(Convert, Profiles),
	Sort = fun({Name1, _Skills1}, {Name2, _Skills2}) ->
		Name1 < Name2
	end,
	lists:sort(Sort, Cprofs).

set_agent(Oldlogin, Newlogin, Newskills, NewSecurity, Newprofile) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Oldlogin]),
		[Agent] = qlc:e(QH),
		Newrec = #agent_auth{
			login = Newlogin,
			profile = Newprofile,
			securitylevel = NewSecurity,
			skills = Newskills,
			password = Agent#agent_auth.password
		},
		destroy(Oldlogin),
		mnesia:write(Newrec),
		ok
	end,
	mnesia:transaction(F).

set_agent(Oldlogin, Newlogin, Newpass, Newskills, NewSecurity, Newprofile) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Oldlogin]),
		case qlc:e(QH) of
			[] ->
				error;
			_Agent ->
				destroy(Oldlogin),
				add_agent(Newlogin, Newpass, Newskills, NewSecurity, Newprofile),
				ok
		end
	end,
	mnesia:transaction(F).
			
get_agent(Login) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Login]),
		qlc:e(QH)
	end,
	mnesia:transaction(F).
	
get_agents() ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth)]),
		qlc:e(QH)
	end,
	{atomic, Agents} = mnesia:transaction(F),
	Sort = fun(#agent_auth{profile = P1}, #agent_auth{profile = P2}) ->
		P1 < P2
	end,
	lists:sort(Sort, Agents).

get_agents(Profile) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.profile =:= Profile]),
		qlc:e(QH)
	end,
	{atomic, Agents} = mnesia:transaction(F),
	Sort = fun(#agent_auth{login = L1}, #agent_auth{login = L2}) ->
		 L1 < L2
	end,
	lists:sort(Sort, Agents).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @hidden
init([Mod, StartFunc, StartArgs, CheckFunc, CheckArgs]) ->
	?DEBUG("~p starting at ~p with integration", [?MODULE, node()]),
	case build_tables() of
		ok -> 
			apply(Mod, StartFunc, StartArgs),
			{ok, #state{mod=Mod, start_func=StartFunc, start_args=StartArgs, check_func = CheckFunc, check_args = CheckArgs}}
	end;
init([]) -> 
	?DEBUG("~p starting at ~p as stand-alone", [?MODULE, node()]),
	case build_tables() of
		ok -> 
			{ok, #state{integration = false}}
	end.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

%% @private
%Password should already be md5'ed.
handle_call({authentication, Username, Password, Salt}, _From, State) -> 
	% start w/ the remote try.  If that fails, try the local.
	case State#state.integration of
		false -> 
			?DEBUG("local authentication only", []),
			Reply = local_auth(Username, Password, Salt),
			{reply, Reply, State};
		_Else -> 
			?DEBUG("remote authentication attempt first: ~p : ~p : ~p", [State#state.mod, State#state.check_func, State#state.check_args]),
			Args = lists:append([[Username, Password, Salt], State#state.check_args]),
			case apply(State#state.mod, State#state.check_func, Args) of
				{allow, CachePassword, Profile, Security} -> 
					cache(Username, CachePassword, Profile, Security),
					{Profile, PSkills} = get_profile(Profile),
					Skills = case get_agent(Username) of
						{atomic, []} ->
						 [];
						{atomic, [#agent_auth{skills = ASkills}]} ->
							ASkills
					end,
					{reply, {allow, lists:umerge(lists:sort(Skills), lists:sort(['_agent', '_node'])), Security, Profile}, State};
				deny -> 
					destroy(Username),
					{reply, deny, State};
				_Otherwise -> 
					Reply = local_auth(Username, Password, Salt),
					{reply, Reply, State}
			end
	end;
handle_call(stop, _From, State) ->
	{stop, normal, ok, State};
handle_call(Request, _From, State) ->
	?DEBUG("agent_auth does not understand request:  ~p", [Request]),
    Reply = {unknown_call, Request},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(Reason, _State) ->
	?NOTICE("terminating:  ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc Base authentication function.  Does the appropriate gen_server:call.  Username, Password, and Salt are 
%% all expected to be of type `string()'.
%% Password is an md5 hash of the salt and the md5 hash of the plain text password.  In pseudo code, password is
%%
%% <pre>md5(Salt + md5(password))</pre>
%%
%% When integration is enabled, the integration module should return `{allow, CachePassword, Profile, Securitylevel}' 
%% for the local authentication
%% cache to store a hashed and unsalted password.  Local passwords are stored in a lower cased md5 hash.
%% 
%% If integration returns anything other than `{allow, CachePassword, Profile, Securitylevel}' 
%% or `deny', agent_auth falls back on it's mnesia cache.
%% If that fails, `deny' is returned in all cases.
%% 
%% The magic skills of `_agent' and `_node' are automcatically appended to the skill list, and therefore do not need to be stored.
%%
%% @see local_auth/3.
-spec(auth/3 :: (Username :: string(), Password :: string(), Salt :: string()) -> {'allow', [atom()], security_level(), string()} | 'deny').
auth(Username, Password, Salt) -> 
	gen_server:call(?MODULE, {authentication, Username, Password, Salt}).

%% @doc Starts mnesia and creates the tables.  If the tables already exist, returns `ok'.  Otherwise, a default username
%% of `"agent"' is stored with password `"Password123"' and skill `[english]'.
-spec(build_tables/0 :: () -> 'ok').
build_tables() ->
	?DEBUG("building tables...", []),
%	Nodes = lists:append([[node()], nodes()]),
	A = util:build_table(agent_auth, [
				{attributes, record_info(fields, agent_auth)},
				{disc_copies, [node()]}
			]),
	case A of
		{atomic, ok} ->
			F = fun() ->
				mnesia:write(#agent_auth{login="agent", password=util:bin_to_hexstr(erlang:md5("Password123")), skills=[english], profile="Default"}),
				mnesia:write(#agent_auth{login="administrator", password=util:bin_to_hexstr(erlang:md5("Password123")), securitylevel=admin, skills=[english], profile="Default"})
			end,
			case mnesia:transaction(F) of
				{atomic, ok} -> 
					ok;
				Else -> 
					Else
			end;
		_Else when A =:= copied; A =:= exists ->
			ok;
		_Else -> 
			A
	end,
	B = util:build_table(release_opt, [
		{attributes, record_info(fields, release_opt)},
		{disc_copies, [node()]}
	]),
	case B of
		{atomic, ok} ->
			ok;
		_Else2 when B =:= copied; B =:= exists ->
			ok;
		_Else2 ->
			B
	end,
	C = util:build_table(agent_profile, [
		{attributes, record_info(fields, agent_profile)},
		{disc_copies, [node()]}
	]),
	case C of
		{atomic, ok} -> 
			G = fun() ->
				mnesia:write(?DEFAULT_PROFILE)
			end,
			case mnesia:transaction(G) of
				{atomic, ok} -> 
					ok;
				Else2 -> 
					Else2
			end;
		_Else3 when C =:= copied; C =:= exists ->
			ok;
		_Else3 ->
			C
	end.

%% @doc Caches the passed `Username', `Password', `Skills', and `Security' type.  to the mnesia database.  
%% `Username' is the plaintext name and used as the key. 
%% `Password' is assumed to be prehashed either from erlang:md5 or as type `string()'.  `Skills' should not
%% include the magic skills of `_agent' or `_node'.  `Security' is either `agent', `supervisor', or `admin'.
-spec(cache/4 ::	(Username :: string(), Password :: string(), Profile :: string(), Security :: 'agent' | 'supervisor' | 'admin') -> 
						{'atomic', 'ok'} | {'aborted', any()};
					(Username :: string(), Password :: binary(), Profile :: string(), Security :: 'agent' | 'supervisor' | 'admin') -> 
						{'atomic', 'ok'} | {'aborted', any()}).
cache(Username, Password, Profile, Security) when is_binary(Password) ->
	cache(Username, util:bin_to_hexstr(Password), Profile, Security);
cache(Username, Password, Profile, Security) when is_atom(Security) ->
	{_, Integrated, _} = now(),
	Agent = #agent_auth{
		login = Username,
		password = Password,
		skills = [],
		securitylevel = Security,
		integrated = Integrated,
		profile = Profile},
	F = fun() ->
		mnesia:write(Agent)
	end,
	mnesia:transaction(F).
	
%% @doc adds a user to the local cache bypassing the integrated at check.  Note that unlike {@link cache/4} this expects the password 
%% in plain text!
-spec(add_agent/5 :: 
	(Username :: string(), Password :: string(), Skills :: [atom()], Security :: 'admin' | 'agent' | 'supervisor', Profile :: string()) -> 
		{'atomic', 'ok'}).
add_agent(Username, Password, Skills, Security, Profile) ->
	Rec = #agent_auth{
		login = Username,
		password = util:bin_to_hexstr(erlang:md5(Password)),
		skills = Skills,
		securitylevel = Security,
		profile = Profile},
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

%% @doc Removes the passed user with login of `Username' from the local cache.  Called when integration returns a deny.
-spec(destroy/1 :: (Username :: string()) -> {'atomic', 'ok'} | {'aborted', any()}).
destroy(Username) -> 
	F = fun() -> 
		mnesia:delete({agent_auth, Username})
	end,
	mnesia:transaction(F).

%% @private 
% Checks the `Username' and prehashed `Password' using the given `Salt' for the cached password.
% internally called by the auth callback; there should be no need to call this directly (aside from tests).
-spec(local_auth/3 :: (Username :: string(), Password :: string(), Salt :: string()) -> {'allow', [atom()], security_level(), string()} | 'deny').
local_auth(Username, Password, Salt) -> 
	QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Username]),
	% salt the password	
	F = fun() -> qlc:e(QH) end,
	case mnesia:transaction(F) of
		{atomic, []} -> 
			deny;
		{atomic, [Agent]} when is_record(Agent, agent_auth) -> 
			%check the password after salt
			case salt(Agent#agent_auth.password, Salt) of
				Password -> 
					{allow, lists:umerge(lists:sort(Agent#agent_auth.skills), lists:sort(['_agent', '_node'])), Agent#agent_auth.securitylevel, Agent#agent_auth.profile};
				Else -> 
					?DEBUG("Password: ~p;  Salting: ~p;  Presalting: ~p;  Agentname: ~p", [Password, Else, Agent#agent_auth.password, Agent#agent_auth.login]),
					deny
			end;
		Else ->
% TODO better error reporting/handling here?
			?WARNING("Unusual response from local auth query: ~p", [Else]),
			deny
	end. 

%% @private
% Apply the passed Salt to the passed Hash.  The Hash is converted from a bin if need be, lowercased, then appended to the Salt.
% all this is then erlang:md5'ed.  That result is then turned into a list, and lowercased.
-spec(salt/2 ::	(Hash :: binary(), Salt :: string()) -> string();
		(Hash :: string(), Salt :: string()) -> string()).
salt(Hash, Salt) when is_binary(Hash) ->
	?DEBUG("agent_auth hash conversion...", []),
	salt(util:bin_to_hexstr(Hash), Salt);
salt(Hash, Salt) when is_list(Hash) -> 
	?DEBUG("agent_auth salting   hash: ~p;  salt: ~p", [Hash, Salt]),
	Lower = string:to_lower(Hash),
	string:to_lower(util:bin_to_hexstr(erlang:md5(Salt ++ Lower))).
	
%% @doc Stops the authentication server.  Note this does not stop the integration server.
stop() -> 
	gen_server:call(?MODULE, stop).

-ifdef(EUNIT).

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------

local_auth_test_() -> 
	["testpx", _Host] = string:tokens(atom_to_list(node()), "@"),
	{
		setup,
		fun() -> 
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			build_tables(),
			start()
		end,
		fun(_) -> 
			stop(),
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			{
				"Salting a Binary",
				fun() -> 
					Salt = "salt",
					Hash = erlang:md5("test"),
					?assertMatch("fa148970883f467111816d22cf840613", salt(Hash, Salt))
				end
			},
			{
				"Salting a Hex",
				fun() ->
					Salt = "salt",
					Hash = util:bin_to_hexstr(erlang:md5("test")),
					?assertMatch("fa148970883f467111816d22cf840613", salt(Hash, Salt))
				end
			},
			{
				"Cache a user with bin encoded password",
				fun() -> 
					cache("A", erlang:md5("B"), "Default", agent),
					F = fun() -> 
						QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= "A"]),
						qlc:e(QH)
					end,
					{atomic, [Agent]} = mnesia:transaction(F),
					?assertEqual("9d5ed678fe57bcca610140957afab571", Agent#agent_auth.password),
					destroy("A")
				end
			},
			{
				"Cache a user with a hex encoded password in caps",
				fun() ->
					cache("A", util:bin_to_hexstr(erlang:md5("B")), "Default", agent),
					F = fun() -> 
						QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= "A"]),
						qlc:e(QH)
					end,
					{atomic, [Agent]} = mnesia:transaction(F),
					?assertEqual("9d5ed678fe57bcca610140957afab571", Agent#agent_auth.password),
					destroy("A")
				end
			},
			{
				"Cache a user with a security level",
				fun() ->
					cache("A", util:bin_to_hexstr(erlang:md5("B")), "Default", supervisor),
					F = fun() ->
						QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= "A"]),
						qlc:e(QH)
					end,
					{atomic, [Agent]} = mnesia:transaction(F),
					?assertEqual(supervisor, Agent#agent_auth.securitylevel),
					destroy("A")
				end
			},
			{
				"Cache a user with default security level",
				fun() ->
					cache("A", util:bin_to_hexstr(erlang:md5("B")), "Default", agent),
					F = fun() ->
						QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= "A"]),
						qlc:e(QH)
					end,
					{atomic, [Agent]} = mnesia:transaction(F),
					?assertEqual(agent, Agent#agent_auth.securitylevel),
					destroy("A")
				end
			},
			{
				"Add a user bypassing the cache",
				fun() ->
					?assertEqual({atomic, ok}, add_agent("A", "Pass", [testskill], agent, "Default")),
					Salt = "12345",
					SaltedPassword = salt(erlang:md5("Pass"), Salt),
					?assertMatch({allow, ['_agent', '_node', testskill], agent, "Default"}, local_auth("A", SaltedPassword, Salt)),
					destroy("A")
				end
			},
			{
				"Auth a user 'A'",
				fun() -> 
					cache("A", erlang:md5("B"), "Default", agent),
					Salt = "12345",
					SaltedPassword = salt(erlang:md5("B"), Salt),
					?assertMatch({allow, ['_agent', '_node'], agent, "Default"}, local_auth("A", SaltedPassword, Salt)),
					destroy("A"),
					?assertMatch(deny, local_auth("A", util:bin_to_hexstr(erlang:md5(integer_to_list(5) ++ erlang:md5("B"))), "5"))
				end
			},
			{
				"auth a user using auth",
				fun() ->
					cache("A", erlang:md5("B"), "Default", agent),
					Salt = "12345",
					SaltedPassword = salt(erlang:md5("B"), Salt),
					?assertMatch({allow, ['_agent', '_node'], agent, "Default"}, auth("A", SaltedPassword, Salt)),
					destroy("A"),
					?assertMatch(deny, local_auth("A", util:bin_to_hexstr(erlang:md5(integer_to_list(5) ++ erlang:md5("B"))), "5"))
				end
			},
			{
				"Auth a user 'A' with integer_to_list(salt)",
				fun() -> 
					cache("A", erlang:md5("B"), "Default", agent),
					Salt = 123,
					SaltedPassword = salt(erlang:md5("B"), integer_to_list(Salt)),
					?assertMatch({allow, ['_agent', '_node'], agent, "Default"}, local_auth("A", SaltedPassword, integer_to_list(Salt))),
					destroy("A"),
					?assertMatch(deny, local_auth("A", SaltedPassword, integer_to_list(Salt)))
				end
			},{
				"Deny a user",
				fun() ->
					cache("A", erlang:md5("B"), "Default", agent),
					Salt = 123,
					SaltedPassword = salt(erlang:md5("wrongpass"), integer_to_list(Salt)),
					?assertEqual(deny, local_auth("A", SaltedPassword, integer_to_list(Salt))),
					destroy("A")
				end
			},
			{
				"Destroy a user 'A'",
				fun() -> 
					cache("A", "B", "Default", agent),
					destroy("A"),
					F = fun() -> 
						Pass = erlang:md5("B"),
						QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= "A", X#agent_auth.password =:= util:bin_to_hexstr(Pass)]),
						qlc:e(QH)
					end,
					?assertMatch({atomic, []}, mnesia:transaction(F))
				end
			}
		]
	}.

%% @hidden
mock_start_success("mock1", "mock2") ->
	{ok, self()}.

%% @hidden
mock_start_failure("mock1", "mock2") ->
	{error, invalid}.

%% @hidden
mock_auth_success(_Username, _Password, _Nonce, "mock1", "mock2") ->
	?CONSOLE("~p", [util:bin_to_hexstr(erlang:md5("password"))]),
	{allow, util:bin_to_hexstr(erlang:md5("password")), "Default", agent}.

%% @hidden
mock_auth_deny(_Username, _Password, _Nonce, "mock1", "mock2") ->
	deny.

%% @hidden
mock_auth_error(_Username, _Password, _Nonce, "mock1", "mock2") ->
	{error, invalid}.

mock_integration_test_() ->
	{
		foreach,
		fun() ->
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			build_tables()
		end,
		fun(_) -> 
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			{
				"Integration starts correctly",
				fun() ->
					?assertMatch({ok, _Pid}, start(?MODULE, mock_start_success, ["mock1", "mock2"], mock_auth_success, ["mock1", "mock2"])),
					stop()
				end
			},
			{
				"Integration fails to start",
				fun() ->
					% this test is for current (2009/03/04) implementation; TODO - do we really just want to ignore this failure?
					?assertMatch({ok, _Pid}, start(?MODULE, mock_start_failure, ["mock1", "mock2"], mock_auth_success, ["mock1", "mock2"])),
					stop()
				end
			},
			{
				"Integration success, and thus caches a user",
				fun() ->
					start(?MODULE, mock_start_success, ["mock1", "mock2"], mock_auth_success, ["mock1", "mock2"]),
					?assertEqual(deny, local_auth("A", salt(erlang:md5("password"), "1234"), "1234")),
					?assertEqual({allow, ['_agent', '_node'], agent, "Default"}, auth("A", "password", "1234")),
					?assertEqual({allow, ['_agent', '_node'], agent, "Default"}, local_auth("A", salt(erlang:md5("password"), "1234"), "1234")),
					destroy("A"),
					stop()
				end
			},
			{
				"Integration deny, thus user is not cached",
				fun() ->
					start(?MODULE, mock_start_success, ["mock1", "mock2"], mock_auth_deny, ["mock1", "mock2"]),
					?assertEqual(deny, auth("A", "password", "1234")),
					?assertEqual(deny, local_auth("A", salt(erlang:md5("password"), "1234"), "1234")),
					stop()
				end
			},
			{
				"Integration deny, falling user is removed from cache",
				fun() ->
					start(?MODULE, mock_start_success, ["mock1", "mock2"], mock_auth_deny, ["mock1", "mock2"]),
					cache("A", erlang:md5("password"), "Default", agent),
					?assertMatch({allow, _Skills, agent, "Default"}, local_auth("A", salt(erlang:md5("password"), "1234"), "1234")),
					auth("A", "password", "1234"),
					?assertEqual(deny, local_auth("A", salt(erlang:md5("password"), "1234"), "1234")),
					stop()
				end
			},
			{
				"Integration error, falling back to local cache",
				fun() ->
					start(?MODULE, mock_start_success, ["mock1", "mock2"], mock_auth_error, ["mock1", "mock2"]),
					cache("A", erlang:md5("password"), "Default", agent),
					?assertMatch({allow, _Skills, agent, "Default"}, auth("A", salt(erlang:md5("password"), "1234"), "1234")),
					stop()
				end
			}
		]
	}.

release_opt_test_() ->
	{
		foreach,
		fun() ->
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			build_tables()
		end,
		fun(_) -> 
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			{
				"Add new release option",
				fun() ->
					Releaseopt = #release_opt{label = "testopt", id = 500, bias = 1},
					new_release(Releaseopt),
					F = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "testopt"]),
						qlc:e(Select)
					end,
					?assertEqual({atomic, [Releaseopt]}, mnesia:transaction(F))
				end
			},
			{
				"Destroy a release option",
				fun() ->
					Releaseopt = #release_opt{label = "testopt", id = 500, bias = 1},
					new_release(Releaseopt),
					destroy_release("testopt"),
					F = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "testopt"]),
						qlc:e(Select)
					end,
					?assertEqual({atomic, []}, mnesia:transaction(F))
				end
			},
			{
				"Update a release option",
				fun() ->
					Oldopt = #release_opt{label = "oldopt", id = 500, bias = 1},
					Newopt = #release_opt{label = "newopt", id = 500, bias = 1},
					new_release(Oldopt),
					update_release("oldopt", Newopt),
					Getold = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "oldopt"]),
						qlc:e(Select)
					end,
					Getnew = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "newopt"]),
						qlc:e(Select)
					end,
					?assertEqual({atomic, []}, mnesia:transaction(Getold)),
					?assertEqual({atomic, [Newopt]}, mnesia:transaction(Getnew))
				end
			},
			{
				"Get all release options",
				fun() ->
					Aopt = #release_opt{label = "aoption", id = 300, bias = 1},
					Bopt = #release_opt{label = "boption", id = 200, bias = 1},
					Copt = #release_opt{label = "coption", id = 100, bias = -1},
					new_release(Copt),
					new_release(Bopt),
					new_release(Aopt),
					?assertEqual([Aopt, Bopt, Copt], get_releases())
				end
			}
		]
	}.

profile_test_() ->
	{
		foreach,
		fun() ->
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			build_tables()
		end,
		fun(_) -> 
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			{
				"Add a profile",
				fun() ->
					F = fun() ->
						QH = qlc:q([X || X <- mnesia:table(agent_profile), X#agent_profile.name =:= "test profile"]),
						qlc:e(QH)
					end,
					?assertEqual({atomic, []}, mnesia:transaction(F)),
					?assertEqual({atomic, ok}, new_profile("test profile", [testskill])),
					Test = #agent_profile{name = "test profile", skills = [testskill]},
					?assertEqual({atomic, [Test]}, mnesia:transaction(F))
				end
			},
			{
				"Update a profile",
				fun() ->
					new_profile("inital", [english]),
					set_profile("initial", "new", [german]),
					?assertEqual(undefined, get_profile("initial")),
					?assertEqual({"new", [german]}, get_profile("new"))
				end
			},
			{
				"Remove a profile",
				fun() ->
					F = fun() ->
						QH = qlc:q([X || X <- mnesia:table(agent_profile), X#agent_profile.name =:= "test profile"]),
						qlc:e(QH)
					end,
					new_profile("test profile", [english]),
					?assertEqual({atomic, [#agent_profile{name = "test profile", skills=[english]}]}, mnesia:transaction(F)),
					?assertEqual({atomic, ok}, destroy_profile("test profile")),
					?assertEqual({atomic, []}, mnesia:transaction(F))
				end
			},
			{
				"Get a profile",
				fun() ->
					?assertEqual(undefined, get_profile("noexists")),
					new_profile("test profile", [testskill]),
					?assertEqual({"test profile", [testskill]}, get_profile("test profile"))
				end
			},
			{
				"Get all profiles",
				fun() ->
					new_profile("B", [german]),
					new_profile("A", [english]),
					new_profile("C", [testskill]),
					F = fun() ->
						mnesia:delete({agent_profile, "Default"})
					end,
					mnesia:transaction(F),
					?CONSOLE("profs:  ~p", [get_profiles()]),
					?assertEqual([{"A", [english]}, {"B", [german]}, {"C", [testskill]}], get_profiles())
				end
			}
		]
	}.
	
-define(MYSERVERFUNC, 
	fun() -> 
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables(),
		{ok, _Pid} = start_link(), 
		{?MODULE, fun() -> stop() end} 
	end).

-include("gen_server_test.hrl").


-endif.
