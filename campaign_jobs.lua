local companion=require('character')
local assets=require('campaign_assets')
local actions={}
function actions.recover(bot,job)
  local a=job.args
  local e=bot.surface.find_entity(a.entity,{a.x,a.y})
  if not e or not e.valid then job.progress=0;job.detail='Target already absent';return true end
  assert(e.force==bot.force or e.type=='tree' or e.name=='big-rock' or e.name=='big-sand-rock' or e.name=='huge-rock','Cannot dismantle this entity')
  assert(e.type~='character' and e.type~='resource','Cannot dismantle this entity')
  if not bot.can_reach_entity(e) then
    local reach=job.close_recover and 2.4 or bot.reach_distance-0.3
    if not companion.approach(bot,job,e.position,reach) then return end
    if not job.close_recover and not bot.can_reach_entity(e) then
      job.close_recover=true
      return
    end
  end
  companion.stop(bot)
  job.mining_started=job.mining_started or game.tick
  local seconds=e.prototype.mineable_properties.mining_time or 0.5
  if game.tick-job.mining_started<math.ceil(seconds*60/math.max(0.1,1+bot.force.manual_mining_speed_modifier)) then return end
  assert(e.mine{inventory=bot.get_main_inventory(),force=false,raise_destroyed=true},'Inventory full or entity cannot be mined')
  job.progress=1
  return true
end
function actions.belt_take(bot,job)
  local a=job.args
  local e=bot.surface.find_entity(a.entity,{a.x,a.y})
  if not e then return true end
  if not bot.can_reach_entity(e) and not companion.approach(bot,job,e.position,bot.reach_distance-0.3) then return end
  assert(bot.can_reach_entity(e),'Belt out of reach')
  local bag=bot.get_main_inventory()
  local limit=math.min(a.count or 8,bag.get_insertable_count(a.name))
  local total=0
  local belts=bot.surface.find_entities_filtered{type={'transport-belt','underground-belt','splitter'},force=bot.force,position=bot.position,radius=bot.reach_distance}
  -- Reach checks use entity bounds; a reachable target's centre can be outside this radius.
  local included=false
  for _,belt in ipairs(belts) do if belt==e then included=true;break end end
  if not included then belts[#belts+1]=e end
  for _,belt in ipairs(belts) do
   if total>=limit then break end
   if bot.can_reach_entity(belt) then
    for i=1,2 do
    local line=belt.get_transport_line(i)
    local available=math.max(0,line.get_item_count(a.name)-(a.keep or 0))
    local n=math.min(limit-total,available)
    if n>0 then
      n=line.remove_item{name=a.name,count=n,quality='normal'}
      assert(bag.insert{name=a.name,count=n,quality='normal'}==n,'Belt pickup capacity changed')
      total=total+n
    end
    end
   end
  end
  job.progress=total
  return true
end
function actions.blueprint_gift(bot,job)
  local a=job.args
  local e=assert(bot.surface.find_entity(a.entity,{a.x,a.y}),'Blueprint chest disappeared')
  if not bot.can_reach_entity(e) and not companion.approach(bot,job,e.position,bot.reach_distance-0.3) then return end
  local inv=e.get_inventory(defines.inventory.chest)
  for i=1,#inv do
    if inv[i].valid_for_read and inv[i].is_blueprint and inv[i].label=='Jump Start Base 1' then return true end
  end
  local slot=assert(inv.find_empty_stack(),'Blueprint chest is full')
  assert(slot.import_stack(assets.jump[1].exchange)==0,'Cannot import blueprint 1')
  slot.label='Jump Start Base 1'
  return true
end
function actions.configure(bot,job)
  local a=job.args
  local e=assert(bot.surface.find_entity(a.entity,{a.x,a.y}),'Configuration target missing')
  if not bot.can_reach_entity(e) and not companion.approach(bot,job,e.position,bot.reach_distance-0.3) then return end
  if a.bar then e.get_inventory(defines.inventory.chest).set_bar(a.bar+1) end
  if a.control_behavior then
    local c=e.get_or_create_control_behavior()
    if a.control_behavior.circuit_enabled~=nil then c.circuit_enable_disable=a.control_behavior.circuit_enabled end
    if a.control_behavior.circuit_condition then c.circuit_condition=a.control_behavior.circuit_condition end
  end
  return true
end
function actions.wire(bot,job)
  local a=job.args
  local e=assert(bot.surface.find_entity(a.entity,{a.x,a.y}),'Wire source missing')
  local target=assert(bot.surface.find_entity(a.other,a.position),'Wire target missing')
  if not bot.can_reach_entity(e) and not companion.approach(bot,job,e.position,bot.reach_distance-0.3) then return end
  local first=assert(e.get_wire_connector(a.connector,true))
  local second=assert(target.get_wire_connector(a.other_connector,true))
  if not first.is_connected_to(second) then assert(first.connect_to(second,true),'Wire connection out of range') end
  return true
end
return actions
