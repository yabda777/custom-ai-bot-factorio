local companion = {name="Sam"}
local map_icon = {type="virtual",name="signal-S"}

function companion.init()
  storage.jobs = storage.jobs or {}
  storage.queue = storage.queue or {}
  storage.next_id = storage.next_id or 1
  storage.books = storage.books or {}
  if storage.bot_label and storage.bot_label.valid then storage.bot_label.text = companion.name end
  if storage.bot_tag and storage.bot_tag.valid then
    storage.bot_tag.text = companion.name
    storage.bot_tag.icon = map_icon
  end
end

function companion.character()
  local bot = storage.bot
  assert(bot and bot.valid, "Companion is absent or dead. Use spawn near your player.")
  return bot
end

local function draw_label(bot)
  local surface=bot.surface
  storage.bot_label=rendering.draw_text{
    text = companion.name, surface = surface, target = {entity = bot, offset = {0, -2.6}},
    color = {r = 0.25, g = 1, b = 1}, alignment = "center", scale = 1.2
  }
end

function companion.spawn(args)
  if storage.bot and storage.bot.valid then return {position = storage.bot.position, existing = true} end
  local player = args.player and game.get_player(args.player)
  assert(not args.player or player, "Unknown player")
  local surface, force, origin
  if args.at_spawn then
    assert(not player, "Choose either a player or the force spawn")
    surface, force = game.surfaces["nauvis"], game.forces.player
    origin = force.get_spawn_position(surface)
  else
    if not player then
      assert(#game.connected_players == 1, "Join the game first, or specify the player name")
      player = game.connected_players[1]
    end
    assert(player.character, "Player needs a character")
    surface, force, origin = player.surface, player.force, player.position
  end
  local pos = surface.find_non_colliding_position("character", origin, 12, 0.5)
  assert(pos, "No room near player")
  local bot = surface.create_entity{name = "character", position = pos, force = force}
  assert(bot, "Could not create companion")
  bot.color = {r = 0.15, g = 0.85, b = 0.85, a = 1}
  draw_label(bot)
  storage.bot = bot
  return {position = pos, surface = surface.name}
end

function companion.distance(a, b)
  return ((a.x - b.x)^2 + (a.y - b.y)^2)^0.5
end

function companion.position(args)
  local x, y = args.x, args.y
  assert(type(x) == "number" and type(y) == "number" and math.abs(x) < 1000000 and
    math.abs(y) < 1000000, "Expected map coordinates x and y")
  return {x = x, y = y}
end

function companion.stop(bot)
  bot.walking_state = {walking = false, direction = defines.direction.north}
  bot.mining_state = {mining = false}
end

function companion.nearby(bot, center, radius, filter)
  assert(companion.distance(bot.position, center) <= 96, "Center is too far from companion")
  filter.position = center
  filter.radius = radius
  filter.limit = 1024
  local entities = bot.surface.find_entities_filtered(filter)
  table.sort(entities, function(a, b)
    return companion.distance(a.position, center) < companion.distance(b.position, center)
  end)
  return entities
end

local function path_request(bot, job, goal, reach, fine)
  local box=bot.prototype.collision_box
  local margin=fine and 0 or ((job.repaths or 0)>0 and 0.12 or 0.04)
  job.fine_path=fine
  job.path_id = bot.surface.request_path{
    bounding_box = {{box.left_top.x-margin,box.left_top.y-margin},
      {box.right_bottom.x+margin,box.right_bottom.y+margin}}, collision_mask = bot.prototype.collision_mask,
    start = bot.position, goal = goal, force = bot.force, radius = reach,
    entity_to_ignore = bot, can_open_gates = true, path_resolution_modifier = fine and 4 or 0
  }
  job.path_tick = game.tick
  job.path_requests = (job.path_requests or 0) + 1
  -- The request tick itself is spent standing still.
  job.path_wait_ticks = (job.path_wait_ticks or 0) + 1
end

script.on_event(defines.events.on_script_path_request_finished, function(event)
  local job = storage.active and storage.jobs[storage.active]
  if not job or job.path_id ~= event.id then return end
  job.path_id = nil
  if event.try_again_later then return end
  job.path = event.path
  job.waypoint = 1
  job.no_path = not event.path
end)

local offsets={{0,-1},{1,-1},{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1}}

function companion.walkable(bot,p)
  local box=bot.prototype.collision_box
  local area={{p.x+box.left_top.x,p.y+box.left_top.y},{p.x+box.right_bottom.x,p.y+box.right_bottom.y}}
  local layers=bot.prototype.collision_mask.layers
  if bot.surface.count_tiles_filtered{area=area,collision_mask=layers,limit=1}>0 then return false end
  -- can_place_entity sees the character itself as an obstacle on short steps.
  for _, e in ipairs(bot.surface.find_entities_filtered{area=area,collision_mask=layers}) do
    if e~=bot and not e.prototype.collision_mask.colliding_with_tiles_only then
      local b=e.bounding_box
      if b.left_top.x<area[2][1] and b.right_bottom.x>area[1][1] and
        b.left_top.y<area[2][2] and b.right_bottom.y>area[1][2] then return false end
    end
  end
  return true
end

local function recover(bot,job)
  job.repaths=(job.repaths or 0)+1
  -- job.repaths is a retry budget that gets reset; this one only grows.
  job.total_repaths=(job.total_repaths or 0)+1
  assert(job.repaths<=5,"Companion could not reach target")
  local pos=bot.position
  local previous=job.walk_direction or 0
  for _, turn in ipairs{4,2,6,3,5,1,7,0} do
    local d=(previous/2+turn+job.repaths-1)%8
    local v=offsets[d+1]
    local scale=d%2==1 and math.sqrt(0.5) or 1
    local steps=0
    for step=1,6 do
      local distance=step*0.20*scale
      if not companion.walkable(bot,{x=pos.x+v[1]*distance,y=pos.y+v[2]*distance}) then break end
      steps=step
    end
    if steps>=2 then
      job.escape={direction=d*2,until_tick=game.tick+math.min(10,steps+1)}
      break
    end
  end
  job.path,job.path_id,job.no_path,job.last_walk=nil,nil,nil,nil
  job.alternate_walk=nil
  job.tried_fine_path=nil
  companion.stop(bot)
end

local function approach(bot, job, goal, reach)
  -- Mining batches change targets. Never follow the previous target's path.
  if job.walk_goal and companion.distance(job.walk_goal,goal)>0.1 then
    job.path,job.path_id,job.no_path,job.last_walk=nil,nil,nil,nil
    job.alternate_walk,job.repaths,job.escape=nil,0,nil
    job.tried_fine_path=nil
    companion.stop(bot)
  end
  job.walk_goal={x=goal.x,y=goal.y}
  if job.escape then
    if game.tick<job.escape.until_tick then
      bot.walking_state={walking=true,direction=job.escape.direction}
      return false
    end
    job.escape=nil
    companion.stop(bot)
  end
  if companion.distance(bot.position, goal) <= reach then
    job.path, job.path_id, job.no_path, job.last_walk = nil, nil, nil, nil
    job.alternate_walk = nil
    companion.stop(bot)
    return true
  end
  if job.path_id and game.tick - job.path_tick < 300 then
    job.path_wait_ticks = (job.path_wait_ticks or 0) + 1
    return false
  end
  if job.no_path then
    -- Coarse waypoints can miss the clearance beside a pole in a mining aisle.
    if not job.tried_fine_path then
      job.tried_fine_path=true
      job.no_path=nil
      path_request(bot,job,goal,math.max(0,reach-0.2),true)
      return false
    end
    local directions = {{1,0},{-1,0},{0,1},{0,-1},{0.707,0.707},{-0.707,0.707},{0.707,-0.707},{-0.707,-0.707}}
    local found
    if reach>1 then
      for i=(job.alternate_walk or 0)+1,#directions do
        local v=directions[i]
        local p={x=goal.x+v[1]*(reach-0.35),y=goal.y+v[2]*(reach-0.35)}
        if companion.walkable(bot,p) then
          job.alternate_walk=i
          job.no_path=nil
          path_request(bot,job,p,0.25)
          found=true
          break
        end
      end
    end
    if not found then
      if (job.repaths or 0)>=3 then error("No walkable path to target") end
      recover(bot,job)
    end
    return false
  end
  if not job.path then
    path_request(bot, job, goal, math.max(0, reach - 0.2))
    return false
  end
  local waypoint = job.path[job.waypoint]
  local waypoint_reach=job.fine_path and 0.10 or 0.16
  while waypoint and companion.distance(bot.position, waypoint.position) <= waypoint_reach do
    job.waypoint = job.waypoint + 1
    waypoint = job.path[job.waypoint]
  end
  if not waypoint or (job.last_walk and game.tick - job.last_walk.tick > 45) then
    recover(bot,job)
    return false
  end
  if not job.last_walk or companion.distance(bot.position, job.last_walk.position) > 0.5 then
    job.last_walk = {tick = game.tick, position = bot.position}
  end
  local pos = bot.position
  local angle = math.atan2(waypoint.position.x - pos.x, pos.y - waypoint.position.y)
  local direction = (math.floor(angle / (math.pi / 4) + 0.5) % 8) * 2
  if not job.density_tick or game.tick>=job.density_tick then
    job.density_tick=game.tick+8
    job.in_corridor=bot.surface.count_entities_filtered{
      position=pos,radius=3.2,type={"furnace","mining-drill","assembling-machine","container","boiler","generator","tree"},
      limit=2
    }>=2
    job.by_water=bot.surface.count_tiles_filtered{position=pos,radius=1.5,collision_mask="water_tile",limit=1}>0
  end
  if (job.in_corridor or job.by_water) and direction%4~=0 then
    local dx,dy=waypoint.position.x-pos.x,waypoint.position.y-pos.y
    local horizontal,vertical=dx>=0 and 4 or 12,dy>=0 and 8 or 0
    local options=math.abs(dx)>=math.abs(dy) and {horizontal,vertical} or {vertical,horizontal}
    local found
    for _, axis in ipairs(options) do
      local v=offsets[axis/2+1]
      local along=axis%8==4 and math.abs(dx) or math.abs(dy)
      if along>=0.10 and companion.walkable(bot,{x=pos.x+v[1]*0.18,y=pos.y+v[2]*0.18}) then
        direction=axis; found=true; break
      end
    end
    if not found then recover(bot,job); return false end
  end
  job.walk_direction=direction
  bot.walking_state = {walking = true, direction = direction}
  return false
end

function companion.approach(bot, job, goal, reach)
  local arrived = approach(bot, job, goal, reach)
  if not arrived then job.travel_ticks = (job.travel_ticks or 0) + 1 end
  return arrived
end

function companion.track()
  if game.tick%30~=0 then return end
  local bot=storage.bot
  local tag=storage.bot_tag
  if not bot or not bot.valid then
    if tag and tag.valid then tag.destroy() end
    return
  end
  if not storage.bot_label or not storage.bot_label.valid then
    rendering.clear("codex-companion")
    draw_label(bot)
  end
  local p=bot.position
  local chunk={math.floor(p.x/32),math.floor(p.y/32)}
  if bot.force.is_chunk_charted(bot.surface,chunk) then
    if tag and tag.valid and tag.surface==bot.surface then tag.position=p; tag.text=companion.name
    else
      if tag and tag.valid then tag.destroy() end
      storage.bot_tag=bot.force.add_chart_tag(bot.surface,{position=p,text=companion.name,icon=map_icon})
    end
  end
  storage.bot_pins=storage.bot_pins or {}
  for _, player in pairs(game.connected_players) do
    local old=storage.bot_pins[player.index]
    if player.force==bot.force and (not old or not old.pin.valid or old.bot~=bot or old.name~=companion.name) then
      if old and old.pin.valid then old.pin.destroy() end
      local pin=player.add_pin{entity=bot,label=companion.name}
      if pin then storage.bot_pins[player.index]={pin=pin,bot=bot,name=companion.name} end
    end
  end
end

function companion.inspect(args)
  local bot = companion.character()
  local player = args.player and game.get_player(args.player)
  local pos = args.x and companion.position(args) or bot.position
  local radius = args.radius or 24
  assert(radius > 0 and radius <= 96, "Radius must be between 1 and 96")
  local items = {}
  for _, item in ipairs(bot.get_main_inventory().get_contents()) do
    items[#items+1] = {name = item.name, quality = item.quality, count = item.count}
  end
  local entities = {}
  local filter = {name = args.name, type = args.type}
  if not args.name and not args.type then filter.type = {"resource", "tree", "character",
    "assembling-machine", "furnace", "container", "mining-drill", "lab", "rocket-silo", "entity-ghost"} end
  local limit = args.limit or 35
  for _, e in ipairs(companion.nearby(bot, pos, radius, filter)) do
    local chunk = {math.floor(e.position.x / 32), math.floor(e.position.y / 32)}
    if bot.force.is_chunk_charted(bot.surface, chunk) or companion.distance(bot.position, e.position) <= 32 then
      entities[#entities+1] = {name = e.name, type = e.type, position = e.position,
        force = e.force.name, amount = e.type == "resource" and e.amount or nil,
        ghost = e.type == "entity-ghost" and e.ghost_name or nil}
      if #entities >= limit then break end
    end
  end
  return {tick = game.tick, surface = bot.surface.name, position = bot.position, health = bot.health,
    player_position = player and player.surface == bot.surface and player.position or nil,
    inventory = items, nearby = entities, active_job = storage.active, queued = #storage.queue,
    research = bot.force.current_research and bot.force.current_research.name,
    research_progress = bot.force.research_progress}
end

return companion

