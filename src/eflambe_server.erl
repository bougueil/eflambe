%%%-------------------------------------------------------------------
%%% @doc
%%% E flambe server stores state for a capture trace that has been started.
%%% When no traced processes remain the server shuts down automatically.
%%% @end
%%%-------------------------------------------------------------------
-module(eflambe_server).

-behaviour(gen_server).

%% API
-export([start_link/2, start_capture_trace/1, stop_capture_trace/1, start_trace/1, stop_trace/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_continue/2,
         handle_info/2]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_OPTIONS, [{output_format, brendan_gregg}]).
-define(FLAGS, [call, return_to, running, procs, garbage_collection, arity,
                timestamp, set_on_spawn]).

-record(state, {
          module :: atom(),
          max_calls :: integer(),
          calls = 0 :: integer(),
          options = [] :: list(),
          pid_traces = [] :: list(pid_trace())
         }).

% For capture traces we could end up tracing invocations in multiple processes.
% We need to keep track of the processes that invoke the function so we can
% track the state of the trace in function and properly handle recursive calls.
% If recursive calls are not handled they will result in infinite number of
% traces started.
-record(pid_trace, {
          pid :: pid(),
          tracer_pid :: pid()
         }).

-type state() :: #state{}.
-type pid_trace() :: #pid_trace{}.
-type from() :: {pid(), Tag :: term()}.

-type tracer_options() :: [eflambe:option() | {pid, pid()} | {max_calls, pos_integer()}].

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(mfa(), tracer_options()) ->
    {ok, pid()} | ignore | {error, Error :: any()}.

start_link(MFA, Options) ->
    gen_server:start_link(?MODULE, [MFA, Options], []).

%%--------------------------------------------------------------------
%% @doc
%% Calls the eflambe_server gen_server to start a tracer for the current
%% process. This is only used for `capture` style traces.
%%
%% @end
%%--------------------------------------------------------------------

-spec start_capture_trace(pid()) -> {ok, boolean()}.

start_capture_trace(ServerPid) ->
    gen_server:call(ServerPid, start_trace).

%%--------------------------------------------------------------------
%% @doc
%% Calls the eflambe_server gen_server to stop a tracer for a specific
%% process. This is only used for `capture` style traces.
%%
%% @end
%%--------------------------------------------------------------------
stop_capture_trace(ServerPid) ->
    gen_server:call(ServerPid, stop_trace).

%%--------------------------------------------------------------------
%% @doc
%% Starts the tracer in the current process (no gen_server). This is
%% used for `apply` style traces only.
%%
%% @end
%%--------------------------------------------------------------------

-spec start_trace(tracer_options()) -> {ok, pid()}.

start_trace(Options) ->
    TracerOptions = [{pid, self()}|Options],
    {ok, TracerPid} = eflambe_tracer:start_link(TracerOptions),

    % Start the actual trace last so it doesn't pick up the above code
    start_erlang_trace(self(), TracerPid),
    {ok, TracerPid}.

%%--------------------------------------------------------------------
%% @doc
%% Stops a tracer and finishes a trace in the current process. This is
%% used for `apply` style traces only as everything is done in the
%% current process.
%%
%% @end
%%--------------------------------------------------------------------
stop_trace(TracerPid) ->
    % Stop tracing immediately so it doesn't pick up the finish gen_server call!
    stop_erlang_trace(self()),
    eflambe_tracer:finish(TracerPid).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(Args :: list(tracer_options())) -> {ok, state()}.

init([{Module, Function, Arity}, Options]) ->
    % Generate complete list of options by falling back to default list
    FinalOptions = merge(Options, ?DEFAULT_OPTIONS),

    % If necessary, set up meck to wrap original function in tracing code that
    % calls out to this process. We'll need to inject the pid of this tracer
    % (self()) into the wrapper function so we can track invocation and return
    % of the function the user wants profiled
    ServerPid = self(),
    ShimmedFunction = fun(Args) ->
        {ok, StartedNew} = eflambe_server:start_capture_trace(ServerPid),

        % Invoke the original function
        Results = meck:passthrough(Args),

        case StartedNew of
            true ->
                eflambe_server:stop_capture_trace(ServerPid);
            false ->
                ok
        end,
        Results
    end,

    case eflambe_meck:shim(Module, Function, Arity, ShimmedFunction) of
        {error, already_mecked} ->
            {stop, already_mecked};
        ok ->
            MaxCalls = proplists:get_value(max_calls, FinalOptions),
            {ok, #state{module = Module, max_calls = MaxCalls, options = FinalOptions}}
    end.

-spec handle_call(Request :: any(), from(), state()) ->
                                  {reply, Reply :: any(), state()} |
                                  {reply, Reply :: any(), state(), {continue, finish}}.

handle_call(start_trace, {FromPid, _}, #state{max_calls = MaxCalls, calls = Calls,
                                              options = Options} = State) ->
    NoTracesRemaining = (MaxCalls =:= Calls),

    case {get_pid_trace(State, FromPid), NoTracesRemaining} of
        {_, true} ->
            {reply, {ok, false}, State};
        {undefined, false} ->
            % Increment number of calls
            NewCalls = Calls + 1,

            % Start a new tracer
            TracerOptions = [{pid, FromPid}|Options],
            {ok, TracerPid} = eflambe_tracer:start_link(TracerOptions),

            % Update state
            NewPidTrace = #pid_trace{ pid = FromPid, tracer_pid = TracerPid},
            NewState = put_pid_trace(State#state{calls = NewCalls}, NewPidTrace),

            % Create new trace record, start tracing function
            start_erlang_trace(FromPid, TracerPid),
            {reply, {ok, true}, NewState};
        {#pid_trace{}, false} ->
            {reply, {ok, false}, State}
    end;

handle_call(stop_trace, {FromPid, _}, #state{max_calls = MaxCalls, calls = Calls,
                                             module = ModuleName,
                                             pid_traces = PidTraces} = State) ->
    % Stop tracing immediately!
    stop_erlang_trace(FromPid),

    NewTraces = case get_pid_trace(State, FromPid) of
        #pid_trace{tracer_pid = TracerPid} ->
            eflambe_tracer:finish(TracerPid),

            % Generate new list of traces
            remove_pid_trace(State, FromPid);
        undefined ->
            PidTraces
    end,

    NoTracesRemaining = (MaxCalls =:= Calls),

    case {NoTracesRemaining, NewTraces} of
        {true, []} ->
            % We are completely finished
            ok = eflambe_meck:unload(ModuleName),

            io:format("Successful finished trace~n"),

            % The only reason we don't stop here is because this is a call and
            % the linked call would crash as well. This feels kind of wrong so
            % I may revisit this
            {reply, ok, State, {continue, finish}};
        {_, _} ->
            % Still some stuff in flight
            {reply, ok, State#state{pid_traces = NewTraces}}
    end.

-spec handle_cast(any(), state()) -> {noreply, state()}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_continue(finish, State) ->
    {stop, normal, State}.

-spec handle_info(Info :: any(), state()) -> {noreply, state()} |
                                  {noreply, state(), timeout()} |
                                  {stop, Reason :: any(), state()}.

handle_info(Info, State) ->
    logger:error("Received unexpected info message: ~w", [Info]),
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_pid_trace(#state{pid_traces = Traces}, Pid) ->
    case lists:filter(lookup_fun(Pid), Traces) of
        [] -> undefined;
        [Trace] -> Trace
    end.

put_pid_trace(#state{pid_traces = ExistingTraces} = State, NewTrace) ->
    State#state{pid_traces = [NewTrace|ExistingTraces]}.

remove_pid_trace(#state{pid_traces = Traces}, Pid) ->
    SelectionFun = lookup_fun(Pid),
    lists:filter(fun(Trace) -> not SelectionFun(Trace) end, Traces).

lookup_fun(Pid) ->
    fun
        (#pid_trace{pid = TracedPid}) when TracedPid =:= Pid -> true;
        (_) -> false
    end.

% https://stackoverflow.com/questions/21873644/combine-merge-two-erlang-lists
merge(In1, In2) ->
    Combined = In1 ++ In2,
    Fun = fun(Key) ->
                  [FinalValue|_] = proplists:get_all_values(Key, Combined),
                  {Key, FinalValue}
          end,
    lists:map(Fun, proplists:get_keys(Combined)).

-spec start_erlang_trace(PidToTrace :: pid(), TracerPid :: pid()) -> integer().

start_erlang_trace(PidToTrace, TracerPid) ->
    MatchSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
    erlang:trace_pattern(on_load, MatchSpec, [local]),
    erlang:trace_pattern({'_', '_', '_'}, MatchSpec, [local]),
    erlang:trace(PidToTrace, true, [{tracer, TracerPid} | ?FLAGS]).

stop_erlang_trace(PidToTrace) ->
    erlang:trace(PidToTrace, false, [all]).
