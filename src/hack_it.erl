-module(hack_it).

-include("records.hrl").

-export([ show_char/0
        , mod_char/0
        , mod_upd/1
        , populate_mob_data/0
        , populate_item_data/0
        ]).

show_char() ->
    CharacterID = 1,
    Char = db:get_char(CharacterID),
    io:format("Char: ~p\n", [Char]).

mod_char() ->
    CharacterID = 1,
    Char = db:get_char(CharacterID),
    NewChar = mod_upd(Char),
    db:save_char(c, NewChar).

mod_upd(#char{map = _OldMap} = Ch) ->
    %% NewMap = <<"prontera">>,
    %% _NewMap = <<"prt_fild00">>,
    NewCh = Ch#char{%map = NewMap,
                    %save_map = NewMap,
                    str = 98,
                    agi = 99,
                    vit = 99,
                    int = 99,
                    dex = 99,
                    luk = 99,
                    base_level = 20,
                    max_hp = 9999,
                    max_sp = 1000,
                    view_head_top = 110,
                    %% Crusader = 14
                    job = 4015, %% Paladin
                    x = 53,
                    y = 111,
                    save_x = 53,
                    save_y = 111
                   },
    io:format("NewChar: ~p\n", [NewCh]),
    NewCh.

populate_mob_data() ->
    {ok, Data} = file:consult("data/mob_db.cfg"),
    %% A little (safe) hack. Transform each line to fit the #mob_data{}
    AsRecords = [list_to_tuple([mob_data| tuple_to_list(MobData)])
        || MobData <- Data],
    save_mob(AsRecords).

save_mob([]) ->
    ok;
save_mob([#mob_data{} = Mob|Mobs]) ->
    Fun = fun() ->
                  mnesia:write(Mob)
          end,
    mnesia:transaction(Fun),
    save_mob(Mobs).

populate_item_data() ->
    {ok, Data} = file:consult("data/item_db.cfg"),
    %% A little (safe) hack. Transform each line to fit the #item_data{}
    AsRecords = [list_to_tuple([item_data| tuple_to_list(ItemData)])
        || ItemData <- Data],
    save_item(AsRecords).

save_item([]) ->
    ok;
save_item([#item_data{} = Item|Items]) ->
    Fun = fun() ->
                  mnesia:write(Item)
          end,
    mnesia:transaction(Fun),
    save_item(Items).
