%%%-------------------------------------------------------------------
%%% @author Dmitrii Zolotarev <dmitry_zolotarev@eltex.loc>
%%% @copyright (C) 2015, Eltex
%%% @doc
%%%
%%% @end
%%% Created : 11 Mar 2015 by Dmitrii Zolotarev <dmitry_zolotarev@eltex.loc>
%%%-------------------------------------------------------------------
-module(bifrost_tests).
-author('dmitry.zolotarev@eltex.loc').

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include("bifrost.hrl").

%% EUNIT TESTS %%

%% Testing Utility Functions

setup() ->
    error_logger:tty(false),
    ok = meck:new(error_logger, [unstick, passthrough]),
    ok = meck:new(gen_tcp, [unstick]),
    ok = meck:new(inet, [unstick, passthrough]),
    ok = meck:new(fake_server, [non_strict]),
    ok = meck:expect(fake_server, init, fun(InitialState, _Opt) -> InitialState end),
    ok = meck:expect(fake_server, disconnect, fun(_, {error, breaked}) -> ok end).

execute(ListenerPid) ->
    State = fake_server:init(#connection_state{module=fake_server}, []),
    receive
        {ack, ListenerPid} ->
            bifrost:control_loop(ListenerPid, {gen_tcp, socket}, State#connection_state{ip_address={127,0,0,1}}),
            meck:validate(fake_server),
            meck:validate(gen_tcp)
    end,
    meck:unload(fake_server),
    meck:unload(inet),
    meck:unload(gen_tcp),
    meck:unload(error_logger),
    error_logger:tty(true).

-define(dataSocketTest(TEST_NAME),
        TEST_NAME() ->
               TEST_NAME(active),
               TEST_NAME(passive)).

%% Awkward, monadic interaction sequence testing
script_dialog([]) ->
    meck:expect(gen_tcp,
                recv,
                fun(_, _, infinity) -> {error, closed} end);
script_dialog([{Request, Response} | Rest]) ->
    meck:expect(gen_tcp,
                recv,
                fun(Socket, _, infinity) ->
                        script_dialog([{resp, Socket, Response}] ++ Rest),
                        {ok, Request}
                end);
script_dialog([{resp, Socket, Response} | Rest]) ->
    meck:expect(gen_tcp,
                send,
                fun(S, C) ->
                        ?assertEqual(Socket, S),
                        ?assertEqual(Response, unicode:characters_to_list(C)),
                        script_dialog(Rest)
                end);
script_dialog([{resp_bin, Socket, Response} | Rest]) ->
    meck:expect(gen_tcp,
                send,
                fun(S, C) ->
                        ?assertEqual(Socket, S),
                        ?assertEqual(Response, C),
                        script_dialog(Rest)
                end);
script_dialog([{resp_error, Socket, Error} | Rest]) ->
    meck:expect(gen_tcp,
                send,
                fun(S, _C) ->
                        ?assertEqual(Socket, S),
                        script_dialog(Rest),
                        {error, Error}
                end);
script_dialog([{req_error, Socket, Error} | Rest]) ->
    meck:expect(gen_tcp,
                recv,
                fun(S, _C, infinity) ->
                        ?assertEqual(Socket, S),
                        script_dialog(Rest),
                        {error, Error}
                end);
script_dialog([{req, Socket, Request} | Rest]) ->
    meck:expect(gen_tcp,
                recv,
                fun(S, _, infinity) ->
                        ?assertEqual(S, Socket),
                        script_dialog(Rest),
                        {ok, Request}
                end).

%% executes the next step in the test script
step(Pid) ->
    Pid ! {ack, self()}, % 1st ACK will be 'eaten' by execute
                         % so valid sequence will be
    receive
        {new_state, Pid, State} ->
            {ok, State};
        _ ->
            ?assert(fail)
    end.

%% stops the script
finish(Pid) ->
    ?assertEqual({error, closed}, gen_tcp:recv(dummy_socket, 0, infinity)), % if fails - some step() forgotten
    Pid ! {done, self()}.


%% Unit Tests

strip_newlines_test() ->
    "testing 1 2 3" = bifrost:strip_newlines("testing 1 2 3\r\n"),
    "testing again" = bifrost:strip_newlines("testing again").

parse_input_test() ->
    {test, [], "1 2 3"} = bifrost:parse_input("TEST 1 2 3"),
    {test, [], ""} = bifrost:parse_input("Test\r\n"),
    {test, [], "awesome"} = bifrost:parse_input("Test awesome\r\n").

format_access_test() ->
    "rwxrwxrwx" = bifrost:format_access(8#0777),
    "rw-rw-rw-" = bifrost:format_access(8#0666),
    "r--rwxrwx" = bifrost:format_access(8#0477),
    "---------" = bifrost:format_access(0).

format_number_test() ->
    "005" = bifrost:format_number(5, 3, $0),
    "500" = bifrost:format_number(500, 2, $0),
    "500" = bifrost:format_number(500, 3, $0).

parse_address_test() ->
    {ok, {{127,0,0,1}, 2000}} = bifrost:parse_address("127,0,0,1,7,208"),
    error = bifrost:parse_address("MEAT MEAT").

ftp_result_test() ->
    % all results from gen_bifrost_server.erl
    State = #connection_state{authenticated_state = unauthenticated},
    NewState = State#connection_state{authenticated_state = authenticated},
    ?assertEqual({ok, NewState}, bifrost:ftp_result(State, {ok, NewState})),
    ?assertEqual({error, undef, NewState}, bifrost:ftp_result(State, {error, NewState})),

    ?assertEqual({error, "Error", State}, bifrost:ftp_result(State, {error, "Error"})),
    ?assertEqual({error, not_found, State}, bifrost:ftp_result(State, {error, not_found})),

    ?assertEqual({error, not_found, NewState}, bifrost:ftp_result(State, {error, not_found, NewState})),
    ?assertEqual({error, not_found, NewState}, bifrost:ftp_result(State, {error, NewState, not_found})),

    %% a special results
    ?assertEqual("/path", bifrost:ftp_result(State, "/path")), %current_directory

    ?assertEqual({error, undef, NewState}, bifrost:ftp_result(State, {error, NewState})), %list_files
    ?assertEqual([], bifrost:ftp_result(State, [])), %list_files

    Fun = fun(_BytesCount) -> ok end,
    ?assertEqual({error, undef, State}, bifrost:ftp_result(State, error)), %get_file
    ?assertMatch({ok, Fun}, bifrost:ftp_result(State, {ok, Fun})), %get_file
    ?assertMatch({ok, Fun, State}, bifrost:ftp_result(State, {ok, Fun},
                                        fun (S, {ok, Fn}) when is_function(Fn)-> {ok, Fn, S};
                                            (_S, Any) -> Any end)),
    ?assertMatch({ok, Fun, NewState}, bifrost:ftp_result(State, {ok, Fun, NewState},
                                        fun (S, {ok, Fn}) when is_function(Fn)-> {ok, Fn, S};
                                            (_S, Any) -> Any end)),

    ?assertMatch({ok, NewState}, bifrost:ftp_result(State, {ok, NewState},
                                        fun (S, {ok, Fn}) when is_function(Fn)-> {ok, Fn, S};
                                            (_S, Any) -> Any end)),

    ?assertMatch({error, undef, NewState}, bifrost:ftp_result(State, {error, NewState},
                                        fun (S, {ok, Fn}) when is_function(Fn)-> {ok, Fn, S};
                                            (_S, Any) -> Any end)),

    ?assertMatch({ok, file_info}, bifrost:ftp_result(State, {ok, file_info})), %file_info
    ?assertMatch({error, "ErrorCause", State}, bifrost:ftp_result(State, {error, "ErrorCause"})), %file_info

    ?assertMatch({ok, [help_info]}, bifrost:ftp_result(State, {ok, [help_info]})), %site_help
    ?assertMatch({error, undef, NewState}, bifrost:ftp_result(State, {error, NewState})), %site_help
    ok.

%% Functional/Integration Tests

login_test_user(SocketPid) ->
    login_test_user(SocketPid, []).

login_test_user(SocketPid, Script) ->
    script_dialog([{req, socket, "USER meat"},
                   {resp, socket, "331 User name okay, need password.\r\n"},
                   {req, socket, "PASS meatmeat"},
                   {resp, socket, "230 User logged in, proceed.\r\n"}] ++ Script),
    ok = meck:expect(fake_server, check_user, fun(S, _A) -> {ok, S} end),
    step(SocketPid), % USER meat

    ok = meck:expect(fake_server,
                     login,
                     fun(St, "meat", "meatmeat") ->
                                    {true, St#connection_state{authenticated_state=authenticated}}
                                end),
    {ok, State1} = step(SocketPid),
    ?assertMatch(#connection_state{authenticated_state=authenticated}, State1),
    {ok, State1}.

authenticate_successful_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      login_test_user(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

authenticate_failure_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      script_dialog([{"USER meat", "331 User name okay, need password.\r\n"},
                                     {"PASS meatmeat", "530 Login incorrect.\r\n"}]),
                      ok = meck:expect(gen_tcp, close, fun(socket) -> ok end),
                      ok = meck:expect(fake_server, login, fun(_, "meat", "meatmeat") -> {error} end),
                      ok = meck:expect(fake_server, check_user, fun(S, _A) -> {ok, S} end),
                      ok = meck:expect(fake_server, disconnect, fun(_, {error, auth}) -> ok end),
                      {ok, State} = step(ControlPid),
                      ?assertMatch(#connection_state{authenticated_state=unauthenticated}, State),
                      step(ControlPid), % last event will be disconnect with reason auth fail
                      finish(ControlPid)
              end),

    execute(Child).

requirements_failure_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
                    fun() ->
                        script_dialog([{"USER meat", "331 User name okay, need password.\r\n"},
                        {"USER heat", "421 Login requirements (DENY).\r\n"}]),
                        ok = meck:expect(gen_tcp, close, fun(socket) -> ok end),
                        ok = meck:expect(fake_server, check_user, fun(S, "meat") -> {ok, S};
                        (S, "heat") -> {error, "DENY", S} end),
                        ok = meck:expect(fake_server, disconnect, fun(_, {error, auth}) -> ok end),
                        {ok, State} = step(ControlPid),
                        ?assertMatch(#connection_state{authenticated_state=unauthenticated}, State),
                        {ok, State} = step(ControlPid),
                        ?assertMatch(#connection_state{authenticated_state=unauthenticated}, State),
                        step(ControlPid), % last event will be disconnect with reason auth fail
                        finish(ControlPid)
                    end),
    execute(Child).


unauthenticated_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      script_dialog([  {"CWD /hamster", "530 Not logged in.\r\n"},
                                       {"MKD /unicorns", "530 Not logged in.\r\n"}]),
                      {ok, StateCmd} = step(ControlPid),
                      ?assertMatch(#connection_state{authenticated_state=unauthenticated}, StateCmd),
                      {ok, StateMkd} = step(ControlPid),
                      ?assertMatch(#connection_state{authenticated_state=unauthenticated}, StateMkd),
                      finish(ControlPid)
                  end),
    execute(Child).

ssl_only_test() ->
    setup(),
    ControlPid = self(),
    ok = meck:expect(fake_server, init, fun(InitialState, _Opt) ->
    InitialState#connection_state{ssl_mode=only, utf8=false} end),

    Child = spawn_link(fun() ->
                            script_dialog([ {"USER hamster", "534 Request denied for policy reasons (only ftps allowed).\r\n"},
                                            {"MKD /unicorns", "534 Request denied for policy reasons (only ftps allowed).\r\n"},
                                            {"CWD /hamster", "534 Request denied for policy reasons (only ftps allowed).\r\n"},
                                            {"PWD", "534 Request denied for policy reasons (only ftps allowed).\r\n"},
                                            {"OPTS UTF8 ON", "501 Syntax error in parameters or arguments.\r\n"},
                                            {"FEAT", "211-Features\r\n"},
                                            {resp, socket, " AUTH TLS\r\n" },
                                            {resp, socket, " PROT\r\n" },
                                            {resp, socket, "211 End\r\n" }
                                          ]),
                            step(ControlPid),
                            step(ControlPid),
                            step(ControlPid),
                            step(ControlPid),
                            step(ControlPid),
                            step(ControlPid),
                            finish(ControlPid)
                       end),
    execute(Child).

mkdir_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  make_directory,
                                  fun(State, _) ->
                                          {ok, State}
                                  end),
                      login_test_user(ControlPid,
                                      [{"MKD test_dir", "250 \"test_dir\" directory created.\r\n"},
                                       {"MKD test_dir_2", "550 Unable to create directory.\r\n"}]),
                      step(ControlPid),

                      meck:expect(fake_server,
                                  make_directory,
                                  fun(_, _) ->
                                          {error, error}
                                  end),
                      step(ControlPid),

                      finish(ControlPid)
              end),
    execute(Child).

cwd_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  change_directory,
                                  fun(State, "/meat/bovine/bison") ->
                                          {ok, State}
                                  end),
                      meck:expect(fake_server,
                                  current_directory,
                                  fun(_) -> "/meat/bovine/bison" end),
                      login_test_user(ControlPid,
                                                 [{"CWD /meat/bovine/bison", "250 Directory changed to \"/meat/bovine/bison\".\r\n"},
                                                  {"CWD /meat/bovine/auroch", "550 Unable to change directory.\r\n"},
                                                  {"CWD /meat/bovine/elefant", "550 Unable to change directory (denied).\r\n"}]),

                      step(ControlPid),

                      meck:expect(fake_server,
                                  change_directory,
                                  fun(State, "/meat/bovine/auroch") ->
                                          {error, State}
                                  end),
                      step(ControlPid),

                      meck:expect(fake_server,
                                  change_directory,
                                  fun(_State, "/meat/bovine/elefant") ->
                                          {error, denied}
                                  end),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

cdup_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  change_directory,
                                  fun(State, "..") -> {ok, State} end),
                      meck:expect(fake_server,
                                  current_directory,
                                  fun(_) -> "/meat" end),
                      login_test_user(ControlPid,
                                      [{"CDUP", "250 Directory changed to \"/meat\".\r\n"},
                                       {"CDUP", "250 Directory changed to \"/\".\r\n"},
                                       {"CDUP", "250 Directory changed to \"/\".\r\n"}]),
                      step(ControlPid),

                      meck:expect(fake_server,
                                  current_directory,
                                  fun(_) -> "/" end),

                      step(ControlPid),

                      meck:expect(fake_server,
                                  current_directory,
                                  fun(_) -> "/" end),
                      step(ControlPid),

                      finish(ControlPid)
              end),
    execute(Child).

pwd_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  current_directory,
                                  fun(_) -> "/meat/bovine/bison" end),

                      login_test_user(ControlPid, [{"PWD", "257 \"/meat/bovine/bison\"\r\n"}]),

                      step(ControlPid),

                      finish(ControlPid)
              end),
    execute(Child).

passive_anyport_successful_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
    fun() ->
        meck:expect(gen_tcp, listen, fun(0, _) -> {ok, listen_socket} end),
        meck:expect(inet, sockname, fun(listen_socket) -> {ok, {{127, 0, 0, 1}, 2000}} end),
        login_test_user(ControlPid, [{"PASV", "227 Entering Passive Mode (127,0,0,1,7,208)\r\n"}]),
        ?assertMatch({ok, #connection_state{pasv_listen={passive, listen_socket, {{127,0,0,1}, 2000}}}},
        step(ControlPid)),
        finish(ControlPid)
    end),
    execute(Child).

passive_anyport_failure_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
    fun() ->
        meck:expect(gen_tcp, listen, fun(0, _) -> {error, eaddrinuse} end),
        login_test_user(ControlPid, [{"PASV", "425 Can't open data connection.\r\n"}]),
        ?assertMatch({ok, #connection_state{pasv_listen=undefined}}, step(ControlPid)),
        finish(ControlPid)
    end),
    execute(Child).

passive_port_range_successful_test() ->
    setup(),
    ok = meck:expect(fake_server, init,
    fun(InitialState, _Opt) -> InitialState#connection_state{port_range={2000, 3000}} end),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            meck:expect(gen_tcp, listen, fun(2500, _) -> {ok, listen_socket_2500};
                                            (N, _) when is_integer(N) -> {error, eaddrinuse} end),

            meck:expect(inet, sockname, fun(listen_socket_2500) -> {ok, {{127, 0, 0, 1}, 2500}} end),

            login_test_user(ControlPid, [{"PASV", "227 Entering Passive Mode (127,0,0,1,9,196)\r\n"}]),
            ok = meck:new(random, [unstick]),
            ok = meck:expect(random, uniform, fun(M) -> M end),
            ?assertMatch({ok, #connection_state{pasv_listen={passive, listen_socket_2500, {{127,0,0,1}, 2500}}}},
            step(ControlPid)),
            ok = meck:unload(random),
            finish(ControlPid)
        end),
    execute(Child).

passive_port_range_failure_test() ->
    setup(),
    ok = meck:expect(fake_server, init,
    fun(InitialState, _Opt) -> InitialState#connection_state{port_range={2000, 4000}} end),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            meck:expect(gen_tcp, listen, fun(N, _) when is_integer(N), N>=2000, 4000>=N -> {error, eaddrinuse} end),
            ok = meck:new(random, [unstick]),
            ok = meck:expect(random, uniform, fun(M) -> M end),
            login_test_user(ControlPid, [{"PASV", "425 Can't open data connection.\r\n"}]),
            ?assertMatch({ok, #connection_state{pasv_listen=undefined}}, step(ControlPid)),
            ok = meck:unload(random),
            finish(ControlPid)
        end),
    execute(Child).

login_test_user_with_data_socket(ControlPid, Script, passive) ->
    meck:expect(gen_tcp, listen, fun(0, _) -> {ok, listen_socket} end),
    meck:expect(gen_tcp, accept, fun(listen_socket) -> {ok, data_socket} end),
    meck:expect(inet, sockname, fun(listen_socket) -> {ok, {{127, 0, 0, 1}, 2000}} end),
    login_test_user(ControlPid, [{"PASV", "227 Entering Passive Mode (127,0,0,1,7,208)\r\n"}] ++ Script),
    ?assertMatch({ok, #connection_state{pasv_listen={passive, listen_socket, {{127,0,0,1}, 2000}}}}, step(ControlPid));


login_test_user_with_data_socket(ControlPid, Script, active) ->
    meck:expect(gen_tcp,
                connect,
                fun(_, _, _) ->
                        {ok, data_socket}
                end),
    login_test_user(ControlPid, [{"PORT 127,0,0,1,7,208", "200 Command okay.\r\n"}] ++ Script),
    ?assertMatch({ok, #connection_state{data_port={active, {127,0,0,1}, 2000}}}, step(ControlPid)).

?dataSocketTest(nlst_test).
nlst_test(Mode) ->
    setup(),
    meck:expect(fake_server,
                list_files,
                fun(_, _, _) ->
                        [#file_info{type=file, name="edward"},
                         #file_info{type=dir, name="Aethelred"}]
                end),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
                      ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),
                      login_test_user_with_data_socket(ControlPid,
                                                       [{"NLST", "150 File status okay; about to open data connection.\r\n"},
                                                        {resp, data_socket, "edward\r\n"},
                                                        {resp, data_socket, "Aethelred\r\n"},
                                                        {resp, socket, "226 Closing data connection.\r\n"}],
                                                       Mode),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

?dataSocketTest(list_test).
list_test(Mode) ->
    setup(),
    meck:expect(fake_server,
                list_files,
                fun(_, _, _) ->
                        [#file_info{type=file,
                                    name="edward",
                                    mode=511,
                                    gid=0,
                                    uid=0,
                                    mtime={{3019,12,12},{12,12,12}},
                                    size=512},
                         #file_info{type=dir,
                                    name="Aethelred",
                                    mode=200,
                                    gid=0,
                                    uid=0,
                                    mtime={{3019,12,12},{12,12,12}},
                                    size=0}]
                end),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      Script = [{"LIST", "150 File status okay; about to open data connection.\r\n"},
                                {resp, data_socket, "-rwxrwxrwx  1     0     0      512 Dec 12 12:12 edward\r\n"},
                                {resp, data_socket, "d-wx--x---  4     0     0        0 Dec 12 12:12 Aethelred\r\n"},
                                {resp, socket, "226 Closing data connection.\r\n"}],

                      ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
                      ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),

                      login_test_user_with_data_socket(ControlPid, Script, Mode),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

remove_directory_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  remove_directory,
                                  fun(St, "/bison/burgers") ->
                                          {ok, St}
                                  end),

                      login_test_user(ControlPid, [{"RMD /bison/burgers", "200 Command okay.\r\n"},
                                                   {"RMD /bison/burgers", "550 Requested action not taken.\r\n"}]),
                      step(ControlPid),

                      ok = meck:expect(fake_server,
                                  remove_directory,
                                  fun(_, "/bison/burgers") ->
                                          {error, error}
                                  end),
                      step(ControlPid),

                      finish(ControlPid)
              end),
    execute(Child).

remove_file_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  remove_file,
                                  fun(St, "cheese.txt") ->
                                          {ok, St}
                                  end),

                      login_test_user(ControlPid, [{"DELE cheese.txt", "250 Requested file action okay, completed.\r\n"},
                                                   {"DELE cheese.txt", "450 Unable to delete file.\r\n"}]),
                      step(ControlPid),

                      meck:expect(fake_server,
                                  remove_file,
                                  fun(_, "cheese.txt") ->
                                          {error, error}
                                  end),

                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

?dataSocketTest(stor_test).
stor_test(Mode) ->
    setup(),
    ControlPid = self(),
    ok = meck:expect(fake_server, init, fun(InitialState, _Opt) ->
                                            InitialState#connection_state{recv_block_size = 1024*1024} end),
    Child = spawn_link(
              fun() ->
                      Script = [{"STOR file.txt", "150 File status okay; about to open data connection.\r\n"},
                                {req, data_socket, <<"SOME DATA HERE">>},
                                {resp, socket, "226 Closing data connection.\r\n"},
                                {"PWD", "257 \"/\"\r\n"}
                               ],
                      meck:expect(fake_server,
                                  put_file,
                                  fun(S, "file.txt", write, F) ->
                                          {ok, Data, DataSize} = F(),
                                          BinData = <<"SOME DATA HERE">>,
                                          ?assertEqual(Data, BinData),
                                          ?assertEqual(DataSize, size(BinData)),
                                          {ok, S}
                                  end),

                      ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
                      ok = meck:expect(inet, setopts,
                                          fun(data_socket, Opts) ->
                                                   ?assertEqual(1024*1024, proplists:get_value(recbuf, Opts)),
                                                   ok
                                          end),

                      login_test_user_with_data_socket(ControlPid, Script, Mode),
                      step(ControlPid), % STOR

                      ok = meck:expect(fake_server, put_file,
                      fun(S, "file.txt", notification, done) -> {ok, S} end),

                      ok = meck:expect(fake_server, current_directory, fun(_) -> "/" end),
                      step(ControlPid), % PWD

                      finish(ControlPid)
              end),
    execute(Child).

?dataSocketTest(stor_user_failure_test).

stor_user_failure_test(Mode) ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            Script=[ {"STOR elif.txt", "150 File status okay; about to open data connection.\r\n"},
                     {req, data_socket, <<"SOME DATA HERE">>},
                     {resp, socket, "451 Error access_denied when storing a file.\r\n"},
                     {"QUIT", "200 Goodbye.\r\n"}],
            ok = meck:expect(fake_server, put_file,
                fun(_, "elif.txt", write, F) ->
                    F(),
                    {error, access_denied}
                end),

            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),
            login_test_user_with_data_socket(ControlPid, Script, Mode),
            step(ControlPid),

            meck:expect(fake_server, disconnect, fun(_, exit) -> ok end),
            meck:expect(gen_tcp, close, fun(socket) -> ok end),
            %% not needed, because USER kills itself
            %% meck:expect(fake_server,put_file, fun(S, "elif.txt", notification, terminated) -> {ok, S} end),
            step(ControlPid),
            finish(ControlPid)
        end),
    execute(Child).

?dataSocketTest(stor_notificaion_test).
    stor_notificaion_test(Mode) ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            Script=[ {"STOR ok.txt", "150 File status okay; about to open data connection.\r\n"},
                     {req, data_socket, <<"SOME DATA HERE">>},
                     {resp, socket, "226 Closing data connection.\r\n"},

                     {"STOR bad.txt", "150 File status okay; about to open data connection.\r\n"},
                     {req, data_socket, <<"SOME DATA HERE">>},
                     {resp, socket, "226 Closing data connection.\r\n"},
                     {req_error, socket, {error, closed}}
                   ],

            ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),
            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            ok = meck:expect(fake_server, put_file, fun(S, "ok.txt", write, F) ->
                                                        {ok, Data, DataSize} = F(),
                                                        BinData = <<"SOME DATA HERE">>,
                                                        ?assertEqual(Data, BinData),
                                                        ?assertEqual(DataSize, size(BinData)),
                                                        {ok, S}
                                                    end),

            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            login_test_user_with_data_socket(ControlPid, Script, Mode),
            step(ControlPid), % STOR(OK)

            ok = meck:expect(fake_server, put_file,
                fun(S, "bad.txt", write, F) ->
                        {ok, Data, DataSize} = F(),
                        BinData = <<"SOME DATA HERE">>,
                        ?assertEqual(Data, BinData),
                        ?assertEqual(DataSize, size(BinData)),
                        {ok, S};
                   (S, "ok.txt", notification, done) ->
                        {ok, S}
                end),
            step(ControlPid), % STOR(BAD)

            ok = meck:expect(fake_server, put_file,
                fun(S, "bad.txt", notification, Result) ->
                    ?assertEqual(terminated, Result),
                    {ok, S}
                end),
            ok = meck:expect(fake_server, disconnect, fun(_, {error, {error, closed}}) -> ok end),
            step(ControlPid), % CRASH CONNECTION
            finish(ControlPid)
        end),
    execute(Child).

?dataSocketTest(stor_failure_test).
stor_failure_test(Mode) ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            Script=[ {"STOR elif.txt", "150 File status okay; about to open data connection.\r\n"},
                     {req, data_socket, <<"SOME DATA HERE">>},
                     {resp, socket, "451 Error access_denied when storing a file.\r\n"},
                     {"QUIT", "200 Goodbye.\r\n"}],
            ok = meck:expect(fake_server, put_file,
                fun(_, "elif.txt", write, F) ->
                    F(),
                    {error, access_denied}
                end),

            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),
            login_test_user_with_data_socket(ControlPid, Script, Mode),
            step(ControlPid),

            meck:expect(fake_server, disconnect, fun(_, exit) -> ok end),
            meck:expect(gen_tcp, close, fun(socket) -> ok end),
            %% meck:expect(fake_server,put_file, fun(S, "elif.txt", notification, terminated) -> {ok, S} end),
            %% not needed, because USER kills itself
            step(ControlPid),
            finish(ControlPid)
        end),
    execute(Child).

?dataSocketTest(retr_test).
retr_test(Mode) ->
    setup(),
    ok = meck:expect(fake_server, init, fun(InitialState, _Opt) ->
                                            InitialState#connection_state{send_block_size=1024*1024} end),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      Script = [{"RETR bologna.txt", "150 File status okay; about to open data connection.\r\n"},
                                {resp, data_socket, "SOME DATA HERE"},
                                {resp, data_socket, "SOME MORE DATA"},
                                {resp, socket, "226 Closing data connection.\r\n"}],
                      meck:expect(fake_server,
                                  get_file,
                                  fun(State, "bologna.txt") ->
                                      {ok,
                                          fun(1024*1024) ->
                                              {ok,
                                               list_to_binary("SOME DATA HERE"),
                                               fun(1024*1024) ->
                                                   {ok,
                                                    list_to_binary("SOME MORE DATA"),
                                                    fun(1024*1024) -> {done, State} end}
                                               end}
                                          end}
                                  end),

                      ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
                      ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),

                      login_test_user_with_data_socket(ControlPid, Script, Mode),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

?dataSocketTest(retr_failure_test).
retr_failure_test(Mode) ->
    setup(),
    ok = meck:expect(fake_server, init, fun(InitialState, _Opt) ->
    InitialState#connection_state{send_block_size=1024} end),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      Script = [{"RETR bologna.txt", "150 File status okay; about to open data connection.\r\n"},
                                {resp, data_socket, "SOME DATA HERE"},
                                {resp, socket, "451 Unable to get file (Disk error).\r\n"}],
                  meck:expect(fake_server,
                                  get_file,
                                  fun(State, "bologna.txt") ->
                                          {ok,
                                           fun(1024) ->
                                                   {ok,
                                                    list_to_binary("SOME DATA HERE"),
                                                    fun(1024) ->
                                                        {error, "Disk error", State}
                                                    end}
                                           end}
                                  end),

                      ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
                      ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),

                      login_test_user_with_data_socket(ControlPid, Script, Mode),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

rein_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      login_test_user(ControlPid, [{"REIN", "200 Command okay.\r\n"}]),
                      ControlPid ! {ack, self()},
                      receive
                          {new_state, _, #connection_state{authenticated_state=unauthenticated}} ->
                              ok;
                          _ ->
                              ?assert(fail)
                      end,
                      finish(ControlPid)
              end),
    execute(Child).

mdtm_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  file_info,
                                  fun(_, "cheese.txt") ->
                                          {ok,
                                           #file_info{type=file,
                                                      mtime={{2012,2,3},{16,3,12}}}}
                                  end),
                      login_test_user(ControlPid, [{"MDTM cheese.txt", "213 20120203160312\r\n"}]),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

mdtm_truncate_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  file_info,
                                  fun(_, "mould.txt") ->
                                          {ok,
                                           #file_info{type=file,
                                                      mtime={{2012,2,3},{16,3,11.933844}}}}
                                  end),
                      login_test_user(ControlPid, [{"MDTM mould.txt", "213 20120203160311\r\n"}]),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

rnfr_rnto_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      login_test_user(ControlPid,
                                      [{"RNTO mushrooms.txt", "503 RNFR not specified.\r\n"},
                                       {"RNFR cheese.txt", "350 Ready for RNTO.\r\n"},
                                       {"RNTO mushrooms.txt", "250 Rename successful.\r\n"}]),
                      step(ControlPid),

                      meck:expect(fake_server,
                                  rename_file,
                                  fun(S, "cheese.txt", "mushrooms.txt") ->
                                          {ok, S}
                                  end),
                      step(ControlPid),
                      step(ControlPid),
                      finish(ControlPid)
              end),
    execute(Child).

type_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      login_test_user(ControlPid,
                                      [{"TYPE I", "200 Command okay.\r\n"},
                                       {"TYPE X", "501 Only TYPE I or TYPE A may be used.\r\n"}]),
                      step(ControlPid),
                      step(ControlPid),
                      finish(ControlPid)
              end
             ),
    execute(Child).

site_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  site_command,
                                  fun(S, monkey, "cheese bits") ->
                                          {ok, S}
                                  end),
                      login_test_user(ControlPid,
                                      [{"SITE MONKEY cheese bits", "200 Command okay.\r\n"},
                                       {"SITE GORILLA cheese", "500 Syntax error, command unrecognized.\r\n"}]),
                      step(ControlPid),

                      meck:expect(fake_server,
                                  site_command,
                                  fun(_, gorilla, "cheese") ->
                                          {error, not_found}
                                  end),
                      step(ControlPid),
                      finish(ControlPid)
              end
             ),
    execute(Child).

help_site_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      meck:expect(fake_server,
                                  site_help,
                                  fun (_) ->
                                          {ok, [{"MEAT", "devour the flesh of beasts."}]}
                                  end),
                      Script = [{"HELP SITE", "214-The following commands are recognized\r\n"},
                                {resp, socket, "MEAT : devour the flesh of beasts.\r\n"},
                                {resp, socket, "214 Help OK\r\n"}],
                      login_test_user(ControlPid, Script),
                      step(ControlPid),
                      finish(ControlPid)
              end
             ),
    execute(Child).

unrecognized_command_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
              fun() ->
                      login_test_user(ControlPid, [{"FEED buffalo", "500 Syntax error, command unrecognized.\r\n"}]),
                      step(ControlPid),
                      finish(ControlPid)
              end
             ),
    execute(Child).

quit_test() ->
    setup(),
    meck:expect(gen_tcp,
                close,
                fun(socket) -> ok end),
    ControlPid = self(),
    Child = spawn_link(
              fun () ->
                      meck:expect(fake_server,
                                  disconnect,
                                  fun(_, exit) ->
                                          ok
                                  end),
                      login_test_user(ControlPid,
                                      [{"QUIT", "200 Goodbye.\r\n"}]),
                      step(ControlPid),
                      finish(ControlPid)
              end
             ),
    execute(Child).

feat_test() ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            login_test_user(ControlPid,
                                [ {"FEAT", "211-Features\r\n"},
                                  {resp, socket, " UTF8\r\n" },
                                  {resp, socket, "211 End\r\n" }]),
            step(ControlPid),
            finish(ControlPid)
        end),
    execute(Child).

?dataSocketTest(utf8_success_test).
utf8_success_test(Mode) ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            FileName = "Молоко-Яйки", %milk-eggs
            UtfFileName = bifrost:to_utf8(FileName), %milk-eggs
            BinData = <<"SOME DATA HERE">>,

            Script=[{"PWD " ++ UtfFileName, "257 \""++ UtfFileName ++"\"\r\n"},
                    {"OPTS UTF8 ON", "200 Accepted.\r\n"},
                    {"CWD " ++ UtfFileName, "250 Directory changed to \""++ UtfFileName ++"\".\r\n"},
                    {"STOR " ++ UtfFileName, "150 File status okay; about to open data connection.\r\n"},
                    {req, data_socket, BinData},
                    {resp, socket, "226 Closing data connection.\r\n"},
                    {"LIST", "150 File status okay; about to open data connection.\r\n"},
                    {resp, data_socket, "d-wx--x---  4     0     0        0 Dec 12 12:12 "++UtfFileName++"\r\n"},
                    {resp, socket, "226 Closing data connection.\r\n"}],

            ok = meck:expect(fake_server,current_directory, fun(_) -> FileName end),

            login_test_user_with_data_socket(ControlPid, Script, Mode),
            step(ControlPid),
            step(ControlPid),

            meck:expect(fake_server,change_directory,
            fun(State, InFileName) ->
                ?assertEqual(InFileName, FileName),
                {ok, State}
            end),
            step(ControlPid),

            meck:expect(fake_server,put_file,
            fun(S, InFileName, write, F) ->
                ?assertEqual(InFileName, FileName),
                {ok, Data, DataSize} = F(),
                ?assertEqual(Data, BinData),
                ?assertEqual(DataSize, size(BinData)),
                {ok, S}
            end),

            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),

            step(ControlPid),

            meck:expect(fake_server, put_file,
            fun(S, InFileName, notification, done) ->
                ?assertEqual(InFileName, FileName),
                {ok, S}
            end),

            meck:expect(fake_server, list_files,
            fun(_, _, _) ->
                [#file_info{type=dir,name=FileName,mode=200,gid=0,uid=0,
                mtime={{3019,12,12},{12,12,12}},size=0}]
            end),

            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            ok = meck:expect(inet, setopts, fun(data_socket,[{recbuf, _Size}]) -> ok end),

            step(ControlPid),
            finish(ControlPid)
        end),
    execute(Child).

?dataSocketTest(utf8_failure_test).
utf8_failure_test(Mode) ->
    setup(),
    ControlPid = self(),
    Child = spawn_link(
        fun() ->
            FileName = "Молоко-Яйки", %milk-eggs
            UtfFileNameOk = bifrost:to_utf8(FileName), %milk-eggs
            {UtfFileNameErr, _} = lists:split(length(UtfFileNameOk)-1, UtfFileNameOk),

            Script =[ {"OPTS UTF8 ON", "200 Accepted.\r\n"},
                      {"CWD " ++ UtfFileNameErr, "501 Syntax error in parameters or arguments.\r\n"}],

            ok = meck:expect(gen_tcp, close, fun(data_socket) -> ok end),
            ok = meck:expect(error_logger, warning_report, fun({bifrost, incomplete_utf8, _}) -> ok end),

            login_test_user_with_data_socket(ControlPid, Script, Mode),
            step(ControlPid),
            step(ControlPid),
            finish(ControlPid)
        end),
    execute(Child).

-endif. %% TEST
