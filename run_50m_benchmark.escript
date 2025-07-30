#!/usr/bin/env escript
%% -*- erlang -*-

main(Args) ->
    % Parse command line arguments
    Config = parse_args(Args, #{}),
    
    % Compile if needed
    case compile_if_needed() of
        ok ->
            % Load elmdb
            code:add_pathz("_build/default/lib/elmdb/ebin"),
            
            % Run the benchmark
            io:format("Starting 50M transaction benchmark...~n~n"),
            
            Result = elmdb_50m_chaos_benchmark:run(Config),
            
            io:format("~n=== Benchmark Complete ===~n"),
            io:format("Result: ~p~n", [Result]);
        {error, Reason} ->
            io:format("Failed to compile: ~p~n", [Reason]),
            halt(1)
    end.

parse_args([], Config) ->
    Config;
parse_args(["--target", Target | Rest], Config) ->
    parse_args(Rest, Config#{target => list_to_integer(Target)});
parse_args(["--workers", Workers | Rest], Config) ->
    parse_args(Rest, Config#{workers => list_to_integer(Workers)});
parse_args(["--value-size", Size | Rest], Config) ->
    parse_args(Rest, Config#{value_size => list_to_integer(Size)});
parse_args(["--map-size", Size | Rest], Config) ->
    parse_args(Rest, Config#{map_size => parse_size(Size)});
parse_args(["--sequential" | Rest], Config) ->
    parse_args(Rest, Config#{sequential => true});
parse_args(["--help" | _], _) ->
    print_help(),
    halt(0);
parse_args([Unknown | _], _) ->
    io:format("Unknown option: ~s~n~n", [Unknown]),
    print_help(),
    halt(1).

parse_size(Size) ->
    case string:to_lower(lists:reverse(Size)) of
        "g" ++ Rev -> list_to_integer(lists:reverse(Rev)) * 1024 * 1024 * 1024;
        "m" ++ Rev -> list_to_integer(lists:reverse(Rev)) * 1024 * 1024;
        "k" ++ Rev -> list_to_integer(lists:reverse(Rev)) * 1024;
        _ -> list_to_integer(Size)
    end.

print_help() ->
    io:format("Usage: ./run_50m_benchmark.escript [OPTIONS]~n~n"),
    io:format("Options:~n"),
    io:format("  --target N         Target number of transactions (default: 50000000)~n"),
    io:format("  --workers N        Number of worker processes (default: 10)~n"),
    io:format("  --value-size N     Size of values in bytes (default: 100)~n"),
    io:format("  --map-size SIZE    Map size (e.g., 100G, 500M) (default: 100G)~n"),
    io:format("  --sequential       Use sequential keys instead of random~n"),
    io:format("  --help             Show this help~n~n"),
    io:format("Examples:~n"),
    io:format("  # Run with defaults (50M transactions, 100GB map)~n"),
    io:format("  ./run_50m_benchmark.escript~n~n"),
    io:format("  # Run smaller test with sequential keys~n"),
    io:format("  ./run_50m_benchmark.escript --target 1000000 --map-size 10G --sequential~n~n"),
    io:format("  # Run with more workers and larger values~n"),
    io:format("  ./run_50m_benchmark.escript --workers 20 --value-size 1000~n").

compile_if_needed() ->
    % Check if test module exists
    TestBeam = "_build/default/lib/elmdb/test/elmdb_50m_chaos_benchmark.beam",
    TestSrc = "test/elmdb_50m_chaos_benchmark.erl",
    
    case needs_recompile(TestBeam, TestSrc) of
        true ->
            io:format("Compiling benchmark module...~n"),
            case os:cmd("rebar3 compile") of
                "" -> ok;
                Output -> 
                    io:format("~s~n", [Output]),
                    ok
            end;
        false ->
            ok
    end.

needs_recompile(Beam, Src) ->
    case {filelib:last_modified(Beam), filelib:last_modified(Src)} of
        {0, _} -> true;  % Beam doesn't exist
        {BeamTime, SrcTime} when SrcTime > BeamTime -> true;
        _ -> false
    end.