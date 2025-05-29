
-module(calc_server_bug).
-author("Duncan Paul Attard").

%%% Includes.
-include_lib("stdlib/include/assert.hrl").

%%% Public API.
-export([start/1]).

%%% Internal callbacks.
-export([loop/1]).


%%% ----------------------------------------------------------------------------
%%% Public API.
%%% ----------------------------------------------------------------------------

%% @doc Starts server.
%%
%% {@params
%%   {@name N}
%%   {@desc The request number to start the server with.}
%% }
%%
%% {@returns Server PID.}
-spec start(N :: integer()) -> pid().
start(N) ->
  spawn(?MODULE, loop, [N]).


%%% ----------------------------------------------------------------------------
%%% Internal callbacks.
%%% ----------------------------------------------------------------------------

%% @private Main server loop.
%%
%% {@params
%%   {@name Tot}
%%   {@desc Total number of serviced requests.}
%% }
%%
%% {@returns Does not return.}
-spec loop(Tot :: integer()) -> no_return().
loop(Tot) ->
  receive
    {Clt, {add, A, B}} ->

      % Handle addition request from client.
      Clt ! {ok, A - B}, % Bug!!
      loop(Tot + 1);

    {Clt, {mul, A, B}} ->

      % Handle multiplication request from client.
      Clt ! {ok, A * B},
      % Bug - enter new loop where after a close request the server loops instead of closing the server
      receive 
        {Clt, {add, A, B}} ->

          % Handle addition request from client.
          Clt ! {ok, A + B},
          loop(Tot + 1);
        {Clt, {mul, A, B}} ->
          % Handle multiplication request from client.
          Clt ! {ok, A * B},
          loop(Tot + 1);
        {Clt, stp} ->
          % Handle stop request. Server does not loop again.
          loop(Tot + 1)
      end;

    {Clt, stp} ->

      % Handle stop request. Server does not loop again.
      Clt ! {bye, Tot}
  end.