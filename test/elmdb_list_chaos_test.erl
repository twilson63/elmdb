-module(elmdb_list_chaos_test).
-export([run/0]).

run() ->
    io:format("=== ELMDB List Operations Chaos Test ===~n~n"),
    
    Dir = "/tmp/elmdb_list_chaos",
    os:cmd("rm -rf " ++ Dir),
    
    {ok, Env} = elmdb:env_open(Dir, [
        {map_size, 10 * 1024 * 1024 * 1024}, % 10GB
        {max_dbs, 5}
    ]),
    
    % Create multiple databases for different list types
    {ok, MainDb} = elmdb:db_open(Env, []),
    {ok, QueueDb} = elmdb:db_open(Env, <<"queues">>, [create]),
    {ok, StackDb} = elmdb:db_open(Env, <<"stacks">>, [create]),
    {ok, SetDb} = elmdb:db_open(Env, <<"sets">>, [create]),
    
    io:format("Running list operation tests...~n~n"),
    
    % Test 1: Queue operations (FIFO)
    io:format("Test 1: Queue operations (FIFO)...~n"),
    test_queue_operations(QueueDb),
    
    % Test 2: Stack operations (LIFO)
    io:format("~nTest 2: Stack operations (LIFO)...~n"),
    test_stack_operations(StackDb),
    
    % Test 3: Set operations (unique elements)
    io:format("~nTest 3: Set operations (unique elements)...~n"),
    test_set_operations(SetDb),
    
    % Test 4: Concurrent list modifications
    io:format("~nTest 4: Concurrent list modifications...~n"),
    test_concurrent_lists(MainDb),
    
    % Test 5: Large list stress test
    io:format("~nTest 5: Large list stress test...~n"),
    test_large_lists(MainDb),
    
    % Test 6: Complex nested structures
    io:format("~nTest 6: Complex nested structures...~n"),
    test_nested_structures(MainDb),
    
    % Clean up
    elmdb:db_close(MainDb),
    elmdb:db_close(QueueDb),
    elmdb:db_close(StackDb),
    elmdb:db_close(SetDb),
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== All List Tests Passed! ===~n").

%% Queue operations (FIFO)
test_queue_operations(Db) ->
    QueueKey = <<"test_queue">>,
    
    % Initialize empty queue
    elmdb:put(Db, QueueKey, term_to_binary([])),
    
    % Enqueue operations
    lists:foreach(fun(I) ->
        {ok, Data} = elmdb:get(Db, QueueKey),
        Queue = binary_to_term(Data),
        NewQueue = Queue ++ [{item, I, erlang:system_time()}],
        elmdb:put(Db, QueueKey, term_to_binary(NewQueue))
    end, lists:seq(1, 100)),
    
    % Dequeue operations
    DequeueResults = lists:map(fun(_) ->
        {ok, Data} = elmdb:get(Db, QueueKey),
        case binary_to_term(Data) of
            [Head | Tail] ->
                elmdb:put(Db, QueueKey, term_to_binary(Tail)),
                Head;
            [] ->
                empty
        end
    end, lists:seq(1, 50)),
    
    % Verify FIFO order
    ExpectedOrder = [{item, I, '_'} || I <- lists:seq(1, 50)],
    case match_order(DequeueResults, ExpectedOrder) of
        true -> io:format("  ✓ Queue FIFO order verified~n");
        false -> throw({queue_order_mismatch, DequeueResults})
    end,
    
    % Concurrent enqueue/dequeue
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(I) ->
                case W rem 2 of
                    0 -> % Enqueue
                        elmdb:txn(fun(Txn) ->
                            {ok, Data} = elmdb:get(Txn, Db, QueueKey),
                            Queue = binary_to_term(Data),
                            NewQueue = Queue ++ [{worker, W, item, I}],
                            elmdb:put(Txn, Db, QueueKey, term_to_binary(NewQueue))
                        end);
                    1 -> % Dequeue
                        elmdb:txn(fun(Txn) ->
                            {ok, Data} = elmdb:get(Txn, Db, QueueKey),
                            case binary_to_term(Data) of
                                [_ | Tail] ->
                                    elmdb:put(Txn, Db, QueueKey, term_to_binary(Tail));
                                [] ->
                                    ok
                            end
                        end)
                end
            end, lists:seq(1, 20)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, 10)),
    
    wait_for_workers(Workers),
    io:format("  ✓ Concurrent queue operations completed~n").

%% Stack operations (LIFO)
test_stack_operations(Db) ->
    StackKey = <<"test_stack">>,
    
    % Initialize empty stack
    elmdb:put(Db, StackKey, term_to_binary([])),
    
    % Push operations
    lists:foreach(fun(I) ->
        {ok, Data} = elmdb:get(Db, StackKey),
        Stack = binary_to_term(Data),
        NewStack = [{value, I} | Stack],
        elmdb:put(Db, StackKey, term_to_binary(NewStack))
    end, lists:seq(1, 100)),
    
    % Pop operations
    PopResults = lists:map(fun(_) ->
        {ok, Data} = elmdb:get(Db, StackKey),
        case binary_to_term(Data) of
            [Top | Rest] ->
                elmdb:put(Db, StackKey, term_to_binary(Rest)),
                Top;
            [] ->
                empty
        end
    end, lists:seq(1, 50)),
    
    % Verify LIFO order
    ExpectedOrder = [{value, I} || I <- lists:seq(100, 51, -1)],
    case PopResults of
        ExpectedOrder -> io:format("  ✓ Stack LIFO order verified~n");
        _ -> throw({stack_order_mismatch, PopResults})
    end.

%% Set operations (unique elements)
test_set_operations(Db) ->
    SetKey = <<"test_set">>,
    
    % Initialize empty set
    elmdb:put(Db, SetKey, term_to_binary([])),
    
    % Add elements (with duplicates)
    lists:foreach(fun(I) ->
        elmdb:txn(fun(Txn) ->
            {ok, Data} = elmdb:get(Txn, Db, SetKey),
            Set = binary_to_term(Data),
            Element = I rem 50, % Intentional duplicates
            NewSet = case lists:member(Element, Set) of
                true -> Set;
                false -> [Element | Set]
            end,
            elmdb:put(Txn, Db, SetKey, term_to_binary(NewSet))
        end)
    end, lists:seq(1, 200)),
    
    % Check set size
    {ok, Data} = elmdb:get(Db, SetKey),
    Set = binary_to_term(Data),
    UniqueCount = length(lists:usort(Set)),
    case UniqueCount of
        50 -> io:format("  ✓ Set contains exactly 50 unique elements~n");
        N -> throw({set_size_mismatch, N})
    end,
    
    % Set operations: union, intersection, difference
    Set1 = lists:seq(1, 30),
    Set2 = lists:seq(20, 50),
    
    elmdb:put(Db, <<"set1">>, term_to_binary(Set1)),
    elmdb:put(Db, <<"set2">>, term_to_binary(Set2)),
    
    % Union
    Union = lists:usort(Set1 ++ Set2),
    io:format("  ✓ Set union: ~p elements~n", [length(Union)]),
    
    % Intersection
    Intersection = [X || X <- Set1, lists:member(X, Set2)],
    io:format("  ✓ Set intersection: ~p elements~n", [length(Intersection)]),
    
    % Difference
    Difference = [X || X <- Set1, not lists:member(X, Set2)],
    io:format("  ✓ Set difference: ~p elements~n", [length(Difference)]).

%% Concurrent list modifications
test_concurrent_lists(Db) ->
    NumLists = 20,
    NumWorkers = 50,
    OpsPerWorker = 100,
    
    % Create initial lists
    lists:foreach(fun(I) ->
        ListKey = <<"list_", I:32>>,
        InitialList = lists:seq(1, 10),
        elmdb:put(Db, ListKey, term_to_binary(InitialList))
    end, lists:seq(1, NumLists)),
    
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(_) ->
                ListNum = rand:uniform(NumLists),
                ListKey = <<"list_", ListNum:32>>,
                Op = rand:uniform(6),
                
                try
                    case Op of
                        1 -> % Append
                            elmdb:txn(fun(Txn) ->
                                {ok, Data} = elmdb:get(Txn, Db, ListKey),
                                List = binary_to_term(Data),
                                NewList = List ++ [rand:uniform(1000)],
                                elmdb:put(Txn, Db, ListKey, term_to_binary(NewList))
                            end);
                        2 -> % Prepend
                            elmdb:txn(fun(Txn) ->
                                {ok, Data} = elmdb:get(Txn, Db, ListKey),
                                List = binary_to_term(Data),
                                NewList = [rand:uniform(1000) | List],
                                elmdb:put(Txn, Db, ListKey, term_to_binary(NewList))
                            end);
                        3 -> % Remove first
                            elmdb:txn(fun(Txn) ->
                                {ok, Data} = elmdb:get(Txn, Db, ListKey),
                                case binary_to_term(Data) of
                                    [_ | Rest] ->
                                        elmdb:put(Txn, Db, ListKey, term_to_binary(Rest));
                                    [] ->
                                        ok
                                end
                            end);
                        4 -> % Remove last
                            elmdb:txn(fun(Txn) ->
                                {ok, Data} = elmdb:get(Txn, Db, ListKey),
                                List = binary_to_term(Data),
                                case lists:reverse(List) of
                                    [_ | Rest] ->
                                        elmdb:put(Txn, Db, ListKey, 
                                                 term_to_binary(lists:reverse(Rest)));
                                    [] ->
                                        ok
                                end
                            end);
                        5 -> % Map operation
                            elmdb:txn(fun(Txn) ->
                                {ok, Data} = elmdb:get(Txn, Db, ListKey),
                                List = binary_to_term(Data),
                                NewList = [X * 2 || X <- List, is_integer(X)],
                                elmdb:put(Txn, Db, ListKey, term_to_binary(NewList))
                            end);
                        6 -> % Filter operation
                            elmdb:txn(fun(Txn) ->
                                {ok, Data} = elmdb:get(Txn, Db, ListKey),
                                List = binary_to_term(Data),
                                NewList = [X || X <- List, is_integer(X), X rem 2 == 0],
                                elmdb:put(Txn, Db, ListKey, term_to_binary(NewList))
                            end)
                    end
                catch
                    _:_ -> ok % Ignore errors for chaos testing
                end
            end, lists:seq(1, OpsPerWorker)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, NumWorkers)),
    
    wait_for_workers(Workers),
    io:format("  ✓ ~p concurrent workers completed ~p operations~n", 
              [NumWorkers, NumWorkers * OpsPerWorker]).

%% Large list stress test
test_large_lists(Db) ->
    LargeListKey = <<"large_list">>,
    
    % Create a large list incrementally
    BaseSize = 10000,
    ChunkSize = 1000,
    
    % Initialize with base list
    BaseList = [crypto:strong_rand_bytes(100) || _ <- lists:seq(1, BaseSize)],
    elmdb:put(Db, LargeListKey, term_to_binary(BaseList)),
    
    % Grow the list
    lists:foreach(fun(I) ->
        elmdb:txn(fun(Txn) ->
            {ok, Data} = elmdb:get(Txn, Db, LargeListKey),
            List = binary_to_term(Data),
            NewChunk = [<<I:32, J:32>> || J <- lists:seq(1, ChunkSize)],
            NewList = List ++ NewChunk,
            elmdb:put(Txn, Db, LargeListKey, term_to_binary(NewList))
        end)
    end, lists:seq(1, 10)),
    
    % Verify final size
    {ok, FinalData} = elmdb:get(Db, LargeListKey),
    FinalList = binary_to_term(FinalData),
    FinalSize = length(FinalList),
    ExpectedSize = BaseSize + (10 * ChunkSize),
    
    case FinalSize of
        ExpectedSize -> 
            io:format("  ✓ Large list grew to ~p elements~n", [FinalSize]);
        _ -> 
            throw({large_list_size_mismatch, FinalSize, ExpectedSize})
    end,
    
    % Test operations on large list
    io:format("  ✓ Testing operations on large list...~n"),
    
    % Reverse
    ReversedList = lists:reverse(FinalList),
    elmdb:put(Db, <<"reversed_large">>, term_to_binary(ReversedList)),
    
    % Split
    {First5000, Rest} = lists:split(5000, FinalList),
    elmdb:put(Db, <<"first_5000">>, term_to_binary(First5000)),
    elmdb:put(Db, <<"rest">>, term_to_binary(Rest)),
    
    io:format("  ✓ Large list operations completed~n").

%% Complex nested structures
test_nested_structures(Db) ->
    % Create a complex nested structure
    NestedKey = <<"nested_structure">>,
    
    % Build nested data
    NestedData = #{
        users => [
            #{id => 1, name => <<"Alice">>, 
              scores => [95, 87, 92, 88, 91],
              tags => [<<"pro">>, <<"verified">>]},
            #{id => 2, name => <<"Bob">>, 
              scores => [78, 82, 85, 79, 83],
              tags => [<<"beginner">>]},
            #{id => 3, name => <<"Charlie">>, 
              scores => [88, 90, 86, 92, 89],
              tags => [<<"intermediate">>, <<"active">>]}
        ],
        metadata => #{
            created => erlang:system_time(second),
            version => 1,
            indexes => lists:seq(1, 100)
        },
        matrix => [
            [rand:uniform(100) || _ <- lists:seq(1, 10)] 
            || _ <- lists:seq(1, 10)
        ]
    },
    
    elmdb:put(Db, NestedKey, term_to_binary(NestedData)),
    
    % Concurrent modifications to nested structure
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(_) ->
                elmdb:txn(fun(Txn) ->
                    {ok, Data} = elmdb:get(Txn, Db, NestedKey),
                    Structure = binary_to_term(Data),
                    
                    % Modify different parts
                    case W rem 3 of
                        0 -> % Add user
                            Users = maps:get(users, Structure),
                            NewUser = #{
                                id => length(Users) + 1,
                                name => <<"User", W:16>>,
                                scores => [rand:uniform(100) || _ <- lists:seq(1, 5)],
                                tags => []
                            },
                            NewStructure = Structure#{users => Users ++ [NewUser]},
                            elmdb:put(Txn, Db, NestedKey, term_to_binary(NewStructure));
                        1 -> % Update scores
                            Users = maps:get(users, Structure),
                            UpdatedUsers = lists:map(fun(User) ->
                                OldScores = maps:get(scores, User),
                                NewScore = rand:uniform(100),
                                User#{scores => OldScores ++ [NewScore]}
                            end, Users),
                            NewStructure = Structure#{users => UpdatedUsers},
                            elmdb:put(Txn, Db, NestedKey, term_to_binary(NewStructure));
                        2 -> % Update metadata
                            Metadata = maps:get(metadata, Structure),
                            NewMetadata = Metadata#{
                                version => maps:get(version, Metadata) + 1,
                                last_modified => erlang:system_time(second)
                            },
                            NewStructure = Structure#{metadata => NewMetadata},
                            elmdb:put(Txn, Db, NestedKey, term_to_binary(NewStructure))
                    end
                end)
            end, lists:seq(1, 10)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, 15)),
    
    wait_for_workers(Workers),
    
    % Verify final structure
    {ok, FinalData} = elmdb:get(Db, NestedKey),
    FinalStructure = binary_to_term(FinalData),
    
    UserCount = length(maps:get(users, FinalStructure)),
    Version = maps:get(version, maps:get(metadata, FinalStructure)),
    
    io:format("  ✓ Nested structure has ~p users, version ~p~n", [UserCount, Version]),
    io:format("  ✓ Complex nested structure operations completed~n").

%% Helper functions
wait_for_workers(Workers) ->
    lists:foreach(fun(Worker) ->
        receive
            {done, Worker} -> ok
        after 30000 ->
            throw({timeout_waiting_for_worker, Worker})
        end
    end, Workers).

match_order([], []) -> true;
match_order([{item, N, _} | Rest1], [{item, N, '_'} | Rest2]) ->
    match_order(Rest1, Rest2);
match_order(_, _) -> false.