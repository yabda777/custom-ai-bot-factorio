local jobs = require("jobs")
local companion = require("character")
local layout = require("starter_layout")
local telemetry = require("starter_telemetry")
local blueprint = require("starter_blueprint")

local starter = {}
local journal = require('action_journal')
local labels = {"Первый железный бур","Пять железных пар","Угольная змея",
  "Расширение железа","Медная плавка","Вторая очередь железа","Пар и автоматизация","Блок It Begins"}
local large_rocks = {"huge-rock","big-rock","big-sand-rock"}
local raw = {["iron-ore"]=true, ["copper-ore"]=true, coal=true, stone=true}
local metals = {["iron-plate"]="iron-ore", ["copper-plate"]="copper-ore"}
local planning_interval = 6
local target_ticks = 15 * 60 * 60

local function inv(bot)
  return bot.get_main_inventory()
end

local function have(bot,item)
  return inv(bot).get_item_count(item)
end

local function stock(entity, access, item)
  local inventory = access(entity)
  if not inventory then return 0 end
  return item and inventory.get_item_count(item) or inventory.get_item_count()
end

local function fuel(e) return e.get_fuel_inventory() end
local input = jobs.input_inventory
local function output(e) return e.get_output_inventory() end
local function chest(e) return e.get_inventory(defines.inventory.chest) end
local function lab(e) return e.get_inventory(defines.inventory.lab_input) end

local function task(s,kind,args,label,key)
  if s.job then return true end
  s.job = jobs.enqueue{kind=kind,args=args,automatic=true}.id
  s.action, s.key = label, key
  return true
end

local function transfer(s,e,slot,mode,item,amount)
  if amount < 1 then return false end
  local p = e.position
  local key = "transfer:"..e.unit_number
  if s.avoid[key] and s.avoid[key] > game.tick then return false end
  return task(s,"transfer",{x=p.x,y=p.y,entity=e.name,inventory=slot,mode=mode,name=item,count=amount},
    (mode=="take" and "Забираю " or "Загружаю ")..item.." ×"..amount,key)
end

local function nearby(bot,s,filter)
  filter.position,filter.radius = s.home,180
  local result = bot.surface.find_entities_filtered(filter)
  table.sort(result,function(a,b)
    return companion.distance(a.position,bot.position)<companion.distance(b.position,bot.position)
  end)
  return result
end

local function blocked_mine(s,key)
  local until_tick=s.avoid[key]
  return until_tick and (until_tick==true or until_tick>game.tick)
end

local function mine(bot,s,item,n)
  if item=="stone" or item=="coal" or item=="wood" then
    local names
    if item~="wood" then names=large_rocks end
    local candidates=nearby(bot,s,{name=names,type=item=="wood" and "tree" or "simple-entity"})
    if item=="stone" and have(bot,"coal")<4 then
      local function rank(entity)
        return companion.distance(bot.position,entity.position)-(entity.name=="huge-rock" and 12 or 0)
      end
      table.sort(candidates,function(a,b) return rank(a)<rank(b) end)
    end
    for _, entity in ipairs(candidates) do
      local p = entity.position
      local key = "mine:"..p.x..":"..p.y
      if (not blocked_mine(s,key)) and (item~="coal" or entity.name=="huge-rock") and
        (item=="wood" or item=="stone" or entity.name=="huge-rock") then
        local batch=item=="stone"
        return task(s,"mine",{x=p.x,y=p.y,exact=true,name=entity.name,item=item,
          count=batch and math.max(65,n) or 1,rock_names=batch and large_rocks or nil,radius=batch and 24 or nil},
          "Добываю "..item.." ("..entity.name..")",key)
      end
    end
  end
  if not raw[item] then s.action="Не вижу доступных деревьев"; return false end
  for _, entity in ipairs(nearby(bot,s,{name=item,type="resource"})) do
    local p = entity.position
    local key = "ore:"..math.floor(p.x/16)..":"..math.floor(p.y/16)
    if not blocked_mine(s,key) then
      return task(s,"mine",{x=p.x,y=p.y,exact=true,radius=10,name=item,count=math.min(32,n)},
        "Добываю "..item,key)
    end
  end
  s.action = "Не вижу доступной залежи: "..item
  return false
end

local function craft(bot,s,item,n)
  local recipe = bot.force.recipes[item]
  if not recipe or not recipe.enabled then s.action = "Рецепт закрыт: "..item; return false end
  if bot.crafting_queue_size > 0 then return false end
  local per = 1
  for _, product in ipairs(recipe.products) do
    if product.name==item then per = product.amount or 1; break end
  end
  local possible = bot.get_craftable_count(item)
  if possible > 0 then
    local count = math.min(possible,math.ceil(n/per),24)
    local before=have(bot,item)
    if journal.craft(bot,{recipe=item,count=count,silent=true})>0 then
      if item=="lab" then s.lab_before=before end
      s.crafting = item
      return true
    end
  end
  return false
end

local supply

local function blocked(s,key)
  local until_tick=s.avoid[key]
  return until_tick==true or (until_tick and until_tick>game.tick)
end

local function build(bot,s,part,key)
  local p = part.position
  local existing = layout.at(bot,part.name,p)
  if existing then return false end
  if blocked(s,key) then return false end
  if have(bot,part.name)==0 then
    local count=1
    if s.stage==8 and s.factory then
      for _, pending in ipairs(s.factory.parts) do
        if pending~=part and pending.name==part.name and not layout.at(bot,pending.name,pending.position) then
          count=count+1
        end
      end
      count=math.min(count,part.name=="assembling-machine-1" and 3 or 6)
    end
    return supply(bot,s,part.name,count)
  end
  return task(s,"build",{x=p.x,y=p.y,name=part.name,direction=part.direction},
    "Строю "..part.name,key)
end

local function furnaces(bot,s,ore)
  local result, seen = {},{}
  for _, unit in ipairs(layout.units(bot,s,ore,"stone-furnace")) do
    if not seen[unit.sink.unit_number] then
      result[#result+1] = {furnace=unit.sink,drill=unit.drill}
      seen[unit.sink.unit_number] = true
    end
  end
  local f = s.manual and layout.at(bot,"stone-furnace",s.manual)
  if f and not seen[f.unit_number] then
    local current = f.get_recipe()
    if not current or current.name == (ore=="iron-ore" and "iron-plate" or "copper-plate") then
      result[#result+1] = {furnace=f}
    end
  end
  if ore=="iron-ore" and s.aux_iron then
    local aux=layout.at(bot,"stone-furnace",s.aux_iron)
    if aux and not seen[aux.unit_number] and aux~=f then result[#result+1]={furnace=aux} end
  end
  return result
end

local function harvest_coal(bot,s)
  local pending=s.coal_harvest
  if not pending then return false end
  while #pending>0 do
    local best=1
    for i=2,#pending do
      if companion.distance(bot.position,pending[i])<companion.distance(bot.position,pending[best]) then best=i end
    end
    local p=table.remove(pending,best)
    local drill=layout.at(bot,"burner-mining-drill",p)
    if drill and not blocked(s,"transfer:"..drill.unit_number) and stock(drill,fuel,"coal")>1 and inv(bot).can_insert{name="coal",count=1} then
      return task(s,"transfer",{x=p.x,y=p.y,entity=drill.name,inventory="fuel",mode="take",
        name="coal",keep_coal=true},"Собираю излишки угля","transfer:"..drill.unit_number)
    end
  end
  s.coal_harvest=nil
  return false
end

local function coal(bot,s,n)
  -- Commit to a useful cargo for the next work visit, rather than one refuel.
  if not s.fuel_trip then
    local pairs=#layout.units(bot,s,"iron-ore","stone-furnace")+#layout.units(bot,s,"copper-ore","stone-furnace")
    local reserve=s.stage==1 and 24 or math.min(100,32+pairs*3+(s.stage>=4 and 24 or 0))
    s.fuel_trip={target=math.max(have(bot,"coal")+n,reserve),minimum=have(bot,"coal")+n}
  end
  local missing=s.fuel_trip.target-have(bot,"coal")
  if missing<=0 then s.fuel_trip=nil; return false end
  if harvest_coal(bot,s) then return true end
  local working_ring=false
  for _, group in ipairs{s.coal,s.extra_coal} do
    local surplus,connected,burning=0,0,false
    local active_count=group.active_count or #group.positions
    for i,p in ipairs(group.positions) do
      local drill=layout.at(bot,"burner-mining-drill",p)
      if drill then
        local coal_count=stock(drill,fuel,"coal")
        local target=layout.drop_sink(drill,"burner-mining-drill")
        surplus=surplus+math.max(0,coal_count-1)
        if i<=active_count and layout.has_ore(bot,p,"coal") and target and
          target==layout.at(bot,"burner-mining-drill",group.positions[i%active_count+1]) then
          connected=connected+1
          burning=burning or coal_count>0 or drill.burner.remaining_burning_fuel>0
        end
      end
    end
    working_ring=working_ring or (burning and connected==active_count and
      (group.active_count~=nil or s.stage>=4 and not s.repair_coal and group~=s.pending_coal))
    if surplus>=math.min(missing,12) then
      s.coal_harvest={}
      for _, p in ipairs(group.positions) do s.coal_harvest[#s.coal_harvest+1]=p end
      if harvest_coal(bot,s) then return true end
    end
  end
  local surplus_drills={}
  for _, e in ipairs(nearby(bot,s,{name="burner-mining-drill",force=bot.force})) do
    local target=e.mining_target
    if ((target and target.valid and target.name=="coal") or layout.has_ore(bot,e.position,"coal")) and
      stock(e,fuel,"coal")>=9 and not blocked(s,"transfer:"..e.unit_number) then
      surplus_drills[#surplus_drills+1]=e.position
    end
  end
  if #surplus_drills>0 then
    s.coal_harvest=surplus_drills
    if harvest_coal(bot,s) then return true end
  end
  if working_ring and s.stage>=7 then
    -- The ring's surplus is already collected above. Once the base is built, topping
    -- the cargo up to the round quota by hand costs more than the next ring visit.
    local short=(s.fuel_trip.minimum or s.fuel_trip.target)-have(bot,"coal")
    if short<=0 then s.fuel_trip=nil; return false end
    missing=short
  end
  if working_ring then
    -- Work beside the running drills until the planned fuel cargo is ready.
    for _, resource in ipairs(nearby(bot,s,{name="coal",type="resource"})) do
      if companion.distance(bot.position,resource.position)<=16 then
        if not s.fuel_trip.counted and s.stage>=4 then
          s.coal_trips=s.coal_trips or {}
          s.coal_trips[#s.coal_trips+1]=game.tick
          s.fuel_trip.counted=true
        end
        return task(s,"mine",{x=resource.position.x,y=resource.position.y,exact=true,radius=6,
          name="coal",count=math.min(16,missing)},"Готовлю запас угля рядом со змеёй",
          "ore:"..math.floor(resource.position.x/16)..":"..math.floor(resource.position.y/16))
      end
      break
    end
  end
  local queued=mine(bot,s,"coal",math.min(24,math.max(1,missing)))
  if queued and s.stage>=4 and storage.jobs[s.job].kind=="mine" then
    s.coal_trips=s.coal_trips or {}
    while s.coal_trips[1] and game.tick-s.coal_trips[1]>10800 do table.remove(s.coal_trips,1) end
    s.coal_trips[#s.coal_trips+1]=game.tick
  end
  return queued
end

local function fuel_stock(entity)
  return stock(entity,fuel)-stock(entity,fuel,"wood")/2
end

local function available_wood(bot,s)
  return math.max(0,have(bot,"wood")-(s.stage>=4 and 2 or 0))
end

-- Once the base is built, iron piles up far beyond what the plan can use while
-- the same coal is what keeps copper running. Stop feeding iron at that point.
local function iron_surplus(bot,s)
  return s.stage>=7 and have(bot,"iron-plate")>=200
end

local function refuel(bot,s,e,target)
  local count=fuel_stock(e)
  if count>=target then return false end
  local coal_count=have(bot,"coal")
  local wood=available_wood(bot,s)
  local slot=fuel(e)
  if coal_count>0 and slot.get_insertable_count{name="coal",quality="normal"}>0 and
    (target<20 or coal_count>=12 or wood==0) then
    return transfer(s,e,"fuel","put","coal",math.min(math.ceil(target-count),coal_count))
  end
  if wood>0 and slot.get_insertable_count{name="wood",quality="normal"}>0 then
    return transfer(s,e,"fuel","put","wood",math.min(math.ceil(2*(target-count)),wood))
  end
  -- A single fuel slot may still contain the other fuel type. Let it burn first.
  if stock(e,fuel)>0 then return false end
  local trees=nearby(bot,s,{type="tree"})
  if trees[1] and companion.distance(bot.position,trees[1].position)<=15 and target<=15 then
    local coal_tiles=nearby(bot,s,{name="coal",type="resource"})
    local rocks=nearby(bot,s,{name="huge-rock",type="simple-entity"})
    local distance=math.huge
    if coal_tiles[1] then distance=companion.distance(bot.position,coal_tiles[1].position) end
    if rocks[1] then distance=math.min(distance,companion.distance(bot.position,rocks[1].position)) end
    for _, group in ipairs{s.coal,s.extra_coal} do
      for _, pos in ipairs(group.positions) do
        local drill=layout.at(bot,"burner-mining-drill",pos)
        if drill and stock(drill,fuel,"coal")>14 then distance=math.min(distance,companion.distance(bot.position,pos)) end
      end
    end
    if companion.distance(bot.position,trees[1].position)+9<distance and mine(bot,s,"wood",1) then return true end
  end
  return coal(bot,s,target>=20 and 32 or 16)
end

local function manual_furnace(bot,s)
  if s.manual and layout.at(bot,"stone-furnace",s.manual) then return false end
  if not s.manual or s.avoid.manual then
    local ore=nearby(bot,s,{name="iron-ore",type="resource"})[1]
    local center=ore and ore.position or s.home
    local p=bot.surface.find_non_colliding_position("stone-furnace",center,24,1,true)
    if not p then s.action = "Не нашёл место для первой печи"; return false end
    s.manual = {x=math.floor(p.x+0.5),y=math.floor(p.y+0.5)}
    s.avoid.manual = nil
  end
  return build(bot,s,{name="stone-furnace",position=s.manual,direction=0},"manual")
end

local function collect_plates(bot,s,furnace,item)
  local key="transfer:"..furnace.unit_number
  if blocked(s,key) or not inv(bot).can_insert{name=item,count=1} then return false end
  local p=furnace.position
  return task(s,"transfer",{x=p.x,y=p.y,entity=furnace.name,inventory="output",mode="take",
    name=item,take_output=true},"Забираю все "..item.." из печи",key)
end

-- Fast transfers along the current route. No new destination or task interruption.
local function service_in_reach(bot,s,job)
  if game.tick%30~=0 or not bot.walking_state.walking then return end
  s.visited_machines=s.visited_machines or {}
  local bag=inv(bot)
  local function move(source,destination,item,n)
    if not source or not destination then return end
    local filter={name=item,quality="normal"}
    n=math.min(n,source.get_item_count(filter),destination.get_insertable_count(filter))
    if source==bag and job and job.kind=="transfer" and job.args.mode=="put" and job.args.name==item then
      n=math.min(n,math.max(0,source.get_item_count(filter)-(job.args.count or 1)))
    end
    if n<=0 then return end
    filter.count=n
    local inserted=destination.insert(filter)
    filter.count=inserted
    source.remove(filter)
    s.route_items=(s.route_items or 0)+inserted
  end
  local resting
  if iron_surplus(bot,s) then
    resting={}
    for _, unit in ipairs(layout.units(bot,s,"iron-ore","stone-furnace")) do
      resting[unit.drill.unit_number],resting[unit.sink.unit_number]=true,true
    end
  end
  for _, e in ipairs(bot.surface.find_entities_filtered{position=bot.position,radius=math.max(1,bot.reach_distance-0.3),force=bot.force,
    name={"burner-mining-drill","stone-furnace","wooden-chest","boiler"}}) do
    local seen=s.visited_machines[e.unit_number]
    local arrival=not seen or game.tick-seen>600
    s.visited_machines[e.unit_number]=game.tick
    local on_coal=e.name=="burner-mining-drill" and layout.has_ore(bot,e.position,"coal")
    local coal_drill=on_coal and layout.drop_sink(e,"burner-mining-drill")
    if arrival then
      if e.name=="stone-furnace" then
        for _, item in ipairs{"iron-plate","copper-plate"} do move(output(e),bag,item,1000) end
      elseif coal_drill then move(fuel(e),bag,"coal",math.max(0,stock(e,fuel,"coal")-1))
      elseif e.name=="wooden-chest" then move(chest(e),bag,"stone",1000) end
    end
    if fuel(e) and fuel_stock(e)<3 and not (resting and resting[e.unit_number]) then
      local reserve=s.row and #s.row.positions*6 or 2
      local target=on_coal and 1 or e.name=="boiler" and 20 or 8
      move(bag,fuel(e),"coal",math.min(target-stock(e,fuel,"coal"),math.max(0,have(bot,"coal")-reserve)))
      if not on_coal and fuel_stock(e)<3 then
        move(bag,fuel(e),"wood",math.min(8,available_wood(bot,s)))
      end
    end
  end
end

local function plates(bot,s,item,needed)
  local ore = metals[item]
  local sources = furnaces(bot,s,ore)
  local ready = {}
  for _, unit in ipairs(sources) do
    local f = unit.furnace
    local count = stock(f,output,item)
    if count>0 then ready[#ready+1] = {f=f,count=count} end
  end
  table.sort(ready,function(a,b)
    local function score(entry) return math.min(needed,entry.count)/(1+companion.distance(bot.position,entry.f.position)/8) end
    return score(a)>score(b)
  end)
  for _, entry in ipairs(ready) do
    local total=have(bot,item)
    for _, other in ipairs(ready) do total=total+other.count end
    if (entry.count>=math.min(needed,8) or total>=needed+have(bot,item)) and
      collect_plates(bot,s,entry.f,item) then
      if s.stage>=7 then s.sweep=item end
      return true
    end
  end
  for _, unit in ipairs(sources) do
    local f,d = unit.furnace,unit.drill
    if fuel_stock(f)<2 and refuel(bot,s,f,math.max(4,math.min(12,math.ceil(needed/3)))) then return true end
    if d and fuel_stock(d)<2 and refuel(bot,s,d,4) then return true end
  end
  if s.stage==2 and item=="iron-plate" then
    if not s.aux_iron and #sources>0 and #sources<=2 and have(bot,"stone-furnace")>=1 and
      have(bot,"coal")+available_wood(bot,s)/2>=3 then
      local next_pair=layout.pair(bot,s,"iron-ore","stone-furnace",s.avoid)
      if next_pair then s.aux_iron=next_pair.sink end
    end
    if s.aux_iron and not layout.at(bot,"stone-furnace",s.aux_iron) then
      if build(bot,s,{name="stone-furnace",position=s.aux_iron,direction=0},"aux-iron") then return true end
    end
    for _, unit in ipairs(sources) do
      local f=unit.furnace
      if not unit.drill and fuel_stock(f)>0 and stock(f,input,ore)<4 and companion.distance(bot.position,f.position)<18 then
        if have(bot,ore)>0 then return transfer(s,f,"input","put",ore,math.min(8,have(bot,ore))) end
        return mine(bot,s,ore,5)
      end
    end
  end
  local f = s.manual and layout.at(bot,"stone-furnace",s.manual)
  if s.mode=="done" then
    for _, furnace in ipairs(nearby(bot,s,{name="stone-furnace",force=bot.force})) do
      local recipe=furnace.get_recipe()
      local source=input(furnace)
      local result=output(furnace)
      if source.get_item_count(ore)>0 and source.get_item_count()==source.get_item_count(ore) then
        for _, stack in ipairs(result.get_contents()) do
          if stack.name~=item and inv(bot).get_insertable_count(stack.name)>0 and
            collect_plates(bot,s,furnace,stack.name) then return true end
        end
      end
      local compatible=(not recipe or recipe.name==item) and
        source.get_item_count()==source.get_item_count(ore) and result.get_item_count()==result.get_item_count(item)
      if compatible and source.get_item_count(ore)<4 then
        local supplied=false
        for _, drill in ipairs(bot.surface.find_entities_filtered{name="burner-mining-drill",position=furnace.position,radius=4,force=bot.force}) do
          if layout.drop_sink(drill,"stone-furnace")==furnace and drill.mining_target then supplied=true;break end
        end
        if not supplied then
          if fuel_stock(furnace)<2 and refuel(bot,s,furnace,4) then return true end
          if have(bot,ore)>0 then return transfer(s,furnace,"input","put",ore,math.min(24,have(bot,ore))) end
          return mine(bot,s,ore,math.max(16,needed))
        end
      end
    end
  end
  if #sources==0 and not f then return manual_furnace(bot,s) end
  for _, unit in ipairs(sources) do
    local furnace = unit.furnace
    local source=input(furnace)
    local result=output(furnace)
    if not unit.drill and stock(furnace,input,ore)<4 and
      source.get_item_count()==source.get_item_count(ore) and result.get_item_count()==result.get_item_count(item) then
      if have(bot,ore)>0 then
        return transfer(s,furnace,"input","put",ore,math.min(24,have(bot,ore)))
      end
      if s.stage==1 then
        local resource=nearby(bot,s,{name=ore,type="resource"})[1]
        local distance=resource and companion.distance(furnace.position,resource.position) or math.huge
        return mine(bot,s,ore,distance<=5 and 1 or math.min(6,math.max(2,needed)))
      end
      return mine(bot,s,ore,math.max(16,needed))
    end
  end
  s.action = "Жду выплавку "..item
  return false
end

-- A plate trip pays for the walk once: empty every furnace of that metal that
-- is within arm's reach, not only the one the current recipe asked for.
local function sweep_plates(bot,s)
  local item=s.sweep
  local range=bot.reach_distance+4
  for _, unit in ipairs(furnaces(bot,s,metals[item])) do
    local f=unit.furnace
    if stock(f,output,item)>=5 and companion.distance(bot.position,f.position)<=range and
      collect_plates(bot,s,f,item) then return true end
  end
  s.sweep=nil
  return false
end

supply = function(bot,s,item,amount,depth)
  depth = depth or 0
  local need = amount-have(bot,item)
  if need<=0 or depth>12 then return false end
  if metals[item] then return plates(bot,s,item,need) end
  if item=="coal" then return coal(bot,s,need) end
  if item=="stone" then
    for _, unit in ipairs(layout.units(bot,s,"stone","wooden-chest")) do
      local n = stock(unit.sink,chest,"stone")
      if n>0 and transfer(s,unit.sink,"chest","take","stone",n) then return true end
      if stock(unit.drill,fuel)<2 and refuel(bot,s,unit.drill,4) then return true end
    end
  end
  if raw[item] or item=="wood" then return mine(bot,s,item,need) end
  local recipe = bot.force.recipes[item]
  if not recipe or not recipe.enabled then s.action="Рецепт закрыт: "..item; return false end
  if craft(bot,s,item,need) then s.action="Крафчу "..item; return false end
  s.craft_goal={name=item,amount=amount}
  if bot.crafting_queue_size>0 then s.action="Крафчу "..(s.crafting or item); return false end
  local per = 1
  for _, product in ipairs(recipe.products) do if product.name==item then per=product.amount or 1; break end end
  local runs = math.min(math.ceil(need/per),8)
  for _, ingredient in ipairs(recipe.ingredients) do
    if ingredient.type=="item" and have(bot,ingredient.name)<ingredient.amount*runs then
      return supply(bot,s,ingredient.name,ingredient.amount*runs,depth+1)
    end
  end
  s.action = "Не удаётся скрафтить "..item
  return false
end

local function pair(bot,s,ore,sink)
  if s.pair and (s.pair.ore~=ore or s.avoid[s.pair.key]) then s.pair=nil end
  if not s.pair and s.row and s.row.ore==ore then
    while s.row.positions[1] and blocked(s,s.row.positions[1].key) do table.remove(s.row.positions,1) end
    s.pair=s.row.positions[1]
  end
  s.pair = s.pair or layout.pair(bot,s,ore,sink,s.avoid)
  local p = s.pair
  if not p then s.action="Нет места для пары на "..ore; return false end
  if s.stage==1 and ore=="iron-ore" and (not s.manual or not layout.at(bot,sink,s.manual)) then s.manual=p.sink end
  if not layout.at(bot,sink,p.sink) then
    return build(bot,s,{name=sink,position=p.sink,direction=0},p.key)
  end
  if not layout.at(bot,"burner-mining-drill",p.drill) then
    return build(bot,s,{name="burner-mining-drill",position=p.drill,direction=p.direction},p.key)
  end
  local drill = layout.at(bot,"burner-mining-drill",p.drill)
  if layout.drop_sink(drill,sink)~=layout.at(bot,sink,p.sink) then
    s.avoid[p.key] = true
    s.pair = nil
    return false
  end
  if s.row and s.row.positions[1]==p then
    local furnace=layout.at(bot,sink,p.sink)
    p.fueled=p.fueled or {}
    for _, machine in ipairs{drill,furnace} do
      if not p.fueled[machine.unit_number] then
        if fuel_stock(machine)<2 then
          if have(bot,"coal")==0 then return coal(bot,s,8) end
          if refuel(bot,s,machine,3) then return true end
        end
        p.fueled[machine.unit_number]=true
      end
    end
    if not p.collected then
      p.collected=true
      local item=ore=="iron-ore" and "iron-plate" or "copper-plate"
      for _, unit in ipairs(furnaces(bot,s,ore)) do
        local neighbor=unit.furnace
        if companion.distance(bot.position,neighbor.position)<=4 and stock(neighbor,output,item)>=8 and
          collect_plates(bot,s,neighbor,item) then return true end
      end
    end
    table.remove(s.row.positions,1)
    s.pair=nil
    if #s.row.positions==0 then s.row=nil end
    return false
  end
  s.pair = nil
  return refuel(bot,s,drill,s.stage>=4 and 10 or 6)
end

local function reserve_drills(bot,s,positions,count)
  local missing=0
  for i=1,count do
    if not layout.at(bot,"burner-mining-drill",positions[i]) then missing=missing+1 end
  end
  if have(bot,"burner-mining-drill")>=missing then return true,false end
  return false,supply(bot,s,"burner-mining-drill",missing)
end

local function seed_coal_drill(bot,s,drill)
  s.seeded_coal=s.seeded_coal or {}
  if s.seeded_coal[drill.unit_number] or stock(drill,fuel,"coal")>0 then
    s.seeded_coal[drill.unit_number]=true
    return false,false
  end
  if have(bot,"coal")==0 then return true,coal(bot,s,8) end
  local p=drill.position
  return true,task(s,"transfer",{x=p.x,y=p.y,entity=drill.name,inventory="fuel",mode="put",
    name="coal",count=1,seed_coal=drill.unit_number},"Запускаю бур одним углём","transfer:"..drill.unit_number)
end

local function fill_ring(bot,s,group)
  local ready,queued=reserve_drills(bot,s,group.positions,#group.positions)
  if not ready then return false,queued end
  for i,p in ipairs(group.positions) do
    if not layout.at(bot,"burner-mining-drill",p) then
      return false,build(bot,s,{name="burner-mining-drill",position=p,direction=group.directions[i]},group.key)
    end
  end
  for i,p in ipairs(group.positions) do
    local drill=layout.at(bot,"burner-mining-drill",p)
    if drill.direction~=group.directions[i] then
      return false,task(s,"orient",{x=p.x,y=p.y,name=drill.name,direction=group.directions[i]},
        "Замыкаю угольную змею",group.key)
    end
  end
  for i,p in ipairs(group.positions) do
    local drill=layout.at(bot,"burner-mining-drill",p)
    if layout.drop_sink(drill,"burner-mining-drill")~=layout.at(bot,"burner-mining-drill",group.positions[i%#group.positions+1]) then
      s.action="Проверьте направления угольной змеи"
      s.avoid[group.key]=true
      return false,false
    end
  end
  for _, p in ipairs(group.positions) do
    local drill=layout.at(bot,"burner-mining-drill",p)
    local needs_seed,queued=seed_coal_drill(bot,s,drill)
    if needs_seed then return false,queued end
  end
  group.active_count=#group.positions
  return true,false
end

local function snake(bot,s)
  if s.coal and blocked(s,s.coal.key) then s.coal=nil end
  s.coal=s.coal or layout.coal(bot,s)
  if not s.coal then s.action="Нет места для четырёх угольных буров"; return false end
  local done,queued=fill_ring(bot,s,s.coal)
  if done then s.stage=s.stage+1 end
  return queued
end

local function expand_coal(bot,s)
  local group=s.pending_coal
  if group and blocked(s,group.key) then s.pending_coal=nil; group=nil end
  if not group then
    local trips=s.coal_trips and #s.coal_trips or 0
    if not s.coal or not s.coal.active_count or s.coal.active_count>=12 or
      (s.coal.active_count>=8 and trips<2) or
      have(bot,"iron-plate")<18 or have(bot,"coal")<2 or
      have(bot,"stone")+5*have(bot,"stone-furnace")<10 then return false end
    group=layout.extend_coal(bot,s,s.coal)
    if not group then s.coal_trips={}; return false end
    s.pending_coal=group
  end
  local done,queued=fill_ring(bot,s,group)
  if done then s.coal=group; s.pending_coal=nil; s.coal_trips={} end
  return queued
end

local function maintain(bot,s,ore)
  if ore=="iron-ore" and iron_surplus(bot,s) then return false end
  for _, unit in ipairs(furnaces(bot,s,ore)) do
    if stock(unit.furnace,fuel)<2 and refuel(bot,s,unit.furnace,6) then return true end
    if unit.drill and stock(unit.drill,fuel)<2 and refuel(bot,s,unit.drill,4) then return true end
  end
  return false
end

local function fuel_patrol(bot,s)
  if s.stage<2 or game.tick<(s.next_fuel_check or 0) then return false end
  s.next_fuel_check=game.tick+120
  if have(bot,"coal")==0 and available_wood(bot,s)==0 then return false end
  local best,score
  local function consider(entity,threshold,target,priority)
    local count=fuel_stock(entity)
    if count>threshold or blocked(s,"transfer:"..entity.unit_number) then return end
    local distance=companion.distance(bot.position,entity.position)
    if distance>(count==0 and 30 or 18) then return end
    local rank=priority+(count==0 and 9 or 0)-distance*0.55
    if not score or rank>score then best,score={entity=entity,count=target},rank end
  end
  for _, ore in ipairs{"iron-ore","copper-ore"} do
    for _, unit in ipairs(furnaces(bot,s,ore)) do
      if unit.drill and stock(unit.furnace,output)<60 and not (ore=="iron-ore" and iron_surplus(bot,s)) then
        consider(unit.drill,3,s.stage>=4 and 12 or 6,15)
        if stock(unit.furnace,input)>0 then consider(unit.furnace,2,8,10) end
      end
    end
  end
  if best then return refuel(bot,s,best.entity,best.count) end
  return false
end

local function replace_exhausted_ring(bot,s)
  if s.stage<4 or not s.coal or game.tick<(s.next_ring_check or 0) then return false end
  s.next_ring_check=game.tick+600
  for _, p in ipairs(s.coal.positions) do
    if not layout.has_ore(bot,p,"coal") or not layout.at(bot,"burner-mining-drill",p) then
      s.avoid[s.coal.key]=true
      local group=layout.coal(bot,s,s.coal.positions)
      if s.extra_coal then
        s.coal,s.extra_coal=s.extra_coal,nil
      elseif group then
        s.coal=group
        s.repair_coal=true
      end
      break
    end
  end
  return false
end

local function first_furnaces(bot,s)
  if not s.initial_stone then
    local total=have(bot,"stone")+have(bot,"stone-furnace")*5
    if total<120 then
      for _, rock in ipairs(nearby(bot,s,{name=large_rocks,type="simple-entity"})) do
        if not blocked_mine(s,"mine:"..rock.position.x..":"..rock.position.y) then
          return mine(bot,s,"stone",120-total)
        end
      end
    end
    s.initial_stone=true
  end
  if have(bot,"stone-furnace")<1 and not s.manual and #furnaces(bot,s,"iron-ore")==0 then
    if have(bot,"stone")<5 then return mine(bot,s,"stone",5) end
    craft(bot,s,"stone-furnace",math.floor(have(bot,"stone")/5))
    s.action="Крафчу первые печи"
    return false
  end
  return false
end

local function start_coal_pair(bot,s,priority)
  if not s.early_coal then
    if not priority and have(bot,"coal")+available_wood(bot,s)/2>=36 then return false end
    s.coal=layout.coal(bot,s)
    if not s.coal then s.early_coal=false; return false end
    s.early_coal=true
  end
  if blocked(s,s.coal.key) then s.early_coal=false; s.coal=nil; return false end
  local ready,queued=reserve_drills(bot,s,s.coal.positions,2)
  if not ready then return true,queued end
  if not s.coal_departure_ready then
    if have(bot,"coal")<2 then return true,coal(bot,s,8) end
    for _, unit in ipairs(layout.units(bot,s,"iron-ore","stone-furnace")) do
      for _, machine in ipairs{unit.drill,unit.sink} do
        if have(bot,"coal")>2 and fuel_stock(machine)<1 and
          transfer(s,machine,"fuel","put","coal",math.min(3,have(bot,"coal")-2)) then return true,true end
      end
    end
    s.coal_departure_ready=true
  end
  for i=1,2 do
    local p=s.coal.positions[i]
    if not layout.at(bot,"burner-mining-drill",p) then
      return true,build(bot,s,{name="burner-mining-drill",position=p,direction=i==1 and 4 or 12},s.coal.key)
    end
  end
  for i=1,2 do
    local drill=layout.at(bot,"burner-mining-drill",s.coal.positions[i])
    local needs_seed,queued=seed_coal_drill(bot,s,drill)
    if needs_seed then return true,queued end
  end
  s.coal.active_count=2
  telemetry.mark(s,"coal_pair_running")
  s.early_coal=false
  return false
end

local function coal_pair_ready(bot,s)
  if s.stage~=2 or s.coal and s.coal.active_count or have(bot,"coal")<2 then return false end
  local units=layout.units(bot,s,"iron-ore","stone-furnace")
  if #units<2 then return false end
  local missing=math.max(0,2-have(bot,"burner-mining-drill"))
  if have(bot,"stone")+5*have(bot,"stone-furnace")<missing*5 then return false end
  local iron=have(bot,"iron-plate")
  for _, unit in ipairs(units) do iron=iron+stock(unit.sink,output,"iron-plate") end
  return iron>=missing*9
end

local function prefer_coal_pair(bot,s)
  if not s.coal_bootstrap and s.fuel_trip and coal_pair_ready(bot,s) then
    s.coal_bootstrap=true
    s.deferred_fuel_trip,s.fuel_trip=s.fuel_trip,nil
  end
  if not s.coal_bootstrap then return false end
  local working=start_coal_pair(bot,s,true)
  if working then return true end
  s.coal_bootstrap=nil
  s.fuel_trip=s.deferred_fuel_trip
  s.deferred_fuel_trip=nil
  return false
end

local function iron_ready(bot,units,minimum,plates_needed)
  if #units<minimum then return false end
  local plates=have(bot,"iron-plate")
  local producing=0
  for _, unit in ipairs(units) do
    plates=plates+stock(unit.sink,output,"iron-plate")
    if fuel_stock(unit.drill)>0 and fuel_stock(unit.sink)>0 then producing=producing+1 end
  end
  return producing>=math.floor(minimum/2) and plates>=plates_needed
end

local function prepare_row(bot,s,ore,missing)
  local count=math.min(missing,4)
  if count<1 then return false,false end
  if have(bot,"burner-mining-drill")<count then
    return false,supply(bot,s,"burner-mining-drill",count)
  end
  if have(bot,"stone-furnace")<count then return false,supply(bot,s,"stone-furnace",count) end
  if have(bot,"coal")<count*6 then return false,coal(bot,s,count*6) end
  local positions={}
  for _=1,count do
    local candidate=layout.pair(bot,s,ore,"stone-furnace",s.avoid,positions)
    if not candidate then break end
    positions[#positions+1]=candidate
  end
  if #positions==0 then return true,false end
  s.row={ore=ore,positions=positions}
  return true,false
end

local function stone_start(bot,s)
  if s.stone_capacity_checked or s.stage<2 or s.stage==3 then return false end
  local stone_units=layout.units(bot,s,"stone","wooden-chest")
  local iron_units=layout.units(bot,s,"iron-ore","stone-furnace")
  local fuels=have(bot,"coal")+available_wood(bot,s)/2
  local stock_on_hand=have(bot,"stone")+5*have(bot,"stone-furnace")
  local emergency=#stone_units==0 and #iron_units>=2 and stock_on_hand<10 and
    bot.surface.count_entities_filtered{name=large_rocks,position=s.home,radius=65,limit=1}==0
  local target=emergency and 1 or s.stage>=6 and 4 or s.stage>=4 and 2 or 0
  if #stone_units>=target then return false end
  if s.pair and s.pair.ore=="stone" then return pair(bot,s,"stone","wooden-chest") end
  if fuels<8 or (have(bot,"burner-mining-drill")<1 and (have(bot,"iron-plate")<18 or stock_on_hand<10)) then return false end
  local candidate=layout.pair(bot,s,"stone","wooden-chest",s.avoid)
  if not candidate then
    s.stone_capacity_checked=true
    return false
  end
  s.pair=candidate
  return pair(bot,s,"stone","wooden-chest")
end

local function smelting(bot,s)
  local stage = s.stage
  if stage==3 then return snake(bot,s) end
  if not s.row and (not s.pair or s.pair.ore=="stone") and stone_start(bot,s) then return true end
  local ore = stage==5 and "copper-ore" or "iron-ore"
  local target = ({1,5,0,8,4,14})[stage]
  local units = layout.units(bot,s,ore,"stone-furnace")
  if stage==2 and #units>=2 and s.early_coal~=false then
    local working,queued=start_coal_pair(bot,s)
    if working then return queued end
  end
  if s.row and s.row.ore==ore and #s.row.positions>0 then
    return pair(bot,s,ore,"stone-furnace")
  end
  if #units>=target or stage==4 and iron_ready(bot,units,6,65) or
    stage==6 and iron_ready(bot,units,12,100) then
    s.stage,s.pair,s.row=stage+1,nil,nil
    return false
  end
  local stocked_early_row=stage==2 and #units>=2 and s.early_coal==false and
    have(bot,"burner-mining-drill")>=2 and have(bot,"stone-furnace")>=2 and have(bot,"coal")>=12
  if stage>=4 or stocked_early_row then
    local ready,queued=prepare_row(bot,s,ore,stocked_early_row and math.min(2,target-#units) or target-#units)
    if not ready then return queued end
    if s.row then return pair(bot,s,ore,"stone-furnace") end
  end
  if stage==1 then
    if not s.salvaged then
      local wrecks=bot.surface.find_entities_filtered{type="container",position=s.home,radius=45}
      table.sort(wrecks,function(a,b)
        return companion.distance(bot.position,a.position)<companion.distance(bot.position,b.position)
      end)
      for _, e in ipairs(wrecks) do
        if e.name:match("^crash%-site%-spaceship%-wreck%-") or e.name:match("^crash%-site%-chest%-") then
          local p=e.position
          local count=stock(e,chest,"iron-plate")
          if count>0 and not blocked(s,"wreck:"..e.unit_number) then
            return task(s,"transfer",{x=p.x,y=p.y,entity=e.name,inventory="chest",mode="take",
              name="iron-plate",count=count,wreck=true},"Забираю плиты из обломков","wreck:"..e.unit_number)
          end
        end
      end
      s.salvaged=true
    end
    if first_furnaces(bot,s) then return true end
    if not s.initial_fuel then
      if have(bot,"coal")+available_wood(bot,s)/2<24 then return coal(bot,s,24) end
      s.initial_fuel=true
    end
  end
  local queued = pair(bot,s,ore,"stone-furnace")
  if queued then return true end
  if maintain(bot,s,ore) then return true end
  return false
end

local function ensure_parts(bot,s,parts)
  for _, part in ipairs(parts) do
    local e = layout.at(bot,part.name,part.position)
    if not e then
      local key = "structure:"..part.position.x..":"..part.position.y
      if blocked(s,key) then s.action="Освободите место для "..part.name; return false,false end
      return false,build(bot,s,part,key)
    end
    if part.recipe then
      local recipe = e.get_recipe()
      if recipe and recipe.name~=part.recipe then
        s.action="Другой рецепт в "..part.name.." на "..part.position.x..", "..part.position.y
        return false,false
      end
      if not recipe then
        local p = part.position
        return false,task(s,"recipe",{x=p.x,y=p.y,name=part.recipe,entity=part.name},
          "Настраиваю "..part.recipe,"recipe:"..p.x..":"..p.y)
      end
    end
  end
  return true,false
end

local function suggest(bot,s,kind)
  if s.proposal and s.proposal.kind==kind then return false end
  local candidate
  if kind=="power" then candidate = layout.power(bot,s,s.home,110)
  else candidate = layout.factory(bot,s,s.home,35) end
  if not candidate then
    s.action = kind=="power" and "Не нашёл свободный берег. Укажите другой район." or
      "Не нашёл места для It Begins. Укажите другой район."
    s.next_suggestion = game.tick+600
    return false
  end
  if s.auto_approve then s[kind]=candidate
  else
    s.proposal = {kind=kind,value=candidate}
    local p = candidate.origin or candidate.parts[1].position
    bot.force.add_chart_tag(bot.surface,{position=p,text=kind=="power" and companion.name..": пар" or companion.name..": It Begins"})
    s.action = "Предложил место на карте"
  end
  return false
end

local function route_power(bot,s,goal)
  if not s.power_tail then s.power_tail = s.power.parts[6].position end
  local tail = s.power_tail
  if s.next_pole and layout.at(bot,"small-electric-pole",s.next_pole) then
    s.power_tail = s.next_pole
    s.power_links=s.power_links or {}
    s.power_links[#s.power_links+1]=s.next_pole
    tail = s.power_tail
    s.next_pole = nil
  end
  if companion.distance(tail,goal)<=7 then return false end
  local p = s.next_pole or layout.next_pole(bot,tail,goal,s.factory.origin)
  if not p then s.action="Нет свободного маршрута ЛЭП. Проложите линию до лабораторий."; return false end
  s.next_pole = p
  return build(bot,s,{name="small-electric-pole",position=p,direction=0},"pole:"..p.x..":"..p.y)
end

local function steam(bot,s)
  if not s.power then
    if not s.next_suggestion or game.tick>=s.next_suggestion then return suggest(bot,s,"power") end
    return false
  end
  telemetry.mark(s,"power_site_chosen")
  if not bot.force.recipes["offshore-pump"].enabled then
    s.action = "Жду открытия паровой энергии"
    return maintain(bot,s,"iron-ore")
  end
  local built,queued = ensure_parts(bot,s,s.power.parts)
  if not built then return queued end
  telemetry.mark(s,"power_built")
  local boiler = layout.at(bot,"boiler",s.power.parts[3].position)
  if stock(boiler,fuel)<5 and refuel(bot,s,boiler,15) then return true end
  if not s.factory then
    if not s.next_suggestion or game.tick>=s.next_suggestion then return suggest(bot,s,"factory") end
    return false
  end
  telemetry.mark(s,"factory_site_chosen")
  local labs,pole = {},nil
  for _, part in ipairs(s.factory.parts) do
    if part.name=="lab" then labs[#labs+1]=part end
    if part.id==5 then pole=part end
  end
  labs[3] = pole
  built,queued = ensure_parts(bot,s,labs)
  if not built then return queued end
  telemetry.mark(s,"labs_built")
  local a = layout.at(bot,"lab",labs[1].position)
  local b = layout.at(bot,"lab",labs[2].position)
  local engine=layout.at(bot,"steam-engine",s.power.parts[4].position)
  local network=engine.electric_network_id
  if not network or a.electric_network_id~=network or b.electric_network_id~=network then
    return route_power(bot,s,pole.position)
  end
  telemetry.mark(s,"labs_powered")
  local automation = bot.force.technologies.automation
  if automation.researched then telemetry.mark(s,"automation_researched"); s.stage=8; return false end
  if not bot.force.recipes["automation-science-pack"].enabled then
    s.action="Жду открытия красной науки"
    return maintain(bot,s,"copper-ore")
  end
  local current = bot.force.current_research
  if not current then
    return task(s,"research",{name="automation"},"Ставлю автоматизацию в очередь","research")
  end
  if current.name~="automation" then s.action="Жду завершения "..current.name; return false end
  telemetry.mark(s,"research_queued")
  local item = "automation-science-pack"
  local count_a,count_b = stock(a,lab,item),stock(b,lab,item)
  local needed = math.max(0,automation.research_unit_count-math.floor(bot.force.research_progress*automation.research_unit_count+0.001)-count_a-count_b)
  if have(bot,item)>0 then telemetry.mark(s,"first_science_pack_crafted") end
  if needed==0 then telemetry.mark(s,"science_delivered") end
  if needed>0 and have(bot,item)>0 then
    local target = count_a<=count_b and a or b
    local count = math.min(needed,have(bot,item),math.max(1,math.ceil((needed+math.abs(count_a-count_b))/2)))
    return transfer(s,target,"lab","put",item,count)
  end
  if needed>0 and supply(bot,s,item,needed) then return true end
  if maintain(bot,s,"iron-ore") or maintain(bot,s,"copper-ore") then return true end
  s.action = "Лаборатории исследуют автоматизацию"
  return false
end

local factory_inputs={[23]={"iron-plate","copper-plate"},[27]={"iron-plate"},
  [32]={"iron-plate","copper-plate"},[37]={"copper-plate","iron-plate"}}

local function gather_for_factory(bot,s)
  if s.delivering_factory then return false end
  if not s.factory_trip then
    local needed={}
    for _, part in ipairs(s.factory.parts) do
      for _, item in ipairs(factory_inputs[part.id] or {}) do
        local key=part.id..":"..item
        local entity=layout.at(bot,"iron-chest",part.position)
        if not s.fed[key] and stock(entity,chest,item)<8 then
          needed[item]=(needed[item] or 0)+math.max(0,16-stock(entity,chest,item))
        end
      end
    end
    if not next(needed) then return false end
    s.factory_trip=needed
    local boiler=layout.at(bot,"boiler",s.power.parts[3].position)
    if boiler and fuel_stock(boiler)<8 then needed.coal=24 end
  end
  local nearest,score
  for _, item in ipairs{"iron-plate","copper-plate","coal"} do
    local amount=s.factory_trip[item] or 0
    if have(bot,item)<amount then
      local distance=math.huge
      if item=="coal" then
        for _, group in ipairs{s.coal,s.extra_coal} do
          for _, p in ipairs(group.positions) do
            local e=layout.at(bot,"burner-mining-drill",p)
            if e and stock(e,fuel,"coal")>1 then distance=math.min(distance,companion.distance(bot.position,p)) end
          end
        end
      else
        for _, unit in ipairs(furnaces(bot,s,metals[item])) do
          if stock(unit.furnace,output,item)>0 then
            distance=math.min(distance,companion.distance(bot.position,unit.furnace.position))
          end
        end
      end
      if not score or distance<score then nearest,score=item,distance end
    end
  end
  if nearest then
    return supply(bot,s,nearest,s.factory_trip[nearest]),true
  end
  s.factory_trip=nil
  s.delivering_factory=true
  return false
end

local function feed_factory(bot,s)
  local inputs=factory_inputs
  for _, part in ipairs(s.factory.parts) do
    if inputs[part.id] then
      local e = layout.at(bot,"iron-chest",part.position)
      for _, item in ipairs(inputs[part.id]) do
        local key = part.id..":"..item
        local count = stock(e,chest,item)
        if count>=8 then s.fed[key]=true end
        if not s.fed[key] then
          if have(bot,item)>0 then
            return transfer(s,e,"chest","put",item,math.min(have(bot,item),16-count))
          end
          return supply(bot,s,item,16)
        end
      end
    end
  end
  s.delivering_factory=nil
  telemetry.mark(s,"factory_fed")
  local belt,insert = false,false
  for _, part in ipairs(s.factory.parts) do
    if part.id==28 or part.id==31 then
      local e = layout.at(bot,"iron-chest",part.position)
      if part.id==28 then belt=stock(e,chest,"transport-belt")>0
      else insert=stock(e,chest,"inserter")>0 end
    end
  end
  local science = false
  for _, part in ipairs(s.factory.parts) do
    if part.id==6 then science=layout.at(bot,part.name,part.position).products_finished>0; break end
  end
  if science then telemetry.mark(s,"science_confirmed") end
  if belt then telemetry.mark(s,"belts_confirmed") end
  if insert then telemetry.mark(s,"inserters_confirmed") end
  if belt and insert and science then
    s.finished_tick=game.tick
    s.mode,s.action = "done","It Begins: наука, ленты и манипуляторы подтверждены"
    return false
  end
  if not s.checked_output then s.checked_output=game.tick end
  if game.tick-s.checked_output>3600 then
    s.checked_output=game.tick
    s.fed={}
  end
  s.action="Проверяю выпуск: наука "..tostring(science)..", ленты "..tostring(belt)..", манипуляторы "..tostring(insert)
  return false
end

function starter.boiler_refill(bot,boiler)
  local st=storage.starter
  if not st or not st.boiler_feed or not st.power or not boiler then return end
  local first=st.power.parts[3].position
  if companion.distance(boiler.position,first)>.1 then return end
  local feed=st.boiler_feed
  local box=layout.at(bot,"wooden-chest",feed[1].position)
  local inserter=box and layout.at(bot,feed[2].name,feed[2].position)
  if not inserter or companion.distance(inserter.pickup_position,box.position)>.15 then return end
  local drop,area=inserter.drop_position,boiler.bounding_box
  if drop.x<area.left_top.x or drop.x>area.right_bottom.x or
      drop.y<area.left_top.y or drop.y>area.right_bottom.y then return end
  local reserve=stock(box,chest,"coal")+stock(boiler,fuel,"coal")
  local amount=reserve<=35 and math.min(180-reserve,math.max(0,have(bot,"coal")-24)) or 0
  return box,amount,reserve
end

local function factory(bot,s)
  local built,queued=ensure_parts(bot,s,s.factory.parts)
  if not built then return queued end
  telemetry.mark(s,"factory_built")
  local collecting,trip=gather_for_factory(bot,s)
  if trip then return collecting end
  local boiler=layout.at(bot,"boiler",s.power.parts[3].position)
  if not s.boiler_feed_checked then
    s.boiler_feed=layout.boiler_feed(bot,s.power)
    s.boiler_feed_checked=true
  end
  if s.boiler_feed then
    local ready,building=ensure_parts(bot,s,s.boiler_feed)
    if building then return true end
    if ready then
      local box,amount=starter.boiler_refill(bot,boiler)
      if box and amount>0 and transfer(s,box,"chest","put","coal",amount) then return true end
    end
  end
  if boiler and stock(boiler,fuel)<4 and refuel(bot,s,boiler,25) then return true end
  return feed_factory(bot,s)
end

function starter.status()
  local s=storage.starter
  if not s then return {mode="off",action="План не запущен"} end
  local proposal = s.proposal
  local value = proposal and proposal.value
  local bot = storage.bot
  local report = telemetry.report(s,labels)
  return {mode=s.mode,stage=s.stage,goal=labels[s.stage],action=s.action,job=s.job,
    stage_log=report.stage_log, stages=report.stages,
    telemetry_since_tick=report.since, telemetry_partial=report.partial,
    planning_interval_ticks=planning_interval,
    elapsed_ticks=(s.finished_tick or game.tick)-s.started_tick,
    iron=bot and bot.valid and #layout.units(bot,s,"iron-ore","stone-furnace") or 0,
    copper=bot and bot.valid and #layout.units(bot,s,"copper-ore","stone-furnace") or 0,
    proposal=proposal and {kind=proposal.kind,position=value.origin or value.parts[1].position,reserve=value.reserve},
    started_tick=s.started_tick, tick=game.tick, actions=s.actions, last_error=s.last_error,
    auto_approve=s.auto_approve,
    coal=bot and bot.valid and have(bot,"coal") or 0,
    stone=bot and bot.valid and have(bot,"stone") or 0,
    target_seconds=target_ticks/60,
    elapsed_seconds=math.floor(((s.finished_tick or game.tick)-s.started_tick)/60),
    within_target=s.finished_tick and s.finished_tick-s.started_tick<target_ticks,
    power=s.power and s.power.parts[1].position, factory=s.factory and s.factory.origin}
end

function starter.start(args)
  local bot=companion.character()
  if storage.starter then
    assert(storage.starter.mode~="done","Стартовый план уже завершён")
    storage.starter.mode="running"
    if args.auto_approve~=nil then storage.starter.auto_approve=args.auto_approve end
    local proposal=storage.starter.proposal
    if storage.starter.auto_approve and proposal then
      storage.starter[proposal.kind]=proposal.value
      storage.starter.proposal=nil
    end
  else
    storage.starter={mode="running",stage=1,home=bot.position,avoid={},fed={},
      started_tick=game.tick,actions=0,auto_approve=args.auto_approve==true}
    telemetry.begin(storage.starter)
    telemetry.sync(storage.starter,bot)
  end
  return starter.status()
end

function starter.pause()
  local s=storage.starter
  if s and s.mode=="running" then
    s.mode="paused"
    if s.job then
      local job=storage.jobs[s.job]
      jobs.cancel{id=s.job}
      telemetry.job(s,job)
      s.job=nil
    end
    local bot=storage.bot
    if s.crafting and bot and bot.valid and not storage.active then
      local queue=bot.crafting_queue or {}
      for i=#queue,1,-1 do bot.cancel_crafting{index=i,count=queue[i].count} end
    end
    s.crafting=nil
    s.action="Пауза"
  end
  return starter.status()
end

function starter.approve()
  local s=assert(storage.starter,"Сначала запустите план")
  local p=assert(s.proposal,"Нет предложения")
  s[p.kind]=p.value
  s.proposal=nil
  return starter.status()
end

function starter.relocate(args)
  local s=assert(storage.starter,"Сначала запустите план")
  local bot=companion.character()
  assert(s.stage==7,"Места для строительства выбираются на этапе пара")
  local position=companion.position(args)
  assert(companion.distance(position,s.home)<180,"Место слишком далеко от базы")
  local kind=not s.power and "power" or not s.factory and "factory"
  assert(kind,"Места уже утверждены")
  local value
  if kind=="power" then value=layout.power(bot,s,position,22)
  else value=layout.factory(bot,s,position,10) end
  assert(value,"Рядом нет подходящего места")
  s.proposal={kind=kind,value=value}
  return starter.status()
end

local function count_trigger_crafts(bot,s)
  local tech=bot.force.technologies
  local statistics=bot.force.get_item_production_statistics(bot.surface)
  -- Detached characters can craft, but their crafts do not fire the player trigger.
  if tech["steam-power"].enabled and not tech["steam-power"].researched and
    statistics.get_input_count("iron-plate")>=50 then tech["steam-power"].researched=true end
  if tech.electronics.enabled and not tech.electronics.researched and
    statistics.get_input_count("copper-plate")>=10 then tech.electronics.researched=true end
  local science=tech["automation-science-pack"]
  if s.lab_crafted and science.enabled and not science.researched and
    tech["steam-power"].researched and tech.electronics.researched then science.researched=true end
  if tech["steam-power"].researched then telemetry.mark(s,"steam_power_unlocked") end
  if tech.electronics.researched then telemetry.mark(s,"electronics_unlocked") end
  if science.researched then telemetry.mark(s,"science_pack_unlocked") end
end

local function decide(bot,s)
  count_trigger_crafts(bot,s)
  if prefer_coal_pair(bot,s) then return end
  if harvest_coal(bot,s) then return end
  if s.sweep and sweep_plates(bot,s) then return end
  if s.fuel_trip then
    -- Steam equipment is ready: the useful minimum beats filling a round-number quota.
    if s.stage>=6 and have(bot,"coal")>=32 and have(bot,"offshore-pump")>=1 and
      have(bot,"boiler")>=1 and have(bot,"steam-engine")>=2 and
      #layout.units(bot,s,"iron-ore","stone-furnace")>=12 and
      #layout.units(bot,s,"copper-ore","stone-furnace")>=4 then s.fuel_trip=nil end
  end
  if s.fuel_trip then
    coal(bot,s,0)
    if s.job or s.fuel_trip then return end
  end
  if not s.repair_coal then replace_exhausted_ring(bot,s) end
  if s.repair_coal then
    local done,queued=fill_ring(bot,s,s.coal)
    if done or blocked(s,s.coal.key) then s.repair_coal=nil end
    if queued then return end
  end
  if not s.row and not s.factory_trip then
    if s.stage>=4 and expand_coal(bot,s) then return end
    if fuel_patrol(bot,s) then return end
  end
  if s.stage<=6 then
    if smelting(bot,s) or s.job then return end
    local waiting=s.action
    if s.stage==2 and waiting and (waiting:match("^Жду") or waiting:match("^Крафчу")) then
      -- Fill the spare furnace while the next machines are crafting or smelting.
      for _, unit in ipairs(furnaces(bot,s,"iron-ore")) do
        local f=unit.furnace
        if not unit.drill and companion.distance(bot.position,f.position)<=10 and fuel_stock(f)>0 and stock(f,input,"iron-ore")<6 then
          if have(bot,"iron-ore")>0 then return transfer(s,f,"input","put","iron-ore",have(bot,"iron-ore")) end
          return mine(bot,s,"iron-ore",6)
        end
      end
      if have(bot,"stone")<10 and have(bot,"stone-furnace")<5 then
        for _, e in ipairs(nearby(bot,s,{name=large_rocks,type="simple-entity"})) do
          if companion.distance(bot.position,e.position)<=22 then return mine(bot,s,"stone",80) end
          break
        end
      end
    end
    return
  end
  if s.stage==7 then return steam(bot,s) end
  return factory(bot,s)
end

local function prepare_while_working(bot,s,job)
  if bot.crafting_queue_size>0 or game.tick%30~=0 then return end
  local goal=s.craft_goal
  if goal and job.kind=="move" then
    local missing=goal.amount-have(bot,goal.name)
    if missing<=0 then s.craft_goal=nil
    elseif craft(bot,s,goal.name,missing) then s.craft_goal=nil; return end
  end
  if job.kind=="mine" and job.args.item~="stone" and s.stage<=2 and have(bot,"stone")>=10 then
    craft(bot,s,"stone-furnace",math.floor(have(bot,"stone")/5))
    return
  end
  if s.stage>=2 and s.stage<=6 and have(bot,"iron-plate")>=18 and
    have(bot,"stone-furnace")>=3 and have(bot,"burner-mining-drill")==0 then
    craft(bot,s,"burner-mining-drill",2)
    return
  end
  if s.stage>=4 and s.stage<=6 and have(bot,"iron-plate")>=36 then
    for _, entry in ipairs{{"offshore-pump",1},{"boiler",1},{"steam-engine",2}} do
      local recipe=bot.force.recipes[entry[1]]
      local missing=entry[2]-have(bot,entry[1])
      if recipe and recipe.enabled and missing>0 and craft(bot,s,entry[1],missing) then return end
    end
  end
  if s.stage==7 and bot.force.current_research and bot.force.current_research.name=="automation" then
    if have(bot,"iron-plate")>=24 and have(bot,"copper-plate")>=8 and have(bot,"inserter")<6 then
      craft(bot,s,"inserter",6-have(bot,"inserter"))
    end
  end
end

-- Hand-crafting is the bottleneck of the last two stages. While the queue is
-- idle, make what the next build steps will ask for, in the order they ask.
-- Batches stay short so a craft the planner needs right now is not held up.
local function precraft(bot,s)
  if s.stage<7 or bot.crafting_queue_size>0 then return end
  local pending={}
  for _, part in ipairs(s.factory and s.factory.parts or blueprint) do
    if not (s.factory and layout.at(bot,part.name,part.position)) then
      pending[part.name]=(pending[part.name] or 0)+1
    end
  end
  local recipes=bot.force.recipes
  local copper_owed=false
  local function want(item,total,batch,uses_copper)
    local missing=total-have(bot,item)
    if missing<=0 or not recipes[item].enabled or (uses_copper and copper_owed) then return false end
    if craft(bot,s,item,math.min(missing,batch)) then return true end
    -- Not enough plates yet: later items must not eat the copper it is waiting for.
    copper_owed=copper_owed or uses_copper
    return false
  end
  if want("lab",pending.lab or 0,1,true) then return end
  local automation=bot.force.technologies.automation
  if not automation.researched then
    local pack="automation-science-pack"
    local packs=automation.research_unit_count
    local current=bot.force.current_research
    if current and current.name=="automation" then
      packs=packs-math.floor(bot.force.research_progress*packs+0.001)
    end
    if s.factory then
      for _, part in ipairs(s.factory.parts) do
        local e=part.name=="lab" and layout.at(bot,"lab",part.position)
        if e then packs=packs-stock(e,lab,pack) end
      end
    end
    if want(pack,packs,2,true) then return end
  end
  local machines=pending["assembling-machine-1"] or 0
  if recipes["assembling-machine-1"].enabled then
    if want("assembling-machine-1",machines,1,true) then return end
  else
    if want("iron-gear-wheel",machines*5,8) then return end
    if want("electronic-circuit",machines*3,2,true) then return end
  end
  if want("inserter",(pending.inserter or 0)+1,2,true) then return end
  if want("iron-chest",pending["iron-chest"] or 0,4) then return end
  want("long-handed-inserter",pending["long-handed-inserter"] or 0,1,true)
end

function starter.tick()
  local s=storage.starter
  if not s then return end
  if s.mode=="paused" then telemetry.add(s,"paused_ticks",1); return end
  if s.mode~="running" or game.tick%planning_interval~=0 then return end
  local bot=storage.bot
  if not bot or not bot.valid then s.mode,s.action="paused","Напарник погиб"; return end
  telemetry.sync(s,bot)
  if bot.crafting_queue_size>0 then telemetry.add(s,"craft_busy_ticks",planning_interval) end
  if s.job then
    local job=storage.jobs[s.job]
    if job and (job.status=="running" or job.status=="queued") then
      if game.tick%60==0 and s.fuel_trip and job.kind=="mine" and job.args.name=="coal" and
        coal_pair_ready(bot,s) then
        jobs.cancel{id=s.job}
        telemetry.job(s,job)
        s.job,s.key=nil,nil
        s.action="Плиты готовы — запускаю угольную пару"
        return
      end
      service_in_reach(bot,s,job)
      prepare_while_working(bot,s,job)
      if game.tick%30==0 then precraft(bot,s) end
      return
    end
    telemetry.job(s,job)
    if job and job.status=="failed" then
      s.last_error=job.detail
      if s.key then
        local transient=s.key:match("^transfer:") or s.key:match("^ore:") or s.key:match("^mine:")
          or s.key:match("^structure:") or s.key:match("^pole:")
        s.avoid[s.key]=transient and game.tick+600 or true
        local ore,x,y=s.key:match("^([^:]+):(-?%d+):(-?%d+):%d+$")
        if ore and job.detail=="No walkable path to target" then
          x,y=tonumber(x),tonumber(y)
          for dx=-1,1 do
            for dy=-1,1 do
              for direction=0,12,4 do s.avoid[ore..":"..(x+dx)..":"..(y+dy)..":"..direction]=true end
            end
          end
        end
      end
    elseif job and job.status=="done" then
      s.actions=s.actions+1
      local a=job.args
      if a.seed_coal then
        s.seeded_coal=s.seeded_coal or {}
        s.seeded_coal[a.seed_coal]=true
      end
      if s.stage==8 and job.kind=="transfer" and a.mode=="put" and a.inventory=="chest" and s.factory then
        for _, part in ipairs(s.factory.parts) do
          if part.position.x==a.x and part.position.y==a.y then s.fed[part.id..":"..a.name]=true end
        end
      end
    end
    s.job,s.key=nil,nil
  end
  if s.lab_before and have(bot,"lab")>s.lab_before then
    s.lab_crafted=true
    telemetry.mark(s,"lab_crafted")
    s.lab_before=nil
  end
  if bot.crafting_queue_size==0 then s.crafting=nil; s.lab_before=nil end
  if storage.active or #storage.queue>0 then
    telemetry.add(s,"wait_other_ticks",planning_interval)
    return
  end
  if s.proposal then
    maintain(bot,s,"iron-ore")
    if not s.job then
      s.action="Жду подтверждения места на карте"
      telemetry.add(s,"wait_player_ticks",planning_interval)
    end
    return
  end
  local ok, err = pcall(decide,bot,s)
  if not ok then
    s.mode,s.action="paused","План приостановлен: "..tostring(err)
    s.last_error=tostring(err)
  end
  telemetry.sync(s,bot)
  if s.mode=="running" and not s.job then precraft(bot,s) end
  if s.mode=="running" and not s.job then
    telemetry.add(s,bot.crafting_queue_size>0 and "wait_craft_ticks" or "wait_other_ticks",planning_interval)
  end
end

-- Reuse the proven early resource gathering without restarting the completed plan.
function starter.assist_supply(item,amount)
  local s=assert(storage.starter,'Starter state missing')
  assert(s.mode=='done','Campaign may only use a completed starter')
  local bot=companion.character()
  supply(bot,s,item,amount)
  local id=s.job
  s.job,s.key=nil,nil
  return id,s.action
end
return starter


