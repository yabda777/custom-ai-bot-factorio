local companion=require('character')
local jobs=require('jobs')
local starter=require('starter')
local layout=require('campaign_layout')
local old=require('starter_layout')
local io={}
local journal=require('action_journal')
function io.have(bot,item) return bot.get_main_inventory().get_item_count(item) end
function io.entity(bot,p)
  for _,e in ipairs(bot.surface.find_entities_filtered{position=p.position,radius=0.05,name=p.name,force=bot.force}) do
    if e.type~='entity-ghost' then return e end
  end
end
function io.task(s,kind,args,label)
  local key=kind..':'..(args.entity or args.name or '')..':'..tostring(args.x)..':'..tostring(args.y)
  if s.avoid[key] and s.avoid[key]>game.tick then return false end
  s.job=jobs.enqueue{kind=kind,args=args,automatic=true}.id
  s.job_key=key;s.action=label or kind
  return true
end
function io.transfer(s,e,slot,mode,item,n,extra)
  if n<1 then return false end
  local a={x=e.position.x,y=e.position.y,entity=e.name,inventory=slot,mode=mode,name=item,count=math.min(1000,n)}
  for k,v in pairs(extra or {}) do a[k]=v end
  return io.task(s,'transfer',a,(mode=='take' and 'Собираю ' or 'Загружаю ')..item)
end
function io.poll(s)
  if not s.job then return false end
  local j=storage.jobs[s.job]
  if j and (j.status=='queued' or j.status=='running') then return true end
  if j then
    s.metrics.jobs=s.metrics.jobs+1
    s.metrics.repaths=s.metrics.repaths+(j.total_repaths or 0)
    s.metrics.travel_ticks=s.metrics.travel_ticks+(j.travel_ticks or 0)
    if j.status=='failed' then
      s.last_error=j.detail;s.metrics.failures=s.metrics.failures+1
      if s.job_key then s.avoid[s.job_key]=game.tick+600 end
      s.failure_log[#s.failure_log+1]={tick=game.tick,kind=j.kind,args=j.args,error=j.detail}
      if #s.failure_log>30 then table.remove(s.failure_log,1) end
      s.repeated_failures=s.repeated_failures or {}
      if s.job_key then
        s.repeated_failures[s.job_key]=(s.repeated_failures[s.job_key] or 0)+1
        if s.repeated_failures[s.job_key]>=4 then
          s.resume_mode=s.mode;s.mode='paused'
          s.action='Повторная ошибка '..j.kind..': '..j.detail
          game.print('[Sam] '..s.action..' ('..tostring(j.args.x)..', '..tostring(j.args.y)..'). План приостановлен.')
        end
      end
    elseif j.status=='done' and s.repeated_failures and s.job_key then
      s.repeated_failures[s.job_key]=nil
    end
  end
  s.job,s.job_key=nil,nil
  return false
end
local function near(bot,s,types)
  local result=bot.surface.find_entities_filtered{type=types,force=bot.force,position=s.home,radius=480}
  table.sort(result,function(a,b) return companion.distance(bot.position,a.position)<companion.distance(bot.position,b.position) end)
  return result
end
local belt_input_id=27
local belt_iron_low=50
local belt_iron_target=200
local construction_iron_reserve=64
local function protected_chest(e,item)
  local st=storage.starter
  if not st or not st.factory then return 0 end
  local inputs={[23]=true,[27]=true,[32]=true,[37]=true}
  for _,p in ipairs(st.boiler_feed or {}) do
    if p.name=='wooden-chest' and companion.distance(p.position,e.position)<0.1 then return math.huge end
  end
  for _,p in ipairs(st.factory.parts) do
    if inputs[p.id] and companion.distance(p.position,e.position)<0.1 then
      return p.id==belt_input_id and item=='iron-plate' and belt_iron_target or 16
    end
  end
  return item=='coal' and 16 or 0
end
local function coal_drill(bot,e)
  if e.name~='burner-mining-drill' then return false end
  if e.mining_target and e.mining_target.valid and e.mining_target.name=='coal' then return true end
  return bot.surface.count_entities_filtered{type='resource',name='coal',area={{e.position.x-1.5,e.position.y-1.5},{e.position.x+1.5,e.position.y+1.5}},limit=1}>0
end
function io.collect(bot,s,item,needed,min_output)
  local bag=bot.get_main_inventory();local room=bag.get_insertable_count(item)
  if room==0 then s.action='Нет места в инвентаре';return false end
  local best,score
  for _,e in ipairs(near(bot,s,{'container','logistic-container','furnace','assembling-machine','mining-drill'})) do
    local slot,inv,keep
    if e.type=='container' or e.type=='logistic-container' then slot='chest';inv=e.get_inventory(defines.inventory.chest);keep=protected_chest(e,item)
    elseif coal_drill(bot,e) and item=='coal' then slot='fuel';inv=e.get_fuel_inventory();keep=1
    elseif e.type=='furnace' or e.type=='assembling-machine' then slot='output';inv=e.get_output_inventory();keep=0 end
    local n=inv and math.max(0,inv.get_item_count(item)-(keep or 0)) or 0
    local k='transfer:'..e.name..':'..e.position.x..':'..e.position.y
    if n>0 and (not min_output or slot=='output' and n>=min_output) and not (s.avoid[k] and s.avoid[k]>game.tick) then
      local value=math.min(n,math.max(needed,16))/(4+companion.distance(bot.position,e.position))
      if not score or value>score then best={e=e,slot=slot,n=math.min(n,room),keep=keep};score=value end
    end
  end
  if best then
    local limits=best.slot=='fuel' and {keep_coal=true} or best.slot=='output' and {take_output=true} or
      best.keep and best.keep>0 and {keep_count=best.keep} or nil
    return io.transfer(s,best.e,best.slot,'take',item,best.n,limits)
  end
  if min_output then return false end
  for _,e in ipairs(near(bot,s,{'transport-belt','underground-belt','splitter'})) do
    local n=0
    for i=1,2 do n=n+e.get_transport_line(i).get_item_count(item) end
    local keep=0
    if n>keep*2 then
      if io.task(s,'belt_take',{x=e.position.x,y=e.position.y,entity=e.name,name=item,count=math.min(room,needed),keep=keep},'Собираю с ленты '..item) then return true end
    end
  end
  return false
end
local function iron_round(bot,s,near_only)
  local iron_plan=s.plans and s.plans['iron-ore']
  local starter_state=storage.starter
  if not starter_state or s.retired or (iron_plan and (iron_plan.target or 0)>=12) then return false,0 end
  local groups=old.units(bot,starter_state,'iron-ore','stone-furnace')
  table.sort(groups,function(a,b)
    return companion.distance(bot.position,a.sink.position)<companion.distance(bot.position,b.sink.position)
  end)
  local coal=io.have(bot,'coal')
  local shortages=0
  for _,unit in ipairs(groups) do
    local furnace=unit.sink
    local output=furnace.get_output_inventory().get_item_count('iron-plate')
    if output<80 then
      for _,machine in ipairs{furnace,unit.drill} do
        local fuel=machine.get_fuel_inventory()
        local count=fuel.get_item_count()
        if count<=2 and (not near_only or bot.can_reach_entity(machine)) then
          shortages=shortages+1
          local amount=math.min(8-count,coal-8,fuel.get_insertable_count('coal'))
          if amount>0 and io.transfer(s,machine,'fuel','put','coal',amount) then return true,shortages end
        end
      end
    end
  end
  return false,shortages
end
function io.ensure(bot,s,item,wanted,depth)
  depth=depth or 0
  if io.have(bot,item)>=wanted then return true end
  if depth>12 or s.job then return false end
  s.waiting_material={name=item,wanted=wanted,have=io.have(bot,item)}
  local shortages=0
  if item=='iron-plate' then
    local working
    working,shortages=iron_round(bot,s,false)
    if working then return false end
  end
  if io.collect(bot,s,item,wanted-io.have(bot,item)) then return false end
  if shortages>=3 and io.have(bot,'coal')<16 then
    io.ensure(bot,s,'coal',80,depth+1)
    if s.job then return false end
  end
  if item=='iron-plate' or item=='copper-plate' then
    local id,action=starter.assist_supply(item,wanted)
    s.action=action or s.action
    if id then s.job=id end
    return false
  end
  local r=bot.force.recipes[item]
  if r and r.enabled and bot.crafting_queue_size==0 then
    local per=1
    for _,p in ipairs(r.products) do if p.name==item then per=p.amount or 1 end end
    local n=math.min(24,math.ceil((wanted-io.have(bot,item))/per))
    local craftable=bot.get_craftable_count(item)
    if craftable>0 then
      journal.craft(bot,{recipe=item,count=math.min(n,craftable),silent=true})
      s.action='Крафчу в пути '..item;return false
    end
    for _,i in ipairs(r.ingredients) do
      if i.type=='item' and io.have(bot,i.name)<i.amount*n then io.ensure(bot,s,i.name,i.amount*n,depth+1);return false end
    end
  end
  if item=='coal' or item=='stone' or item=='wood' then
    local id,action=starter.assist_supply(item,wanted)
    if id then s.job=id;s.action=action end
  elseif not r or not r.enabled then s.wait_recipe=item;s.action='Нужен рецепт '..item end
  return false
end
function io.queued_drills(bot)
  local count=0
  for _,craft in ipairs(bot.crafting_queue or {}) do
    if craft.recipe=='electric-mining-drill' and not craft.prerequisite then count=count+craft.count end
  end
  return count
end
function io.stock_parts(bot,s,parts,items,allow_queued_drills)
  local needed={}
  for _,part in ipairs(parts) do
    if not io.entity(bot,part) then needed[part.name]=(needed[part.name] or 0)+1 end
  end
  for _,item in ipairs(items) do
    if needed[item] then
      local queued=allow_queued_drills and item=='electric-mining-drill' and io.queued_drills(bot) or 0
      if not io.ensure(bot,s,item,needed[item]-queued) then return false end
    end
  end
  return true
end
function io.recover(s,e)
  return io.task(s,'recover',{entity=e.name,x=e.position.x,y=e.position.y},'Разбираю '..e.name)
end
local function box(p)
  local b=prototypes.entity[p.name].collision_box
  local w=math.max(math.abs(b.left_top.x),math.abs(b.right_bottom.x))
  local h=math.max(math.abs(b.left_top.y),math.abs(b.right_bottom.y))
  if (p.direction or 0)%8==4 then w,h=h,w end
  return {{p.position.x-w,p.position.y-h},{p.position.x+w,p.position.y+h}}
end
function io.prepare_site(bot,s,p)
  for _,e in ipairs(bot.surface.find_entities_filtered{area=box(p)}) do
    if e.type=='tree' or e.name=='big-rock' or e.name=='big-sand-rock' or e.name=='huge-rock' then io.recover(s,e);return false end
    if e.force==bot.force and e.name=='burner-mining-drill' then
      -- The sink is remembered before removing the drill, including its inventory.
      local sink=old.drop_sink(e,'stone-furnace') or old.drop_sink(e,'wooden-chest')
      if sink then s.pair_cleanup={name=sink.name,position=sink.position} end
      io.recover(s,e);return false
    end
    if e.force==bot.force and e.name=='stone-furnace' and p.name~='stone-furnace' then
      for _,d in ipairs(bot.surface.find_entities_filtered{name='burner-mining-drill',position=e.position,radius=5,force=bot.force}) do
        if old.drop_sink(d,'stone-furnace')==e then
          s.pair_cleanup={name=e.name,position=e.position};io.recover(s,d);return false
        end
      end
    end
  end
  return true
end
function io.build(bot,s,parts,by_strip)
  if s.pair_cleanup then
    local e=io.entity(bot,s.pair_cleanup)
    if e then io.recover(s,e);return false end
    s.pair_cleanup=nil
  end
  local missing,counts={},{}
  for _,p in ipairs(parts) do
    local e=io.entity(bot,p)
    if not e then missing[#missing+1]=p;counts[p.name]=(counts[p.name] or 0)+1
    elseif not layout.matches(e,p) then
      if p.name=='underground-belt' and e.belt_to_ground_type~=p.type then io.recover(s,e)
      else io.task(s,'orient',{name=p.name,x=p.position.x,y=p.position.y,direction=p.direction},'Поворачиваю '..p.name) end
      return false
    elseif p.recipe and bot.force.recipes[p.recipe].enabled then
      local r=e.get_recipe()
      if not r then io.task(s,'recipe',{entity=e.name,x=e.position.x,y=e.position.y,name=p.recipe},'Задаю рецепт '..p.recipe);return false end
      if r.name~=p.recipe then s.action='Игрок изменил рецепт: '..e.name;s.conflict=p;return false end
    end
    if e and (p.bar or p.control_behavior) then
      local id=e.unit_number..':'..tostring(p.bar)..':'..tostring(p.control_behavior~=nil)
      s.configured=s.configured or {}
      if s.configuring==id and s.configuring_job and storage.jobs[s.configuring_job] and storage.jobs[s.configuring_job].status=='done' then s.configured[id]=true;s.configuring=nil end
      if not s.configured[id] then
        io.task(s,'configure',{entity=e.name,x=e.position.x,y=e.position.y,bar=p.bar,control_behavior=p.control_behavior},'Настраиваю '..e.name)
        s.configuring=id;s.configuring_job=s.job;return false
      end
    end
  end
  s.build_progress={total=#parts,remaining=#missing}
  if #missing==0 then return true end
  local strips
  if by_strip then
    strips={}
    local direction=(16-s.site.direction)%16
    for _,part in ipairs(missing) do
      local pos={x=part.position.x-s.site.origin.x,y=part.position.y-s.site.origin.y}
      strips[part]=math.floor(layout.rotate(pos,direction).x/16)
    end
  end
  table.sort(missing,function(a,b)
    if strips and strips[a]~=strips[b] then return strips[a]<strips[b] end
    return companion.distance(bot.position,a.position)<companion.distance(bot.position,b.position)
  end)
  -- Start the next batch in the pocket while placing the items already carried.
  if bot.crafting_queue_size==0 then
    for _,p in ipairs(missing) do
      local r=bot.force.recipes[p.name]
      if io.have(bot,p.name)<math.min(counts[p.name],12) and r and r.enabled and bot.get_craftable_count(p.name)>0 then
        journal.craft(bot,{recipe=p.name,count=math.min(bot.get_craftable_count(p.name),6),silent=true});break
      end
    end
  end
  for _,p in ipairs(missing) do
    if io.have(bot,p.name)>0 then
      if not io.prepare_site(bot,s,p) then return false end
      if io.task(s,'build',{name=p.name,x=p.position.x,y=p.position.y,direction=p.direction,type=p.type,output_priority=p.output_priority},'Строю '..p.name) then return false end
    end
  end
  local p=missing[1]
  io.ensure(bot,s,p.name,math.min(counts[p.name],p.name=='electric-mining-drill' and 4 or 12))
  return false
end
local feeds={[23]={'iron-plate','copper-plate'},[27]={'iron-plate'},[32]={'iron-plate','copper-plate'},[37]={'copper-plate','iron-plate'}}
function io.starter_science_running(bot,s)
  if s.starter_recovered or s.retired and not s.starter_science then return false end
  for _,p in ipairs(storage.starter.factory.parts) do
    if p.id==6 then
      local assembler=io.entity(bot,p)
      return assembler and assembler.products_finished>0 or false
    end
  end
  return false
end

local function service_science(bot,s,st,near_only)
  for _,part in ipairs(st.factory.parts) do
    if part.id==23 then
      local chest=io.entity(bot,part)
      if not chest or near_only and not bot.can_reach_entity(chest) then return false end
      local inv=chest.get_inventory(defines.inventory.chest)
      for _,item in ipairs{'copper-plate','iron-plate'} do
        local count=inv.get_item_count(item)
        if count<16 then
          local carried=io.have(bot,item)
          local amount=math.min(64-count,carried)
          if amount>=24 or near_only and amount>0 and count<4 then
            if io.transfer(s,chest,'chest','put',item,amount) then return true end
          elseif not near_only then
            io.ensure(bot,s,item,64-count)
            if s.job then return true end
          end
        end
      end
      return false
    end
  end
  return false
end
function io.service_research(bot,s)
  return bot.force.current_research and io.starter_science_running(bot,s) and service_science(bot,s,storage.starter,false)
end

local function boiler_belt_inserter(boiler)
  local surface=boiler.surface
  for _,inserter in ipairs(surface.find_entities_filtered{type='inserter',force=boiler.force,position=boiler.position,radius=4}) do
    if inserter.drop_target==boiler and surface.count_entities_filtered{position=inserter.pickup_position,
        type={'transport-belt','underground-belt','splitter'},limit=1}>0 then return true end
  end
  return false
end

function io.boiler_needs_manual_fuel(s,boiler)
  local route=s.routes and s.routes['coal-to-boilers']
  if not s.coal_line_online and not (route and route.parts and s.phase~='coal') then return true end
  if boiler_belt_inserter(boiler) then return false end
  -- During construction a belt inserter may be missing or empty. The station
  -- stays assigned to its fuel line after commissioning.
  for _,part in ipairs(s.power and s.power.parts or {}) do
    if part.name=='boiler' and companion.distance(part.position,boiler.position)<.1 then return false end
  end
  local starter=storage.starter and storage.starter.power
  local original=starter and starter.parts[3]
  return not (original and companion.distance(original.position,boiler.position)<.1)
end

function io.service_starter_power(bot,s)
  local boiler=io.entity(bot,storage.starter.power.parts[3])
  if not boiler or not io.boiler_needs_manual_fuel(s,boiler) then return false end
  local box,amount,reserve=starter.boiler_refill(bot,boiler)
  if box and amount>=24 then return io.transfer(s,box,'chest','put','coal',amount) end
  if box and reserve>0 then return false end
  local fuel=boiler.get_fuel_inventory()
  local amounts=boiler.get_fluid_contents()
  if fuel.get_item_count()>=4 or (amounts.steam or 0)>=100 then return false end
  local coal=io.have(bot,'coal')
  if coal>=24 then return io.transfer(s,boiler,'fuel','put','coal',math.min(48,coal)) end
  io.ensure(bot,s,'coal',60)
  return s.job~=nil
end
local function supply_belt_input(bot,s,chest,near_only)
  local count=chest.get_inventory(defines.inventory.chest).get_item_count('iron-plate')
  if count>=belt_iron_low then return false end
  local carried=io.have(bot,'iron-plate')
  local amount=math.min(belt_iron_target-count,carried-construction_iron_reserve)
  if amount>=100 or (count<8 and amount>=16 and bot.can_reach_entity(chest)) then
    return io.transfer(s,chest,'chest','put','iron-plate',amount)
  end
  if near_only then return false end
  io.ensure(bot,s,'iron-plate',construction_iron_reserve+belt_iron_target-count)
  return s.job~=nil
end
function io.service(bot,s,near_only)
  local st=storage.starter
  if s.pair_cleanup then
    local e=io.entity(bot,s.pair_cleanup)
    if e then return io.recover(s,e) end
    s.pair_cleanup=nil
  end
  -- Keep a research supply when there is work for the labs. With no active
  -- technology, reserve the carried ingredients for the current build.
  if st and bot.force.current_research and io.starter_science_running(bot,s) and
      service_science(bot,s,st,near_only) then return true end
  local machines=near(bot,s,{'mining-drill','furnace','boiler'})
  for _,e in ipairs(machines) do
    if e.name=='burner-mining-drill' and (not near_only or bot.can_reach_entity(e)) and
      bot.surface.count_entities_filtered{type='resource',area={{e.position.x-1.5,e.position.y-1.5},{e.position.x+1.5,e.position.y+1.5}},limit=1}==0 then
      local sink=old.drop_sink(e,'stone-furnace') or old.drop_sink(e,'wooden-chest')
      if sink then s.pair_cleanup={name=sink.name,position=sink.position} end
      return io.recover(s,e)
    end
    local f=e.get_fuel_inventory()
    if f and e.type=='boiler' and io.boiler_needs_manual_fuel(s,e) and
        (not near_only or bot.can_reach_entity(e)) then
      local box,amount,reserve=starter.boiler_refill(bot,e)
      if box and (not near_only or bot.can_reach_entity(box)) then
        local before_electric_coal=s.mode=='running' and (not s.plans.coal or not s.plans.coal.target)
        if before_electric_coal and not near_only and reserve<=35 and reserve+amount<150 then
          io.ensure(bot,s,'coal',174-reserve)
          if s.job then return true end
        elseif amount>=24 and io.transfer(s,box,'chest','put','coal',amount) then
          return true
        end
      end
      if (not box or reserve==0) and f.get_item_count()<8 then
        if io.have(bot,'coal')>=24 then return io.transfer(s,e,'fuel','put','coal',math.min(io.have(bot,'coal'),24)) end
        if not near_only then io.ensure(bot,s,'coal',60);return s.job~=nil end
      end
    end
  end
  if io.have(bot,'iron-plate')<96 then
    local working,shortages=iron_round(bot,s,near_only)
    if working then return true end
    if not near_only and s.mode=='running' and shortages>=3 and io.have(bot,'coal')<16 then
      io.ensure(bot,s,'coal',80)
      if s.job then return true end
    end
  end
  if (not s.retired or s.starter_science) and st and st.factory then
    for _,p in ipairs(st.factory.parts) do
      if not s.retired and feeds[p.id] then
        local e=io.entity(bot,p)
        if e and (not near_only or bot.can_reach_entity(e)) then
          local inv=e.get_inventory(defines.inventory.chest)
          for _,item in ipairs(feeds[p.id]) do
            if p.id==belt_input_id and item=='iron-plate' then
              if supply_belt_input(bot,s,e,near_only) then return true end
            elseif inv.get_item_count(item)<8 then
              if io.have(bot,item)>=16 and io.transfer(s,e,'chest','put',item,math.min(32,io.have(bot,item))) then
                return true
              end
              if not near_only then
                io.ensure(bot,s,item,item=='iron-plate' and 96 or 48)
                if s.job then return true end
              end
            end
          end
        end
      elseif p.recipe then
        local e=io.entity(bot,p)
        if e and not e.get_recipe() and bot.force.recipes[p.recipe].enabled then
          return io.task(s,'recipe',{entity=e.name,x=e.position.x,y=e.position.y,name=p.recipe},'Восстанавливаю рецепт '..p.recipe)
        end
      end
    end
  end
  for _,e in ipairs(machines) do
    local f=e.get_fuel_inventory()
    if f and e.type~='boiler' and not coal_drill(bot,e) and f.get_item_count()<3 and (not near_only or bot.can_reach_entity(e)) then
      if io.have(bot,'coal')>0 then return io.transfer(s,e,'fuel','put','coal',math.min(12,io.have(bot,'coal'))) end
      if not near_only then io.ensure(bot,s,'coal',60);return s.job~=nil end
    end
  end
  return false
end
function io.unload(bot,s)
  local bag=bot.get_main_inventory()
  if bag.count_empty_stacks()>=16 then s.unloading=nil;return false end
  if not s.unloading and bag.count_empty_stacks()>8 then return false end
  s.unloading=true
  s.depots=s.depots or {}
  local keep={['iron-plate']=200,['copper-plate']=100,coal=60,wood=32,['iron-chest']=2,['wooden-chest']=2,['burner-mining-drill']=0}
  local cargo
  for _,v in ipairs(bag.get_contents()) do
    local limit=keep[v.name]
    if limit==nil then limit=math.min(100,prototypes.item[v.name].stack_size) end
    if v.quality=='normal' and v.count>limit and (not cargo or v.count-limit>cargo.count) then cargo={name=v.name,count=v.count-limit} end
  end
  if not cargo then s.unloading=nil;return false end
  for _,p in ipairs(s.depots) do
    local e=io.entity(bot,p)
    local room=e and e.get_inventory(defines.inventory.chest).get_insertable_count(cargo.name) or 0
    if room>0 then return io.transfer(s,e,'chest','put',cargo.name,math.min(room,cargo.count,1000)) end
  end
  if not s.next_depot then
    local anchor=storage.starter.factory.origin
    local reserved={}
    if s.site then reserved[#reserved+1]=s.site.area end
    if s.power then reserved[#reserved+1]=s.power.area end
    reserved[#reserved+1]=layout.area(storage.starter.factory.parts)
    for radius=5,36 do
      for dx=-radius,radius do for _,dy in ipairs{-radius,radius} do
        local p={x=math.floor(anchor.x)+dx+.5,y=math.floor(anchor.y)+dy+.5}
        local blocked=false
        for _,a in ipairs(reserved) do if p.x>=a[1][1] and p.x<=a[2][1] and p.y>=a[1][2] and p.y<=a[2][2] then blocked=true end end
        if not blocked and bot.surface.can_place_entity{name='iron-chest',position=p,force=bot.force} then s.next_depot={name='iron-chest',position=p,direction=0};break end
      end if s.next_depot then break end end
      if s.next_depot then break end
    end
  end
  if s.next_depot then
    if io.build(bot,s,{s.next_depot}) then
      s.depots[#s.depots+1]=s.next_depot;s.next_depot=nil
    end
    return true
  end
  s.action='Не найдено место для временного склада'
  return true
end
local stage_two_components={{'iron-gear-wheel',32,12},{'electronic-circuit',24,8},{'copper-cable',30,12}}
function io.collect_stage_two_components(bot,s)
  s.second_components_checked=s.second_components_checked or {}
  for _,stock in ipairs(stage_two_components) do
    local item,target,min_output=table.unpack(stock)
    if not s.second_components_checked[item] then
      s.second_components_checked[item]=true
      if io.have(bot,item)<target and io.collect(bot,s,item,target-io.have(bot,item),min_output) then return true end
    end
  end
  return false
end
function io.on_walk(bot,s,job)
  if not job or not job.automatic then return end
  if s.phase=='copper' and s.trials and s.trials.components and bot.walking_state.walking and
      bot.crafting_queue_size==0 and io.have(bot,'iron-plate')>=96 and io.have(bot,'copper-plate')>=48 then
    for _,stock in ipairs(stage_two_components) do
      local item,target=stock[1],stock[2]
      local count=math.min(12,target-io.have(bot,item),bot.get_craftable_count(item))
      if count>0 then journal.craft(bot,{recipe=item,count=count,silent=true});break end
    end
  end
  if s.advance_craft and s.phase=='one' and bot.walking_state.walking and bot.crafting_queue_size==0 then
    s.first_stage_parts=s.first_stage_parts or layout.parts('jump',1,s.site.origin,s.site.direction)
    local needs={}
    for _,part in ipairs(s.first_stage_parts) do
      if not io.entity(bot,part) then needs[part.name]=(needs[part.name] or 0)+1 end
    end
    -- Request finished parts: Factorio queues their intermediates as needed.
    -- Small batches keep the queue available for imminent shortages.
    for _,item in ipairs{'small-electric-pole','inserter','transport-belt','underground-belt','splitter','assembling-machine-1'} do
      local short=(needs[item] or 0)-io.have(bot,item)
      if short>0 then
        local count=math.min(short,12,bot.get_craftable_count(item))
        if count>0 then journal.craft(bot,{recipe=item,count=count,silent=true});break end
      end
    end
  end
  local bag=bot.get_main_inventory()
  for _,e in ipairs(bot.surface.find_entities_filtered{type={'mining-drill','furnace','boiler'},force=bot.force,position=bot.position,radius=bot.reach_distance}) do
    if bot.can_reach_entity(e) and not (job.args.entity==e.name and job.args.x==e.position.x and job.args.y==e.position.y) then
      local f=e.get_fuel_inventory()
      if coal_drill(bot,e) then
        local n=math.min(math.max(0,f.get_item_count('coal')-1),bag.get_insertable_count('coal'))
        if n>0 then
          local got=bag.insert{name='coal',count=n}
          if got>0 then f.remove{name='coal',count=got} end
        end
      elseif f and f.get_item_count()<3 and
          (e.type~='boiler' or io.boiler_needs_manual_fuel(s,e)) then
        local reserve=job.kind=='transfer' and job.args.mode=='put' and job.args.name=='coal' and job.args.count or 0
        local box=e.type=='boiler' and starter.boiler_refill(bot,e)
        local n=not box and math.min(12,math.max(0,bag.get_item_count('coal')-reserve)) or 0
        if n>0 then
          local got=f.insert{name='coal',count=n}
          if got>0 then bag.remove{name='coal',count=got} end
        end
      end
      if e.type=='furnace' then
        local out=e.get_output_inventory()
        for _,item in ipairs(out.get_contents()) do
          if (item.name=='iron-plate' or item.name=='copper-plate') and bag.count_empty_stacks()>8 then
            local n=bag.insert(item)
            if n>0 then out.remove{name=item.name,count=n,quality=item.quality} end
          end
        end
      end
    end
  end
end
return io
