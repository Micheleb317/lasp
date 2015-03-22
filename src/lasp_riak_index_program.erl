%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(lasp_riak_index_program).
-author("Christopher Meiklejohn <cmeiklejohn@basho.com>").

-behavior(lasp_program).

-export([init/1,
         process/5,
         execute/2,
         value/1,
         merge/1,
         sum/1]).

-record(state, {type, id, previous}).

-define(APP,  lasp).
-define(CORE, lasp_core).
-define(SET,  lasp_orset).
-define(VIEW, lasp_riak_index_program).

%% @doc Initialize an or-set as an accumulator.
init(Store) ->
    Id = list_to_binary(atom_to_list(?MODULE)),
    {ok, Id} = ?CORE:declare(Id, ?SET, Store),
    {ok, #state{id=Id}}.

%% @doc Notification from the system of an event.
process(Object, Reason, Idx, State, Store) ->
    lager:info("Processing value for ~p ~p", [?MODULE, Reason]),
    Key = riak_object:key(Object),
    VClock = riak_object:vclock(Object),
    Metadata = riak_object:get_metadata(Object),
    IndexSpecs = extract_valid_specs(Object),
    case Reason of
        put ->
            ok = remove_entries_for_key(Key, Idx, State, Store),
            ok = add_entry(Key, VClock, Metadata, Idx, State, Store),
            %% If this is the top-level index, create any required views
            %% off of this index.
            case ?MODULE of
                lasp_riak_index_program ->
                    ok = create_views(IndexSpecs);
                _ ->
                    ok
            end,
            ok;
        delete ->
            ok = remove_entries_for_key(Key, Idx, State, Store),
            ok;
        handoff ->
            ok
    end,
    {ok, State}.

%% @doc Return the result.
execute(#state{id=Id, previous=Previous}, Store) ->
    {ok, {_, _, Value}} = ?CORE:read(Id, Previous, Store),
    {ok, Value}.

%% @doc Return the result from a merged response
value(Merged) ->
    {ok, lists:usort([K || {K, _} <- ?SET:value(Merged)])}.

%% @doc Given a series of outputs, take each one and merge it.
merge(Outputs) ->
    Value = ?SET:new(),
    Merged = lists:foldl(fun(X, Acc) -> ?SET:merge(X, Acc) end, Value, Outputs),
    {ok, Merged}.

%% @doc Computing a sum accorss nodes is the same as as performing the
%%      merge of outputs between a replica, when dealing with the
%%      set.  For a set, it's safe to just perform the merge.
sum(Outputs) ->
    Value = ?SET:new(),
    Sum = lists:foldl(fun(X, Acc) -> ?SET:merge(X, Acc) end, Value, Outputs),
    {ok, Sum}.

%% Internal Functions

%% @doc For a given key, remove all metadata entries for that key.
remove_entries_for_key(Key, Idx, #state{id=Id, previous=Previous}, Store) ->
    {ok, {_, Type, Value}} = ?CORE:read(Id, Previous, Store),
    lists:foreach(fun(V) ->
                case V of
                    {Key, _} ->
                        {ok, _} = ?CORE:update(Id, {remove, V}, Idx, Store);
                    _ ->
                        ok
                end
        end, Type:value(Value)),
    ok.

%% @doc Add an entry to the index.
%%
%%      To ensure we can map between data types across replicas, we use
%%      the hashed vclock derived from the coordinator as the unique
%%      identifier in the index for the OR-Set.
add_entry(Key, VClock, Metadata, Idx, #state{id=Id}, Store) ->
    Hashed = crypto:hash(md5, term_to_binary(VClock)),
    lager:info("Computing unique token from vclock: ~p", [Hashed]),
    {ok, _} = ?CORE:update(Id, {add_by_token, Hashed, {Key, Metadata}}, Idx, Store),
    ok.

%% @doc Extract index specifications from indexes; only select views
%%      which add information, given we don't want to destroy a
%%      pre-computed view, for now.
extract_valid_specs(Object) ->
    IndexSpecs0 = riak_object:index_specs(Object),
    lists:filter(fun({Type, _, _}) -> Type =:= add end, IndexSpecs0).

%% @doc Register all applicable views.
%%
%%      Launch a process to asynchronously register the view; if this
%%      fails, no big deal, it will be generated on the next write.
create_views(Views) ->
    lists:foreach(fun({_Type, Name, Value}) ->
                Module = list_to_atom(atom_to_list(?VIEW) ++ "-" ++
                                      binary_to_list(Name) ++ "-" ++
                                      binary_to_list(Value)),
                spawn_link(fun() ->
                                ok = lasp:register(
                                        ?VIEW,
                                        code:lib_dir(?APP, src) ++ "/" ++ atom_to_list(?VIEW) ++ ".erl",
                                        global,
                                        [{module, Module},
                                         {index_name, Name},
                                         {index_value, Value}])
                    end)
        end, Views).
