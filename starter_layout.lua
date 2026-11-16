local layout = {}
local blueprint = require("starter_blueprint")
local distance = require("character").distance

local dirs = {{0,-1}, {1,0}, {0,1}, {-1,0}}

function layout.at(bot, name, p)
  local e = bot.surface.find_entity(name, p)
  if e and e.force == bot.force and distance(e.position, p) < 0.15 then return e end
end

local function placeable(bot, name, p, direction)
  return bot.surface.can_place_entity{
    name = name, position = p, direction = direction, force = bot.force,
    build_check_type = defines.build_check_type.manual
  }
end

local function buildable(bot, name, p, direction)
  local e = layout.at(bot, name, p)
  return e and (e.direction == direction or name == "pipe" or name == "small-electric-pole" or name == "lab" or name == "stone-furnace" or name == "wooden-chest" or name == "iron-chest" or name == "assembling-machine-1")
    or placeable(bot, name, p, direction)
end

local function pos(x,y)
  return {x = x, y = y}
end

function layout.drop_sink(drill,name)
  local p = drill.drop_position
  local tile = {x=math.floor(p.x)+0.5,y=math.floor(p.y)+0.5}
  local reach = name=="wooden-chest" and 0.1 or 1
  for _, e in ipairs(drill.surface.find_entities_filtered{name=name,position=tile,radius=1.45,force=drill.force}) do
    if e~=drill and math.abs(e.position.x-tile.x)<reach and math.abs(e.position.y-tile.y)<reach then return e end
  end
end

local function candidate_ore(bot, p, ore)
  return bot.surface.count_entities_filtered{type = "resource", name = ore,
    area = {{p.x-1,p.y-1},{p.x+0.99,p.y+0.99}}, limit = 1} > 0
end

local function deposit(bot,state,ore)
  local rows={}
  local resources=bot.surface.find_entities_filtered{name=ore,type="resource",position=state.home,radius=176}
  for _, entity in ipairs(resources) do
    local x,y=math.floor(entity.position.x),math.floor(entity.position.y)
    rows[x]=rows[x] or {}
    rows[x][y]=entity.amount
  end
  return resources,rows
end

local function deposit_quality(rows,p)
  local amount,coverage=0,0
  for x=p.x-1,p.x do
    for y=p.y-1,p.y do
      local count=rows[x] and rows[x][y]
      if count then amount,coverage=amount+count,coverage+1 end
    end
  end
  local margin=0
  for ring=1,4 do
    for x=p.x-1-ring,p.x+ring do
      for y=p.y-1-ring,p.y+ring do
        if not (rows[x] and rows[x][y]) then return amount,coverage,margin end
      end
    end
    margin=ring
  end
  return amount,coverage,margin
end

function layout.has_ore(bot,p,ore)
  return candidate_ore(bot,p,ore)
end

function layout.units(bot, state, ore, sink)
  local drills = bot.surface.find_entities_filtered{name = "burner-mining-drill",
    force = bot.force, position = state.home, radius = 180}
  local units, used = {}, {}
  for _, drill in ipairs(drills) do
    if candidate_ore(bot, drill.position, ore) then
      local output = layout.drop_sink(drill,sink)
      if output and output.valid and (ore=="stone" or not used[output.unit_number]) then
        used[output.unit_number] = true
        units[#units+1] = {drill = drill, sink = output}
      end
    end
  end
  return units
end

local function intersects(a,b)
  return math.abs(a.x-b.x)<2 and math.abs(a.y-b.y)<2
end

-- The demonstration uses two touching drill rows, with furnaces on the outside.
-- Keep the whole block on one grid, leaving the rest of the deposit for electrics.
local function smelting_plan(bot,state,ore,avoid)
  local resources,rows=deposit(bot,state,ore)
  local width=ore=="iron-ore" and 8 or 4
  local depth=ore=="iron-ore" and 2 or 1
  local best,best_score
  local quality={}
  local function rating(p)
    local key=p.x..":"..p.y
    if not quality[key] then quality[key]={deposit_quality(rows,p)} end
    return table.unpack(quality[key])
  end
  for _, resource in ipairs(resources) do
    local x,y=math.floor(resource.position.x),math.floor(resource.position.y)
    for turn=0,3 do
      local sites,penalty={},0
      for row=0,depth-1 do
        for column=0,width-1 do
          local dx,dy=column*2,row*2
          local sx,sy=dx,dy+(row==0 and -2 or 2)
          for _=1,turn do dx,dy=-dy,dx; sx,sy=-sy,sx end
          local p,q=pos(x+dx,y+dy),pos(x+sx,y+sy)
          local direction=(turn*4+(row==0 and 0 or 8))%16
          local key=ore..":"..p.x..":"..p.y..":"..direction
          local amount,coverage,margin=rating(p)
          if coverage>=3 and not avoid[key] and
            buildable(bot,"burner-mining-drill",p,direction) and buildable(bot,"stone-furnace",q,0) then
            sites[#sites+1]={drill=p,sink=q,direction=direction,key=key,ore=ore}
            penalty=penalty+(3-math.min(3,margin))*10-math.log(1+amount/500)*3
          end
        end
      end
      if #sites>=math.min(4,width) then
        local rank=(width*depth-#sites)*1000+penalty+distance(bot.position,sites[1].drill)*0.5
        if not best_score or rank<best_score then best,best_score=sites,rank end
      end
    end
  end
  return best
end

function layout.planned_pair(bot,state,ore,avoid,planned)
  state.smelting_sites=state.smelting_sites or {}
  local sites=state.smelting_sites[ore]
  if not sites then
    sites=smelting_plan(bot,state,ore,avoid)
    state.smelting_sites[ore]=sites
  end
  for _, p in ipairs(sites or {}) do
    local reserved=false
    for _, q in ipairs(planned or {}) do if p.key==q.key then reserved=true; break end end
    local drill=layout.at(bot,"burner-mining-drill",p.drill)
    local furnace=layout.at(bot,"stone-furnace",p.sink)
    if not reserved and not avoid[p.key] and not (drill and furnace and layout.drop_sink(drill,"stone-furnace")==furnace) and
      buildable(bot,"burner-mining-drill",p.drill,p.direction) and buildable(bot,"stone-furnace",p.sink,0) then return p end
  end
end

local function chest_offset(direction)
  local x,y=-0.35,-1.3
  for _=1,direction/4 do x,y=-y,x end
  return math.floor(x)+0.5,math.floor(y)+0.5
end

function layout.pair(bot, state, ore, sink, avoid, planned)
  if sink=="stone-furnace" then return layout.planned_pair(bot,state,ore,avoid,planned) end
  local resources,rows=deposit(bot,state,ore)
  local best, score
  local assigned,drills = {},{}
  for _, item in ipairs(layout.units(bot,state,ore,sink)) do
    assigned[item.sink.unit_number]=true
    drills[item.drill.unit_number]=item.drill
  end
  for _, resource in ipairs(resources) do
    local p = pos(math.floor(resource.position.x), math.floor(resource.position.y))
    local amount,coverage,margin=deposit_quality(rows,p)
    if coverage>0 and placeable(bot, "burner-mining-drill", p, 0) then
      for i, vector in ipairs(dirs) do
        local direction = (i-1)*4
        local dx,dy = vector[1],vector[2]
        local output = pos(p.x+dx*2, p.y+dy*2)
        if sink == "wooden-chest" then
          local ox,oy=chest_offset(direction)
          output=pos(p.x+ox,p.y+oy)
        end
        local key = ore .. ":" .. p.x .. ":" .. p.y .. ":" .. direction
        local existing = layout.at(bot,sink,output)
        local reserved, planned_neighbor=false,0
        for _, next_pair in ipairs(planned or {}) do
          if intersects(p,next_pair.drill) or intersects(p,next_pair.sink) or
            intersects(output,next_pair.drill) or intersects(output,next_pair.sink) then
            reserved=true
            break
          end
          if next_pair.direction==direction and
            (dx==0 and p.y==next_pair.drill.y and math.abs(p.x-next_pair.drill.x)==2 or
             dy==0 and p.x==next_pair.drill.x and math.abs(p.y-next_pair.drill.y)==2) then
            planned_neighbor=planned_neighbor+1
          end
        end
        if not reserved and not avoid[key] and (not existing or ore=="stone" or not assigned[existing.unit_number]) and buildable(bot, sink, output, 0) then
          local adjacent = bot.surface.count_entities_filtered{position=p,radius=4.25,
            name={"burner-mining-drill","stone-furnace"},force=bot.force}
          local tight, aligned = 0,0
          for _, e in ipairs(bot.surface.find_entities_filtered{
            position=p,radius=5.8,name={"burner-mining-drill","stone-furnace"},force=bot.force
          }) do
            if e~=existing and (math.max(math.abs(e.position.x-p.x),math.abs(e.position.y-p.y))<3
                or math.max(math.abs(e.position.x-output.x),math.abs(e.position.y-output.y))<3) then
              local parallel=drills[e.unit_number] and e.direction==direction and
                (dx==0 and e.position.y==p.y and math.abs(e.position.x-p.x)==2
                  or dy==0 and e.position.x==p.x and math.abs(e.position.y-p.y)==2)
              local neighbor
              for _, other in ipairs(dirs) do
                local nx,ny=other[1]*2,other[2]*2
                if (dx*nx+dy*ny)==0 then
                  local matching=layout.at(bot,"burner-mining-drill",{x=p.x+nx,y=p.y+ny})
                  if matching and drills[matching.unit_number] and matching.direction==direction then
                    local side=layout.drop_sink(matching,sink)
                    if e==side then neighbor=true end
                  end
                end
              end
              if parallel then aligned=aligned+1
              elseif not neighbor then tight=tight+1 end
            end
          end
          local sharing=0
          if ore=="stone" then
            if existing and assigned[existing.unit_number] then sharing=700 end
            for other=0,12,4 do
              local x,y=chest_offset(other)
              local partner=pos(output.x-x,output.y-y)
              local _,covered=deposit_quality(rows,partner)
              if not intersects(p,partner) and covered>=2 and placeable(bot,"burner-mining-drill",partner,other) then
                sharing=sharing+130
              end
            end
          end
          local rank = math.max(0,3-margin)*90+(4-margin)*8+(4-coverage)*22
            -10*math.log(1+amount/500)+distance(bot.position,p)*0.6+distance(state.home,p)*0.15
            +adjacent*8+tight*115-aligned*49-planned_neighbor*52
            -sharing
          if not score or rank < score then
            best,score = {drill = p, sink = output, direction = direction, key = key, ore = ore},rank
          end
        end
      end
    end
  end
  return best
end

function layout.coal(bot, state, occupied)
  local resources,rows=deposit(bot,state,"coal")
  local best, score
  for _, ore in ipairs(resources) do
    local x,y = math.floor(ore.position.x), math.floor(ore.position.y)
    local p = {pos(x,y),pos(x+2,y),pos(x+2,y+2),pos(x,y+2)}
    local direction = {4,8,12,0}
    local valid,weakest,margin = true,math.huge,4
    for i = 1,4 do
      local reserved=false
      for _, used in ipairs(occupied or {}) do
        if math.abs(used.x-p[i].x)<2 and math.abs(used.y-p[i].y)<2 then reserved=true; break end
      end
      local amount,coverage,depth=deposit_quality(rows,p[i])
      weakest,margin=math.min(weakest,amount),math.min(margin,depth)
      if reserved or coverage==0 or not buildable(bot,"burner-mining-drill",p[i],direction[i]) then
        valid = false
        break
      end
    end
    local key = "coal:"..x..":"..y
    local extension=0
    for row=2,3 do
      for col=0,1 do
        local q=pos(x+col*2,y+row*2)
        local _,coverage=deposit_quality(rows,q)
        if coverage>=3 and placeable(bot,"burner-mining-drill",q,0) then extension=extension+1 end
      end
    end
    local rank = (4-margin)*180-35*math.log(1+weakest/500)+distance(bot.position,p[1])*0.4+distance(state.home,p[1])*0.15-extension*80
    if valid and not state.avoid[key] and (not score or rank < score) then
      best,score = {positions = p, directions = direction, key = key},rank
    end
  end
  return best
end

function layout.extend_coal(bot,state,group)
  local minx,miny,maxy=math.huge,math.huge,-math.huge
  for _, p in ipairs(group.positions) do
    minx,miny,maxy=math.min(minx,p.x),math.min(miny,p.y),math.max(maxy,p.y)
  end
  for _, sign in ipairs{1,-1} do
    local y=sign==1 and maxy+2 or miny-2
    if candidate_ore(bot,pos(minx,y),"coal") and candidate_ore(bot,pos(minx+2,y),"coal") and
      placeable(bot,"burner-mining-drill",pos(minx,y),0) and
      placeable(bot,"burner-mining-drill",pos(minx+2,y),8) then
      local top,bottom=math.min(miny,y),math.max(maxy,y)
      local p,d={},{}
      p[#p+1],d[#d+1]=pos(minx,top),4
      for row=top,bottom,2 do p[#p+1],d[#d+1]=pos(minx+2,row),row==bottom and 12 or 8 end
      for row=bottom,top+2,-2 do p[#p+1],d[#d+1]=pos(minx,row),0 end
      return {positions=p,directions=d,key=group.key..":extend:"..#p}
    end
  end
end

local power_template = {
  {"offshore-pump",0.5,0.5,0}, {"pipe",0.5,1.5,0},
  {"boiler",1,3.5,4}, {"steam-engine",4.5,3.5,4}, {"steam-engine",9.5,3.5,4},
  {"small-electric-pole",4.5,5.5,0}, {"small-electric-pole",9.5,5.5,0}
}

local function rotate(x,y,turns)
  for _ = 1,turns do x,y = -y,x end
  return x,y
end

local function power_candidate(bot,x,y,turns)
  local parts = {}
  for _, item in ipairs(power_template) do
    local dx,dy = rotate(item[2],item[3],turns)
    local p, d = pos(x+dx,y+dy),(item[4]+4*turns)%16
    if not buildable(bot,item[1],p,d) then return end
    parts[#parts+1] = {name = item[1], position = p, direction = d}
  end
  return parts
end

function layout.power(bot,state,center,radius)
  local tiles = bot.surface.find_tiles_filtered{position = center, radius = radius,
    collision_mask = "water_tile"}
  local best,score
  for _, tile in ipairs(tiles) do
    local x,y = tile.position.x,tile.position.y
    for turn = 0,3 do
      local dx,dy = rotate(0,1,turn)
      -- Convert the adjacent land cell to the rotated template origin.
      local ox,oy = rotate(0.5,0.5,turn)
      local bx,by = x+dx+0.5-ox,y+dy+0.5-oy
      if not bot.surface.get_tile(x+dx,y+dy).collides_with("water_tile") then
        local rank = distance(state.home,pos(bx,by))
        if not score or rank < score then
          local candidate = power_candidate(bot,bx,by,turn)
          if candidate then
            local reserve = 1
            for row = 1,19 do
              local rx,ry = rotate(0,row*4,turn)
              local a,b = rotate(1,3.5,turn)
              local c,d = rotate(4.5,3.5,turn)
              local e,f = rotate(9.5,3.5,turn)
              if not placeable(bot,"boiler",pos(bx+rx+a,by+ry+b),(4+4*turn)%16)
                or not placeable(bot,"steam-engine",pos(bx+rx+c,by+ry+d),(4+4*turn)%16)
                or not placeable(bot,"steam-engine",pos(bx+rx+e,by+ry+f),(4+4*turn)%16) then break end
              reserve = reserve+1
            end
            rank = rank + (20-reserve)*9
            if not score or rank < score then
              best,score = {parts = candidate, reserve = reserve, origin = nil, turn=turn, base=pos(bx,by)},rank
            end
          end
        end
      end
    end
  end
  return best
end

function layout.boiler_feed(bot,power)
  if not power.base then return end
  local parts={}
  for _, part in ipairs{{"wooden-chest",-1.5,3.5,0},{"inserter",-0.5,3.5,12},{"small-electric-pole",-0.5,5.5,0}} do
    local x,y=rotate(part[2],part[3],power.turn)
    local p=pos(power.base.x+x,power.base.y+y)
    local direction=(part[4]+power.turn*4)%16
    if not buildable(bot,part[1],p,direction) then return end
    parts[#parts+1]={name=part[1],position=p,direction=direction}
  end
  return parts
end

function layout.blueprint_at(bot,origin)
  local parts = {}
  for _, entry in ipairs(blueprint) do
    local p = pos(origin.x+entry.x,origin.y+entry.y)
    if not buildable(bot,entry.name,p,entry.direction) then return end
    parts[#parts+1] = {id = entry.id,name = entry.name, position = p, direction = entry.direction, recipe = entry.recipe}
  end
  return parts
end

function layout.factory(bot, state, center, radius)
  local best,score
  local power = state.power.parts[6].position
  for x = math.floor(center.x-radius),math.floor(center.x+radius),2 do
    for y = math.floor(center.y-radius),math.floor(center.y+radius),2 do
      local p = pos(x,y)
      local rank = distance(state.home,p)+distance(power,p)*0.65
      if not score or rank < score then
        local area = {{x,y},{x+16,y+12}}
        if bot.surface.count_entities_filtered{area=area,type="resource",limit=1} == 0 then
          local parts = layout.blueprint_at(bot,p)
          if parts then best,score = {origin=p,parts=parts},rank end
        end
      end
    end
  end
  return best
end

function layout.next_pole(bot, start, goal, origin)
  local frontier = {{p=start,steps=0,score=0}}
  local visited = {}
  local offsets = {{6,0},{0,6},{-6,0},{0,-6},{4,4},{4,-4},{-4,4},{-4,-4},
    {3,0},{0,3},{-3,0},{0,-3}}
  for _ = 1,2200 do
    if #frontier==0 then return end
    local best=1
    for i=2,#frontier do if frontier[i].score<frontier[best].score then best=i end end
    local node=frontier[best]
    frontier[best]=frontier[#frontier]
    frontier[#frontier]=nil
    if distance(node.p,goal)<=7 then return node.first end
    for _, v in ipairs(offsets) do
      local p=pos(node.p.x+v[1],node.p.y+v[2])
      local key=p.x..":"..p.y
      local inside=p.x>=origin.x and p.x<origin.x+16 and p.y>=origin.y and p.y<origin.y+12
      local remaining=distance(p,goal)
      if not visited[key] and not inside and remaining<distance(start,goal)+45 then
        visited[key]=true
        if placeable(bot,"small-electric-pole",p,0) then
          frontier[#frontier+1]={p=p,first=node.first or p,steps=node.steps+1,
            score=node.steps+1+remaining/4}
        end
      end
    end
  end
end

return layout
