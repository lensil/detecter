-module(history).
-export([start/1, in_history/1, add_to_history/1, set_determinism_function/1, get_determinism_function/0, history_analysis/0, filter_trace/1]).

start(Monitor) ->
    case ets:info(history) of
        undefined -> 
            ets:new(history, [named_table, bag, public]),
            ets:new(monitor, [named_table, set, public]),
            ets:insert(monitor, {m, Monitor});
        _ -> 
            ok
    end.


in_history(Trace) ->
    case ets:match_object(history, {'_', Trace}) of
        [] -> 
            false;
        _  -> 
            true
    end.

% Configure the determinism function
set_determinism_function(DetFunction) when is_function(DetFunction, 1) ->
    ets:insert(monitor, {det_function, DetFunction}).

% Retrieves user-defined determinism function or provides a default
get_determinism_function() ->
    case ets:lookup(monitor, det_function) of
        [{det_function, F}] -> F;
        _ -> fun(_) -> false end % Default: all actions are non-deterministic
    end.

-spec add_to_history(Trace :: list()) -> reference().
add_to_history(Trace) ->
    TraceId = make_ref(),
    % Extract the current monitor
    case ets:lookup(monitor, m) of
        [{m, Monitor}] ->
            FilteredTrace = process_unfiltered_trace(Trace, [{Monitor, []}]),
            ets:insert(history, {FilteredTrace, Trace});
        _ ->
            ets:insert(history, {TraceId, Trace})
    end,
    TraceId.

sub(H, _Fun) ->  

    CleanedH = lists:map(
        fun({TraceList, TraceMonitor}) ->
            % Remove spawn events from head until we get a non-spawn event
            CleanedTrace = lists:dropwhile(
                fun({trace, _, spawn, _, _}) -> true; 
                   (_) -> false 
                end, 
                TraceList
            ),
            {CleanedTrace, TraceMonitor}
        end,
        H
    ),
    
    % Process each trace with its own monitor
    {Continuations, FirstAction} = lists:foldl(
        fun({TraceList, TraceMonitor}, {ContAcc, ActionAcc}) ->
            case TraceList of
                [] -> 
                    {ContAcc, ActionAcc};  % Skip empty traces
                [FirstAct|RestActions] ->
                    % All monitors should be act monitors at this point
                    {act, _, TraceFun} = TraceMonitor,
                    % Try to apply this trace's monitor function
                    try
                        NextMon = TraceFun(FirstAct),
                        % Add the continuation
                        NewContAcc = [{RestActions, NextMon} | ContAcc],
                        % Save the first action if we don't have one yet
                        NewActionAcc = case ActionAcc of
                            undefined -> FirstAct;
                            _ -> ActionAcc
                        end,
                        {NewContAcc, NewActionAcc}
                    catch
                        _:_ -> 
                            {ContAcc, ActionAcc}  % Pattern didn't match, skip
                    end
            end
        end,
        {[], undefined},
        CleanedH
    ),
    
    case Continuations of
        [] -> 
            {no_match, []};
        _ ->
            {_, RepresentativeMonitor} = hd(Continuations),
            % Return action, continuations, and representative monitor
            {FirstAction, Continuations, RepresentativeMonitor}
    end.

get_history() ->
    [Trace || {_Id, Trace} <- ets:tab2list(history)].

get_monitor() ->
    case ets:lookup(monitor, m) of
        [{m, M}] -> M;
        _ -> undefined
    end.

lb(Formula) ->
    case Formula of
        {ff, _} ->
            0;
        {tt, _} ->
            infinity;
        {var, _, _} ->
            infinity;
        {'or', _, Phi, Psi} ->
            lb(Phi) + lb(Psi) + 1;
        {'and', _, Phi, Psi} ->
            min(lb(Phi), lb(Psi));
        {nec, _, _, Phi} ->
            lb(Phi); 
        {'end', _} ->
            infinity;
        {no, _} ->
            0;
        {act, Env, Fun} when is_function(Fun) ->
            try
                {pat, Pattern} = lists:keyfind(pat, 1, element(2, Env)),
                
                {env, FunEnv} = erlang:fun_info(Fun, env),
                
                case extract_continuation_from_env(FunEnv) of
                    {ok, Continuation} ->
                        lb(Continuation);
                    error ->
                        try_apply_safely(Fun, Pattern)
                end
            catch
                _:_ -> 0  
            end;{act, Env, Fun} when is_function(Fun) ->
            try
                {pat, Pattern} = lists:keyfind(pat, 1, element(2, Env)),
                
                {env, FunEnv} = erlang:fun_info(Fun, env),
                
                case extract_continuation_from_env(FunEnv) of
                    {ok, Continuation} ->
                        lb(Continuation);
                    error ->
                        try_apply_safely(Fun, Pattern)
                end
            catch
                _:_ -> 0  
            end; 
        {rec, _, Fun} when is_function(Fun) ->
            try lb(Fun()) catch _:_ -> 1 end;
        _ ->
            0 
    end.

history_analysis() ->
    case get_monitor() of
        undefined ->
            {error, monitor_not_found};
        M ->
            H = get_history(),
            % Calculate lower bound to guide analysis
            LowerBound = lb(M),
            HistorySize = length(H),

            % Check if the history length is sufficient
            case HistorySize >= (LowerBound + 1) of
                true ->
                    bfs_analyze_history(H, M);
                false ->
                    {ok, insufficient_length}
            end
    end.

extract_continuation_from_env(FunEnv) ->
    try
        {_, _, _, [{_, Continuation}|_]} = FunEnv,
        {ok, Continuation}
    catch
        _:_ -> error
    end.

try_apply_safely(Fun, Pattern) ->
    try
        Continuation = Fun(make_safe_pattern(Pattern)),
        lb(Continuation)
    catch
        _:_ -> 0
    end.

make_safe_pattern(Pattern) ->
    safe_copy_pattern(Pattern).

safe_copy_pattern(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([safe_copy_pattern(Element) || Element <- tuple_to_list(Tuple)]);
safe_copy_pattern(List) when is_list(List) ->
    [safe_copy_pattern(Element) || Element <- List];
safe_copy_pattern(Other) ->
    Other.

%%%%%%% Filter traces %%%%%%%%
%%%%% @doc Processes an unfiltered trace through a list of monitor-trace pairs to produce filtered traces.

filter_trace(Trace) ->
    % Get the current monitor
    case ets:lookup(monitor, m) of
        [{m, Monitor}] ->
            % Start processing the unfiltered trace with the monitor
            process_unfiltered_trace(Trace, [{Monitor, []}]);
        _ ->
            % If no monitor exists, return the original trace
            Trace
    end.

process_unfiltered_trace([], MonitorTracePairs) ->
    % When unfiltered trace is empty, filter out 'no' monitors
    ValidMonitors = lists:filter(
        fun({Monitor, _Trace}) ->
            case Monitor of
                {no, _} -> true;
                _ -> false
            end
        end,
        MonitorTracePairs
    ),
    
    % Return the first valid monitor-trace pair
    case ValidMonitors of
        [{_, FilteredTrace} | _] -> FilteredTrace;
        [] -> error(no_valid_monitor_found)
    end;
    
process_unfiltered_trace([Event | RestTrace], MonitorTracePairs) ->
    % Process the event with each monitor-trace pair
    NewMonitorTracePairs = lists:flatten([
        process_event_with_monitor(Event, Monitor, FilteredTrace)
        || {Monitor, FilteredTrace} <- MonitorTracePairs
    ]),
    
    % Continue processing with the rest of the trace
    process_unfiltered_trace(RestTrace, NewMonitorTracePairs).


process_event_with_monitor(Event, Monitor = {act, Env, Fun}, FilteredTrace) ->
    % For action monitor, try to filter and transition
    try
        % Get pattern from monitor environment
        {pat, Pattern} = lists:keyfind(pat, 1, element(2, Env)),
        
        % Filter event based on pattern 
        FilteredEvent = filter_event_by_pattern(Event, Pattern),
        
        % Apply the monitor function to get the next state
        NextMonitor = Fun(FilteredEvent),
        
        % Return the continuation with filtered trace updated
        [{NextMonitor, FilteredTrace ++ [FilteredEvent]}]
    catch
        _:_ ->
            % Pattern matching failed, cannot transition
            []
    end;
    
process_event_with_monitor(Event, Monitor = {'and', _Env, Left, Right}, FilteredTrace) ->
    % Try both branches
    LeftResults = process_event_with_monitor(Event, Left, FilteredTrace),
    RightResults = process_event_with_monitor(Event, Right, FilteredTrace),
    
    % Return all possible continuations from both branches
    LeftResults ++ RightResults;
    
process_event_with_monitor(Event, Monitor = {'or', _Env, Left, Right}, FilteredTrace) ->
    % Try both branches
    LeftResults = process_event_with_monitor(Event, Left, FilteredTrace),
    RightResults = process_event_with_monitor(Event, Right, FilteredTrace),
    
    % Return all possible continuations from both branches
    LeftResults ++ RightResults;
    
process_event_with_monitor(Event, Monitor = {rec, _Env, Fun}, FilteredTrace) ->
    % Unfold and process
    UnfoldedMonitor = Fun(),
    process_event_with_monitor(Event, UnfoldedMonitor, FilteredTrace);
    
process_event_with_monitor(Event, Monitor = {var, _Env, Fun}, FilteredTrace) ->
    % Unfold and process
    UnfoldedMonitor = Fun(),
    process_event_with_monitor(Event, UnfoldedMonitor, FilteredTrace);
    
process_event_with_monitor(_Event, Monitor = {'end', _Env}, FilteredTrace) ->
    % Do nothing
    [];
    
process_event_with_monitor(_Event, Monitor = {no, _Env}, FilteredTrace) ->
    % do nothing
    [];
    
process_event_with_monitor(_Event, _Monitor, _FilteredTrace) ->
    % Do nothing
    [].

-spec filter_event_by_pattern(Event, Pattern) -> FilteredEvent
  when
    Event :: any(),
    Pattern :: any(),
    FilteredEvent :: any().
filter_event_by_pattern(Event = {trace, _, spawned, _, _}, Pattern) ->
    filter_spawned_event(Event, Pattern);
filter_event_by_pattern(Event = {trace, _, 'receive', _}, Pattern) ->
    filter_receive_event(Event, Pattern);
filter_event_by_pattern(Event = {trace, _, send, _, _}, Pattern) ->
    filter_send_event(Event, Pattern);
filter_event_by_pattern(Event, _Pattern) ->
    Event;
filter_event_by_pattern(Event = {trace, _, spawn, _, _}, Pattern) ->
    filter_spawn_event(Event, Pattern);
filter_event_by_pattern(Event = {trace, _, exit, _}, Pattern) ->
    filter_exit_event(Event, Pattern).

-spec filter_exit_event(ConcreteEvent, Pattern) -> FilteredEvent
  when
    ConcreteEvent :: {trace, pid(), exit, any()},
    Pattern :: {trace, pid() | '_', exit, any()},
    FilteredEvent :: {trace, pid() | '_', exit, any()}.
filter_exit_event(ConcreteEvent, Pattern) ->
    % Extract components from the concrete event
    {trace, ConcretePid, exit, ConcreteReason} = ConcreteEvent,
    
    % Extract components from the pattern
    {trace, PatternPid, exit, PatternReason} = Pattern,
    
    % Filter Pid
    FilteredPid = case PatternPid of
        '_' -> '_';
        _ -> ConcretePid
    end,
    
    % Filter Reason 
    FilteredReason = filter_message(ConcreteReason, PatternReason),
    
    % Construct and return the filtered event
    {trace, FilteredPid, exit, FilteredReason}.

-spec filter_spawn_event(ConcreteEvent, Pattern) -> FilteredEvent
  when
    ConcreteEvent :: {trace, pid(), spawn, pid(), {atom(), atom(), list()}},
    Pattern :: {trace, pid() | '_', spawn, pid() | '_', {atom() | '_', atom() | '_', list()}},
    FilteredEvent :: {trace, pid() | '_', spawn, pid() | '_', {atom() | '_', atom() | '_', list()}}.
filter_spawn_event(ConcreteEvent, Pattern) ->
    % Extract components from the concrete event
    {trace, ConcretePid1, spawn, ConcretePid2, {ConcreteModule, ConcreteFunction, ConcreteArgs}} = ConcreteEvent,
    
    % Extract components from the pattern
    {trace, PatternPid1, spawn, PatternPid2, {PatternModule, PatternFunction, PatternArgs}} = Pattern,
    
    % Filter Pid1
    FilteredPid1 = case PatternPid1 of
        '_' -> '_';
        _ -> ConcretePid1
    end,
    
    % Filter Pid2
    FilteredPid2 = case PatternPid2 of
        '_' -> '_';
        _ -> ConcretePid2
    end,
    
    % Filter module name
    FilteredModule = case PatternModule of
        '_' -> '_';
        _ -> ConcreteModule
    end,
    
    % Filter function name
    FilteredFunction = case PatternFunction of
        '_' -> '_';
        _ -> ConcreteFunction
    end,
    
    % Filter arguments list
    FilteredArgs = filter_args(ConcreteArgs, PatternArgs),
    
    % Construct and return the filtered event
    {trace, FilteredPid1, spawn, FilteredPid2, {FilteredModule, FilteredFunction, FilteredArgs}}.


-spec filter_spawned_event(ConcreteEvent, Pattern) -> FilteredEvent
  when
    ConcreteEvent :: {trace, pid(), spawned, pid(), {atom(), atom(), list()}},
    Pattern :: {trace, pid() | '_', spawned, pid() | '_', {atom() | '_', atom() | '_', list()}},
    FilteredEvent :: {trace, pid() | '_', spawned, pid() | '_', {atom() | '_', atom() | '_', list()}}.
filter_spawned_event(ConcreteEvent, Pattern) ->
    % Extract components from the concrete event
    {trace, ConcretePid1, spawned, ConcretePid2, {ConcreteModule, ConcreteFunction, ConcreteArgs}} = ConcreteEvent,
    
    % Extract components from the pattern
    {trace, PatternPid1, spawned, PatternPid2, {PatternModule, PatternFunction, PatternArgs}} = Pattern,
    
    % Filter Pid1
    FilteredPid1 = case PatternPid1 of
        '_' -> '_';
        _ -> ConcretePid1
    end,
    
    % Filter Pid2
    FilteredPid2 = case PatternPid2 of
        '_' -> '_';
        _ -> ConcretePid2
    end,
    
    % Filter module name
    FilteredModule = case PatternModule of
        '_' -> '_';
        _ -> ConcreteModule
    end,
    
    % Filter function name
    FilteredFunction = case PatternFunction of
        '_' -> '_';
        _ -> ConcreteFunction
    end,
    
    % Filter arguments list
    FilteredArgs = filter_args(ConcreteArgs, PatternArgs),
    
    % Construct and return the filtered event
    {trace, FilteredPid1, spawned, FilteredPid2, {FilteredModule, FilteredFunction, FilteredArgs}}.

%% Replaces concrete arguments with wildcards where pattern has wildcards.
-spec filter_args(ConcreteArgs, PatternArgs) -> FilteredArgs
  when
    ConcreteArgs :: list(),
    PatternArgs :: list(),
    FilteredArgs :: list().
filter_args(ConcreteArgs, PatternArgs) ->
    % Ensure both lists have the same length
    case length(ConcreteArgs) =:= length(PatternArgs) of
        true ->
            lists:zipwith(
                fun(ConcreteArg, PatternArg) ->
                    case PatternArg of
                        '_' -> '_';
                        _ -> ConcreteArg
                    end
                end,
                ConcreteArgs, PatternArgs);
        false ->
            % If argument lists have different lengths, return the concrete args
            ConcreteArgs
    end.

-spec filter_receive_event(ConcreteEvent, Pattern) -> FilteredEvent
  when
    ConcreteEvent :: {trace, pid(), 'receive', any()},
    Pattern :: {trace, pid() | '_', 'receive', any()},
    FilteredEvent :: {trace, pid() | '_', 'receive', any()}.
filter_receive_event(ConcreteEvent, Pattern) ->
    % Extract components from the concrete event
    {trace, ConcretePid, 'receive', ConcreteMsg} = ConcreteEvent,
    
    % Extract components from the pattern
    {trace, PatternPid, 'receive', PatternMsg} = Pattern,
    
    % Filter Pid
    FilteredPid = case PatternPid of
        '_' -> '_';
        _ -> ConcretePid
    end,
    
    % Filter Message (recursively if needed)
    FilteredMsg = filter_message(ConcreteMsg, PatternMsg),
    
    % Construct and return the filtered event
    {trace, FilteredPid, 'receive', FilteredMsg}.

-spec filter_send_event(ConcreteEvent, Pattern) -> FilteredEvent
  when
    ConcreteEvent :: {trace, pid(), send, any(), pid()},
    Pattern :: {trace, pid() | '_', send, any(), pid() | '_'},
    FilteredEvent :: {trace, pid() | '_', send, any(), pid() | '_'}.
filter_send_event(ConcreteEvent, Pattern) ->
    % Extract components from the concrete event
    {trace, ConcretePid1, send, ConcreteMsg, ConcretePid2} = ConcreteEvent,
    
    % Extract components from the pattern
    {trace, PatternPid1, send, PatternMsg, PatternPid2} = Pattern,
    
    % Filter Pid1
    FilteredPid1 = case PatternPid1 of
        '_' -> '_';
        _ -> ConcretePid1
    end,
    
    % Filter Pid2
    FilteredPid2 = case PatternPid2 of
        '_' -> '_';
        _ -> ConcretePid2
    end,
    
    % Filter Message 
    FilteredMsg = filter_message(ConcreteMsg, PatternMsg),
    
    % Construct and return the filtered event
    {trace, FilteredPid1, send, FilteredMsg, FilteredPid2}.

-spec filter_message(ConcreteMsg, PatternMsg) -> FilteredMsg
  when
    ConcreteMsg :: any(),
    PatternMsg :: any(),
    FilteredMsg :: any().
filter_message(ConcreteMsg, '_') ->
    % If pattern is wildcard, replace entire message with wildcard
    '_';
filter_message(ConcreteMsg, PatternMsg) when is_tuple(ConcreteMsg), is_tuple(PatternMsg) ->
    % Both are tuples, process elements
    ConcreteElements = tuple_to_list(ConcreteMsg),
    PatternElements = tuple_to_list(PatternMsg),
    
    % Process tuple elements 
    FilteredElements = case length(ConcreteElements) =:= length(PatternElements) of
        true ->
            % Recursively filter each element
            lists:zipwith(
                fun(ConcreteElem, PatternElem) ->
                    filter_message(ConcreteElem, PatternElem)
                end,
                ConcreteElements, PatternElements);
        false ->
            % Different sizes, return concrete elements
            ConcreteElements
    end,
    
    % Convert back to tuple
    list_to_tuple(FilteredElements);

filter_message(ConcreteMsg, PatternMsg) when is_list(ConcreteMsg), is_list(PatternMsg) ->
    % Both are lists, process elements
    case length(ConcreteMsg) =:= length(PatternMsg) of
        true ->
            % Same size, recursively filter each element
            lists:zipwith(
                fun(ConcreteElem, PatternElem) ->
                    filter_message(ConcreteElem, PatternElem)
                end,
                ConcreteMsg, PatternMsg);
        false ->
            % Different sizes, return concrete list
            ConcreteMsg
    end;
filter_message(ConcreteMsg, PatternMsg) ->
    % Atoms, numbers, or other simple values
    case PatternMsg of
        '_' -> '_';
        _ -> ConcreteMsg
    end.

%%%%%%% BFS History Algorithm %%%%%%%

expO({H, F, {no, _}}, DET) ->
    case H of
        [] -> 
            [];    % no completed derivation
        _ ->
            [[]]   % completed derivation
    end;

expO({H, F, {act, {env, _}, Fun}}, DET) ->
    case sub(H, Fun) of  
        {no_match, _} -> 
            [];
        {MatchedAction, Continuations, NextMonitor} ->  
            NewFlag = F andalso DET(MatchedAction),
            [[{Continuations, NewFlag, NextMonitor}]]
    end;

expO({H, F, {'and', {env, _}, Left, Right}}, DET) ->
    % Need to update H to have appropriate branch monitors
    LeftH = lists:map(
        fun({Trace, Monitor}) ->
            case Monitor of
                {'and', _, L, _} -> {Trace, L};
                _ -> {Trace, Left} 
            end
        end,
        H
    ),
    
    RightH = lists:map(
        fun({Trace, Monitor}) ->
            case Monitor of
                {'and', _, _, R} -> {Trace, R};
                _ -> {Trace, Right}  
            end
        end,
        H
    ),
    
    LeftResult = {LeftH, F, Left},
    RightResult = {RightH, F, Right},
    [[LeftResult], [RightResult]];

expO({H, F, {'or', {env, _}, Left, Right}}, DET) ->
    LeftH = lists:map(
        fun({Trace, Monitor}) ->
            case Monitor of
                {'or', _, L, _} -> {Trace, L};
                _ -> {Trace, Left}
            end
        end,
        H
    ),
    
    RightH = lists:map(
        fun({Trace, Monitor}) ->
            case Monitor of
                {'or', _, _, R} -> {Trace, R};
                _ -> {Trace, Right}
            end
        end,
        H
    ),
    
    case F of
        true -> 
            LeftResult = {LeftH, F, Left},
            RightResult = {RightH, F, Right},
            [[LeftResult, RightResult]];
        false ->
            []
    end;

expO({H, F, {rec, {env, _}, Fun}}, DET) ->
    % Update H to unfold recursion for each trace
    NewH = lists:map(
        fun({Trace, Monitor}) ->
            case Monitor of
                {rec, _, RecFun} -> {Trace, RecFun()};
                _ -> {Trace, Fun()} 
            end
        end,
        H
    ),
    
    NewMonitor = Fun(),
    [[{NewH, F, NewMonitor}]];

expO({H, F, {var, {env, _}, Fun}}, DET) ->
    NewH = lists:map(
        fun({Trace, Monitor}) ->
            case Monitor of
                {var, _, VarFun} -> {Trace, VarFun()};
                _ -> {Trace, Fun()}
            end
        end,
        H
    ),
    
    NewMonitor = Fun(),
    [[{NewH, F, NewMonitor}]];

expO({_, _, _}, _DET) ->
    [].

expC(CSet, DET) -> % start
    expC(CSet, [[]], DET). 

expC([], Acc, _DET) ->
    case Acc of
        [] -> 
            [];
        _ -> 
            Acc
    end;

expC([C|Rest], Acc, DET) ->
    case expO(C, DET) of
        [] -> % if cannot complete the derivation
            expC([], [], DET);
        [[]] -> % if no further obligations
            expC(Rest, Acc, DET); % continue with the rest
        Result -> % if there are obligations
            case Acc of
                [[]] -> % if no obligations in the accumulator
                    expC(Rest, Result, DET); % add the obligations to the accumulator
                _ -> % if there are obligations in the accumulator
                    expC(Rest, Acc ++ Result, DET) % add the obligations to the accumulator
            end
    end.

exp(Dset, DET)  -> % start
    exp(Dset, [], DET).

exp([], Acc, DET) ->
    case Acc of
        [] -> 
            false;
        _ -> 
            exp(Acc, DET)
    end;

exp([D|Rest], Acc, DET) ->
    case expC(D, DET) of % expand each derivation
        [] -> % % if cannot complete the derivation
            exp(Rest, Acc, DET); % continue with the rest
        [[]] -> % if no further obligations
            true; % derivation is rejected
        Result -> % if there are obligations
            exp(Rest, Acc ++ Result, DET) % add the obligations to the accumulator
    end.

bfs_analyze_history(H, Monitor) ->
    % Get the determinism function
    DET = get_determinism_function(),
    
    % Convert H to list of (trace, monitor) pairs
    % Initially all traces start with the same monitor
    HPairs = lists:map(fun(Trace) -> {Trace, Monitor} end, H),
    
    % Start with flag set to true (same as DFS)
    InitialState = {HPairs, true, Monitor},
    
    % Run the BFS analysis
    case exp([[InitialState]], DET) of
        true ->
            io:format("Analysis Result:: History is rejected~n");
        false ->
            io:format("Analysis Result:S: History is inconclusive~n")

    end.