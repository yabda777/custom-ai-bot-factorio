local companion = require("character")
local blueprints = {}

local function entries(stack, path, result, depth)
  assert(depth <= 16, "Blueprint book nesting exceeds 16 levels")
  if stack.is_blueprint and stack.is_blueprint_setup() then
    result[#result+1] = {path = path, label = stack.label or "",
      entities = stack.get_blueprint_entity_count(), tiles = #(stack.get_blueprint_tiles() or {})}
    assert(#result <= 4096, "Book contains too many blueprints")
  elseif stack.is_blueprint_book then
    local inv = stack.get_inventory(defines.inventory.item_main)
    for index = 1, #inv do
      local slot = inv[index]
      if slot.valid_for_read then
        entries(slot, path == "" and tostring(index) or path .. "/" .. index, result, depth + 1)
      end
    end
  end
end

function blueprints.import(args)
  assert(type(args.exchange) == "string" and #args.exchange <= 2000000 and
    args.exchange:match("^0[A-Za-z0-9+/=]+$"), "Invalid blueprint exchange string")
  assert(type(args.book) == "string" and #args.book > 0 and #args.book <= 80, "Invalid book name")
  assert(storage.books[args.book] or table_size(storage.books) < 24, "Book limit reached")
  local inv = game.create_inventory(1)
  local ok, result = pcall(function()
    local code = inv[1].import_stack(args.exchange)
    assert(code == 0, "Factorio rejected the blueprint or found missing prototypes (code " .. code .. ")")
    local catalog = {}
    entries(inv[1], "", catalog, 0)
    assert(#catalog > 0, "No usable blueprints in this import")
    return catalog
  end)
  if not ok then inv.destroy(); error(result) end
  local previous = storage.books[args.book]
  storage.books[args.book] = {inventory = inv, catalog = result}
  if previous then previous.inventory.destroy() end
  return {book = args.book, blueprints = #result}
end

function blueprints.list(args)
  local books = {}
  if not args.book then
    for name, book in pairs(storage.books) do books[#books+1] = {book = name, blueprints = #book.catalog} end
    return {books = books}
  end
  local book = assert(storage.books[args.book], "Unknown book")
  local offset = args.offset or 0
  local page = {}
  for i = offset + 1, math.min(offset + 30, #book.catalog) do page[#page+1] = book.catalog[i] end
  return {book = args.book, total = #book.catalog, offset = offset, entries = page}
end

function blueprints.get(args)
  local book = assert(storage.books[args.book], "Unknown book")
  local stack = book.inventory[1]
  local path = args.path or ""
  assert(path == "" or (path:match("^%d[%d/]*$") and not path:find("//", 1, true)
    and not path:match("/$")), "Invalid blueprint path")
  for token in path:gmatch("%d+") do
    assert(stack.valid_for_read and stack.is_blueprint_book, "Invalid blueprint path")
    local inv = stack.get_inventory(defines.inventory.item_main)
    local index = tonumber(token)
    assert(index >= 1 and index <= #inv, "Invalid slot in blueprint path")
    stack = inv[index]
  end
  assert(stack.valid_for_read and stack.is_blueprint and stack.is_blueprint_setup(), "Select a blueprint path")
  return stack
end

local function placement_items(prototype)
  local items = prototype.items_to_place_this or {}
  local result = {}
  for _, item in ipairs(items) do result[#result+1] = {name = item.name, count = item.count} end
  return result
end

local function cost(inv, prototype, quality)
  for _, item in ipairs(placement_items(prototype)) do
    local stack = {name = item.name, count = item.count, quality = quality}
    if inv.get_item_count(stack) >= stack.count then return stack end
  end
  error("Missing placement item for " .. prototype.name .. " (" .. quality .. ")")
end

function blueprints.describe(args)
  local bp = blueprints.get(args)
  local counts = {}
  local function add(proto, quality)
    local key = proto.name .. ":" .. quality
    if not counts[key] then
      counts[key] = {name = proto.name, quality = quality, count = 0, placement_options = placement_items(proto)}
    end
    counts[key].count = counts[key].count + 1
  end
  local entities = bp.get_blueprint_entities() or {}
  local tiles = bp.get_blueprint_tiles() or {}
  for _, entry in ipairs(entities) do add(prototypes.entity[entry.name], entry.quality or "normal") end
  for _, entry in ipairs(tiles) do add(prototypes.tile[entry.name], "normal") end
  local result = {}
  for _, count in pairs(counts) do result[#result+1] = count end
  local offset = args.offset or 0
  local page = {}
  for i = offset + 1, math.min(offset + 30, #result) do page[#page+1] = result[i] end
  return {label = bp.label or "", entities = #entities, tiles = #tiles,
    total_types = #result, offset = offset, requirements = page}
end

function blueprints.build(bot, job)
  local args = job.args
  local pos = companion.position(args)
  local proto = assert(prototypes.entity[args.name], "Unknown entity prototype")
  local inv = bot.get_main_inventory()
  local quality = args.quality or "normal"
  local placement = {name = args.name, position = pos, direction = args.direction or 0,
    force = bot.force, quality = quality, build_check_type = defines.build_check_type.manual}
  if args.type then placement.type=args.type end
  if job.build_stand then
    if not companion.approach(bot, job, job.build_stand, 0.45) then return end
  elseif not companion.approach(bot, job, pos,math.max(1,bot.build_distance-0.3)) then
    return
  end
  if not bot.surface.can_place_entity(placement) then
    local box=proto.collision_box
    local width=math.max(math.abs(box.left_top.x),math.abs(box.right_bottom.x))
    local height=math.max(math.abs(box.left_top.y),math.abs(box.right_bottom.y))
    if placement.direction%8==4 then width,height=height,width end
    local area={{pos.x-width,pos.y-height},{pos.x+width,pos.y+height}}
    for _, blocker in ipairs(bot.surface.find_entities_filtered{area=area,type={"character","unit","car","spider-vehicle"}}) do
      if blocker~=bot then
        if not job.obstruction_tick then
          job.obstruction_tick=game.tick
          game.print("["..companion.name.."] Отойди, мешаешь работать ("..pos.x..", "..pos.y..").")
        end
        assert(game.tick-job.obstruction_tick<900,"Building site still blocked after 15 seconds")
        companion.stop(bot)
        return
      end
    end
    if not job.build_stand then
      local stands = {{3.3,0},{-3.3,0},{0,3.3},{0,-3.3},{2.4,2.4},{-2.4,2.4},{2.4,-2.4},{-2.4,-2.4}}
      local best, score
      for _, offset in ipairs(stands) do
        local p = {x=pos.x+offset[1],y=pos.y+offset[2]}
        local d = companion.distance(bot.position,p)
        if (not score or d<score) and bot.surface.can_place_entity{name="character",position=p,force=bot.force} then
          best,score=p,d
        end
      end
      if best then job.build_stand=best; return end
    end
    error("Cannot place entity here")
  end
  local stack = cost(inv, proto, quality)
  placement.raise_built = true
  local entity
  for _, ghost in ipairs(bot.surface.find_entities_filtered{type='entity-ghost',ghost_name=args.name,position=pos,radius=0.05,force=bot.force}) do
    local _,revived=ghost.revive{raise_revive=true,overflow=inv}
    entity=revived
    break
  end
  entity=entity or bot.surface.create_entity(placement)
  assert(entity and entity.valid, "Game refused to place entity")
  if args.output_priority and entity.type=='splitter' then entity.splitter_output_priority=args.output_priority end
  inv.remove(stack)
  job.progress = 1
  return true
end

local function stage(bot, job, pos)
  local args = job.args
  local bp = blueprints.get(args)
  local expected = bp.get_blueprint_entity_count() + #(bp.get_blueprint_tiles() or {})
  assert(expected > 0 and expected <= 500, "Blueprint must have 1 to 500 placements")
  local ghosts = bp.build_blueprint{surface = bot.surface, force = bot.force, position = pos,
    direction = args.direction or 0, build_mode = defines.build_mode.normal, skip_fog_of_war = false}
  job.targets = {}
  for _, ghost in ipairs(ghosts) do
    if ghost.valid and (ghost.type == "entity-ghost" or ghost.type == "tile-ghost") then
      job.targets[#job.targets+1] = {ghost = ghost, name = ghost.ghost_name,
        quality = ghost.type == "tile-ghost" and "normal" or ghost.quality.name,
        position = ghost.position, tile = ghost.type == "tile-ghost",
        direction = ghost.direction}
    end
  end
  -- Place terrain first so subsequent buildings can use it.
  table.sort(job.targets, function(a, b) return a.tile and not b.tile end)
  job.item_requests = 0
  job.expected = expected
  job.staged = #job.targets
  job.index = 1
  job.progress = 0
end

function blueprints.place(bot, job)
  if not job.targets then
    local pos = companion.position(job.args)
    if not companion.approach(bot, job, pos, 3) then return end
    stage(bot, job, pos)
  end
  local target = job.targets[job.index]
  if not target then
    assert(job.progress == job.expected, "Blueprint only partially placed. Some positions were obstructed, already built or outside visibility")
    if job.item_requests > 0 then
      job.detail = "All placements built. " .. job.item_requests .. " item request proxies remain for modules or other contents."
    end
    return true
  end
  local ghost = target.ghost
  if not ghost.valid then
    if target.tile then
      assert(bot.surface.get_tile(target.position).name == target.name, "Tile ghost disappeared")
    else
      local found = bot.surface.find_entities_filtered{name = target.name, position = target.position, radius = 0.1,
        force = bot.force, quality = target.quality}
      local matches = false
      for _, entity in ipairs(found) do matches = matches or entity.direction == target.direction end
      assert(matches, "Entity ghost disappeared")
    end
  else
    if not companion.approach(bot, job, target.position, 3.5) then return end
    local inv = bot.get_main_inventory()
    local proto = target.tile and prototypes.tile[target.name] or prototypes.entity[target.name]
    local stack = cost(inv, proto, target.quality)
    local revived, entity, proxy = ghost.revive{raise_revive = true, overflow = inv}
    assert(revived ~= nil and (target.tile or (entity and entity.valid)), "Ghost obstructed at " ..
      target.position.x .. ", " .. target.position.y)
    inv.remove(stack)
    if proxy and proxy.valid then job.item_requests = job.item_requests + 1 end
  end
  job.progress = job.progress + 1
  job.index = job.index + 1
  job.repaths = 0
  return false
end

return blueprints


