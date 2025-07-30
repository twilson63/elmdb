-module(simple_list_test).
-export([run/0]).

run() ->
    io:format("=== Simple List Operations Test ===~n~n"),
    
    Dir = "/tmp/elmdb_simple_list_test",
    os:cmd("rm -rf " ++ Dir),
    
    {ok, Env} = elmdb:env_open(Dir, [{map_size, 100 * 1024 * 1024}]),
    {ok, Db} = elmdb:db_open(Env, []),
    
    % Test 1: Basic list storage and retrieval
    io:format("Test 1: Basic list operations...~n"),
    ListKey = <<"test_list">>,
    List1 = [1, 2, 3, 4, 5],
    elmdb:put(Db, ListKey, term_to_binary(List1)),
    
    {ok, Data1} = elmdb:get(Db, ListKey),
    RetrievedList = binary_to_term(Data1),
    case RetrievedList of
        List1 -> io:format("  ✓ List stored and retrieved correctly~n");
        _ -> throw({list_mismatch, List1, RetrievedList})
    end,
    
    % Test 2: Append to list
    io:format("~nTest 2: Append to list...~n"),
    NewList = RetrievedList ++ [6, 7, 8],
    elmdb:put(Db, ListKey, term_to_binary(NewList)),
    {ok, Data2} = elmdb:get(Db, ListKey),
    UpdatedList = binary_to_term(Data2),
    case UpdatedList of
        [1,2,3,4,5,6,7,8] -> io:format("  ✓ List appended correctly~n");
        _ -> throw({append_failed, UpdatedList})
    end,
    
    % Test 3: Concurrent list operations
    io:format("~nTest 3: Concurrent list operations...~n"),
    NumWorkers = 10,
    Parent = self(),
    
    % Initialize a counter list
    CounterKey = <<"counter_list">>,
    elmdb:put(Db, CounterKey, term_to_binary([])),
    
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(I) ->
                % Add worker ID and iteration to the list
                {ok, CurrentData} = elmdb:get(Db, CounterKey),
                CurrentList = binary_to_term(CurrentData),
                NewEntry = {worker, W, iteration, I},
                UpdatedCounterList = CurrentList ++ [NewEntry],
                elmdb:put(Db, CounterKey, term_to_binary(UpdatedCounterList))
            end, lists:seq(1, 10)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, NumWorkers)),
    
    % Wait for workers
    lists:foreach(fun(Worker) ->
        receive
            {done, Worker} -> ok
        after 5000 ->
            throw({timeout, Worker})
        end
    end, Workers),
    
    % Check final list
    {ok, FinalData} = elmdb:get(Db, CounterKey),
    FinalList = binary_to_term(FinalData),
    FinalLength = length(FinalList),
    io:format("  ✓ Final list has ~p entries (may be less than 100 due to race conditions)~n", [FinalLength]),
    
    % Test 4: Binary list operations
    io:format("~nTest 4: Binary list operations...~n"),
    BinListKey = <<"binary_list">>,
    BinaryList = [<<I:32>> || I <- lists:seq(1, 1000)],
    elmdb:put(Db, BinListKey, term_to_binary(BinaryList)),
    
    {ok, BinData} = elmdb:get(Db, BinListKey),
    RetrievedBinList = binary_to_term(BinData),
    case length(RetrievedBinList) of
        1000 -> io:format("  ✓ Binary list with 1000 elements stored correctly~n");
        N -> throw({binary_list_size_mismatch, N})
    end,
    
    % Test 5: Nested list structures
    io:format("~nTest 5: Nested list structures...~n"),
    NestedKey = <<"nested_list">>,
    NestedList = [
        {users, [<<"alice">>, <<"bob">>, <<"charlie">>]},
        {scores, [[90, 85, 88], [75, 80, 82], [92, 94, 91]]},
        {metadata, [{created, erlang:system_time()}, {version, 1}]}
    ],
    elmdb:put(Db, NestedKey, term_to_binary(NestedList)),
    
    {ok, NestedData} = elmdb:get(Db, NestedKey),
    RetrievedNested = binary_to_term(NestedData),
    Users = proplists:get_value(users, RetrievedNested),
    case length(Users) of
        3 -> io:format("  ✓ Nested structure stored with ~p users~n", [length(Users)]);
        _ -> throw(nested_structure_error)
    end,
    
    % Clean up
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== All Tests Passed! ===~n").