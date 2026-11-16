local assets=require("campaign_assets")
local layout={}
local function rotate(p,d)
  local x,y=p.x,p.y
  for _=1,d/4 do x,y=-y,x end
  return {x=x,y=y}
end
layout.rotate=rotate
function layout.world(site,p)
  local r=rotate(p,site.direction)
  return {x=site.origin.x+r.x,y=site.origin.y+r.y}
end
local symmetric={['stone-furnace']=true,['small-electric-pole']=true,['iron-chest']=true,['wooden-chest']=true,lab=true,pipe=true,['assembling-machine-1']=true}
function layout.matches(e,p)
  local name=e.type=='entity-ghost' and e.ghost_name or e.name
  return name==p.name and (symmetric[name] or e.direction==p.direction or name=='steam-engine' and e.direction%8==p.direction%8) and
    (name~='underground-belt' or e.belt_to_ground_type==p.type)
end
function layout.parts(kind,index,origin,direction)
  assert(direction==0 or direction==4 or direction==8 or direction==12,"Cardinal direction required")
  local result={}
  for _, e in ipairs(assert(assets[kind][index]).entities) do
    local p=rotate(e.position,direction)
    result[#result+1]={name=e.name,position={x=p.x+origin.x,y=p.y+origin.y},
      direction=((e.direction or 0)+direction)%16,type=e.type,recipe=e.recipe,source_id=e.entity_number,bar=e.bar,control_behavior=e.control_behavior}
  end
  return result
end
function layout.area(parts)
  local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
  for _, e in ipairs(parts) do
    local b=prototypes.entity[e.name].collision_box
    local w=math.max(math.abs(b.left_top.x),math.abs(b.right_bottom.x))
    local h=math.max(math.abs(b.left_top.y),math.abs(b.right_bottom.y))
    if e.direction%8==4 then w,h=h,w end
    left,top=math.min(left,e.position.x-w),math.min(top,e.position.y-h)
    right,bottom=math.max(right,e.position.x+w),math.max(bottom,e.position.y+h)
  end
  return {{left-1,top-1},{right+1,bottom+1}}
end
function layout.overlap(a,b)
  return a[1][1]<b[2][1] and a[2][1]>b[1][1] and a[1][2]<b[2][2] and a[2][2]>b[1][2]
end
-- Reserve the final footprint before accepting stage 1. Trees are cleared by jobs later.
function layout.check_site(bot,origin,direction,reservations,allow_first)
  local area=layout.area(layout.parts("jump",5,origin,direction))
  for _, reserved in ipairs(reservations or {}) do
    if layout.overlap(area,reserved) then return nil,"Пересечение с запланированным участком" end
  end
  if bot.surface.count_tiles_filtered{area=area,collision_mask="water_tile",limit=1}>0 then return nil,"Вода в границах будущей базы" end
  local allowed={}
  if allow_first then
    for _,p in ipairs(layout.parts('jump',1,origin,direction)) do allowed[p.position.x..':'..p.position.y]=p end
  end
  for x=math.floor(area[1][1]/32),math.floor(area[2][1]/32) do
    for y=math.floor(area[1][2]/32),math.floor(area[2][2]/32) do
      if not bot.surface.is_chunk_generated{x,y} then return nil,'Участок ещё не разведан' end
    end
  end
  local trees={}
  for _, e in ipairs(bot.surface.find_entities_filtered{area=area}) do
    if e.type=="tree" then trees[#trees+1]=e
    elseif allowed[e.position.x..':'..e.position.y] and layout.matches(e,allowed[e.position.x..':'..e.position.y]) then
    elseif e~=bot and e.type~="character" and e.type~="item-entity" then
      return nil,"Место занято: "..e.name
    end
  end
  return {origin=origin,direction=direction,area=area,trees=trees}
end
-- Incremental search: bounded work per planning call, no whole-map synchronous scan.
function layout.find_site(bot,state,reservations)
  state.search=state.search or {index=0}
  for _=1,4 do
    local i=state.search.index;state.search.index=i+1
    if i>=3200 then return nil,"В стартовом районе не найдено свободное место",true end
    local turn=i%4
    local cell=math.floor(i/4)
    local ring=math.floor(math.sqrt(cell))+1
    local angle=(cell-(ring-1)^2)/(2*ring-1)*math.pi*2
    local p={x=math.floor(state.home.x+math.cos(angle)*(35+ring*8)),y=math.floor(state.home.y+math.sin(angle)*(35+ring*8))}
    local candidate=layout.check_site(bot,p,turn*4,reservations)
    if candidate then return candidate end
  end
end
-- A blueprint is validated by the complete constellation, not by any one ghost.
function layout.match_first(bot,anchor)
  local first=assets.jump[1].entities[1]
  local candidates=bot.surface.find_entities_filtered{type="entity-ghost",ghost_name=first.name,position=anchor,radius=300,force=bot.force}
  for _, ghost in ipairs(candidates) do
    for turn=0,12,4 do
      local offset=rotate(first.position,turn)
      local origin={x=ghost.position.x-offset.x,y=ghost.position.y-offset.y}
      local parts=layout.parts("jump",1,origin,turn)
      local valid=true
      for _, p in ipairs(parts) do
        local found=false
        for _, e in ipairs(bot.surface.find_entities_filtered{position=p.position,radius=0.05,force=bot.force}) do
          if layout.matches(e,p) then found=true;break end
        end
        if not found then valid=false;break end
      end
      if valid then return {origin=origin,direction=turn} end
    end
  end
end
return layout
