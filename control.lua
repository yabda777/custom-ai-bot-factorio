local companion = require("character")
local blueprints = require("blueprints")
local jobs = require("jobs")

local starter = require("starter")
local ui = require("starter_ui")
local recording = require("recording")
local campaign = require('campaign')
local journal = require('action_journal')
local pairing = require("ai_pairing")

local function init()
  companion.init()
  for _, player in pairs(game.players) do ui.install(player) end
end

script.on_init(init)
script.on_configuration_changed(init)
script.on_event(defines.events.on_research_finished, function(event)
  journal.record{event='research_finished',technology=event.research.name,force=event.research.force.name}
end)
script.on_event(defines.events.on_tick, function()
  recording.tick()
  companion.track()
  jobs.tick()
  starter.tick()
  campaign.tick()
  ui.tick()
  journal.tick(storage.bot)
end)

commands.add_command("companion-spawn", "Create Sam near your character.", function(command)
  local player = command.player_index and game.get_player(command.player_index)
  if not player then return end
  local ok, result = pcall(companion.spawn, {player = player.name})
  player.print(ok and companion.name.." готов к работе." or tostring(result))
end)

local methods = {
  journal_start=journal.start, journal_flush=journal.flush,
  campaign_start=campaign.start,campaign_status=campaign.status,campaign_confirm=campaign.confirm,
  campaign_audit=campaign.audit,
  campaign_helper=campaign.helper,campaign_pause=campaign.pause,
  ping = function() return {version = script.active_mods[script.mod_name], tick = game.tick, live = storage.bot and storage.bot.valid or false} end,
  demo_prepare = recording.arm_demo,
  starter_start = starter.start, starter_pause = starter.pause, starter_status = starter.status,
  starter_approve = starter.approve, starter_relocate = starter.relocate,
  spawn = companion.spawn, observe = companion.inspect, enqueue = jobs.enqueue,
  status = jobs.status, cancel = jobs.cancel, retry = jobs.retry,
  import_blueprints = blueprints.import, list_blueprints = blueprints.list,
  describe_blueprint = blueprints.describe, inspect_machine = jobs.inspect_machine, inspect_recipe = jobs.inspect_recipe
}

local function upload(args)
  storage.uploads = storage.uploads or {}
  local uploads = storage.uploads
  for key, transfer in pairs(uploads) do
    if game.tick - transfer.tick > 3600 then uploads[key] = nil end
  end
  assert(type(args.key) == "string" and #args.key == 32 and args.key:match("^%x+$"), "Invalid upload ID")
  assert(type(args.chunk) == "string" and #args.chunk <= 2800, "Invalid upload chunk")
  if args.offset == 0 then
    assert(uploads[args.key] or table_size(uploads) < 8, "Too many uploads in progress")
    uploads[args.key] = {parts = {}, size = 0, tick = game.tick}
  end
  local transfer = uploads[args.key]
  assert(transfer and transfer.size == args.offset, "Upload expired or interrupted")
  assert(transfer.size + #args.chunk <= 2000000, "Blueprint file exceeds 2 MB")
  if args.book then
    uploads[args.key] = nil
    return blueprints.import{book = args.book, exchange = table.concat(transfer.parts)}
  end
  transfer.parts[#transfer.parts+1] = args.chunk
  transfer.size = transfer.size + #args.chunk
  transfer.tick = game.tick
  return {received = transfer.size}
end

methods.upload = upload

commands.add_command("codex-companion-rcon", "Local server interface for Custom AI Bot (ChatGPT-Codex).", function(command)
  if command.player_index then return end
  local ok, result = pcall(function()
    local request = helpers.json_to_table(command.parameter or "")
    assert(type(request) == "table", "Invalid request")
    return assert(methods[request.method], "Unknown method")(request.args or {})
  end)
  local payload
  if ok then payload = {ok = true, result = result}
  else payload = {ok = false, error = tostring(result)} end
  rcon.print("COMPANION " .. helpers.table_to_json(payload))
end)

commands.add_command("sam-ai-rcon", "Local interface for a paired AI client.", function(command)
  if command.player_index then return end
  local ok, result = pcall(function()
    local request = helpers.json_to_table(command.parameter or "")
    assert(type(request)=="table", "Invalid bridge request")
    return pairing.dispatch(request)
  end)
  local payload = ok and {ok=true,result=result} or {ok=false,error=tostring(result)}
  rcon.print("SAM " .. helpers.table_to_json(payload))
end)
