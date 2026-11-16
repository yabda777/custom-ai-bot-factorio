local companion=require('character')
local jobs=require('jobs')
local io=require('campaign_io')
local layout=require('campaign_layout')
local mining=require('campaign_mining')
local old=require('starter_layout')
local routes=require('campaign_routes')
local network=require('campaign_network')
local assets=require('campaign_assets')
local campaign={}
local journal=require('action_journal')
local technologies={'electric-mining-drill','logistics','logistic-science-pack'}
local red_research={'military','fast-inserter','steel-processing','repair-pack','radar','stone-wall',
  'lamp','heavy-armor','physical-projectile-damage-1','weapon-shooting-speed-1'}
local starter_science_ids={[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,
  [11]=true,[21]=true,[22]=true,[23]=true,[24]=true,[25]=true,[39]=true}
local function starter_parts(s)
  local parts=storage.starter.factory.parts
  if not s.retired then return parts end
  local kept={}
  if s.starter_science then
    for _,p in ipairs(parts) do if starter_science_ids[p.id] then kept[#kept+1]=p end end
  end
  return kept
end
local phase_labels={planning='Разметка участков',clearing='Расчистка будущей базы',power='Электростанция и вода',stone='Производство печей',coal='Электрический уголь',
  iron='Первые электрические железные буры',one='Jump Start Base 1',copper='Расширение железа и медная добыча',two='Jump Start Base 2',
  expand='Расширение стартовой добычи',three='Jump Start Base 3',four='Jump Start Base 4',five='Jump Start Base 5',verify='Проверка работы базы'}
local function say(text) game.print('['..companion.name..'] '..text) end
local function transition(s,phase)
  if s.phase==phase then return end
  if s.stage_log[#s.stage_log] then s.stage_log[#s.stage_log].finished_tick=game.tick end
  s.phase=phase;s.stage_log[#s.stage_log+1]={phase=phase,started_tick=game.tick}
  if phase=='copper' then
    s.first_stage_parts=nil
  end
  journal.record{event='phase_changed',to=phase}
  s.action=phase_labels[phase] or phase
end
local function init()
  local st=storage.starter
  local s={mode='await_choice',phase='waiting',home=st.home,avoid={},metrics={jobs=0,failures=0,repaths=0,travel_ticks=0,idle_ticks=0},
    failure_log={},stage_log={},plans={},searches={},routes={},service_budget=0,next_service=0,created_tick=game.tick}
  storage.campaign=s
  say('It Begins работает. Продолжать строительство Jump Start Base или остаться помощником? Открой «Напарник» или введи /companion дальше либо /companion помощник.')
  return s
end
function campaign.status()
  local s=storage.campaign
  if not s then return {mode='off'} end
  local bot=storage.bot
  if bot and not bot.valid then bot=nil end
  local crafting=bot and bot.crafting_queue_size>0
  local research=bot and s.wait_recipe and bot.force.current_research
  local capacities={}
  for ore,p in pairs(s.plans) do capacities[ore]={capacity=p.capacity,built_target=p.target or 0} end
  return {mode=s.mode,phase=s.phase,goal=phase_labels[s.phase],action=s.action,test_mode=s.test_mode,
    elapsed_seconds=s.started_tick and math.floor(((s.finished_tick or game.tick)-s.started_tick)/60),
    estimate_seconds=3600,site=s.site and {origin=s.site.origin,direction=s.site.direction},
    stage_log=s.stage_log,metrics=s.metrics,last_error=s.last_error,failures=s.failure_log,capacity=capacities,
    route_error=s.route_error,route_detail=s.route_detail,job=s.job,retired=s.retired,waiting_recipe=s.wait_recipe,build=s.build_progress,
    network_pending=s.network_pending,pair_cleanup=s.pair_cleanup,waiting_material=s.waiting_material,
    rejected_water_sites=s.rejected_water_sites,
    early_three=s.early_three,
    crafting_count=crafting and bot.crafting_queue_size,
    crafting_progress=crafting and bot.crafting_queue_progress,
    required_research=research and research.name,
    required_research_progress=research and bot.force.research_progress}
end
function campaign.audit()
  local s=assert(storage.campaign,'Campaign missing')
  local bot=companion.character()
  local result={blueprint=s.blueprint,missing={},wrong_direction={},wrong_recipe={},unpowered={},depots={},starter_remaining=0,technologies={},science_production={}}
  local inspected=s.phase=='five' and s.mode=='running' and 5 or s.blueprint
  if s.site and inspected then
    local parts=layout.parts('jump',inspected,s.site.origin,s.site.direction)
    result.expected=#parts;result.present=0
    for _,p in ipairs(parts) do
      local e=io.entity(bot,p)
      if not e then result.missing[#result.missing+1]=p
      else
        result.present=result.present+1
        if not layout.matches(e,p) then result.wrong_direction[#result.wrong_direction+1]=p end
        if p.recipe then local r=e.get_recipe();if not r or r.name~=p.recipe then result.wrong_recipe[#result.wrong_recipe+1]=p end end
        if p.recipe=='automation-science-pack' or p.recipe=='logistic-science-pack' then
          result.science_production[#result.science_production+1]={recipe=p.recipe,position=e.position,products_finished=e.products_finished,status=e.status,energy=e.energy,
            input=jobs.input_inventory(e).get_contents()}
        end
        if (e.type=='assembling-machine' or e.type=='inserter' or e.type=='lab') and not e.electric_network_id then result.unpowered[#result.unpowered+1]=p end
      end
    end
  end
  for _,p in ipairs(storage.starter.factory.parts) do if io.entity(bot,p) then result.starter_remaining=result.starter_remaining+1 end end
  for _,p in ipairs(s.depots or {}) do local e=io.entity(bot,p);if e then result.depots[#result.depots+1]={position=e.position,contents=e.get_inventory(defines.inventory.chest).get_contents()} end end
  for _,name in ipairs(technologies) do result.technologies[name]=bot.force.technologies[name].researched end
  result.boilers={count=0,empty_fuel=0,coal=0}
  result.boiler_supply={}
  result.water_route={present=0,expected=0,boilers_with_water=0}
  if s.routes.water and s.routes.water.parts then
    result.water_route.expected=#s.routes.water.parts
    for _,part in ipairs(s.routes.water.parts) do
      if io.entity(bot,part) then result.water_route.present=result.water_route.present+1 end
    end
  end
  if s.power then
    for _,part in ipairs(s.power.parts) do
      if part.name=='boiler' then
        local e=io.entity(bot,part)
        if e and (e.get_fluid_contents().water or 0)>0 then
          result.water_route.boilers_with_water=result.water_route.boilers_with_water+1
        end
      end
    end
  end
  for _,e in ipairs(bot.surface.find_entities_filtered{type='boiler',force=bot.force}) do
    local fuel=e.get_fuel_inventory()
    local supply={position=e.position,coal=fuel.get_item_count('coal'),burning=e.burner.currently_burning~=nil,
      fluids=e.get_fluid_contents(),feeders={}}
    for _,inserter in ipairs(bot.surface.find_entities_filtered{type='inserter',force=bot.force,position=e.position,radius=4}) do
      if inserter.drop_target==e then
        local pickup=inserter.pickup_target
        local belt=bot.surface.find_entities_filtered{position=inserter.pickup_position,
          type={'transport-belt','underground-belt','splitter'},limit=1}[1]
        pickup=pickup or belt
        local feeder={position=inserter.position,pickup=inserter.pickup_position,energy=inserter.energy,
          source=pickup and pickup.name}
        if belt then
          feeder.coal=belt.get_transport_line(1).get_item_count('coal')+belt.get_transport_line(2).get_item_count('coal')
        end
        supply.feeders[#supply.feeders+1]=feeder
      end
    end
    result.boiler_supply[#result.boiler_supply+1]=supply
    result.boilers.count=result.boilers.count+1
    result.boilers.coal=result.boilers.coal+fuel.get_item_count('coal')
    if fuel.is_empty() and not e.burner.currently_burning then
      result.boilers.empty_fuel=result.boilers.empty_fuel+1
    end
  end
  result.coal_routes={}
  for _,id in ipairs{'coal-to-boilers','coal-to-base'} do
    local route=s.routes[id]
    if route and route.parts then
      local present=0
      for _,part in ipairs(route.parts) do
        local entity=io.entity(bot,part)
        if entity and layout.matches(entity,part) then present=present+1 end
      end
      local endpoint=io.entity(bot,route.parts[#route.parts])
      local coal=0
      if endpoint then
        for lane=1,2 do coal=coal+endpoint.get_transport_line(lane).get_item_count('coal') end
      end
      result.coal_routes[id]={present=present,expected=#route.parts,endpoint_coal=coal}
    end
  end
  result.starter_science={}
  for _,p in ipairs(starter_parts(s)) do
    local e=io.entity(bot,p)
    if e and (e.type=='lab' or p.id==6 or p.id==39) then
      local recipe=e.type=='assembling-machine' and e.get_recipe()
      local input=e.get_inventory(e.type=='lab' and defines.inventory.lab_input or defines.inventory.crafter_input)
      local output=e.type=='assembling-machine' and e.get_output_inventory()
      result.starter_science[#result.starter_science+1]={name=e.name,recipe=recipe and recipe.name,
        network=e.electric_network_id,energy=e.energy,status=e.status,input=input and input.get_contents(),
        output=output and output.get_contents(),products=e.type=='assembling-machine' and e.products_finished or nil}
    end
  end
  return result
end
function campaign.start(args)
  assert(storage.starter and storage.starter.mode=='done','Сначала нужно завершить It Begins')
  local s=storage.campaign or init()
  assert(s.mode=='await_choice' or s.mode=='helper' or s.mode=='paused','Следующий этап уже начат')
  if args and args.trials then
    assert(args.test_mode==true or s.test_mode and s.mode=='paused','Варианты доступны в тестовой кампании')
    s.trials=args.trials
    if s.trials.strips then s.start_science_early=true end
  end
  if args and args.early_three~=nil then
    assert(s.test_mode and s.mode=='paused' and s.phase=='expand','Тест раннего старта доступен после чертежа 2')
    s.early_three=args.early_three
  end
  if args and args.expansion_kit~=nil then
    assert(s.test_mode and s.mode=='paused' and s.phase=='expand','Нужна тестовая точка после чертежа 2')
    s.expansion_kit=args.expansion_kit
    s.expansion_service_nearby=args.expansion_service_nearby==true
    s.expansion_craft_overlap=args.expansion_craft_overlap==true
  elseif s.expansion_kit==nil then
    s.expansion_kit=true
    s.expansion_service_nearby=true
  end
  if s.expansion_craft_overlap==nil then s.expansion_craft_overlap=s.expansion_kit end
  if args and args.stop_after then s.stop_after=args.stop_after end
  if args and args.iron_timing then
    assert(s.test_mode and s.mode=='paused' and s.phase=='five','Нужна тестовая точка перед чертежом 5')
    assert(args.iron_timing=='early' or args.iron_timing=='late','Неизвестный порядок расширения железа')
    s.iron_timing=args.iron_timing
  end
  if args and args.research_on_stall~=nil then
    assert(args.test_mode==true and s.mode=='await_choice','Нужен старт тестовой кампании')
    s.research_on_stall=args.research_on_stall
  end
  if args and args.prefer_boiler_belts~=nil then
    assert(s.test_mode and s.mode=='paused' and s.phase=='five','Нужна тестовая точка перед чертежом 5')
    s.prefer_boiler_belts=args.prefer_boiler_belts
  end
  if args and args.clearing_service~=nil then
    assert((args.test_mode==true and s.mode=='await_choice') or
      (s.test_mode and s.mode=='paused' and s.phase=='clearing'),'Нужна тестовая кампания до конца расчистки')
    s.clearing_service=args.clearing_service
  end
  if args and args.advance_craft~=nil then
    assert((args.test_mode==true and s.mode=='await_choice') or
      (s.test_mode and s.mode=='paused' and s.phase=='one'),'Нужна тестовая кампания до чертежа 1')
    s.advance_craft=args.advance_craft
  end
  if args and args.expand_after_five then
    assert(s.test_mode and s.mode=='paused' and s.blueprint==5,'Нужна остановленная тестовая база после чертежа 5')
    s.iron_only_expansion=args.expand_after_five=='iron'
    s.resume_mode='running'
    s.finished_tick=nil
    transition(s,'science_supply')
  end
  if args and args.coal_batch~=nil then
    assert(s.test_mode and s.mode=='paused' and (s.phase=='stone' or s.phase=='coal'),'Нужна тестовая точка до завершения угольного участка')
    s.coal_batch=args.coal_batch
    s.coal_focus=args.coal_focus==true
  elseif s.coal_focus==nil then
    s.coal_batch=true
    s.coal_focus=true
  end
  if args and args.prepare_labs~=nil then
    assert(s.test_mode and s.mode=='paused' and s.phase=='five','Нужна тестовая точка перед чертежом 5')
    s.prepare_labs=args.prepare_labs
  end
  if args and args.start_science_early~=nil then
    assert(s.test_mode and s.mode=='paused' and s.phase=='five','Нужна тестовая точка перед чертежом 5')
    s.start_science_early=args.start_science_early
  end
  if args and args.local_clearing~=nil then
    assert(args.test_mode==true and s.mode=='await_choice','Расчистка настраивается при старте тестовой кампании')
    s.local_clearing=args.local_clearing
  end
  if s.mode=='paused' then
    s.mode=s.resume_mode~='paused' and s.resume_mode or (s.site and 'running' or s.test_mode and 'select_site' or 'deliver_blueprint')
    s.route_error=nil;s.last_error=nil;s.repeated_failures={}
    for id,r in pairs(s.routes) do if r.search and r.search.failed then s.routes[id]=nil end end
    return campaign.status()
  end
  s.test_mode=args and args.test_mode==true
  s.mode=s.test_mode and 'select_site' or 'deliver_blueprint'
  s.action=s.test_mode and 'Выбираю место для всей базы' or 'Готовлю чертеж 1 в сундуке'
  return campaign.status()
end
function campaign.helper()
  local s=storage.campaign or init()
  if s.job then jobs.cancel{id=s.job};s.job=nil end
  s.mode='helper';s.action='Помощник: снабжаю It Begins и выполняю команды'
  return campaign.status()
end
function campaign.pause()
  local s=assert(storage.campaign,'Этап ещё не начат')
  if s.mode=='paused' then return campaign.status() end
  s.resume_mode=s.mode;s.mode='paused'
  if s.job then jobs.cancel{id=s.job};s.job=nil end
  return campaign.status()
end
local function reservations(s)
  local a={}
  if s.routes.water and s.routes.water.parts then
    for _,part in ipairs(s.routes.water.parts) do
      local x,y=part.position.x,part.position.y
      a[#a+1]={{x-.5,y-.5},{x+.5,y+.5}}
    end
  end
  if s.site then a[#a+1]=s.site.area end
  if s.power then a[#a+1]=s.power.area end
  local st=storage.starter
  if st and st.factory then a[#a+1]=layout.area(st.factory.parts) end
  if st and st.power then a[#a+1]=layout.area(st.power.parts) end
  return a
end
local function first_matches(bot,site)
  for _,p in ipairs(layout.parts('jump',1,site.origin,site.direction)) do
    local yes=false
    for _,e in ipairs(bot.surface.find_entities_filtered{position=p.position,radius=0.05,force=bot.force}) do
      if layout.matches(e,p) then yes=true;break end
    end
    if not yes then return false end
  end
  return true
end
function campaign.confirm(args)
  local s=assert(storage.campaign,'Нет предложения')
  assert(s.mode=='await_confirm','Сначала размести чертеж 1')
  if args and args.accept==false then s.rejected_site=s.site;s.site=nil;s.mode='await_placement';say('Переставь чертеж 1. После новой разметки попрошу подтвердить место.');return campaign.status() end
  local bot=companion.character()
  if not first_matches(bot,s.site) then s.site=nil;s.mode='await_placement';error('Разметка изменилась. Требуется новое подтверждение.') end
  local site,err=layout.check_site(bot,s.site.origin,s.site.direction,nil,true)
  assert(site,err)
  s.site=site;s.mode='running';s.started_tick=game.tick;transition(s,'planning')
  say('Расположение подтверждено. Начинаю Jump Start Base; It Begins продолжает работать.')
  return campaign.status()
end
local function research(bot,s)
  local force=bot.force
  local current=force.current_research
  local function next_tech(t,seen)
    if not t or t.researched or seen[t.name] then return end
    seen[t.name]=true
    for _,p in pairs(t.prerequisites) do if not p.researched then return next_tech(p,seen) end end
    return t
  end
  local building_turrets=s.phase=='expand' or s.phase=='three' or s.phase=='four'
  local critical=building_turrets and next_tech(force.technologies['gun-turret'],{})
  if current then
    if critical and current.name==s.optional_red and #force.research_queue==1 then
      force.research_queue={critical.name,current.name}
      if force.current_research and force.current_research.name==critical.name then
        journal.record{event='research_queued',technology=critical.name,mode=s.mode}
      end
    end
    return
  end
  for _,name in ipairs(technologies) do
    local t=next_tech(bot.force.technologies[name],{})
    if t and bot.force.add_research(t.name) then
      s.research=t.name
      journal.record{event='research_queued',technology=t.name,mode=s.mode}
      return
    end
  end
  if critical and force.add_research(critical.name) then
    s.research=critical.name
    journal.record{event='research_queued',technology=critical.name,mode=s.mode}
    return
  end
  if s.wait_recipe and bot.force.recipes[s.wait_recipe] and not bot.force.recipes[s.wait_recipe].enabled then
    for _,technology in pairs(bot.force.technologies) do
      for _,effect in pairs(technology.prototype.effects or {}) do
        if effect.type=='unlock-recipe' and effect.recipe==s.wait_recipe then
          local t=next_tech(technology,{})
          if t then bot.force.add_research(t.name);s.research=t.name end
          return
        end
      end
    end
  end
  local function red_only(t)
    if not t or t.researched or not t.enabled or #t.research_unit_ingredients==0 then return false end
    for _,ingredient in ipairs(t.research_unit_ingredients) do
      if ingredient.name~='automation-science-pack' then return false end
    end
    return true
  end
  local function queue_red(t)
    local next=next_tech(t,{})
    if red_only(next) and bot.force.add_research(next.name) then
      s.research=next.name
      s.optional_red=next.name
      journal.record{event='research_queued',technology=next.name,mode=s.mode}
      return true
    end
    return false
  end
  for _,name in ipairs(red_research) do
    if red_only(bot.force.technologies[name]) and queue_red(bot.force.technologies[name]) then return end
  end
  local remaining={}
  for name,t in pairs(bot.force.technologies) do
    if red_only(t) then remaining[#remaining+1]=name end
  end
  table.sort(remaining)
  for _,name in ipairs(remaining) do
    if queue_red(bot.force.technologies[name]) then return end
  end

end
local function researched(bot)
  for _,name in ipairs(technologies) do if not bot.force.technologies[name].researched then return false end end
  return true
end
local function ore_inlet(s,ore)
  return layout.world(s.site,{x=-0.5,y=ore=='iron-ore' and 19.5 or 8.5})
end
local function tile_key(position)
  return math.floor(position.x)..':'..math.floor(position.y)
end
local function mask(s,exclude_collector,exclude_route)
  local m={}
  if s.site then
    routes.mask(layout.parts('jump',5,s.site.origin,s.site.direction),m)
    for _,ore in ipairs{'iron-ore','copper-ore'} do m[tile_key(ore_inlet(s,ore))]=true end
  end
  if s.power then
    routes.mask(s.power.parts,m)
    if s.power.max_units and s.power.max_units>=5 then
      routes.mask(network.power_feed_parts(s.power),m)
    end
  end
  if s.stone then routes.mask(s.stone.parts,m) end
  for _,plan in pairs(s.plans) do
    routes.mask(mining.parts(plan,mining.goal(plan.ore)),m)
    if plan.collector and plan.ore~=exclude_collector then
      routes.mask(plan.collector,m)
      for _,parts in pairs(plan.feeders or {}) do routes.mask(parts,m) end
      if plan.outlet then m[math.floor(plan.outlet.x)..':'..math.floor(plan.outlet.y)]=true end
    end
  end
  for id,r in pairs(s.routes) do if id~=exclude_route and r.parts and (not exclude_collector or id:sub(1,#exclude_collector)~=exclude_collector) then routes.mask(r.parts,m) end end
  return m
end
local function plan_collector(bot,s,plan)
  if plan.outlet or plan.collector_version==2 then return true end
  local target=plan.ore=='iron-ore' and 30 or plan.ore=='copper-ore' and 14 or 10
  local _,exits=mining.parts(plan,target)
  local left,top,bottom=math.huge,math.huge,-math.huge
  for _,p in ipairs(exits) do left=math.min(left,p.x);top=math.min(top,p.y);bottom=math.max(bottom,p.y) end
  local reserved=mask(s,plan.ore)
  local owned={}
  for _,p in ipairs(plan.collector or {}) do owned[math.floor(p.position.x)..':'..math.floor(p.position.y)]=true end
  local function free(x,y)
    local k=math.floor(x)..':'..math.floor(y)
    if reserved[k] or bot.surface.get_tile(x,y).collides_with('water_tile') then return false end
    for _,e in ipairs(bot.surface.find_entities_filtered{area={{x-.35,y-.35},{x+.35,y+.35}}}) do
      if e.type~='resource' and e.type~='tree' and e.type~='item-entity' and e.type~='character' and not (owned[k] and e.name=='transport-belt' and e.force==bot.force) then return false end
    end
    return true
  end
  local candidates={}
  if plan.collector and plan.hub then candidates[#candidates+1]=plan.hub end
  for dy=0,10 do
    if plan.hub then candidates[#candidates+1]={x=plan.hub.x,y=top-2-dy} end
    for dx=0,16 do candidates[#candidates+1]={x=left-3-dx,y=top-2-dy} end
  end
  for _,p in ipairs(candidates) do
    local good=free(p.x+1,p.y) and free(p.x+2,p.y)
    if good then for y=p.y,bottom do if not free(p.x,y) then good=false;break end end end
    if good then
      local parts,keep={},{}
      for y=p.y,bottom do
        parts[#parts+1]={name='transport-belt',position={x=p.x,y=y},direction=y==p.y and 4 or 0}
        keep[p.x..':'..y]=true
      end
      plan.cleanup={}
      for _,oldpart in ipairs(plan.collector or {}) do if not keep[oldpart.position.x..':'..oldpart.position.y] then plan.cleanup[#plan.cleanup+1]=oldpart end end
      plan.hub=p;plan.collector=parts;plan.collector_version=2
      return true
    end
  end
  s.action='Нет свободного выхода с месторождения '..plan.ore
  return false
end
local function deliver_blueprint(bot,s)
  local st=storage.starter
  if not s.blueprint_chest then
    for _,e in ipairs(bot.surface.find_entities_filtered{type='container',position=st.factory.origin,radius=22,force=bot.force}) do
      -- Avoid taking over a production input/output chest.
      local used=false
      for _,p in ipairs(st.factory.parts) do if companion.distance(p.position,e.position)<0.1 then used=true end end
      if not used then s.blueprint_chest={name=e.name,position=e.position,direction=0};break end
    end
    if not s.blueprint_chest then
      local p=bot.surface.find_non_colliding_position('wooden-chest',{st.factory.origin.x-3,st.factory.origin.y+3},12,0.5,true)
      assert(p,'Нет места для сундука с чертежом')
      s.blueprint_chest={name='wooden-chest',position=p,direction=0}
    end
  end
  if not io.build(bot,s,{s.blueprint_chest}) then return end
  local p=s.blueprint_chest
  if not s.gift_job then
    io.task(s,'blueprint_gift',{entity=p.name,x=p.position.x,y=p.position.y},'Кладу чертеж 1 в сундук')
    s.gift_job=s.job;return
  end
  local j=storage.jobs[s.gift_job]
  if not j or j.status~='done' then s.gift_job=nil;return end
  s.mode='await_placement'
  bot.force.add_chart_tag(bot.surface,{position=p.position,text='Jump Start Base: чертеж 1',icon={type='item',name='blueprint'}})
  say(('Чертеж 1 в сундуке [gps=%.1f,%.1f]. Размести его, задав направление главной шины. После размещения я отдельно спрошу подтверждение.'):format(p.position.x,p.position.y))
end
local function boiler_inlet(s)
  return network.power_position(s.power,{x=3*(s.power.max_units or 20)+3.5,y=12.5})
end
local function mine_outlet(plan)
  return plan.outlet or {x=plan.hub.x+1,y=plan.hub.y}
end
local function trunk_mask(s,ore)
  local m=mask(s)
  if s.plans[ore].outlet then
    for _,plan in pairs(s.plans) do
      for cell in pairs(plan.patch.cells) do m[cell]=true end
    end
    local stone=s.searches.stone and s.searches.stone.patch
    for cell in pairs(stone and stone.cells or {}) do m[cell]=true end
  end
  return m
end
local function clear_planned_sites(bot,s)
  local trees={}
  for _,area in ipairs{s.site.area,s.power.area} do
    for _,tree in ipairs(bot.surface.find_entities_filtered{type='tree',area=area}) do trees[#trees+1]=tree end
  end
  table.sort(trees,function(a,b) return companion.distance(bot.position,a.position)<companion.distance(bot.position,b.position) end)
  for _,tree in ipairs(trees) do if io.recover(s,tree) then return false end end
  return #trees==0
end
local function plan(bot,s)
  if not s.power then
    local p,err=network.power_site(bot,s,reservations(s))
    if p then
      s.power=p
      if p.integrated then s.prefer_boiler_belts=true end
    elseif err then s.action=err end
    return
  end
  if not bot.force.technologies['electric-mining-drill'].researched or not bot.force.technologies.logistics.researched then
    s.action='Исследую электрические буры и логистику; готовлю запас для строительства'
    local trial=s.trials and s.trials.planning
    if trial then
      if io.service_research(bot,s) then return end
      if not clear_planned_sites(bot,s) then return end
    elseif io.service(bot,s,false) then return end
    for _,cargo in ipairs{{'iron-plate',300},{'copper-plate',120},{'coal',100},{'stone-furnace',20},{'small-electric-pole',16},{'transport-belt',100}} do
      if io.have(bot,cargo[1])<cargo[2] then io.ensure(bot,s,cargo[1],cargo[2]);return end
    end
    return
  end
  for _,ore in ipairs{'coal','iron-ore','copper-ore'} do
    if not s.plans[ore] then
      s.searches[ore]=s.searches[ore] or {home=s.home}
      local search=s.searches[ore]
      search.collector_mask=search.collector_mask or mask(s)
      local destination=ore=='coal' and boiler_inlet(s) or ore_inlet(s,ore)
      local p,err=mining.plan(bot,search,ore,reservations(s),destination,search.collector_mask)
      if p then
        s.plans[ore]=p
        s.searches[ore]=nil
        local desired=mining.goal(ore)
        if p.capacity<desired then say(ore..': на стартовом участке помещается '..p.capacity..' из '..desired..' буров. Использую доступные места.') end
      elseif err then s.action=err;s.last_error=err end
      return
    end
  end
  if not s.stone then
    s.searches.stone=s.searches.stone or {home=s.home}
    local p,err=mining.stone(bot,s.searches.stone,reservations(s))
    if p then s.stone=p elseif err then s.last_error=err;s.action=err end
    return
  end
  for _,ore in ipairs{'coal','iron-ore','copper-ore'} do if not plan_collector(bot,s,s.plans[ore]) then return end end
  transition(s,s.local_clearing and 'power' or 'clearing')
end
local function power(bot,s,n)
  for _,p in ipairs(s.power.relocate_poles or {}) do
    local pole=io.entity(bot,p)
    if pole then io.recover(s,pole);return false end
  end
  s.power.relocate_poles=nil
  local parts=network.power_parts(s.power,n)
  if s.power.feed_chest and io.entity(bot,s.power.feed_chest) then
    for i,p in ipairs(parts) do if p==s.power.feed_belt then table.remove(parts,i);break end end
  end
  if not io.build(bot,s,parts) then return false end
  if not s.power.integrated then
    local water=network.power_position(s.power,{x=-0.5,y=10.5})
    local source=storage.starter.power.parts[2].position
    local water_mask=mask(s,nil,'water')
    network.reserve_steam_ports(storage.starter.power.parts,water_mask)
    network.reserve_steam_ports(s.power.parts,water_mask)
    if not network.route(bot,s,'water',source,water,'pipe',0,water_mask) then return false end
  end
  if not network.connect(bot,s,parts,mask(s)) then return false end
  for _,p in ipairs(parts) do if p.name=='boiler' then
    local e=io.entity(bot,p)
    if (e.get_fluid_contents().water or 0)<=0 then
      s.action='Жду поступления воды в бойлер'
      return false
    end
    if e.get_fuel_inventory().get_item_count()<4 and io.boiler_needs_manual_fuel(s,e) then
      if io.have(bot,'coal')>0 then io.transfer(s,e,'fuel','put','coal',math.min(12,io.have(bot,'coal')))
      else io.ensure(bot,s,'coal',48) end
      return false
    end
  end end
  return true
end
local function finish_station(bot,s)
  if s.final_power_ready or not s.power.max_units or s.power.max_units<5 then return true end
  if not power(bot,s,5) then return false end
  local position=network.power_position(s.power,{x=13.5,y=10})
  local boiler=io.entity(bot,{name='boiler',position=position})
  if boiler.get_fuel_inventory().get_item_count('coal')==0 and not boiler.burner.currently_burning then
    s.action='Жду уголь с ленты для пятого бойлера'
    return false
  end
  s.final_power_ready=true
  journal.record{event='power_expanded',boilers=5}
  return true
end
local function mine(bot,s,ore,n)
  local plan=s.plans[ore]
  if not plan_collector(bot,s,plan) then return false end
  for _,p in ipairs(plan.cleanup or {}) do local e=io.entity(bot,p);if e then io.recover(s,e);return false end end
  plan.cleanup=nil
  local parts,exits=mining.parts(plan,n)
  -- These recipes use copper. Have them ready before replacing the
  -- starter copper pairs, while their furnaces can still make plates.
  if ore=='copper-ore' and plan.feeders then
    local missing={['splitter']=0,['electric-mining-drill']=0}
    for _,p in ipairs(plan.collector) do
      if p.name=='splitter' and not io.entity(bot,p) then missing.splitter=missing.splitter+1 end
    end
    for _,p in ipairs(parts) do
      if p.name=='electric-mining-drill' and not io.entity(bot,p) then
        missing[p.name]=missing[p.name]+1
      end
    end
    for _,item in ipairs{'splitter','electric-mining-drill'} do
      if not io.ensure(bot,s,item,missing[item]) then return false end
    end
  end
  local target=math.min(n,plan.capacity)
  local early_coal=ore=='coal' and s.phase=='coal' and s.coal_focus and not plan.start_batch_ready
  local copper_stage=s.phase=='copper' and s.trials and s.trials.copper
  local expansion=(s.phase=='expand' and s.expansion_kit or copper_stage) and plan.target~=target
  if early_coal or (expansion and s.deploying_mine~=ore) then
    local kit={}
    for _,part in ipairs(parts) do kit[#kit+1]=part end
    for _,part in ipairs(plan.collector) do kit[#kit+1]=part end
    for _,exit in ipairs(exits) do
      for _,part in ipairs(plan.feeders and plan.feeders[exit.y] or {}) do kit[#kit+1]=part end
    end
    local stream_drills=expansion and s.expansion_craft_overlap and ore~='copper-ore'
    local items=stream_drills and {'splitter','underground-belt','transport-belt','small-electric-pole','electric-mining-drill'} or
      {'electric-mining-drill','splitter','underground-belt','transport-belt','small-electric-pole'}
    if not io.stock_parts(bot,s,kit,items,stream_drills) then
      return false
    end
    if early_coal then
      plan.start_batch_ready=true
    else
      s.deploying_mine=ore
      journal.record{event='mining_kit_ready',ore=ore,target=target,
        queued_drills=stream_drills and io.queued_drills(bot) or nil}
    end
  end
  if not io.build(bot,s,parts) then return false end
  if not network.connect(bot,s,parts,mask(s)) then return false end
  if not io.build(bot,s,plan.collector) then return false end
  for _,p in ipairs(exits) do
    if plan.feeders then
      if not io.build(bot,s,plan.feeders[p.y]) then return false end
    elseif not network.route(bot,s,ore..':'..p.y,{x=p.x-1,y=p.y},{x=plan.hub.x,y=p.y},'belt',0,mask(s)) then
      return false
    end
  end
  plan.target=target
  if s.deploying_mine==ore then s.deploying_mine=nil end
  return true
end
local function coal_feed(bot,s)
  local site=s.power
  local edge=3*(site.max_units or 20)
  local direction=network.power_direction(site,12)
  local parts=network.power_feed_parts(site)
  if not io.build(bot,s,parts) then return false end
  if not network.route(bot,s,'coal-to-boilers',mine_outlet(s.plans.coal),boiler_inlet(s),'belt',direction,trunk_mask(s,'coal')) then return false end
  if site.feed_chest then
    local chest=io.entity(bot,site.feed_chest)
    if chest then io.recover(s,chest);return false end
    if not io.build(bot,s,{site.feed_belt}) then return false end
  end
  s.coal_line_online=true
  local stub={}
  for x=-0.5,2.5 do stub[#stub+1]={name='transport-belt',position=layout.world(s.site,{x=x,y=0.5}),direction=(s.site.direction+4)%16} end
  if not io.build(bot,s,stub) then return false end
  return network.route(bot,s,'coal-to-base',network.power_position(site,{x=edge+1.5,y=13.5}),stub[1].position,'belt',(s.site.direction+4)%16,trunk_mask(s,'coal'))
end
local function ore_feed(bot,s,ore)
  return network.route(bot,s,ore..'-to-base',mine_outlet(s.plans[ore]),ore_inlet(s,ore),'belt',(s.site.direction+4)%16,trunk_mask(s,ore))
end
-- Older plans can occupy the approach tiles just outside the blueprint.
-- Keep the ore inputs and take the existing coal line under them.
local function repair_coal_crossings(bot,s)
  local route=s.routes['coal-to-base']
  if not route or not route.parts or route.inlets_checked then return true end
  local crossings={}
  for _,ore in ipairs{'iron-ore','copper-ore'} do crossings[tile_key(ore_inlet(s,ore))]=true end
  for i,p in ipairs(route.parts) do
    if crossings[tile_key(p.position)] then
      local before,after=route.parts[i-1],route.parts[i+1]
      local next_tile=layout.world({origin=p.position,direction=p.direction},{x=0,y=-1})
      local reserved=mask(s,nil,'coal-to-base')
      if not before or not after or before.name~='transport-belt' or after.name~='transport-belt' or
          before.direction~=p.direction or after.direction~=p.direction or
          tile_key(after.position)~=tile_key(next_tile) or
          reserved[tile_key(before.position)] or reserved[tile_key(after.position)] then
        s.action='Нужно перенаправить угольную ленту у входа руды'
        s.route_error='coal-to-base'
        return false
      end
      local ends={
        {name='underground-belt',position=before.position,direction=p.direction,type='input'},
        {name='underground-belt',position=after.position,direction=p.direction,type='output'},
      }
      for _,old_part in ipairs{before,after} do
        local e=io.entity(bot,old_part)
        if e then io.recover(s,e);return false end
      end
      if not io.build(bot,s,ends) then return false end
      if io.entity(bot,ends[1]).underground_belt_neighbour~=io.entity(bot,ends[2]) then
        s.action='Подземная угольная лента не соединилась'
        s.route_error='coal-to-base'
        return false
      end
      route.parts[i-1],route.parts[i+1]=ends[1],ends[2]
      table.remove(route.parts,i)
      return false
    end
  end
  route.inlets_checked=true
  return true
end
local function feed_research(bot,s,lab,technology)
  local inv=lab.get_inventory(defines.inventory.lab_input)
  for _,ingredient in pairs(technology.research_unit_ingredients) do
    if inv.get_item_count(ingredient.name)<5 then
      local amount=math.max(5,math.min(20,technology.research_unit_count*ingredient.amount))
      if io.have(bot,ingredient.name)>0 then
        io.transfer(s,lab,'lab','put',ingredient.name,math.min(amount,io.have(bot,ingredient.name)))
      else
        io.ensure(bot,s,ingredient.name,amount)
      end
      return s.job~=nil
    end
  end
  return false
end
local function research_needs_delivery(bot,s,technology)
  if s.optional_red==technology.name or io.starter_science_running(bot,s) then return false end
  if not s.research_on_stall then return true end
  local progress=bot.force.research_progress
  local watch=s.research_watch
  if not watch or watch.name~=technology.name or watch.progress~=progress then
    s.research_watch={name=technology.name,progress=progress,tick=game.tick}
    return false
  end
  return game.tick-watch.tick>=20*60
end
local function support_research(bot,s)
  local technology=bot.force.current_research
  if not technology then return end
  local labs=bot.surface.find_entities_filtered{type='lab',force=bot.force}
  if #labs==0 then
    if not s.temporary_lab then
      for _,p in ipairs(storage.starter.factory.parts) do
        if p.name=='lab' then s.temporary_lab={name='lab',position=p.position,direction=p.direction};break end
      end
    end
    if not s.temporary_lab then s.action='Не найдена площадка временной лаборатории';return end
    if not io.build(bot,s,{s.temporary_lab}) then return end
    labs={io.entity(bot,s.temporary_lab)}
  end
  local lab=labs[1]
  if not network.connect(bot,s,{{name='lab',position=lab.position,direction=lab.direction}},mask(s)) then return end
  if lab.energy<1 then
    for _,p in ipairs(s.power.parts) do
      if p.name=='boiler' then
        local boiler=io.entity(bot,p)
        if boiler and boiler.get_fuel_inventory().get_item_count()<8 and io.boiler_needs_manual_fuel(s,boiler) then
          if io.have(bot,'coal')>0 then io.transfer(s,boiler,'fuel','put','coal',math.min(50,io.have(bot,'coal')))
          else io.ensure(bot,s,'coal',60) end
          return
        end
      end
    end
  end
  if not io.starter_science_running(bot,s) then feed_research(bot,s,lab,technology) end
end
local function start_science(bot,s,parts)
  s.primed_science=s.primed_science or {}
  s.science_targets=s.science_targets or {}
  for _,recipe in ipairs{'automation-science-pack','logistic-science-pack'} do
    if not s.primed_science[recipe] then
      local target=s.science_targets[recipe]
      if not target then
        for _,p in ipairs(parts) do
          if p.recipe==recipe and (not target or companion.distance(bot.position,p.position)<companion.distance(bot.position,target.position)) then
            target=p
          end
        end
        s.science_targets[recipe]=target
      end
      if not io.build(bot,s,{target}) or not network.connect(bot,s,{target},mask(s)) then return false end
      local machine=io.entity(bot,target)
      local input=jobs.input_inventory(machine)
      if machine.products_finished==0 then
        for _,ingredient in ipairs(bot.force.recipes[recipe].ingredients) do
          local need=ingredient.amount-input.get_item_count(ingredient.name)
          if need>0 then
            if io.have(bot,ingredient.name)>=need then
              io.transfer(s,machine,'input','put',ingredient.name,need)
            else
              io.ensure(bot,s,ingredient.name,need)
            end
            return false
          end
        end
      end
      s.primed_science[recipe]=true
    end
  end
  return true
end
local function precraft_labs(bot,s)
  if s.phase~='four' or s.prepare_labs==false or s.iron_timing or bot.crafting_queue_size>0 then return end
  local wanted=0
  for _,part in ipairs(assets.jump[5].entities) do if part.name=='lab' then wanted=wanted+1 end end
  for _,part in ipairs(starter_parts(s)) do
    if part.name=='lab' and io.entity(bot,part) then wanted=wanted-1 end
  end
  local iron=math.max(0,io.have(bot,'iron-plate')-64)
  local copper=math.max(0,io.have(bot,'copper-plate')-32)
  local has_components=io.have(bot,'iron-gear-wheel')>=10 and
    io.have(bot,'electronic-circuit')>=10 and io.have(bot,'transport-belt')>=32
  local free=math.max(has_components and 1 or 0,math.min(math.floor(iron/36),math.floor(copper/15)))
  local n=math.min(4,wanted-io.have(bot,'lab'),free,bot.get_craftable_count('lab'))
  if n>0 then journal.craft(bot,{recipe='lab',count=n,silent=true}) end
end

local function jump(bot,s,n)
  if n>=3 and not repair_coal_crossings(bot,s) then return false end
  local parts=layout.parts('jump',n,s.site.origin,s.site.direction)
  if n==5 and s.start_science_early and not start_science(bot,s,parts) then return false end
  if n==5 and s.iron_timing=='early' and s.iron_expansion_started and not s.iron_expansion_done then
    if not mine(bot,s,'iron-ore',30) then return false end
    s.iron_expansion_done=true
    journal.record{event='iron_timing_finished',target=s.plans['iron-ore'].target}
  end
  if n==5 and s.prepare_labs~=false and not s.labs_prepared then
    local wanted=0
    for _,part in ipairs(parts) do
      if part.name=='lab' and not io.entity(bot,part) then wanted=wanted+1 end
    end
    local missing=wanted-io.have(bot,'lab')
    if missing<=0 then
      s.labs_prepared=true
    elseif bot.crafting_queue_size==0 then
      local craftable=bot.get_craftable_count('lab')
      if craftable>0 then
        -- Hand crafting continues during the next construction job.
        local queued=journal.craft(bot,{recipe='lab',count=math.min(missing,craftable),silent=true})
        if queued>0 and s.iron_timing=='early' and not s.iron_expansion_started then
          s.iron_expansion_started=true
          journal.record{event='iron_timing_started',labs_queued=queued}
          return false
        end
      else
        io.ensure(bot,s,'lab',wanted)
        if s.job then return false end
      end
    end
  end
  if n>=4 and not s.poles_moved then
    local next_set={}
    for _,p in ipairs(parts) do next_set[p.name..':'..p.position.x..':'..p.position.y]=true end
    for _,p in ipairs(layout.parts('jump',3,s.site.origin,s.site.direction)) do
      if p.name=='small-electric-pole' and not next_set[p.name..':'..p.position.x..':'..p.position.y] then
        local e=io.entity(bot,p);if e then io.recover(s,e);return false end
      end
    end
    s.poles_moved=true
  end
  if n==5 and s.prepare_labs~=false and not s.five_non_labs_done then
    if not s.five_non_labs then
      s.five_non_labs={}
      for _,part in ipairs(parts) do
        if part.name~='lab' then s.five_non_labs[#s.five_non_labs+1]=part end
      end
    end
    if not io.build(bot,s,s.five_non_labs,s.trials and s.trials.strips) then return false end
    s.five_non_labs=nil
    s.five_non_labs_done=true
  end
  if n==5 and s.prepare_labs~=false and not s.labs_prepared then return false end
  if not io.build(bot,s,parts) then return false end
  for _,p in ipairs(parts) do
    if p.recipe and not bot.force.recipes[p.recipe].enabled then
      s.wait_recipe=p.recipe;s.action='Жду исследование рецепта '..p.recipe;support_research(bot,s);return false
    end
  end
  s.wait_recipe=nil
  if not network.connect(bot,s,parts,mask(s)) then return false end
  local by_id={}
  for _,p in ipairs(parts) do by_id[p.source_id]=p end
  for _,w in ipairs(assets.jump[n].wires or {}) do
    if w[2]~=5 then
      local a,b=by_id[w[1]],by_id[w[3]]
      local first=io.entity(bot,a).get_wire_connector(w[2],true)
      local second=io.entity(bot,b).get_wire_connector(w[4],true)
      if not first.is_connected_to(second) then
        io.task(s,'wire',{entity=a.name,x=a.position.x,y=a.position.y,connector=w[2],other=b.name,position=b.position,other_connector=w[4]},'Соединяю схему ограничения выпуска')
        return false
      end
    end
  end
  s.blueprint=n
  return true
end
local function retire(bot,s)
  if s.retired then return true end
  if not researched(bot) then s.action='Жду электрические буры, логистику и зелёную науку перед разбором It Begins';return false end
  -- Dismantle only the recorded starter, never arbitrary nearby player buildings.
  for _,p in ipairs(storage.starter.factory.parts) do
    local e=not starter_science_ids[p.id] and io.entity(bot,p)
    if e then io.recover(s,e);return false end
  end
  s.retired=true;s.starter_science=true;s.network_pending=true
  return true
end
local function finish_starter_retirement(bot,s)
  if s.starter_recovered then return true end
  s.starter_science=false
  for _,p in ipairs(storage.starter.factory.parts) do
    local entity=io.entity(bot,p)
    if entity then io.recover(s,entity);return false end
  end
  s.starter_recovered=true
  return true
end
local function verify(bot,s)
  local red,green=false,false
  for _,p in ipairs(layout.parts('jump',5,s.site.origin,s.site.direction)) do
    if p.recipe=='automation-science-pack' or p.recipe=='logistic-science-pack' then
      local e=io.entity(bot,p)
      if e and e.products_finished>0 then
        if p.recipe=='automation-science-pack' then red=true else green=true end
      end
    end
  end
  if red and green then
    s.finished_tick=game.tick;s.mode='done';transition(s,'done')
    say('Jump Start Base построена. Выпуск красной и зелёной науки подтверждён. Перехожу в режим помощника.')
  else s.action='Проверяю выпуск науки: красная '..tostring(red)..', зелёная '..tostring(green) end
end
local function decide(bot,s)
  if s.mode=='deliver_blueprint' then deliver_blueprint(bot,s);return end
  if s.mode=='select_site' then
    local site,err=layout.find_site(bot,s,reservations(s))
    if site then s.site=site;s.mode='running';s.started_tick=game.tick;transition(s,'planning')
    elseif err then s.action=err end
    return
  end
  if s.mode=='await_placement' then
    local site=layout.match_first(bot,s.home)
    if site and s.rejected_site and site.direction==s.rejected_site.direction and companion.distance(site.origin,s.rejected_site.origin)<0.1 then return end
    if site then
      local checked,err=layout.check_site(bot,site.origin,site.direction,nil,true)
      if checked then
        s.site=checked;s.mode='await_confirm'
        say(('Чертеж 1 размещён в %.1f, %.1f. Уверен в расположении и направлении? /companion подтверждаю или /companion другое место.'):format(site.origin.x,site.origin.y))
      else s.action=err end
    end
    return
  end
  if s.mode~='running' then return end
  research(bot,s)
  local technology=bot.force.current_research
  if not technology then s.research_watch=nil end
  if technology and research_needs_delivery(bot,s,technology) then
    for _,part in ipairs(starter_parts(s)) do
      if part.name=='lab' then
        local lab=io.entity(bot,part)
        if lab then
          if s.research_on_stall and lab.energy<1 then
            if io.service_starter_power(bot,s) then return end
          elseif feed_research(bot,s,lab,technology) then return end
        end
      end
    end
  end
  local rebuilding_power=s.power and s.power.integrated and s.phase=='power'
  if s.power and not rebuilding_power and (s.network_pending or game.tick>=(s.next_network_check or 0)) and
      s.phase~='planning' and s.phase~='clearing' then
    s.network_pending=true
    local groups={storage.starter.power.parts}
    groups[#groups+1]=starter_parts(s)
    if s.stone then groups[#groups+1]=s.stone.parts end
    for _,ore in ipairs{'coal','iron-ore','copper-ore'} do
      local p=s.plans[ore]
      if p and p.target and p.target>0 then groups[#groups+1]=mining.parts(p,p.target) end
    end
    for _,parts in ipairs(groups) do if not network.connect(bot,s,parts,mask(s)) then return end end
    s.network_pending=nil;s.next_network_check=game.tick+1800
  end
  if s.phase=='planning' then plan(bot,s)
  elseif s.phase=='clearing' then
    if clear_planned_sites(bot,s) then
      transition(s,'power')
      if s.stop_after=='clearing' then s.mode='paused';s.resume_mode='running';s.action='Расчистка завершена.' end
    end
  elseif s.phase=='power' then if power(bot,s,2) then transition(s,'stone') end
  elseif s.phase=='stone' then
    if io.build(bot,s,s.stone.parts) and network.connect(bot,s,s.stone.parts,mask(s)) then
      transition(s,'coal')
      if s.stop_after=='stone' then
        s.mode='paused';s.resume_mode='running';s.action='Каменный участок готов. Контрольная остановка перед углём.'
      end
    end
  elseif s.phase=='coal' then if mine(bot,s,'coal',4) and coal_feed(bot,s) then
    transition(s,'iron')
    if s.stop_after=='coal' then s.mode='paused';s.resume_mode='running';s.action='Угольная линия построена.' end
  end
  elseif s.phase=='iron' then
    if not s.iron_buffer_ready then
      local pairs=old.units(bot,storage.starter,'iron-ore','stone-furnace')
      local wanted=#pairs>=4 and math.min(300,60+#pairs*20) or 0
      if not io.ensure(bot,s,'iron-plate',wanted) then return end
      s.iron_buffer_ready=true
    end
    if mine(bot,s,'iron-ore',4) and ore_feed(bot,s,'iron-ore') then
    transition(s,'one')
    if s.stop_after=='iron' then s.mode='paused';s.resume_mode='running';s.action='Готов к строительству чертежа 1.' end
  end
  elseif s.phase=='one' then if jump(bot,s,1) then
    transition(s,'copper')
    if s.stop_after=='one' then s.mode='paused';s.resume_mode='running';s.action='Чертеж 1 завершён.' end
  end
  elseif s.phase=='copper' then
    if power(bot,s,4) and mine(bot,s,'iron-ore',12) and mine(bot,s,'copper-ore',6) and ore_feed(bot,s,'copper-ore') then transition(s,'two') end
  elseif s.phase=='two' then
    if s.trials and s.trials.components and io.collect_stage_two_components(bot,s) then return end
    if jump(bot,s,2) then
    transition(s,'expand')
    if s.stop_after=='two' then s.mode='paused';s.resume_mode='running';s.action='Чертеж 2 завершён.' end
  end
  elseif s.phase=='expand' then
    if s.early_three or (power(bot,s,s.power.max_units and 4 or 8) and mine(bot,s,'coal',10) and mine(bot,s,'iron-ore',30) and mine(bot,s,'copper-ore',14)) then
      transition(s,'three')
    end
  elseif s.phase=='three' then if retire(bot,s) and jump(bot,s,3) then
    transition(s,'four')
    if s.stop_after=='three' then s.mode='paused';s.resume_mode='running';s.action='Чертеж 3 завершён. Контрольная остановка перед 4.' end
  end
  elseif s.phase=='four' then if jump(bot,s,4) then
    transition(s,'five')
    if s.stop_after=='four' then s.mode='paused';s.resume_mode='running';s.action='Чертеж 4 завершён. Контрольная остановка перед 5.' end
  end
  elseif s.phase=='five' then if finish_station(bot,s) and finish_starter_retirement(bot,s) and jump(bot,s,5) then
    if s.iron_timing and not s.iron_expansion_done then
      journal.record{event='iron_timing_started'}
      transition(s,'iron_after_five')
    else transition(s,'verify') end
  end
  elseif s.phase=='iron_after_five' then
    if mine(bot,s,'iron-ore',30) then
      s.iron_expansion_done=true
      journal.record{event='iron_timing_finished',target=s.plans['iron-ore'].target}
      transition(s,'verify')
    end
  elseif s.phase=='science_supply' then
    if (s.iron_only_expansion or mine(bot,s,'coal',10)) and mine(bot,s,'iron-ore',30) then
      s.mode='paused';s.resume_mode='running';transition(s,'verify')
    end
  elseif s.phase=='verify' then verify(bot,s) end
end
local expansion_next_ore={coal='iron-ore',['iron-ore']='copper-ore'}
local function precraft_expansion(bot,s,job)
  if s.phase~='expand' or not s.expansion_craft_overlap or not job or not job.automatic or
      not bot.walking_state.walking or bot.crafting_queue_size>0 then return end
  local next_ore=expansion_next_ore[s.deploying_mine]
  local plan=next_ore and s.plans[next_ore]
  if not plan then return end
  local missing=math.min(plan.capacity,mining.goal(next_ore))-(plan.target or 0)-io.have(bot,'electric-mining-drill')
  if missing<=0 then return end
  local count=math.min(6,missing,bot.get_craftable_count('electric-mining-drill'))
  if count>0 then journal.craft(bot,{recipe='electric-mining-drill',count=count,silent=true}) end
end
function campaign.tick()
  if game.tick%6~=0 then return end
  if not storage.starter or storage.starter.mode~='done' then return end
  local s=storage.campaign or init()
  if s.mode=='paused' then return end
  local bot=storage.bot
  if not bot or not bot.valid then s.resume_mode=s.mode;s.mode='paused';s.last_error='Sam отсутствует или погиб';return end
  local ok,err=pcall(function()
    if s.mode=='running' or s.mode=='select_site' or s.mode=='deliver_blueprint' or
        s.mode=='await_placement' or s.mode=='await_confirm' then
      research(bot,s)
    end
    if game.tick%60==0 and storage.active then
      local job=storage.jobs[storage.active]
      io.on_walk(bot,s,job)
      if s.mode=='running' then
        precraft_labs(bot,s)
        precraft_expansion(bot,s,job)
      end
    end
    if io.poll(s) or s.mode=='paused' or storage.active or #storage.queue>0 then return end
    if io.unload(bot,s) then return end
    local local_service=s.phase=='clearing' and s.clearing_service or s.phase=='coal' and s.coal_focus or
      s.phase=='expand' and s.expansion_kit and (s.expansion_service_nearby or s.deploying_mine) or
      s.trials and (s.phase=='planning' and s.trials.planning or s.phase=='copper' and s.trials.copper)
    if s.mode=='running' and local_service then
      if game.tick>=(s.next_local_service or 0) then
        s.next_local_service=game.tick+120
        if io.service_starter_power(bot,s) or io.service(bot,s,true) then return end
      end
      decide(bot,s)
      return
    end
    local waiting=s.mode=='helper' or s.mode=='await_choice' or s.mode=='await_placement' or s.mode=='await_confirm' or s.mode=='done'
    if not waiting then s.service_budget=math.min(s.service_budget or 0,2) end
    if game.tick>=(s.next_service or 0) then s.service_budget=waiting and 10 or 2;s.next_service=game.tick+1800 end
    if s.service_budget>0 then
      s.service_budget=s.service_budget-1
      if io.service(bot,s,false) then return end
    elseif game.tick%120==0 and io.service(bot,s,true) then return end
    decide(bot,s)
    if not s.job then
      s.metrics.idle_ticks=s.metrics.idle_ticks+6
      if game.tick%120==0 then io.service(bot,s,false) end
    end
  end)
  if not ok then s.last_error=tostring(err);s.resume_mode=s.mode;s.mode='paused';say('Этап приостановлен: '..s.last_error) end
end
return campaign
