local starter = require("starter")
local companion = require("character")
local jobs = require("jobs")
local recording = require("recording")
local campaign = require('campaign')
local pairing = require("ai_pairing")
local connection_prompt = require("connection_prompt")

local ui = {}
local function refresh(player)
  local frame = player.gui.screen.codex_starter
  if not frame then return end
  frame.caption=companion.name
  local status = starter.status()
  local cs=campaign.status()
  local text = (status.goal and status.goal.."\n" or "")..(status.action or "")
  text = text.."\nЖелезо: "..(status.iron or 0).."   Медь: "..(status.copper or 0)
  text=text.."\nВ карманах: уголь "..(status.coal or 0).."   камень "..(status.stone or 0)
  if status.elapsed_seconds then
    local seconds=status.elapsed_seconds
    text=text..("\nВремя: %d:%02d / 15:00"):format(math.floor(seconds/60),seconds%60)
  end
  if cs.mode~='off' then
    text=text..'\nJump Start: '..(cs.goal or cs.mode)..'\n'..(cs.action or '')
    if cs.elapsed_seconds then text=text..('\nЭтап 2: %d:%02d · ориентир ~60 мин'):format(math.floor(cs.elapsed_seconds/60),cs.elapsed_seconds%60) end
    frame.campaign_controls.next_stage.enabled=cs.mode=='await_choice' or cs.mode=='helper' or cs.mode=='paused'
    frame.campaign_controls.confirm_site.enabled=cs.mode=='await_confirm'
  end
  if status.proposal then
    local p=status.proposal
    text=text..("\n%s: %.1f, %.1f"):format(p.kind=="power" and "Пар" or "It Begins",p.position.x,p.position.y)
    if p.reserve then text=text.." · ряд на "..p.reserve.." бойлеров" end
  end
  local recorded=recording.status(player)
  if recorded then text=text.."\nЗапись показа: "..recorded.." событий" end
  if frame.record then frame.record.caption=recorded and "Остановить запись" or "Записать мой показ" end
  frame.status.caption = text
  frame.controls.approve.enabled = status.proposal~=nil
  frame.controls.pause.enabled = status.mode=="running" or cs.mode~='off' and cs.mode~='paused'
  frame.controls.start.enabled = status.mode~="running" and status.mode~="done"
end

local function open(player)
  local frame=player.gui.screen.codex_starter
  if frame then
    frame.destroy()
    if player.gui.screen.sam_connection then player.gui.screen.sam_connection.destroy() end
    return
  end
  frame=player.gui.screen.add{type="frame",name="codex_starter",caption=companion.name,direction="vertical"}
  frame.auto_center=true
  local status=frame.add{type="label",name="status"}
  status.style.single_line=false
  status.style.maximal_width=510
  local row=frame.add{type="flow",name="controls",direction="horizontal"}
  row.add{type="button",name="start",caption="Начать / продолжить"}
  row.add{type="button",name="pause",caption="Пауза"}
  row.add{type="button",name="approve",caption="Принять место"}
  local nextrow=frame.add{type='flow',name='campaign_controls',direction='horizontal'}
  nextrow.add{type='button',name='next_stage',caption='Перейти к Jump Start',enabled=false}
  nextrow.add{type='button',name='confirm_site',caption='Подтвердить разметку',enabled=false}
  nextrow.add{type='button',name='helper',caption='Работать помощником'}
  frame.add{type="checkbox",name="observer",caption="Только наблюдаю · выбирать места автоматически",state=starter.status().auto_approve==true}
  frame.add{type="textfield",name="order",tooltip="Старт, пауза, принять, здесь, ко мне, добыть камень 20"}
  frame.add{type="button",name="send",caption="Отдать команду"}
  frame.add{type="button",name="record",caption="Записать мой показ"}
  if game.is_multiplayer() and player.admin then
    frame.add{type="button",name="ai_pair",caption="Данные для подключения"}
    frame.add{type="button",name="ai_revoke",caption="Отключить ИИ"}
  end
  refresh(player)
end

local function show_connection(player)
  local draft = connection_prompt(player,pairing.offer(player))
  local screen = player.gui.screen
  if screen.sam_connection then screen.sam_connection.destroy() end
  local dialog = screen.add{type="frame",name="sam_connection",caption="Данные для подключения",direction="vertical"}
  dialog.auto_center=true
  dialog.add{type="label",caption="Вставьте скопированный текст в локальный ИИ-клиент. Код действует 10 игровых минут."}
  local field = dialog.add{type="text-box",name="prompt",text=draft}
  field.style.width=620
  field.style.height=250
  field.word_wrap=true
  field.read_only=true
  dialog.add{type="label",name="copy_hint",caption="При первом подключении нажмите Ctrl+C."}
  local buttons = dialog.add{type="flow",name="buttons",direction="horizontal"}
  buttons.add{type="button",name="copy_connection",caption="Копировать"}
  buttons.add{type="button",name="close_connection",caption="Закрыть"}
  field.focus()
  field.select_all()
end

local function start(player,observer)
  companion.spawn{player=player.name}
  starter.start{auto_approve=observer}
end

local orders = {["камень"]="stone",["уголь"]="coal",["железо"]="iron-ore",["медь"]="copper-ore"}
local function order(player,line)
  line=line:match("^%s*(.-)%s*$")
  if line=="" then return end
  if line=='дальше' then campaign.start{};return end
  if line=='подтверждаю' then campaign.confirm{accept=true};return end
  if line=='другое место' then campaign.confirm{accept=false};return end
  if line=='помощник' then campaign.helper();return end
  if line=="старт" or line=="продолжить" then start(player,false); return end
  if line=="пауза" or line=="стоп" then if campaign.status().mode~='off' then campaign.pause() else starter.pause() end; return end
  if line=="принять" then starter.approve(); return end
  if line=="здесь" then starter.relocate(player.position); return end
  local bot=companion.character()
  assert(player.surface==bot.surface,"Напарник на другой поверхности")
  if line=="ко мне" then
    local p=player.surface.find_non_colliding_position("character",player.position,4,0.5)
    assert(p,"Нет свободного места рядом")
    jobs.enqueue{kind="move",args=p}
    return
  end
  local item,n=line:match("^добыть%s+([^%s]+)%s+(%d+)$")
  local name=orders[item]
  if name then
    n=tonumber(n)
    assert(n>=1 and n<=100,"Укажите от 1 до 100")
    jobs.enqueue{kind="mine",args={name=name,count=n,radius=64}}
    return
  end
  error("Команды: старт, пауза, принять, здесь, ко мне, добыть камень 20 (уголь, железо, медь)")
end

function ui.install(player)
  local screen = player.gui.screen
  local previous_dialog = screen.semen_connection
  if previous_dialog then previous_dialog.destroy() end
  if screen.codex_starter then screen.codex_starter.caption = companion.name end
  if not player.gui.top.codex_starter_toggle then
    player.gui.top.add{type="button",name="codex_starter_toggle",caption="Напарник"}
  end
end

commands.add_command("companion", "Open companion panel or issue a local order.",function(command)
  local player=command.player_index and game.get_player(command.player_index)
  if not player then return end
  local ok,err=pcall(function()
    if command.parameter then order(player,command.parameter) else open(player) end
  end)
  if not ok then player.print(tostring(err)) end
end)

script.on_event(defines.events.on_player_joined_game,function(event)
  local player=game.get_player(event.player_index)
  ui.install(player)
  recording.on_join(player)
end)

local function click(event)
  local e=event.element
  if not e or not e.valid then return end
  local player=game.get_player(event.player_index)
  if e.name=="codex_starter_toggle" then open(player); return end
  local dialog=player.gui.screen.sam_connection
  if dialog and e.parent==dialog.buttons then
    if e.name=="close_connection" then dialog.destroy();return end
    if e.name=="copy_connection" and player.admin then
      dialog.prompt.focus()
      dialog.prompt.select_all()
      local ok = pcall(helpers.write_file,"sam-engineer/clipboard.txt",dialog.prompt.text,false,player.index)
      dialog.copy_hint.caption=ok and "Если мост запущен, он скопирует текст. Иначе нажмите Ctrl+C."
        or "Нажмите Ctrl+C, чтобы скопировать выделенный текст."
      return
    end
  end
  if dialog and e.parent==dialog and e.name=="close_connection" then dialog.destroy();return end
  local frame=player.gui.screen.codex_starter
  if not frame or (e.parent~=frame and e.parent~=frame.controls and e.parent~=frame.campaign_controls) then return end
  local ok,err=pcall(function()
    if e.name=="start" then start(player,frame.observer.state)
    elseif e.name=="pause" then if campaign.status().mode~='off' then campaign.pause() else starter.pause() end
    elseif e.name=='next_stage' then campaign.start{test_mode=frame.observer.state}
    elseif e.name=='confirm_site' then campaign.confirm{accept=true}
    elseif e.name=='helper' then campaign.helper()
    elseif e.name=="approve" then starter.approve()
    elseif e.name=="ai_pair" then show_connection(player)
    elseif e.name=="ai_revoke" then
      pairing.revoke(player)
      if dialog then dialog.destroy() end
    elseif e.name=="record" then
      if recording.status(player) then recording.stop(player) else recording.start(player) end
    elseif e.name=="send" or e.name=="order" then order(player,frame.order.text); frame.order.text="" end
  end)
  if not ok then player.print(tostring(err)) end
  refresh(player)
end

script.on_event(defines.events.on_gui_click,click)
script.on_event(defines.events.on_gui_confirmed,click)

function ui.tick()
  if game.tick%60~=0 then return end
  for _, player in pairs(game.connected_players) do refresh(player) end
end

return ui
