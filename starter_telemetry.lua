-- Stage measurements for the starter plan. Collected in game ticks by code only;
-- nothing here changes what the planner decides.
local layout = require("starter_layout")

local telemetry = {}
local max_events = 300
local counters = {"jobs_done","jobs_failed","jobs_cancelled","planning_delay_ticks","dispatch_delay_ticks",
  "path_requests","repaths","path_wait_ticks","travel_ticks","wait_craft_ticks","wait_other_ticks",
  "wait_player_ticks","craft_busy_ticks","paused_ticks"}

local function seconds(ticks)
  return math.floor(ticks/6+0.5)/10
end

local function current(s)
  local t=s.telemetry
  local record=t and t.stages[#t.stages]
  if record and not record.finished_tick then return record,t end
end

local function event(t,stage,name,tick,partial)
  if #t.log>=max_events then return end
  t.log[#t.log+1]={tick=tick,stage=stage,event=name,partial=partial or nil}
end

-- What the base hands over to the next stage.
local function snapshot(s,bot)
  if not bot or not bot.valid then return end
  local items={}
  for _, item in ipairs(bot.get_main_inventory().get_contents()) do
    items[item.name]=(items[item.name] or 0)+item.count
  end
  return {inventory=items,crafting_queue=bot.crafting_queue_size,
    iron_pairs=#layout.units(bot,s,"iron-ore","stone-furnace"),
    copper_pairs=#layout.units(bot,s,"copper-ore","stone-furnace")}
end

function telemetry.begin(s)
  s.telemetry={since=game.tick,partial=false,stages={},log={},marks={}}
end

-- Opens and closes stage records. A plan that was already running when the
-- measurements appeared gets a partial first record; earlier times stay unknown.
function telemetry.sync(s,bot)
  local t=s.telemetry
  if not t then
    t={since=game.tick,partial=true,stages={},log={},marks={}}
    s.telemetry=t
  end
  local record=t.stages[#t.stages]
  local done=s.mode=="done"
  if record and not record.finished_tick and (done or record.stage~=s.stage) then
    record.finished_tick=done and s.finished_tick or game.tick
    record.exit_state=snapshot(s,bot)
    event(t,record.stage,"stage_finished",record.finished_tick,record.partial)
  end
  if done then return end
  if not record or record.stage~=s.stage then
    record={stage=s.stage,started_tick=game.tick,partial=(#t.stages==0 and t.partial) or nil,job_ticks={}}
    for _, name in ipairs(counters) do record[name]=0 end
    t.stages[#t.stages+1]=record
    event(t,record.stage,"stage_started",game.tick,record.partial)
  end
end

-- First tick at which a named milestone was observed.
function telemetry.mark(s,name)
  local record,t=current(s)
  if not record or t.marks[name] then return end
  t.marks[name]=game.tick
  event(t,record.stage,name,game.tick,record.partial)
end

function telemetry.add(s,name,ticks)
  local record=current(s)
  if record then record[name]=record[name]+ticks end
end

-- Call once when the planner lets go of a job, whatever its outcome.
function telemetry.job(s,job)
  local record=current(s)
  if not record or not job then return end
  local outcome=job.status=="done" and "jobs_done" or job.status=="failed" and "jobs_failed" or "jobs_cancelled"
  record[outcome]=record[outcome]+1
  local finished=job.updated_tick or game.tick
  record.planning_delay_ticks=record.planning_delay_ticks+math.max(0,game.tick-finished)
  if job.started_tick then
    record.job_ticks[job.kind]=(record.job_ticks[job.kind] or 0)+math.max(0,finished-job.started_tick)
    record.dispatch_delay_ticks=record.dispatch_delay_ticks+math.max(0,job.started_tick-job.created_tick)
  end
  record.path_requests=record.path_requests+(job.path_requests or 0)
  record.repaths=record.repaths+(job.total_repaths or 0)
  record.path_wait_ticks=record.path_wait_ticks+(job.path_wait_ticks or 0)
  record.travel_ticks=record.travel_ticks+(job.travel_ticks or 0)
end

function telemetry.report(s,labels)
  local t=s.telemetry
  if not t then return {partial=true,stages={},stage_log={}} end
  local stages={}
  for _, record in ipairs(t.stages) do
    local last=record.finished_tick or game.tick
    local by_kind,accounted={},0
    for kind,ticks in pairs(record.job_ticks) do
      by_kind[kind]=seconds(ticks)
      accounted=accounted+ticks
    end
    accounted=accounted+record.planning_delay_ticks+record.dispatch_delay_ticks+record.wait_craft_ticks+
      record.wait_other_ticks+record.wait_player_ticks+record.paused_ticks
    stages[#stages+1]={stage=record.stage,goal=labels[record.stage],
      started_tick=record.started_tick,finished_tick=record.finished_tick,
      duration_seconds=seconds(last-record.started_tick),partial=record.partial,
      jobs_done=record.jobs_done,jobs_failed=record.jobs_failed,jobs_cancelled=record.jobs_cancelled,
      planning_delay_seconds=seconds(record.planning_delay_ticks),
      dispatch_delay_seconds=seconds(record.dispatch_delay_ticks),
      path_requests=record.path_requests,repaths=record.repaths,
      path_wait_seconds=seconds(record.path_wait_ticks),
      -- Time inside jobs, by kind. travel_seconds is the part of it spent
      -- approaching a target, path waits and route recovery included.
      job_seconds=by_kind,travel_seconds=seconds(record.travel_ticks),
      -- Planner had no job: hand-craft queue busy, or waiting on machines.
      wait_craft_seconds=seconds(record.wait_craft_ticks),
      wait_other_seconds=seconds(record.wait_other_ticks),
      wait_player_seconds=seconds(record.wait_player_ticks),
      paused_seconds=seconds(record.paused_ticks),
      -- Sampled every planning tick, with or without a job.
      craft_busy_seconds=seconds(record.craft_busy_ticks),
      -- Finished stages only: duration not covered by the parts above.
      unaccounted_seconds=record.finished_tick and seconds(last-record.started_tick-accounted) or nil,
      exit_state=record.exit_state}
  end
  local log={}
  for _, entry in ipairs(t.log) do
    log[#log+1]={tick=entry.tick,seconds=seconds(entry.tick-s.started_tick),stage=entry.stage,
      event=entry.event,partial=entry.partial}
  end
  return {since=t.since,partial=t.partial,stages=stages,stage_log=log}
end

return telemetry
