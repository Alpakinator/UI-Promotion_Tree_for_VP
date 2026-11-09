-- Geometry reuse and crossing presentation. No game state or UI controls here.
local cache, cacheAccessOrder, cacheHitCount, layoutSolveCount = {}, 0, 0, 0
local LAYOUT_CACHE_LIMIT = 48
local function encodeKeyPart(v)
  local s = tostring(v or "")
  return #s .. ":" .. s
end
local EMPTY_LIST = {}
local function sortedCopy(values)
  -- Callers only iterate the result. Zero/one-item lists are already sorted.
  if not values then
    return EMPTY_LIST
  end
  if #values < 2 then
    return values
  end
  local out = {}
  for _, value in ipairs(values or {}) do
    out[#out + 1] = value
  end
  table.sort(out)
  return out
end
function PromotionLayoutKey(graph, geometry)
  local out = { "presentation-v5-channels" }
  for _, name in ipairs(sortedCopy(graph.order)) do
    out[#out + 1] = encodeKeyPart(name)
    local node = graph.nodes[name]
    out[#out + 1] = encodeKeyPart(node.name) .. encodeKeyPart(node.family)
    for _, p in ipairs(sortedCopy(node.parents)) do
      out[#out + 1] = encodeKeyPart(p)
    end
    out[#out + 1] = ";" .. encodeKeyPart(node.requiredPrereq)
    for _, p in ipairs(sortedCopy(node.orPrereqs)) do
      out[#out + 1] = encodeKeyPart(p)
    end
  end
  out[#out + 1] = "roots"
  for _, name in ipairs(sortedCopy(graph.roots)) do
    out[#out + 1] = encodeKeyPart(name)
  end
  local chains = {}
  for _, chain in ipairs(graph.chains or {}) do
    local members = chain.nodes or chain
    local parts = {}
    for _, name in ipairs(members) do
      parts[#parts + 1] = encodeKeyPart(name)
    end
    chains[#chains + 1] = table.concat(parts, "|")
  end
  table.sort(chains)
  for _, chain in ipairs(chains) do
    out[#out + 1] = "chain" .. chain
  end
  local keys = {}
  for k, v in pairs(geometry) do
    if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = encodeKeyPart(k) .. encodeKeyPart(geometry[k])
  end
  return table.concat(out, "|")
end

-- The logical tree may be fitted, but its painted cards have a fixed width.
-- Centering each card on its logical rectangle preserves top/bottom ports;
-- only left/right endpoints and the body-height top/bottom contacts move.
function PromotionPaintedRoutes(layout, buttonW, buttonH, cardW)
  if
    type(layout) ~= "table"
    or type(layout.buttons) ~= "table"
    or type(buttonW) ~= "number"
    or type(buttonH) ~= "number"
    or type(cardW) ~= "number"
  then
    return nil, nil, "rendered card geometry is unavailable"
  end
  local scale = layout.scale or 1
  local portraitH = buttonH == 46 and 45 or buttonH == 60 and 64 or buttonH
  local bodyH = buttonH == 60 and 48 or portraitH - 2
  local ringInset = buttonH == 46 and 2 or 8
  local cards, byType, routes = {}, {}, {}
  local function pixel(v)
    return math.floor(v + 0.5)
  end
  for _, button in ipairs(layout.buttons) do
    local x = pixel(button.x * scale + (buttonW * scale - cardW) / 2)
    local y = pixel(button.y * scale + (buttonH * scale - portraitH) / 2)
    local card = {
      type = button.type,
      x = x,
      y = buttonH == 46 and y - 1 or y,
      right = x + cardW,
      bottom = y + portraitH,
      bodyTop = buttonH == 46 and y or y + pixel((portraitH - bodyH) / 2),
      bodyBottom = buttonH == 46 and y + 43 or y + pixel((portraitH - bodyH) / 2) + bodyH,
      logical = button,
    }
    cards[#cards + 1] = card
    byType[button.type] = card
  end
  local function append(route)
    local copy =
      { parent = route.parent, child = route.child, dim = route.dim, gaps = {}, points = {} }
    for _, gap in ipairs(route.gaps or {}) do
      copy.gaps[#copy.gaps + 1] = { segment = gap.segment, from = gap.from, to = gap.to }
    end
    for _, point in ipairs(route.points or {}) do
      copy.points[#copy.points + 1] = { x = point.x, y = point.y }
    end
    local p = copy.points
    if #p < 2 then
      return nil, "painted route has fewer than two points"
    end
    local parent, child = byType[route.parent], byType[route.child]
    local function move(point, neighbor, card)
      local b = card.logical
      if (point.y == b.y or point.y == b.y + buttonH) and point.x == neighbor.x then
        local portX = pixel(point.x * scale)
        if portX < card.x + 2 or portX > card.right - 2 then
          return false, "top/bottom pipe misses fixed card: " .. card.type
        end
      end
      if point.x == b.x and point.y == neighbor.y then
        point.x = (card.x + ringInset) / scale
      elseif point.x == b.x + buttonW and point.y == neighbor.y then
        point.x = card.right / scale
      elseif point.y == b.y and point.x == neighbor.x then
        point.y = card.bodyTop / scale
      elseif point.y == b.y + buttonH and point.x == neighbor.x then
        point.y = card.bodyBottom / scale
      end
      return true
    end
    if parent then
      local old = p[1].x == p[2].x and math.abs(p[2].y - p[1].y) or math.abs(p[2].x - p[1].x)
      local okay, reason = move(p[1], p[2], parent)
      if not okay then
        return nil, reason
      end
      local new = p[1].x == p[2].x and math.abs(p[2].y - p[1].y) or math.abs(p[2].x - p[1].x)
      for _, gap in ipairs(copy.gaps) do
        if gap.segment == 1 then
          gap.from = gap.from + new - old
          gap.to = gap.to + new - old
        end
      end
    end
    if child then
      local okay, reason = move(p[#p], p[#p - 1], child)
      if not okay then
        return nil, reason
      end
    end
    routes[#routes + 1] = copy
    return true
  end
  for _, route in ipairs(layout.sourceRoutes or {}) do
    local okay, reason = append(route)
    if not okay then
      return nil, nil, reason
    end
  end
  for _, route in ipairs(layout.routes or {}) do
    local okay, reason = append(route)
    if not okay then
      return nil, nil, reason
    end
  end
  return routes, cards
end

-- Screen pixels kept between a root row and the unit box's pipe where both
-- meet the root spine, so their native junction tiles do not overlap.
local SOURCE_JUNCTION_ROOM = 44

-- Center the *rendered* diagram inside the visible tree panel. The solver's
-- coordinates and all relative card/pipe positions stay untouched, including
-- cached layouts. A little clearance covers the native pipe
-- artwork around its centerline, so a tall tree remains within the viewport.
function PromotionTreeVerticalOffset(
  layout,
  viewportH,
  buttonW,
  buttonH,
  cardW,
  routes,
  sourceTargetY
)
  if not layout or type(viewportH) ~= "number" or viewportH <= 0 then
    return 0
  end
  local cards = layout.paintedCards
  if not cards then
    local _, paintedCards = PromotionPaintedRoutes(layout, buttonW, buttonH, cardW)
    cards = paintedCards
  end
  if not cards or #cards == 0 then
    return 0
  end
  local scale = layout.scale or 1
  local top, bottom = math.huge, -math.huge
  for _, card in ipairs(cards) do
    top = math.min(top, card.y)
    bottom = math.max(bottom, card.bottom)
  end
  local function includeRoutes(list)
    for _, route in ipairs(list or {}) do
      for _, point in ipairs(route.points or {}) do
        local y = point.y * scale
        -- Native TechBranches elbows reach 26px above a contact point;
        -- TechBranchH reaches 31px below it. Their fixed-size artwork is not
        -- scaled down with the logical tree at every junction.
        top = math.min(top, y - 26)
        bottom = math.max(bottom, y + 31)
      end
    end
  end
  if routes or layout.paintedRoutes then
    -- Painted routes already contain both prerequisites and source feeds.
    includeRoutes(routes or layout.paintedRoutes)
  else
    includeRoutes(layout.routes)
    includeRoutes(layout.sourceRoutes)
  end
  if layout.source then
    top = math.min(top, layout.source.y * scale - 26)
    bottom = math.max(bottom, layout.source.y * scale + 31)
  end
  local clearance = 8
  if bottom - top + 2 * clearance >= viewportH then
    return 0
  end
  local fitLo, fitHi = clearance - top, viewportH - clearance - bottom
  local desired = math.max(fitLo, math.min(math.floor((viewportH - top - bottom) / 2 + 0.5), fitHi))
  -- The unit box's pipe enters the root spine (the vertical source pipe at
  -- the roots' left). Centre the tree as far as that pipe still meets the
  -- spine head-on, so it never needs a bend: on a root row, or between two
  -- roots with room for the native junction art clear of the root rows.
  if sourceTargetY and layout.source then
    local sourceX, rows = layout.source.x, {}
    local spineTop, spineBottom = layout.source.y * scale, layout.source.y * scale
    for _, route in ipairs(layout.sourceRoutes or {}) do
      local points = route.points or {}
      local last = points[#points]
      if last then
        rows[#rows + 1] = last.y * scale
      end
      for _, point in ipairs(points) do
        if point.x == sourceX then
          spineTop = math.min(spineTop, point.y * scale)
          spineBottom = math.max(spineBottom, point.y * scale)
        end
      end
    end
    local function allowed(offset)
      if offset < fitLo or offset > fitHi then
        return false
      end
      local y = sourceTargetY - offset
      if y < spineTop - 0.5 or y > spineBottom + 0.5 then
        return false
      end
      for _, row in ipairs(rows) do
        local d = math.abs(y - row)
        if d > 1 and d < SOURCE_JUNCTION_ROOM then
          return false
        end
      end
      return true
    end
    local candidates = {
      math.max(sourceTargetY - spineBottom, math.min(desired, sourceTargetY - spineTop)),
    }
    for _, row in ipairs(rows) do
      for _, shift in ipairs({ 0, -SOURCE_JUNCTION_ROOM, SOURCE_JUNCTION_ROOM }) do
        candidates[#candidates + 1] = sourceTargetY - row + shift
      end
    end
    local best
    for _, offset in ipairs(candidates) do
      offset = math.floor(offset + 0.5)
      if allowed(offset) and (not best or math.abs(offset - desired) < math.abs(best - desired)) then
        best = offset
      end
    end
    if best then
      return best
    end
  end
  return desired
end

-- Emergency layout, used only if the live search raises an error: columns by
-- prerequisite depth, rows in name order, every pipe an elbow on its own
-- track. Plain, but every promotion and link is shown.
local EMERGENCY_MIN_SCALE = 0.8165 -- as PromotionTreeLayout's MIN_SCALE
function PromotionEmergencyLayout(graph, geometry, reason)
  local bw, bh = geometry.buttonW, geometry.buttonH
  local depth = {}
  local function depthOf(t, seen)
    if depth[t] then
      return depth[t]
    end
    seen = seen or {}
    if seen[t] then
      return 0
    end
    seen[t] = true
    local d = 0
    for _, p in ipairs(graph.nodes[t] and graph.nodes[t].parents or {}) do
      d = math.max(d, depthOf(p, seen) + 1)
    end
    depth[t] = d
    return d
  end
  local margin, rowGap, trackGap = 24, 22, 10
  -- The screen scrolls sideways but not vertically: a depth with more cards
  -- than fit in height at the smallest scale continues in further columns.
  local vhFit = geometry.viewportH or 1000
  local maxRows = math.max(1, math.floor((vhFit / EMERGENCY_MIN_SCALE - 2 * margin + rowGap) / (bh + rowGap)))
  local byDepth, depthsUsed = {}, 0
  for _, t in ipairs(graph.order) do
    local d = depthOf(t)
    byDepth[d] = byDepth[d] or {}
    table.insert(byDepth[d], t)
    depthsUsed = math.max(depthsUsed, d + 1)
  end
  local columns, columnsUsed, columnOf = {}, 0, {}
  for d = 0, depthsUsed - 1 do
    for i, t in ipairs(byDepth[d] or {}) do
      local c = columnsUsed + math.floor((i - 1) / maxRows)
      columns[c] = columns[c] or {}
      table.insert(columns[c], t)
      columnOf[t] = c
    end
    columnsUsed = columnsUsed + math.max(1, math.ceil(#(byDepth[d] or {}) / maxRows))
  end
  local links = {}
  for c = 0, columnsUsed - 1 do
    links[c] = 0
  end
  for _, t in ipairs(graph.order) do
    local c = columnOf[t]
    links[c] = links[c] + #(graph.nodes[t].children or {})
  end
  local x, columnX, channelStart = margin + 40, {}, {}
  for c = 0, columnsUsed - 1 do
    columnX[c] = x
    channelStart[c] = x + bw + 16
    x = channelStart[c] + math.max(40, (links[c] + 1) * trackGap) + 16
  end
  local width = x - 16 + margin
  local buttons, pos, rowsUsed = {}, {}, 0
  for c = 0, columnsUsed - 1 do
    for r, t in ipairs(columns[c] or {}) do
      local b = { type = t, x = columnX[c], y = margin + (r - 1) * (bh + rowGap) }
      buttons[#buttons + 1] = b
      pos[t] = b
      rowsUsed = math.max(rowsUsed, r)
    end
  end
  local height = 2 * margin + rowsUsed * (bh + rowGap) - rowGap
  local routes, track = {}, {}
  for _, t in ipairs(graph.order) do
    local a = pos[t]
    local c = columnOf[t]
    for _, child in ipairs(graph.nodes[t].children or {}) do
      local b = pos[child]
      if a and b then
        local ay, by = a.y + math.floor(bh / 2), b.y + math.floor(bh / 2)
        local points
        if ay == by then
          points = { { x = a.x + bw, y = ay }, { x = b.x, y = by } }
        else
          track[c] = (track[c] or 0) + 1
          local tx = channelStart[c] + track[c] * trackGap
          points = { { x = a.x + bw, y = ay }, { x = tx, y = ay }, { x = tx, y = by }, { x = b.x, y = by } }
        end
        routes[#routes + 1] = { parent = t, child = child, points = points, gaps = {} }
      end
    end
  end
  local vw, vh = geometry.viewportW or width, geometry.viewportH or height
  local scale = math.min(1, vw / width, vh / height)
  local overflow = scale < EMERGENCY_MIN_SCALE
  scale = math.max(EMERGENCY_MIN_SCALE, scale)
  return {
    buttons = buttons,
    routes = routes,
    sourceRoutes = {},
    width = math.max(width, vw / scale),
    height = math.max(height, vh / scale),
    contentWidth = width,
    contentHeight = height,
    scale = scale,
    overflow = overflow,
    tooTall = scale * height > vh,
    crossings = 0,
    underpasses = {},
    valid = false,
    violations = { "layout failed: " .. tostring(reason) },
    method = "emergency",
  }
end

-- Every tree is laid out by the live search (PromotionTreeLayoutSolve);
-- nothing is stored per tree. Should the search ever fail, the emergency
-- layout still shows the tree.
function PromotionLayoutChoose(graph, geometry)
  local solved, layout = pcall(PromotionTreeLayoutSolve, graph, geometry)
  if not solved or type(layout) ~= "table" or not layout.buttons or #layout.buttons == 0 then
    local reason = solved and "no cards placed" or layout
    local ok, emergency = pcall(PromotionEmergencyLayout, graph, geometry, reason)
    if ok then
      return emergency
    end
    return {
      buttons = {},
      routes = {},
      sourceRoutes = {},
      valid = false,
      violations = { "layout failed: " .. tostring(reason), "emergency layout failed: " .. tostring(emergency) },
    }
  end
  return layout
end
function PromotionLayoutCached(graph, geometry)
  local key = PromotionLayoutKey(graph, geometry)
  cacheAccessOrder = cacheAccessOrder + 1
  if cache[key] then
    cache[key].used = cacheAccessOrder
    cacheHitCount = cacheHitCount + 1
    return cache[key].layout, true
  end
  local layout = PromotionLayoutChoose(graph, geometry)
  layoutSolveCount = layoutSolveCount + 1
  local size, oldestKey, oldestAccessOrder = 0, nil, math.huge
  for k, entry in pairs(cache) do
    size = size + 1
    if entry.used < oldestAccessOrder then
      oldestKey, oldestAccessOrder = k, entry.used
    end
  end
  if size >= LAYOUT_CACHE_LIMIT then
    cache[oldestKey] = nil
  end
  cache[key] = { layout = layout, used = cacheAccessOrder }
  return layout, false
end
function PromotionLayoutCacheStats()
  return { hits = cacheHitCount, solves = layoutSolveCount }
end
function PromotionLayoutCacheClear()
  cache = {}
  cacheAccessOrder, cacheHitCount, layoutSolveCount = 0, 0, 0
end

-- The unit/class box is fixed to the left panel while the promotion geometry
-- is fitted inside the right viewport. Add its visual stem only after fitting
-- so no prerequisite, solver placement, or cache key depends on sidebar art.
function PromotionUnitSourceBridge(layout, originX, originY, boxRight, boxCentreY, boxHeight)
  if not layout or not layout.source or not layout.sourceRoutes or #layout.sourceRoutes == 0 then
    return nil
  end
  local scale = layout.scale or 1
  local sx, sy = layout.source.x, layout.source.y
  local bx = (boxRight - originX) / scale
  local by = (boxCentreY - originY) / scale
  if bx >= sx then
    return nil
  end
  local points = { { x = bx, y = by }, { x = sx, y = by } }
  if by ~= sy then
    points[#points + 1] = { x = sx, y = sy }
  end
  return { parent = "__PROMOTION_SOURCE__", child = "__PROMOTION_BOX__", points = points }
end

-- The box pipe meets the root spine at the box's height. When that height
-- lies on the spine, the source feeds start there instead of at the layout's
-- source point, so the box pipe runs straight on into the root level with it
-- (or meets the spine head-on between roots) and the spine branches up and
-- down from that point; no feed turns back along the box pipe. Returns the
-- routes to draw (a copy; the cached ones stay unchanged) with the box pipe.
function PromotionJoinUnitSource(layout, routes, originX, originY, boxRight, boxCentreY, boxHeight)
  local bridge = PromotionUnitSourceBridge(layout, originX, originY, boxRight, boxCentreY, boxHeight)
  local out = {}
  for i = 1, #routes do
    out[i] = routes[i]
  end
  if not bridge then
    return out, nil
  end
  local sx = layout.source.x
  local by = bridge.points[1].y
  local top, bottom = math.huge, -math.huge
  local feeds = {}
  for i, route in ipairs(out) do
    if route.parent == "__PROMOTION_SOURCE__" then
      if route.gaps and #route.gaps > 0 then
        out[#out + 1] = bridge
        return out, bridge
      end
      for _, point in ipairs(route.points) do
        if point.x == sx then
          top, bottom = math.min(top, point.y), math.max(bottom, point.y)
        end
      end
      feeds[#feeds + 1] = i
    end
  end
  -- Only head-on joins: on a root row, or clear of every root row by the
  -- room the junction art needs (a tree too tall to move may allow neither).
  -- A box pipe within two pixels of a root row snaps onto it.
  local scale = layout.scale or 1
  for _, i in ipairs(feeds) do
    local points = out[i].points
    if math.abs(points[#points].y - by) * scale <= 2 then
      by = points[#points].y
    end
  end
  local clear = #feeds > 0 and by >= top - 0.01 and by <= bottom + 0.01
  for _, i in ipairs(feeds) do
    local points = out[i].points
    local d = math.abs(points[#points].y - by) * scale
    if d > 0.01 and d < SOURCE_JUNCTION_ROOM then
      clear = false
    end
  end
  if clear then
    for _, i in ipairs(feeds) do
      local route = out[i]
      local last = route.points[#route.points]
      local points = { { x = sx, y = by } }
      if math.abs(last.y - by) > 0.01 then
        points[#points + 1] = { x = sx, y = last.y }
      end
      points[#points + 1] = { x = last.x, y = last.y }
      out[i] = { parent = route.parent, child = route.child, dim = route.dim, gaps = {}, points = points }
    end
    bridge.points = { { x = bridge.points[1].x, y = by }, { x = sx, y = by } }
  end
  out[#out + 1] = bridge
  return out, bridge
end
