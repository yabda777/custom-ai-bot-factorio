local layout=require('campaign_layout')
local old=require('starter_layout')
local routes=require('campaign_routes')
local mining={}
local function key(x,y) return x..':'..y end
local function deposit(bot,home,ore)
  local all=bot.surface.find_entities_filtered{type='resource',name=ore,position=home,radius=180}
  local cells,seed,dist={},nil,math.huge
  for _,e in ipairs(all) do
    local x,y=math.floor(e.position.x),math.floor(e.position.y)
    cells[key(x,y)]={x=x,y=y,amount=e.amount}
    local d=(x-home.x)^2+(y-home.y)^2
    if d<dist then seed,dist=key(x,y),d end
  end
  if not seed then return nil end
  -- Only the connected starting deposit; never silently expand to a distant patch.
  local queue,seen,head={cells[seed]},{[seed]=true},1
  local result={cells={},left=math.huge,top=math.huge,right=-math.huge,bottom=-math.huge}
  while head<=#queue do
    local p=queue[head];head=head+1;result.cells[key(p.x,p.y)]=p.amount
    result.left,result.right=math.min(result.left,p.x),math.max(result.right,p.x)
    result.top,result.bottom=math.min(result.top,p.y),math.max(result.bottom,p.y)
    for dx=-1,1 do for dy=-1,1 do
      local k=key(p.x+dx,p.y+dy)
      if cells[k] and not seen[k] then seen[k]=true;queue[#queue+1]=cells[k] end
    end end
  end
  return result
end
local function coverage(patch,p)
  local n,total=0,0
  for x=math.floor(p.x)-2,math.floor(p.x)+2 do for y=math.floor(p.y)-2,math.floor(p.y)+2 do
    local v=patch.cells[key(x,y)]
    if v then n=n+1;total=total+v end
  end end
  return n,total
end
local function allowed(bot,parts,reservations)
  local area=layout.area(parts)
  for _,a in ipairs(reservations or {}) do if layout.overlap(area,a) then return false end end
  if bot.surface.count_tiles_filtered{area=area,collision_mask='water_tile',limit=1}>0 then return false end
  local removals={}
  for _,e in ipairs(bot.surface.find_entities_filtered{area=area}) do
    if e.name=='burner-mining-drill' and e.force==bot.force then
      removals[e.unit_number]=e
      local sink=old.drop_sink(e,'stone-furnace') or old.drop_sink(e,'wooden-chest')
      if sink then removals[sink.unit_number]=sink end
    end
  end
  for _,e in ipairs(bot.surface.find_entities_filtered{area=area}) do
    if e.type~='resource' and e.type~='tree' and e.type~='character' and e.type~='item-entity' and not removals[e.unit_number] then return false end
  end
  return true
end
local function goal(ore)
  return ore=='iron-ore' and 30 or ore=='copper-ore' and 14 or 10
end
mining.goal=goal

local function local_patch_bounds(patch,direction)
  local a=layout.rotate({x=patch.left,y=patch.top},(16-direction)%16)
  local b=layout.rotate({x=patch.right+1,y=patch.bottom+1},(16-direction)%16)
  return math.min(a.x,b.x),math.min(a.y,b.y),math.max(a.x,b.x)-1,math.max(a.y,b.y)-1
end

local function starter_iron_footprints(bot,home)
  local pairs={}
  for _,unit in ipairs(old.units(bot,{home=home},'iron-ore','stone-furnace')) do
    local footprint={}
    for _,entity in ipairs{unit.drill,unit.sink} do
      local box=entity.bounding_box
      for x=math.floor(box.left_top.x),math.floor(box.right_bottom.x) do
        for y=math.floor(box.left_top.y),math.floor(box.right_bottom.y) do footprint[key(x,y)]=true end
      end
    end
    pairs[#pairs+1]=footprint
  end
  return pairs
end

local function displaced_pairs(parts,footprints)
  if #footprints==0 then return 0 end
  local tiles=routes.mask(parts)
  local count=0
  for _,footprint in ipairs(footprints) do
    for cell in pairs(footprint) do
      if tiles[cell] then count=count+1;break end
    end
  end
  return count
end

function mining.plan(bot,s,ore,reservations,destination,collector_mask)
  s.patch=s.patch or deposit(bot,s.home,ore)
  if not s.patch then return nil,'Не найдено стартовое месторождение '..ore end
  s.kind=s.kind or (bot.force.technologies.logistics.researched and 'mining' or 'mining_basic')
  local height=s.kind=='mining' and 7 or 10
  -- Start a new search when loading a checkpoint made with the fixed westward layout.
  if not s.rotated then s.offset=0;s.best={};s.rotated=true end
  if ore=='iron-ore' and not s.starter_iron then s.starter_iron=starter_iron_footprints(bot,s.home) end
  local per_direction=6*height
  for _=1,6 do
    if s.offset>=4*per_direction then
      local best
      local center={x=(s.patch.left+s.patch.right+1)/2,y=(s.patch.top+s.patch.bottom+1)/2}
      for _,candidate in pairs(s.best) do
        local outlet=layout.rotate({x=-1,y=0},candidate.direction)
        local facing=(destination.x-center.x)*outlet.x+(destination.y-center.y)*outlet.y
        local d=math.abs(candidate.outlet.x-destination.x)+math.abs(candidate.outlet.y-destination.y)
        local score=math.min(goal(ore),candidate.capacity)*10000+facing*3-d+candidate.score/5000-(candidate.displaced or 0)*100
        if not best or score>best.rank or score==best.rank and candidate.direction<best.direction then
          candidate.rank=score;best=candidate
        end
      end
      if not best then return nil,'На стартовом месторождении нет места для модуля добычи с выходом' end
      return best
    end
    local direction=math.floor(s.offset/per_direction)*4
    local index=s.offset%per_direction
    local dx,dy=index%6,math.floor(index/6)
    s.offset=s.offset+1
    local left,top,right,bottom=local_patch_bounds(s.patch,direction)
    local modules,score={},0
    for x=left-3+dx,right,6 do
      for y=top-4+dy,bottom,height do
        local parts=layout.parts(s.kind,1,layout.rotate({x=x,y=y},direction),direction)
        local good,value=true,0
        for _,p in ipairs(parts) do if p.name=='electric-mining-drill' then
          local n,total=coverage(s.patch,p.position)
          if n<6 then good=false;break end
          value=value+n*100+math.sqrt(total)
          for _,r in ipairs(bot.surface.find_entities_filtered{type='resource',area={{p.position.x-2.5,p.position.y-2.5},{p.position.x+2.5,p.position.y+2.5}}}) do
            if r.name~=ore then good=false;break end
          end
        end end
        if good and allowed(bot,parts,reservations) then
          modules[#modules+1]={parts=parts,x=x,y=y,score=value};score=score+value
        end
      end
    end
    local previous=s.best[direction]
    local capacity=#modules*4
    if capacity>0 and (not previous or math.min(goal(ore),capacity)>=math.min(goal(ore),previous.capacity) and
        (s.starter_iron or score>previous.score or math.min(goal(ore),capacity)>math.min(goal(ore),previous.capacity))) then
      table.sort(modules,function(a,b)
        if a.score~=b.score then return a.score>b.score end
        if a.y~=b.y then return a.y<b.y end
        return a.x<b.x
      end)
      local candidate={modules=modules,score=score,ore=ore,direction=direction,capacity=capacity,kind=s.kind,patch=s.patch}
      if s.starter_iron and #s.starter_iron>0 then
        local limit=math.min(#modules,math.ceil(goal(ore)/4))
        local first,min_displaced=1,math.huge
        for i=1,limit do
          modules[1],modules[i]=modules[i],modules[1]
          local parts=mining.parts(candidate,4)
          local displaced=displaced_pairs(parts,s.starter_iron)
          if displaced<min_displaced then first,min_displaced=i,displaced end
          modules[1],modules[i]=modules[i],modules[1]
          if displaced==0 then break end
        end
        if first>1 then table.insert(modules,1,table.remove(modules,first)) end
        candidate.displaced=min_displaced
      end
      local value=math.min(goal(ore),capacity)*1e6-(candidate.displaced or 0)*1e5+score
      if (not previous or not previous.value or value>previous.value) and
          mining.collector(bot,candidate,destination,collector_mask) then
        candidate.value=value
        s.best[direction]=candidate
      end
    end
  end
end

function mining.parts(plan,target)
  local direction=plan.direction or 0
  local function world(x,y) return layout.rotate({x=x,y=y},direction) end
  local parts,seen,rows={}, {},{}
  local final_rows={}
  local limit=goal(plan.ore)
  for i,m in ipairs(plan.modules) do
    if (i-1)*4>=math.min(limit,plan.capacity) then break end
    local y=m.y+(plan.kind=='mining' and 2.5 or 4.5)
    local row=final_rows[y] or {left=m.x,right=m.x};final_rows[y]=row
    row.left=math.min(row.left,m.x);row.right=math.max(row.right,m.x)
  end
  local function add(p)
    local k=p.name..':'..key(p.position.x,p.position.y)
    if not seen[k] then seen[k]=true;parts[#parts+1]=p end
  end
  local remain=math.min(target,plan.capacity)
  for _,m in ipairs(plan.modules) do
    if remain<=0 then break end
    local n=0
    for _,p in ipairs(m.parts) do
      if p.name~='electric-mining-drill' then add(p)
      elseif remain>0 then add(p);remain=remain-1;n=n+1 end
    end
    if n>0 then
      local y=m.y+(plan.kind=='mining' and 2.5 or 4.5)
      rows[y]=rows[y] or {left=m.x,right=m.x}
      rows[y].left=math.min(rows[y].left,m.x);rows[y].right=math.max(rows[y].right,m.x)
    end
  end
  local exits={}
  for y,row in pairs(rows) do
    local left=final_rows[y] and final_rows[y].left or row.left
    -- Keep the eventual row outlet fixed. Build the upstream end only when
    -- its drills are needed, so it can remain occupied by starter pairs.
    for x=left,row.right,6 do
      for _,p in ipairs(layout.parts(plan.kind,1,world(x,y-(plan.kind=='mining' and 2.5 or 4.5)),direction)) do
        if p.name~='electric-mining-drill' then add(p) end
      end
    end
    local x=left-0.5
    if plan.kind=='mining' then
      x=left-1.5
      add{name='underground-belt',position=world(x,y),direction=(direction+12)%16,type='output'}
      x=x-1
    end
    add{name='transport-belt',position=world(x,y),direction=(direction+12)%16}
    exits[#exits+1]=plan.direction and {x=x,y=y,position=world(x,y)} or {x=x,y=y}
  end
  table.sort(exits,function(a,b) return a.y<b.y end)
  return parts,exits
end
-- Each row feeds a full splitter input. The other input carries the preceding
-- rows, and a single connected output preserves both lanes down the spine.
function mining.collector(bot,plan,destination,reserved)
  local mine_parts,exits=mining.parts(plan,goal(plan.ore))
  local occupied=routes.mask(mine_parts)
  local direction=plan.direction
  local left=local_patch_bounds(plan.patch,direction)
  local local_destination=layout.rotate(destination,(16-direction)%16)
  for _,heading in ipairs(local_destination.y<(exits[1].y+exits[#exits].y)/2 and {-1,1} or {1,-1}) do
    local vertical=heading==-1 and 0 or 8
    for offset=0,12 do
      local spine=left-2.5-offset
      for _,exit in ipairs(exits) do spine=math.min(spine,exit.x-2) end
      local parts,feeders={},{}
      local valid=true
      local function free(x,y)
        local pos=layout.rotate({x=x,y=y},direction)
        local k=key(math.floor(pos.x),math.floor(pos.y))
        if occupied[k] or reserved[k] or not bot.surface.is_chunk_generated{math.floor(pos.x/32),math.floor(pos.y/32)} or
            bot.surface.get_tile(pos).collides_with('water_tile') then return false end
        for _,e in ipairs(bot.surface.find_entities_filtered{area={{pos.x-.4,pos.y-.4},{pos.x+.4,pos.y+.4}}}) do
          if e.type~='resource' and e.type~='tree' and e.type~='item-entity' and e.type~='character' then return false end
        end
        return true
      end
      local function add(list,name,x,y,facing)
        list[#list+1]={name=name,position=layout.rotate({x=x,y=y},direction),direction=(direction+facing)%16}
      end
      if #exits==1 then
        local exit=exits[1]
        for x=exit.x-1,spine,-1 do
          if not free(x,exit.y) then valid=false;break end
          add(parts,'transport-belt',x,exit.y,12)
        end
        if valid and free(spine-1,exit.y) then
          plan.collector=parts;plan.feeders={[exit.y]={}}
          plan.outlet=layout.rotate({x=spine-1,y=exit.y},direction)
          return true
        end
        parts,valid={},true
      end
      local start=heading==-1 and #exits or 1
      local finish=heading==-1 and 1 or #exits
      local joins={}
      for i=start,finish,heading do
        local exit=exits[i]
        local first=i==start
        local turn_x=first and spine or spine+1
        local branch={}
        for x=exit.x-1,turn_x,-1 do
          if not free(x,exit.y) then valid=false;break end
          if x~=turn_x or not first then add(branch,'transport-belt',x,exit.y,x==turn_x and vertical or 12) end
        end
        if not valid then break end
        if not first then
          local y=exit.y+heading
          if not free(spine+1,y) then valid=false;break end
          joins[y]=true
        end
        feeders[exit.y]=branch
      end
      local y_end=exits[finish].y+heading*(#exits==1 and 0 or 2)
      for y=exits[start].y,y_end,heading do
        if not valid or not free(spine,y) then valid=false;break end
        if joins[y] then add(parts,'splitter',spine+.5,y,vertical)
        else add(parts,'transport-belt',spine,y,vertical) end
      end
      if valid and free(spine,y_end+heading) then
        local outlet=layout.rotate({x=spine,y=y_end+heading},direction)
        plan.collector=parts;plan.feeders=feeders;plan.outlet=outlet
        return true
      end
    end
  end
  return false
end

function mining.stone(bot,state,reservations)
  state.patch=state.patch or deposit(bot,state.home,'stone')
  if not state.patch then return nil,'Нет стартового камня' end
  state.index=state.index or 0
  local width=state.patch.right-state.patch.left+1
  -- Prefer automated furnaces, then the compact two-drill chest, then burners.
  local available=bot.force.recipes['electric-mining-drill'].enabled
  local variants=available and {3,2,1} or {1}
  for _=1,6 do
    if state.index>=width*(state.patch.bottom-state.patch.top+1)*#variants then return nil,'Не помещается добыча камня' end
    local cell=math.floor(state.index/#variants);local variant=variants[state.index%#variants+1];state.index=state.index+1
    local origin={x=state.patch.left+cell%width-3,y=state.patch.top+math.floor(cell/width)-3}
    local parts=layout.parts('stone',variant,origin,0)
    local good=true
    for _,p in ipairs(parts) do if p.name:find('mining%-drill') then
      if coverage(state.patch,p.position)<6 then good=false;break end
      local radius=p.name=='electric-mining-drill' and 2.5 or 1
      local found=bot.surface.find_entities_filtered{type='resource',area={{p.position.x-radius,p.position.y-radius},{p.position.x+radius,p.position.y+radius}}}
      if #found==0 then good=false end
      for _,r in ipairs(found) do if r.name~='stone' then good=false;break end end
    end end
    if good and allowed(bot,parts,reservations) then
      -- Poles are separate from the supplied book; find places covering consumers.
      return {parts=parts,variant=variant,origin=origin}
    end
  end
end
return mining
