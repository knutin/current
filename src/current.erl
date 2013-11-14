%% @doc: DynamoDB client
-module(current).
-compile(export_all).


%%
%% HIGH-LEVEL HELPERS
%%

wait_for_active(Table, Timeout) ->
    case describe_table({[{<<"TableName">>, Table}]}, [{timeout, Timeout}]) of
        {ok, {[{<<"Table">>, {Description}}]}} ->
            case proplists:get_value(<<"TableStatus">>, Description) of
                <<"ACTIVE">> ->
                    ok;
                <<"DELETING">> ->
                    {error, deleting};
                _Other ->
                    wait_for_active(Table, Timeout)
            end;
        {error, {<<"ResourceNotFoundException">>, _}} ->
            {error, not_found}
    end.


wait_for_delete(Table, Timeout) ->
    case describe_table({[{<<"TableName">>, Table}]}, [{timeout, Timeout}]) of
        {ok, {[{<<"Table">>, {Description}}]}} ->
            case proplists:get_value(<<"TableStatus">>, Description) of
                <<"DELETING">> ->
                    wait_for_delete(Table, Timeout);
                Other ->
                    {error, {unexpected_state, Other}}
            end;
        {error, {<<"ResourceNotFoundException">>, _}} ->
            ok
    end.




%%
%% LOW-LEVEL API
%%


create_table(Request, Opts) ->
    retry(create_table, Request, Opts).

delete_table(Request) -> delete_table(Request, []).
delete_table(Request, Opts) ->
    retry(delete_table, Request, Opts).

describe_table(Request) -> describe_table(Request, []).
describe_table(Request, Opts) ->
    retry(describe_table, Request, Opts).


batch_write_item({UserRequest}, Opts) ->
    do_batch_write_item({UserRequest}, Opts).


do_batch_write_item(Request, Opts) ->
    {Batch, Rest} = take_write_batch(Request),

    BatchRequest = {[{<<"ReturnConsumedCapacity">>, <<"TOTAL">>},
                     {<<"ReturnItemCollectionMetrics">>, <<"NONE">>},
                     {<<"RequestItems">>, {Batch}}]},

    case retry(batch_write_item, BatchRequest, Opts) of
        {ok, {Result}} ->
            {Unprocessed} = proplists:get_value(<<"UnprocessedItems">>, Result),
            case Unprocessed =:= [] andalso Rest =:= [] of
                true ->
                    ok;
                false ->
                    Remaining = orddict:merge(fun (_, Left, Right) ->
                                                      Left ++ Right
                                              end,
                                              orddict:from_list(Unprocessed),
                                              orddict:from_list(Rest)),

                    do_batch_write_item({[{<<"RequestItems">>, {Remaining}}]}, Opts)
            end;
        {error, _} = Error ->
            Error
    end.


take_write_batch({[{<<"RequestItems">>, {RequestItems}}]}) ->
    %% TODO: Validate item size
    %% TODO: Chunk on 1MB request size
    %% try
    %%     {lists:foldl(fun ({Table, Requests}, Acc) ->
    %%                          case take_batch(25, Requests, []) of
    %%                              {Batch, []} ->
    %%                                  [{Table, Batch}| Acc];
    %%                              {Batch, Rest} ->
    %%                                  throw({batch, {Table, Batch}, [{Table, Rest} | Acc]})
    %%                          end
    %%                  end, [], RequestItems), []}
    %% catch
    %%     {batch, Batch, Rest} ->
    %%         {Batch, Rest}
    %% end.

    do_take_write_batch(RequestItems, 0, []).

do_take_write_batch(Remaining, 25, Acc) ->
    {lists:reverse(Acc), Remaining};

do_take_write_batch([], _, Acc) ->
    {lists:reverse(Acc), []};

do_take_write_batch([{Table, Requests} | RemainingTables], N, Acc) ->
    case take_batch(25, Requests, []) of
        {Batch, []} ->
            do_take_write_batch(RemainingTables,
                                N + length(Batch),
                                [{Table, Batch} | Acc]);
        {Batch, Rest} ->
            do_take_write_batch([{Table, Rest} | RemainingTables],
                                N + length(Batch),
                                [{Table, Batch} | Acc])
    end.



take_batch(0, T, Acc)       -> {lists:reverse(Acc), T};
take_batch(_, [H], Acc)     -> {lists:reverse([H | Acc]), []};
take_batch(N, [H | T], Acc) -> take_batch(N-1, T, [H | Acc]).


%% retry(F, Opts) ->
%%     retry(F, 0, os:timestamp(), timeout(Opts)).

%% retry(F, Retries, RequestStart, Timeout) ->
%%     %% Assume requests take the same amount of time....
%%     FStart = os:timestamp(),
%%     try F() of
%%         {ok, Result} ->
%%             {ok, Result};

%%         {error, timeout} ->

%%             %% Do we have time to try again?
%%             FDelta = timer:now_diff(os:timestamp(), FStart),
%%             case timer:now_diff(os:timestamp(), Start) < Timeout


retry(Op, Request, Opts) ->
    retry(Op, Request, 0, Opts).

retry(Op, Request, Retries, Opts) ->
    case do(Op, Request, timeout(Opts)) of
        {ok, _} = Result ->
            Result;
        {error, {server, _}} = Error ->
            lager:info("server error: ~p", [Error]),
            Sleep = math:pow(2, Retries) * 50,
            lager:info("sleep: ~p", [Sleep]),
            timer:sleep(Sleep),
            case Retries+1 =:= retries(Opts) of
                true ->
                    {error, max_retries};
                false ->
                    retry(Op, Request, Retries+1, Opts)
            end;

        {error, {_Exception, _Message}} = Error->
            Error
    end.



do(Operation, Request, Timeout) ->
    Now = edatetime:now2ts(),

    Body = jiffy:encode(Request),

    URL = "http://dynamodb." ++ endpoint() ++ ".amazonaws.com/",
    Headers = [
               {"host", "dynamodb." ++ endpoint() ++ ".amazonaws.com"},
               {"content-type", "application/x-amz-json-1.0"},
               {"x-amz-date", binary_to_list(edatetime:iso8601(Now))},
               {"x-amz-target", target(Operation)}
              ],

    Signed = [{"Authorization", authorization(Headers, Body, Now)} | Headers],

    case lhttpc:request(URL, "POST", Signed, Body, Timeout) of
        {ok, {{200, "OK"}, _, ResponseBody}} ->
            {ok, jiffy:decode(ResponseBody)};

        {ok, {{Code, _}, _, ResponseBody}}
          when 400 =< Code andalso Code =< 499 ->
            {Response} = jiffy:decode(ResponseBody),
            Type = case proplists:get_value(<<"__type">>, Response) of
                       <<"com.amazonaws.dynamodb.v20120810#", T/binary>> ->
                           T;
                       <<"com.amazon.coral.validate#", T/binary>> ->
                           T;
                       <<"com.amazon.coral.service#", T/binary>> ->
                           T
                   end,
            Message = case proplists:get_value(<<"message">>, Response) of
                          undefined ->
                              %% com.amazon.coral.service#SerializationException
                              proplists:get_value(<<"Message">>, Response);
                          M ->
                              M
                      end,
            {error, {Type, Message}};

        {ok, {{Code, _}, _, ResponseBody}}
          when 500 =< Code andalso Code =< 599 ->
            {error, {server, jiffy:decode(ResponseBody)}}
    end.


timeout(Opts) -> proplists:get_value(timeout, Opts, 5000).
retries(Opts) -> proplists:get_value(retries, Opts, 3).


%%
%% AWS4 request signing
%% http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
%%


authorization(Headers, Body, Now) ->
    CanonicalRequest = canonical(Headers, Body),

    HashedCanonicalRequest = string:to_lower(
                               hmac:hexlify(
                                 erlsha2:sha256(CanonicalRequest))),

    StringToSign = string_to_sign(HashedCanonicalRequest, Now),

    lists:flatten(
      ["AWS4-HMAC-SHA256 ",
       "Credential=", credential(Now), ", ",
       "SignedHeaders=", string:join([string:to_lower(K)
                                      || {K, _} <- lists:sort(Headers)],
                                     ";"), ", ",
       "Signature=", signature(StringToSign, Now)]).


canonical(Headers, Body) ->
    string:join(
      ["POST",
       "/",
       "",
       [string:to_lower(K) ++ ":" ++ V ++ "\n" || {K, V} <- lists:sort(Headers)],
       string:join([string:to_lower(K) || {K, _} <- lists:sort(Headers)],
                   ";"),
       hexdigest(Body)],
      "\n").

string_to_sign(HashedCanonicalRequest, Now) ->
    ["AWS4-HMAC-SHA256", "\n",
     binary_to_list(edatetime:iso8601_basic(Now)), "\n",
     [ymd(Now), "/", endpoint(), "/", aws_host(), "/aws4_request"], "\n",
     HashedCanonicalRequest].


derived_key(Now) ->
    Secret = ["AWS4", secret_key()],
    Date = hmac:hmac256(Secret, ymd(Now)),
    Region = hmac:hmac256(Date, endpoint()),
    Service = hmac:hmac256(Region, aws_host()),
    hmac:hmac256(Service, "aws4_request").


signature(StringToSign, Now) ->
    string:to_lower(
      hmac:hexlify(
        hmac:hmac256(derived_key(Now),
                     StringToSign))).



credential(Now) ->
    [access_key(), "/", ymd(Now), "/", endpoint(), "/", aws_host(), "/aws4_request"].

hexdigest(Body) ->
    string:to_lower(hmac:hexlify(erlsha2:sha256(Body))).



target(batch_write_item)   -> "DynamoDB_20120810.BatchWriteItem";
target(create_table)   -> "DynamoDB_20120810.CreateTable";
target(delete_table)   -> "DynamoDB_20120810.DeleteTable";
target(describe_table) -> "DynamoDB_20120810.DescribeTable";
target(list_tables)    -> "DynamoDB_20120810.ListTables";
target(Target)         -> throw({unknown_target, Target}).


%%
%% INTERNAL HELPERS
%%


endpoint() ->
    {ok, Endpoint} = application:get_env(current, endpoint),
    Endpoint.

aws_host() ->
    application:get_env(current, aws_host, "dynamodb").

access_key() ->
    {ok, Access} = application:get_env(current, access_key),
    Access.

secret_key() ->
    {ok, Secret} = application:get_env(current, secret_access_key),
    Secret.

ymd(Now) ->
    {Y, M, D} = edatetime:ts2date(Now),
    io_lib:format("~4.10.0B~2.10.0B~2.10.0B", [Y, M, D]).

