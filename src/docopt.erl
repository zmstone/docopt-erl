-module(docopt).

-compile([export_all]).

%%%_* Includes ================================================================

-include_lib("eunit/include/eunit.hrl").

%-define(DEBUG, true).

%%%_* Records =================================================================

-record(state, { options = [] :: [child_pattern()]
               , tokens  = [] :: [string()]
               , mode         :: parse_mode()
               }).

%% Parent patterns
-record(one_or_more , {children :: [pattern()]}).
-record(required    , {children :: [pattern()]}).
-record(optional    , {children :: [pattern()]}).
-record(either      , {children :: [pattern()]}).

%% Child patterns
%% TODO: Default for arguments should be undefined
-record(command  , {name :: string(), value = false :: any()}).
-record(argument , {name :: string(), value = false :: any()}).
-record(option   , { short            :: string()
                   , long             :: string()
                   , argcount = 0     :: non_neg_integer()
                   , value    = false :: any()
                   }).

%%%_* Types ===================================================================

-type pattern() :: child_pattern() | parent_pattern().

-type child_pattern()  :: #command{}
                        | #argument{}
                        | #option{}.

-type parent_pattern() :: #one_or_more{}
                        | #required{}
                        | #optional{}
                        | #either{}.

-type parse_mode() :: parse_args | parse_pattern.

%%%_* Code ====================================================================

docopt(Doc, Args) ->
  Usage      = printable_usage(Doc),
  Options    = parse_doc_options(Doc),
  Pattern    = parse_pattern(formal_usage(Usage), Options),
  ParsedArgs = parse_args(Args, Options),
  case match(fix_list_arguments(Pattern), ParsedArgs) of
    {true, [], Collected} ->
      ct:pal("\n"
             "args:       ~p\n"
             "usage:      ~p\n"
             "options:    ~p\n"
             "pattern:    ~p\n"
             "parsedargs: ~p\n"
             "collected:  ~p\n"
             "flat patns: ~p\n",
         [Args,Usage,Options,Pattern,ParsedArgs,Collected,flatten(Pattern)]),
      lists:foldl(fun (Pat, Acc) ->
                      orddict:store(name(Pat), value(Pat), Acc)
                  end, orddict:new(), flatten(Pattern) ++ Options ++ Collected);
    Res -> {error, {"failed to parse :(", Res}}
  end.

fix_list_arguments(Pat) ->
  Either   = [children(C) || C <- children(fix_either(Pat))],
  FixThese = [E || Case <- Either, E <- Case, count(E, Case) > 1],
  do_fix_list_arguments(Pat, FixThese).

count(X, Patterns) ->
  length([P || P <- Patterns, X == P]).

do_fix_list_arguments(Pat, FixThese) ->
  case children(Pat) of
    undefined ->
      case lists:member(Pat, FixThese) of
        false -> Pat;
        true  -> set_default_value(Pat)
      end;
    Children ->
      set_children(Pat, [do_fix_list_arguments(C, FixThese) || C <- Children])
  end.

fix_either(Pat) when not is_list(Pat) ->
  either(lists:map(fun ([[_|_]=P]) -> req(P);
                       (P)         -> req(P)
                   end, fix_either([[Pat]])));
fix_either([]) -> [];
fix_either([Children0|Groups0]) ->
  Groups = lists:foldl(fun(Type, false) ->
                           %% Eeek, matching on record tuple structure..
                           case lists:keyfind(Type, 1, Children0) of
                             false -> false;
                             Pat   ->
                               Children = lists:delete(Pat, Children0),
                               Groups0 ++ fix_either(Pat, Children)
                           end;
                          (_Type, Acc) -> Acc
                       end, false, [either, required, optional, one_or_more]),
  case Groups of
    false  -> [Children0|fix_either(Groups0)];
    Groups -> fix_either(Groups)
  end.

fix_either(#either{}=Pat, Children)      ->
  [[C|Children] || C <- Pat#either.children];
fix_either(#required{}=Pat, Children)    -> [Pat#required.children ++ Children];
fix_either(#optional{}=Pat, Children)    -> [Pat#optional.children ++ Children];
fix_either(#one_or_more{}=Pat, Children) ->
  [Pat#one_or_more.children ++ Pat#one_or_more.children ++ Children].

flatten(#required{children=Children})    -> flatten_children(Children);
flatten(#either{children=Children})      -> flatten_children(Children);
flatten(#one_or_more{children=Children}) -> flatten_children(Children);
flatten(#optional{children=Children})    -> flatten_children(Children);
flatten(#command{}=Cmd)                  -> [Cmd];
flatten(#option{}=Opt)                   -> [Opt];
flatten(#argument{}=Arg)                 -> [Arg].

flatten_children(Children) ->
  lists:flatten(lists:map(fun flatten/1, Children)).

children(#required{children=Children})    -> Children;
children(#either{children=Children})      -> Children;
children(#one_or_more{children=Children}) -> Children;
children(#optional{children=Children})    -> Children;
children(_)                               -> undefined.

set_children(#required{}    = P, Children) -> P#required{children=Children};
set_children(#either{}      = P, Children) -> P#either{children=Children};
set_children(#one_or_more{} = P, Children) -> P#one_or_more{children=Children};
set_children(#optional{}    = P, Children) -> P#optional{children=Children}.

name(#command{name=Name})                 -> Name;
name(#argument{name=Name})                -> Name;
name(#option{long=undefined, short=Name}) -> Name;
name(#option{long=Name})                  -> Name.

value(#command{value=Value})  -> Value;
value(#argument{value=Value}) -> Value;
value(#option{value=Value})   -> Value.

set_value(#command{}  = P, Value) -> P#command{value=Value};
set_value(#argument{} = P, Value) -> P#argument{value=Value};
set_value(#option{}   = P, Value) -> P#option{value=Value}.

set_default_value(#argument{}         = P) -> P#argument{value=[]};
set_default_value(#command{}          = P) -> P#command{value=0};
set_default_value(#option{argcount=0} = P) -> P#option{value=0};
set_default_value(#option{}           = P) -> P#option{value=[]}.

parse_doc_options(Doc) ->
  [_|OptStrings] = re:split(Doc, "^ *-|\\n *-", [{return, list}]),
  [option_parse("-" ++ S) || S <- OptStrings].

strip(Str) ->
  StripLeft = fun (S) ->
                  lists:dropwhile(fun(C) -> lists:member(C, [$ , $\n]) end, S)
              end,
  lists:reverse(StripLeft(lists:reverse(StripLeft(Str)))).

option_parse(Str) ->
  {Options, Desc} = partition(strip(Str), "  "),
  lists:foldl(fun([$-,$-|_] = S, Opt) -> Opt#option{long  = S};
                 ([$-|_]    = S, Opt) -> Opt#option{short = S};
                 (_            , Opt) ->
                  Opt#option{argcount = 1, value = default_value(Desc)}
              end, #option{}, string:tokens(Options, ",= ")).

default_value(Desc) ->
  case re:run(Desc,"\\[default: (.*)\\]", [{capture, [1], list}, caseless]) of
    {match, [DefaultValue]} -> DefaultValue;
    nomatch                 -> false
  end.

parse_args(Args, Options) ->
  State = #state{ tokens  = string:tokens(Args, " ")
                , options = Options
                , mode    = parse_args
                },
  parse_args_tokens(State).

parse_args_tokens(#state{tokens=[]}) -> [];
parse_args_tokens(State0) ->
  case current(State0) of
    "--"      -> [#argument{value=Arg} || Arg <- tokens(State0)];
    [$-,$-|_] ->
      {Opts, State} = parse_long(State0),
      Opts ++ parse_args_tokens(State);
    [$-|_]    ->
      {Opts, State} = parse_shorts(State0),
      Opts ++ parse_args_tokens(State);
    _         ->
      [#argument{value=current(State0)}|parse_args_tokens(move(State0))]
  end.

current(#state{tokens=[Current|_]}) -> Current;
current(#state{tokens=[]})          -> undefined.
move(#state{tokens=[_|Rest]}=St)    -> St#state{tokens=Rest}.
tokens(#state{tokens=Tokens})       -> Tokens.
rest(#state{tokens=[_|Rest]})       -> Rest.
options(#state{options=Options})    -> Options.
mode(#state{mode=Mode})             -> Mode.

parse_long(State0) ->
  {Raw, Value} = partition(current(State0), "="),
  Opt0 = lists:filter(fun (#option{long=Long}) ->
                          Long == Raw orelse (mode(State0) == parse_args
                                              andalso starts_with(Long, Raw))
                      end, options(State0)),
  {Opt, State} = case {mode(State0), Opt0} of
                   {parse_pattern, []} ->
                     Argcount = case Value == [] of
                                  true  -> 0;
                                  false -> 1
                                end,
                     O = #option{long=Raw, argcount=Argcount},
                     {O, move(State0#state{options=[O|options(State0)]})};
                   {parse_args, []} -> throw({Raw, "not recognized"});
                   {_, [O]} -> {O, move(State0)};
                   {_, _}   -> throw({Raw, "is not a unique prefix"})
                 end,
  Rest = tokens(State),
  case Opt#option.argcount of
    1 when Value == [],
           Rest  == [] -> throw({Raw, "requires an argument"});
    1 when Value == [] -> {[Opt#option{value = current(State)}], move(State)};
    1 when Value /= [] -> {[Opt#option{value = Value}], State};
    0 when Value /= [] -> throw({Raw, "must not have an argument"});
    0 when Value == [] -> {[Opt#option{value = true}], State}
  end.

starts_with(Str, SubStr) when is_list(Str), is_list(SubStr) ->
  string:str(Str, SubStr) == 1;
starts_with(_, _) -> false.

parse_shorts(State) ->
  [$-|Str] = current(State),
  parse_shorts(Str, move(State), []).

parse_shorts([], State, Acc) -> {lists:reverse(Acc), State};
parse_shorts([H|T], State, Acc) ->
 case [O || O <- options(State), tl(O#option.short) == [H]] of
   [] when State#state.mode == parse_args ->
     throw({[$-, H], "not recognized", State});
   [] when State#state.mode == parse_pattern ->
     %% TODO: What about value here? Probably needs to parse value...
     Opt = #option{short=[$-, H], value=true},
     parse_shorts(T, State#state{options=[Opt|options(State)]}, [Opt|Acc]);
   Opt when length(Opt) > 1 -> throw({[$-, H], "specified ambiguously"});
   [Opt] when Opt#option.argcount == 0 ->
     parse_shorts(T, State, [Opt#option{value = true}|Acc]);
   [Opt] ->
     {Value, Rest} = get_value_shorts(H, T, State),
     {[Opt#option{value = Value}], Rest}
 end.

get_value_shorts(H, [], [])     -> throw({H, "requires an argument"});
get_value_shorts(_, [], State)  -> {current(State), move(State)};
get_value_shorts(_, Arg, State) -> {Arg, State}.

printable_usage(Doc) ->
  case re:split(Doc, "([Uu][Ss][Aa][Gg][Ee]:)", [{return, list}]) of
    UsageSplit when length(UsageSplit) < 3 ->
      throw("\"usage:\" (case-insensitive) not found.");
    UsageSplit when length(UsageSplit) > 3 ->
      throw("More than one \"usage:\" (case-insensitive)");
    [_|UsageSplit] ->
      L = re:split(lists:flatten(UsageSplit), "\\n\\s*\\n", [{return, list}]),
      strip(hd(L))
  end.

formal_usage(PrintableUsage) ->
  %% Split and drop "usage:"
  [_Usage, ProgName|Args] = string:tokens(PrintableUsage, " \n"),
  F = fun (S) when S == ProgName -> ") | (";
          (S)                    -> S
      end,
  "( " ++ string:join(lists:map(F, Args), " ") ++ " )".

parse_pattern(Source0, Options) ->
  %% Add spaces around []()| and ...
  Source = re:replace(Source0, "([\\[\\]\\(\\)\\|]|\\.\\.\\.)", " \\1 ",
                      [{return, list}, global]),
  State = #state{ tokens  = string:tokens(Source, " ")
                , options = Options
                , mode    = parse_pattern
                },
  {Result, _} = parse_expr(State),
  #required{children=Result}.

% expr ::= seq ( '|' seq )* ;
parse_expr(State0) ->
  {Seq, State} = parse_seq(State0),
  case current(State) of
    "|" -> parse_expr(move(State), [maybe_required_seq(Seq)]);
    _   -> {Seq, State}
  end.

parse_expr(State0, Acc)                 ->
  debug("in parse_expr: ~p, ~p", [tokens(State0), Acc]),
  {Seq, State} = parse_seq(State0),
  debug("in parse_expr after parse_seq: ~p, ~p", [tokens(State), Seq]),
  case current(State) of
    "|" -> parse_expr(move(State), [maybe_required_seq(Seq)|Acc]);
    _   ->
      case lists:reverse([maybe_required_seq(Seq)|Acc]) of
        Result when length(Result) > 1 -> {[#either{children=Result}], State};
        Result                         -> {Result, State} % Needed?
      end
   end.

maybe_required_seq([Seq]) -> Seq;
maybe_required_seq(Seq)   -> #required{children=Seq}.

%% seq ::= ( atom [ '...' ] )* ;
parse_seq(State) -> parse_seq(State, []).

parse_seq(#state{tokens=[]}      = State, Acc) -> {lists:reverse(Acc), State};
parse_seq(#state{tokens=["]"|_]} = State, Acc) -> {lists:reverse(Acc), State};
parse_seq(#state{tokens=[")"|_]} = State, Acc) -> {lists:reverse(Acc), State};
parse_seq(#state{tokens=["|"|_]} = State, Acc) -> {lists:reverse(Acc), State};
parse_seq(State0, Acc) ->
  debug("in parse seq: ~p, ~p", [tokens(State0), Acc]),
  {Atom, State} = parse_atom(State0),
  debug("in parse seq after parse_atom: ~p, ~p, ~p", [Atom, tokens(State), Acc]),
  case current(State) of
    "..." -> parse_seq(move(State), [#one_or_more{children=Atom}|Acc]);
    _     -> parse_seq(State, Atom ++ Acc)
  end.

%% atom ::= '(' expr ')' | '[' expr ']' | 'options'
%%       | long | shorts | argument | command ;
parse_atom(State) ->
  debug("in parse atom: ~p", [tokens(State)]),
  case current(State) of
    "["       -> parse_optional(move(State));
    "("       -> parse_required(move(State));
    "options" -> {options(State), move(State)};
    [$-,$-|_] -> parse_long(State);
    [$-|_]    -> parse_shorts(State);
    Current   ->
      case is_arg(Current) of
        true  -> {[#argument{name=Current}], move(State)};
        false -> {[#command{name=Current}] , move(State)}
      end
  end.

parse_optional(State0) ->
  debug("parse optional ~p", [State0]),
  {Expr, State} = parse_expr(State0),
  debug("parse optional after parse_expr ~p\n~p", [Expr, State]),
  case current(State) of
    "]" -> {[#optional{children=Expr}], move(State)};
    _   -> throw("Unmatched '['")
  end.

parse_required(State0) ->
  debug("parse required ~p", [tokens(State0)]),
  {Expr, State} = parse_expr(State0),
  debug("parse required after parse_expr ~p, ~p", [tokens(State), Expr]),
  case current(State) of
    ")" -> {[#required{children=Expr}], move(State)};
    Res -> throw({"Unmatched '(':", Res})
  end.

is_arg(S) ->
  (hd(S) == $< andalso lists:last(S) == $>) orelse string:to_upper(S) == S.

match(Pat, Rest) ->
  {Bool, R, A} = match(Pat, Rest, []),
  {Bool, R, lists:reverse(A)}.

match(#optional{}    = Pat, Rest, Acc) -> match_optional(Pat, Rest, Acc);
match(#required{}    = Pat, Rest, Acc) -> match_required(Pat, Rest, Acc);
match(#either{}      = Pat, Rest, Acc) -> match_either(Pat, Rest, Acc);
match(#one_or_more{} = Pat, Rest, Acc) -> match_one_or_more(Pat, Rest, Acc);
match(                 Pat, Rest, Acc) -> match_child_pattern(Pat, Rest, Acc).

match_optional(#optional{children=Children}, Rest0, Acc0) ->
  lists:foldl(fun(Pat, {true, R, A}) ->
                  {_, Rest, Acc} = match(Pat, R, A),
                  {true, Rest, Acc}
              end, {true, Rest0, Acc0}, Children).

match_required(#required{children=Children}, Rest0, Acc0) ->
  lists:foldl(fun(Pat, {true, R, A}) ->
                  case match(Pat, R, A) of
                    {true , _, _} = Res -> Res;
                    {false, _, _}       -> {false, Rest0, Acc0}
                  end;
                 (_, {false, _, _}) -> {false, Rest0, Acc0}
              end, {true, Rest0, Acc0}, Children).

match_either(#either{children=Children}, Rest0, Acc0) ->
  Outcomes = lists:foldl(fun(Pat, Acc) ->
                             case match(Pat, Rest0, Acc0) of
                               {true , _, _} = Res -> [Res|Acc];
                               {false, _, _}       -> Acc
                             end
                         end, [], Children),
  case lists:reverse(Outcomes) of
    []    -> {false, Rest0, Acc0};
    [H|T] -> lists:foldl(fun most_consumed/2, H, T)
  end.

most_consumed({_, R, _}=Res, {_, Min, _}) when length(R) < length(Min) -> Res;
most_consumed({_, _, _}    , Acc)                                      -> Acc.

match_one_or_more(#one_or_more{children=[Child]}, Rest0, Acc0) ->
  case consume_one_or_more(Child, Rest0, Acc0) of
    {Rest0, Acc0} -> {false, Rest0, Acc0};
    {Rest, Acc}   -> {true, Rest, Acc}
  end.

consume_one_or_more(Pat, Rest0, Acc0) ->
  case match(Pat, Rest0, Acc0) of
    {true, Rest, Acc}  -> consume_one_or_more(Pat, Rest, Acc);
    {false, Rest, Acc} -> {Rest, Acc}
  end.

match_child_pattern(Pat, Rest0, Acc) ->
  case single_match(Pat, Rest0) of
    nomatch              -> {false, Rest0, Acc};
    {match, Match, Rest} ->
      SameName = lists:filter(match_fun(Pat), Acc),
      %% TODO: Refactor this crap
      case value(Pat) of
        0 ->
          case SameName of
            []       -> {true, Rest, [set_value(Match, 1)|Acc]};
            [Same|_] -> {true, Rest, replace(Same, set_value(Same, value(Same)+1), Acc)}
          end;
        [] ->
          case SameName of
            []       -> {true, Rest, [set_value(Match, [value(Match)])|Acc]};
            [Same|_] -> {true, Rest, replace(Same, set_value(Same, value(Same) ++ [value(Match)]), Acc)}
          end;
        _Value -> {true, Rest, [Match|Acc]}
      end
  end.

replace(_Old, New, [])     -> [New];
replace(Old, New, [Old|T]) -> [New|T];
replace(Old, New, [H|T])   -> [H|replace(Old, New, T)].

replace_test() ->
  ?assertEqual([a,2,3], replace(1, a, [1,2,3])),
  ?assertEqual([a]    , replace(1, a, [])),
  ?assertEqual([2,3,a], replace(1, a, [2,3])),
  ?assertEqual([1,b,3], replace(2, b, [1,2,3])).

single_match(Pat, Rest) ->
  case lists:filter(match_fun(Pat), Rest) of
    []        -> nomatch;
    [Match|_] -> {match, match_result(Pat, Match), lists:delete(Match, Rest)}
  end.

match_result(#option{}   = Opt, O) -> Opt#option{value=O#option.value};
match_result(#argument{} = Arg, A) -> Arg#argument{value=A#argument.value};
match_result(#command{}  = Cmd, _) -> Cmd#command{value=true}.

match_fun(#option{}=Opt) ->
  fun(#option{}=O) -> name(O) == name(Opt);
     (_)           -> false
  end;
match_fun(#argument{}) ->
  fun(#argument{}) -> true;
     (_)           -> false
  end;
match_fun(#command{name=Name}) ->
  fun(#argument{value=Arg}) -> Arg == Name;
     (_)                    -> false
  end.

partition(Str, Delim) ->
  case string:str(Str, Delim) of
    0 -> {Str, ""};
    I -> {string:substr(Str, 1, I - 1), string:substr(Str, I + length(Delim))}
  end.

-ifdef(DEBUG).
debug(Fmt, Args) -> ct:pal(Fmt, Args).
-else.
debug(_Fmt, _Args) -> ok.
-endif.

%%%_* Tests ===================================================================

docopt_any_options_test_() ->
  Doc = "Usage: prog [options] A

    -q  Be quiet
    -v  Be verbose.",
  D = fun(L) -> orddict:from_list(L) end,
  [ ?_assertEqual(D([{"A", "arg"}, {"-v", false}, {"-q", false}]),
                  docopt(Doc, "arg"))
  , ?_assertEqual(D([{"A", "arg"}, {"-v", true}, {"-q", false}]),
                  docopt(Doc, "-v arg"))
  , ?_assertEqual(D([{"A", "arg"}, {"-v", false}, {"-q", true}]),
                  docopt(Doc, "-q arg"))
  ].

docopt_commands_test_() ->
  D = fun(L) -> orddict:from_list(L) end,
  [ ?_assertEqual(D([{"add", true}]) , docopt("Usage: prog add", "add"))
  , ?_assertEqual(D([{"add", false}]), docopt("Usage: prog [add]", ""))
  , ?_assertEqual(D([{"add", true}]) , docopt("Usage: prog [add]", "add"))
  , ?_assertEqual(D([{"add", true}, {"rm", false}]),
                  docopt("Usage: prog (add|rm)", "add"))
  , ?_assertEqual(D([{"add", false}, {"rm", true}]),
                  docopt("Usage: prog (add|rm)", "rm"))
  , ?_assertEqual(D([{"a", true}, {"b", true}]),
                  docopt("Usage: prog a b", "a b"))
  %% TODO:
  %% , ?_assertThrow(_, docopt("Usage: prog a b", "b a"))
  ]
.

parse_doc_options_test() ->
  Doc = "-h, --help  Print help message.
         -o FILE     Output file.
         --verbose   Verbose mode.",
  ?assertEqual([ opt("-h", "--help")
               , opt("-o", undefined, 1)
               , opt(undefined, "--verbose")
               ], parse_doc_options(Doc)).

basic_pattern_matching_test_() ->
  %% ( -a N [ -x Z ] )
  P = req([opt("-a"), arg("N"), optional([opt("-x"), arg("Z")])]),
  [ { "-a N"
    , ?_assertEqual({true, [], [opt("-a"), arg("N", 9)]},
                    match(P, [opt("-a"), arg(9)]))}
  , { "-a -x N Z"
    , ?_assertEqual({true, [], [opt("-a"), arg("N",9), opt("-x"), arg("Z", 5)]},
                    match(P, [opt("-a"), opt("-x"), arg(9), arg(5)]))}
  , { "-x N Z # BZZ!"
    , ?_assertEqual({false, [opt("-x"), arg(9), arg(5)], []},
                    match(P, [opt("-x"), arg(9), arg(5)]))}
  ].

%% TODO:
%% allow_double_dash_test_() ->
%%   Doc = "Usage: prog [-o] [--] <arg>

%%          -o",
%%   D = fun(L) -> orddict:from_list(L) end,
%%   [ ?_assertEqual(D([{"-o", false}, {"<arg>", "-o"}, {"--", true}]),
%%                   docopt(Doc, "-- -o"))
%%   ].

%% TODO:
%% allow_single_dash_test_() ->
%%   [ ?_assertEqual([{"-", true}], docopt("usage: prog [-]", "-"))
%%   , ?_assertEqual([{"-", false}], docopt("usage: prog [-]", ""))
%%   ].

allow_empty_pattern_test() ->
  ?assertEqual([], docopt("usage: prog", "")).

docopt_test_() ->
  Doc = "Usage: prog [-vqr] [FILE]
                prog INPUT OUTPUT
                prog --help

  Options:
    -v  print status messages
    -q  report only file names
    -r  show all occurrences of the same error
    --help

  ",
  D = fun(L) -> orddict:from_list(L) end,
  %% TODO: FILE/INPUT/OUTPUT should be undefined, not false
  [ ?_assertEqual(D([ {"-v", true}, {"-q", false}, {"-r", false}
                    , {"--help", false}, {"FILE", "file.py"}
                    , {"INPUT", false}, {"OUTPUT", false}]),
                  docopt(Doc, "-v file.py"))
  , ?_assertEqual(D([ {"-v", true}, {"-q", false}, {"-r", false}
                    , {"--help", false}, {"FILE", false}
                    , {"INPUT", false}, {"OUTPUT", false}]),
                  docopt(Doc, "-v"))
  %% TODO: Assert exceptions
  ].

match_option_test_() ->
  A  = opt("-a"),
  AT = A#option{value = true},
  X  = opt("-x"),
  N  = arg("N"),
  [ ?_assertEqual({true , []    , [AT]}, match(A, [AT]))
  , ?_assertEqual({false, [X]   , []}  , match(A, [X]))
  , ?_assertEqual({false, [N]   , []}  , match(A, [N]))
  , ?_assertEqual({true , [X, N], [A]} , match(A, [X, A, N]))
  , ?_assertEqual({true , [A]   , [AT]}, match(A, [AT, A]))
  ].

match_argument_test_() ->
  A  = arg("V"),
  AV = arg("V", 9),
  V  = arg(9),
  V0 = arg(0),
  OX = opt("-x"),
  OA = opt("-a"),
  [ ?_assertEqual({true , []      , [AV]}, match(A, [AV]))
  , ?_assertEqual({false, [OX]    , []}  , match(A, [OX]))
  , ?_assertEqual({true , [OX, OA], [AV]}, match(A, [OX, OA, V]))
  , ?_assertEqual({true , [V0]    , [AV]}, match(A, [V, V0]))
  ].

match_command_test_() ->
  C  = cmd("c"),
  AC = arg(undefined, "c"),
  CT = cmd("c", true),
  OX = opt("-x"),
  OA = opt("-a"),
  [ ?_assertEqual({true , []      , [CT]}, match(C, [AC]))
  , ?_assertEqual({false, [OX]    , []}  , match(C, [OX]))
  , ?_assertEqual({true , [OX, OA], [CT]}, match(C, [OX, OA, AC]))
  , ?_assertEqual({true , []      , [cmd("rm", true)]},
                  match(either([cmd("add"), cmd("rm")]),
                        [arg(undefined, "rm")]))
  ].

match_optional_test_() ->
  OA = opt("-a"),
  OB = opt("-b"),
  OX = opt("-x"),
  A  = arg("A"),
  AV = arg("A", 9),
  V  = arg(9),
  [ ?_assertEqual({true, []  , [OA]}, match(optional([OA])    , [OA]))
  , ?_assertEqual({true, []  , []}  , match(optional([OA])    , []))
  , ?_assertEqual({true, [OX], []}  , match(optional([OA])    , [OX]))
  , ?_assertEqual({true, []  , [OA]}, match(optional([OA, OB]), [OA]))
  , ?_assertEqual({true, []  , [OB]}, match(optional([OA, OB]), [OB]))
  , ?_assertEqual({true, [OX], []}  , match(optional([OA, OB]), [OX]))
  , ?_assertEqual({true, []  , [AV]}, match(optional([A])     , [V]))
  , ?_assertEqual({true, [OX], [OA, OB]},
                  match(optional([OA, OB]), [OB, OX, OA]))
  ].

match_required_test_() ->
  A = opt("-a"),
  X = opt("-x"),
  [ ?_assertEqual({true , [] , [A]}, match(req([A])   , [A]))
  , ?_assertEqual({false, [] , []} , match(req([A])   , []))
  , ?_assertEqual({false, [X], []} , match(req([A])   , [X]))
  , ?_assertEqual({false, [A], []} , match(req([A, X]), [A]))
  ].

match_either_test_() ->
  OA  = opt("-a"),
  OB  = opt("-b"),
  OC  = opt("-c"),
  OX  = opt("-x"),
  AN  = arg("N"),
  AM  = arg("M"),
  A1  = arg(1),
  A2  = arg(2),
  AN1 = arg("N", 1),
  AM2 = arg("M", 2),
  [ ?_assertEqual({true , []  , [OA]}, match(either([OA, OB])    , [OA]))
  , ?_assertEqual({true , [OB], [OA]}, match(either([OA, OB])    , [OA, OB]))
  , ?_assertEqual({false, [OX], []}  , match(either([OA, OB])    , [OX]))
  , ?_assertEqual({true , [OX], [OB]}, match(either([OA, OB, OC]), [OX, OB]))
  , ?_assertEqual({true , []  , [AN1, AM2]},
                  match(either([AM, req([AN, AM])]), [A1, A2]))
  ].

match_one_or_more_test_() ->
  A  = arg("A"),
  AV = arg("A", 9),
  V  = arg(undefined, 9),
  OX = opt("-x"),
  [ ?_assertEqual({true , []  , [AV]}, match(one_or_more([A]), [V]))
  , ?_assertEqual({false, []  , []}  , match(one_or_more([A]), []))
  , ?_assertEqual({false, [OX], []}  , match(one_or_more([A]), [OX]))
  ].

parse_atom_test_() ->
  O = [ #option{short="-h"}
      , #option{short="-v", long="--verbose"}
      , #option{short="-f", long="--file", argcount=1}
      ],
  St = fun(Tokens) ->
           #state{ options = O
                 , tokens  = Tokens
                 , mode    = parse_pattern}
       end,
  [ ?_assertEqual({[#argument{name="FOO"}], St([])},
                  parse_atom(St(["FOO"])))
  , ?_assertEqual({[#argument{name="<foo>"}], St([])},
                  parse_atom(St(["<foo>"])))
  , ?_assertEqual({[#command{name="foo"}], St([])},
                  parse_atom(St(["foo"])))
  , ?_assertEqual({O, St([])},
                  parse_atom(St(["options"])))
  , ?_assertEqual({[#option{short="-v", long="--verbose", value=true}], St([])},
                  parse_atom(St(["--verbose"])))
  , ?_assertEqual({[#option{short="-h", value=true}], St([])},
                  parse_atom(St(["-h"])))
  , ?_assertEqual({[#required{children=[#argument{name="FOO"}]}], St([])},
                  parse_atom(St(["(", "FOO", ")"])))
  ].

printable_and_formal_usage_test_() ->
  Doc =
    "Usage: prog [-hv] ARG
            prog N M

     prog is a program.",
  [ ?_assertEqual("Usage: prog [-hv] ARG\n            prog N M",
                  printable_usage(Doc))
  , ?_assertEqual("( [-hv] ARG ) | ( N M )",
                  formal_usage(printable_usage(Doc)))
  , ?_assertEqual("uSaGe: prog ARG",
                  printable_usage("uSaGe: prog ARG\n\t \t\n bla"))
  ].

parse_args_test_() ->
  HelpOpt    = #option{short="-h", value=true},
  FileOpt    = #option{short="-f", long="--file", argcount=1, value="f.txt"},
  VerboseOpt = #option{short="-v", long="--verbose", value=true},
  Arg        = fun(V) -> #argument{value=V} end,
  O = [ #option{short="-h"}
      , #option{short="-v", long="--verbose"}
      , #option{short="-f", long="--file", argcount=1}
      ],
  [ ?_assertEqual([]                    , parse_args(""                , O))
  , ?_assertEqual([HelpOpt]             , parse_args("-h"              , O))
  , ?_assertEqual([HelpOpt, VerboseOpt] , parse_args("-h -v"           , O))
  , ?_assertEqual([HelpOpt, VerboseOpt] , parse_args("-hv"             , O))
  , ?_assertEqual([HelpOpt, FileOpt]    , parse_args("-h -f f.txt"     , O))
  , ?_assertEqual([HelpOpt, FileOpt]    , parse_args("-h -ff.txt"      , O))
  , ?_assertEqual([HelpOpt, FileOpt]    , parse_args("-h --file f.txt" , O))
  , ?_assertEqual([HelpOpt, FileOpt]    , parse_args("-h --file=f.txt" , O))
  , ?_assertEqual([HelpOpt, VerboseOpt] , parse_args("-h --verbose"    , O))
  , ?_assertEqual([HelpOpt, VerboseOpt] , parse_args("-h --ver"        , O))
  , ?_assertEqual([Arg("arg")]          , parse_args("arg"             , O))
  , ?_assertEqual([HelpOpt, FileOpt, Arg("arg"), Arg("arg2")],
                  parse_args("-h --file f.txt arg arg2", O))
  , ?_assertEqual([HelpOpt, Arg("arg"), Arg("--"), Arg("-v")],
                  parse_args("-h arg -- -v", O))
  ].

parse_pattern_test_() ->
  HelpOpt    = #option{short="-h", value=true},
  FileOpt    = #option{short="-f", long="--file", argcount=1, value="<f>"},
  VerboseOpt = #option{short="-v", long="--verbose", value=true},
  O = [opt("-h"), opt("-v", "--verbose"), opt("-f", "--file", 1)],
  [ ?_assertEqual(
       req([optional([HelpOpt])]),
       parse_pattern("[ -h ]", O))
  , ?_assertEqual(
       req([optional([HelpOpt])]),
       parse_pattern("[ -h ]", []))
  , ?_assertEqual(
       req([optional([#option{long="--verbose", value=true}])]),
       parse_pattern("[ --verbose ]", []))
  , ?_assertEqual(
       req([optional([one_or_more([arg("ARG")])])]),
       parse_pattern("[ ARG ... ]", O))
  , ?_assertEqual(
       req([optional([either([HelpOpt, VerboseOpt])])]),
       parse_pattern("[ -h | -v ]", O))
  , ?_assertEqual(
       req([VerboseOpt, optional([FileOpt])]),
       parse_pattern("-v [ --file <f> ]", O))
  , ?_assertEqual(
       req([optional([either([arg("M"), req([either([arg("K"),
                                                     arg("L")])])])])]),
       parse_pattern("[M | (K | L)]", O))
  , ?_assertEqual(
       req([arg("N"), arg("M")]),
       parse_pattern("N M", O))
  , ?_assertEqual(
       req([arg("N"), optional([arg("M")])]),
       parse_pattern("N [M]", O))
  , ?_assertEqual(
       req([arg("N"), optional([either([arg("M"), arg("K"), arg("L")])])]),
       parse_pattern("N [M | K | L]", O))
  , ?_assertEqual(
       req([optional([HelpOpt]), optional([arg("N")])]),
       parse_pattern("[ -h ] [N]", O))
  , ?_assertEqual(
       req([optional(lists:reverse(O))]),
       parse_pattern("[options]", O))
  , ?_assertEqual(
       req([arg("ADD")]),
       parse_pattern("ADD", O))
  , ?_assertEqual(
       req([arg("<add>")]),
       parse_pattern("<add>", O))
  , ?_assertEqual(
       req([cmd("add")]),
       parse_pattern("add", O))
  , ?_assertEqual(
       req([req([either([HelpOpt, req([VerboseOpt, optional([arg("A")])])])])]),
       parse_pattern("( -h | -v [ A ] )", O))
  , ?_assertEqual(
       req([req([either([req([arg("N"),
                              optional([either([arg("M"),
                                                req([either([arg("K"),
                                                             arg("L")
                                                            ])])])])]),
                         req([arg("O"), arg("P")])])])]),
       parse_pattern("(N [M | (K | L)] | O P)", O))
  ].

arg(A) when is_list(A) -> #argument{name=A};
arg(V)                 -> #argument{value=V}.
arg(Arg, Value)       -> #argument{name=Arg, value=Value}.
cmd(Cmd)              -> #command{name=Cmd}.
cmd(Cmd, Value)       -> #command{name=Cmd, value=Value}.
req(Children)         -> #required{children=Children}.
either(Children)      -> #either{children=Children}.
optional(Children)    -> #optional{children=Children}.
one_or_more(Children) -> #one_or_more{children=Children}.

opt(Short)            -> #option{short=Short}.
opt(Short, Long)      -> #option{short=Short, long=Long}.
opt(Short, Long, Ac)  -> #option{short=Short, long=Long, argcount=Ac}.

partition_test_() ->
  [ ?_assertEqual({"foobar", ""}     , partition("foobar"      , "abc"))
  , ?_assertEqual({"foo", "bar"}     , partition("foo bar"     , " "))
  , ?_assertEqual({"foo", "bar baz"} , partition("foo bar baz" , " "))
  , ?_assertEqual({"foo", "bar"}     , partition("foo  bar"    , "  "))
  , ?_assertEqual({"foo", "bar"}     , partition("fooabcbar"   , "abc"))
  ].

option_parse_test_() ->
  [ ?_assertEqual(#option{short="-h"}, option_parse("-h"))
  , ?_assertEqual(#option{long="--help"}, option_parse("--help"))
  , ?_assertEqual(#option{short="-h", long="--help"}, option_parse("-h --help"))
  , ?_assertEqual(#option{short="-h", long="--help"}, option_parse("--help -h"))
  , ?_assertEqual(#option{short="-h", long="--help"}, option_parse("-h,--help"))

  , ?_assertEqual(#option{short="-h", argcount=1}, option_parse("-h TOPIC"))
  , ?_assertEqual(#option{long="--help", argcount=1},
                  option_parse("--help TOPIC"))
  , ?_assertEqual(#option{short="-h", long="--help", argcount=1},
                  option_parse("-h TOPIC --help TOPIC"))
  , ?_assertEqual(#option{short="-h", long="--help", argcount=1},
                  option_parse("-h TOPIC, --help TOPIC"))
  , ?_assertEqual(#option{short="-h", long="--help", argcount=1},
                  option_parse("-h TOPIC, --help=TOPIC"))

  , ?_assertEqual(#option{short="-h"}, option_parse("-h  Description..."))
  , ?_assertEqual(#option{short="-h", long="--help"},
                  option_parse("-h --help  Description..."))
  , ?_assertEqual(#option{short="-h", argcount=1},
                  option_parse("-h TOPIC  Description..."))

  , ?_assertEqual(#option{short="-h"}, option_parse("    -h"))
  , ?_assertEqual(#option{short="-h", argcount=1, value="2"},
                  option_parse("-h TOPIC  Descripton... [default: 2]"))
  , ?_assertEqual(#option{short="-h", argcount=1, value="topic-1"},
                  option_parse("-h TOPIC  Descripton... [default: topic-1]"))
  , ?_assertEqual(#option{long="--help", argcount=1, value="3.14"},
                  option_parse("--help=TOPIC  ... [default: 3.14]"))
  , ?_assertEqual(#option{short="-h", long="--help", argcount=1, value="./"},
                  option_parse("-h, --help=DIR  ... [default: ./]"))
  , ?_assertEqual(#option{short="-h", argcount=1, value="2"},
                  option_parse("-h TOPIC  Descripton... [dEfAuLt: 2]"))
  ].

fix_either_test_() ->
  OA = opt("-a"),
  OB = opt("-b"),
  OC = opt("-c"),
  AN = arg("N"),
  AM = arg("M"),
  [ ?_assertEqual(either([req([OA])]), fix_either(OA))
  , ?_assertEqual(either([req([AN])]), fix_either(AN))
  , ?_assertEqual(either([req([AN, AM, AN, AM])]),
                  fix_either(one_or_more([AN, AM])))
  , ?_assertEqual(either([req([OA, OC]), req([OB, OC])]),
                  fix_either(req([either([OA, OB]), OC])))
  , ?_assertEqual(either([req([OB, OA]), req([OC, OA])]),
                  fix_either(optional([OA, either([OB, OC])])))
  , ?_assertEqual(either([req([OA]), req([OB]), req([OC])]),
                  fix_either(either([OA, either([OB, OC])])))

  ].

name_test_() ->
  [ ?_assertEqual("-h"    , name(opt("-h")))
  , ?_assertEqual("--help", name(opt("-h", "--help")))
  , ?_assertEqual("--help", name(opt(undefined, "--help")))
  , ?_assertEqual("foo"   , name(arg("foo")))
  , ?_assertEqual("foo"   , name(cmd("foo")))
  ].

list_argument_match_test_() ->
  M = fun (Pat, Args) -> match(fix_list_arguments(Pat), Args) end,
  [ ?_assertEqual({true, [], [arg("N", ["1", "2"])]},
                  M(req([arg("N"), arg("N")]),
                    [arg(undefined, "1"), arg(undefined, "2")]))
  , ?_assertEqual({true, [], [arg("N", ["1", "2", "3"])]},
                 M(one_or_more([arg("N")]),
                   [ arg(undefined, "1")
                   , arg(undefined, "2")
                   , arg(undefined, "3")
                   ]))
  , ?_assertEqual({true, [], [arg("N", ["1", "2", "3"])]},
                  M(req([arg("N"), one_or_more([arg("N")])]),
                    [ arg(undefined, "1")
                    , arg(undefined, "2")
                    , arg(undefined, "3")
                    ]))
  , ?_assertEqual({true, [], [arg("N", ["1", "2"])]},
                  M(req([arg("N"), req([arg("N")])]),
                    [arg(undefined, "1"), arg(undefined, "2")]))
  ].

fix_list_arguments_test_() ->
  Fix = fun fix_list_arguments/1,
  [ ?_assertEqual(opt("-a"), Fix(opt("-a")))
  , ?_assertEqual(arg("N", undefined), Fix(arg("N", undefined)))
  , ?_assertEqual(req([arg("N", []), arg("N", [])]),
                  Fix(req([arg("N"), arg("N")])))
  , ?_assertEqual(either([arg("N", []), one_or_more([arg("N", [])])]),
                  Fix(either([arg("N"), one_or_more([arg("N")])])))
  ].

strip_test_() ->
  [ ?_assertEqual(""       , strip(""))
  , ?_assertEqual("foo"    , strip("foo"))
  , ?_assertEqual("foo"    , strip("\n    \n  \nfoo"))
  , ?_assertEqual("foo"    , strip("    \n\n  \nfoo   \n \n  "))
  , ?_assertEqual("foo bar", strip("  \n  \n  \nfoo bar \n \n"))
  ].

%%%_* Emacs ===================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
