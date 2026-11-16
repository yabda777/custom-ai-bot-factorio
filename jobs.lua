local companion = require("character")
local blueprints = require("blueprints")
local journal = require('action_journal')
local jobs = {}

local function count(args)
  local value = args.count or 1
  assert(value >= 1 and value <= 1000 and value == math.floor(value), "Count must be 1вЂ“1000")
  return value
end

local function mine(bot, job)
  local args = job.args
  local inv = bot.get_main_inventory()
  local product = args.item or args.name
  local available = inv.get_item_count(product)
  job.progress = (job.progress or 0) + math.max(0, available - (job.last_item_count or available))
  job.last_item_count = available
  job.expected = count(args)
  if job.progress >= job.expected then return true end
  assert(inv.can_insert{name = product, count = 1}, "Companion inventory is full")
  local target = job.target
  if not target or not target.valid then
    job.mining_since = nil
    local center = args.x and companion.position(args) or bot.position
    if args.exact and job.target==nil then
      target = bot.surface.find_entity(args.name, center)
      assert(target and target.valid and target.force.name == "neutral" and target.minable,
        "Mining target disappeared")
      job.target = target
    end
    if not target then
    for _, entity in ipairs(companion.nearby(bot, center, args.radius or 32,
      {name = args.rock_names or args.name, type = {"resource", "tree", "simple-entity"}})) do
      local props = entity.prototype.mineable_properties
      local key=entity.position.x..":"..entity.position.y
      if not (job.skipped_rocks and job.skipped_rocks[key]) and
        entity.minable and not props.required_fluid and entity.force.name == "neutral" then
        for _, output in ipairs(props.products or {}) do
          if output.type == "item" and output.name == product then target = entity; break end
        end
        if target and target.valid then break end
      end
    end
    end
    if args.rock_names and job.progress>0 and (not target or not target.valid) then return true end
    assert(target and target.valid, "No nearby mineable source for " .. product)
    job.target = target
    job.repaths = 0
  end
  if not companion.approach(bot, job, target.position, 2.4) then return end
  local before = job.last_progress
  if before ~= job.progress or not job.mining_since then
    job.last_progress, job.mining_since = job.progress, game.tick
  end
  if args.rock_names and game.tick-job.mining_since>=600 then
    job.skipped_rocks=job.skipped_rocks or {}
    job.skipped_rocks[target.position.x..":"..target.position.y]=true
    job.target=false
    companion.stop(bot)
    return
  end
  assert(game.tick - job.mining_since < 3600, "Mining made no progress")
  bot.selected = target
  bot.mining_state = {mining = true, position = target.position}
end

local function craft(bot, job)
  local recipe = job.args.name
  if not job.started_craft then
    if bot.crafting_queue_size > 0 then return false end
    job.expected = count(job.args)
    assert(bot.get_craftable_count(recipe) >= job.expected, "Recipe is unavailable or ingredients are missing")
    local started = journal.craft(bot,{recipe = recipe, count = job.expected, silent = true})
    job.started_craft = true
    assert(started == job.expected, "Only " .. started .. " crafts accepted")
  end
  local remaining = 0
  for _, entry in ipairs(bot.crafting_queue or {}) do
    if entry.recipe == recipe then remaining = remaining + entry.count end
  end
  job.progress = job.expected - remaining
  return (bot.crafting_queue_size or 0) == 0
end

function jobs.input_inventory(entity)
  return entity.get_inventory(defines.inventory.crafter_input)
end

local inventory_access = {
  chest = function(entity)
    assert(entity.type == "container" or entity.type == "logistic-container",
      "Select a container or choose fuel, input or output")
    return entity.get_inventory(defines.inventory.chest)
  end,
  fuel = function(entity) return entity.get_fuel_inventory() end,
  input = jobs.input_inventory,
  output = function(entity) return entity.get_output_inventory() end,
  lab = function(entity)
    assert(entity.type == "lab", "Select a lab")
    return entity.get_inventory(defines.inventory.lab_input)
  end,
  ammo = function(entity)
    assert(entity.type == "ammo-turret", "Select an ammo turret")
    return entity.get_inventory(defines.inventory.turret_ammo)
  end
}

local function find_machine(bot, args, pos)
  local found
  for _, entity in ipairs(bot.surface.find_entities_filtered{
    position = pos, radius = 0.15, name = args.entity, force = bot.force
  }) do
    if entity.type ~= "entity-ghost" and entity.type ~= "character" then
      assert(not found, "Multiple targets. Specify the entity prototype")
      found = entity
    end
  end
  return assert(found, "No matching friendly entity at those coordinates")
end

function jobs.inspect_machine(args)
  local bot = companion.character()
  local pos = companion.position(args)
  assert(companion.distance(bot.position, pos) <= 32, "Machine is too far from the companion")
  local machine = find_machine(bot, args, pos)
  local contents = {}
  local access = assert(inventory_access[args.inventory or "chest"], "Unknown inventory")
  local inv = assert(access(machine), "Machine does not have that inventory")
  for _, item in ipairs(inv.get_contents()) do
    contents[#contents+1] = {name = item.name, quality = item.quality, count = item.count}
  end
  return {entity = machine.name, position = machine.position, inventory = contents}
end

function jobs.inspect_recipe(args)
  local bot = companion.character()
  local recipe = assert(bot.force.recipes[args.name], "Unknown recipe")
  return {name = recipe.name, enabled = recipe.enabled,
    seconds = recipe.energy, ingredients = recipe.ingredients, products = recipe.products,
    hand_craftable_now = bot.get_craftable_count(recipe.name)}
end

local function transfer(bot, job)
  local args = job.args
  local pos = companion.position(args)
  local machine
  if args.wreck then
    assert(args.mode=="take" and args.name=="iron-plate" and
      (args.entity:match("^crash%-site%-spaceship%-wreck%-") or args.entity:match("^crash%-site%-chest%-")), "Invalid wreck salvage")
    machine=assert(bot.surface.find_entity(args.entity,pos),"Wreck is gone")
    if not bot.can_reach_entity(machine) and not companion.approach(bot,job,pos,5) then return end
    if not bot.can_reach_entity(machine) and not companion.approach(bot,job,pos,2.8) then return end
    assert(bot.can_reach_entity(machine),"Wreck out of reach")
  else
    machine=find_machine(bot,args,pos)
    if not bot.can_reach_entity(machine) and
      not companion.approach(bot,job,pos,math.max(1,bot.reach_distance-0.3)) then return end
    assert(bot.can_reach_entity(machine),"Machine out of reach")
    companion.stop(bot)
  end
  local inventory = assert(inventory_access[args.inventory or "chest"], "Unknown inventory")(machine)
  assert(inventory, "Machine does not have that inventory")
  local source, destination = bot.get_main_inventory(), inventory
  if args.mode == "take" then source, destination = destination, source end
  job.expected = count(args)
  job.progress = job.progress or 0
  local quality = args.quality or "normal"
  if args.take_output then
    assert(args.mode=="take" and args.inventory=="output", "Expected a pickup from output")
    local filter={name=args.name,quality=quality}
    job.expected=math.min(source.get_item_count(filter),destination.get_insertable_count(filter))
    if job.expected==0 then return true end
  end
  if args.keep_count then
    assert(args.mode=="take" and args.inventory=="chest", "Chest reserve applies only to a pickup")
    local filter={name=args.name,quality=quality}
    job.expected=math.min(job.expected,math.max(0,source.get_item_count(filter)-args.keep_count),
      destination.get_insertable_count(filter))
    if job.expected==0 then return true end
  end
  if args.keep_coal then
    assert(machine.name=="burner-mining-drill" and args.mode=="take" and args.inventory=="fuel" and args.name=="coal",
      "Coal reserve applies only to burner drills")
    job.expected=math.max(0,source.get_item_count{name="coal",quality=quality}-1)
    if job.expected==0 then return true end
  end
  for i = 1, #source do
    local slot = source[i]
    if slot.valid_for_read and slot.name == args.name and slot.quality.name == quality then
      -- Preserve item metadata, e.g. partially used magazines or spoilage.
      local stack = slot
      local temporary
      local needed = job.expected - job.progress
      if needed < slot.count then
        temporary = game.create_inventory(1)
        temporary[1].set_stack(slot)
        temporary[1].count = needed
        stack = temporary[1]
      end
      local inserted = destination.insert(stack)
      if temporary then temporary.destroy() end
      if inserted > 0 then
        if inserted == slot.count then slot.clear() else slot.count = slot.count - inserted end
        job.progress = job.progress + inserted
        if job.progress == job.expected then return true end
      end
    end
  end
  error("Transfer incomplete: item supply or destination capacity exhausted")
end

local function recipe(bot, job)
  local args = job.args
  local pos = companion.position(args)
  local entity = find_machine(bot, args, pos)
  if not bot.can_reach_entity(entity) and
    not companion.approach(bot,job,pos,math.max(1,bot.reach_distance-0.3)) then return end
  assert(bot.can_reach_entity(entity),"Machine out of reach")
  companion.stop(bot)
  assert(entity.type == "assembling-machine", "Select an assembling machine")
  local selected = assert(bot.force.recipes[args.name], "Unknown recipe")
  assert(selected.enabled and not selected.hidden, "Recipe is locked or hidden")
  local current = entity.get_recipe()
  if current and current.name == selected.name then return true end
  assert(not current, "Machine already has a recipe")
  local returned = entity.set_recipe(selected, args.quality or "normal")
  local inv = bot.get_main_inventory()
  for _, item in ipairs(returned) do
    local stack = {name = item.name, quality = item.quality, count = item.count}
    stack.count = stack.count - inv.insert(stack)
    if stack.count > 0 then
      bot.surface.spill_item_stack{position = bot.position, stack = stack, enable_looted = true, force = bot.force}
    end
  end
  current = entity.get_recipe()
  assert(current and current.name == selected.name, "Machine cannot run this recipe")
  return true
end

local function research(bot, job)
  local tech = assert(bot.force.technologies[job.args.name], "Unknown technology")
  if tech.researched then return true end
  assert(bot.force.add_research(tech), "Technology cannot be added to the research queue")
  job.detail = "Added to force research queue. Labs must produce the research normally."
  return true
end

local function orient(bot,job)
  local p=companion.position(job.args)
  local entity=find_machine(bot,{entity=job.args.name},p)
  if not bot.can_reach_entity(entity) and
    not companion.approach(bot,job,p,math.max(1,bot.reach_distance-0.3)) then return end
  assert(bot.can_reach_entity(entity),"Machine out of reach")
  companion.stop(bot)
  entity.direction=job.args.direction
  return true
end

local handlers = {
  recover=require('campaign_jobs').recover,
  configure=require('campaign_jobs').configure,
  wire=require('campaign_jobs').wire,
  belt_take=require('campaign_jobs').belt_take,
  blueprint_gift=require('campaign_jobs').blueprint_gift,
  orient=orient,
  move = function(bot, job) return companion.approach(bot, job, companion.position(job.args), 0.65) end,
  mine = mine, craft = craft, build = blueprints.build, blueprint = blueprints.place,
  transfer = transfer, recipe = recipe, research = research
}

local function summary(job)
  return {id = job.id, kind = job.kind, status = job.status, progress = job.progress,
    expected = job.expected, staged = job.staged, detail = job.detail, created_tick = job.created_tick,
    updated_tick = job.updated_tick, attempts = job.attempts, args = job.args,
    started_tick = job.started_tick, path_requests = job.path_requests or 0,
    repaths = job.total_repaths or 0,
    path_wait_seconds = math.floor((job.path_wait_ticks or 0) / 6 + 0.5) / 10,
    travel_seconds = math.floor((job.travel_ticks or 0) / 6 + 0.5) / 10}
end

function jobs.enqueue(args)
  companion.character()
  assert(handlers[args.kind], "Unknown task")
  if args.request_id then
    for _, existing in pairs(storage.jobs) do
      if existing.request_id == args.request_id then return summary(existing) end
    end
  end
  assert(#storage.queue < 64, "Queue full")
  local id = storage.next_id
  storage.next_id = id + 1
  local job = {id = id, kind = args.kind, args = args.args or {}, status = "queued",
    created_tick = game.tick, updated_tick = game.tick, request_id = args.request_id, automatic = args.automatic, attempts = 0}
  storage.jobs[id] = job
  if args.automatic then storage.queue[#storage.queue+1] = id
  else
    local index = #storage.queue + 1
    for i, queued in ipairs(storage.queue) do
      if storage.jobs[queued].automatic then index = i; break end
    end
    table.insert(storage.queue, index, id)
    local active=storage.active and storage.jobs[storage.active]
    if active and active.automatic then jobs.cancel{id=active.id} end
  end
  for old = storage.prune_from or 1, id - 500 do
    local candidate = storage.jobs[old]
    if candidate and (candidate.status == "queued" or candidate.status == "running") then
      storage.prune_from = old
      return summary(job)
    end
    storage.jobs[old] = nil
    storage.prune_from = old + 1
  end
  return summary(job)
end

function jobs.status(args)
  if args.id then return summary(assert(storage.jobs[args.id], "Unknown task")) end
  local result = {}
  for id = storage.next_id - 1, math.max(1, storage.next_id - 21), -1 do
    if storage.jobs[id] then result[#result+1] = summary(storage.jobs[id]) end
  end
  return {tick = game.tick, active = storage.active, queued = storage.queue, recent = result}
end

local function finish(job, status, detail)
  job.status, job.detail, job.updated_tick = status, detail, game.tick
  storage.active = nil
  job.path, job.path_id, job.no_path, job.last_walk, job.repaths = nil, nil, nil, nil, nil
  local bot = storage.bot
  journal.track(bot, job)
  journal.record{event='job_finished', job=summary(job), distance_tiles=job.distance_tiles,
    start_position=job.journal_start, end_position=job.journal_position, position_jumps=job.position_jumps}
  if bot and bot.valid then
    companion.stop(bot)
    if job.kind == "craft" and status ~= "done" and job.started_craft then
      local queue = bot.crafting_queue or {}
      for i = #queue, 1, -1 do bot.cancel_crafting{index = i, count = queue[i].count} end
    end
  end
end

function jobs.cancel(args)
  local job = assert(storage.jobs[args.id], "Unknown task")
  if job.status == "running" then
    finish(job, "cancelled", "Stopped. Completed work and blueprint ghosts remain.")
  elseif job.status == "queued" then
    for i, id in ipairs(storage.queue) do
      if id == job.id then table.remove(storage.queue, i); break end
    end
    job.status, job.updated_tick = "cancelled", game.tick
  end
  return summary(job)
end

function jobs.retry(args)
  local job = assert(storage.jobs[args.id], "Unknown task")
  assert(job.status == "failed", "Only failed jobs can be retried")
  assert(#storage.queue < 64, "Queue full")
  if job.kind == "craft" then
    job.args.count = (job.expected or count(job.args)) - (job.progress or 0)
    job.started_craft = nil
  end
  job.mining_since, job.target, job.last_item_count = nil, nil, nil
  job.status, job.updated_tick, job.detail = "queued", game.tick, nil
  storage.queue[#storage.queue+1] = job.id
  return summary(job)
end

function jobs.tick()
  if not storage.active then
    if #storage.queue == 0 then return end
    storage.active = table.remove(storage.queue, 1)
    local job = storage.jobs[storage.active]
    job.status, job.started_tick, job.attempts = "running", game.tick, job.attempts + 1
    job.updated_tick = game.tick
    job.journal_position, job.journal_start, job.position_jumps, job.distance_tiles = nil, nil, nil, nil
    journal.record{event='job_started', id=job.id, kind=job.kind, args=job.args, attempt=job.attempts}
  end
  local job = storage.jobs[storage.active]
  journal.track(storage.bot, job)
  local ok, result = pcall(function()
    assert(game.tick - job.started_tick < 36000, "Task reached its 10-minute time limit")
    return handlers[job.kind](companion.character(), job)
  end)
  if not ok then finish(job, "failed", tostring(result):gsub("^.-:%d+: ", ""))
  elseif result then finish(job, "done", job.detail)
  else job.updated_tick = game.tick end
end

return jobs



