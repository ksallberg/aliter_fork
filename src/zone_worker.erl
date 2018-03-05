-module(zone_worker).

-behaviour(gen_server).

-include("records.hrl").
-include("ro.hrl").

-include_lib("stdlib/include/qlc.hrl").

-export([ start_link/4 ]).

-export([ init/1 ]).

-export([ show_actors/1
        , say/2
        , send/2]).

-export([ code_change/3
        , format_status/2
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2 ]).

-define(WALKSPEED, 150).

send(#zone_state{tcp = TCP, packet_handler = PacketHandler}, Packet) ->
    ragnarok_proto:send_packet(Packet, TCP, PacketHandler).

start_link(TCP, DB, PacketHandler, Server) ->
    gen_server:start_link(?MODULE, [TCP, DB, PacketHandler, Server], []).

init([TCP, DB, PacketHandler, Server]) ->
    process_flag(trap_exit, true),
    {ok, #zone_state{db = DB, tcp = TCP,
                     packet_handler = PacketHandler, server = Server}}.

handle_cast({connect, AccountID, CharacterID, SessionIDa, _Gender}, State) ->
    DB = State#zone_state.db,
    Session =
        gen_server:call(char_server,
                        {verify_session, AccountID, CharacterID, SessionIDa}),
    case Session of
        {ok, Worker} ->
            {ok, C = #char_state{char = Char}} =
                gen_server:call(Worker, switch_zone),
            {ok, Map, MapServer} =
                gen_server:call(State#zone_state.server, {add_player,
                                                          Char#char.map,
                                                          {AccountID, self()}}),
            send(State, {account_id, AccountID}),
            send(State, {accept, {zone_master:tick(),
                                  {Char#char.x, Char#char.y, 0}}}),
            Items = db:get_player_items(DB, Char#char.id),
            send(State, {inventory, Items}),
            WorldItems = db:get_world_items(DB, Char#char.map),
            lists:foreach(
              fun(Item) ->
                      send(State, {item_on_ground, {Item#world_item.slot,
                                                    Item#world_item.item,
                                                    1,
                                                    Char#char.x + 1,
                                                    Char#char.y + 1,
                                                    1,
                                                    2,
                                                    Item#world_item.amount
                                                   }})
              end,
              WorldItems),
            case Char#char.guild_id of
                0 ->
                    ok;
                GuildID ->
                    send(State, {guild_status, master}),
                    Guild = db:get_guild(DB, GuildID),
                    send(State, {update_gd_id, Guild})
            end,
            say("Welcome to Aliter.", State),
            NewState = State#zone_state{map = Map,
                                        map_server = MapServer,
                                        account = C#char_state.account,
                                        char = C#char_state.char,
                                        id_a = C#char_state.id_a,
                                        id_b = C#char_state.id_b,
                                        packet_ver = C#char_state.packet_ver,
                                        char_worker = Worker},
            {noreply, NewState};
        invalid ->
            lager:log(warning, "Invalid zone login attempt caught ~p ~p",
                      [{account_id, AccountID},
                       {character_id, CharacterID}]),
            {noreply, State}
    end;
handle_cast({set_server, Server}, State) ->
    {noreply, State#zone_state{server = Server}};
handle_cast({npc_activate, ActorID},
            State = #zone_state{map_server=MapServer}) ->
    case gen_server:call(MapServer, {get_actor, ActorID}) of
        {npc, NPC} ->
            ZoneWorker = self(),
            SpawnFun = fun() ->
                               zone_npc:spawn_logic(ZoneWorker, ActorID,
                                                    NPC#npc.main)
                       end,
            Proc = spawn(SpawnFun),
            {noreply, State#zone_state{npc = {Proc, NPC}}};
        _Invalid ->
            lager:log(error, self(), "NPC not found ~p", [{id, ActorID}]),
            {noreply, State}
    end;
%% TODO: handle selecting 255 (Cancel button)
handle_cast({npc_menu_select, _ActorID, Selection},
            State = #zone_state{npc = {Pid, _NPC}}) ->
    Pid ! Selection,
    {noreply, State};
handle_cast({npc_next, _ActorID}, State = #zone_state{npc = {Pid, _NPC}}) ->
    Pid ! continue,
    {noreply, State};
handle_cast({npc_close, _ActorID}, State = #zone_state{npc = {Pid, _NPC}}) ->
    Pid ! close,
    {noreply, State};
handle_cast(map_loaded, State) ->
    show_actors(State),
    {noreply, State};
handle_cast({create_guild, CharId, GName},
            State = #zone_state{db   = DB,
                                char = Char}) ->
    Guild = #guild{name      = GName,
                   master_id = CharId},
    GuildSaved = db:save_guild(DB, Guild),
    GuildID = GuildSaved#guild.id,
    NewChar = Char#char{guild_id=GuildID},
    %% Update char
    db:save_char(DB, NewChar),
    %% Notify client
    send(State, {guild_status, master}),
    send(State, {update_gd_id, GuildSaved}),
    say("Welcome to guild " ++ GName ++ ".", State),
    {noreply, State#zone_state{char=NewChar}};
handle_cast({action_request, _Target, 2},
            State = #zone_state{map_server = MapServer,
                                account = #account{id=AccountID},
                                char = #char{x=X, y=Y}}) ->
    Msg = {AccountID, 0, zone_master:tick(), 0, 0, 0, 0, 2, 0},
    gen_server:cast(MapServer,
                    {send_to_players_in_sight, {X, Y}, actor_effect, Msg}),
    {noreply, State};
handle_cast({action_request, _Target, 3},
            State = #zone_state{map_server = MapServer,
                                account = #account{id = AID},
                                char = #char{x = X, y = Y}}) ->
    gen_server:cast(MapServer,
                    {send_to_players_in_sight, {X, Y}, actor_effect,
                     {AID, 0, zone_master:tick(), 0, 0, 0, 0, 3, 0}}),
    {noreply, State};
%% TODO use GuildID
handle_cast({guild_emblem, _GuildID}, State) ->
    send(State, {guild_relationships, []}),
    {noreply, State};
%% Change ongoing walk
handle_cast({walk, {ToX, ToY, _ToD}},
            State = #zone_state{map = Map,
                                is_walking = true,
                                char = #char{x = X,
                                             y = Y}}) ->
    Path = nif:pathfind(Map#map.id, [X | Y], [ToX | ToY]),
    {noreply, State#zone_state{walk_path = Path,
                               walk_changed = {X, Y}}};
handle_cast({walk, {ToX, ToY, _ToD}},
            State = #zone_state{map = Map,
                                map_server = MapServer,
                                account = #account{id = AccountID},
                                char = C = #char{id = CharacterID,
                                                 x = X,
                                                 y = Y}}) ->
    PathFound = nif:pathfind(Map#map.id, [X | Y], [ToX | ToY]),
    case PathFound of
        [{SX, SY, SDir} | Path] ->
            {ok, Timer} = walk_interval(SDir),
            {FX, FY, _FDir} = lists:last(PathFound),
            Msg = {send_to_other_players_in_sight,
                   {X, Y},
                   CharacterID,
                   actor_move,
                   {AccountID, {X, Y}, {FX, FY}, zone_master:tick()}},
            gen_server:cast(MapServer, Msg),
            send(State, {move, {{X, Y}, {FX, FY}, zone_master:tick()}}),
            {noreply, State#zone_state{char = C#char{x = SX, y = SY},
                                       is_walking = true,
                                       walk_timer = Timer,
                                       walk_prev = {erlang:timestamp(), SDir},
                                       walk_path = Path}};
        _Error ->
            {noreply, State}
    end;
handle_cast(step, State = #zone_state{char = C,
                                      account = A,
                                      map_server = MapServer,
                                      walk_timer = Timer,
                                      walk_prev = {Time, PDir},
                                      walk_path = Path,
                                      walk_changed = Changed}) ->
    case Path of
        [] ->
            timer:cancel(Timer),
            NewState = State#zone_state{walk_timer = undefined,
                                        walk_path = undefined,
                                        is_walking = false,
                                        walk_changed = false},
            {noreply, NewState};
        [{CX, CY, CDir} | Rest] ->
            if
                CDir == PDir ->
                    NewTimer = Timer;
                true ->
                    timer:cancel(Timer),
                    {ok, NewTimer} = walk_interval(CDir)
            end,
            case Changed of
                {X, Y} ->
                    {FX, FY, _FDir} = lists:last(Path),
                    gen_server:cast(
                      MapServer,
                      { send_to_other_players_in_sight,
                        {X, Y},
                        C#char.id,
                        actor_move,
                        {A#account.id, {X, Y}, {FX, FY}, zone_master:tick()}
                      }
                     ),
                    send(State, {move, {{X, Y}, {FX, FY}, zone_master:tick()}});
                _ -> ok
            end,
            NewState = State#zone_state{char = C#char{x = CX, y = CY},
                                        walk_timer = NewTimer,
                                        walk_prev = {Time, CDir},
                                        walk_path = Rest,
                                        walk_changed = false},
            {noreply, NewState}
    end;
handle_cast({send_packet_if, Pred, Packet, Data}, State) ->
    case Pred(State) of
        true ->
            send(State, {Packet, Data});
        false ->
            ok
    end,
    {noreply, State};
handle_cast(quit, State) ->
    send(State, {quit_response, 0}),
    {noreply, State};
handle_cast({char_select, _Type}, State) ->
    send(State, {confirm_back_to_char, {1}}),
    {noreply, State};
handle_cast({request_name, ActorID},
            State = #zone_state{account = #account{id = AccountID},
                                db = DB,
                                char = #char{name = CharacterName,
                                             guild_id = GuildID},
                                map_server = MapServer}) ->
    Name =
        if
            ActorID == AccountID ->
                case GuildID of
                    0 ->
                        GuildName = "";
                    _ ->
                        #guild{name=GuildName} = db:get_guild(DB, GuildID)
                end,
                {actor_name_full,
                 {ActorID, CharacterName, <<"">>, GuildName, <<"">>}};
                         %%               party          guild position
            true ->
                case gen_server:call(MapServer, {get_actor, ActorID}) of
                    {player, Worker} ->
                        {ok, #zone_state{char=#char{name=CharName,
                                                    guild_id=OtherGuildID}}}
                            = gen_server:call(Worker, get_state),
                        case OtherGuildID of
                            0 ->
                                OtherGuildName = "";
                            _ ->
                                #guild{name=OtherGuildName}
                                    = db:get_guild(DB, OtherGuildID)
                        end,
                        {actor_name_full, {ActorID,
                                           CharName,
                                           "", %% party
                                           OtherGuildName,
                                           ""}}; %% guild position
                    {mob, Mob} ->
                        {actor_name, {ActorID, Mob#npc.name}};
                    {npc, NPC} ->
                        {actor_name, {ActorID, NPC#npc.name}};
                    none ->
                        "Unknown"
                end
        end,
    send(State, Name),
    {noreply, State};
handle_cast(player_count, State) ->
    Num = gen_server:call(zone_master, player_count),
    send(State, {player_count, Num}),
    {noreply, State};
handle_cast({emotion, Id},
            State = #zone_state{map_server = MapServer,
                                account = #account{id = AccountID},
                                char = #char{id = CharacterID,
                                             x = X,
                                             y = Y}}) ->
    Map = {send_to_other_players_in_sight, {X, Y}, CharacterID,
           emotion, {AccountID, Id}},
    gen_server:cast(MapServer, Map),
    send(State, {emotion, {AccountID, Id}}),
    {noreply, State};
handle_cast({speak, Message},
            State = #zone_state{map_server = MapServer,
                                account = #account{id = AccountID},
                                char = #char{id = CharacterID,
                                             x = X,
                                             y = Y}}) ->
    [_Name | Rest] = re:split(Message, " : ", [{return, list}]),
    Said = lists:concat(Rest),
    if
        (hd(Said) == 92) and (length(Said) > 1) -> % GM command
            [Command | Args] = zone_commands:parse(tl(Said)),
            Worker = self(),
            spawn(
              fun() ->
                      zone_commands:execute(Worker, Command, Args, State)
              end
             );
        true ->
            gen_server:cast(MapServer, {send_to_other_players_in_sight, {X, Y},
                                        CharacterID, actor_message,
                                        {AccountID, Message}}),
            send(State, {message, Message})
    end,
    {noreply, State};
handle_cast({broadcast, Message}, State) ->
    gen_server:cast(zone_master,
                    {send_to_all, {send_to_all,
                                   {send_to_players, broadcast, Message}}}),
    {noreply, State};
handle_cast({switch_zones, Update}, State) ->
    {stop, normal, Update(State)};
handle_cast({hat_sprite, SpriteID},
      #zone_state{char=#char{x=X, y=Y, id=_CharacterID, account_id=AID},
                  map_server=MapServer} = State) ->
    send(State, {sprite, {AID, 4, SpriteID}}),
    Msg = {send_to_other_players_in_sight, {X, Y},
           AID,
           sprite,
           {AID, 4, SpriteID}},
    gen_server:cast(MapServer, Msg),
    {noreply, State};
handle_cast({change_job, JobID},
      #zone_state{db=DB, char=#char{x=X, y=Y, account_id=AID}=Char,
                  map_server=MapServer}=State) ->
    NewChar = Char#char{job=JobID},
    NewState = State#zone_state{char=NewChar},
    db:save_char(DB, NewChar),
    send(State, {sprite, {AID, 0, JobID}}),
    Msg = {send_to_other_players_in_sight, {X, Y},
           AID,
           sprite,
           {AID, 0, JobID}},
    gen_server:cast(MapServer, Msg),
    {noreply, NewState};
handle_cast({monster, SpriteID, X, Y},
            #zone_state{map=Map, map_server=MapServer,
                        char=#char{account_id=AID}} = State) ->
    MonsterID = gen_server:call(monster_srv, next_id),
    NPC = #npc{id=MonsterID,
               name=monsters:strname(SpriteID),
               sprite=SpriteID,
               map=Map,
               coordinates={X, Y},
               direction=north,
               main=0},
    gen_server:cast(zone_map:server_for(Map), {register_mob, NPC}),
    send(State, {monster, {SpriteID, X, Y, MonsterID}}),
    Msg = {send_to_other_players_in_sight, {X, Y},
           AID,
           monster,
           {SpriteID, X, Y, MonsterID}},
    gen_server:cast(MapServer, Msg),
    {noreply, State};
handle_cast({npc, SpriteID, X, Y},
            #zone_state{map=Map, map_server=MapServer,
                        char=#char{account_id=AID}} = State) ->
    MonsterID = gen_server:call(monster_srv, next_id),
    NPC = #npc{id=MonsterID,
               name="npc",
               sprite=SpriteID,
               map=Map,
               coordinates={X, Y},
               direction=north,
               objecttype=6,
               main=0},
    gen_server:cast(zone_map:server_for(Map), {register_npc, NPC}),
    send(State, {show_npc, NPC}),
    Msg = {send_to_other_players_in_sight, {X, Y},
           AID,
           show_npc,
           NPC},
    gen_server:cast(MapServer, Msg),
    {noreply, State};
handle_cast({give_item, ID, Amount},
            State = #zone_state{char = #char{id = CharacterID}}) ->
    give_item(State, CharacterID, ID, Amount),
    {noreply, State};
handle_cast(stop, State = #zone_state{char_worker = Char}) ->
    gen_server:cast(Char, exit),
    {stop, normal, State};
handle_cast({tick, _Tick}, State) ->
    send(State, {tick, zone_master:tick()}),
    {noreply, State};
handle_cast({send_packet, Packet, Data}, State) ->
    lager:log(info, self(), "Send packet ~p ~p", [{packet, Packet},
                                                  {data, Data}]),
    send(State, {Packet, Data}),
    {noreply, State};
handle_cast({send_packets, Packets},
            #zone_state{tcp = Socket,
                        packet_handler = PacketHandler} = State) ->
    ragnarok_proto:send_packets(Socket, Packets, PacketHandler),
    {noreply, State};
handle_cast({show_to, Worker},
            State = #zone_state{account = A, char = C }) ->
    gen_server:cast(Worker, {send_packet, change_look, C}),
    gen_server:cast(Worker, {send_packet, actor, {normal, A, C}}),
    {noreply, State};
handle_cast({update_state, Fun}, State) ->
    {noreply, Fun(State)};
handle_cast(crash, _) ->
    exit('crash induced');
handle_cast(request_guild_status,
            State = #zone_state{db = DB,
                                char = #char{id = CharacterID,
                                             guild_id = GuildID}}) ->
    if
        GuildID /= 0 ->
            GetGuildMaster = db:get_guild_master(DB, GuildID),
            case GetGuildMaster of
                CharacterID ->
                    send(State, {guild_status, master});
                _ ->
                    send(State, {guild_status, member})
            end;
        true ->
            send(State, {guild_status, none})
    end,
    {noreply, State};
handle_cast({request_guild_info, 0},
            State = #zone_state{
                       db = DB,
                       char = #char{guild_id = GuildID}
                      }) when GuildID /= 0 ->
    GetGuild = db:get_guild(DB, GuildID),
    case GetGuild of
        %% TODO?
        nil -> ok;
        G ->
            send(State, {guild_info, G}),
            send(State, {guild_relationships, G#guild.relationships})
    end,
    {noreply, State};
handle_cast({request_guild_info, 1},
            State = #zone_state{
                       db = DB,
                       char = #char{guild_id = GuildID}
                      }) when GuildID /= 0 ->
    GetMembers =
        gen_server:call(char_server,
                        {get_chars, db:get_guild_members(DB, GuildID)}),
    case GetMembers of
        {atomic, Members} ->
            send(State, {guild_members, Members});

        _Error ->
            ok
    end,
    {noreply, State};
handle_cast({request_guild_info, 2}, State) ->
    {noreply, State};
handle_cast({less_effect, _IsLess}, State) ->
    {noreply, State};
handle_cast({drop, Slot, Amount},
            State = #zone_state{
                       db = DB,
                       map_server = MapServer,
                       char = #char{
                                 id = CharacterID,
                                 map = Map,
                                 x = X,
                                 y = Y}}) ->
    send(State, {drop_item, {Slot, Amount}}),
    case db:get_player_item(DB, CharacterID, Slot) of
        nil ->
            say("Invalid item.", State);
        Item ->
            if
                Amount == Item#world_item.amount ->
                    db:remove_player_item(DB, CharacterID, Slot);

                true ->
                    %% TODO: update amount
                    ok
            end,
            %% TODO
            ObjectID = db:give_world_item(DB, Map, Item#world_item.item,
                                          Amount),
            Msg = {ObjectID, Item#world_item.item, 1, X+1, Y+1, 1, 2, Amount},
            gen_server:cast(MapServer,
                            {send_to_players_in_sight, {X, Y},
                             item_on_ground, Msg})
    end,
    {noreply, State};
handle_cast({pick_up, ObjectID},
            State = #zone_state{db = DB,
                                map_server = MapServer,
                                account = #account{id = AccountID},
                                char = #char{id = CharacterID,
                                             map = Map,
                                             x = X,
                                             y = Y
                                            }}) ->
    gen_server:cast(MapServer, {send_to_players, item_disappear, ObjectID}),
    Msg = {AccountID, ObjectID, zone_master:tick(), 0, 0, 0, 0, 1, 0},
    gen_server:cast(MapServer,
                    {send_to_players_in_sight, {X, Y}, actor_effect, Msg}),
    case db:get_world_item(DB, ObjectID) of
        nil ->
            say("Item already picked up", State);
        Item ->
            db:remove_world_item(DB, Map, ObjectID),
            give_item(State, CharacterID,
                      Item#world_item.item, Item#world_item.amount)
    end,
    {noreply, State};
handle_cast({change_direction, Head, Body},
            State = #zone_state{map_server = MapServer,
                                account = #account{id = AccountID},
                                char = #char{id = CharacterID,
                                             x = X,
                                             y = Y}}) ->
    Msg = {send_to_other_players_in_sight, {X, Y},
           CharacterID,
           change_direction,
           {AccountID, Head, Body}},
    gen_server:cast(MapServer, Msg),
    {noreply, State};
handle_cast(exit, State) ->
    lager:log(error, self(), "Zone Worker got EXIT signal", []),
    {stop, normal, State};
handle_cast(Other, State) ->
    lager:log(warning, self(), "Zone Worker got unknown request: ~p", [Other]),
    {noreply, State}.

%% FIXME: Not used right now:
%%        How to integrate?
terminate(_Reason, #zone_state{map_server = MapServer,
                               account = #account{id = AccountID},
                               char = Character}) ->
    Msg = {send_to_other_players, Character#char.id, vanish, {AccountID, 3}},
    gen_server:cast(MapServer, Msg),
    gen_server:cast(char_server, {save_char, Character}),
    gen_server:cast(MapServer, {remove_player, AccountID});
terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

format_status(_Opt, _) ->
    ok.

handle_call(get_state, From, State) ->
    Actions = [{reply, From, {ok, State}}],
    {reply, Actions, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

%% Helper walking function
walk_interval(N) ->
    Interval = case N band 1 of
                   1 ->
                       %% Walking diagonally.
                       trunc(?WALKSPEED * 1.4);
                   0 ->
                       %% Walking straight.
                       ?WALKSPEED
               end,
    timer:apply_interval(Interval, gen_server, cast, [self(), step]).

show_actors(#zone_state{map_server = MapServer,
                        char = C,
                        account = A
                       } = State) ->
    send(State, {status, C}), %% Send stats to client
    send(State, {status, C}),
    send(State, {param_change, {?SP_MAX_HP, 100}}),
    send(State, {param_change, {?SP_CUR_HP, 90}}),
    send(State, {param_change, {?SP_MAX_SP, 60}}),
    send(State, {param_change, {?SP_CUR_SP, 50}}),
    send(State, {equipment, whatever}), %% FIXME: Needs db support
    gen_server:cast(MapServer,
                    {send_to_other_players, C#char.id, change_look, C}),
    gen_server:cast(MapServer,
                    {send_to_other_players, C#char.id, actor, {new, A, C}}),
    gen_server:cast(MapServer,
                    {show_actors, {A#account.id, self()}}).

say(Message, State) ->
    send(State, {message, Message}).

give_item(#zone_state{db = DB} = State, CharacterID, ID, Amount) ->
    Slot = db:give_player_item(DB, CharacterID, ID, Amount),
    send(State, {give_item, {Slot,   %% Index
                             Amount, %% Amount
                             ID,     %% ID
                             1,      %% Identified
                             0,      %% Damaged
                             0,      %% Refined
                             0,      %% Card1
                             0,      %%     2
                             0,      %%     3
                             0,      %%     4
                             2,      %% EquipLocation
                             4,      %% Type
                             0,      %% Result
                             0,      %% ExpireTime
                             0}}).    %% BindOnEquipType
