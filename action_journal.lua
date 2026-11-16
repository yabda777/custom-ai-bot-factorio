local journal = {}

function journal.start(args)
  assert(type(args.id) == 'string' and args.id:match('^%x+$') and #args.id == 32, 'Invalid journal ID')
  storage.action_journal = {path = 'sam-' .. args.id .. '.jsonl', pending = {}}
  return storage.action_journal.path
end

function journal.flush()
  local log = storage.action_journal
  if not log or #log.pending == 0 then return true end
  helpers.write_file(log.path, table.concat(log.pending, '\n') .. '\n', true, 0)
  log.pending = {}
  return true
end

function journal.record(event)
  local log = storage.action_journal
  if not log then return end
  event.tick = game.tick
  event.phase = storage.campaign and storage.campaign.phase
  event.starter_stage = storage.starter and storage.starter.stage
  log.pending[#log.pending+1] = helpers.table_to_json(event)
  if #log.pending >= 64 then journal.flush() end
end

function journal.craft(bot, args)
  local count = bot.begin_crafting(args)
  if count > 0 and storage.action_journal then storage.action_journal.crafting = true end
  journal.record{event='craft_request', recipe=args.recipe, requested=args.count, queued=count, concurrent_job=storage.active}
  return count
end

function journal.tick(bot)
  local log = storage.action_journal
  if not log then return end
  if log.crafting and bot and bot.valid and bot.crafting_queue_size == 0 then
    journal.record{event='craft_queue_drained', concurrent_job=storage.active}
    log.crafting = nil
  end
  if game.tick % 300 == 0 then journal.flush() end
end

function journal.track(bot, job)
  if not storage.action_journal or not bot or not bot.valid then return end
  local p, surface = bot.position, bot.surface.index
  local previous = job.journal_position
  if not previous then
    job.journal_start = p
    job.distance_tiles = 0
  elseif surface == job.journal_surface then
    local dx, dy = p.x - previous.x, p.y - previous.y
    -- A character cannot walk one tile in one tick. Exclude teleports.
    local squared = dx*dx + dy*dy
    if squared < 1 then job.distance_tiles = job.distance_tiles + math.sqrt(squared)
    else job.position_jumps = (job.position_jumps or 0) + 1 end
  else
    job.position_jumps = (job.position_jumps or 0) + 1
  end
  job.journal_position, job.journal_surface = p, surface
end

return journal
