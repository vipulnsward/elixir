-module(elixir_module).
-export([compile/4, compile/5, data_table/1, docs_table/1,
         eval_quoted/4, format_error/1, eval_callbacks/5]).
-include("elixir.hrl").

-define(acc_attr, '__acc_attributes').
-define(docs_attr, '__docs_table').
-define(lexical_attr, '__lexical_tracker').
-define(persisted_attr, '__persisted_attributes').
-define(overridable_attr, '__overridable').

eval_quoted(Module, Quoted, Binding, Opts) ->
  Scope = scope_for_eval(Module, Opts),
  elixir_def:reset_last(Module),

  case lists:keyfind(line, 1, Opts) of
    { line, Line } -> Line;
    false -> Line = 1
  end,

  { Value, FinalBinding, _Scope } = elixir:eval_quoted([Quoted], Binding, Line, Scope),
  { Value, FinalBinding }.

scope_for_eval(Module, #elixir_scope{} = S) ->
  S#elixir_scope{module=Module};
scope_for_eval(Module, Opts) ->
  scope_for_eval(Module, elixir:scope_for_eval(Opts)).

%% TABLE METHODS

data_table(Module) ->
  Module.

docs_table(Module) ->
  ets:lookup_element(Module, ?docs_attr, 2).

%% Compilation hook

compile(Module, Block, Vars, ExEnv) ->
  #elixir_env{line=Line} = Env = elixir_env:ex_to_env(ExEnv),
  Dict = [{ { Name, Kind }, Value } || { Name, Kind, Value, _ } <- Vars],

  %% In case we are generating a module from inside a function,
  %% we get rid of the lexical tracker information as, at this
  %% point, the lexical tracker process is long gone.
  LexEnv = case Env#elixir_env.function of
    nil -> Env;
    _   -> Env#elixir_env{lexical_tracker=nil, function=nil}
  end,

  compile(Line, Module, Block, Vars, elixir_env:env_to_scope_with_vars(LexEnv, Dict)).

compile(Line, Module, Block, Vars, RawS) when is_atom(Module) ->
  C = elixir_compiler:get_opts(),
  S = RawS#elixir_scope{module=Module},

  File = S#elixir_scope.file,
  FileList = elixir_utils:characters_to_list(File),

  check_module_availability(Line, File, Module, C),
  build(Line, File, Module, S#elixir_scope.lexical_tracker),

  try
    Result = eval_form(Line, Module, Block, Vars, S),
    { Base, Export, Private, Def, Defmacro, Functions } = elixir_def:unwrap_definitions(FileList, Module),

    { All, Forms0 } = functions_form(Line, File, Module, Base, Export, Def, Defmacro, Functions, C),
    Forms1          = specs_form(Module, Private, Defmacro, Forms0),
    Forms2          = attributes_form(Line, File, Module, Forms1),
    Forms3          = typedocs_form(Module, Forms2),

    case ets:lookup(data_table(Module), 'on_load') of
      [] -> ok;
      [{on_load,OnLoad}] ->
        [elixir_tracker:record_local(Tuple, Module) || Tuple <- OnLoad]
    end,

    AllFunctions = Def ++ [T || { T, defp, _, _, _ } <- Private],
    elixir_tracker:ensure_no_function_conflict(Line, File, Module, AllFunctions),
    elixir_tracker:warn_unused_local(File, Module, Private),
    warn_invalid_clauses(Line, File, Module, All),
    warn_unused_docs(Line, File, Module),

    Final = [
      { attribute, Line, file, { FileList, Line } },
      { attribute, Line, module, Module } | Forms3
    ],

    Binary = load_form(Line, Final, compile_opts(Module), S),
    { module, Module, Binary, Result }
  after
    elixir_tracker:cleanup(Module),
    elixir_def:cleanup(Module),
    ets:delete(docs_table(Module)),
    ets:delete(data_table(Module))
  end;

compile(Line, Other, _Block, _Vars, #elixir_scope{file=File}) ->
  elixir_errors:form_error(Line, File, ?MODULE, { invalid_module, Other }).

%% Hook that builds both attribute and functions and set up common hooks.

build(Line, File, Module, Lexical) ->
  %% Table with meta information about the module.
  DataTable = data_table(Module),

  case ets:info(DataTable, name) == DataTable of
    true  -> elixir_errors:form_error(Line, File, ?MODULE, { module_in_definition, Module });
    false -> []
  end,

  ets:new(DataTable, [set, named_table, public]),
  ets:insert(DataTable, { before_compile, [] }),
  ets:insert(DataTable, { after_compile, [] }),

  case elixir_compiler:get_opt(docs) of
    true -> ets:insert(DataTable, { on_definition, [{ 'Elixir.Module', compile_doc }] });
    _    -> ets:insert(DataTable, { on_definition, [] })
  end,

  Attributes = [behavior, behaviour, on_load, spec, type, export_type, opaque, callback, compile],
  ets:insert(DataTable, { ?acc_attr, [before_compile, after_compile, on_definition|Attributes] }),
  ets:insert(DataTable, { ?persisted_attr, [vsn|Attributes] }),
  ets:insert(DataTable, { ?docs_attr, ets:new(DataTable, [ordered_set, public]) }),
  ets:insert(DataTable, { ?lexical_attr, Lexical }),
  ets:insert(DataTable, { ?overridable_attr, [] }),

  %% Setup other modules
  elixir_def:setup(Module),
  elixir_tracker:setup(Module).

%% Receives the module representation and evaluates it.

eval_form(Line, Module, Block, Vars, S) ->
  KV = [{ K, V } || { _, _, K, V } <- Vars],
  { Value, NewS } = elixir_compiler:eval_forms([Block], Line, KV, S),
  elixir_def_overridable:store_pending(Module),
  Env = elixir_env:scope_to_ex({ Line, S }),
  eval_callbacks(Line, Module, before_compile, [Env], NewS),
  elixir_def_overridable:store_pending(Module),
  Value.

%% Return the form with exports and function declarations.

functions_form(Line, File, Module, BaseAll, BaseExport, Def, Defmacro, RawFunctions, C) ->
  BaseFunctions = case elixir_compiler:get_opt(internal, C) of
    true  -> RawFunctions;
    false -> record_rewrite_functions(Module, RawFunctions)
  end,

  Info = add_info_function(Line, File, Module, BaseExport, Def, Defmacro, C),

  All       = [{ '__info__', 1 }|BaseAll],
  Export    = [{ '__info__', 1 }|BaseExport],
  Functions = [Info|BaseFunctions],

  { All, [
    { attribute, Line, export, lists:sort(Export) } | Functions
  ] }.

record_rewrite_functions(Module, Functions) ->
  lists:map(fun
    ({ function, Line, Name, Arity, Clauses }) ->
      Rewriten = [begin
        { C, _, _ } = 'Elixir.Kernel.RecordRewriter':optimize_clause(Module, Clause),
        C
      end || Clause <- Clauses],
      { function, Line, Name, Arity, Rewriten };
    (Other) -> Other
  end, Functions).

%% Add attributes handling to the form

attributes_form(Line, _File, Module, Current) ->
  Table = data_table(Module),

  AccAttrs = ets:lookup_element(Table, '__acc_attributes', 2),
  PersistedAttrs = ets:lookup_element(Table, '__persisted_attributes', 2),

  Transform = fun({ Key, Value }, Acc) ->
    case lists:member(Key, PersistedAttrs) of
      false -> Acc;
      true  ->
        Attrs = case lists:member(Key, AccAttrs) of
          true  -> Value;
          false -> [Value]
        end,
        lists:foldl(fun(X, Final) -> [{ attribute, Line, Key, X }|Final] end, Acc, Attrs)
    end
  end,

  ets:foldl(Transform, Current, Table).

%% Add typedocs to the form
typedocs_form(Module, Current) ->
  Table = docs_table(Module),
  Transform = fun({ Tuple, Line, Kind, _Sig, Doc }, Acc) ->
    case Kind of
      type      -> [{ attribute, Line, typedoc, { Tuple, Doc } } | Acc];
      opaque    -> [{ attribute, Line, typedoc, { Tuple, Doc } } | Acc];
      _         -> Acc
    end
  end,
  ets:foldl(Transform, Current, Table).

%% Specs

specs_form(Module, Private, Defmacro, Forms) ->
  Defmacrop = [Tuple || { Tuple, defmacrop, _, _, _ } <- Private],
  case code:ensure_loaded('Elixir.Kernel.Typespec') of
    { module, 'Elixir.Kernel.Typespec' } ->
      Callbacks = 'Elixir.Module':get_attribute(Module, callback),
      Specs     = [translate_spec(Spec, Defmacro, Defmacrop) ||
                    Spec <- 'Elixir.Module':get_attribute(Module, spec)],

      'Elixir.Module':delete_attribute(Module, spec),
      'Elixir.Module':delete_attribute(Module, callback),

      Temp = specs_attributes(spec, Forms, Specs),
      specs_attributes(callback, Temp, Callbacks);
    { error, _ } ->
      Forms
  end.

specs_attributes(Type, Forms, Specs) ->
  Keys = lists:foldl(fun({ Tuple, Value }, Acc) ->
                       lists:keystore(Tuple, 1, Acc, { Tuple, Value })
                     end, [], Specs),
  lists:foldl(fun({ Tuple, _ }, Acc) ->
    Values = [V || { K, V } <- Specs, K == Tuple],
    { type, Line, _, _ } = hd(Values),
    [{ attribute, Line, Type, { Tuple, Values } }|Acc]
  end, Forms, Keys).

translate_spec({ Spec, Rest }, Defmacro, Defmacrop) ->
  case ordsets:is_element(Spec, Defmacrop) of
    true  -> { Spec, Rest };
    false ->
      case ordsets:is_element(Spec, Defmacro) of
        true ->
          { Name, Arity } = Spec,
          { { ?elixir_macro(Name), Arity + 1 }, spec_for_macro(Rest) };
        false ->
          { Spec, Rest }
      end
  end.

spec_for_macro({ type, Line, 'fun', [{ type, _, product, Args }|T] }) ->
  NewArgs = [{type,Line,term,[]}|Args],
  { type, Line, 'fun', [{ type, Line, product, NewArgs }|T] };

spec_for_macro(Else) -> Else.

%% Loads the form into the code server.

compile_opts(Module) ->
  case ets:lookup(data_table(Module), compile) of
    [{compile,Opts}] when is_list(Opts) -> Opts;
    [] -> []
  end.

load_form(Line, Forms, Opts, #elixir_scope{file=File} = S) ->
  elixir_compiler:module(Forms, File, Opts, fun(Module, Binary) ->
    Env = elixir_env:scope_to_ex({ Line, S }),
    eval_callbacks(Line, Module, after_compile, [Env, Binary], S),

    case get(elixir_compiled) of
      Current when is_list(Current) ->
        put(elixir_compiled, [{Module,Binary}|Current]),

        case get(elixir_compiler_pid) of
          undefined -> [];
          PID ->
            Ref = make_ref(),
            PID ! { module_available, self(), Ref, File, Module, Binary },
            receive { Ref, ack } -> ok end
        end;
      _ ->
        []
    end,

    Binary
  end).

check_module_availability(Line, File, Module, Compiler) ->
  case elixir_compiler:get_opt(ignore_module_conflict, Compiler) of
    false ->
      case code:ensure_loaded(Module) of
        { module, _ } ->
          elixir_errors:handle_file_warning(File, { Line, ?MODULE, { module_defined, Module } });
        { error, _ } ->
          []
      end;
    true ->
      []
  end.

warn_invalid_clauses(_Line, _File, 'Elixir.Kernel.SpecialForms', _All) -> ok;
warn_invalid_clauses(_Line, File, Module, All) ->
  ets:foldl(fun
    ({ _, _, Kind, _, _ }, _) when Kind == type; Kind == opaque ->
      ok;
    ({ Tuple, Line, _, _, _ }, _) ->
      case lists:member(Tuple, All) of
        false ->
          elixir_errors:handle_file_warning(File, { Line, ?MODULE, { invalid_clause, Tuple } });
        true ->
          ok
      end
  end, ok, docs_table(Module)).

warn_unused_docs(Line, File, Module) ->
  lists:foreach(fun(Attribute) ->
    case ets:member(data_table(Module), Attribute) of
      true ->
        elixir_errors:handle_file_warning(File, { Line, ?MODULE, { unused_doc, Attribute } });
      _ ->
        ok
    end
  end, [typedoc]).

% EXTRA FUNCTIONS

add_info_function(Line, File, Module, Export, Def, Defmacro, C) ->
  Pair = { '__info__', 1 },
  case lists:member(Pair, Export) of
    true  ->
      elixir_errors:form_error(Line, File, ?MODULE, {internal_function_overridden, Pair});
    false ->
      Docs = elixir_compiler:get_opt(docs, C),
      { function, 0, '__info__', 1, [
        functions_clause(Def),
        macros_clause(Defmacro),
        docs_clause(Module, Docs),
        moduledoc_clause(Line, Module, Docs),
        module_clause(Module),
        else_clause()
      ] }
  end.

functions_clause(Def) ->
  { clause, 0, [{ atom, 0, functions }], [], [elixir_utils:elixir_to_erl(Def)] }.

macros_clause(Defmacro) ->
  { clause, 0, [{ atom, 0, macros }], [], [elixir_utils:elixir_to_erl(Defmacro)] }.

module_clause(Module) ->
  { clause, 0, [{ atom, 0, module }], [], [{ atom, 0, Module }] }.

docs_clause(Module, true) ->
  Docs = ordsets:from_list(
    [{Tuple, Line, Kind, Sig, Doc} ||
     {Tuple, Line, Kind, Sig, Doc} <- ets:tab2list(docs_table(Module)),
     Kind =/= type, Kind =/= opaque]),
  { clause, 0, [{ atom, 0, docs }], [], [elixir_utils:elixir_to_erl(Docs)] };

docs_clause(_Module, _) ->
  { clause, 0, [{ atom, 0, docs }], [], [{ atom, 0, nil }] }.

moduledoc_clause(Line, Module, true) ->
  Docs = 'Elixir.Module':get_attribute(Module, moduledoc),
  { clause, 0, [{ atom, 0, moduledoc }], [], [elixir_utils:elixir_to_erl({ Line, Docs })] };

moduledoc_clause(_Line, _Module, _) ->
  { clause, 0, [{ atom, 0, moduledoc }], [], [{ atom, 0, nil }] }.

else_clause() ->
  Info = { call, 0, { atom, 0, module_info }, [{ var, 0, atom }] },
  { clause, 0, [{ var, 0, atom }], [], [Info] }.

% HELPERS

eval_callbacks(Line, Module, Name, Args, RawS) ->
  { Binding, S } = elixir_scope:load_binding([], RawS),
  Callbacks = lists:reverse(ets:lookup_element(data_table(Module), Name, 2)),
  Meta      = [{line,Line},{require,false}],

  lists:foreach(fun({M,F}) ->
    { Tree, _ } = elixir_dispatch:dispatch_require(Meta, M, F, Args, S, fun() ->
      apply(M, F, Args),
      { { atom, 0, nil }, S }
    end),

    case Tree of
      { atom, _, Atom } ->
        Atom;
      _ ->
        try
          erl_eval:exprs([Tree], Binding)
        catch
          Kind:Reason ->
            Info = { M, F, length(Args), [{ file, elixir_utils:characters_to_list(S#elixir_scope.file) }, { line, Line }] },
            erlang:raise(Kind, Reason, prune_stacktrace(Info, erlang:get_stacktrace()))
        end
    end
  end, Callbacks).

%% We've reached the elixir_module or erl_eval internals, skip it with the rest
prune_stacktrace(Info, [{ erl_eval, _, _, _ }|_]) ->
  [Info];

prune_stacktrace(Info, [{ elixir_module, _, _, _ }|_]) ->
  [Info];

prune_stacktrace(Info, [H|T]) ->
  [H|prune_stacktrace(Info, T)];

prune_stacktrace(Info, []) ->
  [Info].

% ERROR HANDLING

format_error({ invalid_clause, { Name, Arity } }) ->
  io_lib:format("empty clause provided for nonexistent function or macro ~ts/~B", [Name, Arity]);

format_error({ unused_doc, typedoc }) ->
  "@typedoc provided but no type follows it";

format_error({ unused_doc, doc }) ->
  "@doc provided but no definition follows it";

format_error({ internal_function_overridden, { Name, Arity } }) ->
  io_lib:format("function ~ts/~B is internal and should not be overridden", [Name, Arity]);

format_error({ invalid_module, Module}) ->
  io_lib:format("invalid module name: ~p", [Module]);

format_error({ module_defined, Module }) ->
  io_lib:format("redefining module ~ts", [elixir_errors:inspect(Module)]);

format_error({ module_in_definition, Module }) ->
  io_lib:format("cannot define module ~ts because it is currently being defined",
    [elixir_errors:inspect(Module)]).
