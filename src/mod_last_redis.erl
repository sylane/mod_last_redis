%% ===========================================================================
%% @doc REDIS backed ejabberd module implementing xmpp's last activity
%% extension XEP-0012.
%%
%% Based on mod_last.erl written by Alexey Shchepin <alexey@process-one.net>.
%%
%% It is using the redo library from Jacob Vorreuter:
%%
%%      https://github.com/JacobVorreuter/redo.git.
%%
%% As for mod_last_odbc, some web screen do not shows last activity properly
%% when using mod_last_redis:
%%
%%      https://support.process-one.net/browse/EJAB-6.
%%
%% @see http://xmpp.org/extensions/xep-0012.html
%% @see http://redis.io
%% @see https://github.com/JacobVorreuter/redo
%%
%% @since      Mar 09, 2012
%% @version    1.0
%% @copyright  2012, Sebastien Merle <s.merle@gmail.com>
%% @author     Sebastien Merle <s.merle@gmail.com>
%% @end
%%
%% Copyright (c) 2012, Sebastien Merle <s.merle@gmail.com>
%% All rights reserved.
%%
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%% ===========================================================================

-module(mod_last_redis).

-author('Sebastien Merle <s.merle@gmail.com>').

-behaviour(gen_mod).


%% --------------------------------------------------------------------
%% Includes
%% --------------------------------------------------------------------

-include("jlib.hrl").

-include("ejabberd.hrl").

-include("mod_privacy.hrl").


%% --------------------------------------------------------------------
%% Exports
%% --------------------------------------------------------------------

% API exports
-export([store_last_info/4,
         get_last_info/2]).

% gen_mod callbacks
-export([start/2,
         stop/1]).

        
% iq handlers
-export([process_local_iq/3,
         process_sm_iq/3]).

% hooks callbacks
-export([on_presence_update/4,
         remove_user/2]).


%% --------------------------------------------------------------------
%% Macros
%% --------------------------------------------------------------------

-define(REDO_PROCNAME, mod_last_redis_redo).


%% --------------------------------------------------------------------
%% API Functions
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% @spec get_last_info(User::string(), Server::string()) ->
%%           {ok, TimeStamp::pos_integer(), Status::string()} | not_found
%%
%% @doc Retrieves the specified user's last status from the data store.
%% @see mode_last:get_last_info/2

-spec get_last_info(User::string(), Server::string()) ->
          {ok, TimeStamp::pos_integer(), Status::string()} | not_found.

get_last_info(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    case get_last_info_(LUser, LServer) of
        {error, _Reason} -> not_found;
        Res -> Res
    end.


%% --------------------------------------------------------------------
%% @spec store_last_info(User::string(), Server::string(),
%%                       TimeStamp::pos_integer(), Status::string()) -> ok
%%
%% @doc Updates specified user's last status information in the data store. 
%% @see mode_last:store_last_info/4

-spec store_last_info(User::string(), Server::string(),
                      TimeStamp::pos_integer(), Status::string()) -> ok.

store_last_info(User, Server, TimeStamp, Status) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    store_last_info_(LUser, LServer, TimeStamp, Status).


%% --------------------------------------------------------------------
%% gen_mod Callback Functions
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% @spec start(Host::string(), Opts::term()) -> ok
%%
%% @doc Starts the module implementing redis backed last activity queries.

-spec start(Host::string(), Opts::term()) -> ok.

start(Host, Opts) ->
    {ok, _Pid} = start_redo_(Host), % ensure started    
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_LAST,
				  ?MODULE, process_local_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_LAST,
				  ?MODULE, process_sm_iq, IQDisc),
    ejabberd_hooks:add(remove_user, Host,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(unset_presence_hook, Host,
		       ?MODULE, on_presence_update, 50),
    ok.


%% --------------------------------------------------------------------
%% @spec stop(Host::string()) -> ok
%%
%% @doc Stops the module implementing redis backed last activity queries.

-spec stop(Host::string()) -> ok.

stop(Host) ->
    stop_redo_(Host),
    ejabberd_hooks:delete(remove_user, Host,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(unset_presence_hook, Host,
			  ?MODULE, on_presence_update, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_LAST),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_LAST),
    ok.


%% --------------------------------------------------------------------
%% IQ Handlers Functions
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% @spec process_local_iq(From, To, IQ) -> IQ
%% where From = To = #jid{}
%%       IQ = #iq{}
%%
%% @doc Processes IQ stanzas with namespace jabber:iq:last addressed
%% to the server itself, used to query the node uptime.
%% @see mode_last:process_local_iq/3

-spec process_local_iq(From::#jid{}, To::#jid{}, IQ::#iq{}) -> #iq{}.

process_local_iq(_From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    case Type of
	set ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
	get ->
	    Sec = get_node_uptime(),
	    IQ#iq{type = result,
		  sub_el =  [{xmlelement, "query",
			      [{"xmlns", ?NS_LAST},
			       {"seconds", integer_to_list(Sec)}],
			      []}]}
    end.


%% --------------------------------------------------------------------
%% @spec get_node_uptime() -> integer()
%%
%% @doc Get the uptime of the ejabberd node, expressed in seconds.
%% When ejabberd is starting, ejabberd_config:start/0 stores the datetime.
%% @see mod_last:get_node_uptime/0

-spec get_node_uptime() -> pos_integer().

get_node_uptime() ->
    case ejabberd_config:get_local_option(node_start) of
	{_, _, _} = StartNow ->
	    now_to_seconds(now()) - now_to_seconds(StartNow);
	_undefined ->
	    trunc(element(1, erlang:statistics(wall_clock))/1000)
    end.

%% --------------------------------------------------------------------
%% @see mod_last:now_to_seconds/0

now_to_seconds({MegaSecs, Secs, _MicroSecs}) ->
    MegaSecs * 1000000 + Secs.


%% --------------------------------------------------------------------
%% @spec process_sm_iq(From, To, IQ) -> IQ
%% where From = To = #jid{}
%%       IQ = #iq{}
%%
%% @doc Processes all other IQ stanzas with namespace jabber:iq:last,
%% verifies the user is authorized to access the contact presence information.
%% @see mode_last:process_sm_iq/3

-spec process_sm_iq(From::#jid{}, To::#jid{}, IQ::#iq{}) -> #iq{}.

process_sm_iq(From, To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    case Type of
	set ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
	get ->
	    User = To#jid.luser,
	    Server = To#jid.lserver,
	    {Subscription, _Groups} =
		ejabberd_hooks:run_fold(
		  roster_get_jid_info, Server,
		  {none, []}, [User, Server, From]),
	    if
		(Subscription == both) or (Subscription == from)
		or ((From#jid.luser == To#jid.luser)
		    and (From#jid.lserver == To#jid.lserver)) ->
		    UserListRecord = ejabberd_hooks:run_fold(
				       privacy_get_user_list, Server,
				       #userlist{},
				       [User, Server]),
		    case ejabberd_hooks:run_fold(
			   privacy_check_packet, Server,
			   allow,
			   [User, Server, UserListRecord,
			    {To, From,
			     {xmlelement, "presence", [], []}},
			    out]) of
			allow ->
			    get_last_iq(IQ, SubEl, User, Server);
			deny ->
			    IQ#iq{type = error,
				  sub_el = [SubEl, ?ERR_FORBIDDEN]}
		    end;
		true ->
		    IQ#iq{type = error,
			  sub_el = [SubEl, ?ERR_FORBIDDEN]}
	    end
    end.


%% --------------------------------------------------------------------
%% @spec get_last_iq(IQ::#iq{}, SubEl::term(),
%%                   LUser::string(), LServer::string()) -> #iq{}
%%
%% @doc Returns an IQ result with the last status of specified contact.
%% If the contact do not have active resources, it queries the data store
%% to retrieve the last status, otherwise it responde on his behalf with
%% the last known status.
%% @see mod_last:get_last_iq/4 

-spec get_last_iq(IQ::#iq{}, SubEl::term(),
                  LUser::string(), LServer::string()) -> #iq{}.

get_last_iq(IQ, SubEl, LUser, LServer) ->
    case ejabberd_sm:get_user_resources(LUser, LServer) of
	[] ->
	    case get_last_info_(LUser, LServer) of
		{error, _Reason} ->
		    IQ#iq{type = error, sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]};
		not_found ->
		    IQ#iq{type = error, sub_el = [SubEl, ?ERR_SERVICE_UNAVAILABLE]};
		{ok, TimeStamp, Status} ->
		    TimeStamp2 = now_to_seconds(now()),
		    Sec = TimeStamp2 - TimeStamp,
		    IQ#iq{type = result,
			  sub_el = [{xmlelement, "query",
				     [{"xmlns", ?NS_LAST},
				      {"seconds", integer_to_list(Sec)}],
				     [{xmlcdata, Status}]}]}
	    end;
	_ ->
	    IQ#iq{type = result,
		  sub_el = [{xmlelement, "query",
			     [{"xmlns", ?NS_LAST},
			      {"seconds", "0"}],
			     []}]}
    end.


%% --------------------------------------------------------------------
%% Hook Callbacks
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% @spec on_presence_update(User::string(), Server::string(),
%%                          Resource::string(), Status::string()) -> ok.
%%
%% @doc Updates the presence information in the data store. 
%% @see mod_last:on_presence_update/4

-spec on_presence_update(User::string(), Server::string(),
                         Resource::string(), Status::string()) -> ok.

on_presence_update(User, Server, _Resource, Status) ->
    TimeStamp = now_to_seconds(now()),
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    store_last_info_(LUser, LServer, TimeStamp, Status).


%% --------------------------------------------------------------------
%% @spec remove_user(User::string(), Server::string()) -> ok.
%%
%% @doc Removes the presence information from the data store
%% when a user is removed. 
%% @see mod_last:on_presence_update/4

-spec remove_user(User::string(), Server::string()) -> ok.

remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),    
    remove_user_(LUser, LServer).


%% --------------------------------------------------------------------
%% Redis Specific Functions
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% @spec start_redo_(Host::string()) -> {ok, pid()} | {error, term()}
%%
%% @doc Starts and links the redo process as a child to ejabberd supervisor.

-spec start_redo_(Host::string()) -> {ok, pid()} | {error, term()}.

start_redo_(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?REDO_PROCNAME),
    ChildSpec = {Proc, {redo, start_link, [?REDO_PROCNAME]},
                 permanent, 1000, worker, [redo]},
    supervisor:start_child(ejabberd_sup, ChildSpec).


%% --------------------------------------------------------------------
%% @spec stop_redo_(Host::string()) -> ok
%%
%% @doc Stops and remove the redo process from ejabberd supervisor.

-spec stop_redo_(Host::string()) -> ok.

stop_redo_(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?REDO_PROCNAME),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc),
    ok.


%% --------------------------------------------------------------------
%% @spec get_last_info_(LUser::string(), LServer::string()) ->
%%         not_found | {error, term()} | {ok, pos_integer(), string()}
%%
%% @doc Retrieves the last information of specified user from
%% the local redis data store.

-spec get_last_info_(LUser::string(), LServer::string()) ->
          not_found | {error, term()} | {ok, pos_integer(), string()}.

get_last_info_(LUser, LServer) ->
    Key = LUser ++ [$@ |LServer],
    case redo:cmd(?REDO_PROCNAME, ["GET", Key]) of
        undefined ->
            not_found;
        {error, Reason} ->
            ?ERROR_MSG("Failed to retrieve value for key ~s: ~w.",
                       [Key, Reason]),
            {error, Reason};
        <<TimeStamp:32/unsigned-little-integer,BinStatus/binary>> ->
            {ok, TimeStamp, binary_to_list(BinStatus)};
        Value ->
            ?ERROR_MSG("Invalid value format for key ~s: ~w.", [Key, Value]),
            {error, bad_value_format}
    end.


%% --------------------------------------------------------------------
%% @spec store_last_info_(LUser::string(), LServer::string(),
%%                        TimeStamp::pos_integer(), Status::string()) -> ok
%%
%% @doc Stores the last information of specified user to
%% the local redis data store.

-spec store_last_info_(LUser::string(), LServer::string(),
                       TimeStamp::pos_integer(), Status::string()) -> ok.

store_last_info_(LUser, LServer, TimeStamp, Status) ->
    Key = LUser ++ [$@ |LServer],
    BinStatus = list_to_binary(Status),
    Value = <<TimeStamp:32/unsigned-little-integer,BinStatus/binary>>,
    case redo:cmd(?REDO_PROCNAME, ["SET", Key, Value]) of
        <<"OK">> -> ok;
        {error, Reason} ->
            ?ERROR_MSG("Failed to store value ~w for key ~s: ~w.",
                       [Value, Key, Reason]),
            ok; % no errors expected
        Result ->
            ?ERROR_MSG("Unexpected result when storing value "
                       "~w for key ~s: ~w.", [Value, Key, Result]),
            ok % no errors expected
    end.


%% --------------------------------------------------------------------
%% @spec remove_user_(LUser::string(), LServer::string()) -> ok
%%
%% @doc Removes the last information of specified user from the local
%% redis data store.

-spec remove_user_(LUser::string(), LServer::string()) -> ok.

remove_user_(LUser, LServer) ->
    Key = LUser ++ [$@ |LServer],
    case redo:cmd(?REDO_PROCNAME, ["DEL", Key]) of
        Count when is_integer(Count) -> ok;
        {error, Reason} ->
            ?ERROR_MSG("Failed to delete key ~s: ~w.", [Key, Reason]),
            ok; % no errors expected
        Result ->
            ?ERROR_MSG("Unexpected result when deleting key ~s: ~w.",
                       [Key, Result]),
            ok % no errors expected
    end.
