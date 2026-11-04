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

local function between(v, a, b)
  return v > math.min(a, b) + 0.01 and v < math.max(a, b) - 0.01
end
local function cross(a, b, c, d)
  if a.y == b.y and c.x == d.x and between(c.x, a.x, b.x) and between(a.y, c.y, d.y) then
    return c.x, a.y
  end
  if a.x == b.x and c.y == d.y and between(a.x, c.x, d.x) and between(c.y, a.y, b.y) then
    return a.x, c.y
  end
end
local function distance(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y)
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

-- Reject routes hidden behind another painted card and native-art junctions
-- invalidated by the last few pixels of port adjustment.
function PromotionRenderedCardClear(layout, buttonW, buttonH, cardW)
  cardW = cardW or 160
  local audited = type(layout) == "table" and layout.paintedAudit
  if
    audited
    and audited.buttonW == buttonW
    and audited.buttonH == buttonH
    and audited.cardW == cardW
  then
    return audited.ok, audited.reason
  end
  local routes, cards, reason = PromotionPaintedRoutes(layout, buttonW, buttonH, cardW)
  if not routes then
    return false, reason
  end
  local function finish(ok, detail)
    layout.paintedAudit =
      { buttonW = buttonW, buttonH = buttonH, cardW = cardW, ok = ok, reason = detail }
    if ok then
      layout.paintedRoutes = routes
      layout.paintedCards = cards
    end
    return ok, detail
  end
  local scale = layout.scale or 1
  for _, card in ipairs(cards) do
    if
      card.x < 0
      or card.y < 0
      or (layout.width and card.right > layout.width * scale + 0.01)
      or (layout.height and card.bottom > layout.height * scale + 0.01)
    then
      return finish(false, "painted card exceeds fixed canvas: " .. card.type)
    end
  end
  if type(PipeManagerValidateNetwork) == "function" then
    local okay, nativeReason =
      PipeManagerValidateNetwork(routes, { scale = scale, nativeArt = scale < 0.999 })
    if not okay then
      return finish(false, "painted pipe: " .. tostring(nativeReason))
    end
  end
  local pad = 4
  for _, route in ipairs(routes) do
    for segment = 1, #(route.points or {}) - 1 do
      local a, b = route.points[segment], route.points[segment + 1]
      local ax, ay, bx, by = a.x * scale, a.y * scale, b.x * scale, b.y * scale
      for _, card in ipairs(cards) do
        if
          not (card.type == route.parent and segment == 1)
          and not (card.type == route.child and segment == #route.points - 1)
        then
          local touches = false
          if ay == by then
            touches = ay > card.y - pad
              and ay < card.bottom + pad
              and math.max(ax, bx) > card.x - pad
              and math.min(ax, bx) < card.right + pad
          elseif ax == bx then
            touches = ax > card.x - pad
              and ax < card.right + pad
              and math.max(ay, by) > card.y - pad
              and math.min(ay, by) < card.bottom + pad
          end
          if touches then
            return finish(false, route.parent .. " -> " .. route.child .. " near " .. card.type)
          end
        end
      end
    end
  end
  return finish(true)
end

-- Center the *rendered* diagram inside the visible tree panel. The solver's
-- coordinates and all relative card/pipe positions stay untouched, including
-- the cached and reviewed layouts. A little clearance covers the native pipe
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
  -- Translate the whole tree, without changing its internal layout, when its
  -- source can meet the sidebar centre while all painted bounds still fit.
  if sourceTargetY and layout.source then
    local aligned = sourceTargetY - layout.source.y * scale
    if aligned >= clearance - top and aligned <= viewportH - clearance - bottom then
      return aligned
    end
  end
  local desired = math.floor((viewportH - top - bottom) / 2 + 0.5)
  return math.max(clearance - top, math.min(desired, viewportH - clearance - bottom))
end

function PromotionPrepareUnderpasses(layout, graph, geometry)
  layout.underpasses = {}
  layout.underpassOrientation = {}
  local routes = {}
  for _, r in ipairs(layout.routes or {}) do
    routes[#routes + 1] = r
  end
  for _, r in ipairs(layout.sourceRoutes or {}) do
    routes[#routes + 1] = r
  end
  for _, r in ipairs(routes) do
    r.gaps = {}
  end
  local crossings = 0
  -- Bring each underpass run two rendered pixels closer to the overpass.
  -- Gaps are stored in logical coordinates, while the requested clearance
  -- change is in screen pixels and must survive uniformly fitted layouts.
  local halfGap = (geometry.underpassHalfGap or 10) - 2 / (layout.scale or 1)
  local underAtPoint = {}
  local function endpointClearance(horizontal, x, y)
    local nearest = math.huge
    for _, route in ipairs(routes) do
      for k = 1, #route.points - 1 do
        local a, b = route.points[k], route.points[k + 1]
        if
          (horizontal and a.y == b.y and a.y == y)
          or (not horizontal and a.x == b.x and a.x == x)
        then
          nearest = math.min(
            nearest,
            horizontal and math.min(math.abs(x - a.x), math.abs(x - b.x))
              or math.min(math.abs(y - a.y), math.abs(y - b.y))
          )
        end
      end
    end
    return nearest
  end
  for i = 1, #routes do
    for j = i + 1, #routes do
      local r, s = routes[i], routes[j]
      for ri = 1, #r.points - 1 do
        for si = 1, #s.points - 1 do
          local a, b, c, d = r.points[ri], r.points[ri + 1], s.points[si], s.points[si + 1]
          local x, y = cross(a, b, c, d)
          if x then
            crossings = crossings + 1
            if
              type(geometry.readabilityCrossingBudget) == "number"
              and geometry.readabilityCrossingBudget > 0
            then
              local under, over, index, first, last = r, s, ri, a, b
              local horizontalRoute, horizontalIndex, hFirst, hLast
              local verticalRoute, verticalIndex, vFirst, vLast
              if a.y == b.y then
                horizontalRoute, horizontalIndex, hFirst, hLast = r, ri, a, b
                verticalRoute, verticalIndex, vFirst, vLast = s, si, c, d
              else
                horizontalRoute, horizontalIndex, hFirst, hLast = s, si, c, d
                verticalRoute, verticalIndex, vFirst, vLast = r, ri, a, b
              end
              local pointKey = x .. "|" .. y
              local horizontalUnder = underAtPoint[pointKey]
              if horizontalUnder == nil then
                horizontalUnder = layout.underpassOverrides and layout.underpassOverrides[pointKey]
                if horizontalUnder == nil then
                  horizontalUnder = endpointClearance(true, x, y) > endpointClearance(false, x, y)
                end
                underAtPoint[pointKey] = horizontalUnder
                layout.underpassOrientation[pointKey] = horizontalUnder
              end
              if horizontalUnder then
                under, over, index, first, last =
                  horizontalRoute, verticalRoute, horizontalIndex, hFirst, hLast
              else
                under, over, index, first, last =
                  verticalRoute, horizontalRoute, verticalIndex, vFirst, vLast
              end
              local at = distance(first, { x = x, y = y })
              local length = distance(first, last)
              local from, to = math.max(0, at - halfGap), math.min(length, at + halfGap)
              -- Several logical edges may share one visible overpass. Keep
              -- every crossing record, but cut its physical gap only once.
              local alreadyCut = false
              for _, gap in ipairs(under.gaps) do
                if gap.segment == index and gap.from == from and gap.to == to then
                  alreadyCut = true
                  break
                end
              end
              if not alreadyCut then
                under.gaps[#under.gaps + 1] = { segment = index, from = from, to = to }
              end
              layout.underpasses[#layout.underpasses + 1] = {
                x = x,
                y = y,
                under = { parent = under.parent, child = under.child },
                over = { parent = over.parent, child = over.child },
              }
            end
          end
        end
      end
    end
  end
  layout.crossings = crossings
  return layout
end
-- Native pipe art and painted cards must both fit the finished geometry.
local function drawable(layout, geometry)
  local routes = {}
  for _, route in ipairs(layout.sourceRoutes or {}) do
    routes[#routes + 1] = route
  end
  for _, route in ipairs(layout.routes or {}) do
    routes[#routes + 1] = route
  end
  local scale = layout.scale or 1
  local nativeOkay, nativeReason =
    PipeManagerValidateNetwork(routes, { scale = scale, nativeArt = scale < 0.999 })
  if not nativeOkay then
    return false, "native_art: " .. tostring(nativeReason)
  end
  local painted, clear, reason =
    pcall(PromotionRenderedCardClear, layout, geometry.buttonW, geometry.buttonH, 160)
  if not painted then
    return false, "rendered_card_clear: " .. tostring(clear)
  end
  if clear ~= true then
    return false, "rendered_card_clear: " .. tostring(reason)
  end
  return true
end

-- A reviewed layout (hand-approved geometry for one exact graph) when one
-- matches and still draws cleanly; otherwise the channel layout, which takes
-- stored rows and routings for known graphs and searches the rest.
function PromotionLayoutChoose(graph, geometry)
  if type(PromotionReviewedLayout) == "function" then
    local built, reviewed, reviewGeometry, reviewName =
      pcall(PromotionReviewedLayout, graph, geometry)
    if built and reviewed then
      PromotionPrepareUnderpasses(reviewed, graph, reviewGeometry)
      local okay, reason = drawable(reviewed, geometry)
      if okay then
        reviewed.method = "reviewed"
        reviewed.reviewName = reviewName
        reviewed.valid = true
        reviewed.violations = {}
        return reviewed
      end
      print("Promotion Tree reviewed layout rejected: " .. tostring(reviewName) .. ": " .. tostring(reason))
    end
  end
  local solved, layout = pcall(PromotionTreeLayoutSolve, graph, geometry)
  if not solved then
    return {
      buttons = {},
      routes = {},
      sourceRoutes = {},
      valid = false,
      violations = { "layout failed: " .. tostring(layout) },
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
