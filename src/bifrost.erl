%%%-------------------------------------------------------------------
%%% File    : bifrost.erl
%%% Author  : Ryan Crum <ryan@ryancrum.org>
%%% Description : Pluggable FTP Server gen_server
%%%-------------------------------------------------------------------

-module(bifrost).

-behaviour(gen_server).
-include("bifrost.hrl").

-ifdef(TEST).
-compile(export_all).
-else.
-export([
         start_link/2,
         establish_control_connection/2,
         await_connections/2,
         supervise_connections/2
        ]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).
-endif. %% TEST

-define(MAX_TCPIP_PORT, 65535).

start_link(HookModule, Opts) ->
    gen_server:start_link(?MODULE, [HookModule, Opts], []).

%% gen_server callbacks implementation
init([HookModule, Opts]) ->
    try
        DefState = #connection_state{module=HookModule},
        Port = proplists:get_value(port, Opts, 21),
        SslMode = case proplists:get_value(ssl, Opts, DefState#connection_state.ssl_mode) of
                      disabled -> disabled;
                      false -> disabled; % legacy
                      Mode when Mode == enabled;
                                Mode == only;
                                Mode == true ->
                          % is SSL module started?
                          case lists:any(fun({ssl,_,_})->true;(_A)->false end, application:which_applications()) of
                              true ->
                                  if true == Mode -> enabled; true -> Mode end;
                              false ->
                                  throw({stop, ssl_not_started})
                          end
                  end,
        SslKey = proplists:get_value(ssl_key, Opts),
        SslCert = proplists:get_value(ssl_cert, Opts),
        CaSslCert = proplists:get_value(ca_ssl_cert, Opts),
        UTF8 = proplists:get_value(utf8, Opts, DefState#connection_state.utf8),
        RecvBlockSize = proplists:get_value(recv_block_size, Opts, DefState#connection_state.recv_block_size),
        SendBlockSize = proplists:get_value(recv_block_size, Opts, DefState#connection_state.send_block_size),

        ControlTimeout = proplists:get_value(control_timeout, Opts, DefState#connection_state.control_timeout),

        PortRange = case proplists:get_value(port_range, Opts, DefState#connection_state.port_range) of
                        0 -> 0;
                        1 -> 0;
                        {0, ?MAX_TCPIP_PORT} -> 0;
                        {1, ?MAX_TCPIP_PORT} -> 0;
                        N when is_integer(N), N>=0, ?MAX_TCPIP_PORT>=N ->
                            {N, ?MAX_TCPIP_PORT};
                        {N,M} when is_integer(N), N>=0, ?MAX_TCPIP_PORT>=N andalso
                                   is_integer(M), M>=0, ?MAX_TCPIP_PORT>=M, M>=N ->
                            {N, M};
                        _AnotherValue ->
                            throw({stop, lists:flatten(io_lib:format("Invalid port_range ~p", [_AnotherValue]))})
                    end,
        case listen_socket(Port, [{active, false}, {reuseaddr, true}, list]) of
            {ok, Listen} ->
                IpAddress = proplists:get_value(ip_address, Opts, get_socket_addr(Listen)),
                InitialState = DefState#connection_state{ip_address = IpAddress,
                                                         ssl_mode = SslMode,
                                                         ssl_key = SslKey,
                                                         ssl_cert = SslCert,
                                                         ssl_ca_cert = CaSslCert,
                                                         utf8 = UTF8,
                                                         recv_block_size = RecvBlockSize,
                                                         send_block_size = SendBlockSize,
                                                         control_timeout = ControlTimeout,
                                                         port_range = PortRange},
                Self = self(),
                Supervisor = proc_lib:spawn_link(?MODULE,
                                                 supervise_connections,
                                                 [Self, HookModule:init(InitialState, Opts)]),
                proc_lib:spawn_link(?MODULE,
                                    await_connections,
                                    [Listen, Supervisor]),
                HookModule:clean_alarm(),
                {ok, {listen_socket, Listen}};
            {error, Error} ->
                error_logger:error_report({bifrost, init_error, Error}),
                HookModule:set_alarm(Error),
                ignore
        end
    catch
        _Type0:{stop, Reason} ->
            error_logger:error_report({bifrost, init_error, Reason}),
            HookModule:set_alarm(Reason),
            ignore;
        _Type1:Exception ->
            error_logger:error_report({bifrost, init_exception, Exception}),
            HookModule:set_alarm(Exception),
            ignore
    end.

%-------------------------------------------------------------------------------

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, {listen_socket, Socket}) ->
    gen_tcp:close(Socket);
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

get_socket_addr(Socket) ->
    {ok, {Addr, _Port}} = inet:sockname(Socket),
    Addr.

%-------------------------------------------------------------------------------
get_socket_port(Socket) ->
    {ok, {_Addr, Port}} = inet:sockname(Socket),
    Port.

%-------------------------------------------------------------------------------
listen_socket({Start, End}, _TcpOpts, _NextPort) when End < Start ->
    error_logger:warning_report({bifrost, listen_socket, "no free socket in range"}),
    {error, emfile};

listen_socket({Start, End}, TcpOpts, random) ->
    %% if the for [Start, End] Start<End => Start-1 < End and we have additional item for test
    listen_socket({Start-1, End}, TcpOpts, random:uniform(End-Start+1)+Start-1);

listen_socket({Start, End}, TcpOpts, TryPort) when is_integer(TryPort) ->
    case listen_socket(TryPort, TcpOpts) of
        {error, eaddrinuse} ->
            listen_socket({Start+1, End}, TcpOpts, Start+1);
            Another ->
                Another
    end.

listen_socket({Start, End}, TcpOpts0) ->
    %% strategy - try a random port, after it - try from start to end
    %% the assumption a lot of ports and just few connections
    TcpOpts = case proplists:get_value(reuseaddr, TcpOpts0, false) of
        true ->
            error_logger:warning_report({bifrost, listen_socket, "find free listen socket with reuseaddr"}),
            proplists:delete(reuseaddr, TcpOpts0);
        false ->
            TcpOpts0
    end,
    listen_socket({Start, End}, TcpOpts, random);
listen_socket(Port, TcpOpts) when is_integer(Port) ->
    gen_tcp:listen(Port, TcpOpts).

await_connections(Listen, Supervisor) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Supervisor ! {new_connection, self(), Socket},
            receive
                {ack, Worker} ->
                    %% ssl:ssl_accept/2 will return {error, not_owner} otherwise
                    case gen_tcp:controlling_process(Socket, Worker) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            exit(Reason)
                    end
            end;
        _Error ->
            exit(bad_accept)
    end,
    await_connections(Listen, Supervisor).

supervise_connections(ParentPid, InitialState) ->
    process_flag(trap_exit, true),
    erlang:monitor(process, ParentPid),
    connections_monitor(InitialState).

connections_monitor(InitialState) ->
    receive
        {new_connection, Acceptor, Socket} ->
            Worker = proc_lib:spawn_link(?MODULE,
                                establish_control_connection,
                                [Socket, InitialState]),
            Acceptor ! {ack, Worker},
            connections_monitor(InitialState);
        {'EXIT', _Pid, normal} -> % not a crash
            connections_monitor(InitialState);
        {'EXIT', _Pid, shutdown} -> % manual termination, not a crash
            connections_monitor(InitialState);
        {'EXIT', Pid, Info} ->
            error_logger:error_msg("Control connection ~p crashed: ~p~n", [Pid, Info]),
            connections_monitor(InitialState);
        {'DOWN', MonitorRef, process, _Object, _Info} ->
            erlang:demonitor(MonitorRef, [flush]),
            ok;
        _ ->
            connections_monitor(InitialState)
    end.

establish_control_connection(Socket, InitialState) ->
    respond({gen_tcp, Socket}, 220, "FTP Server Ready"),
    IpAddress = case InitialState#connection_state.ip_address of
                    undefined -> get_socket_addr(Socket);
                    {0, 0, 0, 0} -> get_socket_addr(Socket);
                    {0, 0, 0, 0, 0, 0} -> get_socket_addr(Socket);
                    Ip -> Ip
                end,
    control_loop(none,
                 {gen_tcp, Socket},
                 InitialState#connection_state{control_socket=Socket, ip_address=IpAddress}).

control_loop(HookPid, {SocketMod, RawSocket} = Socket, State0) ->
    case SocketMod:recv(RawSocket, 0, State0#connection_state.control_timeout) of
        {ok, Input} ->
            {Command, Options, Arg} = parse_input(Input),
            State = prev_cmd_notify(Socket, State0, done), % get a valid command => let's notify about prev
            case ftp_command(Socket, State, Command, Options, Arg) of
                {ok, NewState} ->
                    if is_pid(HookPid) ->
                            HookPid ! {new_state, self(), NewState},
                            receive
                                {ack, HookPid} ->
                                    control_loop(HookPid, Socket, NewState);
                                {done, HookPid} ->
                                    disconnect(State, {error, breaked}),
                                    {error, closed}
                            end;
                       true ->
                            control_loop(HookPid, Socket, NewState)
                    end;
                {new_socket, NewState, NewSock} ->
                    control_loop(HookPid, NewSock, NewState);
                {error, timeout} ->
                    respond(Socket, 412, "Timed out. Closing control connection."),
                    disconnect(State, {error, timeout}),
                    SocketMod:close(RawSocket),
                    {error, timeout};
                {error, closed} ->
                    disconnect(State, {error, closed}),
                    {error, closed};
                {error, auth} ->
                    disconnect(State, {error, auth}),
                    SocketMod:close(RawSocket),
                    {ok, quit};
                quit ->
                    disconnect(State, exit),
                    SocketMod:close(RawSocket),
                    {ok, quit}
            end;
        {error, timeout} ->
            NewState = prev_cmd_notify(Socket, State0, timeout),
            control_loop(HookPid, Socket, NewState);
        {error, Reason} ->
            State = prev_cmd_notify(Socket, State0, terminated),
            disconnect(State, {error, Reason}),
            error_logger:warning_report({bifrost, connection_terminated}),
            {error, Reason}
    end.

respond(Socket, ResponseCode) ->
    respond(Socket, ResponseCode, response_code_string(ResponseCode) ++ ".").

respond({SocketMod, Socket}, ResponseCode, Message) ->
    Line = integer_to_list(ResponseCode) ++ " " ++ to_utf8(Message) ++ "\r\n",
    SocketMod:send(Socket, Line).

respond_raw({SocketMod, Socket}, Line) ->
    SocketMod:send(Socket, to_utf8(Line) ++ "\r\n").

respond_feature(Socket, Name, true) ->
    respond_raw(Socket, " " ++ Name);
respond_feature(_Socket, _Name, false) ->
    ok.

ssl_options(State) ->
    [{keyfile, State#connection_state.ssl_key},
     {certfile, State#connection_state.ssl_cert},
     {cacertfile, State#connection_state.ssl_ca_cert}].

data_connection(ControlSocket, State) ->
    respond(ControlSocket, 150),
    case establish_data_connection(State) of
        {ok, DataSocket} ->
            %% switch socket's block
            case inet:setopts(DataSocket, [{recbuf, State#connection_state.recv_block_size}]) of
                ok -> ok;
                {error, Reason} ->
                    error_logger:warning_report({bifrost, data_connection_socket, Reason})
            end,
            case State#connection_state.protection_mode of
                clear ->
                    {gen_tcp, DataSocket};
                private ->
                    case ssl:ssl_accept(DataSocket,
                                        ssl_options(State)) of
                        {ok, SslSocket} ->
                            {ssl, SslSocket};
                        E ->
                            respond(ControlSocket, 425),
                            throw({error, E})
                    end
            end;
        {error, Error} ->
            respond(ControlSocket, 425),
            throw(Error)
    end.

%% passive -- accepts an inbound connection
establish_data_connection(#connection_state{pasv_listen={passive, Listen, _}}) ->
    gen_tcp:accept(Listen);

%% active -- establishes an outbound connection
establish_data_connection(#connection_state{data_port={active, Addr, Port}}) ->
    gen_tcp:connect(Addr, Port, [{active, false}, binary]).

pasv_connection(ControlSocket, State) ->
    case State#connection_state.pasv_listen of
        {passive, PasvListen, _} ->
                                                % We should only have one passive socket open at a time, so close the current one
                                                % and open a new one.
            gen_tcp:close(PasvListen),
            pasv_connection(ControlSocket, State#connection_state{pasv_listen=undefined});
        undefined ->
            case listen_socket(State#connection_state.port_range, [{active, false}, binary]) of
                {ok, Listen} ->
                    {ok, {_, Port}} = inet:sockname(Listen),
                    Port = get_socket_port(Listen),
                    Ip = State#connection_state.ip_address,
                    PasvSocketInfo = {passive,
                                      Listen,
                                      {Ip, Port}},
                    {P1,P2} = format_port(Port),
                    {S1,S2,S3,S4} = Ip,
                    respond(ControlSocket,
                            227,
                            lists:flatten(
                              io_lib:format("Entering Passive Mode (~p,~p,~p,~p,~p,~p)",
                                            [S1,S2,S3,S4,P1,P2]))),

                    {ok,
                     State#connection_state{pasv_listen=PasvSocketInfo}};
                {error, _} ->
                    respond(ControlSocket, 425),
                    {ok, State}
            end
    end.


%%-------------------------------------------------------------------------------
%% put_file (stor) need a notification - when next command arrived there is a grarantee
%% that previouse 'stor' command was executed successfully
%% so this function notify about previous command
prev_cmd_notify(_Socket, State, Notif) ->
    case State#connection_state.prev_cmd_notify of
        undefined ->
            State;
        {stor, FileName} ->
            Mod = State#connection_state.module,
            State1 = case ftp_result(State, Mod:put_file(State, FileName, notification, Notif)) of
                         {ok, NewState} ->
                             NewState;
                         {error, Reason, NewState} ->
                             error_logger:warning_report({bifrost, notify_error, Reason}),
                             NewState
                     end,
            State1#connection_state{prev_cmd_notify=undefined};
            {Command, _Arg} when is_atom(Command) ->
                %%skip valid notification for another command
                State#connection_state{prev_cmd_notify=undefined};

        Notify ->
            %%skip notify
            error_logger:warning_report({bifrost, unsupported_nofity, Notify}),
            State#connection_state{prev_cmd_notify=undefined}
    end.

%%-------------------------------------------------------------------------------
disconnect(State, Type) ->
    Mod = State#connection_state.module,
    Mod:disconnect(State, Type).

%%-------------------------------------------------------------------------------
-spec ftp_result(#connection_state{}, term()) -> term().
ftp_result(State, {error}) ->
    ftp_result(State, error);

ftp_result(State, {error, error}) ->
    ftp_result(State, error);

ftp_result(State, error) ->
    ftp_result(State, {error, State});

ftp_result(_State, {error, #connection_state{}=NewState}) ->
    {error, undef, NewState};

ftp_result(State, {error, Reason}) ->
    {error, Reason, State};

ftp_result(_State, {error, Reason, #connection_state{}=NewState}) ->
    {error, Reason, NewState};

ftp_result(_State, {error, #connection_state{}=NewState, Reason}) ->
    {error, Reason, NewState};

ftp_result(_State, Data) ->
    Data.

-spec ftp_result(#connection_state{}, term(), fun()) -> term().
ftp_result(State, Data, UserFunction) ->
    ftp_result(State, UserFunction(State, Data)).



%%-------------------------------------------------------------------------------
%% FTP COMMANDS
ftp_command(Socket, State, Command, Options, RawArg) ->
    Mod = State#connection_state.module,
    case from_utf8(RawArg, State#connection_state.utf8) of
        {error, List, _RestData} ->
            error_logger:warning_report({bifrost, invalid_utf8, List}),
            respond(Socket, 501),
            {ok, State};
        {incomplete, List, _Binary} ->
            error_logger:warning_report({bifrost, incomplete_utf8, List}),
            respond(Socket, 501),
            {ok, State};
        Arg ->
            State1 = State#connection_state{prev_cmd_notify={Command, Arg}},
            ftp_command(Mod, Socket, State1, Command, Options, Arg)
    end.

ftp_command(_Mod, Socket, _State, quit, _, _) ->
    respond(Socket, 200, "Goodbye."),
    quit;

ftp_command(_Mod, Socket, State=#connection_state{ssl_mode=disabled}, auth, _, _Arg) ->
    respond(Socket, 504),
    {ok, State};

ftp_command(_Mod, {_, RawSocket} = Socket, State, auth, _, Arg) ->
    case string:to_lower(Arg) of
        "tls" ->
            respond(Socket, 234, "Command okay."),
            case ssl:ssl_accept(RawSocket, ssl_options(State)) of
                {ok, SslSocket} ->
                    {new_socket,State#connection_state{ssl_socket=SslSocket},{ssl, SslSocket}};
                {error, Reason} ->
                    %% Command itself is executed and 234 is sent
                    %% but if issue at SSL level - just disconnect is a solution - so returns quit
                    error_logger:error_report({bifrost, ssl_accept, Reason}),
                    quit
            end;
        _Method ->
            respond(Socket, 502, "Unsupported security extension."),
            {ok, State}
    end;

ftp_command(_Mod, Socket, State, feat, _, _Arg) ->
    respond_raw(Socket, "211-Features"),
    respond_feature(Socket, "UTF8", State#connection_state.utf8),
    respond_feature(Socket, "AUTH TLS", State#connection_state.ssl_mode =/= disabled),
    respond_feature(Socket, "PROT", State#connection_state.ssl_mode =/= disabled),
    respond(Socket, 211, "End"),
    {ok, State};

ftp_command(_Mod, Socket, State, opts, _, Arg) ->
    case string:to_upper(Arg) of
        "UTF8 ON" when State#connection_state.utf8 =:= true ->
            respond(Socket, 200, "Accepted.");
        _Option ->
            respond(Socket, 501)
    end,
    {ok, State};


% Allow only commands 'QUIT', 'AUTH', 'FEAT', 'OPTS'
% for ssl_mode == only
ftp_command(_, Socket, State=#connection_state{ssl_socket=undefined, ssl_mode=only}, _, _, _) ->
    respond(Socket, 534, "Request denied for policy reasons (only ftps allowed)."),
    {ok, State};

ftp_command(_, Socket, State, pasv, _, _) ->
    pasv_connection(Socket, State);

ftp_command(_, Socket, State, prot, _, Arg) ->
    ProtMode = case string:to_lower(Arg) of
                   "c" -> clear;
                   _ -> private
               end,
    respond(Socket, 200),
    {ok, State#connection_state{protection_mode=ProtMode}};

ftp_command(_, Socket, State, pbsz, _, "0") ->
    respond(Socket, 200),
    {ok, State};

ftp_command(Mod, Socket, State, user, _, Arg) ->
    case ftp_result(State, Mod:check_user(State, Arg)) of
        {ok, NewState} ->
            respond(Socket, 331),
            {ok, NewState#connection_state{user_name=Arg, authenticated_state=unauthenticated}};

        {error, Reason, _State} ->
            error_logger:warning_report({bifrost, user_check, Reason}),
            respond(Socket, 421, format_error("Login requirements", Reason)),
            {error, auth}
    end;

ftp_command(_, Socket, State, port, _, Arg) ->
    case parse_address(Arg) of
        {ok, {Addr, Port}} ->
            respond(Socket, 200),
            {ok, State#connection_state{data_port = {active, Addr, Port}}};
        _ ->
            respond(Socket, 452, "Error parsing address.")
    end;

ftp_command(Mod, Socket, State, pass, _, Arg) ->
    case Mod:login(State, State#connection_state.user_name, Arg) of
        {true, NewState} ->
            respond(Socket, 230),
            {ok, NewState#connection_state{authenticated_state=authenticated}};
        {false, NewState} ->
            respond(Socket, 530, "Login incorrect."),
            {ok, NewState#connection_state{user_name=none, authenticated_state=unauthenticated}};
        _Quit ->
            respond(Socket, 530, "Login incorrect."),
            {error, auth}
    end;

%% ^^^ from this point down every command requires authentication ^^^

ftp_command(_, Socket, State=#connection_state{authenticated_state=unauthenticated}, _, _, _) ->
    respond(Socket, 530),
    {ok, State};

ftp_command(_, Socket, State, rein, _, _) ->
    respond(Socket, 200),
    {ok,
     State#connection_state{user_name=none,authenticated_state=unauthenticated}};

ftp_command(Mod, Socket, State, pwd, _, _) ->
    respond(Socket, 257, "\"" ++ Mod:current_directory(State) ++ "\""),
    {ok, State};

ftp_command(Mod, Socket, State, cdup, Options, _) ->
    ftp_command(Mod, Socket, State, cwd, Options, "..");

ftp_command(Mod, Socket, State, cwd, _, Arg) ->
    case ftp_result(State, Mod:change_directory(State, Arg)) of
        {ok, NewState} ->
            respond(Socket, 250, "Directory changed to \"" ++ Mod:current_directory(NewState) ++ "\"."),
            {ok, NewState};
        {error, Reason, NewState} ->
            respond(Socket, 550, format_error("Unable to change directory", Reason)),
            {ok, NewState}
    end;

ftp_command(Mod, Socket, State, mkd, _, Arg) ->
    case ftp_result(State, Mod:make_directory(State, Arg)) of
        {ok, NewState} ->
            respond(Socket, 250, "\"" ++ Arg ++ "\" directory created."),
            {ok, NewState};
        {error, Reason, NewState} ->
            respond(Socket, 550, format_error("Unable to create directory", Reason)),
            {ok, NewState}
    end;

ftp_command(Mod, Socket, State, nlst, Options, Arg) ->
    case ftp_result(State, Mod:list_files(State, Options, Arg)) of
        {error, Reason, NewState} ->
            respond(Socket, 451, format_error("Unable to list", Reason)),
            {ok, NewState};
        Files when is_list(Files)->
            DataSocket = data_connection(Socket, State),
            list_file_names_to_socket(DataSocket, Files),
            respond(Socket, 226),
            bf_close(DataSocket),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, list, Options, Arg) ->
    case ftp_result(State, Mod:list_files(State, Options, Arg)) of
        {error, Reason, NewState} ->
            respond(Socket, 451, format_error("Unable to list", Reason)),
            {ok, NewState};
        Files when is_list(Files)->
            DataSocket = data_connection(Socket, State),
            list_files_to_socket(DataSocket, Files),
            respond(Socket, 226),
            bf_close(DataSocket),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, rmd, _, Arg) ->
    case ftp_result(State, Mod:remove_directory(State, Arg)) of
        {ok, NewState} ->
            respond(Socket, 200),
            {ok, NewState};
        {error, Reason, NewState} ->
            respond(Socket, 550, format_error(550, Reason)),
             {ok, NewState}
    end;

ftp_command(_, Socket, State, syst, _, _) ->
    respond(Socket, 215, "UNIX Type: L8"),
    {ok, State};

ftp_command(Mod, Socket, State, dele, _, Arg) ->
    case ftp_result(State, Mod:remove_file(State, Arg)) of
        {ok, NewState} ->
            respond(Socket, 250), % see RFC 959
            {ok, NewState};
        {error, Reason, NewState} ->
            respond(Socket, 450, format_error("Unable to delete file", Reason)),
            {ok, NewState}
    end;

ftp_command(Mod, Socket, State, stor, _, Arg) ->
    DataSocket = data_connection(Socket, State),
    Fun = fun() ->
                  case bf_recv(DataSocket) of
                      {ok, Data} ->
                          {ok, Data, size(Data)};
                      {error, closed} ->
                          done
                  end
          end,
    RetState = case ftp_result(State, Mod:put_file(State, Arg, write, Fun)) of
                   {ok, NewState} ->
                       respond(Socket, 226),
                       NewState;
                   {error, Reason, NewState} ->
                        respond(Socket, 451, format("Error ~p when storing a file.", [Reason])),
                        NewState#connection_state{prev_cmd_notify=undefined}
               end,
    bf_close(DataSocket),
    {ok, RetState};

ftp_command(_, Socket, State, type, _, Arg) ->
    case Arg of
        "I" ->
            respond(Socket, 200);
        "A" ->
            respond(Socket, 200);
        _->
            respond(Socket, 501, "Only TYPE I or TYPE A may be used.")
    end,
    {ok, State};

ftp_command(Mod, Socket, State, site, _, Arg) ->
    [Command | Sargs] = string:tokens(Arg, " "),
    case ftp_result(State, Mod:site_command(State, list_to_atom(string:to_lower(Command)), string:join(Sargs, " "))) of
        {ok, NewState} ->
            respond(Socket, 200),
            {ok, NewState};
        {error, not_found, NewState} ->
            respond(Socket, 500),
            {ok, NewState};
        {error, Reason, NewState} ->
            respond(Socket, 501, format("Error completing command (~p).", [Reason])),
            {ok, NewState}
    end;

ftp_command(Mod, Socket, State, site_help, _, _) ->
    case ftp_result(State, Mod:site_help(State)) of
        {error, Reason, NewState} ->
            respond(Socket, 500, format_error("Unable to help site", Reason)),
            {ok, NewState};
        {ok, []} ->
            respond(Socket, 500),
            {ok, State};
        {ok, Commands} ->
            respond_raw(Socket, "214-The following commands are recognized"),
            lists:map(fun({CmdName, Descr}) ->
                          respond_raw(Socket, CmdName ++ " : " ++ Descr)
                      end,
                      Commands),
            respond(Socket, 214, "Help OK"),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, help, _, Arg) ->
    LowerArg =  string:to_lower(Arg),
    case LowerArg of
        "site" ->
            ftp_command(Mod, Socket, State, site_help, undefined, Arg);
        _ ->
            respond(Socket, 500),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, retr, _, Arg) ->
    try
        case ftp_result(State, Mod:get_file(State, Arg),
                        fun (S, {ok, Fun}) when is_function(Fun)-> {ok, Fun, S};
                            (_S, Any) -> Any end) of

            {ok, Fun, State0} ->
                DataSocket = data_connection(Socket, State0),
                case ftp_result(State0, write_fun(State0#connection_state.send_block_size, DataSocket, Fun)) of
                    {ok, NewState} ->
                        bf_close(DataSocket),
                        respond(Socket, 226),
                        {ok, NewState};

                    {error, Reason, NewState} ->
                        bf_close(DataSocket),
                        respond(Socket, 451, format_error("Unable to get file", Reason)),
                        {ok, NewState}
                end;

            {error, Reason, NewState} ->
                respond(Socket, 550, format_error("Unable to get file", Reason)),
                {ok, NewState}
        end
    catch
        Error ->
            error_logger:error_msg("~w:get_file Exception ~p", [Mod, Error]),
            respond(Socket, 550),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, mdtm, _, Arg) ->
    case ftp_result(State, Mod:file_info(State, Arg)) of
        {ok, FileInfo} ->
            respond(Socket, 213, format_mdtm_date(FileInfo#file_info.mtime)),
            {ok, State};
        {error, Reason, NewState} ->
            respond(Socket, 550, format_error(550, Reason)),
            {ok, NewState}
    end;

ftp_command(_, Socket, State, rnfr, _, Arg) ->
    respond(Socket, 350, "Ready for RNTO."),
    {ok, State#connection_state{rnfr=Arg}};

ftp_command(Mod, Socket, State, rnto, _, Arg) ->
    case State#connection_state.rnfr of
        undefined ->
            respond(Socket, 503, "RNFR not specified."),
            {ok, State};
        Rnfr ->
            case ftp_result(State, Mod:rename_file(State, Rnfr, Arg)) of
                {error, Reason, NewState} ->
                    respond(Socket, 550, io_lib:format("Unable to rename (~p).", [Reason])),
                    {ok, NewState};
                {ok, NewState} ->
                    respond(Socket, 250, "Rename successful."),
                    {ok, NewState#connection_state{rnfr=undefined}}
            end
    end;

ftp_command(Mod, Socket, State, xcwd, Options, Arg) ->
    ftp_command(Mod, Socket, State, cwd, Options, Arg);

ftp_command(Mod, Socket, State, xcup, Options, Arg) ->
    ftp_command(Mod, Socket, State, cdup, Options, Arg);

ftp_command(Mod, Socket, State, xmkd, Options, Arg) ->
    ftp_command(Mod, Socket, State, mkd, Options, Arg);

ftp_command(Mod, Socket, State, xpwd, Options, Arg) ->
    ftp_command(Mod, Socket, State, pwd, Options, Arg);

ftp_command(Mod, Socket, State, xrmd, Options, Arg) ->
    ftp_command(Mod, Socket, State, rmd, Options, Arg);

ftp_command(_Mod, Socket, State, size, _, _Arg) ->
    respond(Socket, 550),
    {ok, State};

ftp_command(_, Socket, State, Command, _, _Arg) ->
    error_logger:warning_report({bifrost, unrecognized_command, Command}),
    respond(Socket, 500),
    {ok, State}.

write_fun(SendBlockSize,Socket, Fun) ->
    case Fun(SendBlockSize) of
        {ok, Bytes, NextFun} ->
            bf_send(Socket, Bytes),
            write_fun(SendBlockSize, Socket, NextFun);
        {done, NewState} ->
            {ok, NewState};
        Another -> % errors and etc
            Another
    end.

strip_newlines(S) ->
    lists:foldr(fun(C, A) ->
                        string:strip(A, right, C) end,
                S,
                "\r\n").

parse_input(Input) ->
    [Command | Other] = string:tokens(Input, " "),
    %% [Command | Args] = lists:map(fun(S) -> strip_newlines(S) end,
    %%                              Tokens),
    Fun = fun
              ([$-|Option], {OptsAcc, ArgsAcc}) ->
                  {[strip_newlines(Option)|OptsAcc], ArgsAcc};
              (Item, {OptsAcc, ArgsAcc}) ->
                  {OptsAcc, [strip_newlines(Item)|ArgsAcc]}
          end,
    {Options, Args} = lists:foldl(Fun, {[], []}, Other),
    {list_to_atom(string:to_lower(strip_newlines(Command))), lists:reverse(Options), string:join(lists:reverse(Args), " ")}.

list_files_to_socket(DataSocket, Files) ->
    lists:map(fun(Info) ->
                      bf_send(DataSocket,
                              to_utf8(file_info_to_string(Info)) ++ "\r\n") end,
              Files),
    ok.

list_file_names_to_socket(DataSocket, Files) ->
    lists:map(fun(Info) ->
                      bf_send(DataSocket,
                      to_utf8(Info#file_info.name) ++ "\r\n") end,
              Files),
    ok.

bf_send({SockMod, Socket}, Data) ->
    SockMod:send(Socket, Data).

bf_close({SockMod, Socket}) ->
    SockMod:close(Socket).

bf_recv({SockMod, Socket}) ->
    SockMod:recv(Socket, 0, infinity).

%% Adapted from jungerl/ftpd.erl
response_code_string(110) -> "MARK yyyy = mmmm";
response_code_string(120) -> "Service ready in nnn minutes";
response_code_string(125) -> "Data connection alredy open; transfere starting";
response_code_string(150) -> "File status okay; about to open data connection";
response_code_string(200) -> "Command okay";
response_code_string(202) -> "Command not implemented, superfluous at this site";
response_code_string(211) -> "System status, or system help reply";
response_code_string(212) -> "Directory status";
response_code_string(213) -> "File status";
response_code_string(214) -> "Help message";
response_code_string(215) -> "UNIX system type";
response_code_string(220) -> "Service ready for user";
response_code_string(221) -> "Service closing control connection";
response_code_string(225) -> "Data connection open; no transfere in progress";
response_code_string(226) -> "Closing data connection";
response_code_string(227) -> "Entering Passive Mode (h1,h2,h3,h4,p1,p2)";
response_code_string(230) -> "User logged in, proceed";
response_code_string(250) -> "Requested file action okay, completed";
response_code_string(257) -> "PATHNAME created";
response_code_string(331) -> "User name okay, need password";
response_code_string(332) -> "Need account for login";
response_code_string(350) -> "Requested file action pending further information";
response_code_string(421) -> "Service not available, closing control connection";
response_code_string(425) -> "Can't open data connection";
response_code_string(426) -> "Connection closed; transfere aborted";
response_code_string(450) -> "Requested file action not taken";
response_code_string(451) -> "Requested action not taken: local error in processing";
response_code_string(452) -> "Requested action not taken";
response_code_string(500) -> "Syntax error, command unrecognized";
response_code_string(501) -> "Syntax error in parameters or arguments";
response_code_string(502) -> "Command not implemented";
response_code_string(503) -> "Bad sequence of commands";
response_code_string(504) -> "Command not implemented for that parameter";
response_code_string(530) -> "Not logged in";
response_code_string(532) -> "Need account for storing files";
response_code_string(550) -> "Requested action not taken";
response_code_string(551) -> "Requested action aborted: page type unkown";
response_code_string(552) -> "Requested file action aborted";
response_code_string(553) -> "Requested action not taken";
response_code_string(_) -> "N/A".

%% Taken from jungerl/ftpd

file_info_to_string(Info) ->
    format_type(Info#file_info.type) ++
        format_access(Info#file_info.mode) ++ " " ++
        format_number(type_num(Info#file_info.type), 2, $ ) ++ " " ++
        format_number(Info#file_info.uid,5,$ ) ++ " " ++
        format_number(Info#file_info.gid,5,$ ) ++ " "  ++
        format_number(Info#file_info.size,8,$ ) ++ " " ++
        format_date(Info#file_info.mtime) ++ " " ++
        Info#file_info.name.

format_mdtm_date({{Year, Month, Day}, {Hours, Mins, Secs}}) ->
    lists:flatten(io_lib:format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
                                [Year, Month, Day, Hours, Mins, erlang:trunc(Secs)])).

format_date({Date, Time}) ->
    {Year, Month, Day} = Date,
    {Hours, Min, _} = Time,
    {LDate, _LTime} = calendar:local_time(),
    {LYear, _, _} = LDate,
    format_month_day(Month, Day) ++
        if LYear > Year ->
                format_year(Year);
           true ->
                format_time(Hours, Min)
        end.

format_month_day(Month, Day) ->
    io_lib:format("~s ~2.2w", [month(Month), Day]).

format_year(Year) ->
    io_lib:format(" ~5.5w", [Year]).

format_time(Hours, Min) ->
    io_lib:format(" ~2.2.0w:~2.2.0w", [Hours, Min]).

format_type(file) -> "-";
format_type(dir) -> "d";
format_type(_) -> "?".

type_num(file) ->
    1;
type_num(dir) ->
    4;
type_num(_) ->
    0.

format_access(Mode) ->
    format_rwx(Mode bsr 6) ++ format_rwx(Mode bsr 3) ++ format_rwx(Mode).

format_rwx(Mode) ->
    [if Mode band 4 == 0 -> $-; true -> $r end,
     if Mode band 2 == 0 -> $-; true -> $w end,
     if Mode band 1 == 0 -> $-; true -> $x end].

format_number(X, N, LeftPad) when X >= 0 ->
    Ls = integer_to_list(X),
    Len = length(Ls),
    if Len >= N -> Ls;
       true ->
            lists:duplicate(N - Len, LeftPad) ++ Ls
    end.

month(1) -> "Jan";
month(2) -> "Feb";
month(3) -> "Mar";
month(4) -> "Apr";
month(5) -> "May";
month(6) -> "Jun";
month(7) -> "Jul";
month(8) -> "Aug";
month(9) -> "Sep";
month(10) -> "Oct";
month(11) -> "Nov";
month(12) -> "Dec".

%% parse address on form:
%% d1,d2,d3,d4,p1,p2  => { {d1,d2,d3,d4}, port} -- ipv4
%% h1,h2,...,h32,p1,p2 => {{n1,n2,..,n8}, port} -- ipv6
%% Taken from jungerl/ftpd
parse_address(Str) ->
    paddr(Str, 0, []).

paddr([X|Xs],N,Acc) when X >= $0, X =< $9 -> paddr(Xs, N*10+(X-$0), Acc);
paddr([X|Xs],_N,Acc) when X >= $A, X =< $F -> paddr(Xs,(X-$A)+10, Acc);
paddr([X|Xs],_N,Acc) when X >= $a, X =< $f -> paddr(Xs, (X-$a)+10, Acc);
paddr([$,,$,|_Xs], _N, _Acc) -> error;
paddr([$,|Xs], N, Acc) -> paddr(Xs, 0, [N|Acc]);
paddr([],P2,[P1,D4,D3,D2,D1]) -> {ok,{{D1,D2,D3,D4}, P1*256+P2}};
paddr([],P2,[P1|As]) when length(As) == 32 ->
    case addr6(As,[]) of
        {ok,Addr} -> {ok, {Addr, P1*256+P2}};
        error -> error
    end;
paddr(_, _, _) -> error.

addr6([H4,H3,H2,H1|Addr],Acc) when H4<16,H3<16,H2<16,H1<16 ->
    addr6(Addr, [H4 + H3*16 + H2*256 + H1*4096 |Acc]);
addr6([], Acc) -> {ok, list_to_tuple(Acc)};
addr6(_, _) -> error.

format_port(PortNumber) ->
    [A,B] = binary_to_list(<<PortNumber:16>>),
    {A, B}.

%-------------------------------------------------------------------------------
-spec format(string(), list()) -> string().
format(FormatString, Args) ->
    case catch io_lib:format(FormatString, Args) of
        {'EXIT',{badarg,_}} ->
            error_logger:error_report({bifrost, format_error, {FormatString, Args}}),
            "Invalid format";
        Data ->
            lists:flatten(Data)
    end.

%-------------------------------------------------------------------------------
-spec format_error(integer() | string(), term()) -> string().
format_error(Code, Reason) when is_integer(Code) ->
    format_error(response_code_string(Code), Reason);

format_error(Message, undef) ->
    Message ++ ".";

format_error(Message, Reason) ->
    Format = case io_lib:printable_unicode_list(Reason) of
                 true ->
                     "~ts (~ts)";
                 _False ->
                     "~ts (~p)"
             end,
    format(Format, [Message, Reason]) ++ ".".

%-------------------------------------------------------------------------------
from_utf8(String, true) ->
    unicode:characters_to_list(erlang:list_to_binary(String), utf8);

from_utf8(String, false) ->
    String.

%-------------------------------------------------------------------------------
to_utf8(String) ->
    to_utf8(String, true).

to_utf8(String, true) ->
    erlang:binary_to_list(unicode:characters_to_binary(String, utf8));

to_utf8(String, false) ->
    [if C > 255 orelse C<0 -> $?; true -> C end || C <- String].
