local recording={}

local function items(inventory)
  return inventory and inventory.valid and inventory.get_contents() or {}
end

local function entity_info(entity)
  if not entity or not entity.valid then return end
  return {name=entity.name,type=entity.type,position=entity.position,direction=entity.direction}
end

local function active(index)
  return storage.recordings and storage.recordings[index]
end

local function flush(session)
  if #session.pending==0 then return end
  helpers.write_file(session.path,table.concat(session.pending,"\n").."\n",true,0)
  session.pending={}
end

local function add(player,kind,data)
  local session=active(player.index)
  if not session then return end
  session.count=session.count+1
  session.pending[#session.pending+1]=helpers.table_to_json{
    version=1,sequence=session.count,tick=game.tick,elapsed_ticks=game.tick-session.start,
    player=player.index,surface=player.surface.name,position=player.position,kind=kind,data=data
  }
  if #session.pending>=30 then flush(session) end
end

function recording.start(player)
  if active(player.index) then return end
  storage.recordings=storage.recordings or {}
  storage.recording_serial=(storage.recording_serial or 0)+1
  local path=("companion-demonstrations/player-%d-tick-%d-run-%d.jsonl")
    :format(player.index,game.tick,storage.recording_serial)
  local session={path=path,start=game.tick,count=0,pending={}}
  storage.recordings[player.index]=session
  add(player,"start",{seed=player.surface.map_gen_settings.seed,inventory=items(player.get_main_inventory())})
  flush(session)
  player.print("Журнал действий включён. Остановить: /companion-record stop")
end

function recording.stop(player)
  local session=active(player.index)
  if not session then return end
  add(player,"stop",{inventory=items(player.get_main_inventory())})
  flush(session)
  storage.recordings[player.index]=nil
  player.print("Журнал сохранён: "..session.path)
end

function recording.status(player)
  local session=active(player.index)
  return session and session.count
end

function recording.arm_demo()
  assert(#game.players==0,"Демонстрацию можно подготовить только на карте без игроков")
  storage.demo_recording=true
  return {ready=true,empty_inventory=true,recording_on_join=true}
end

local function inventory_snapshot(player,session)
  local inventory=items(player.get_main_inventory())
  local stack=player.cursor_stack
  local cursor=stack and stack.valid_for_read and {name=stack.name,count=stack.count} or nil
  local state=helpers.table_to_json{items=inventory,cursor=cursor}
  if state~=session.inventory then
    session.inventory=state
    add(player,"inventory",{items=inventory,cursor=cursor})
  end
end

local function machine_stock(entity)
  if not entity or not entity.valid then return end
  local stock={fuel=items(entity.get_fuel_inventory()),output=items(entity.get_output_inventory())}
  if entity.type=="furnace" or entity.type=="assembling-machine" then
    stock.input=items(entity.get_inventory(defines.inventory.crafter_input))
    local recipe=entity.get_recipe()
    stock.recipe=recipe and recipe.name or nil
  end
  if entity.type=="container" or entity.type=="logistic-container" then
    stock.chest=items(entity.get_inventory(defines.inventory.chest))
  end
  return stock
end

function recording.tick()
  if storage.demo_pending then
    for index in pairs(storage.demo_pending) do
      local player=game.get_player(index)
      if player and player.connected and player.character then
        player.clear_cursor()
        for _, slot in ipairs{defines.inventory.character_main,defines.inventory.character_guns,
          defines.inventory.character_ammo,defines.inventory.character_armor,defines.inventory.character_trash} do
          local inventory=player.get_inventory(slot)
          if inventory then inventory.clear() end
        end
        storage.demo_pending[index]=nil
        recording.start(player)
      end
    end
  end
  if game.tick%60~=0 or not storage.recordings then return end
  for index,session in pairs(storage.recordings) do
    local player=game.get_player(index)
    if player and player.connected then
      inventory_snapshot(player,session)
      local opened=player.opened
      if opened and opened.object_name=="LuaEntity" and opened.valid then
        local snapshot={entity=entity_info(opened),stock=machine_stock(opened)}
        local serialized=helpers.table_to_json(snapshot)
        if serialized~=session.machine then
          session.machine=serialized
          add(player,"machine_stock",snapshot)
        end
      else session.machine=nil end
      local p=player.position
      local previous=session.last_position
      if not previous or previous.surface~=player.surface.name or
        math.abs(previous.x-p.x)+math.abs(previous.y-p.y)>=1 then
        session.last_position={x=p.x,y=p.y,surface=player.surface.name}
        add(player,"waypoint")
      end
      if game.tick%120==0 then flush(session) end
    end
  end
end

function recording.on_join(player)
  if storage.demo_recording then
    storage.demo_recording=nil
    storage.demo_pending={[player.index]=true}
  end
end

local function event_handler(kind, details)
  return function(event)
    local player=event.player_index and game.get_player(event.player_index)
    if not player or not active(player.index) then return end
    add(player,kind,details(event))
  end
end

local function describe_entity(event)
  return {entity=entity_info(event.entity)}
end

script.on_event(defines.events.on_built_entity,event_handler("build",describe_entity))
script.on_event(defines.events.on_player_rotated_entity,event_handler("rotate",function(event)
  return {entity=entity_info(event.entity),previous_direction=event.previous_direction}
end))
script.on_event(defines.events.on_pre_player_mined_item,event_handler("mine_target",describe_entity))
script.on_event(defines.events.on_player_mined_item,event_handler("mined_item",function(event)
  return {item=event.item_stack.name,count=event.item_stack.count}
end))
script.on_event(defines.events.on_player_mined_entity,event_handler("mine",function(event)
  return {entity=entity_info(event.entity),items=items(event.buffer)}
end))
script.on_event(defines.events.on_pre_player_crafted_item,event_handler("queue_craft",function(event)
  return {recipe=event.recipe.name,count=event.queued_count,ingredients=items(event.items)}
end))
script.on_event(defines.events.on_player_crafted_item,event_handler("craft",function(event)
  local stack=event.item_stack
  return {recipe=event.recipe.name,item=stack.valid_for_read and stack.name or nil,
    count=stack.valid_for_read and stack.count or nil}
end))
script.on_event(defines.events.on_player_fast_transferred,event_handler("fast_transfer",function(event)
  return {entity=entity_info(event.entity),direction=event.from_player and "put" or "take"}
end))
script.on_event(defines.events.on_player_dropped_item_into_entity,event_handler("insert_one",describe_entity))
script.on_event(defines.events.on_gui_opened,event_handler("open_entity",function(event)
  if not event.entity then return {gui_type=event.gui_type} end
  return {entity=entity_info(event.entity),stock=machine_stock(event.entity)}
end))
script.on_event(defines.events.on_gui_closed,event_handler("close_gui",describe_entity))
script.on_event(defines.events.on_pre_player_left_game,function(event)
  local session=active(event.player_index)
  if session then flush(session) end
end)

commands.add_command("companion-record","Запись действий: start, stop или status.",function(command)
  local player=command.player_index and game.get_player(command.player_index)
  if not player then return end
  if command.parameter=="start" then recording.start(player)
  elseif command.parameter=="stop" then recording.stop(player)
  else
    local session=active(player.index)
    player.print(session and ("Журнал: "..session.count.." событий, "..session.path) or
      "Журнал выключен. Команда запуска: /companion-record start")
  end
end)

return recording
