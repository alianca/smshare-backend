-module(smshare_backend_files_controller, [Req]).
-export([fetch/2,
         status/2,
         destroy/2
%%       compress/2,
%%       decompress/2
        ]).

-include_lib("kernel/include/file.hrl").

-define('FILES_DIR', "/home/edric/projects/ovo/files/").


fetch('GET', [EncodedUrl, Description]) ->
    Url = http_uri:decode(EncodedUrl),
    {ok, Id} = gen_file_id(),
    boss_mq:push(Id, [{phase, starting}]),
    spawn(fun() ->
        download(Id, Url, Description)
    end),
    {json, [{ok, Id}]}.


status('GET', [Id]) ->
    case boss_mq:pull(Id, last) of
    {ok, _, []} ->
        {json, [{ok, nothing}]};
    {ok, _, [Status|_]} ->
        {json, [{ok, Status}]};
    {error, Reason} ->
        {json, [{error, [Reason]}]}
    end.


destroy('GET', [Id]) ->
    case file:delete(?FILES_DIR ++ Id) of
    ok ->
        {json, [{ok, ok}]};
    {error,enoent} ->
        {json, [{ok, ok}]};
    Err={error,_} ->
        {json, [Err]}
    end.


compress('GET', [Filename | Files]) ->
    {ok, Id} = gen_file_id(),
    %% BG Compress with LP progress report
    {json, [{ok, Id}]}.


decompress('GET', [Filename]) ->
    %% BG Decompress with LP progress report
    {json, [{ok, null}]}.


%% Private Functions

error_for(404) -> not_found;
error_for(403) -> forbidden;
error_for(500) -> server_error.


timestamp() ->
    {M,S,U} = now(),
    M * 1000000 + S * 1000 + U.


gen_file_id() ->
    Id = url_b64(crypto:md5(integer_to_list(timestamp()))),
    case file:path_consult(string:tokens(?FILES_DIR, "/"), Id) of
    {error, enoent} ->
        {ok, Id};
    {ok, _, _} ->
        gen_file_id();
    Error ->
        Error
    end.


tr(Str, Chr, Rep) ->
    TR1 = fun({C, R}, Acc) ->
        re:replace(Acc, "\\"++[C], [R], [global,{return,list}])
    end,
    lists:foldl(TR1, Str, lists:zip(Chr, Rep)).


url_b64(String) ->
    B64 = base64:encode_to_string(String),
    string:strip(tr(B64, "+/", "-_"), right, $=).


download(Id, Url, Description) ->
    io:format("0-Self: ~p~n", [self()]),
    Options = [{sync, false}, {receiver, self()}, {stream, self}],
    case httpc:request(get, {valid(Url), []}, [], Options) of
    {ok, ReqId} ->
        File = [{filename, filename(Url)},
                {filepath, ?FILES_DIR ++ Id},
                {description, Description}],
        track_transfer(ReqId, Id, 0, 0, File);
    Error ->
        io:format("Error: ~p~n", [Error]),
        boss_mq:push(Id, [{error, Error}])
    end.

track_transfer(ReqId, Id, Size, Progress, File) ->
    io:format("Self: ~p~n", [self()]),
    receive
    %% Headers
    {http, {ReqId, stream_start, Headers}} ->
        io:format("1-Self: ~p~n", [self()]),
        {_, Type} = lists:keyfind("content-type", 1, Headers),
        {_, StrSize} = lists:keyfind("content-length", 1, Headers),

        NewSize = list_to_integer(StrSize),
        
        if Type == "text/html" ->
            boss_mq:push(Id, [{error, html_file}]);
        true ->
            NewFile = File ++ [{filetype, Type}, {filesize, NewSize}],
            track_transfer(ReqId, Id, NewSize, Progress, NewFile)
        end;

    %% Partial data
    {http, {ReqId, stream, Data}} ->
        io:format("2-Self: ~p~n", [self()]),
        ok = file:write_file(?FILES_DIR ++ Id, Data, [append]),
        
        NewProg = Progress + size(Data),
        boss_mq:push(Id, [{phase,working},{done,NewProg},{total,Size}]),
        
        track_transfer(ReqId, Id, Size, NewProg, File);

    %% Done
    {http, {ReqId, stream_end, Headers}} ->
        io:format("3-Self: ~p~n", [self()]),
        boss_mq:push(Id, [{phase, done}, {file, File}]);

    %% Error
    {http, {ReqId, Error}} ->
        boss_mq:push(Id, [Error])
    end.


valid(Url) ->
    case re:run(Url, "^(https?|s?ftp):\\/\\/") of
    {match, _} ->
        Url;
    nomatch ->
        "http://" ++ Url
    end.


filename(Url) ->
    {match, [Filename]} = re:run(Url, "([^/]+)$", [{capture, [1], list}]),
    Filename.
