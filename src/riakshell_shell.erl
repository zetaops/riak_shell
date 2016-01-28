%% -------------------------------------------------------------------
%%
%% The main shell runner file for riakshell
%%
%% Copyright (c) 2007-2016 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(riakshell_shell).

%% main export
-export([
         start/0
        ]).

%% various extensions like history which runs an old command
%% and load which reloads EXT modules need to call back into
%% riakshell_shell
-export([
         register_extensions/1,
         handle_cmd/2
        ]).

-include("riakshell.hrl").

start() -> spawn(fun main/0).

main() ->
    State = startup(),
    process_flag(trap_exit, true),
    io:format("riakshell ~p, use 'quit;' or 'q;' to exit or " ++
                  "'help;' for help~n", [State#state.version]),
    loop(State).

loop(State) ->
    {Prompt, NewState} = make_prompt(State),
    Cmd = io:get_line(standard_io, Prompt),
    {Result, NewState2} = handle_cmd(Cmd, NewState),
    case Result of
        [] -> ok;
        _  -> io:format(Result ++ "~n")
    end,
    loop(NewState2).

handle_cmd(Cmd, #state{} = State) ->
    {ok, Toks, _} = cmdline_lexer:string(Cmd),
    case is_complete(Toks, State) of
        {true, Toks2, State2} -> run_cmd(Toks2, Cmd, State2);
        {false, State2}       -> {"", State2}
    end.

is_complete(Toks, S) ->
    case lists:member({semicolon, ";"}, Toks) of
        true  -> Toks2 = S#state.partial_cmd ++ Toks,
                 NewState = S#state{partial_cmd = []},
                 {true, Toks2, NewState};
        false -> NewP = S#state.partial_cmd ++ Toks,
           {false, S#state{partial_cmd = NewP}}
    end.

run_cmd([{atom, "riak"}, {hyphen, "-"}, {atom, "admin"} | _T] = _Toks, _Cmd, State) ->
    {"riak-admin is not supported yet", State};
run_cmd([{atom, Fn} | _T] = Toks, Cmd, State) ->
    case lists:member(Fn, [atom_to_list(X) || X <- ?IMPLEMENTED_SQL_STATEMENTS]) of
        true  -> run_sql_command(Cmd, State);
        false -> run_riakshell_cmd(Toks, State)
end.

run_sql_command(Cmd, State) ->
    Cmd2 = string:strip(Cmd, both, $\n),
    try
        Toks = riak_ql_lexer:get_tokens(Cmd2),
        case riak_ql_parser:parse(Toks) of
            {error, Err} ->
                Msg1 = io_lib:format("SQL Parser error ~p", [Err]),
                {Msg1, State};
            SQL ->
                io:format("SQL is ~p~n", [SQL]),
                Result = "SQL not implemented",
                NewState = log(Cmd, Result, State),
                NewState2 = add_cmd_to_history(Cmd, NewState),
                {Result, NewState2}
        end
    catch _:Error ->
            Msg2 = io_lib:format("SQL Lexer error ~p", [Error]),
            {Msg2, State}
    end.

run_riakshell_cmd(Toks, State) ->
    io:format("running riakshell commmand ~p~n", [Toks]),
    case cmdline_parser:parse(Toks) of
        {ok, {{Fn, Arity}, Args}} ->
            Cmd = toks_to_string(Toks),
            {Result, NewState} = run_ext({{Fn, Arity}, Args}, State),
            NewState2 = log(Cmd, Result, NewState),
            NewState3 = add_cmd_to_history(Cmd, NewState2),
            Msg1 = try
                       io_lib:format(Result, [])
                   catch _:_ ->
                           io_lib:format("The extension did not return printable output. " ++
                                             "Please report this bug to the EXT developer.", [])
                   end,
            {Msg1, NewState3};
        Error ->
            Msg2 = io_lib:format("Error: ~p", [Error]),
            {Msg2, State}
        end.

toks_to_string(Toks) ->
    Cmd = [riakshell_util:to_list(TkCh) || {_, TkCh} <- Toks],
    _Cmd2 = riakshell_util:pretty_pr_cmd(lists:flatten(Cmd)).

add_cmd_to_history(Cmd, #state{history = Hs} = State) ->
    N = case Hs of
            []             -> 1;
            [{NH, _} | _T] -> NH + 1
        end,
    State#state{history = [{N, Cmd} | Hs]}.

%% help is a special function
run_ext({{help, 0}, []}, #state{extensions = E} = State) ->
    Msg1 = io_lib:format("The following functions are available~n\r" ++
                             "(the number of arguments is given)~n\r", []),
    Msg2 = print_exts(E),
    Msg3 = io_lib:format("~nYou can get more help by calling help with the~n" ++
                             "function name and arguments like 'help quit 0;'", []),
   {Msg1 ++ Msg2 ++ Msg3,  State};
%% the help funs are not passed the state and can't change it
run_ext({{help, 2}, [Fn, Arity]}, #state{extensions = E} = State) ->
    Msg = case lists:keysearch({Fn, Arity}, 1, E) of
        {value, {{_, _}, Mod}} ->
            try
                erlang:apply(Mod, help, [Fn, Arity])
            catch _:_ ->
                    io_lib:format("There is no help for ~p",
                                  [{Fn, Arity}])
            end;
        false ->
            io_lib:format("There is no help for ~p", [{Fn, Arity}])
    end,
    {Msg, State};
run_ext({Ext, Args}, #state{extensions = E} = State) ->
    case lists:keysearch(Ext, 1, E) of
        {value, {{Fn, _}, Mod}} ->
            try
                erlang:apply(Mod, Fn, [State] ++ Args)
            catch A:B ->
                    io:format("Error ~p~n", [{A, B}]),
                    Msg1 = io_lib:format("Error: invalid function call : ~p:~p ~p", [Mod, Fn, Args]),
                    {Msg2, NewS} = run_ext({{help, 2}, [Fn, length(Args)]}, State),
                    {Msg1 ++ Msg2, NewS}
            end;
        false ->
            Msg = io_lib:format("Extension ~p not implemented.", [Ext]),
            {Msg, State}
    end.

make_prompt(S = #state{count       = SQLN,
                       partial_cmd = []}) ->
    Prompt =  "riakshell(" ++ integer_to_list(SQLN) ++ ")>",
    {Prompt, S#state{count = SQLN + 1}};
make_prompt(S) ->
    Prompt = "->",
    {Prompt, S}.

startup() ->
    State = try
                load_config()
            catch
                _ ->
                    io:format("Invalid_config~n", []),
                    exit(invalid_config)
            end,
    register_extensions(State).

load_config() ->
    try
        {ok, Config} = file:consult(?CONFIGFILE),
        State = #state{config = Config},
        _State2 = set_logging_defaults(State)
    catch _:_ ->
            io:format("Cannot read configfile ~p~n", [?CONFIGFILE]),
            exit('cannot start riakshell')
    end.

set_logging_defaults(#state{config = Config} = State) ->
    Logfile  = read_config(Config, logfile, State#state.logfile),
    Logging  = read_config(Config, logging, State#state.logging),
    Date_Log = read_config(Config, date_log, State#state.date_log),
    State#state{logfile  = Logfile,
                logging  = Logging,
                date_log = Date_Log}.

read_config(Config, Key, Default) when is_list(Config) andalso
                                       is_atom(Key) ->
    case lists:keyfind(Key, 1, Config) of
        {Key, V} -> V;
        false    -> Default
    end.

register_extensions(#state{} = S) ->
    %% the application may already be loaded to don't check
    %% the return value
    _ = application:load(riakshell),
    {ok, Mods} = application:get_key(riakshell, modules),
    %% this might be a call to reload modules so delete
    %% and purge them first
    ReloadFn = fun(X) ->
                       code:delete(X),
                       code:purge(X)
               end,
    [ReloadFn(X) || X <- Mods,
                    is_extension(X),
                    X =/= debug_EXT],
    %% now load the modules
    [{module, X} = code:ensure_loaded(X) || X <- Mods],
    %% now going to register the extensions
    Extensions = [X || X <- Mods, is_extension(X)],
    register_e2(Extensions, S#state{extensions = []}).

register_e2([], #state{extensions = E} = State) ->
    validate_extensions(E),
    State;
register_e2([Mod | T], #state{extensions = E} = State) ->
    %% a fun that appears in the shell like
    %% 'fishpaste(bleh, bloh, blah)'
    %% is implemented like this
    %% 'fishpaste(#state{} = S, Arg1, Arg2, Arg3) ->
    %% so reduce the arity by 1
    Fns = [{{Fn, Arity - 1}, Mod} || {Fn, Arity} <- Mod:module_info(exports),
                                     {Fn, Arity} =/= {help, 2},
                                     {Fn, Arity} =/= {module_info, 0},
                                     {Fn, Arity} =/= {module_info, 1},
                                     Arity =/= 0,
                                     Fn =/= 'riak-admin',
                                     not lists:member(Fn, ?IMPLEMENTED_SQL_STATEMENTS)],
    register_e2(T, State#state{extensions = Fns ++ E}).

is_extension(Module) ->
    case lists:reverse(atom_to_list(Module)) of
        "TXE_" ++ _Rest -> true;
        _               -> false
    end.

validate_extensions(Extensions) ->
    case identify_multiple_definitions(Extensions) of
        [] ->
            ok;
        Problems ->
            print_errors(Problems)
    end.

identify_multiple_definitions(Extensions) ->
    Funs = proplists:get_keys(Extensions),
    AllDefs = [{Fun, proplists:get_all_values(Fun, Extensions)}
                || Fun <- Funs ],
    [ FunDefs || FunDefs = {_Fun, [_,_|_]} <- AllDefs ].

print_errors([]) ->
    exit("Shell cannot start because of invalid extensions");
print_errors([{{Fn, Arity}, Mods} | T]) ->
    io:format("function ~p ~p is multiply defined in ~p~n", [Fn, Arity, Mods]),
    print_errors(T).

print_exts(E) ->
    Grouped = group(E, []),
    lists:flatten([begin
                       io_lib:format("~nExtension '~s' provides:~n", [Mod]) ++
                       riakshell_util:printkvs(Fns)
                   end || {Mod, Fns} <- Grouped]).

group([], Acc) ->
    [{Mod, lists:sort(L)} || {Mod, L} <- lists:sort(Acc)];
group([{FnArity, Mod} | T], Acc) ->
    Mod2 = shrink(Mod),
    NewAcc = case lists:keyfind(Mod2, 1, Acc) of
                 false ->
                     [{Mod2, [FnArity]} | Acc];
                 {Mod2, A2} ->
                     lists:keyreplace(Mod2, 1, Acc, {Mod2, [FnArity | A2]})
             end,
    group(T, NewAcc).

shrink(Atom) ->
    re:replace(atom_to_list(Atom), "_EXT", "", [{return, list}]).

log(_Cmd, _Result, #state{logging = off} = State) ->
    State#state{log_this_cmd = true};
log(_Cmd, _Result, #state{log_this_cmd = false} = State) ->
    State#state{log_this_cmd = true};
log(Cmd, Result, #state{logging      = on,
                        date_log     = IsDateLog,
                        logfile      = LogFile,
                        current_date = Date} = State) ->
    File = case IsDateLog of
               on  -> LogFile ++ "." ++ Date ++ ".log";
               off -> LogFile ++ ".log"
           end,
    _FileName = filelib:ensure_dir(File),
    Result2 = re:replace(Result, "\\\"", "\\\\\"", [global, {return, list}]),
    case file:open(File, [append]) of
        {ok, Id} ->
            io:fwrite(Id, "{{command, ~p}, {result, \"" ++ Result2 ++ "\"}}.~n",
                      [Cmd]),
            file:close(Id);
        Err  ->
            exit({'Cannot log', Err})
    end,
    State#state{log_this_cmd = true}.
