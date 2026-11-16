-- Incremental cardinal A*. Trees are passable in the plan and mined before building.
local routes={}
local directions={{0,-1,0},{1,0,4},{0,1,8},{-1,0,12}}
local function key(x,y) return x..':'..y end
local function push(h,v)
  h[#h+1]=v;local i=#h
  while i>1 do local p=math.floor(i/2);if h[p].f<=v.f then break end;h[i]=h[p];i=p end
  h[i]=v
end
local function pop(h)
  local first,last=h[1],table.remove(h)
  if #h>0 then
    local i=1
    while i*2<=#h do
      local c=i*2;if c<#h and h[c+1].f<h[c].f then c=c+1 end
      if h[c].f>=last.f then break end;h[i]=h[c];i=c
    end
    h[i]=last
  end
  return first
end
function routes.mask(parts,mask)
  mask=mask or {}
  for _,p in ipairs(parts) do
    local b=prototypes.entity[p.name].collision_box
    local w=math.max(math.abs(b.left_top.x),math.abs(b.right_bottom.x))
    local h=math.max(math.abs(b.left_top.y),math.abs(b.right_bottom.y))
    if (p.direction or 0)%8==4 then w,h=h,w end
    for x=math.floor(p.position.x-w),math.floor(p.position.x+w) do
      for y=math.floor(p.position.y-h),math.floor(p.position.y+h) do mask[key(x,y)]=true end
    end
  end
  return mask
end
function routes.begin(a,b,mask,underground,kind)
  local x,y,gx,gy=math.floor(a.x),math.floor(a.y),math.floor(b.x),math.floor(b.y)
  local k=key(x,y)
  return {start=k,goal=key(gx,gy),gx=gx,gy=gy,heap={{x=x,y=y,k=k,g=0,f=math.abs(x-gx)+math.abs(y-gy)}},
    costs={[k]=0},parents={},cache={},mask=mask or {},expanded=0,underground=underground,kind=kind,turn_cost=kind=='belt' and 3 or nil}
end
function routes.pipe_tile_available(bot,position)
  local surface=bot.surface
  if surface.get_tile(position).collides_with('water_tile') then return false end
  local pipe=surface.find_entity('pipe',position)
  -- Adjacent ordinary pipes join automatically, even if they were placed
  -- before either of the two segments had filled.
  for _,offset in ipairs{{0,0},{0,-1},{1,0},{0,1},{-1,0}} do
    local adjacent=surface.find_entity('pipe',{x=position.x+offset[1],y=position.y+offset[2]})
    if adjacent then
      for fluid in pairs(adjacent.get_fluid_contents()) do
        if fluid~='water' then return false end
      end
    end
  end
  if pipe and pipe.force==bot.force then return true end
  if surface.can_place_entity{name='pipe',position=position,force=bot.force,
      build_check_type=defines.build_check_type.manual} then return true end
  local box=prototypes.entity.pipe.collision_box
  local area={{position.x+box.left_top.x,position.y+box.left_top.y},{position.x+box.right_bottom.x,position.y+box.right_bottom.y}}
  local blockers=surface.find_entities_filtered{area=area,collision_mask=prototypes.entity.pipe.collision_mask.layers}
  if #blockers==0 then return false end
  for _,entity in ipairs(blockers) do
    if entity.type~='tree' and entity~=bot then return false end
  end
  return true
end
local function previous(s,node)
  return node.previous or s.parents[node.k]
end
local function used_tiles(s,node)
  local used={}
  while node do
    used[node.tile or node.k]=true
    if node.entry then used[node.entry]=true end
    node=previous(s,node)
  end
  return used
end
local function free(bot,s,x,y,k)
  if k==s.start or k==s.goal then
    return s.kind~='pipe' or (not s.mask[k] and routes.pipe_tile_available(bot,{x=x+.5,y=y+.5}))
  end
  if s.mask[k] then return false end
  if s.cache[k]~=nil then return s.cache[k] end
  local ok=bot.surface.is_chunk_generated{math.floor(x/32),math.floor(y/32)} and not bot.surface.get_tile(x,y).collides_with('water_tile')
  if ok and s.kind=='pipe' then
    ok=routes.pipe_tile_available(bot,{x=x+.5,y=y+.5})
    s.cache[k]=ok
    return ok
  end
  if ok then
    for _,e in ipairs(bot.surface.find_entities_filtered{area={{x+0.1,y+0.1},{x+0.9,y+0.9}}}) do
      if e.type~='tree' and e.type~='resource' and e.type~='character' and e.type~='item-entity' then ok=false;break end
    end
  end
  s.cache[k]=ok
  return ok
end
function routes.step(bot,s)
  if s.path then return s.path end
  if s.failed then return nil,s.failed end
  for _=1,180 do
    local v=pop(s.heap)
    if not v then s.failed='Не найден свободный маршрут';return nil,s.failed end
    if v.g==s.costs[v.k] then
      s.expanded=s.expanded+1
      if s.expanded>24000 then s.failed='Поиск маршрута исчерпал лимит';return nil,s.failed end
      if (v.tile or v.k)==s.goal then
        local path={}
        while v do
          table.insert(path,1,{x=v.x+0.5,y=v.y+0.5,underground_direction=v.under_direction,type=v.under_direction and 'output'})
          local prior=previous(s,v)
          if v.under_direction then
            local d=directions[v.under_direction/4+1]
            table.insert(path,1,{x=prior.x+d[1]+0.5,y=prior.y+d[2]+0.5,underground_direction=v.under_direction,type='input'})
          end
          v=prior
        end
        s.path=path;s.heap={};s.parents={};s.costs={};s.cache={};s.mask={}
        return path
      end
      -- Belt states carry their heading. A different heading may revisit
      -- the same tile, but a physical route can place only one belt there.
      local used=s.turn_cost and used_tiles(s,v) or {}
      local last=s.turn_cost and v or nil
      for _,d in ipairs(directions) do
        local x,y=v.x+d[1],v.y+d[2];local k=key(x,y)
        local turn=s.turn_cost and v.heading and v.heading~=d[3] and s.turn_cost or 0
        local state_key=s.turn_cost and k..'d'..d[3] or k
        local cost=v.g+1+turn
        if not used[k] and (not v.under_direction or v.under_direction==d[3]) and (not s.costs[state_key] or cost<s.costs[state_key]) and free(bot,s,x,y,k) then
          s.costs[state_key]=cost;s.parents[state_key]=v
          push(s.heap,{x=x,y=y,k=state_key,tile=k,heading=d[3],previous=last,g=cost,f=cost+math.abs(x-s.gx)+math.abs(y-s.gy)})
        end
        -- One ordinary tile precedes the input; an output must discharge forward.
        -- Endpoints remain clear of future construction. The tunnel may cross it.
        if s.underground and not v.under_direction and not used[k] and free(bot,s,x,y,k) and k~=s.goal then
          local obstacle=false
          for n=2,6 do
            local qx,qy=v.x+d[1]*n,v.y+d[2]*n;local qk=key(qx,qy)
            local open=free(bot,s,qx,qy,qk)
            if n>=3 and obstacle and open and qk~=s.goal and not used[qk] then
              local state_key=qk..'u'..d[3];local cost=v.g+n+4+turn
              if not s.costs[state_key] or cost<s.costs[state_key] then
                s.costs[state_key]=cost;s.parents[state_key]=v
                push(s.heap,{x=qx,y=qy,k=state_key,tile=qk,entry=k,previous=last,g=cost,f=cost+math.abs(qx-s.gx)+math.abs(qy-s.gy),under_direction=d[3],heading=d[3]})
              end
            end
            if not open then obstacle=true end
          end
        end
      end
    end
  end
end
function routes.belts(path,final_direction)
  local out={}
  for i,p in ipairs(path) do
    local q=path[i+1];local d=final_direction or 0
    if q then d=q.x>p.x and 4 or q.x<p.x and 12 or q.y>p.y and 8 or 0 end
    out[#out+1]={name=p.underground_direction and 'underground-belt' or 'transport-belt',position={x=p.x,y=p.y},direction=p.underground_direction or d,type=p.type}
  end
  return out
end
return routes
