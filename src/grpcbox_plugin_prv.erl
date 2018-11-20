-module(grpcbox_plugin_prv).

-export([init/1, do/1, format_error/1]).

-include_lib("providers/include/providers.hrl").

-define(PROVIDER, gen).
-define(NAMESPACE, grpc).
-define(DEPS, [{default, app_discovery}]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {namespace, ?NAMESPACE},
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 grpc gen"}, % How to use the plugin
            {opts, [{protos, $p, "protos", string, ""},
                    {force, $f, "force", boolean, ""}]},
            {short_desc, "Generates behaviours for grpc services"},
            {desc, "Generates behaviours for grpc services"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

% TODO: this function is subject to be placed in rebar3. Isn't it?
expand_env_vars(State, Input) ->
  lists:foldl(
    fun({Var, Value}, Input0) ->
      rebar_utils:expand_env_variable(Input0, Var, Value)
    end,
    Input,
    rebar_env:create_env(State)).

out_dir(State) ->
  Config     = rebar_state:opts(State),
  GrpcConfig = rebar_opts:get(Config, grpc, []),
  OutDir0    = proplists:get_value(out_dir, GrpcConfig, "src"),
  OutDir     = expand_env_vars(State, OutDir0),

  case ec_file:mkdir_p(OutDir) of
    ok ->
      OutDir;

    {error, Reason} ->
      throw(?PRV_ERROR({filelib, ensure_dir, Reason}))
  end.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    Config = rebar_state:opts(State),
    GrpcConfig = rebar_opts:get(Config, grpc, []),
    {Options, _} = rebar_state:command_parsed_args(State),
    ProtosDir = proplists:get_value(protos, Options, proplists:get_value(protos, GrpcConfig, "priv/protos")),
    GpbOpts = proplists:get_value(gpb_opts, GrpcConfig, []),
    GrpcOutDir = out_dir(State),

    [begin
         GpbModule = compile_pb(Filename, GrpcOutDir, GpbOpts),
         gen_service_behaviour(GpbModule, Options, GrpcConfig, State)
     end || Filename <- filelib:wildcard(filename:join(ProtosDir, "*.proto"))],

    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error({compile_errors, Errors, Warnings}) ->
    [begin
         rebar_api:warn("Warning building ~s~n", [File]),
         [rebar_api:warn("        ~p: ~s", [Line, M:format_error(E)]) || {Line, M, E} <- Es]
     end || {File, Es} <- Warnings],
    [[io_lib:format("Error building ~s~n", [File]) |
         [io_lib:format("        ~p: ~s", [Line, M:format_error(E)]) || {Line, M, E} <- Es]] || {File, Es} <- Errors];
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

maybe_rename(name) ->
    method;
maybe_rename(N) ->
    N.

unmodified_maybe_rename(name) ->
    unmodified_method;
unmodified_maybe_rename(N) ->
    N.

gen_service_behaviour(GpbModule, Options, GrpcConfig, State) ->
    OutDir = out_dir(State),
    Force = proplists:get_value(force, Options, true),
    ServicePrefix = proplists:get_value(prefix, GrpcConfig, ""),
    ServiceSuffix = proplists:get_value(suffix, GrpcConfig, ""),
    Services = [begin
                    {{_, Name}, Methods} = GpbModule:get_service_def(S),
                    [{out_dir, OutDir},
                     {pb_module, atom_to_list(GpbModule)},
                     {unmodified_service_name, atom_to_list(Name)},
                     {service_name, ServicePrefix++list_snake_case(atom_to_list(Name))++ServiceSuffix},
                     {methods, [lists:flatten([[{maybe_rename(X), maybe_snake_case(X, atom_to_list(Y))},
                                                   {unmodified_maybe_rename(X), atom_to_list(Y)}]
                                               || {X, Y} <- maps:to_list(Method), X =/= opts])
                                || Method <- Methods]}]
                end || S <- GpbModule:get_service_names()],
    rebar_log:log(debug, "services: ~p", [Services]),
    [rebar_templater:new("grpcbox", Service, Force, State) || Service <- Services].

compile_pb(Filename, GrpcOutDir, Options) ->
    OutDir = proplists:get_value(o, Options, GrpcOutDir),
    ModuleNameSuffix = proplists:get_value(module_name_suffix, Options, ""),
    ModuleNamePrefix = proplists:get_value(module_name_prefix, Options, ""),
    CompiledPB =  filename:join(OutDir, ModuleNamePrefix++filename:basename(Filename, ".proto") ++ ModuleNameSuffix++".erl"),
    rebar_log:log(info, "Writing ~s", [CompiledPB]),
    ok = gpb_compile:file(Filename, [{rename,{msg_name,snake_case}},
                                     {rename,{msg_fqname,base_name}},
                                     use_packages, maps,
                                     strings_as_binaries, {i, "."}, {o, OutDir} | Options]),
    GpbInludeDir = filename:join(code:lib_dir(gpb), "include"),
    case compile:file(CompiledPB,
                      [binary, {i, GpbInludeDir}, return_errors]) of
        {ok, Module, Compiled} ->
            {module, _} = code:load_binary(Module, CompiledPB, Compiled),
            Module;
        {ok, Module, Compiled, Warnings} ->
            [begin
                 rebar_api:warn("Warning building ~s~n", [File]),
                 [rebar_api:warn("        ~p: ~s", [Line, M:format_error(E)]) || {Line, M, E} <- Es]
             end || {File, Es} <- Warnings],
            {module, _} = code:load_binary(Module, CompiledPB, Compiled),
            Module;
        {error, Errors, Warnings} ->
            throw(?PRV_ERROR({compile_errors, Errors, Warnings}))
    end.

maybe_snake_case(name, Name) ->
    list_snake_case(Name);
maybe_snake_case(_, "true") ->
    true;
maybe_snake_case(_, "false") ->
    false;
maybe_snake_case(_, Value) ->
    Value.

list_snake_case(NameString) ->
    Snaked = lists:foldl(fun(RE, Snaking) ->
                                 re:replace(Snaking, RE, "\\1_\\2", [{return, list},
                                                                     global])
                         end, NameString, [%% uppercase followed by lowercase
                                           "(.)([A-Z][a-z]+)",
                                           %% any consecutive digits
                                           "(.)([0-9]+)",
                                           %% uppercase with lowercase
                                           %% or digit before it
                                           "([a-z0-9])([A-Z])"]),
    Snaked1 = string:replace(Snaked, ".", "_", all),
    Snaked2 = string:replace(Snaked1, "__", "_", all),
    string:to_lower(unicode:characters_to_list(Snaked2)).
