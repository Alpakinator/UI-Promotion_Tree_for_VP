-- Native Civilization V technology-pipe art for promotion routes.
--
-- XML instance (under the same ScrollPanel as the promotion buttons):
--   <Instance Name="PipeInstance">
--     <Box Anchor="L,T" Size="32,42" ID="PipeIcon">
--       <Image Size="32,42" ID="PipeArt"/>
--     </Box>
--   </Instance>
--
-- PipeManagerDrawPath({{x=,y=}, ...}, {
--   scale=1, offsetX=0, offsetY=0, colour="route",
--   gaps={{segment=1, from=45, to=55}, ...}
-- })
--
-- Points are ordered route-centre vertices in logical panel coordinates. A
-- gap's distances are measured from the first vertex of that segment. It
-- removes visible art only; callers keep the complete semantic route. No T or
-- crossing is inferred from proximity: only explicitly supplied paths draw.

include("FLuaVector")

local WHITE = Color(1, 1, 1, 1)
-- Civ V's TechTree tints these same pipe images in place. A bright azure
-- tint changes near-white art without scaling or layering another sprite.
local HOVER_BLUE_R, HOVER_BLUE_G, HOVER_BLUE_B = 0.26, 0.66, 1
local PIPE_COLORS = {
  route = WHITE,
  dim = Color(1, 1, 1, 90 / 255),
  red = Color(1, 0, 0, 1),
  green = Color(0, 1, 0, 1),
  blue = Color(0, 0, 1, 1),
  white = WHITE,
  black = Color(0, 0, 0, 1),
  clear = Color(0, 0, 0, 0),
}

-- First-party TechTree.lua uses a 32x42 Image and these four atlas cells.
-- The source crops remove only native straight tails (and, on bottom-right,
-- transparent edges). The arc pixels are still sampled from the original
-- TechBranches atlas, and the separate H/V textures replace the cut tails.
-- Decoded BNW alpha audit: top-tile rows 32..41 have only the vertical 5px
-- band; bottom-tile rows 0..4 likewise; right-tile columns 0..1 have only
-- the horizontal 5px band. No curve silhouette occupies a removed pixel.
local NATIVE_TILE_WIDTH, NATIVE_TILE_HEIGHT = 32, 42
local CORNERS = {
  WS = {
    offsetX = 72,
    offsetY = 0,
    anchorX = 23,
    anchorY = 11,
    cropX = 2,
    cropY = 0,
    cropW = 24,
    cropH = 32,
    verticalShoulderFrom = 21,
    verticalShoulderTo = 32,
  },
  WN = {
    offsetX = 72,
    offsetY = 72,
    anchorX = 23,
    anchorY = 26,
    cropX = 2,
    cropY = 5,
    cropW = 24,
    cropH = 24,
    verticalShoulderFrom = 0,
    verticalShoulderTo = 11,
  },
  ES = {
    offsetX = 0,
    offsetY = 0,
    anchorX = 11,
    anchorY = 11,
    cropX = 0,
    cropY = 0,
    cropW = 32,
    cropH = 32,
    verticalShoulderFrom = 17,
    verticalShoulderTo = 32,
  },
  EN = {
    offsetX = 0,
    offsetY = 72,
    anchorX = 11,
    anchorY = 26,
    cropX = 0,
    cropY = 5,
    cropW = 32,
    cropH = 24,
    verticalShoulderFrom = 0,
    verticalShoulderTo = 14,
  },
}
-- Use these only for graph-verified shared branch points. The centre atlas
-- cell is a connected cross, never a representation of unrelated routes.
local JUNCTIONS = {
  ESW = { offsetX = 36, offsetY = 0, anchorX = 17, anchorY = 11 },
  ENS = { offsetX = 0, offsetY = 36, anchorX = 11, anchorY = 17 },
  NSW = { offsetX = 72, offsetY = 36, anchorX = 23, anchorY = 17 },
  ENW = { offsetX = 36, offsetY = 72, anchorX = 17, anchorY = 26 },
  ENSW = { offsetX = 36, offsetY = 36, anchorX = 17, anchorY = 17 },
}
-- The decoded BNW art has its straight contact band at local x/y 9..13.
-- Top/bottom elbows move that band by 15px; left/right by 12px. Keep a
-- route's logical vertex at the intersection of those two contact bands.
local H_CENTER_Y, V_CENTER_X = 11, 11
local TURN_TRIM = 21
-- A branch curve meets the straight band this far from its vertex.
local CURVE_TANGENT = 8
local legacyRouteUnit = 8 -- compatibility with old TreeLayout calls
local instanceManager = nil
local captureNativePiece = nil -- optional offline native-pixel audit
local piecesByIdentity = {} -- exact physical duplicates in this draw
local ownersByPieceIdentity = {}
local emittedPieceIdentities = {}
local piecesByEdge = {} -- ownership index for incremental hover
local focusedPieces = {}

local function pixel(value)
  return math.floor(value + 0.5)
end

local function resolvePipeColor(colour)
  if type(colour) == "string" then
    return PIPE_COLORS[colour] or WHITE
  elseif type(colour) == "table" then
    return colour
  end
  return WHITE
end

local function screenCoordinate(value, scale, offset)
  return pixel(value * scale + offset)
end

-- A piece normally turns opaque under hover; focusedAlpha 0 hides it instead.
local function emitNativePiece(
  texture,
  x,
  y,
  width,
  height,
  sourceW,
  sourceH,
  atlasX,
  atlasY,
  colour,
  owners,
  focusedAlpha
)
  if not instanceManager or width <= 0 or height <= 0 then
    return
  end
  local tint = resolvePipeColor(colour)
  local r, g, b, a = tint.x or tint[1], tint.y or tint[2], tint.z or tint[3], tint.w or tint[4]
  focusedAlpha = focusedAlpha or 1
  local identity = table.concat({
    texture,
    x,
    y,
    width,
    height,
    sourceW,
    sourceH,
    atlasX or 0,
    atlasY or 0,
    string.format("%.17g", r),
    string.format("%.17g", g),
    string.format("%.17g", b),
    string.format("%.17g", a),
    focusedAlpha,
  }, "|")
  local descriptor = piecesByIdentity[identity]
  if not descriptor then
    descriptor = {
      texture = texture,
      x = x,
      y = y,
      width = width,
      height = height,
      sourceW = sourceW,
      sourceH = sourceH,
      atlasX = atlasX or 0,
      atlasY = atlasY or 0,
      r = r,
      g = g,
      b = b,
      a = a,
      focusedAlpha = focusedAlpha,
      colour = colour,
      owners = {},
    }
    piecesByIdentity[identity] = descriptor
    ownersByPieceIdentity[identity] = {}
  end
  if owners then
    local seen = ownersByPieceIdentity[identity]
    for i = 1, #owners do
      local owner = owners[i]
      if not seen[owner] then
        descriptor.owners[#descriptor.owners + 1] = owner
        seen[owner] = true
        local pieces = piecesByEdge[owner]
        if not pieces then
          pieces = {}
          piecesByEdge[owner] = pieces
        end
        pieces[#pieces + 1] = descriptor
      end
    end
  end
  if emittedPieceIdentities[identity] then
    return
  end
  emittedPieceIdentities[identity] = true
  local instance = instanceManager:GetInstance()
  local root = instance.PipeIcon
  local icon = instance.PipeArt
  descriptor.icon = icon
  descriptor.focused = false
  root:SetOffsetVal(x, y)
  root:SetSizeVal(width, height)
  icon:SetTexture(texture)
  icon:SetOffsetVal(0, 0)
  icon:SetSizeVal(width, height)
  -- InstanceManager may recycle an atlas tile as a straight run. Reset both
  -- texture coordinates on every draw so no stale crop or offset survives.
  icon:SetTextureOffsetVal(atlasX or 0, atlasY or 0)
  icon:SetTextureSizeVal(sourceW, sourceH)
  icon:NormalizeTexture()
  icon:SetColor(Color(r, g, b, a))
  if captureNativePiece then
    captureNativePiece(descriptor)
  end
end

-- Recolor the corresponding native art in place.
-- Rebuilding the network on mouse movement changes draw order and can put
-- pipes in front of promotion cards. Shared straight sections retain every
-- traversing owner; flow-junction curves retain only their turning owners.
function PipeManagerHighlightEdges(edgeKeys)
  local nextFocusedPieces = {}
  for key, enabled in pairs(edgeKeys or {}) do
    if enabled then
      for _, piece in ipairs(piecesByEdge[key] or {}) do
        nextFocusedPieces[piece] = true
      end
    end
  end
  for piece in pairs(focusedPieces) do
    if not nextFocusedPieces[piece] and piece.icon then
      piece.icon:SetColor(Color(piece.r, piece.g, piece.b, piece.a))
      piece.focused = false
    end
  end
  for piece in pairs(nextFocusedPieces) do
    if not piece.focused and piece.icon then
      piece.icon:SetColor(
        Color(
          piece.r * HOVER_BLUE_R,
          piece.g * HOVER_BLUE_G,
          piece.b * HOVER_BLUE_B,
          piece.focusedAlpha
        )
      )
      piece.focused = true
    end
  end
  focusedPieces = nextFocusedPieces
end

local function drawHorizontal(x0, x1, y, scale, offsetX, offsetY, colour, owners, focusedAlpha)
  local left = screenCoordinate(math.min(x0, x1), scale, offsetX)
  local right = screenCoordinate(math.max(x0, x1), scale, offsetX)
  local top = screenCoordinate(y - H_CENTER_Y, scale, offsetY)
  local bottom = screenCoordinate(y - H_CENTER_Y + NATIVE_TILE_HEIGHT, scale, offsetY)
  if right > left then
    emitNativePiece(
      "TechBranchH.dds",
      left,
      top,
      right - left,
      bottom - top,
      math.abs(x1 - x0),
      NATIVE_TILE_HEIGHT,
      0,
      0,
      colour,
      owners,
      focusedAlpha
    )
  end
end

local function drawVertical(x, y0, y1, scale, offsetX, offsetY, colour, owners, focusedAlpha)
  local left = screenCoordinate(x - V_CENTER_X, scale, offsetX)
  local right = screenCoordinate(x - V_CENTER_X + NATIVE_TILE_WIDTH, scale, offsetX)
  local top = screenCoordinate(math.min(y0, y1), scale, offsetY)
  local bottom = screenCoordinate(math.max(y0, y1), scale, offsetY)
  if bottom > top then
    emitNativePiece(
      "TechBranchV.dds",
      left,
      top,
      right - left,
      bottom - top,
      NATIVE_TILE_WIDTH,
      math.abs(y1 - y0),
      0,
      0,
      colour,
      owners,
      focusedAlpha
    )
  end
end

local function sideOf(x, y, otherX, otherY)
  if otherX < x then
    return "W"
  end
  if otherX > x then
    return "E"
  end
  if otherY < y then
    return "N"
  end
  if otherY > y then
    return "S"
  end
end

local function cornerKind(a, b)
  if not a or not b or a == b then
    return nil
  end
  if
    (a == "W" and b == "E")
    or (a == "E" and b == "W")
    or (a == "N" and b == "S")
    or (a == "S" and b == "N")
  then
    return nil
  end
  if a == "W" or b == "W" then
    return (a == "N" or b == "N") and "WN" or "WS"
  end
  return (a == "N" or b == "N") and "EN" or "ES"
end

local function drawCorner(x, y, kind, scale, offsetX, offsetY, colour, owners, focusedAlpha)
  local cell = CORNERS[kind]
  if not cell then
    return
  end
  -- Keep the exact cropped source region when the destination is zoomed down.
  local logicalX = x - cell.anchorX + cell.cropX
  local logicalY = y - cell.anchorY + cell.cropY
  local left = screenCoordinate(logicalX, scale, offsetX)
  local top = screenCoordinate(logicalY, scale, offsetY)
  local right = screenCoordinate(logicalX + cell.cropW, scale, offsetX)
  local bottom = screenCoordinate(logicalY + cell.cropH, scale, offsetY)
  emitNativePiece(
    "TechBranches.dds",
    left,
    top,
    right - left,
    bottom - top,
    cell.cropW,
    cell.cropH,
    cell.offsetX + cell.cropX,
    cell.offsetY + cell.cropY,
    colour,
    owners,
    focusedAlpha
  )
end

local function drawCompactCornerShoulder(x, y, kind, settings, colour, owners)
  local cell = CORNERS[kind]
  -- A short approach forces this elbow to fit the tree scale, while its long
  -- vertical arm keeps the native 5px pipe. At small scale the elbow's flat
  -- contact band loses a core pixel. Continue the native vertical art only
  -- through the atlas rows that are straight, underneath the curved tile.
  -- The interval stays vertically inside the elbow crop, so route gaps and
  -- crossings outside the corner retain their existing boundaries.
  local logicalTop = y - cell.anchorY + cell.cropY
  local top =
    screenCoordinate(logicalTop + cell.verticalShoulderFrom, settings.scale, settings.offsetY)
  local bottom =
    screenCoordinate(logicalTop + cell.verticalShoulderTo, settings.scale, settings.offsetY)
  drawVertical(
    screenCoordinate(x, settings.scale, settings.offsetX),
    top,
    bottom,
    1,
    0,
    0,
    colour,
    owners
  )
end

function PipeManagerInit(iRouteUnit, sInstanceName, rootControl, parentControl)
  if type(iRouteUnit) == "number" and iRouteUnit > 0 then
    legacyRouteUnit = iRouteUnit
  else
    legacyRouteUnit = 8
  end
  instanceManager = InstanceManager:new(sInstanceName, rootControl, parentControl)
  piecesByIdentity = {}
  ownersByPieceIdentity = {}
  emittedPieceIdentities = {}
  piecesByEdge, focusedPieces = {}, {}
end

function PipeManagerReset()
  if instanceManager then
    instanceManager:ResetInstances()
  end
  piecesByIdentity = {}
  ownersByPieceIdentity = {}
  emittedPieceIdentities = {}
  piecesByEdge, focusedPieces = {}, {}
end

function PipeManagerSetCapture(callback)
  if callback ~= nil and type(callback) ~= "function" then
    return false, "capture must be a function or nil"
  end
  captureNativePiece = callback
  return true
end

function PipeManagerGetMetrics()
  return {
    imageW = NATIVE_TILE_WIDTH,
    imageH = NATIVE_TILE_HEIGHT,
    horizontalCentreY = H_CENTER_Y,
    verticalCentreX = V_CENTER_X,
    turnTrimWest = TURN_TRIM,
    turnTrimEast = TURN_TRIM,
    turnTrimNorth = TURN_TRIM,
    turnTrimSouth = TURN_TRIM,
  }
end

local function canonicalArms(arms)
  if type(arms) ~= "string" then
    return nil
  end
  local letters = {}
  local seen = {}
  for i = 1, #arms do
    local letter = string.sub(arms, i, i)
    if letter ~= "N" and letter ~= "S" and letter ~= "E" and letter ~= "W" then
      return nil
    end
    if seen[letter] then
      return nil
    end
    letters[#letters + 1] = letter
    seen[letter] = true
  end
  table.sort(letters)
  return table.concat(letters)
end

local function validNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function pathOptions(options)
  options = options or {}
  if
    type(options) ~= "table"
    or (options.gaps ~= nil and type(options.gaps) ~= "table")
    or (options.owners ~= nil and type(options.owners) ~= "table")
  then
    return nil, "invalid path options"
  end
  local scale = options.scale or 1
  local offsetX = options.offsetX or 0
  local offsetY = options.offsetY or 0
  if
    not validNumber(scale)
    or scale <= 0
    or not validNumber(offsetX)
    or not validNumber(offsetY)
  then
    return nil, "invalid scale or offset"
  end
  local owners = {}
  for i = 1, #(options.owners or {}) do
    if type(options.owners[i]) ~= "string" then
      return nil, "invalid route owner"
    end
    owners[#owners + 1] = options.owners[i]
  end
  if options.routeId then
    if type(options.routeId) ~= "string" then
      return nil, "invalid route owner"
    end
    owners[#owners + 1] = options.routeId
  end
  return {
    scale = scale,
    offsetX = offsetX,
    offsetY = offsetY,
    nativeArt = options.nativeArt == true,
    junctionStyle = options.junctionStyle or "flow",
    colour = options.colour or options.shade or "route",
    gaps = options.gaps or {},
    owners = owners,
  }
end

-- Draw one explicit native T/cross tile. The caller must identify the
-- junction from the prerequisite graph; this function never scans contacts.
function PipeManagerDrawJunction(x, y, arms, options)
  local settings, reason = pathOptions(options)
  if not settings then
    return false, reason
  end
  if not validNumber(x) or not validNumber(y) then
    return false, "invalid junction vertex"
  end
  local cell = JUNCTIONS[canonicalArms(arms)]
  if not cell then
    return false, "junction requires three or four arms"
  end
  if not instanceManager then
    return false, "PipeManagerInit was not called"
  end
  local logicalX, logicalY = x - cell.anchorX, y - cell.anchorY
  local left = screenCoordinate(logicalX, settings.scale, settings.offsetX)
  local top = screenCoordinate(logicalY, settings.scale, settings.offsetY)
  local right = screenCoordinate(logicalX + NATIVE_TILE_WIDTH, settings.scale, settings.offsetX)
  local bottom = screenCoordinate(logicalY + NATIVE_TILE_HEIGHT, settings.scale, settings.offsetY)
  emitNativePiece(
    "TechBranches.dds",
    left,
    top,
    right - left,
    bottom - top,
    NATIVE_TILE_WIDTH,
    NATIVE_TILE_HEIGHT,
    cell.offsetX,
    cell.offsetY,
    settings.colour,
    settings.owners
  )
  return true
end

local function drawJunctionCell(x, y, cell, settings, owners)
  local logicalX, logicalY = x - cell.anchorX, y - cell.anchorY
  local left = screenCoordinate(logicalX, settings.scale, settings.offsetX)
  local top = screenCoordinate(logicalY, settings.scale, settings.offsetY)
  local right = screenCoordinate(logicalX + NATIVE_TILE_WIDTH, settings.scale, settings.offsetX)
  local bottom = screenCoordinate(logicalY + NATIVE_TILE_HEIGHT, settings.scale, settings.offsetY)
  emitNativePiece(
    "TechBranches.dds",
    left,
    top,
    right - left,
    bottom - top,
    NATIVE_TILE_WIDTH,
    NATIVE_TILE_HEIGHT,
    cell.offsetX,
    cell.offsetY,
    settings.colour,
    owners
  )
end

local function validPath(points, options)
  if type(points) ~= "table" or #points < 2 then
    return nil, "path needs at least two vertices"
  end
  for i = 1, #points do
    local p = points[i]
    if type(p) ~= "table" or not validNumber(p.x) or not validNumber(p.y) then
      return nil, "invalid path vertex"
    end
    if i > 1 then
      local previous = points[i - 1]
      if (p.x == previous.x) == (p.y == previous.y) then
        return nil, "path segments must be nonzero and orthogonal"
      end
    end
  end
  for i = 1, #options.gaps do
    local gap = options.gaps[i]
    if
      type(gap) ~= "table"
      or type(gap.segment) ~= "number"
      or gap.segment ~= math.floor(gap.segment)
      or gap.segment < 1
      or gap.segment >= #points
      or not validNumber(gap.from)
      or not validNumber(gap.to)
    then
      return nil, "invalid gap"
    end
    local a, b = points[gap.segment], points[gap.segment + 1]
    local length = math.abs(b.x - a.x) + math.abs(b.y - a.y)
    if gap.from < 0 or gap.to > length or gap.to <= gap.from then
      return nil, "gap outside segment"
    end
  end
  return true
end

local function gapIntervals(gaps, segment)
  local result = {}
  for i = 1, #gaps do
    local gap = gaps[i]
    if gap.segment == segment then
      result[#result + 1] = { from = gap.from, to = gap.to }
    end
  end
  table.sort(result, function(a, b)
    if a.from == b.from then
      return a.to < b.to
    end
    return a.from < b.from
  end)
  local merged = {}
  for i = 1, #result do
    local item = result[i]
    local last = merged[#merged]
    if last and item.from <= last.to then
      last.to = math.max(last.to, item.to)
    else
      merged[#merged + 1] = { from = item.from, to = item.to }
    end
  end
  return merged
end

local function drawRun(a, b, from, to, options)
  if to <= from then
    return
  end
  if a.y == b.y then
    local direction = (b.x > a.x) and 1 or -1
    drawHorizontal(
      a.x + direction * from,
      a.x + direction * to,
      a.y,
      options.scale,
      options.offsetX,
      options.offsetY,
      options.colour,
      options.owners
    )
  else
    local direction = (b.y > a.y) and 1 or -1
    drawVertical(
      a.x,
      a.y + direction * from,
      a.y + direction * to,
      options.scale,
      options.offsetX,
      options.offsetY,
      options.colour,
      options.owners
    )
  end
end

local function elbowTrim(bend, arm)
  if not bend then
    return 0
  end
  return TURN_TRIM
end

-- Only deliberate path vertices create elbows. The caller owns graph
-- semantics and must not use an underpass gap at a real shared junction.
local function compilePath(points, options)
  local settings, reason = pathOptions(options)
  if not settings then
    return nil, reason
  end
  local okay
  okay, reason = validPath(points, settings)
  if not okay then
    return nil, reason
  end

  local bends = {}
  for i = 2, #points - 1 do
    local p = points[i]
    local prevSide = sideOf(p.x, p.y, points[i - 1].x, points[i - 1].y)
    local nextSide = sideOf(p.x, p.y, points[i + 1].x, points[i + 1].y)
    bends[i] = cornerKind(prevSide, nextSide)
    if prevSide == nextSide then
      return nil, "path doubles back"
    end
  end

  local startTrims, endTrims = {}, {}
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local length = math.abs(b.x - a.x) + math.abs(b.y - a.y)
    local startTrim = elbowTrim(bends[i], sideOf(a.x, a.y, b.x, b.y))
    local endTrim = elbowTrim(bends[i + 1], sideOf(b.x, b.y, a.x, a.y))
    if startTrim + endTrim > length then
      return nil, "segment too short for native elbows"
    end
    startTrims[i], endTrims[i] = startTrim, endTrim
    for j = 1, #settings.gaps do
      local gap = settings.gaps[j]
      if gap.segment == i and (gap.from < startTrim or gap.to > length - endTrim) then
        return nil, "gap overlaps native elbow"
      end
    end
  end
  return { settings = settings, bends = bends, startTrims = startTrims, endTrims = endTrims }
end

function PipeManagerValidatePath(points, options)
  local plan, reason = compilePath(points, options)
  if not plan then
    return false, reason
  end
  return true
end

function PipeManagerDrawPath(points, options)
  local plan, reason = compilePath(points, options)
  if not plan then
    return false, reason
  end
  if not instanceManager then
    return false, "PipeManagerInit was not called"
  end
  local settings = plan.settings
  local bends = plan.bends
  local startTrims, endTrims = plan.startTrims, plan.endTrims

  -- Straight art ends at each elbow's contact area. Gaps split only their
  -- specified run; each native corner remains one unaltered atlas cell.
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local length = math.abs(b.x - a.x) + math.abs(b.y - a.y)
    local visibleStart = startTrims[i]
    local visibleEnd = length - endTrims[i]
    local cursor = visibleStart
    local gaps = gapIntervals(settings.gaps, i)
    for j = 1, #gaps do
      local gap = gaps[j]
      drawRun(a, b, cursor, math.min(gap.from, visibleEnd), settings)
      cursor = math.max(cursor, gap.to)
    end
    drawRun(a, b, cursor, visibleEnd, settings)
  end
  for i = 2, #points - 1 do
    if bends[i] then
      local p = points[i]
      drawCorner(
        p.x,
        p.y,
        bends[i],
        settings.scale,
        settings.offsetX,
        settings.offsetY,
        settings.colour,
        settings.owners
      )
    end
  end
  return true
end

local function samePoint(a, x, y)
  return a.x == x and a.y == y
end

local function relatedRoutes(routes, ids)
  for i = 1, #ids do
    for j = i + 1, #ids do
      local a, b = routes[ids[i]], routes[ids[j]]
      if a.parent ~= b.parent and a.child ~= b.child then
        return false
      end
    end
  end
  return true
end

local function ownerKeys(routes, ids)
  local keys, seen = {}, {}
  for i = 1, #ids do
    local route = routes[ids[i]]
    local key = route.parent .. "\001" .. route.child
    if not seen[key] then
      keys[#keys + 1] = key
      seen[key] = true
    end
  end
  table.sort(keys)
  return keys
end

local function routeColour(routes, ids, override)
  if override then
    return override
  end
  for i = 1, #ids do
    if not routes[ids[i]].dim then
      return "route"
    end
  end
  return "dim"
end

local function addNetworkSpan(spans, a, b, from, to, routeIndex)
  if to <= from then
    return
  end
  local axis = (a.y == b.y) and "H" or "V"
  local positive = (axis == "H" and b.x > a.x) or (axis == "V" and b.y > a.y)
  local start = (axis == "H") and a.x or a.y
  local p = positive and (start + from) or (start - from)
  local q = positive and (start + to) or (start - to)
  spans[#spans + 1] = {
    axis = axis,
    fixed = (axis == "H") and a.y or a.x,
    lo = math.min(p, q),
    hi = math.max(p, q),
    rid = routeIndex,
  }
end

local function networkSpans(routes)
  local spans = {}
  for rid = 1, #routes do
    local route = routes[rid]
    if
      type(route) ~= "table"
      or type(route.parent) ~= "string"
      or type(route.child) ~= "string"
    then
      return nil, "network route needs parent and child"
    end
    local points = route.points
    local ok, reason = validPath(points, { gaps = route.gaps or {} })
    if not ok then
      return nil, reason
    end
    for i = 2, #points - 1 do
      local p = points[i]
      if
        sideOf(p.x, p.y, points[i - 1].x, points[i - 1].y)
        == sideOf(p.x, p.y, points[i + 1].x, points[i + 1].y)
      then
        return nil, "network path doubles back"
      end
    end
    for i = 1, #points - 1 do
      local a, b = points[i], points[i + 1]
      local length = math.abs(b.x - a.x) + math.abs(b.y - a.y)
      local cursor = 0
      local gaps = gapIntervals(route.gaps or {}, i)
      for j = 1, #gaps do
        addNetworkSpan(spans, a, b, cursor, gaps[j].from, rid)
        cursor = gaps[j].to
      end
      addNetworkSpan(spans, a, b, cursor, length, rid)
    end
  end
  return spans
end

local function addCut(cuts, value)
  cuts[value] = true
end

local function splitNetworkSpans(spans, routes)
  local cuts = {}
  for i = 1, #spans do
    cuts[i] = { [spans[i].lo] = true, [spans[i].hi] = true }
  end
  for i = 1, #spans do
    local a = spans[i]
    for j = i + 1, #spans do
      local b = spans[j]
      if a.axis == b.axis then
        if a.fixed == b.fixed and a.lo <= b.hi and b.lo <= a.hi then
          if b.lo >= a.lo and b.lo <= a.hi then
            addCut(cuts[i], b.lo)
          end
          if b.hi >= a.lo and b.hi <= a.hi then
            addCut(cuts[i], b.hi)
          end
          if a.lo >= b.lo and a.lo <= b.hi then
            addCut(cuts[j], a.lo)
          end
          if a.hi >= b.lo and a.hi <= b.hi then
            addCut(cuts[j], a.hi)
          end
        end
      else
        local h = (a.axis == "H") and a or b
        local v = (a.axis == "V") and a or b
        if v.fixed >= h.lo and v.fixed <= h.hi and h.fixed >= v.lo and h.fixed <= v.hi then
          addCut(cuts[(a.axis == "H") and i or j], v.fixed)
          addCut(cuts[(a.axis == "V") and i or j], h.fixed)
        end
      end
    end
  end
  local atoms, byKey = {}, {}
  for i = 1, #spans do
    local span = spans[i]
    local values = {}
    for value in pairs(cuts[i]) do
      values[#values + 1] = value
    end
    table.sort(values)
    for j = 1, #values - 1 do
      local lo, hi = values[j], values[j + 1]
      if hi > lo then
        local key = span.axis .. "|" .. span.fixed .. "|" .. lo .. "|" .. hi
        local atom = byKey[key]
        if not atom then
          atom = { axis = span.axis, fixed = span.fixed, lo = lo, hi = hi, ids = {}, idSet = {} }
          atoms[#atoms + 1] = atom
          byKey[key] = atom
        end
        if not atom.idSet[span.rid] then
          atom.ids[#atom.ids + 1] = span.rid
          atom.idSet[span.rid] = true
        end
      end
    end
  end
  for i = 1, #atoms do
    if not relatedRoutes(routes, atoms[i].ids) then
      return nil, "unrelated routes share a visible span"
    end
  end
  table.sort(atoms, function(a, b)
    if a.axis ~= b.axis then
      return a.axis < b.axis
    end
    if a.fixed ~= b.fixed then
      return a.fixed < b.fixed
    end
    return a.lo < b.lo
  end)
  return atoms
end

local function networkNode(nodes, x, y)
  local key = x .. "|" .. y
  local node = nodes[key]
  if not node then
    node = { x = x, y = y, arms = {}, ids = {}, idSet = {} }
    nodes[key] = node
  end
  return node
end

local function addNodeArm(node, arm, atom)
  node.arms[arm] = atom
  for i = 1, #atom.ids do
    local rid = atom.ids[i]
    if not node.idSet[rid] then
      node.ids[#node.ids + 1] = rid
      node.idSet[rid] = true
    end
  end
end

local function networkNodes(atoms, routes, settings)
  local nodes = {}
  for i = 1, #atoms do
    local atom = atoms[i]
    if atom.axis == "H" then
      addNodeArm(networkNode(nodes, atom.lo, atom.fixed), "E", atom)
      addNodeArm(networkNode(nodes, atom.hi, atom.fixed), "W", atom)
    else
      addNodeArm(networkNode(nodes, atom.fixed, atom.lo), "S", atom)
      addNodeArm(networkNode(nodes, atom.fixed, atom.hi), "N", atom)
    end
  end
  local ordered = {}
  for _, node in pairs(nodes) do
    ordered[#ordered + 1] = node
  end
  table.sort(ordered, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    return a.y < b.y
  end)
  for i = 1, #ordered do
    local node = ordered[i]
    local arms = {}
    for _, arm in ipairs({ "E", "N", "S", "W" }) do
      if node.arms[arm] then
        arms[#arms + 1] = arm
      end
    end
    node.armString = table.concat(arms)
    node.owners = ownerKeys(routes, node.ids)
    node.colour = routeColour(routes, node.ids)
    local degree = #arms
    local commonEndpoint = true
    for j = 1, #node.ids do
      local points = routes[node.ids[j]].points
      if
        not samePoint(points[1], node.x, node.y)
        and not samePoint(points[#points], node.x, node.y)
      then
        commonEndpoint = false
        break
      end
    end
    if degree > 2 then
      local sharedArm = false
      for j = 1, #arms do
        if #node.arms[arms[j]].ids > 1 then
          sharedArm = true
        end
      end
      if not relatedRoutes(routes, node.ids) or (not sharedArm and not commonEndpoint) then
        return nil, "unrelated crossing or branch contact at (" .. node.x .. "," .. node.y .. ")"
      end
      node.junction = JUNCTIONS[node.armString]
      if not node.junction then
        return nil, "unsupported network junction"
      end
      if settings.junctionStyle ~= "atlas" then
        -- A shared prefix/suffix identifies the actual stem. Curves join
        -- that arm to each branch; the opposite arm continues straight.
        local stem
        -- The sidebar stem enters from the west and splits toward roots
        -- above and below. Give this one junction two mirrored native bends
        -- even when the source rail is shared by several root routes.
        if node.arms.W and node.arms.N and node.arms.S and not node.arms.E then
          for _, rid in ipairs(node.ids) do
            if routes[rid].child == "__PROMOTION_BOX__" then
              stem = "W"
              break
            end
          end
        end
        for _, arm in ipairs(arms) do
          if not stem and #node.arms[arm].ids == #node.ids then
            stem = arm
            break
          end
        end
        -- At the abstract common source, no incoming route exists. Keep
        -- its rail continuous and let the outgoing branch peel from it.
        if not stem and commonEndpoint then
          stem = node.arms.W and "W" or node.arms.N and "N" or arms[1]
        end
        if stem then
          local opposite = { N = "S", S = "N", E = "W", W = "E" }
          node.flowCorners = {}
          node.flowCornerOwners = {}
          local sourceOnly = true
          for _, rid in ipairs(node.ids) do
            if routes[rid].parent ~= "__PROMOTION_SOURCE__" then
              sourceOnly = false
              break
            end
          end
          node.flowStem = stem
          if node.arms[opposite[stem]] then
            node.flowAxis = (stem == "W" or stem == "E") and "H" or "V"
            -- A centre run crosses the branch point, but a turning route
            -- owns only the half before its turn. Keep the two native halves
            -- physically contiguous while preserving exact arm provenance.
            node.flowArmOwners = {}
            node.flowArmOwners[stem] = ownerKeys(routes, node.arms[stem].ids)
            node.flowArmOwners[opposite[stem]] = ownerKeys(routes, node.arms[opposite[stem]].ids)
          end
          for _, arm in ipairs(arms) do
            local kind = cornerKind(stem, arm)
            if kind then
              node.flowCorners[#node.flowCorners + 1] = kind
              -- The common stem carries every route at this junction, but
              -- this curve belongs only to routes taking its branch arm.
              -- Abstract root feeds share a decorative source connection;
              -- they are never included in promotion hover edge sets.
              node.flowCornerOwners[kind] = sourceOnly and node.owners
                or ownerKeys(routes, node.arms[arm].ids)
            end
          end
        end
      end
    elseif degree == 2 then
      local first, second = node.arms[arms[1]], node.arms[arms[2]]
      local sharedRoute = false
      for j = 1, #first.ids do
        if second.idSet[first.ids[j]] then
          sharedRoute = true
          break
        end
      end
      if not sharedRoute and (not relatedRoutes(routes, node.ids) or not commonEndpoint) then
        return nil, "unrelated routes touch end-to-end"
      end
      node.corner = cornerKind(arms[1], arms[2])
    end
  end
  return nodes, ordered
end

local function networkTrim(node, arm, settings)
  local trim
  if node.corner or node.flowCorners then
    trim = TURN_TRIM
  else
    local cell = node.junction
    if not cell then
      return 0
    end
    if arm == "W" then
      trim = cell.anchorX
    elseif arm == "E" then
      trim = NATIVE_TILE_WIDTH - cell.anchorX
    elseif arm == "N" then
      trim = cell.anchorY
    else
      trim = NATIVE_TILE_HEIGHT - cell.anchorY
    end
  end
  return settings.nativeArt and not node.compact and trim / settings.scale or trim
end

local function compileNetwork(routes, options)
  if type(routes) ~= "table" then
    return nil, "network routes must be a table"
  end
  local settings, reason = pathOptions(options)
  if not settings then
    return nil, reason
  end
  local spans
  spans, reason = networkSpans(routes)
  if not spans then
    return nil, reason
  end
  local atoms
  atoms, reason = splitNetworkSpans(spans, routes)
  if not atoms then
    return nil, reason
  end
  local nodes, ordered
  nodes, ordered = networkNodes(atoms, routes, settings)
  if not nodes then
    return nil, ordered
  end
  if settings.nativeArt then
    -- Two nearby junctions may fit with the fitted-size tiles but not with
    -- both full native tiles. Keep those two tiles compact; all longer runs
    -- and well-spaced junctions retain unscaled source artwork.
    for i = 1, #atoms do
      local atom = atoms[i]
      local first, last, firstArm, lastArm
      if atom.axis == "H" then
        first = nodes[atom.lo .. "|" .. atom.fixed]
        last = nodes[atom.hi .. "|" .. atom.fixed]
        firstArm, lastArm = "E", "W"
      else
        first = nodes[atom.fixed .. "|" .. atom.lo]
        last = nodes[atom.fixed .. "|" .. atom.hi]
        firstArm, lastArm = "S", "N"
      end
      if
        atom.hi - atom.lo
        < networkTrim(first, firstArm, settings) + networkTrim(last, lastArm, settings)
      then
        first.compact = true
        last.compact = true
      end
    end
  end
  for i = 1, #atoms do
    local atom = atoms[i]
    local startNode, endNode, startArm, endArm
    if atom.axis == "H" then
      startNode = nodes[atom.lo .. "|" .. atom.fixed]
      endNode = nodes[atom.hi .. "|" .. atom.fixed]
      startArm, endArm = "E", "W"
    else
      startNode = nodes[atom.fixed .. "|" .. atom.lo]
      endNode = nodes[atom.fixed .. "|" .. atom.hi]
      startArm, endArm = "S", "N"
    end
    atom.drawLo = atom.lo + networkTrim(startNode, startArm, settings)
    atom.drawHi = atom.hi - networkTrim(endNode, endArm, settings)
    if atom.drawHi < atom.drawLo then
      return nil,
        "network segment too short for native junction art at "
          .. atom.axis
          .. " "
          .. atom.fixed
          .. ":"
          .. atom.lo
          .. ".."
          .. atom.hi
    end
    atom.colour = routeColour(routes, atom.ids, options and (options.colour or options.shade))
    atom.owners = ownerKeys(routes, atom.ids)
  end
  return { atoms = atoms, nodes = ordered, settings = settings }
end

function PipeManagerValidateNetwork(routes, options)
  local plan, reason = compileNetwork(routes, options)
  if not plan then
    return false, reason
  end
  return true
end

-- Compose graph-approved shared prefixes/suffixes once. Every physical
-- interval is split at genuine route vertices and gap boundaries. A T/cross
-- tile is drawn only where route ownership proves a local shared network;
-- an unrelated crossing without an underpass gap is rejected before draw.
function PipeManagerDrawNetwork(routes, options)
  local plan, reason = compileNetwork(routes, options)
  if not plan then
    return false, reason
  end
  if not instanceManager then
    return false, "PipeManagerInit was not called"
  end
  local settings = plan.settings
  local function position(x, y)
    return screenCoordinate(x, settings.scale, settings.offsetX),
      screenCoordinate(y, settings.scale, settings.offsetY)
  end
  local function horizontal(lo, hi, y, colour, owners, focusedAlpha)
    if settings.nativeArt then
      local x0, py = position(lo, y)
      local x1 = screenCoordinate(hi, settings.scale, settings.offsetX)
      drawHorizontal(x0, x1, py, 1, 0, 0, colour, owners, focusedAlpha)
    else
      drawHorizontal(
        lo,
        hi,
        y,
        settings.scale,
        settings.offsetX,
        settings.offsetY,
        colour,
        owners,
        focusedAlpha
      )
    end
  end
  local function vertical(x, lo, hi, colour, owners, focusedAlpha)
    if settings.nativeArt then
      local px, y0 = position(x, lo)
      local y1 = screenCoordinate(hi, settings.scale, settings.offsetY)
      drawVertical(px, y0, y1, 1, 0, 0, colour, owners, focusedAlpha)
    else
      drawVertical(
        x,
        lo,
        hi,
        settings.scale,
        settings.offsetX,
        settings.offsetY,
        colour,
        owners,
        focusedAlpha
      )
    end
  end
  local function corner(x, y, kind, colour, owners, compact, focusedAlpha)
    if settings.nativeArt and not compact then
      local px, py = position(x, y)
      drawCorner(px, py, kind, 1, 0, 0, colour, owners, focusedAlpha)
    else
      drawCorner(
        x,
        y,
        kind,
        settings.scale,
        settings.offsetX,
        settings.offsetY,
        colour,
        owners,
        focusedAlpha
      )
    end
  end
  -- A flow node's curves lie under its straight band, so a hovered straight
  -- route covers the neutral curves; but a hovered curve must cover the
  -- neutral band. Each flow piece is drawn twice: the copy in place hides
  -- under hover, and a transparent twin above every pipe shows instead.
  -- Hovered pieces thus cover neutral ones and keep their own order.
  local function flowNode(node, colour, focusedAlpha)
    for _, kind in ipairs(node.flowCorners) do
      corner(node.x, node.y, kind, colour, node.flowCornerOwners[kind], node.compact, focusedAlpha)
    end
    -- The band's halves meet where the branch curve joins it, a little past
    -- the vertex on the stem side: splitting at the vertex would tint the
    -- straight-through pipe before the hovered curve has reached it.
    local nativeNode = settings.nativeArt and not node.compact
    local trim = nativeNode and TURN_TRIM / settings.scale or TURN_TRIM
    local tangent = nativeNode and CURVE_TANGENT / settings.scale or CURVE_TANGENT
    local stem = node.flowStem
    if node.flowAxis == "H" then
      local split = node.x + (stem == "E" and tangent or stem == "W" and -tangent or 0)
      horizontal(node.x - trim, split, node.y, colour, node.flowArmOwners.W, focusedAlpha)
      horizontal(split, node.x + trim, node.y, colour, node.flowArmOwners.E, focusedAlpha)
    elseif node.flowAxis == "V" then
      local split = node.y + (stem == "S" and tangent or stem == "N" and -tangent or 0)
      vertical(node.x, node.y - trim, split, colour, node.flowArmOwners.N, focusedAlpha)
      vertical(node.x, split, node.y + trim, colour, node.flowArmOwners.S, focusedAlpha)
    end
  end
  for i = 1, #plan.atoms do
    local atom = plan.atoms[i]
    if atom.drawHi > atom.drawLo then
      if atom.axis == "H" then
        horizontal(atom.drawLo, atom.drawHi, atom.fixed, atom.colour, atom.owners)
      else
        vertical(atom.fixed, atom.drawLo, atom.drawHi, atom.colour, atom.owners)
      end
    end
  end
  for i = 1, #plan.nodes do
    local node = plan.nodes[i]
    local colour = options and (options.colour or options.shade) or node.colour
    local nativeNode = settings.nativeArt and not node.compact
    if node.flowCorners then
      flowNode(node, colour, 0)
    elseif node.junction then
      if nativeNode then
        local px, py = position(node.x, node.y)
        drawJunctionCell(
          px,
          py,
          node.junction,
          { scale = 1, offsetX = 0, offsetY = 0, colour = colour },
          node.owners
        )
      else
        drawJunctionCell(node.x, node.y, node.junction, {
          scale = settings.scale,
          offsetX = settings.offsetX,
          offsetY = settings.offsetY,
          colour = colour,
        }, node.owners)
      end
    elseif node.corner then
      if settings.nativeArt and node.compact then
        drawCompactCornerShoulder(node.x, node.y, node.corner, settings, colour, node.owners)
      end
      corner(node.x, node.y, node.corner, colour, node.owners, node.compact)
    end
  end
  -- Hover twins of every flow node (see flowNode).
  for i = 1, #plan.nodes do
    local node = plan.nodes[i]
    if node.flowCorners then
      local tint = resolvePipeColor(options and (options.colour or options.shade) or node.colour)
      flowNode(node, Color(tint.x or tint[1], tint.y or tint[2], tint.z or tint[3], 0))
    end
  end
  return true
end

-- Legacy TreeLayout API. x/y is the top-left of a route-unit square.
function PipeManagerDrawHorizontalPipe(x, y, length, colour)
  if length and length > 0 then
    drawHorizontal(x, x + length, y + legacyRouteUnit / 2, 1, 0, 0, colour)
  end
end

function PipeManagerDrawVerticalPipe(x, y, height, colour)
  if height and height > 0 then
    drawVertical(x + legacyRouteUnit / 2, y, y + height, 1, 0, 0, colour)
  end
end

function PipeManagerDrawCorner(x, y, side, dir, fillet, colour)
  if not fillet or type(dir) ~= "number" or dir == 0 then
    return
  end
  local kind
  if side == "spine" then
    kind = (dir < 0) and "WN" or "WS"
  elseif side == "branch" then
    kind = (dir < 0) and "EN" or "ES"
  end
  if kind then
    drawCorner(x + legacyRouteUnit / 2, y + legacyRouteUnit / 2, kind, 1, 0, 0, colour)
  end
end

-- Last resort when a network cannot be drawn: every route on its own. Shared
-- stretches and junctions lose their merged art, but no pipe is left out.
-- A route whose elbows don't fit is drawn as plain runs.
-- Draw what can be drawn: each route whole if it validates, else segment by
-- segment, skipping (and counting) any segment the pipe art cannot show.
function PipeManagerDrawRoutesLenient(routes, options)
  local skipped = 0
  if not instanceManager then
    return 0
  end
  for _, route in ipairs(routes or {}) do
    local points = route.points or {}
    local owners = {}
    if type(route.parent) == "string" and type(route.child) == "string" then
      owners[1] = route.parent .. "\001" .. route.child
    end
    local settings = {
      scale = options.scale,
      offsetX = options.offsetX,
      offsetY = options.offsetY,
      nativeArt = options.nativeArt,
      gaps = route.gaps,
      owners = owners,
    }
    local ran, valid = pcall(PipeManagerValidatePath, points, settings)
    if #points >= 2 and ran and valid then
      PipeManagerDrawPath(points, settings)
    else
      for i = 1, #points - 1 do
        local gaps = {}
        for _, gap in ipairs(route.gaps or {}) do
          if gap.segment == i then
            gaps[#gaps + 1] = { segment = 1, from = gap.from, to = gap.to }
          end
        end
        settings.gaps = gaps
        local ran, ok = pcall(PipeManagerDrawPath, { points[i], points[i + 1] }, settings)
        if not ran or not ok then
          settings.gaps = nil
          ran, ok = pcall(PipeManagerDrawPath, { points[i], points[i + 1] }, settings)
          if not ran or not ok then
            skipped = skipped + 1
          end
        end
      end
    end
  end
  return skipped
end

function PipeManagerDrawRoutesSeparately(routes, options)
  if not instanceManager then
    return false, "PipeManagerInit was not called"
  end
  for _, route in ipairs(routes) do
    local owners = {}
    if type(route.parent) == "string" and type(route.child) == "string" then
      owners[1] = route.parent .. "\001" .. route.child
    end
    local settings = {
      scale = options.scale,
      offsetX = options.offsetX,
      offsetY = options.offsetY,
      nativeArt = options.nativeArt,
      gaps = route.gaps,
      owners = owners,
    }
    if PipeManagerValidatePath(route.points, settings) then
      PipeManagerDrawPath(route.points, settings)
    else
      for i = 1, #route.points - 1 do
        local gaps = {}
        for _, gap in ipairs(route.gaps or {}) do
          if gap.segment == i then
            gaps[#gaps + 1] = { segment = 1, from = gap.from, to = gap.to }
          end
        end
        settings.gaps = gaps
        local ok, reason = PipeManagerDrawPath({ route.points[i], route.points[i + 1] }, settings)
        if not ok then
          return false, reason
        end
      end
    end
  end
  return true
end
