local companion = require("character")
local starter = require("starter")
local campaign = require("campaign")
local jobs = require("jobs")

local pairing = {}
local resources = {stone=true, coal=true, ["iron-ore"]=true, ["copper-ore"]=true}

function pairing.offer(player)
  assert(game.is_multiplayer() and player.admin, "Привязка ИИ доступна администратору сетевой игры")
  local code = ("%08d"):format((math.random(0, 99999999)+game.tick)%100000000)
  storage.ai_offer = {code=code, owner=player.index, expires=game.tick+36000}
  return code
end

function pairing.revoke(player)
  assert(player.admin, "Отключить ИИ может администратор")
  storage.ai_offer, storage.ai_link = nil, nil
  player.print("Подключение ИИ отключено.")
end

local function owner(index)
  local player = game.get_player(index)
  assert(player and player.connected and player.admin, "Администратор, выдавший доступ, должен быть в игре")
  return player
end

local function status()
  local bot = storage.bot
  local result = {tick=game.tick, starter=starter.status(), campaign=campaign.status(),
    live=bot and bot.valid or false, jobs=jobs.status{}}
  if result.live then
    result.position = bot.position
    result.surface = bot.surface.name
    result.inventory = bot.get_main_inventory().get_contents()
  end
  return result
end

function pairing.dispatch(request)
  local token = request.token
  assert(type(token)=="string" and #token==64 and token:match("^%x+$"), "Invalid bridge identity")
  local args = request.args or {}
  if request.method=="pair" then
    local offer = assert(storage.ai_offer, "Нажмите «Данные для подключения» в панели «Напарник»")
    assert(game.tick<offer.expires and args.code==offer.code, "Код неверен или истёк")
    local player = owner(offer.owner)
    storage.ai_link, storage.ai_offer = {token=token,owner=player.index}, nil
    player.print("ИИ подключён к Sam. Доступ можно отозвать в панели «Напарник».")
    return {paired=true}
  end
  local link = storage.ai_link
  assert(link and link.token==token, "Сначала привяжите ИИ кодом из панели «Напарник»")
  local player = owner(link.owner)
  if request.method=="status" then return status() end
  if request.method=="job_status" then
    assert(type(args.id)=="number" and args.id>=1 and args.id%1==0, "Invalid job ID")
    return jobs.status{id=args.id}
  end
  if request.method=="mine" then
    assert(resources[args.resource], "Unsupported resource")
    assert(type(args.count)=="number" and args.count>=1 and args.count<=100 and args.count%1==0, "Expected 1 to 100 items")
  elseif request.method~="come_here" then
    error("Unknown bridge method")
  end
  companion.spawn{player=player.name}
  local bot = companion.character()
  assert(player.force==bot.force and player.surface==bot.surface, "Sam на другой поверхности или в другой команде")
  if request.method=="mine" then
    return jobs.enqueue{kind="mine",args={name=args.resource,count=args.count,radius=64}}
  end
  local position = assert(player.surface.find_non_colliding_position("character",player.position,4,0.5), "Нет свободного места рядом")
  return jobs.enqueue{kind="move",args=position}
end

return pairing
