-- ItemArrange core: pure logic for laying out selected items at a fixed
-- interval and snapping each one's left edge to the grid line on its left.
-- No UI code, and nothing touches `reaper` at load time so the offline tests
-- can load it against a stub.
-- MC Scripts

local M = {}

M.VERSION = "1.3.0"
M.SCRIPT_NAME = "MC ItemArrange"

-- Snap tolerance expressed in grid-index units, not seconds. Doubles carry
-- about 1e-16 relative precision, so at 1e5 s a time value already wobbles by
-- ~1e-11 s; adding an epsilon in the time domain is unreliable (it misses
-- exact lines at large times), while the index domain stays well conditioned.
M.EPS_INDEX = 1e-6

M.GAP_DEFAULT = 1.0
M.MODE_DEFAULT = "end"   -- "start" | "end"

--------------------------------------------------------------------------------
-- Grid interfaces
--
-- A grid object must provide:
--   grid:prev_line(t)  -> time of the closest grid line <= t (or nil)
--   grid:describe()    -> short human readable description (optional)
--------------------------------------------------------------------------------

-- SWS/BR BR_GetPrevGridDivision is strictly-less-than, so ask for t+eps.
-- Its wobble tolerance is around 1e-9 s, hence EPS_TIME = 1e-6 s is safe and
-- still far below any real musical subdivision.
local EPS_TIME = 1e-6

local SWSGrid = {}
SWSGrid.__index = SWSGrid

function SWSGrid.new(prev_fn)
  return setmetatable({ prev_fn = prev_fn }, SWSGrid)
end

function SWSGrid:prev_line(t)
  -- prev_fn(t) gives the line strictly left of t, so an item sitting exactly on
  -- a line would jump to the previous one. Probing t+EPS_TIME picks up that
  -- line without ever crossing t.
  local line = self.prev_fn(t + EPS_TIME)
  if not line then return nil end
  if line > t then
    if (line - t) <= EPS_TIME then return t end
    return self.prev_fn(t)
  end
  return line
end

function SWSGrid:describe() return "sws" end

--------------------------------------------------------------------------------
-- Project math grid: decoded from projgridframe / projgriddiv.
--------------------------------------------------------------------------------
local MathGrid = {}
MathGrid.__index = MathGrid

function MathGrid.new(ctx)
  return setmetatable({ ctx = ctx }, MathGrid)
end

function MathGrid:prev_line(t)
  local ctx = self.ctx
  if ctx.mode == "frames" then
    -- Index-domain epsilon: t*fps lands on a whole number for exact lines.
    local n = math.floor(t * ctx.fps / ctx.frame_div + M.EPS_INDEX)
    return n * ctx.frame_div / ctx.fps
  elseif ctx.mode == "beats" then
    return self:prev_beat_line(t)
  end
  return nil
end

function MathGrid:prev_beat_line(t)
  local ctx = self.ctx
  local div = ctx.div_qn
  if not div or div <= 0 then return nil end
  local qn = ctx.time_to_qn(t)
  local n = math.floor(qn / div + M.EPS_INDEX)
  local line = ctx.qn_to_time(n * div)
  if ctx.swing and ctx.swing > 0 and n % 2 == 1 then
    local swung = ctx.qn_to_time(n * div + div * ctx.swing)
    if swung <= t then return swung end
    return ctx.qn_to_time((n - 1) * div)
  end
  if line > t then return ctx.qn_to_time((n - 1) * div) end
  return line
end

function MathGrid:describe() return self.ctx.mode end

--------------------------------------------------------------------------------
-- Constant spacing grid: used by the offline tests and as a last resort.
--------------------------------------------------------------------------------
local FixedGrid = {}
FixedGrid.__index = FixedGrid

function FixedGrid.new(origin, step)
  return setmetatable({ origin = origin, step = step }, FixedGrid)
end

function FixedGrid:prev_line(t)
  if not self.step or self.step <= 0 then return nil end
  local idx = math.floor((t - self.origin) / self.step + M.EPS_INDEX)
  return self.origin + idx * self.step
end

function FixedGrid:describe() return "fixed" end

M.SWSGrid = SWSGrid
M.MathGrid = MathGrid
M.FixedGrid = FixedGrid

--------------------------------------------------------------------------------
-- Arrange plan
--
-- Lays the selected items out in their current left-to-right order, at a fixed
-- interval, and snaps every resulting start to the grid line on its left.
--
-- opts:
--   mode        "start" = next start is previous start + gap
--               "end"   = next start is previous end + gap
--   gap_sec     interval in seconds (may be 0 or negative)
--   skip_locked default true
--   propagate_groups default true
--
-- items: array of { pos, length, lock, group, selected }
-- The anchor is the earliest selected item that is not locked: it keeps its
-- position and merely snaps left. Everything lays out forward from it.
--------------------------------------------------------------------------------
function M.build_arrange_plan(grid, items, opts)
  opts = opts or {}
  local mode = opts.mode or M.MODE_DEFAULT
  local gap = opts.gap_sec or M.GAP_DEFAULT
  local skip_locked = opts.skip_locked ~= false
  local propagate_groups = opts.propagate_groups ~= false
  local snap = opts.snap ~= false          -- true: land on the grid line
  -- With snapping off the interval has to be honoured exactly, so a beat or
  -- frame grid must not quantise it. The caller still passes a grid for the
  -- snapped path; it is simply not consulted here.

  local out = { moves = {}, skipped_locked = 0, overlaps = 0, ok = true,
                mode = mode, gap_sec = gap, snap = snap }

  -- Collect the items taking part, in current left-to-right order.
  local seq = {}
  for _, it in ipairs(items) do
    if it.selected then
      if (it.lock and it.lock ~= 0) and skip_locked then
        out.skipped_locked = out.skipped_locked + 1
      else
        seq[#seq + 1] = it
      end
    end
  end
  if #seq == 0 then
    out.ok = false
    out.error = "nothing_to_arrange"
    return out
  end
  table.sort(seq, function(a, b) return a.pos < b.pos end)

  -- Walk forward from the anchor. Every item is placed relative to the one
  -- before it: either its end plus the gap, or its start plus the gap.
  local placements = {}
  for i, it in ipairs(seq) do
    local desired
    if i == 1 then
      desired = it.pos                      -- the first item stays where it is
    else
      local prev = placements[i - 1]
      if mode == "end" then
        desired = prev.to + (prev.length or 0) + gap
      else
        desired = prev.to + gap
      end
    end

    local target
    if snap then
      local line = grid:prev_line(desired)
      if not line then
        out.ok = false
        out.error = "grid_line_unavailable"
        return out
      end
      target = line
    else
      -- No snapping: keep the requested interval exactly. Only the very first
      -- item, which does not move anyway, can be left where it is.
      target = desired
    end

    local snapped = math.max(target, 0)
    local delta = snapped - it.pos
    if math.abs(delta) <= 1e-12 then delta = 0 end

    local entry = {
      item = it,
      from = it.pos,
      to = snapped,
      delta = delta,
      length = it.length or 0,
      index = i,
    }
    placements[i] = entry
    out.moves[#out.moves + 1] = entry
  end

  -- Overlap count: started items that begin before the previous one ends.
  for i = 2, #placements do
    local prev, cur = placements[i - 1], placements[i]
    if cur.to < prev.to + (prev.length or 0) - 1e-9 then
      out.overlaps = out.overlaps + 1
    end
  end

  -- Group members that were not selected follow their group, exactly like
  -- dragging the selection in the arrange view.
  if propagate_groups then
    local group_delta = {}
    for _, mv in ipairs(out.moves) do
      local g = mv.item.group
      if g and g ~= 0 and group_delta[g] == nil then group_delta[g] = mv.delta end
    end
    if next(group_delta) ~= nil then
      local seen = {}
      for _, mv in ipairs(out.moves) do seen[mv.item] = true end
      for _, it in ipairs(items) do
        if not it.selected and not seen[it] and it.group and it.group ~= 0 then
          local delta = group_delta[it.group]
          if delta and delta ~= 0 and not (it.lock and it.lock ~= 0) then
            out.moves[#out.moves + 1] = {
              item = it, from = it.pos, to = it.pos + delta, delta = delta,
              length = it.length or 0, via_group = it.group,
            }
            seen[it] = true
          end
        end
      end
    end
  end

  table.sort(out.moves, function(a, b) return a.from < b.from end)
  return out
end

-- Did the plan change anything at all?
function M.plan_changed(plan)
  for _, mv in ipairs(plan.moves or {}) do
    if mv.delta ~= 0 then return true end
  end
  return false
end

function M.count_changed(plan)
  local n = 0
  for _, mv in ipairs(plan.moves or {}) do
    if mv.delta ~= 0 then n = n + 1 end
  end
  return n
end

-- Human readable summary used by the dialog and by the console message.
function M.describe_plan(plan)
  local changed = M.count_changed(plan)
  local parts = { ("%d 个对象，其中 %d 个需要移动"):format(#(plan.moves or {}), changed) }
  if plan.skipped_locked and plan.skipped_locked > 0 then
    parts[#parts + 1] = ("跳过 %d 个锁定对象"):format(plan.skipped_locked)
  end
  if plan.overlaps and plan.overlaps > 0 then
    parts[#parts + 1] = ("%d 处重叠"):format(plan.overlaps)
  end
  return table.concat(parts, "，")
end

return M
