local layout=require('campaign_layout')
local routes=require('campaign_routes')
local io=require('campaign_io')
local distance=require('character').distance
local network={}
local assets=require('campaign_assets')
local manual_pipe_route_version=3
-- External tiles immediately beyond the steam connections, facing north.
-- These come from the vanilla boiler and steam-engine fluid box prototypes.
local steam_ports={boiler={{x=0,y=-1.5}},['steam-engine']={{x=0,y=-3},{x=0,y=3}}}

function network.reserve_steam_ports(parts,mask)
  for _,part in ipairs(parts) do
    for _,offset in ipairs(steam_ports[part.name] or {}) do
      local port=layout.world({origin=part.position,direction=part.direction},offset)
      mask[math.floor(port.x)..':'..math.floor(port.y)]=true
    end
  end
  return mask
end
local function covers(pole,entity)
  local b=entity.bounding_box
  local r=pole.prototype.get_supply_area_distance(pole.quality)
  return b.left_top.x<pole.position.x+r and b.right_bottom.x>pole.position.x-r and b.left_top.y<pole.position.y+r and b.right_bottom.y>pole.position.y-r
end
local wire_offsets={{6,0},{-6,0},{0,6},{0,-6},{3,0},{-3,0},{0,3},{0,-3},{4,4},{-4,4},{4,-4},{-4,-4}}
local flexible_wire_offsets={}
for x=-7,7 do for y=-7,7 do
  if x*x+y*y>0 and x*x+y*y<=7.5^2 then flexible_wire_offsets[#flexible_wire_offsets+1]={x,y} end
end end
local function next_wire_pole(bot,start,goal,mask,offsets)
  local frontier={{position=start,cost=0,score=0}};local seen={}
  for _=1,2200 do
    if #frontier==0 then return end
    local best=1
    for i=2,#frontier do if frontier[i].score<frontier[best].score then best=i end end
    local node=table.remove(frontier,best)
    if distance(node.position,goal)<=7.5 then return node.first end
    for _,d in ipairs(offsets) do
      local p={x=node.position.x+d[1],y=node.position.y+d[2]}
      local k=math.floor(p.x)..':'..math.floor(p.y)
      local cost=node.cost+1+(d[1]~=0 and d[2]~=0 and .65 or 0)+
          (node.offset and (node.offset[1]*d[2]~=node.offset[2]*d[1]) and .25 or 0)
        if (not seen[k] or cost<seen[k]) and not (mask and mask[k]) and distance(p,goal)<distance(start,goal)+40 then
        seen[k]=cost
        local good=not bot.surface.get_tile(p).collides_with('water_tile')
        if good then
          for _,e in ipairs(bot.surface.find_entities_filtered{area={{p.x-.15,p.y-.15},{p.x+.15,p.y+.15}}}) do
            if e.type~='tree' and e.type~='resource' and e.type~='item-entity' then good=false;break end
          end
        end
        if good then frontier[#frontier+1]={position=p,first=node.first or p,offset=d,cost=cost,score=cost+distance(p,goal)/6} end
      end
    end
  end
end
function network.power_direction(site,direction)
  return (site.direction+(site.mirrored and -direction or direction))%16
end

function network.power_position(site,position)
  return layout.world(site,{x=site.mirrored and -position.x or position.x,y=position.y})
end

function network.power_feed_parts(site)
  local edge=3*(site.max_units or 20)
  local direction=network.power_direction(site,12)
  local parts={{name='splitter',position=network.power_position(site,{x=edge+2.5,y=13}),
    direction=direction,output_priority=site.mirrored and 'left' or 'right'}}
  for x=edge+.5,edge+1.5 do
    parts[#parts+1]={name='transport-belt',position=network.power_position(site,{x=x,y=12.5}),direction=direction}
  end
  return parts
end

local function compact_station(site)
  local parts={}
  for _,entity in ipairs(assets.power[1].entities) do
    if entity.position.x<3*site.max_units then
      parts[#parts+1]={name=entity.name,position=network.power_position(site,entity.position),
        direction=network.power_direction(site,entity.direction or 0),station_x=entity.position.x}
    end
  end
  -- The fifth module uses the gap beside its engines. The blueprint's
  -- next pole is outside the footprint of a five-boiler station.
  parts[#parts+1]={name='small-electric-pole',position=network.power_position(site,{x=11.5,y=3.5}),
    direction=0,station_x=13.5}
  return parts
end

local function station_footprint(site,parts)
  local footprint={}
  for _,part in ipairs(parts) do footprint[#footprint+1]=part end
  for _,part in ipairs(network.power_feed_parts(site)) do footprint[#footprint+1]=part end
  return footprint
end

local function integrated_power_site(bot,s)
  local starter=storage.starter
  local anchor=starter.power.parts[3]
  local feed=starter.boiler_feed
  local own_poles={}
  for _,part in ipairs(starter.power.parts) do
    if part.name=='small-electric-pole' then
      local pole=io.entity(bot,part)
      if pole then own_poles[pole.unit_number]=true end
    end
  end
  for _,position in ipairs(starter.power_links or {}) do
    local pole=io.entity(bot,{name='small-electric-pole',position=position})
    if pole then own_poles[pole.unit_number]=true end
  end
  for _,mirrored in ipairs{false,true} do
    local site={direction=anchor.direction,mirrored=mirrored,max_units=5,integrated=true}
    local offset=layout.rotate({x=mirrored and -1.5 or 1.5,y=10},site.direction)
    site.origin={x=anchor.position.x-offset.x,y=anchor.position.y-offset.y}
    local parts=compact_station(site)
    local footprint=station_footprint(site,parts)
    local poles={}
    local area=layout.area(footprint)
    local clear=not layout.overlap(area,s.site.area) and
      not layout.overlap(area,layout.area(starter.factory.parts))
    for _,part in ipairs(footprint) do
      if not clear then break end
      local e=io.entity(bot,part)
      if e and layout.matches(e,part) then
        -- Existing starter boiler and both engines occupy the first module.
      else
        local position=part.position
        local chest=feed and part.name=='transport-belt' and distance(position,feed[1].position)<.1
        if chest and io.entity(bot,feed[1]) then
          site.feed_chest=feed[1]
          site.feed_belt=part
        elseif not bot.surface.can_place_entity{name=part.name,position=position,direction=part.direction,force=bot.force,
            build_check_type=defines.build_check_type.manual} then
          local box=prototypes.entity[part.name].collision_box
          local w=math.max(math.abs(box.left_top.x),math.abs(box.right_bottom.x))
          local h=math.max(math.abs(box.left_top.y),math.abs(box.right_bottom.y))
          if part.direction%8==4 then w,h=h,w end
          local collision={{position.x-w,position.y-h},{position.x+w,position.y+h}}
          local obstacles=bot.surface.find_entities_filtered{area=collision,collision_mask=prototypes.entity[part.name].collision_mask.layers}
          if #obstacles==0 or bot.surface.count_tiles_filtered{area=collision,collision_mask='water_tile',limit=1}>0 then
            clear=false
          else
            for _,obstacle in ipairs(obstacles) do
              if obstacle.name=='small-electric-pole' and obstacle.force==bot.force and
                  (own_poles[obstacle.unit_number] or s.test_mode) then
                poles[obstacle.unit_number]={name=obstacle.name,position=obstacle.position}
              elseif obstacle.type~='tree' and obstacle~=bot then clear=false;break end
            end
          end
        end
      end
    end
    if clear then
      if site.feed_chest and feed[2] then
        local first_feeder=network.power_position(site,{x=2.5,y=11.5})
        for i,part in ipairs(parts) do
          if part.name=='inserter' and distance(part.position,first_feeder)<.1 then
            parts[i]={name='inserter',position=feed[2].position,direction=feed[2].direction,station_x=part.station_x}
            break
          end
        end
      end
      site.relocate_poles={}
      for _,pole in pairs(poles) do site.relocate_poles[#site.relocate_poles+1]=pole end
      table.sort(site.relocate_poles,function(a,b)
        if a.position.x~=b.position.x then return a.position.x<b.position.x end
        return a.position.y<b.position.y
      end)
      site.parts,site.area=parts,area
      return site
    end
  end
end

function network.power_site(bot,s,reservations)
  if not s.integrated_power_checked then
    s.integrated_power_checked=true
    local integrated=integrated_power_site(bot,s)
    if integrated then return integrated end
  end
  s.power_search=s.power_search or 0
  local anchor=storage.starter.power.parts[3].position
  if s.power_candidate then
    local candidate=s.power_candidate
    local path,err=routes.step(bot,candidate.water_search)
    if path then
      s.power_candidate=nil
      s.routes.water={parts=network.pipe_parts(path),pipe_route_version=manual_pipe_route_version}
      candidate.water_search=nil
      return candidate
    end
    if err then
      s.power_candidate=nil
      s.rejected_water_sites=(s.rejected_water_sites or 0)+1
    end
    return nil,'Проверяю подвод воды к электростанции'
  end
  for _=1,4 do
    local i=s.power_search;s.power_search=i+1
    if i>=1800 then return nil,'Не найдено место для электростанции' end
    local turn=i%4*4;local j=math.floor(i/4)
    local ring=math.floor(math.sqrt(j))+1
    local angle=(j-(ring-1)^2)/(2*ring-1)*math.pi*2
    local p={x=math.floor(anchor.x+math.cos(angle)*(20+ring*5)),y=math.floor(anchor.y+math.sin(angle)*(20+ring*5))}
    local candidate={origin=p,direction=turn,max_units=5}
    local parts=compact_station(candidate)
    local footprint=station_footprint(candidate,parts)
    local area=layout.area(footprint)
    local good=true
    for _,a in ipairs(reservations) do if layout.overlap(a,area) then good=false;break end end
    if good and bot.surface.count_tiles_filtered{area=area,collision_mask='water_tile',limit=1}==0 then
      for _,e in ipairs(bot.surface.find_entities_filtered{area=area}) do
        if e.type~='tree' and e.type~='character' and e.type~='item-entity' then good=false;break end
      end
      for x=math.floor(area[1][1]/32),math.floor(area[2][1]/32) do for y=math.floor(area[1][2]/32),math.floor(area[2][2]/32) do
        if not bot.surface.is_chunk_generated{x,y} then good=false end
      end end
      if good then
        candidate.parts,candidate.area=parts,area
        local mask=routes.mask(footprint)
        routes.mask(layout.parts('jump',5,s.site.origin,s.site.direction),mask)
        network.reserve_steam_ports(parts,mask)
        network.reserve_steam_ports(storage.starter.power.parts,mask)
        local source=storage.starter.power.parts[2].position
        local inlet=layout.world(candidate,{x=-.5,y=10.5})
        if routes.pipe_tile_available(bot,inlet) and not mask[math.floor(inlet.x)..':'..math.floor(inlet.y)] then
          candidate.water_search=routes.begin(source,inlet,mask,false,'pipe')
          s.power_candidate=candidate
          return nil,'Проверяю подвод воды к электростанции'
        end
        s.rejected_water_sites=(s.rejected_water_sites or 0)+1
      end
    end
  end
end
function network.pipe_parts(path)
  local parts={}
  for _,position in ipairs(path) do parts[#parts+1]={name='pipe',position=position,direction=0} end
  return parts
end
function network.power_parts(site,n)
  local parts={}
  local raw=assets.power[1].entities
  local count=site.max_units and math.min(n,site.max_units) or n
  local limit=3*count+(site.max_units and 0 or 1)
  for i,p in ipairs(site.parts) do
    if p.name=='transport-belt' or (p.station_x or raw[i].position.x)<limit then
      parts[#parts+1]=p
    end
  end
  return parts
end
function network.route(bot,s,id,a,b,kind,last_direction,mask)
  s.routes=s.routes or {}
  local r=s.routes[id]
  if kind=='pipe' and r and r.pipe_route_version~=manual_pipe_route_version then r=nil end
  if kind=='pipe' and r and r.parts then
    -- The station and other structures may have changed the map since planning.
    for _,part in ipairs(r.parts) do
      local p=part.position
      if mask[math.floor(p.x)..':'..math.floor(p.y)] or not routes.pipe_tile_available(bot,p) then
        r=nil
        break
      end
    end
  end
  if not r then
    r={search=routes.begin(a,b,mask,kind=='belt' and bot.force.technologies.logistics.researched,kind),
      pipe_route_version=kind=='pipe' and manual_pipe_route_version or nil}
    s.routes[id]=r
  end
  if not r.parts then
    local path,err=routes.step(bot,r.search)
    if err then s.action=id..': '..err;s.route_error=id;s.route_detail={id=id,reason=err,start=a,goal=b,expanded=r.search.expanded};return false end
    if not path then s.action='Размечаю маршрут '..id;return false end
    r.parts=routes.belts(path,last_direction)
    if kind=='pipe' then r.parts=network.pipe_parts(path) end
    if kind=='pole' then
      r.parts={}
      for i=1,#path,6 do r.parts[#r.parts+1]={name='small-electric-pole',position=path[i],direction=0} end
      if (#path-1)%6~=0 then r.parts[#r.parts+1]={name='small-electric-pole',position=path[#path],direction=0} end
    end
    r.search=nil
  end
  local coal_trunk=id=='coal-to-boilers' or id=='coal-to-base'
  local stock_copper=id=='copper-ore-to-base' and s.phase=='copper' and s.trials and s.trials.copper
  -- Long routes are built with the normal replenishment cycle so a single
  -- route cannot reserve most of the character's inventory.
  if (stock_copper or s.coal_batch and s.phase=='coal' and coal_trunk) and #r.parts<=200 and not r.stocked then
    if not io.stock_parts(bot,s,r.parts,{'underground-belt','transport-belt'}) then return false end
    r.stocked=true
  end
  return io.build(bot,s,r.parts)
end
function network.connect(bot,s,parts,mask)
  local engines=bot.surface.find_entities_filtered{name='steam-engine',force=bot.force,position=s.home,radius=480}
  local networks={}
  local primary
  if s.power then
    for _,p in ipairs(s.power.parts) do
      if p.name=='steam-engine' then local e=io.entity(bot,p);if e and e.electric_network_id then primary=e.electric_network_id;break end end
    end
  end
  if not primary then for _,e in ipairs(engines) do if e.electric_network_id then primary=e.electric_network_id;break end end end
  if primary then networks[primary]=true end
  for _,p in ipairs(parts) do
    local e=io.entity(bot,p)
    if e and (e.type=='mining-drill' and e.name=='electric-mining-drill' or e.type=='assembling-machine' or e.type=='lab' or e.type=='inserter' or e.type=='electric-pole') and
      not networks[e.electric_network_id or 0] then
      local goal
      if e.type=='electric-pole' then goal=e.position else
        for _,pole in ipairs(bot.surface.find_entities_filtered{type='electric-pole',position=e.position,radius=4,force=bot.force}) do
          if covers(pole,e) then goal=pole.position;break end
        end
        if not goal then
          for r=2,4 do
            for dx=-r,r do for dy=-r,r do
              local pos={x=math.floor(e.position.x)+dx+0.5,y=math.floor(e.position.y)+dy+0.5}
              if not goal and (math.abs(dx)==r or math.abs(dy)==r) and not (mask and mask[math.floor(pos.x)..':'..math.floor(pos.y)]) and bot.surface.can_place_entity{name='small-electric-pole',position=pos,force=bot.force} then goal=pos end
            end end
            if goal then break end
          end
          if goal then io.build(bot,s,{{name='small-electric-pole',position=goal,direction=0}});return false end
        end
      end
      if not goal then s.action='Нет места для опоры возле '..e.name;return false end
      local best,score
      for _,pole in ipairs(bot.surface.find_entities_filtered{type='electric-pole',force=bot.force,position=s.home,radius=480}) do
        if networks[pole.electric_network_id or 0] then
          local d=distance(pole.position,goal)
          if not score or d<score then best,score=pole.position,d end
        end
      end
      if not best then s.action='Нет действующей электросети';return false end
      if distance(best,goal)<=7.5 then
        local source=bot.surface.find_entity('small-electric-pole',best)
        local target=bot.surface.find_entity('small-electric-pole',goal)
        if source and target and source~=target then
          io.task(s,'wire',{entity=source.name,x=best.x,y=best.y,connector=5,other=target.name,position=goal,other_connector=5},'Соединяю электрические сети')
        else s.action='Проверяю покрытие электросети' end
      else
        local p=next_wire_pole(bot,best,goal,mask,wire_offsets) or
          next_wire_pole(bot,best,goal,mask,flexible_wire_offsets)
        if p then s.route_error=nil;io.build(bot,s,{{name='small-electric-pole',position=p,direction=0}})
        else s.action='Нет места для соединяющей опоры';s.route_error='power:'..goal.x..':'..goal.y end
      end
      return false
    end
  end
  return true
end
return network
