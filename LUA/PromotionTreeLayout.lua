-- Promotion tree layout: prerequisite columns, rigid rows, channel-routed pipes.
--
-- A promotion's column is its prerequisite depth. Every card, rank chain and
-- long pipe is a rigid row object, and a local search orders those rows to
-- minimise pipe crossings. Pipes run straight along rows and change rows
-- only on vertical tracks in the channel between two columns, so each
-- channel is routed exactly and independently of the others:
--
--   * a prerequisite with several children in a channel splits from one
--     vertical trunk; a child with several prerequisites there collects them
--     on one vertical collector; nothing else touches;
--   * every other contact is a plain crossing, drawn with an underpass gap.
--     The pipe of the lower-priority promotion path always passes under, so
--     two paths cross the same way everywhere.
--
-- Every graph is searched here, nothing is stored per tree: a quick
-- estimate search for a start, then a row search scored by real channel
-- routings kept live per channel (only the touched channels re-route,
-- incrementally), stopped by a fixed work budget so even large trees open
-- without lag. (refinePasses > 0 selects the slow exact refinement, used
-- offline by devtools as a quality reference.)
--
-- A tree larger than the viewport is shrunk uniformly (layout.scale) down
-- to the smallest scale the card art accepts; beyond that layout.overflow is
-- set. The game scrolls the tree sideways but not vertically, so a tree too
-- tall even then moves cards into later columns (foldColumns) and grows
-- wider instead. The result uses the established layout table: buttons, routes,
-- sourceRoutes, source, width, height and scale. Nothing here depends on
-- Civ V.

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local INF = math.huge

local SOURCE_X = 24 -- the root source spine
local FIRST_COLUMN_X = 92
local MARGIN = 28 -- right and vertical canvas margin
local MARGIN_TIGHT = 12 -- vertical margin of a tree that otherwise would not fit in height
local STUB = 30 -- straight run between a card side and the first track
local JUNCTION_TRIM = 21 -- screen pixels a native pipe turn needs (PipeManager)
local TRACK_GAP = 44 -- preferred distance between tracks in a channel
local MIN_TRACK_GAP = 42 -- two native junction tiles still fit between tracks
local CHANNEL_MIN = 64
local MIN_SCALE = 0.8165 -- the smallest scale the card art accepts (1/sqrt(1.5))
local CHANNEL_MAX = 260
local ROW_GAP_MIN = 16 -- clear space between two cards in one column
local ROW_GAP_MAX = 56

-- Search effort. All loops are bounded by these and by the graph size.
local INITIAL_SWEEPS = 6
local SEARCH_PASSES = 6 -- before the slow exact refinement (offline)
local START_PASSES = 2 -- before the live search (in game)
local SEARCH_WINDOW = 3 -- candidate rows: within this of the neighbours' rows
local ORDER_PASSES = 4

-- Proxy weights: crossings dominate, then same-row conflicts, row changes
-- (vertical pipe length) and finally the number of rows.
local W_CROSS, W_CONTACT, W_SPAN, W_ROW = 1000, 400, 6, 30

--------------------------------------------------------------------------
-- Graph
--------------------------------------------------------------------------

local function prepareGraph(graph)
  local names = {}
  for i, name in ipairs(graph.order) do
    names[i] = name
  end
  table.sort(names)
  local id = {}
  for i, name in ipairs(names) do
    id[name] = i
  end
  local n = #names
  local parents, children, indegree = {}, {}, {}
  for i = 1, n do
    parents[i], children[i], indegree[i] = {}, {}, 0
  end
  local edges = {}
  for child = 1, n do
    local list = graph.nodes[names[child]].parents or {}
    local seen = {}
    for _, parentName in ipairs(list) do
      local parent = id[parentName]
      assert(parent, "dangling prerequisite " .. tostring(parentName))
      if not seen[parent] then
        seen[parent] = true
        edges[#edges + 1] = { parent = parent, child = child }
      end
    end
  end
  table.sort(edges, function(a, b)
    if a.parent ~= b.parent then
      return a.parent < b.parent
    end
    return a.child < b.child
  end)
  for i, e in ipairs(edges) do
    e.index = i
    parents[e.child][#parents[e.child] + 1] = e.parent
    children[e.parent][#children[e.parent] + 1] = e.child
    indegree[e.child] = indegree[e.child] + 1
  end
  local rank, queue, head = {}, {}, 1
  for i = 1, n do
    if indegree[i] == 0 then
      queue[#queue + 1], rank[i] = i, 0
    end
  end
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    for _, child in ipairs(children[node]) do
      rank[child] = max(rank[child] or 0, rank[node] + 1)
      indegree[child] = indegree[child] - 1
      if indegree[child] == 0 then
        queue[#queue + 1] = child
      end
    end
  end
  assert(#queue == n, "cyclic promotion prerequisites")
  local columns = 0
  for i = 1, n do
    columns = max(columns, rank[i] + 1)
  end
  -- Rank chains (Shock I-II-III) are rigid rows. A chain whose ranks do not
  -- strictly increase cannot be one row and is laid out as single cards.
  local chains = {}
  for _, chain in ipairs(graph.chains or {}) do
    local members = {}
    for _, name in ipairs(chain.nodes or chain) do
      members[#members + 1] = id[name]
    end
    local ok = #members > 1
    for i = 2, #members do
      if not members[i] or not members[i - 1] or rank[members[i]] <= rank[members[i - 1]] then
        ok = false
      end
    end
    if ok then
      chains[#chains + 1] = members
    end
  end
  -- A promotion whose only prerequisite is the previous column continues
  -- that prerequisite's row (Buffalo Chest, Horns, Loins), like a rank chain.
  -- Where a prerequisite has several such children, the one leading to the
  -- most promotions continues the row.
  local chainOf, position = {}, {}
  for index, chain in ipairs(chains) do
    for i, node in ipairs(chain) do
      chainOf[node], position[node] = index, i
    end
  end
  local descendants = {}
  local function countBelow(node)
    if descendants[node] then
      return descendants[node]
    end
    local seen, stack, count = { [node] = true }, { node }, 0
    while #stack > 0 do
      local current = table.remove(stack)
      for _, child in ipairs(children[current]) do
        if not seen[child] then
          seen[child], count = true, count + 1
          stack[#stack + 1] = child
        end
      end
    end
    descendants[node] = count
    return count
  end
  local byRank = {}
  for i = 1, n do
    byRank[i] = i
  end
  table.sort(byRank, function(a, b)
    if rank[a] ~= rank[b] then
      return rank[a] < rank[b]
    end
    return a < b
  end)
  for _, node in ipairs(byRank) do
    local ownChain = chainOf[node]
    local isTail = not ownChain or position[node] == #chains[ownChain]
    if isTail then
      local best = nil
      for _, child in ipairs(children[node]) do
        local childChain = chainOf[child]
        if
          #parents[child] == 1
          and rank[child] == rank[node] + 1
          and (not childChain or position[child] == 1)
          and (not best or countBelow(child) > countBelow(best))
        then
          best = child
        end
      end
      if best then
        local head = ownChain and chains[ownChain] or { node }
        if not ownChain then
          chains[#chains + 1] = head
          ownChain = #chains
          chainOf[node], position[node] = ownChain, 1
        end
        local tail = chainOf[best] and chains[chainOf[best]] or { best }
        local dropped = chainOf[best]
        for _, member in ipairs(tail) do
          head[#head + 1] = member
          chainOf[member], position[member] = ownChain, #head
        end
        if dropped then
          chains[dropped] = {}
        end
      end
    end
  end
  local kept = {}
  for _, chain in ipairs(chains) do
    if #chain > 1 then
      kept[#kept + 1] = chain
    end
  end
  chains = kept
  return {
    names = names,
    id = id,
    n = n,
    parents = parents,
    children = children,
    edges = edges,
    rank = rank,
    columns = columns,
    chains = chains,
  }
end

--------------------------------------------------------------------------
-- Folding: wider instead of taller
--------------------------------------------------------------------------

-- Rows of one column: its cards, the rank chains spanning it and the long
-- pipes crossing it (one row per prerequisite and target column, as in
-- buildObjects). Row packing reaches the largest of these.
local function columnLoads(g, rank)
  local load = {}
  local inChain, chainNext = {}, {}
  for _, chain in ipairs(g.chains) do
    for i, node in ipairs(chain) do
      inChain[node] = true
      if i > 1 then
        chainNext[chain[i - 1]] = node
      end
    end
    for c = rank[chain[1]], rank[chain[#chain]] do
      load[c] = (load[c] or 0) + 1
    end
  end
  for node = 1, g.n do
    if not inChain[node] then
      load[rank[node]] = (load[rank[node]] or 0) + 1
    end
  end
  local lanes, onChain = {}, {}
  for _, e in ipairs(g.edges) do
    local ra, rb = rank[e.parent], rank[e.child]
    if rb - ra >= 2 then
      local key = e.parent * 1000 + rb
      lanes[key] = lanes[key] or { ra, rb }
      if chainNext[e.parent] == e.child then
        onChain[key] = true
      end
    end
  end
  for key, span in pairs(lanes) do
    if not onChain[key] then
      for c = span[1] + 1, span[2] - 1 do
        load[c] = (load[c] or 0) + 1
      end
    end
  end
  return load
end

-- The screen allows no vertical scrolling, only horizontal: a tree whose
-- fullest column needs more rows than fit at the smallest scale moves cards
-- one column right (their descendants follow) until every column fits or
-- no move helps. Greedy over single cards and the sibling groups of one
-- prerequisite; scored by the rows still over, then columns, then pipe rows.
-- Roots stay in the first column, at the source spine.
local function foldColumns(g, fitRows)
  local load = columnLoads(g, g.rank)
  local function score(l)
    local over, total, columns = 0, 0, 0
    for c, v in pairs(l) do
      over = over + max(0, v - fitRows)
      total = total + v
      columns = max(columns, c + 1)
    end
    return over, columns, total
  end
  local over, columns, total = score(load)
  if over == 0 then
    return 0
  end
  local moved = 0
  for _ = 1, g.n do
    local best, bestOver, bestColumns, bestTotal = nil, over, columns, total
    local function try(nodes, c)
      local rank = {}
      for i = 1, g.n do
        rank[i] = g.rank[i]
      end
      local function push(node, r)
        if rank[node] >= r then
          return
        end
        rank[node] = r
        for _, child in ipairs(g.children[node]) do
          push(child, r + 1)
        end
      end
      for _, node in ipairs(nodes) do
        push(node, c + 1)
      end
      for _, chain in ipairs(g.chains) do
        for i = 2, #chain do
          if rank[chain[i]] <= rank[chain[i - 1]] then
            return -- would break a rank chain's order
          end
        end
      end
      local o, k, t = score(columnLoads(g, rank))
      if o < bestOver or (o == bestOver and best and (k < bestColumns or (k == bestColumns and t < bestTotal))) then
        best, bestOver, bestColumns, bestTotal = rank, o, k, t
      end
    end
    for c = 0, columns - 1 do
      if (load[c] or 0) > fitRows then
        local groups = {}
        for node = 1, g.n do
          if g.rank[node] == c and #g.parents[node] > 0 then
            try({ node }, c)
            for _, parent in ipairs(g.parents[node]) do
              groups[parent] = groups[parent] or {}
              table.insert(groups[parent], node)
            end
          end
        end
        for parent = 1, g.n do
          local group = groups[parent]
          if group and #group > 1 then
            try(group, c)
          end
        end
      end
    end
    if not best then
      break
    end
    g.rank = best
    moved = moved + 1
    load = columnLoads(g, g.rank)
    over, columns, total = score(load)
    if over == 0 then
      break
    end
  end
  g.columns = columns
  local stuck = over > 0
  return moved, stuck
end

-- Rows that fit the viewport at the smallest scale.
local RETRY_WORK = 1200 -- live search work of a refold (one start)
local function rowsThatFit(geometry)
  local viewportH = geometry.viewportH or 1000
  local free = viewportH / MIN_SCALE - 2 * MARGIN_TIGHT - geometry.buttonH
  return max(1, floor(free / (geometry.buttonH + ROW_GAP_MIN)) + 1)
end

--------------------------------------------------------------------------
-- Row objects and channels
--------------------------------------------------------------------------

-- Objects are rigid rows spanning columns lo..hi. Items are the cells of an
-- object, one per column: a card or a lane cell that a long pipe crosses.
local function buildObjects(g)
  local objects, items = {}, {}
  local cardItem, objectOf = {}, {}
  local function newObject(lo, hi)
    local object = { lo = lo, hi = hi, cells = {}, index = #objects + 1 }
    objects[#objects + 1] = object
    return object
  end
  local function newItem(object, column, card, lane)
    local item = { object = object, column = column, card = card, lane = lane, index = #items + 1 }
    items[#items + 1] = item
    assert(not object.cells[column], "object cell used twice")
    object.cells[column] = item
    return item
  end
  local chainOf, chainNext = {}, {}
  for _, chain in ipairs(g.chains) do
    local object = newObject(g.rank[chain[1]], g.rank[chain[#chain]])
    object.chain = chain
    for i, node in ipairs(chain) do
      chainOf[node] = object
      cardItem[node] = newItem(object, g.rank[node], node, nil)
      objectOf[node] = object
      if i > 1 then
        chainNext[chain[i - 1]] = node
      end
    end
  end
  for node = 1, g.n do
    if not cardItem[node] then
      local object = newObject(g.rank[node], g.rank[node])
      cardItem[node] = newItem(object, g.rank[node], node, nil)
      objectOf[node] = object
    end
  end
  -- A long pipe crosses the columns between its ends on one row. Pipes from
  -- one prerequisite to the same target column share that row; a chain's
  -- own long link stays on the chain's row.
  local laneOf, lanes = {}, {}
  local laneByKey = {}
  for _, e in ipairs(g.edges) do
    local ra, rb = g.rank[e.parent], g.rank[e.child]
    if rb - ra >= 2 then
      local key = e.parent * 1000 + rb
      local lane = laneByKey[key]
      if not lane then
        lane = { parent = e.parent, lo = ra + 1, hi = rb - 1, edges = {}, cells = {} }
        laneByKey[key] = lane
        lanes[#lanes + 1] = lane
      end
      lane.edges[#lane.edges + 1] = e
      if chainNext[e.parent] == e.child then
        lane.object = chainOf[e.parent]
      end
      laneOf[e.index] = lane
    end
  end
  for _, lane in ipairs(lanes) do
    local object = lane.object or newObject(lane.lo, lane.hi)
    lane.object = object
    for c = lane.lo, lane.hi do
      lane.cells[c] = newItem(object, c, nil, lane)
    end
  end
  -- Channel c lies between columns c and c+1. Merge every logical edge's
  -- passage through it into channel links between two items.
  local channels = {}
  for c = 0, g.columns - 2 do
    channels[c] = { links = {}, byKey = {} }
  end
  for _, e in ipairs(g.edges) do
    local ra, rb = g.rank[e.parent], g.rank[e.child]
    local lane = laneOf[e.index]
    for c = ra, rb - 1 do
      local left = c == ra and cardItem[e.parent] or lane.cells[c]
      local right = c + 1 == rb and cardItem[e.child] or lane.cells[c + 1]
      local channel = channels[c]
      local key = left.index * 100000 + right.index
      local link = channel.byKey[key]
      if not link then
        link = { left = left, right = right, edges = {} }
        channel.byKey[key] = link
        channel.links[#channel.links + 1] = link
      end
      link.edges[#link.edges + 1] = e
    end
  end
  -- Objects touched by a channel, for incremental re-scoring.
  for c = 0, g.columns - 2 do
    local channel = channels[c]
    channel.byKey = nil
    for _, link in ipairs(channel.links) do
      for _, object in ipairs({ link.left.object, link.right.object }) do
        object.channels = object.channels or {}
        object.channels[c] = true
      end
    end
  end
  for _, object in ipairs(objects) do
    local list = {}
    for c in pairs(object.channels or {}) do
      list[#list + 1] = c
    end
    table.sort(list)
    object.channelList = list
  end
  return {
    objects = objects,
    items = items,
    cardItem = cardItem,
    objectOf = objectOf,
    lanes = lanes,
    laneOf = laneOf,
    channels = channels,
  }
end

--------------------------------------------------------------------------
-- Row search with a crossing estimate
--------------------------------------------------------------------------

-- Estimate one channel for the current rows. Each left item is treated as
-- one vertical trunk spanning itself and its targets. For two trunks the
-- cheaper of their two left/right orders is charged; a straight row link
-- crosses every trunk that spans its row. Merges into a shared child are
-- free, as in the real router.
local function estimateShape(channel)
  local shape = { lefts = {}, targets = {}, rightOf = {}, leftOf = {}, y = {}, lo = {}, hi = {}, straight = {} }
  local index = {}
  for _, link in ipairs(channel.links) do
    local i = index[link.left]
    if not i then
      i = #shape.lefts + 1
      index[link.left] = i
      shape.lefts[i] = link.left.object
      shape.targets[i] = {}
    end
    local targets = shape.targets[i]
    targets[#targets + 1] = link.right.object
    shape.rightOf[#shape.rightOf + 1] = link.right.object
    shape.leftOf[#shape.leftOf + 1] = i
  end
  channel.shape = shape
  return shape
end

local function channelEstimate(channel, row)
  local shape = channel.shape or estimateShape(channel)
  local lefts, targets = shape.lefts, shape.targets
  local ys, los, his, straight = shape.y, shape.lo, shape.hi, shape.straight
  local count = #lefts
  local span = 0
  for i = 1, count do
    local yl = row[lefts[i]]
    local lo, hi, through = yl, yl, false
    local list = targets[i]
    for k = 1, #list do
      local yr = row[list[k]]
      if yr == yl then
        through = true
      else
        if yr < lo then
          lo = yr
        elseif yr > hi then
          hi = yr
        end
        span = span + abs(yr - yl)
      end
    end
    ys[i], los[i], his[i], straight[i] = yl, lo, hi, through
  end
  local crossings = 0
  for i = 1, count do
    local ya, loA, hiA, tA = ys[i], los[i], his[i], targets[i]
    local spansA = loA < hiA
    for j = i + 1, count do
      local yb, loB, hiB, tB = ys[j], los[j], his[j], targets[j]
      local spansB = loB < hiB
      -- A west of B: B's exit row passes A's trunk; A's entry rows pass B.
      -- Merging into B's trunk is free only where B's flow ends; elsewhere
      -- it costs a crossing or a separate collector.
      local ab, ba, fixed = 0, 0, 0
      if spansA then
        if yb > loA and yb < hiA then
          ab = 1
          -- A straight row crosses the other trunk whatever the order.
          if straight[j] then
            fixed = 1
          end
        end
        for k = 1, #tB do
          local y = row[tB[k]]
          if y ~= yb and y > loA and y < hiA then
            ba = ba + 1
          end
        end
      end
      if spansB then
        if ya > loB and ya < hiB then
          ba = ba + 1
          if straight[i] then
            fixed = fixed + 1
          end
        end
        for k = 1, #tA do
          local y = row[tA[k]]
          if y ~= ya and y > loB and y < hiB then
            ab = ab + 1
          end
        end
      end
      crossings = crossings + fixed + (ab < ba and ab or ba)
    end
  end
  -- A right item on the row of an unrelated left item shares that row in
  -- the channel; legal only with careful track order. Discourage it.
  local contacts = 0
  local rightOf, leftOf = shape.rightOf, shape.leftOf
  for m = 1, #rightOf do
    local yr, own = row[rightOf[m]], leftOf[m]
    for j = 1, count do
      if ys[j] == yr and j ~= own and not straight[j] then
        contacts = contacts + 1
      end
    end
  end
  return crossings * W_CROSS + contacts * W_CONTACT + span * W_SPAN
end

local function occupied(cells, object, r)
  for c = object.lo, object.hi do
    local owner = cells[c][r]
    if owner and owner ~= object then
      return true
    end
  end
  return false
end

local function place(cells, object, r)
  for c = object.lo, object.hi do
    cells[c][r] = object
  end
  object.row = r
end

local function lift(cells, object)
  for c = object.lo, object.hi do
    if cells[c][object.row] == object then
      cells[c][object.row] = nil
    end
  end
end

-- Pack objects in the order of their wanted positions: each takes the first
-- row below everything already placed in its columns. Rows keep the order.
local function packRows(objects, wanted, columns)
  local sorted = {}
  for i, object in ipairs(objects) do
    sorted[i] = object
  end
  table.sort(sorted, function(a, b)
    if wanted[a] ~= wanted[b] then
      return wanted[a] < wanted[b]
    end
    return a.index < b.index
  end)
  local nextFree = {}
  for c = 0, columns - 1 do
    nextFree[c] = 0
  end
  local rows = 0
  for _, object in ipairs(sorted) do
    local r = 0
    for c = object.lo, object.hi do
      r = max(r, nextFree[c])
    end
    object.row = r
    for c = object.lo, object.hi do
      nextFree[c] = r + 1
    end
    rows = max(rows, r + 1)
  end
  return rows
end

local function neighbourObjects(g, s)
  -- Objects joined by a pipe, with lanes standing in for distant ends.
  local links = {}
  for _, object in ipairs(s.objects) do
    links[object] = {}
  end
  local function join(a, b)
    if a ~= b then
      links[a][#links[a] + 1] = b
      links[b][#links[b] + 1] = a
    end
  end
  for c = 0, g.columns - 2 do
    for _, link in ipairs(s.channels[c].links) do
      join(link.left.object, link.right.object)
    end
  end
  return links
end

-- Start orders of the live search: seed 2 first (the better one on its
-- own), then 1, then shuffled name orders.
local LIVE_STARTS = { 2, 1, 3, 4, 5, 6, 7, 8 }
local MULTI_START_WORK = 1500 -- live routing work for all starts together
local MULTI_START_MIN = 150 -- a further start needs at least this much

local function initialRows(g, s, links, seed)
  -- Barycentric sweeps on real positions, re-packed into rows each time.
  local wanted = {}
  for _, object in ipairs(s.objects) do
    local first = object.cells[object.lo]
    local key = first.card and g.names[first.card] or ("~" .. object.index)
    wanted[object] = object.index
    object.key = key
    if seed > 2 then
      local h = seed * 2654435761 % 4294967296
      for i = 1, #key do
        h = (h * 33 + key:byte(i)) % 4294967296
      end
      object.shuffle = h + object.index / 1024
    end
  end
  local sorted = {}
  for i, object in ipairs(s.objects) do
    sorted[i] = object
  end
  table.sort(sorted, function(a, b)
    if a.lo ~= b.lo then
      return a.lo < b.lo
    end
    if seed == 2 then
      return a.key > b.key
    elseif seed > 2 then
      return a.shuffle < b.shuffle
    end
    return a.key < b.key
  end)
  for i, object in ipairs(sorted) do
    wanted[object] = i
  end
  local rows = packRows(s.objects, wanted, g.columns)
  for sweep = 1, INITIAL_SWEEPS do
    local next = {}
    for _, object in ipairs(s.objects) do
      local list = links[object]
      if #list > 0 then
        local sum = 0
        for i = 1, #list do
          sum = sum + list[i].row
        end
        next[object] = 0.5 * object.row + 0.5 * sum / #list + object.index * 1e-6
      else
        next[object] = object.row + object.index * 1e-6
      end
    end
    rows = packRows(s.objects, next, g.columns)
  end
  return rows
end

local function searchRows(g, s, rows, passes)
  local columns = g.columns
  local channels = s.channels
  local cells = {}
  for c = 0, columns - 1 do
    cells[c] = {}
  end
  local row = {}
  for _, object in ipairs(s.objects) do
    place(cells, object, object.row)
  end
  local function syncRows()
    for _, object in ipairs(s.objects) do
      row[object] = object.row
    end
  end
  syncRows()
  -- Neighbours: objects joined to an object by a link.
  local near = {}
  for _, object in ipairs(s.objects) do
    near[object] = {}
  end
  for c = 0, columns - 2 do
    for _, link in ipairs(channels[c].links) do
      local a, b = link.left.object, link.right.object
      if a ~= b then
        table.insert(near[a], b)
        table.insert(near[b], a)
      end
    end
  end
  local channelCost = {}
  local total = 0
  for c = 0, columns - 2 do
    channelCost[c] = channelEstimate(channels[c], row)
    total = total + channelCost[c]
  end
  local function usedRows()
    local used = 0
    for c = 0, columns - 1 do
      for r in pairs(cells[c]) do
        if r + 1 > used then
          used = r + 1
        end
      end
    end
    return used
  end
  local rowsUsed = usedRows()
  local fill = {}
  for r = 0, rowsUsed do
    fill[r] = 0
  end
  for _, object in ipairs(s.objects) do
    fill[object.row] = fill[object.row] + 1
  end
  -- Rows in use after moving one object from one row to another.
  local function rowsAfter(from, to)
    if to >= rowsUsed then
      return to + 1
    end
    if from == rowsUsed - 1 and fill[from] == 1 then
      local top = from - 1
      while top > to and fill[top] == 0 do
        top = top - 1
      end
      return top + 1
    end
    return rowsUsed
  end
  local function rescore(objectA, objectB)
    local delta = 0
    local fresh = {}
    for _, c in ipairs(objectA.channelList) do
      local value = channelEstimate(channels[c], row)
      fresh[c] = value
      delta = delta + value - channelCost[c]
    end
    if objectB then
      for _, c in ipairs(objectB.channelList) do
        if not fresh[c] then
          local value = channelEstimate(channels[c], row)
          fresh[c] = value
          delta = delta + value - channelCost[c]
        end
      end
    end
    return delta, fresh
  end
  local function commit(fresh)
    for c, value in pairs(fresh) do
      total = total + value - channelCost[c]
      channelCost[c] = value
    end
  end
  for pass = 1, passes do
    local improved = false
    for _, object in ipairs(s.objects) do
      if #object.channelList > 0 then
        local from = object.row
        local bestDelta, bestRow, bestFresh = -0.5, nil, nil
        local bestSwap, bestRows = nil, nil
        -- Rows near the neighbours' rows, up to one fresh row below.
        local rlo, rhi = INF, -INF
        for _, nb in ipairs(near[object]) do
          if nb.row < rlo then rlo = nb.row end
          if nb.row > rhi then rhi = nb.row end
        end
        if rlo > rhi then rlo, rhi = from, from end
        rlo, rhi = max(0, rlo - SEARCH_WINDOW), min(rowsUsed, rhi + SEARCH_WINDOW)
        for r = rlo, rhi do
          if r ~= from then
            if not occupied(cells, object, r) then
              lift(cells, object)
              place(cells, object, r)
              row[object] = r
              local newRows = rowsAfter(from, r)
              local delta, fresh = rescore(object)
              delta = delta + (newRows - rowsUsed) * W_ROW
              if delta < bestDelta then
                bestDelta, bestRow, bestFresh, bestSwap, bestRows = delta, r, fresh, nil, newRows
              end
              lift(cells, object)
              place(cells, object, from)
              row[object] = from
            else
              -- Swap with the single object in the way, when both fit.
              local other = nil
              local single = true
              for c = object.lo, object.hi do
                local owner = cells[c][r]
                if owner and owner ~= object then
                  if other and other ~= owner then
                    single = false
                  end
                  other = owner
                end
              end
              if single and other and #other.channelList > 0 then
                lift(cells, object)
                lift(cells, other)
                local fits = not occupied(cells, object, r) and not occupied(cells, other, from)
                if fits then
                  place(cells, object, r)
                  place(cells, other, from)
                  row[object], row[other] = r, from
                  local delta, fresh = rescore(object, other)
                  if delta < bestDelta then
                    bestDelta, bestRow, bestFresh, bestSwap, bestRows = delta, r, fresh, other, rowsUsed
                  end
                  lift(cells, object)
                  lift(cells, other)
                  row[object], row[other] = from, r
                end
                place(cells, other, r)
                place(cells, object, from)
              end
            end
          end
        end
        if bestRow then
          lift(cells, object)
          if bestSwap then
            lift(cells, bestSwap)
            place(cells, bestSwap, from)
            row[bestSwap] = from
          end
          place(cells, object, bestRow)
          row[object] = bestRow
          if not bestSwap then
            fill[from] = fill[from] - 1
            fill[bestRow] = (fill[bestRow] or 0) + 1
          end
          commit(bestFresh)
          rowsUsed = bestRows
          improved = true
        end
      end
    end
    if not improved then
      break
    end
  end
  -- Drop empty rows.
  local usedRow = {}
  for _, object in ipairs(s.objects) do
    usedRow[object.row] = true
  end
  local remap, count = {}, 0
  for r = 0, rowsUsed do
    if usedRow[r] then
      remap[r] = count
      count = count + 1
    end
  end
  for _, object in ipairs(s.objects) do
    object.row = remap[object.row]
  end
  return total + count * W_ROW, count
end

--------------------------------------------------------------------------
-- Exact channel routing
--------------------------------------------------------------------------

local ILLEGAL, CROSSING, TRACK_COST = 1000000, 1000, 40
-- Structure search rounds per channel: full routing, and the quick routing
-- that scores rows during exact refinement.
local ROUTE_ROUNDS, QUICK_ROUNDS = 4, 2

-- The channel's prerequisite-side (left) and child-side (right) items.
local function channelItems(channel, yOf)
  local lefts, rights = {}, {}
  local leftList, rightList = {}, {}
  for _, link in ipairs(channel.links) do
    local l, r = link.left, link.right
    if not lefts[l] then
      lefts[l] = { item = l, y = yOf[l], links = {}, isLeft = true }
      leftList[#leftList + 1] = lefts[l]
    end
    if not rights[r] then
      rights[r] = { item = r, y = yOf[r], links = {} }
      rightList[#rightList + 1] = rights[r]
    end
    local L, R = lefts[l], rights[r]
    L.links[#L.links + 1] = link
    R.links[#R.links + 1] = link
    link.L, link.R = L, R
    link.straight = L.y == R.y
    if link.straight then
      L.straight = R
      R.straight = L
    end
  end
  return leftList, rightList
end

-- Tracks from each link's mode: "trunk" shares its prerequisite's vertical
-- trunk, "collector" shares its child's vertical collector and "own" runs on
-- a track of its own. A link on its own track only ever splits from its
-- prerequisite's row or merges into its child's row.
local function buildTracks(links, leftList, rightList)
  for _, L in ipairs(leftList) do
    L.tracks = {}
  end
  for _, R in ipairs(rightList) do
    R.tracks = {}
  end
  local tracks, trunkOf, collectorOf = {}, {}, {}
  for _, link in ipairs(links) do
    if not link.straight then
      local L, R = link.L, link.R
      local track
      if link.mode == "trunk" then
        track = trunkOf[L]
      elseif link.mode == "collector" then
        track = collectorOf[R]
      end
      if not track then
        track = {
          kind = link.mode,
          owner = link.mode == "collector" and R or L,
          links = {},
          lo = INF,
          hi = -INF,
          sources = {},
          targets = {},
          ys = {},
          id = #tracks + 1,
        }
        tracks[#tracks + 1] = track
        if link.mode == "trunk" then
          trunkOf[L] = track
        elseif link.mode == "collector" then
          collectorOf[R] = track
        end
      end
      track.links[#track.links + 1] = link
      link.track = track
      track.lo = min(track.lo, L.y, R.y)
      track.hi = max(track.hi, L.y, R.y)
      track.ys[L.y], track.ys[R.y] = true, true
      if not track.sources[L] then
        track.sources[L] = true
        L.tracks[#L.tracks + 1] = track
      end
      if not track.targets[R] then
        track.targets[R] = true
        R.tracks[#R.tracks + 1] = track
      end
    else
      link.track = nil
    end
  end
  return tracks
end

-- Does flow on this track run past row y, i.e. does any of its links span y
-- strictly? A line meeting the track there would join unrelated pipes.
local function flowsThrough(track, y)
  for _, link in ipairs(track.links) do
    local a, b = link.L.y, link.R.y
    if (a - y) * (b - y) < 0 then
      return true
    end
  end
  return false
end

-- What it costs a row line to pass a track: a prerequisite's row runs east
-- to its last track, a child's row from its first track. Passing a track it
-- belongs to is a split or merge, legal unless other flow runs through the
-- point; any other contact is a crossing or, at a junction row, illegal.
local function contactCosts(tracks, leftList, rightList)
  for _, L in ipairs(leftList) do
    local cost, y, through = {}, L.y, L.straight
    for i, track in ipairs(tracks) do
      if track.sources[L] or (through and track.targets[through]) then
        cost[i] = flowsThrough(track, y) and ILLEGAL or 0
      elseif track.ys[y] then
        cost[i] = ILLEGAL
      elseif y > track.lo and y < track.hi then
        cost[i] = CROSSING
      else
        cost[i] = 0
      end
    end
    L.cost = cost
  end
  for _, R in ipairs(rightList) do
    local cost, y = {}, R.y
    for i, track in ipairs(tracks) do
      if track.targets[R] then
        cost[i] = flowsThrough(track, y) and ILLEGAL or 0
      elseif R.straight or track.ys[y] then
        -- A straight row was charged as its prerequisite's line.
        cost[i] = R.straight and 0 or ILLEGAL
      elseif y > track.lo and y < track.hi then
        cost[i] = CROSSING
      else
        cost[i] = 0
      end
    end
    R.cost = cost
  end
end

-- One row line's cost for a track order: the contacts it passes plus a
-- small length term. A straight row is charged on its prerequisite's side;
-- its child side only checks that the row splits before it merges.
local function lineCost(line, k, pos)
  local tracks = line.tracks
  if line.isLeft then
    local east = 0
    if line.straight then
      east = k + 1
    else
      for j = 1, #tracks do
        local p = pos[tracks[j].id]
        if p > east then
          east = p
        end
      end
    end
    local cost, total = line.cost, east
    for i = 1, k do
      if pos[i] < east then
        total = total + cost[i]
      end
    end
    return total
  end
  local straight = line.straight
  if straight then
    -- West of the child's first merge the row carries only its
    -- prerequisite's pipes; east of it only pipes into the child.
    local total = 0
    local own = straight.tracks
    for m = 1, #own do
      local p = pos[own[m].id]
      for j = 1, #tracks do
        if p > pos[tracks[j].id] then
          total = total + ILLEGAL
        end
      end
    end
    return total
  end
  local west = k + 1
  for j = 1, #tracks do
    local p = pos[tracks[j].id]
    if p < west then
      west = p
    end
  end
  local cost, total = line.cost, k + 1 - west
  for i = 1, k do
    if pos[i] > west then
      total = total + cost[i]
    end
  end
  return total
end

-- Lines whose cost depends on where a track stands.
local function trackLines(tracks, leftList, rightList)
  for _, track in ipairs(tracks) do
    track.lines = {}
  end
  local function add(track, line)
    local lines = track.lines
    if lines[#lines] ~= line then
      lines[#lines + 1] = line
    end
  end
  for _, L in ipairs(leftList) do
    for _, track in ipairs(L.tracks) do
      add(track, L)
    end
  end
  for _, R in ipairs(rightList) do
    for _, track in ipairs(R.tracks) do
      add(track, R)
    end
    if R.straight then
      for _, track in ipairs(R.straight.tracks) do
        add(track, R)
      end
    end
  end
end

local function orderCost(k, leftList, rightList, pos)
  local total = 0
  for _, L in ipairs(leftList) do
    L.contribution = lineCost(L, k, pos)
    total = total + L.contribution
  end
  for _, R in ipairs(rightList) do
    R.contribution = lineCost(R, k, pos)
    total = total + R.contribution
  end
  return total
end

-- Order tracks west to east. Swapping two neighbours only changes the lines
-- of those two tracks, so swaps are scored incrementally; the final
-- structure also tries moving every track anywhere.
local function orderTracks(tracks, leftList, rightList, thorough)
  local k = #tracks
  local order = {}
  for i = 1, k do
    order[i] = tracks[i]
  end
  table.sort(order, function(a, b)
    local ka = a.kind == "collector" and 1 or 0
    local kb = b.kind == "collector" and 1 or 0
    if ka ~= kb then
      return ka < kb
    end
    if a.hi - a.lo ~= b.hi - b.lo then
      return (a.hi - a.lo) < (b.hi - b.lo)
    end
    if a.lo ~= b.lo then
      return a.lo < b.lo
    end
    return a.id < b.id
  end)
  local pos = {}
  for i = 1, k do
    pos[order[i].id] = i
  end
  trackLines(tracks, leftList, rightList)
  local best = orderCost(k, leftList, rightList, pos)
  local affected, seen = {}, {}
  for _ = 1, ORDER_PASSES do
    local improved = false
    for i = 1, k - 1 do
      local a, b = order[i], order[i + 1]
      local count = 0
      for _, list in ipairs({ a.lines, b.lines }) do
        for j = 1, #list do
          local line = list[j]
          if seen[line] ~= a then
            seen[line] = a
            count = count + 1
            affected[count] = line
          end
        end
      end
      local before = 0
      for j = 1, count do
        before = before + affected[j].contribution
      end
      pos[a.id], pos[b.id] = i + 1, i
      local after = 0
      for j = 1, count do
        local line = affected[j]
        line.fresh = lineCost(line, k, pos)
        after = after + line.fresh
      end
      if after < before then
        best, improved = best + after - before, true
        order[i], order[i + 1] = b, a
        for j = 1, count do
          affected[j].contribution = affected[j].fresh
        end
      else
        pos[a.id], pos[b.id] = i, i + 1
      end
      for j = 1, count do
        seen[affected[j]] = nil
      end
    end
    if thorough then
      for i = 1, k do
        for j = 1, k do
          if i ~= j then
            local moved = table.remove(order, i)
            table.insert(order, j, moved)
            for m = min(i, j), max(i, j) do
              pos[order[m].id] = m
            end
            local value = orderCost(k, leftList, rightList, pos)
            if value < best then
              best, improved = value, true
            else
              table.remove(order, j)
              table.insert(order, i, moved)
              for m = min(i, j), max(i, j) do
                pos[order[m].id] = m
              end
            end
          end
        end
      end
      orderCost(k, leftList, rightList, pos)
    end
    if not improved then
      break
    end
  end
  return order, pos, best
end

-- Route one channel. Link modes start either with collectors for children
-- fed by several prerequisites or with trunks only; then single links and
-- whole groups (all of one prerequisite's links, all of one child's) change
-- mode while that removes crossings or illegal contacts.
local LETTER_MODE = { t = "trunk", c = "collector", o = "own" }

local function routeChannel(channel, yOf, quick, key)
  local links = channel.links
  local leftList, rightList = channelItems(channel, yOf)
  local function evaluate(thorough)
    local tracks = buildTracks(links, leftList, rightList)
    contactCosts(tracks, leftList, rightList)
    local order, pos, cost = orderTracks(tracks, leftList, rightList, thorough)
    return cost + #tracks * TRACK_COST, tracks, order, pos
  end
  -- A routing key from the live search, "modes:order": one letter per
  -- link, then the track ids west to east. Nil unless it fits these links
  -- and is legal.
  local function replay()
    local modeText, orderText = key:match("^(%a*):([%d,]*)$")
    if not modeText or #modeText ~= #links then
      return nil
    end
    for i, link in ipairs(links) do
      link.mode = LETTER_MODE[modeText:sub(i, i)]
      if not link.mode then
        return nil
      end
    end
    local tracks = buildTracks(links, leftList, rightList)
    contactCosts(tracks, leftList, rightList)
    local order, pos = {}, {}
    for text in orderText:gmatch("%d+") do
      local id = tonumber(text)
      if not tracks[id] or pos[id] then
        return nil
      end
      order[#order + 1] = tracks[id]
      pos[id] = #order
    end
    if #order ~= #tracks then
      return nil
    end
    local cost = orderCost(#tracks, leftList, rightList, pos)
    if cost >= ILLEGAL then
      return nil
    end
    return cost + #tracks * TRACK_COST, tracks, order, pos
  end
  local function snapshot()
    local modes = {}
    for i, link in ipairs(links) do
      modes[i] = link.mode
    end
    return modes
  end
  local function restore(modes)
    for i, link in ipairs(links) do
      link.mode = modes[i]
    end
  end
  -- Links that take part in a crossing or illegal contact: those of a line
  -- that pays for a contact and those of every track it pays for.
  local function involvedLinks()
    local tracks = buildTracks(links, leftList, rightList)
    contactCosts(tracks, leftList, rightList)
    local _, pos = orderTracks(tracks, leftList, rightList, false)
    local k = #tracks
    local mark, list = {}, {}
    local function addLinks(group)
      for _, link in ipairs(group) do
        if not mark[link] and not link.straight then
          mark[link] = true
          list[#list + 1] = link
        end
      end
    end
    local function addLine(line)
      local paid = false
      if line.isLeft then
        local east = line.straight and k + 1 or 0
        for _, track in ipairs(line.tracks) do
          east = max(east, pos[track.id])
        end
        for i = 1, k do
          if pos[i] < east and line.cost[i] > 0 then
            addLinks(tracks[i].links)
            paid = true
          end
        end
      elseif line.straight then
        if line.contribution >= ILLEGAL then
          addLinks(line.straight.links)
          paid = true
        end
      else
        local west = k + 1
        for _, track in ipairs(line.tracks) do
          west = min(west, pos[track.id])
        end
        for i = 1, k do
          if pos[i] > west and line.cost[i] > 0 then
            addLinks(tracks[i].links)
            paid = true
          end
        end
      end
      if paid then
        addLinks(line.links)
      end
    end
    for _, L in ipairs(leftList) do
      addLine(L)
    end
    for _, R in ipairs(rightList) do
      addLine(R)
    end
    return list
  end
  local function improve(best)
    local modes = { "trunk", "collector", "own" }
    for _ = 1, quick and QUICK_ROUNDS or ROUTE_ROUNDS do
      if best < CROSSING then
        break
      end
      local improved = false
      local candidates = involvedLinks()
      for _, link in ipairs(candidates) do
        local current = link.mode
        for _, mode in ipairs(modes) do
          if mode ~= current then
            link.mode = mode
            local value = evaluate(false)
            if value < best then
              best, current, improved = value, mode, true
            end
          end
        end
        link.mode = current
      end
      local groups, seenItem = {}, {}
      for _, link in ipairs(candidates) do
        local L, R = link.L, link.R
        if not seenItem[L] then
          seenItem[L] = true
          groups[#groups + 1] = { members = L.links, mode = "trunk" }
          groups[#groups + 1] = { members = L.links, mode = "own" }
        end
        if not seenItem[R] then
          seenItem[R] = true
          groups[#groups + 1] = { members = R.links, mode = "collector" }
        end
      end
      for _, group in ipairs(groups) do
        local saved = snapshot()
        local changed = false
        for _, link in ipairs(group.members) do
          if not link.straight and link.mode ~= group.mode then
            link.mode, changed = group.mode, true
          end
        end
        if changed then
          local value = evaluate(false)
          if value < best then
            best, improved = value, true
          else
            restore(saved)
          end
        end
      end
      if not improved then
        break
      end
    end
    return best
  end
  local value, tracks, order, pos
  if key then
    value, tracks, order, pos = replay()
  end
  if not value then
    local best, bestModes = INF, nil
    for start = 1, quick and 1 or 2 do
      for _, link in ipairs(links) do
        link.mode = (start == 1 and #link.R.links >= 2) and "collector" or "trunk"
      end
      local found = improve(evaluate(false))
      if found < best then
        best, bestModes = found, snapshot()
      end
      if best < CROSSING then
        break
      end
    end
    restore(bestModes)
    if quick then
      return best
    end
    value, tracks, order, pos = evaluate(true)
  end
  -- Report each crossing for the underpass pass.
  local k = #tracks
  local crossingsList, illegal = {}, 0
  for _, L in ipairs(leftList) do
    local east = L.straight and k + 1 or 0
    for _, track in ipairs(L.tracks) do
      east = max(east, pos[track.id])
    end
    for i = 1, k do
      if pos[i] < east then
        if L.cost[i] == CROSSING then
          crossingsList[#crossingsList + 1] = { track = tracks[i], y = L.y }
        elseif L.cost[i] >= ILLEGAL then
          illegal = illegal + 1
        end
      end
    end
  end
  for _, R in ipairs(rightList) do
    if not R.straight then
      local west = k + 1
      for _, track in ipairs(R.tracks) do
        west = min(west, pos[track.id])
      end
      for i = 1, k do
        if pos[i] > west then
          if R.cost[i] == CROSSING then
            crossingsList[#crossingsList + 1] = { track = tracks[i], y = R.y }
          elseif R.cost[i] >= ILLEGAL then
            illegal = illegal + 1
          end
        end
      end
    end
  end
  illegal = max(illegal, floor(value / ILLEGAL))
  return {
    tracks = tracks,
    order = order,
    crossings = crossingsList,
    illegal = illegal,
  }
end

-- Exact refinement of the row order: the same moves as the estimate search,
-- scored by routing the affected channels for real.
local function refineRows(g, s, passes)
  local columns, channels = g.columns, s.channels
  local cells = {}
  for c = 0, columns - 1 do
    cells[c] = {}
  end
  for _, object in ipairs(s.objects) do
    place(cells, object, object.row)
  end
  local yOf = {}
  local function sync(object)
    for _, item in pairs(object.cells) do
      yOf[item] = object.row
    end
  end
  for _, object in ipairs(s.objects) do
    sync(object)
  end
  -- Routing compares rows only, so a channel's result depends on the order
  -- of its items' rows; most trial moves repeat an order already routed.
  local memo, ranked = {}, {}
  for c = 0, columns - 2 do
    local items, seen = {}, {}
    for _, link in ipairs(channels[c].links) do
      for _, item in ipairs({ link.left, link.right }) do
        if not seen[item] then
          seen[item] = true
          items[#items + 1] = item
        end
      end
    end
    channels[c].items = items
    memo[c] = {}
  end
  local routed = 0
  local function channelValue(c)
    local items = channels[c].items
    local rows, distinct, present = {}, {}, {}
    for i, item in ipairs(items) do
      local r = yOf[item]
      rows[i] = r
      if not present[r] then
        present[r] = true
        distinct[#distinct + 1] = r
      end
    end
    table.sort(distinct)
    local rank = {}
    for i, r in ipairs(distinct) do
      rank[r] = i
    end
    for i = 1, #items do
      rows[i] = rank[rows[i]]
    end
    local key = table.concat(rows, ",")
    local value = memo[c][key]
    if not value then
      for i, item in ipairs(items) do
        ranked[item] = rows[i]
      end
      value = routeChannel(channels[c], ranked, true)
      memo[c][key] = value
      routed = routed + 1
    end
    return value
  end
  local cost, total = {}, 0
  for c = 0, columns - 2 do
    cost[c] = channelValue(c)
    total = total + cost[c]
  end
  local rowsUsed = 0
  for _, object in ipairs(s.objects) do
    rowsUsed = max(rowsUsed, object.row + 1)
  end
  local evaluations = 0
  local function trial(a, b)
    local touched = {}
    for _, object in ipairs({ a, b }) do
      if object then
        for _, c in ipairs(object.channelList) do
          touched[c] = true
        end
      end
    end
    local delta, fresh = 0, {}
    for c in pairs(touched) do
      fresh[c] = channelValue(c)
      delta = delta + fresh[c] - cost[c]
    end
    evaluations = evaluations + 1
    return delta, fresh
  end
  for _ = 1, passes do
    local improved = false
    for _, object in ipairs(s.objects) do
      if #object.channelList > 0 then
        local from = object.row
        local bestDelta, bestRow, bestFresh, bestSwap = -0.5, nil, nil, nil
        for r = 0, rowsUsed do
          if r ~= from then
            local other, single = nil, true
            for c = object.lo, object.hi do
              local owner = cells[c][r]
              if owner and owner ~= object then
                if other and other ~= owner then
                  single = false
                end
                other = owner
              end
            end
            if not other then
              lift(cells, object)
              place(cells, object, r)
              sync(object)
              local delta, fresh = trial(object)
              if delta < bestDelta then
                bestDelta, bestRow, bestFresh, bestSwap = delta, r, fresh, nil
              end
              lift(cells, object)
              place(cells, object, from)
              sync(object)
            elseif single and #other.channelList > 0 then
              lift(cells, object)
              lift(cells, other)
              if not occupied(cells, object, r) and not occupied(cells, other, from) then
                place(cells, object, r)
                place(cells, other, from)
                sync(object)
                sync(other)
                local delta, fresh = trial(object, other)
                if delta < bestDelta then
                  bestDelta, bestRow, bestFresh, bestSwap = delta, r, fresh, other
                end
                lift(cells, object)
                lift(cells, other)
              end
              place(cells, other, r)
              place(cells, object, from)
              sync(object)
              sync(other)
            end
          end
        end
        if bestRow then
          lift(cells, object)
          if bestSwap then
            lift(cells, bestSwap)
            place(cells, bestSwap, from)
            sync(bestSwap)
          end
          place(cells, object, bestRow)
          sync(object)
          for c, value in pairs(bestFresh) do
            total = total + value - cost[c]
            cost[c] = value
          end
          rowsUsed = max(rowsUsed, bestRow + 1)
          improved = true
        end
      end
    end
    if not improved then
      break
    end
  end
  local usedRow = {}
  for _, object in ipairs(s.objects) do
    usedRow[object.row] = true
  end
  local remap, count = {}, 0
  for r = 0, rowsUsed do
    if usedRow[r] then
      remap[r], count = count, count + 1
    end
  end
  for _, object in ipairs(s.objects) do
    object.row = remap[object.row]
  end
  return count, evaluations, total, routed
end

--------------------------------------------------------------------------
-- Families: which pipe passes over at a crossing
--------------------------------------------------------------------------

-- A promotion path starts at a root or at a promotion with several
-- prerequisites and continues through single-prerequisite promotions. Paths
-- unlocked by something outside the class (a unique unit's promotions) rank
-- lowest; the rest rank by their first promotion's database order (Shock
-- before Drill), then by row, top first.
-- Live search (the game path): an exact
-- channel router kept live per channel, and a row search scored by it.
local liveRefine
do
  -- Routing work of the live search: 3 per live trial, 1 per mode trial
  -- (about 4000 VM instructions each).
  local liveWork = 0
  -- Exact track order by branch-and-bound from an incumbent (the current
  -- order and its cost). Tracks are placed west to east; a left line settles
  -- when its last own track is placed, a right line when its first one is.
  -- Rewrites order/pos when it finds better. Returns value, nodes, aborted.
  local function exactTrackOrder(k, order, pos, nL, nR, Lstraight, Rstraight, ownL, ownLN, ownR, ownRN, wL, wR, srcC, incumbent, cap)
    local slots = {}
    for j = 1, k do slots[j] = order[j] end
    -- Work in local indices 1..k.
    local idx = {}
    for j = 1, k do idx[slots[j]] = j end
    local WL, WR = {}, {}
    for a = 1, nL do
      local row, w = {}, wL[a]
      for j = 1, k do row[j] = w[slots[j]] end
      WL[a] = row
    end
    for b = 1, nR do
      local row, w = {}, wR[b]
      for j = 1, k do row[j] = w[slots[j]] end
      WR[b] = row
    end
    local OL, OR = {}, {}
    for a = 1, nL do
      local l = {}
      for m = 1, ownLN[a] do l[m] = idx[ownL[a][m]] end
      OL[a] = l
    end
    for b = 1, nR do
      local l = {}
      for m = 1, ownRN[b] do l[m] = idx[ownR[b][m]] end
      OR[b] = l
    end
    local constant = 0
    for a = 1, nL do
      if Lstraight[a] ~= 0 then
        constant = constant + k + 1
        for j = 1, k do constant = constant + WL[a][j] end
      end
    end
    local P = {}
    for i = 1, k do local row = {}; for j = 1, k do row[j] = 0 end; P[i] = row end
    for a = 1, nL do
      if Lstraight[a] == 0 then
        local own, n, w = OL[a], #OL[a], WL[a]
        local isOwn = {}
        for m = 1, n do isOwn[own[m]] = true end
        for m = 1, n do
          local o = own[m]
          for i = 1, k do
            if not isOwn[i] then P[i][o] = P[i][o] + (1 + w[i]) / n end
          end
        end
      end
    end
    for b = 1, nR do
      local sa = Rstraight[b]
      if sa ~= 0 then
        for m = 1, #OL[sa] do
          local p = OL[sa][m]
          for j = 1, #OR[b] do
            local q = OR[b][j]
            P[q][p] = P[q][p] + ILLEGAL
          end
        end
      elseif #OR[b] == 1 then
        local o, w = OR[b][1], WR[b]
        for i = 1, k do if i ~= o then P[o][i] = P[o][i] + 1 + w[i] end end
      end
    end
    local pairMin = 0
    for i = 1, k - 1 do
      for j = i + 1, k do
        local x, y = P[i][j], P[j][i]
        pairMin = pairMin + (x < y and x or y)
      end
    end
    if constant + pairMin >= incumbent then return incumbent, 0, false end
    local totR = {}
    for b = 1, nR do
      local s, w = 0, WR[b]
      for j = 1, k do s = s + 1 + w[j] end
      totR[b] = s
    end
    local isL, isR = {}, {}
    for j = 1, k do isL[j], isR[j] = {}, {} end
    for a = 1, nL do
      if Lstraight[a] == 0 then
        for _, j in ipairs(OL[a]) do local l = isL[j]; l[#l + 1] = a end
      end
    end
    for b = 1, nR do
      for _, j in ipairs(OR[b]) do local l = isR[j]; l[#l + 1] = b end
    end
    local placed, accL, accR, cntL, startedR = {}, {}, {}, {}, {}
    for j = 1, k do placed[j] = false end
    for a = 1, nL do accL[a], cntL[a] = 0, 0 end
    for b = 1, nR do accR[b], startedR[b] = 0, false end
    local pendL, pendR = 0, 0 -- 1 + accL over unsettled lefts; 1 per unstarted right
    for a = 1, nL do if Lstraight[a] == 0 then pendL = pendL + 1 end end
    for b = 1, nR do if Rstraight[b] == 0 then pendR = pendR + 1 end end
    local best = incumbent
    local bestOrder = nil
    local cur = {}
    local nodes, aborted = 0, false
    local function dfs(depth, cost, pm, pend)
      nodes = nodes + 1
      if nodes > cap then aborted = true return end
      if depth > k then
        if cost < best then
          best = cost
          bestOrder = {}
          for j = 1, k do bestOrder[j] = cur[j] end
        end
        return
      end
      for t = 1, k do
        if not placed[t] then
          local add = 0
          local lt, rt = isL[t], isR[t]
          local pendDelta = 0
          for m = 1, #lt do
            local a = lt[m]
            if cntL[a] + 1 == #OL[a] then add = add + 1 + accL[a]; pendDelta = pendDelta - 1 - accL[a] end
          end
          for m = 1, #rt do
            local b = rt[m]
            local sa = Rstraight[b]
            if sa == 0 then
              if not startedR[b] then
                add = add + 1 + totR[b] - accR[b] - (1 + WR[b][t])
                pendDelta = pendDelta - 1
              end
            else
              for _, q in ipairs(OL[sa]) do if not placed[q] then add = add + ILLEGAL end end
            end
          end
          local c2 = cost + add
          if c2 < best then
            placed[t] = true
            cur[depth] = t
            for m = 1, #lt do local a = lt[m]; cntL[a] = cntL[a] + 1 end
            local changedR = {}
            for m = 1, #rt do
              local b = rt[m]
              if not startedR[b] then startedR[b] = true; changedR[#changedR + 1] = b end
            end
            -- Unsettled lefts pay 1 + w for t now placed before their east.
            local accDelta = 0
            for a = 1, nL do
              local v = 1 + WL[a][t]
              accL[a] = accL[a] + v
              if Lstraight[a] == 0 and cntL[a] < #OL[a] then accDelta = accDelta + v end
            end
            for b = 1, nR do accR[b] = accR[b] + 1 + WR[b][t] end
            local pm2, Pt = pm, P[t]
            for j = 1, k do
              if not placed[j] then
                local x, y = Pt[j], P[j][t]
                pm2 = pm2 - (x < y and x or y)
              end
            end
            local pend2 = pend + pendDelta + accDelta
            if c2 + pm2 + pend2 < best then dfs(depth + 1, c2, pm2, pend2) end
            for a = 1, nL do accL[a] = accL[a] - 1 - WL[a][t] end
            for b = 1, nR do accR[b] = accR[b] - 1 - WR[b][t] end
            for m = 1, #changedR do startedR[changedR[m]] = false end
            for m = 1, #lt do local a = lt[m]; cntL[a] = cntL[a] - 1 end
            placed[t] = false
            if aborted then return end
          end
        end
      end
    end
    dfs(1, constant, pairMin, pendL + pendR)
    if bestOrder then
      for j = 1, k do
        local s = slots[bestOrder[j]]
        order[j] = s
        pos[s] = j
      end
    end
    return best, nodes, aborted
  end

  -- Channel router: link modes (trunk / collector / own) and track order for
  -- one channel, scored like contactCosts/lineCost (crossing 1000, illegal
  -- contact 1000000, 40 per track). Tracks live in stable slots; a mode change
  -- touches only the slots a link leaves and joins and is undone exactly. A
  -- router also keeps a live routing: try() moves items to new rows
  -- incrementally, repair() improves link modes inside the trial, undo()
  -- restores the routing exactly.
  local CROSSING, ILLEGAL, TRACK_COST = 1000, 1000000, 40
  local INF = math.huge

  -- A router for one channel: static structure built once, then
  -- route(yOf, quick, opts) for any rows of its items.
  local function newChannelRouter(channel)
    local quick, opts
    local links = channel.links
    local nlink = #links
    local Lidx, Ridx = {}, {}
    local Litem, Ritem = {}, {}
    local nL, nR = 0, 0
    local Ly, Ry, lL, lR, lStraight = {}, {}, {}, {}, {}
    local Lstraight, Rstraight = {}, {}
    for i = 1, nlink do
      local link = links[i]
      local a, b = Lidx[link.left], Ridx[link.right]
      if not a then
        nL = nL + 1; a = nL; Lidx[link.left] = a; Litem[a] = link.left
      end
      if not b then
        nR = nR + 1; b = nR; Ridx[link.right] = b; Ritem[b] = link.right
      end
      lL[i], lR[i] = a, b
    end
    local function setRows(yOf)
      for a = 1, nL do Ly[a], Lstraight[a] = yOf[Litem[a]], 0 end
      for b = 1, nR do Ry[b], Rstraight[b] = yOf[Ritem[b]], 0 end
      for i = 1, nlink do
        local a, b = lL[i], lR[i]
        local s = Ly[a] == Ry[b]
        lStraight[i] = s
        if s then Lstraight[a], Rstraight[b] = b, a end
      end
    end
    local Llinks, Rlinks = {}, {}
    for a = 1, nL do Llinks[a] = {} end
    for b = 1, nR do Rlinks[b] = {} end
    for i = 1, nlink do
      local t = Llinks[lL[i]]; t[#t + 1] = i
      t = Rlinks[lR[i]]; t[#t + 1] = i
    end

    -- Slots.
    local S = nlink
    local active, kind, owner, memN, mem, lo, hi = {}, {}, {}, {}, {}, {}, {}
    local srcC, tgtC, rowC = {}, {}, {}
    local wL, wR = {}, {}
    for a = 1, nL do wL[a] = {} end
    for b = 1, nR do wR[b] = {} end
    for t = 1, S do
      active[t], memN[t], mem[t] = false, 0, {}
      srcC[t], tgtC[t], rowC[t] = { n = 0, keys = {} }, { n = 0, keys = {} }, { n = 0, keys = {} }
    end
    local trunkSlot, collSlot = {}, {}
    local ownL, ownLN, ownR, ownRN = {}, {}, {}, {}
    for a = 1, nL do ownL[a], ownLN[a], trunkSlot[a] = {}, 0, 0 end
    for b = 1, nR do ownR[b], ownRN[b], collSlot[b] = {}, 0, 0 end
    local mode, trackOf = {}, {}
    local order, pos, k = {}, {}, 0

    local function listRemove(list, nArr, idx, t)
      local n = nArr[idx]
      for j = 1, n do
        if list[j] == t then
          list[j] = list[n]
          list[n] = nil
          nArr[idx] = n - 1
          return
        end
      end
    end
    -- Counted sets: counts in tab, live keys in list (tab.n of them).
    local function dec(tab, key)
      local v = tab[key] - 1
      if v == 0 then
        tab[key] = nil
        local keys, n = tab.keys, tab.n
        for j = 1, n do
          if keys[j] == key then keys[j] = keys[n]; keys[n] = nil; break end
        end
        tab.n = n - 1
      else
        tab[key] = v
      end
      return v
    end
    local function clearSet(tab)
      local keys = tab.keys
      for j = tab.n, 1, -1 do tab[keys[j]] = nil; keys[j] = nil end
      tab.n = 0
    end

    local function activate(t, m, own)
      active[t], kind[t], owner[t], memN[t] = true, m, own, 0
      lo[t], hi[t] = INF, -INF
      if m == 1 then trunkSlot[own] = t elseif m == 2 then collSlot[own] = t end
    end
    local function deactivate(t)
      active[t] = false
      local m = kind[t]
      if m == 1 and trunkSlot[owner[t]] == t then trunkSlot[owner[t]] = 0 end
      if m == 2 and collSlot[owner[t]] == t then collSlot[owner[t]] = 0 end
      -- Remove from order.
      local p = pos[t]
      for j = p, k - 1 do
        local u = order[j + 1]
        order[j] = u
        pos[u] = j
      end
      order[k] = nil
      k = k - 1
      pos[t] = nil
    end
    local function addLink(t, i)
      local a, b = lL[i], lR[i]
      local n = memN[t] + 1
      memN[t] = n
      mem[t][n] = i
      trackOf[i] = t
      -- Counted sets and own lists, inlined (hot path).
      local set = srcC[t]
      local v = (set[a] or 0) + 1
      set[a] = v
      if v == 1 then
        local c = set.n + 1
        set.n = c
        set.keys[c] = a
        c = ownLN[a] + 1
        ownL[a][c] = t
        ownLN[a] = c
      end
      set = tgtC[t]
      v = (set[b] or 0) + 1
      set[b] = v
      if v == 1 then
        local c = set.n + 1
        set.n = c
        set.keys[c] = b
        c = ownRN[b] + 1
        ownR[b][c] = t
        ownRN[b] = c
      end
      local ya, yb = Ly[a], Ry[b]
      set = rowC[t]
      for _ = 1, 2 do
        v = (set[ya] or 0) + 1
        set[ya] = v
        if v == 1 then
          local c = set.n + 1
          set.n = c
          set.keys[c] = ya
        end
        ya, yb = yb, ya
      end
      if ya < lo[t] then lo[t] = ya end
      if yb < lo[t] then lo[t] = yb end
      if ya > hi[t] then hi[t] = ya end
      if yb > hi[t] then hi[t] = yb end
    end
    local function removeLink(t, i)
      local a, b = lL[i], lR[i]
      local list, n = mem[t], memN[t]
      for j = 1, n do
        if list[j] == i then list[j] = list[n]; list[n] = nil; break end
      end
      n = n - 1
      memN[t] = n
      trackOf[i] = 0
      if dec(srcC[t], a) == 0 then listRemove(ownL[a], ownLN, a, t) end
      if dec(tgtC[t], b) == 0 then listRemove(ownR[b], ownRN, b, t) end
      local set, ya = rowC[t], Ly[a]
      for _ = 1, 2 do
        local v = set[ya] - 1
        if v == 0 then
          set[ya] = nil
          local keys, c = set.keys, set.n
          for j = 1, c do
            if keys[j] == ya then keys[j] = keys[c]; keys[c] = nil; break end
          end
          set.n = c - 1
        else
          set[ya] = v
        end
        ya = Ry[b]
      end
      local l, h = INF, -INF
      for j = 1, n do
        local m = list[j]
        local ya, yb = Ly[lL[m]], Ry[lR[m]]
        if ya < l then l = ya end
        if yb < l then l = yb end
        if ya > h then h = ya end
        if yb > h then h = yb end
      end
      lo[t], hi[t] = l, h
    end
    local function through(t, y)
      local list = mem[t]
      for j = 1, memN[t] do
        local i = list[j]
        if (Ly[lL[i]] - y) * (Ry[lR[i]] - y) < 0 then return true end
      end
      return false
    end
    -- Contact costs of every line against slot t.
    local function column(t)
      local src, tgt, rows, l, h = srcC[t], tgtC[t], rowC[t], lo[t], hi[t]
      -- Geometry: outside the span nothing, a junction row is illegal, any
      -- other row inside is a crossing.
      for a = 1, nL do
        local y = Ly[a]
        local c = 0
        if y >= l and y <= h then c = rows[y] and ILLEGAL or CROSSING end
        wL[a][t] = c
      end
      for b = 1, nR do
        local c = 0
        if Rstraight[b] == 0 then
          local y = Ry[b]
          if y >= l and y <= h then c = rows[y] and ILLEGAL or CROSSING end
        end
        wR[b][t] = c
      end
      -- Members (and a straight row's partner): legal unless flow runs past.
      local keys = src.keys
      for j = 1, src.n do
        local a = keys[j]
        wL[a][t] = through(t, Ly[a]) and ILLEGAL or 0
      end
      keys = tgt.keys
      for j = 1, tgt.n do
        local b = keys[j]
        local y = Ry[b]
        wR[b][t] = through(t, y) and ILLEGAL or 0
        local sa = Rstraight[b]
        if sa ~= 0 then wL[sa][t] = through(t, Ly[sa]) and ILLEGAL or 0 end
      end
    end

    -- Exact line costs for the current order.
    local function leftCost(a)
      local w = wL[a]
      if Lstraight[a] ~= 0 then
        local total = k + 1
        for j = 1, k do total = total + w[order[j]] end
        return total
      end
      local east, list = 0, ownL[a]
      for j = 1, ownLN[a] do
        local p = pos[list[j]]
        if p > east then east = p end
      end
      local total = east
      for j = 1, east - 1 do total = total + w[order[j]] end
      return total
    end
    local function rightCost(b)
      local sa = Rstraight[b]
      if sa ~= 0 then
        local total = 0
        local own, list = ownL[sa], ownR[b]
        for m = 1, ownLN[sa] do
          local p = pos[own[m]]
          for j = 1, ownRN[b] do
            if p > pos[list[j]] then total = total + ILLEGAL end
          end
        end
        return total
      end
      local west, list = k + 1, ownR[b]
      for j = 1, ownRN[b] do
        local p = pos[list[j]]
        if p < west then west = p end
      end
      local w, total = wR[b], k + 1 - west
      for j = west + 1, k do total = total + w[order[j]] end
      return total
    end
    local function totalCost()
      local total = 0
      for a = 1, nL do total = total + leftCost(a) end
      for b = 1, nR do total = total + rightCost(b) end
      return total
    end

    -- Swap delta of the tracks at i and i + 1: only lines owning one of
    -- them change, and only through those two tracks.
    local function leftDelta(a, x, y, i)
      local list, east, east2 = ownL[a], 0, 0
      for j = 1, ownLN[a] do
        local t = list[j]
        local p = pos[t]
        if p > east then east = p end
        if t == x then p = i + 1 elseif t == y then p = i end
        if p > east2 then east2 = p end
      end
      if east == east2 and east ~= i and east ~= i + 1 then return 0 end
      local w, d = wL[a], 0
      if i + 1 < east2 then d = d + 1 + w[x] end
      if i < east then d = d - 1 - w[x] end
      if i < east2 then d = d + 1 + w[y] end
      if i + 1 < east then d = d - 1 - w[y] end
      return d
    end
    local function rightDelta(b, x, y, i)
      local sa = Rstraight[b]
      if sa ~= 0 then
        local d = 0
        if (srcC[x][sa] or 0) > 0 and (tgtC[y][b] or 0) > 0 then d = d + ILLEGAL end
        if (srcC[y][sa] or 0) > 0 and (tgtC[x][b] or 0) > 0 then d = d - ILLEGAL end
        return d
      end
      local list, west, west2 = ownR[b], k + 1, k + 1
      for j = 1, ownRN[b] do
        local t = list[j]
        local p = pos[t]
        if p < west then west = p end
        if t == x then p = i + 1 elseif t == y then p = i end
        if p < west2 then west2 = p end
      end
      if west == west2 and west ~= i and west ~= i + 1 then return 0 end
      local w, d = wR[b], 0
      if i + 1 > west2 then d = d + 1 + w[x] end
      if i > west then d = d - 1 - w[x] end
      if i > west2 then d = d + 1 + w[y] end
      if i + 1 > west then d = d - 1 - w[y] end
      return d
    end
    local markL, markR, markStamp = {}, {}, 0
    local function swapDelta(i)
      local x, y = order[i], order[i + 1]
      markStamp = markStamp + 1
      local d = 0
      local t = x
      for _ = 1, 2 do
        local src, tgt = srcC[t], tgtC[t]
        local keys = src.keys
        for j = 1, src.n do
          local a = keys[j]
          local sb = Lstraight[a]
          if sb == 0 then
            if markL[a] ~= markStamp then markL[a] = markStamp; d = d + leftDelta(a, x, y, i) end
          elseif markR[sb] ~= markStamp then
            markR[sb] = markStamp; d = d + rightDelta(sb, x, y, i)
          end
        end
        keys = tgt.keys
        for j = 1, tgt.n do
          local b = keys[j]
          if markR[b] ~= markStamp then markR[b] = markStamp; d = d + rightDelta(b, x, y, i) end
        end
        t = y
      end
      return d
    end
    local function swap(i)
      local x, y = order[i], order[i + 1]
      order[i], order[i + 1] = y, x
      pos[x], pos[y] = i + 1, i
    end
    -- Adjacent sifting passes; returns the total change.
    local function sift(passes)
      local change = 0
      for _ = 1, passes do
        local improved = false
        for i = 1, k - 1 do
          local d = swapDelta(i)
          if d < 0 then swap(i); change = change + d; improved = true end
        end
        if not improved then break end
      end
      return change
    end
    -- Slide the track at p to its best place; returns the change.
    -- Move the track at p to its best place; returns the change. The cost of
    -- the track at every position comes from one pass over the lines (prefix
    -- sums for the lines it belongs to, a step for the others), not from
    -- walking it through the order. Ties keep p, then the nearest place east,
    -- then the nearest west (as a walk east and back would choose).
    local others, f, D, P = {}, {}, {}, {}
    local function slide(p)
      local t = order[p]
      for j = 1, p - 1 do others[j] = order[j] end
      for j = p + 1, k do others[j - 1] = order[j] end
      for q = 1, k + 1 do f[q], D[q] = 0, 0 end
      -- Position of track u among the others.
      local function at(u)
        local pu = pos[u]
        return pu > p and pu - 1 or pu
      end
      local src, tgt = srcC[t], tgtC[t]
      for a = 1, nL do
        if Lstraight[a] == 0 then
          local w, list, east = wL[a], ownL[a], 0
          for m = 1, ownLN[a] do
            local u = list[m]
            if u ~= t then
              local pu = at(u)
              if pu > east then east = pu end
            end
          end
          local wt = 1 + w[t]
          if (src[a] or 0) > 0 then
            -- East of its other tracks the line ends at t.
            local sum = 0
            P[0] = 0
            for j = 1, k - 1 do sum = sum + 1 + w[others[j]]; P[j] = sum end
            for q = 1, k do
              if q > east then f[q] = f[q] + P[q - 1] else f[q] = f[q] + P[east - 1] + wt end
            end
          elseif east > 0 then
            D[1] = D[1] + wt
            D[east + 1] = D[east + 1] - wt
          end
        end
      end
      for b = 1, nR do
        local sa = Rstraight[b]
        if sa == 0 then
          local w, list, west = wR[b], ownR[b], k
          for m = 1, ownRN[b] do
            local u = list[m]
            if u ~= t then
              local pu = at(u)
              if pu < west then west = pu end
            end
          end
          local wt = 1 + w[t]
          if (tgt[b] or 0) > 0 then
            -- West of its other tracks the line starts at t.
            local sum = 0
            P[k] = 0
            for j = k - 1, 1, -1 do sum = sum + 1 + w[others[j]]; P[j] = sum end
            local after = P[west + 1] or 0
            for q = 1, k do
              if q <= west then f[q] = f[q] + P[q] else f[q] = f[q] + after + wt end
            end
          elseif west < k then
            D[west + 1] = D[west + 1] + wt
          end
        else
          -- Straight row: every own track of sa must stay east of b's.
          if (src[sa] or 0) > 0 then
            local list = ownR[b]
            for m = 1, ownRN[b] do
              local u = list[m]
              if u ~= t then local j = at(u); D[j + 1] = D[j + 1] + ILLEGAL end
            end
          end
          if (tgt[b] or 0) > 0 then
            local list = ownL[sa]
            for m = 1, ownLN[sa] do
              local u = list[m]
              if u ~= t then
                local j = at(u)
                D[1] = D[1] + ILLEGAL
                D[j + 1] = D[j + 1] - ILLEGAL
              end
            end
          end
        end
      end
      local run = 0
      for q = 1, k do run = run + D[q]; f[q] = f[q] + run end
      local base, bestD, bestP = f[p], 0, p
      for q = p + 1, k do
        local d = f[q] - base
        if d < bestD then bestD, bestP = d, q end
      end
      for q = p - 1, 1, -1 do
        local d = f[q] - base
        if d < bestD then bestD, bestP = d, q end
      end
      if bestP ~= p then
        local n = 0
        for j = 1, k - 1 do
          if n + 1 == bestP then n = n + 1; order[n] = t; pos[t] = n end
          n = n + 1
          local u = others[j]
          order[n] = u
          pos[u] = n
        end
        if bestP == k then order[k] = t; pos[t] = k end
      end
      for j = 1, k - 1 do others[j] = nil end
      return bestD
    end

    local function startBefore(x, y)
      local kx = kind[x] == 2 and 1 or 0
      local ky = kind[y] == 2 and 1 or 0
      if kx ~= ky then return kx < ky end
      local sx, sy = hi[x] - lo[x], hi[y] - lo[y]
      if sx ~= sy then return sx < sy end
      if lo[x] ~= lo[y] then return lo[x] < lo[y] end
      return x < y
    end

    -- Fresh state for the current modes, slots in link order.
    local function rebuild()
      for t = 1, S do
        active[t], memN[t] = false, 0
        local m = mem[t]; for j = #m, 1, -1 do m[j] = nil end
        clearSet(srcC[t]); clearSet(tgtC[t]); clearSet(rowC[t])
      end
      for a = 1, nL do trunkSlot[a] = 0; ownLN[a] = 0; local l = ownL[a]; for j = #l, 1, -1 do l[j] = nil end end
      for b = 1, nR do collSlot[b] = 0; ownRN[b] = 0; local l = ownR[b]; for j = #l, 1, -1 do l[j] = nil end end
      for j = #order, 1, -1 do order[j] = nil end
      k = 0
      local next = 0
      for i = 1, nlink do
        if lStraight[i] then
          trackOf[i] = 0
        else
          local a, b, m = lL[i], lR[i], mode[i]
          local t = m == 1 and trunkSlot[a] or m == 2 and collSlot[b] or 0
          if t == 0 then
            next = next + 1
            t = next
            activate(t, m, m == 1 and a or m == 2 and b or i)
            k = k + 1
            order[k] = t
          end
          addLink(t, i)
        end
      end
      for t = 1, k do column(t) end
      table.sort(order, startBefore)
      for j = 1, k do pos[order[j]] = j end
    end

    local function freeSlot()
      for t = 1, S do if not active[t] then return t end end
    end
    -- Move link i to mode m, keeping the order; a new track is appended and
    -- slid into place by the caller. Returns the undo record.
    local function move(i, m)
      local from = trackOf[i]
      local rec = { i = i, mode = mode[i], from = from, fromKind = kind[from], fromOwner = owner[from] }
      removeLink(from, i)
      if memN[from] == 0 then deactivate(from) end
      local a, b = lL[i], lR[i]
      local t = m == 1 and trunkSlot[a] or m == 2 and collSlot[b] or 0
      local fresh = false
      if t == 0 then
        t = freeSlot()
        activate(t, m, m == 1 and a or m == 2 and b or i)
        k = k + 1
        order[k] = t
        pos[t] = k
        fresh = true
      end
      addLink(t, i)
      mode[i] = m
      rec.to, rec.fresh = t, fresh
      return rec
    end
    local function unmove(rec)
      local i, t = rec.i, rec.to
      removeLink(t, i)
      if memN[t] == 0 then deactivate(t) end
      local from = rec.from
      if not active[from] then
        activate(from, rec.fromKind, rec.fromOwner)
        k = k + 1
        order[k] = from
        pos[from] = k
      end
      addLink(from, i)
      mode[i] = rec.mode
    end

    -- Try a set of mode changes. Keeps them and returns the new value when it
    -- beats `best`; otherwise restores everything and returns nil.
    local trials = 0
    local modeLog = nil -- when set, accepted mode moves are appended here
    -- Contact columns saved before a trial; a rejected trial restores every
    -- slot it touched exactly, so their columns come back from here.
    local savedL, savedR, savedList, savedMark = {}, {}, {}, {}
    local function saveColumn(t)
      if not t or t == 0 or savedMark[t] then return end
      savedMark[t] = true
      savedList[#savedList + 1] = t
      local sl, sr = savedL[t], savedR[t]
      if not sl then sl, sr = {}, {}; savedL[t], savedR[t] = sl, sr end
      for a = 1, nL do sl[a] = wL[a][t] end
      for b = 1, nR do sr[b] = wR[b][t] end
    end
    local function try(changes, best)
      trials = trials + 1
      liveWork = liveWork + 1
      local savedOrder = {}
      for j = 1, k do savedOrder[j] = order[j] end
      for j = #savedList, 1, -1 do savedMark[savedList[j]] = nil; savedList[j] = nil end
      for _, ch in ipairs(changes) do
        local i, m = ch[1], ch[2]
        if not lStraight[i] and mode[i] ~= m then
          saveColumn(trackOf[i])
          saveColumn(m == 1 and trunkSlot[lL[i]] or m == 2 and collSlot[lR[i]] or 0)
        end
      end
      local recs = {}
      for _, ch in ipairs(changes) do
        local i, m = ch[1], ch[2]
        if not lStraight[i] and mode[i] ~= m then recs[#recs + 1] = move(i, m) end
      end
      if #recs == 0 then return nil end
      local touched = {}
      for _, r in ipairs(recs) do
        if active[r.from] then touched[r.from] = true end
        touched[r.to] = true
      end
      for t in pairs(touched) do if active[t] then column(t) end end
      for _, r in ipairs(recs) do
        if r.fresh and active[r.to] then slide(pos[r.to]) end
      end
      local v = totalCost() + k * TRACK_COST
      if v >= best and not opts.noTrySift then
        -- One polishing pass before giving up (not inside trial repairs).
        v = v + sift(1)
      end
      if v < best then
        if modeLog then
          for _, r in ipairs(recs) do modeLog[#modeLog + 1] = r end
        end
        return v
      end
      for j = #recs, 1, -1 do unmove(recs[j]) end
      for j = #order, 1, -1 do order[j] = nil end
      for j = 1, #savedOrder do order[j] = savedOrder[j]; pos[savedOrder[j]] = j end
      k = #savedOrder
      for j = 1, #savedList do
        local t = savedList[j]
        if active[t] then
          local sl, sr = savedL[t], savedR[t]
          for a = 1, nL do wL[a][t] = sl[a] end
          for b = 1, nR do wR[b][t] = sr[b] end
        end
      end
      return nil
    end

    local function involved(floor)
      floor = floor or 1
      local mark, list = {}, {}
      local function addTrack(t)
        local tl, n0 = mem[t], #list
        for j = 1, memN[t] do
          local i = tl[j]
          if not mark[i] then mark[i] = true; list[#list + 1] = i end
        end
        -- Member lists change order on undo; sort for a repeatable search.
        for j = n0 + 2, #list do
          local v, q = list[j], j - 1
          while q > n0 and list[q] > v do list[q + 1] = list[q]; q = q - 1 end
          list[q + 1] = v
        end
      end
      local function addLinks(ll)
        for j = 1, #ll do
          local i = ll[j]
          if not lStraight[i] and not mark[i] then mark[i] = true; list[#list + 1] = i end
        end
      end
      for a = 1, nL do
        local east = Lstraight[a] ~= 0 and k + 1 or 0
        for m = 1, ownLN[a] do local p = pos[ownL[a][m]]; if p > east then east = p end end
        local paid = false
        for j = 1, east - 1 do
          local t = order[j]
          if wL[a][t] >= floor then addTrack(t); paid = true end
        end
        if paid then addLinks(Llinks[a]) end
      end
      for b = 1, nR do
        local paid = false
        if Rstraight[b] ~= 0 then
          if rightCost(b) >= ILLEGAL then
            local sa = Rstraight[b]
            for m = 1, ownLN[sa] do addTrack(ownL[sa][m]) end
            paid = true
          end
        else
          local west = k + 1
          for m = 1, ownRN[b] do local p = pos[ownR[b][m]]; if p < west then west = p end end
          for j = west + 1, k do
            local t = order[j]
            if wR[b][t] >= floor then addTrack(t); paid = true end
          end
        end
        if paid then addLinks(Rlinks[b]) end
      end
      return list
    end

    local function improve(best)
      local rounds, floor = quick and (opts.rounds or 2) or 4, 1
      -- Illegal-only repair: candidates in illegal contacts, stop once the
      -- illegal count is down to target.
      local target = opts.illegalTarget
      if target then floor = ILLEGAL end
      local function reached() return target and math.floor(best / ILLEGAL) <= target end
      for _ = 1, rounds do
        if best < CROSSING or reached() then break end
        local improved = false
        local cands = involved(floor)
        local focus = opts.focus
        if focus then
          local kept = {}
          for _, i in ipairs(cands) do
            if focus[Litem[lL[i]]] or focus[Ritem[lR[i]]] then kept[#kept + 1] = i end
          end
          cands = kept
        end
        for _, i in ipairs(cands) do
          for m = 1, 3 do
            if m ~= mode[i] and not reached() then
              local v = try({ { i, m } }, best)
              if v then best, improved = v, true end
            end
          end
        end
        if reached() then break end
        local seenL, seenR, groups = {}, {}, {}
        for _, i in ipairs(cands) do
          local a, b = lL[i], lR[i]
          if not seenL[a] then
            seenL[a] = true
            groups[#groups + 1] = { Llinks[a], 1 }
            groups[#groups + 1] = { Llinks[a], 3 }
          end
          if not seenR[b] then
            seenR[b] = true
            groups[#groups + 1] = { Rlinks[b], 2 }
          end
        end
        for _, g in ipairs(groups) do
          local changes = {}
          for _, i in ipairs(g[1]) do changes[#changes + 1] = { i, g[2] } end
          local v = try(changes, best)
          if v then best, improved = v, true end
        end
        if not improved then break end
      end
      return best
    end

    local function fresh()
      rebuild()
      local v = totalCost()
      v = v + sift(4)
      return v + k * TRACK_COST
    end

    -- Snapshot: modes plus the order as each track's first link.
    local function snapshot(value)
      local snap = { value = value, modes = {}, reps = {} }
      for i = 1, nlink do snap.modes[i] = mode[i] end
      for j = 1, k do
        local t, rep = order[j], INF
        local list = mem[t]
        for m = 1, memN[t] do if list[m] < rep then rep = list[m] end end
        snap.reps[j] = rep
      end
      return snap
    end
    -- Rebuild for snap's modes and put tracks in snap's order; tracks the
    -- snapshot doesn't know (rows changed) go last.
    local function restore(snap)
      for i = 1, nlink do mode[i] = snap.modes[i] end
      rebuild()
      local seen, n = {}, 0
      for j = 1, #snap.reps do
        local t = trackOf[snap.reps[j]]
        if t and t ~= 0 and not seen[t] then
          seen[t] = true
          n = n + 1
          order[n] = t
        end
      end
      local rest = {}
      for t = 1, S do if active[t] and not seen[t] then rest[#rest + 1] = t end end
      table.sort(rest, startBefore)
      for _, t in ipairs(rest) do n = n + 1; order[n] = t end
      for j = 1, k do pos[order[j]] = j end
    end

    local function route(yOf, quick_, opts_)
    quick, opts = quick_, opts_ or {}
    setRows(yOf)
    trials = 0
    local warm = opts.warm
    local value
    if warm then
      restore(warm)
      value = totalCost()
      value = value + sift(4) + k * TRACK_COST
      value = improve(value)
      value = value - k * TRACK_COST
    else
      local bestSnap, current = nil, false
      for start = 1, quick and 1 or 2 do
        for i = 1, nlink do
          mode[i] = (start == 1 and #Rlinks[lR[i]] >= 2) and 2 or 1
        end
        local found = improve(fresh())
        current = false
        if not bestSnap or found < bestSnap.value then bestSnap, current = snapshot(found), true end
        if found < CROSSING then break end
      end
      if not current then restore(bestSnap) end
      value = totalCost()
    end
    if not quick then
      for _ = 1, 4 do
        local d = 0
        for p = 1, k do d = d + slide(p) end
        d = d + sift(4)
        value = value + d
        if d >= 0 then break end
      end
    end
    local nodes, aborted = 0, false
    if not quick and k > 1 then
      value, nodes, aborted = exactTrackOrder(k, order, pos, nL, nR, Lstraight, Rstraight, ownL, ownLN, ownR, ownRN,
        wL, wR, srcC, value, opts.nodeCap)
    end
    value = value + k * TRACK_COST
    -- Key: canonical track ids by first use in link order.
    local canon, nextId = {}, 0
    local letters = {}
    local LET = { "t", "c", "o" }
    for i = 1, nlink do
      letters[i] = LET[mode[i]] or "t"
      local t = trackOf[i]
      if t and t ~= 0 and not canon[t] then nextId = nextId + 1; canon[t] = nextId end
    end
    local ids = {}
    for j = 1, k do ids[j] = canon[order[j]] end
    return value, table.concat(letters) .. ":" .. table.concat(ids, ","), trials, nodes, aborted, snapshot(value)
    end

    ---------------------------------------------------------------------
    -- Live state: the router keeps the routing of the channel's accepted
    -- rows; a trial changes some items' rows incrementally and is undone.
    ---------------------------------------------------------------------
    local liveValue = 0
    local function rowLeft(a)
      local y, sb, w = Ly[a], Lstraight[a], wL[a]
      for j = 1, k do
        local t = order[j]
        local c = 0
        if (srcC[t][a] or 0) > 0 or (sb ~= 0 and (tgtC[t][sb] or 0) > 0) then
          if through(t, y) then c = ILLEGAL end
        elseif (rowC[t][y] or 0) > 0 then
          c = ILLEGAL
        elseif y > lo[t] and y < hi[t] then
          c = CROSSING
        end
        w[t] = c
      end
    end
    local function rowRight(b)
      local y, w = Ry[b], wR[b]
      local straight = Rstraight[b] ~= 0
      for j = 1, k do
        local t = order[j]
        local c = 0
        if (tgtC[t][b] or 0) > 0 then
          if through(t, y) then c = ILLEGAL end
        elseif straight then
          c = 0
        elseif (rowC[t][y] or 0) > 0 then
          c = ILLEGAL
        elseif y > lo[t] and y < hi[t] then
          c = CROSSING
        end
        w[t] = c
      end
    end
    local function orderReps()
      local reps = {}
      for j = 1, k do
        local t, rep = order[j], INF
        local list = mem[t]
        for m = 1, memN[t] do if list[m] < rep then rep = list[m] end end
        reps[j] = rep
      end
      return reps
    end
    local prevSlot = {}
    -- Move items to new rows all at once (a swap passes two items through
    -- each other's rows): detach their links, set rows, redo straight links,
    -- reattach. Returns the fresh slots.
    local function applyRows(changes)
      local touched, freshSlots, dirtyL, dirtyR = {}, {}, {}, {}
      local lists = {}
      for j = 1, #changes, 2 do
        local item = changes[j]
        local a, b = Lidx[item], Ridx[item]
        local list = a and Llinks[a] or Rlinks[b]
        lists[#lists + 1] = list
        for m = 1, #list do
          local i = list[m]
          local t = trackOf[i] or 0
          prevSlot[i] = t
          if t ~= 0 then
            touched[t] = true
            removeLink(t, i)
          end
          -- Straight relations through this link end now.
          if lStraight[i] then
            local la, rb = lL[i], lR[i]
            Lstraight[la], Rstraight[rb] = 0, 0
            dirtyL[la], dirtyR[rb] = true, true
            lStraight[i] = false
          end
        end
      end
      for j = 1, #changes, 2 do
        local item, y = changes[j], changes[j + 1]
        local a = Lidx[item]
        if a then Ly[a] = y; dirtyL[a] = true else local b = Ridx[item]; Ry[b] = y; dirtyR[b] = true end
      end
      for _, list in ipairs(lists) do
        for m = 1, #list do
          local i = list[m]
          local la, rb = lL[i], lR[i]
          if Ly[la] == Ry[rb] then
            lStraight[i] = true
            Lstraight[la], Rstraight[rb] = rb, la
            dirtyL[la], dirtyR[rb] = true, true
          end
        end
      end
      for _, list in ipairs(lists) do
        for m = 1, #list do
          local i = list[m]
          if not lStraight[i] and (trackOf[i] or 0) == 0 then
            local t = prevSlot[i]
            if t == 0 then
              local md = mode[i]
              t = md == 1 and trunkSlot[lL[i]] or md == 2 and collSlot[lR[i]] or 0
              if t == 0 then
                t = freeSlot()
                activate(t, md, md == 1 and lL[i] or md == 2 and lR[i] or i)
                k = k + 1
                order[k] = t
                pos[t] = k
                freshSlots[#freshSlots + 1] = t
              end
            end
            addLink(t, i)
            touched[t] = true
          end
        end
      end
      for t in pairs(touched) do
        if active[t] and memN[t] == 0 then deactivate(t) end
      end
      for t in pairs(touched) do
        if active[t] then column(t) end
      end
      for a in pairs(dirtyL) do rowLeft(a) end
      for b in pairs(dirtyR) do rowRight(b) end
      return freshSlots
    end
    local saved = nil
    local function liveTry(changes, siftPasses, limit)
      liveWork = liveWork + 3
      -- changes: item, y, item, y, ...
      local back = {}
      for j = 1, #changes, 2 do
        local item = changes[j]
        local a = Lidx[item]
        back[j] = item
        back[j + 1] = a and Ly[a] or Ry[Ridx[item]]
      end
      saved = { reps = orderReps(), back = back, value = liveValue, log = {} }
      local freshSlots = applyRows(changes)
      for _, t in ipairs(freshSlots) do
        if active[t] then slide(pos[t]) end
      end
      local v = totalCost()
      if limit and v + k * TRACK_COST >= limit then return v + k * TRACK_COST end
      v = v + sift(siftPasses or 2)
      return v + k * TRACK_COST
    end
    local function liveUndo()
      local log = saved.log
      if #log > 0 then
        local touched = {}
        for j = #log, 1, -1 do
          local r = log[j]
          unmove(r)
          touched[r.from], touched[r.to] = true, true
        end
        for t in pairs(touched) do if active[t] then column(t) end end
      end
      applyRows(saved.back)
      local seen, n = {}, 0
      for j = 1, #saved.reps do
        local t = trackOf[saved.reps[j]]
        if t and t ~= 0 and not seen[t] then
          seen[t] = true
          n = n + 1
          order[n] = t
        end
      end
      for t = 1, S do
        if active[t] and not seen[t] then n = n + 1; order[n] = t end
      end
      for j = 1, k do pos[order[j]] = j end
      liveValue = saved.value
    end
    local function liveInit(yOf, rounds)
      local v = route(yOf, true, { rounds = rounds })
      liveValue = v
      return v
    end
    -- Keep the trial just made.
    local function liveKeep(v)
      liveValue = v
    end
    -- Mode repair inside a trial (undone by liveUndo). v: the trial's value.
    local function liveRepair(rounds, focus, v, extra)
      quick, opts = true, { rounds = rounds, focus = focus, noTrySift = true }
      if extra then for key, val in pairs(extra) do opts[key] = val end end
      modeLog = saved.log
      local best = improve(v)
      modeLog = nil
      return best
    end
    local function liveSnapshot()
      return snapshot(liveValue)
    end
    -- Items at the ends of the links in illegal contacts.
    local function liveIllegalItems(set)
      for _, i in ipairs(involved(ILLEGAL)) do
        set[Litem[lL[i]]], set[Ritem[lR[i]]] = true, true
      end
      return set
    end
    local function liveTracks()
      return k
    end
    return { route = route, init = liveInit, try = liveTry, undo = liveUndo, keep = liveKeep, repair = liveRepair,
      snapshot = liveSnapshot, illegalItems = liveIllegalItems, tracks = liveTracks }
  end

  -- Row search scored by real channel routings. Every channel keeps a live
  -- routing; moving an object re-routes only the channels it touches,
  -- incrementally, and is undone exactly unless it is kept. Each object tries
  -- the rows near its neighbours (or a swap with the single object there):
  -- first every candidate is routed without link-mode repair, counting each
  -- new illegal contact as about one crossing; then only candidates that can
  -- still beat the best so far are repaired and scored exactly. The score adds
  -- the vertical pipe span and the number of rows to the routing cost.
  -- Objects with the most links go first; the search stops after
  -- LIVE_PASSES passes, a pass without a kept move, or LIVE_BUDGET work
  -- (about 50 ms here on the largest trees), keeping the best rows so far.
  local LIVE_PASSES = 3
  local INIT_ROUNDS = 2 -- mode-search rounds of the starting routings
  local TRIAL_SIFT = 2 -- track-order sifting passes after a trial move
  local SIFT_SKIP = 3000 -- no sifting when a trial is this much worse
  local REPAIR_MARGIN = 1500 -- repair trials that come this close
  local SKIPILL = 3 -- repair rarely clears this many new illegal contacts
  local ILLEGAL_GUESS = 1000 -- a repaired illegal contact, about one crossing
  local SLACK = 1000 -- repair candidates whose guess is this close to the best
  local WINDOW = 4 -- candidate rows: within this of the neighbours' rows
  local SPAN_WEIGHT = 6 -- per row of vertical pipe span per edge
  local ROW_WEIGHT = 30 -- per used row
  local FINAL_NODES = 500 -- branch-and-bound cap of the final track orders
  local LIVE_BUDGET = 2500 -- routing work (see liveWork) after which the search stops
  local CLEAR_ROUNDS = 2 -- repair rounds while clearing a left illegal contact
  local CLEAR_TRIES = 6 -- clearing moves repaired, best unrepaired first
  local FIT_BUDGET = 1000 -- extra work for rows too large for the screen

  -- fit (optional): need(k), the screen width of a channel with k tracks at
  -- the smallest scale, and the costs of overflowing the screen there by a
  -- total channel width (widthCost) or a row count (heightCost). budget:
  -- routing work for the main passes (default LIVE_BUDGET).
  liveRefine = function(g, s, fit, budget)
    local columns, channels = g.columns, s.channels
    local cells = {}
    for c = 0, columns - 1 do cells[c] = {} end
    for _, object in ipairs(s.objects) do place(cells, object, object.row) end
    local yOf, objCells = {}, {}
    for _, object in ipairs(s.objects) do
      local list = {}
      for _, item in pairs(object.cells) do list[#list + 1] = item end
      objCells[object] = list
    end
    local function sync(object)
      local list, r = objCells[object], object.row
      for j = 1, #list do yOf[list[j]] = r end
    end
    for _, object in ipairs(s.objects) do sync(object) end
    for c = 0, columns - 2 do
      local items, seen = {}, {}
      for _, link in ipairs(channels[c].links) do
        for _, item in ipairs({ link.left, link.right }) do
          if not seen[item] then seen[item] = true; items[#items + 1] = item end
        end
      end
      channels[c].items = items
    end

    local function spanOf(c)
      local sum = 0
      for _, link in ipairs(channels[c].links) do
        local d = yOf[link.left] - yOf[link.right]
        sum = sum + (d < 0 and -d or d) * #link.edges
      end
      return SPAN_WEIGHT * sum
    end
    -- cost[c]: routing value plus span of channel c's kept routing.
    local routers, cost, cache, rawCache, total = {}, {}, {}, {}, 0
    local routed = 0
    for c = 0, columns - 2 do
      routers[c] = newChannelRouter(channels[c])
      cost[c] = routers[c].init(yOf, INIT_ROUNDS) + spanOf(c)
      cache[c], rawCache[c] = {}, {}
      total = total + cost[c]
      routed = routed + 1
    end
    -- Screen fit: channel widths at the smallest scale against the screen.
    local need = fit and fit.need or function() return 0 end
    local fitOn, fitWidth = false, true
    local function widthCost(sum) return fitOn and fitWidth and fit.widthCost(sum) or 0 end
    local function heightCost(rows) return fitOn and fit.heightCost(rows) or 0 end
    local kOf, needSum = {}, 0
    for c = 0, columns - 2 do
      kOf[c] = routers[c].tracks()
      needSum = needSum + need(kOf[c])
    end
    -- The width cost change when channels change their track counts.
    local function widthDelta(dNeed)
      if dNeed == 0 then return 0 end
      return widthCost(needSum + dNeed) - widthCost(needSum)
    end
    -- After a kept routing.
    local function setCost(c, v)
      total = total + v - cost[c]
      cost[c], cache[c], rawCache[c] = v, {}, {}
      local k = routers[c].tracks()
      needSum = needSum + need(k) - need(kOf[c])
      kOf[c] = k
    end

    -- Items of each object in each channel, for live row changes.
    local objItems = {}
    for c = 0, columns - 2 do
      local map = {}
      for _, item in ipairs(channels[c].items) do
        local list = map[item.object]
        if not list then list = {}; map[item.object] = list end
        list[#list + 1] = item
      end
      objItems[c] = map
    end
    local function changesFor(c, a, b)
      local changes, n, map = {}, 0, objItems[c]
      local list = map[a]
      for pass = 1, 2 do
        if list then
          for j = 1, #list do
            local item = list[j]
            changes[n + 1], changes[n + 2] = item, yOf[item]
            n = n + 2
          end
        end
        list = b and map[b]
      end
      return changes
    end
    -- Routing depends only on the rank order of a channel's item rows.
    local keyRows, keyDistinct, keyRank = {}, {}, {}
    local function patternKey(c)
      local items = channels[c].items
      local n, m = #items, 0
      for i = 1, n do
        local r = yOf[items[i]]
        keyRows[i] = r
        if not keyRank[r] then keyRank[r] = true; m = m + 1; keyDistinct[m] = r end
      end
      for j = #keyDistinct, m + 1, -1 do keyDistinct[j] = nil end
      table.sort(keyDistinct)
      for j = 1, m do keyRank[keyDistinct[j]] = j end
      for i = 1, n do keyRows[i] = keyRank[keyRows[i]] end
      for j = 1, m do keyRank[keyDistinct[j]] = nil end
      for i = #keyRows, n + 1, -1 do keyRows[i] = nil end
      return table.concat(keyRows, ",")
    end
    local function siftLimit(c, sp)
      return cost[c] - sp + SIFT_SKIP
    end
    -- New illegal contacts of a trial value and whether to repair it.
    local function wantsRepair(c, v, sp)
      local n = floor(v / ILLEGAL) - floor(cost[c] / ILLEGAL)
      if n > 0 then return n < SKIPILL, n end
      local d = v + sp - cost[c]
      return d > 0 and d < REPAIR_MARGIN, 0
    end
    local function touchedBy(a, b)
      local touched = {}
      local list = a.channelList
      for j = 1, #list do touched[list[j]] = true end
      if b then
        list = b.channelList
        for j = 1, #list do touched[list[j]] = true end
      end
      return touched
    end
    -- Unrepaired trial: estimated delta, whether it is exact, and the fresh
    -- per-channel results (exact channels only).
    local function rawTrial(a, b)
      local delta, exact, fresh, dNeed = 0, true, {}, 0
      for c in pairs(touchedBy(a, b)) do
        local key = patternKey(c)
        local sp = spanOf(c)
        local hit = cache[c][key]
        if hit then
          fresh[c] = { hit[1] + sp, hit[2], sp }
          delta = delta + hit[1] + sp - cost[c]
          dNeed = dNeed + need(hit[3]) - need(kOf[c])
        else
          local raw = rawCache[c][key]
          local v, k
          if raw then
            v, k = raw[1], raw[2]
          else
            local router = routers[c]
            v = router.try(changesFor(c, a, b), TRIAL_SIFT, siftLimit(c, sp))
            k = router.tracks()
            router.undo()
            routed = routed + 1
            if wantsRepair(c, v, sp) then rawCache[c][key] = { v, k } else cache[c][key] = { v, false, k } end
          end
          dNeed = dNeed + need(k) - need(kOf[c])
          local want, n = wantsRepair(c, v, sp)
          if want then
            exact = false
            v = v - n * ILLEGAL + n * ILLEGAL_GUESS
          else
            fresh[c] = { v + sp, false, sp }
          end
          delta = delta + v + sp - cost[c]
        end
      end
      return delta + widthDelta(dNeed), exact, fresh
    end
    -- Repaired trial: exact delta and fresh results. A repair is recorded so
    -- the kept move can replay it.
    local evaluations = 0
    local function trial(a, b)
      local delta, fresh, dNeed = 0, {}, 0
      for c in pairs(touchedBy(a, b)) do
        local key = patternKey(c)
        local hit = cache[c][key]
        local sp = spanOf(c)
        if not hit then
          local router = routers[c]
          local changes = changesFor(c, a, b)
          local v = router.try(changes, TRIAL_SIFT, siftLimit(c, sp))
          local repaired = false
          local base = floor(cost[c] / ILLEGAL)
          local n = floor(v / ILLEGAL) - base
          local d = v + sp - cost[c]
          if (n > 0 and n < SKIPILL) or (n <= 0 and d > 0 and d < REPAIR_MARGIN) then
            local focus = {}
            for j = 1, #changes, 2 do focus[changes[j]] = true end
            local second = true
            if n > 0 then
              -- Clear the new illegal contacts first; a full repair only if
              -- the trial is then close.
              v = router.repair(1, focus, v, { illegalTarget = base })
              d = v + sp - cost[c]
              second = d > 0 and d < REPAIR_MARGIN
            end
            if second then v = router.repair(1, focus, v) end
            repaired = { focus = focus, illegalFirst = n > 0, target = base, second = second }
          end
          local k = router.tracks()
          router.undo()
          routed = routed + 1
          hit = { v, repaired, k }
          cache[c][key] = hit
        end
        fresh[c] = { hit[1] + sp, hit[2], sp }
        delta = delta + hit[1] + sp - cost[c]
        dNeed = dNeed + need(hit[3]) - need(kOf[c])
      end
      evaluations = evaluations + 1
      return delta + widthDelta(dNeed), fresh
    end

    local rowsUsed, rowCount = 0, 0
    local rowFill = {}
    for _, object in ipairs(s.objects) do
      rowsUsed = math.max(rowsUsed, object.row + 1)
      if not rowFill[object.row] then rowCount = rowCount + 1 end
      rowFill[object.row] = (rowFill[object.row] or 0) + 1
    end
    -- Cost change of the used rows when an object moves from -> r.
    local function rowDelta(from, r)
      local d = 0
      if (rowFill[from] or 0) == 1 then d = d - 1 end
      if (rowFill[r] or 0) == 0 then d = d + 1 end
      if d == 0 then return 0 end
      return ROW_WEIGHT * d + heightCost(rowCount + d) - heightCost(rowCount)
    end
    -- Neighbours: objects joined to an object by a link, once per link.
    local neighbours = {}
    for _, object in ipairs(s.objects) do neighbours[object] = {} end
    for c = 0, columns - 2 do
      for _, link in ipairs(channels[c].links) do
        local a, b = link.left.object, link.right.object
        if a ~= b then
          local la, lb = neighbours[a], neighbours[b]
          la[#la + 1] = b
          lb[#lb + 1] = a
        end
      end
    end
    -- Best-connected objects first.
    local visit, index = {}, {}
    for i, object in ipairs(s.objects) do visit[i], index[object] = object, i end
    table.sort(visit, function(a, b)
      local da, db = #neighbours[a], #neighbours[b]
      if da ~= db then return da > db end
      return index[a] < index[b]
    end)

    -- The best move of object to a row in rlo..rhi (or a swap with the single
    -- object there): delta, row, fresh results, swapped object. Estimated
    -- candidates are repaired only when they can still win, unless exactAll.
    local function bestMove(object, rlo, rhi, exactAll)
      -- exactAll: the exact scoring function for every candidate.
      local from = object.row
      local bestDelta, bestRow, bestFresh, bestSwap = -0.5, nil, nil, nil
      -- Score candidate (r, other) with fn, then put everything back.
      local function evaluate(r, other, fn)
        local delta, x, y
        if not other then
          lift(cells, object); place(cells, object, r); sync(object)
          delta, x, y = fn(object)
          delta = delta + rowDelta(from, r)
          lift(cells, object); place(cells, object, from); sync(object)
        else
          lift(cells, object); lift(cells, other)
          place(cells, object, r); place(cells, other, from); sync(object); sync(other)
          delta, x, y = fn(object, other)
          lift(cells, object); lift(cells, other)
          place(cells, other, r); place(cells, object, from); sync(object); sync(other)
        end
        return delta, x, y
      end
      local pending = {}
      for r = rlo, rhi do
        if r ~= from then
          local other, single = nil, true
          for c = object.lo, object.hi do
            local owner = cells[c][r]
            if owner and owner ~= object then
              if other and other ~= owner then single = false end
              other = owner
            end
          end
          local ok = not other
          if other and single and #other.channelList > 0 then
            lift(cells, object); lift(cells, other)
            ok = not occupied(cells, object, r) and not occupied(cells, other, from)
            place(cells, other, r); place(cells, object, from)
          end
          if ok and exactAll then
            local delta, fresh = evaluate(r, other, exactAll)
            if delta < bestDelta then bestDelta, bestRow, bestFresh, bestSwap = delta, r, fresh, other end
          elseif ok then
            local guess, exact, fresh = evaluate(r, other, rawTrial)
            if exact then
              if guess < bestDelta then bestDelta, bestRow, bestFresh, bestSwap = guess, r, fresh, other end
            else
              pending[#pending + 1] = { guess, r, other }
            end
          end
        end
      end
      table.sort(pending, function(p, q) return p[1] < q[1] end)
      for _, p in ipairs(pending) do
        if p[1] - SLACK >= bestDelta then break end
        local delta, fresh = evaluate(p[2], p[3], trial)
        if delta < bestDelta then bestDelta, bestRow, bestFresh, bestSwap = delta, p[2], fresh, p[3] end
      end
      return bestDelta, bestRow, bestFresh, bestSwap
    end
    local function keepMove(object, row, fresh, swap)
      local from = object.row
      lift(cells, object)
      if swap then
        lift(cells, swap); place(cells, swap, from); sync(swap)
      else
        rowFill[from] = rowFill[from] - 1
        if rowFill[from] == 0 then rowCount = rowCount - 1 end
        if (rowFill[row] or 0) == 0 then rowCount = rowCount + 1 end
        rowFill[row] = (rowFill[row] or 0) + 1
      end
      place(cells, object, row); sync(object)
      -- Replay each touched channel's trial (and repair).
      for c, f in pairs(fresh) do
        local router = routers[c]
        local sp = spanOf(c)
        local rp = f[2]
        local v = router.try(changesFor(c, object, swap), TRIAL_SIFT, not (rp and rp.noLimit) and siftLimit(c, sp) or nil)
        if rp then
          local rounds = rp.rounds or 1
          if rp.illegalFirst then v = router.repair(rounds, rp.focus, v, { illegalTarget = rp.target }) end
          if rp.second then v = router.repair(rounds, rp.focus, v) end
        end
        router.keep(v)
        setCost(c, v + sp)
      end
      rowsUsed = math.max(rowsUsed, row + 1)
    end

    -- The drawer refuses unrelated pipes sharing a line, so no illegal
    -- contact may remain, whatever the budget.
    local function illegalCount()
      local n = 0
      for c = 0, columns - 2 do n = n + floor(cost[c] / ILLEGAL) end
      return n
    end
    -- Trial for clearing: a channel left with an illegal contact gets an
    -- illegal-only repair of the links at contacts and the moved items (the
    -- kept move also gets a full repair of those).
    local clearFocus
    local function clearTrial(a, b)
      local delta, fresh, dNeed = 0, {}, 0
      for c in pairs(touchedBy(a, b)) do
        local router = routers[c]
        local sp = spanOf(c)
        local changes = changesFor(c, a, b)
        local v = router.try(changes, TRIAL_SIFT)
        local focus = {}
        for item in pairs(clearFocus) do focus[item] = true end
        for j = 1, #changes, 2 do focus[changes[j]] = true end
        local rp = { noLimit = true, rounds = CLEAR_ROUNDS, focus = focus }
        if v >= ILLEGAL then
          v = router.repair(CLEAR_ROUNDS, focus, v, { illegalTarget = 0 })
          rp.illegalFirst, rp.target = true, 0
        end
        dNeed = dNeed + need(router.tracks()) - need(kOf[c])
        router.undo()
        routed = routed + 1
        fresh[c] = { v + sp, rp, sp }
        delta = delta + v + sp - cost[c]
      end
      evaluations = evaluations + 1
      return delta + widthDelta(dNeed), fresh
    end
    -- Clear illegal contacts: a full repair of the rows as they are, then,
    -- while any is left, the best clearing move of an object at a contact
    -- to any row (rowsUsed is a fresh empty one).
    local function clearIllegal()
      for c = 0, columns - 2 do
        if cost[c] >= ILLEGAL then
          local router = routers[c]
          local sp = spanOf(c)
          local v = router.try({}, TRIAL_SIFT)
          v = router.repair(CLEAR_ROUNDS, nil, v, { illegalTarget = 0 })
          v = router.repair(CLEAR_ROUNDS, nil, v)
          if v + sp < cost[c] then
            router.keep(v)
            setCost(c, v + sp)
          else
            router.undo()
          end
        end
      end
      while illegalCount() > 0 do
        local inIllegal, items = {}, {}
        for c = 0, columns - 2 do
          if cost[c] >= ILLEGAL then routers[c].illegalItems(items) end
        end
        for item in pairs(items) do inIllegal[item.object] = true end
        clearFocus = items
        -- Rank every move by an unrepaired routing (an illegal contact
        -- counted as ILLEGAL_GUESS); repair-score the best CLEAR_TRIES.
        local ranked, rankFrom = {}, nil
        local function rank(a, b)
          local delta = 0
          for c in pairs(touchedBy(a, b)) do
            local router = routers[c]
            local v = router.try(changesFor(c, a, b), TRIAL_SIFT)
            router.undo()
            local n = floor(v / ILLEGAL)
            delta = delta + v - n * ILLEGAL + n * ILLEGAL_GUESS + spanOf(c) - cost[c] + floor(cost[c] / ILLEGAL) * ILLEGAL
          end
          ranked[#ranked + 1] = { delta + (b and 0 or rowDelta(rankFrom, a.row)), a, a.row }
          return INF
        end
        for _, object in ipairs(visit) do
          if inIllegal[object] then
            rankFrom = object.row
            bestMove(object, 0, rowsUsed, rank)
          end
        end
        table.sort(ranked, function(p, q)
          if p[1] ~= q[1] then return p[1] < q[1] end
          if index[p[2]] ~= index[q[2]] then return index[p[2]] < index[q[2]] end
          return p[3] < q[3]
        end)
        local bestDelta, bestObject, bestRow, bestFresh, bestSwap = -ILLEGAL / 2, nil, nil, nil, nil
        for j, p in ipairs(ranked) do
          if j > CLEAR_TRIES and bestObject then break end
          local delta, row, fresh, swap = bestMove(p[2], p[3], p[3], clearTrial)
          if row and delta < bestDelta then
            bestDelta, bestObject, bestRow, bestFresh, bestSwap = delta, p[2], row, fresh, swap
          end
        end
        if not bestObject then return end
        for _, f in pairs(bestFresh) do f[2].second = true end
        keepMove(bestObject, bestRow, bestFresh, bestSwap)
      end
    end

    local function runPasses(budget, clearAfterFirst)
    for pass = 1, LIVE_PASSES do
      local improved = false
      for _, object in ipairs(visit) do
        if #object.channelList > 0 and liveWork < budget then
          local rlo, rhi = INF, -INF
          for _, nb in ipairs(neighbours[object]) do
            if nb.row < rlo then rlo = nb.row end
            if nb.row > rhi then rhi = nb.row end
          end
          if rlo > rhi then rlo, rhi = object.row, object.row end
          rlo, rhi = math.max(0, rlo - WINDOW), math.min(rowsUsed, rhi + WINDOW)
          local _, row, fresh, swap = bestMove(object, rlo, rhi, false)
          if row then
            keepMove(object, row, fresh, swap)
            improved = true
          end
        end
      end
      -- Contacts the first pass left are cleared now, outside the budget
      -- (rare), so the later passes can win back what clearing costs.
      if clearAfterFirst and pass == 1 and illegalCount() > 0 then
        local work = liveWork
        clearIllegal()
        liveWork = work
        improved = true
      end
      if not improved then break end
    end
    end
    -- Final routings: thorough, from the kept modes and order; keys that
    -- routeChannel replays. Routing depends only on the row order, so
    -- they stay valid when empty rows are dropped. Also the screen overflow
    -- at the smallest scale.
    local function finalRoutes()
      local keys, width = {}, 0
      for c = 0, columns - 2 do
        local router = routers[c]
        local _, key = router.route(yOf, false, { warm = router.snapshot(), nodeCap = FINAL_NODES })
        keys[c + 1] = key
        width = width + need(router.tracks())
      end
      if not fit then
        return keys, 0, 0
      end
      return keys, fit.widthCost(width), fit.heightCost(rowCount)
    end

    liveWork = 0
    runPasses(budget or LIVE_BUDGET, true)
    clearIllegal()
    local keys, wOver, hOver = finalRoutes()
    -- Rows a little too large for the screen even at the smallest scale:
    -- more passes from here, now also scored by the overflow. The screen
    -- scrolls sideways but not vertically, so height is chased further (up
    -- to four rows over) than width (two track gaps); trees further over
    -- never fit and only cost crossings.
    if fit and ((hOver > 0 and hOver <= 2 * fit.reach) or (wOver > 0 and wOver <= fit.reach)) then
      local keptRows, keptKeys, keptTotal, keptCount = {}, keys, total, rowCount
      for i, object in ipairs(s.objects) do keptRows[i] = object.row end
      total = 0
      for c = 0, columns - 2 do
        cost[c] = routers[c].init(yOf, INIT_ROUNDS) + spanOf(c)
        cache[c], rawCache[c] = {}, {}
        total = total + cost[c]
        routed = routed + 1
      end
      needSum = 0
      for c = 0, columns - 2 do
        kOf[c] = routers[c].tracks()
        needSum = needSum + need(kOf[c])
      end
      fitOn, fitWidth = true, wOver <= fit.reach
      runPasses(liveWork + FIT_BUDGET, false)
      clearIllegal()
      local wAfter, hAfter
      keys, wAfter, hAfter = finalRoutes()
      -- Kept if it is shorter, or (width only) if it now fits; otherwise
      -- the overflow costs crossings for nothing and the rows found before
      -- are kept.
      local better
      if hOver > 0 then
        better = hAfter < hOver
      else
        better = wAfter + hAfter == 0
      end
      if not better then
        for i, object in ipairs(s.objects) do
          object.row = keptRows[i]
          sync(object)
        end
        keys, total, rowCount = keptKeys, keptTotal, keptCount
      else
        wOver, hOver = wAfter, hAfter
      end
    end

    local illegalLeft = illegalCount()

    -- Drop empty rows (keeps the order, so the routings stay valid).
    local usedRow = {}
    for _, object in ipairs(s.objects) do usedRow[object.row] = true end
    local remap, count = {}, 0
    for r = 0, rowsUsed do
      if usedRow[r] then remap[r], count = count, count + 1 end
    end
    for _, object in ipairs(s.objects) do
      object.row = remap[object.row]
      sync(object)
    end
    -- Comparable across starts: legal first, then not cut off at the
    -- bottom, then fitting the width, then cost.
    local score = illegalLeft * ILLEGAL + (hOver > 0 and ILLEGAL / 2 + hOver or 0)
      + (wOver > 0 and ILLEGAL / 4 or 0) + total + ROW_WEIGHT * count
    return count, evaluations, score, routed, keys, liveWork
  end
end

local function familyPriority(graph, g, s)
  local family = {}
  local function familyOf(node)
    if family[node] then
      return family[node]
    end
    local parents = g.parents[node]
    if #parents == 1 then
      family[node] = familyOf(parents[1])
    else
      family[node] = node
    end
    return family[node]
  end
  local priority = {}
  local starts = {}
  for node = 1, g.n do
    local start = familyOf(node)
    if not starts[start] then
      starts[start] = true
      local data = graph.nodes[g.names[start]]
      local external = #g.parents[start] == 0
        and ((data.requiredPrereq ~= nil) or #(data.orPrereqs or {}) > 0)
      local r = s.cardItem[start].object.row
      local order = type(data.id) == "number" and data.id or 100000 + r
      priority[start] = (external and 0 or 1000000) - order * 10 - g.rank[start]
    end
  end
  return function(node)
    return priority[familyOf(node)]
  end
end

--------------------------------------------------------------------------
-- Solve
--------------------------------------------------------------------------

local function simplify(points)
  local out = {}
  for _, p in ipairs(points) do
    local last = out[#out]
    if not last or last.x ~= p.x or last.y ~= p.y then
      out[#out + 1] = p
    end
  end
  local i = 2
  while i < #out do
    local a, b, c = out[i - 1], out[i], out[i + 1]
    if (a.x == b.x and b.x == c.x) or (a.y == b.y and b.y == c.y) then
      table.remove(out, i)
    else
      i = i + 1
    end
  end
  return out
end


-- The screen as the live search sees it: at the smallest scale (the most
-- that fits), the width of a channel with k tracks, and the cost of
-- overflowing the viewport, FIT_COST per track gap of width or per row.
local FIT_COST = 3000
local function screenFit(g, geometry)
  local buttonW, buttonH = geometry.buttonW, geometry.buttonH
  local viewportW = geometry.viewportW or 1630
  local viewportH = geometry.viewportH or 1000
  local sc = MIN_SCALE
  local cardW = geometry.cardWidth or 160
  local stub = max(STUB, max(0, (cardW / sc - buttonW) / 2) + (JUNCTION_TRIM + 6) / sc)
  local gap = MIN_TRACK_GAP / sc
  local roomW = viewportW - sc * (FIRST_COLUMN_X + g.columns * buttonW + MARGIN)
  local rowPitch = sc * (buttonH + ROW_GAP_MIN)
  return {
    reach = 2 * FIT_COST, -- overflow worth searching: two track gaps or rows
    need = function(k)
      if k == 0 then return sc * CHANNEL_MIN end
      return sc * max(CHANNEL_MIN, 2 * stub + (k - 1) * gap)
    end,
    widthCost = function(sum)
      local over = sum - roomW
      return over > 0 and FIT_COST * over / MIN_TRACK_GAP or 0
    end,
    heightCost = function(rows)
      local over = sc * (MARGIN_TIGHT * 2 + (rows - 1) * (buttonH + ROW_GAP_MIN) + buttonH) - viewportH
      return over > 0 and FIT_COST * over / rowPitch or 0
    end,
  }
end

function PromotionTreeLayoutSolve(graph, geometry)
  local clock = os and os.clock
  local started = clock and clock()
  local buttonW, buttonH = geometry.buttonW, geometry.buttonH
  assert(buttonW and buttonH, "buttonW and buttonH required")
  local viewportW = geometry.viewportW or 1630
  local viewportH = geometry.viewportH or 1000
  local fitRows = rowsThatFit(geometry)
  local refinePasses = geometry.refinePasses or 0

  -- One attempt: fold to a row target, then search the rows.
  local lastColumns = nil
  local function attempt(target, retry)
    local g = prepareGraph(graph)
    local folded, stuck = foldColumns(g, target)
    -- A lower target that folds no differently needs no new search.
    local columnsKey = table.concat(g.rank, ",")
    if retry and (folded == 0 or columnsKey == lastColumns) then
      return nil, stuck
    end
    lastColumns = columnsKey
    local s = buildObjects(g)
    -- Rows: searched.
    local bestCost, bestCount = 0, nil
    local trials, routings = 0, 0
    local liveRoutes
    do
      local links = neighbourObjects(g, s)
      -- Starting orders; keep the better estimate.
      local bestRows
      bestCost = INF
      for seed = 1, refinePasses > 0 and 2 or 0 do
        local rows = initialRows(g, s, links, seed)
        local value, count = searchRows(g, s, rows, refinePasses > 0 and SEARCH_PASSES or START_PASSES)
        if value < bestCost then
          bestCost, bestCount = value, count
          bestRows = {}
          for _, object in ipairs(s.objects) do
            bestRows[object] = object.row
          end
        end
      end
      if refinePasses > 0 then
        for _, object in ipairs(s.objects) do
          object.row = bestRows[object]
        end
        bestCount, trials, _, routings = refineRows(g, s, refinePasses)
      else
        -- Live search from a first start order; a small tree that leaves most
        -- of the work budget unused searches again from other start orders
        -- with what is left, and keeps the best result.
        local fit = screenFit(g, geometry)
        local spent, bestScore = 0, INF
        bestRows = {}
        for start = 1, retry and 1 or #LIVE_STARTS do
          local budget = start > 1 and MULTI_START_WORK - spent or nil
          if retry then
            budget = RETRY_WORK
          end
          if budget and budget < MULTI_START_MIN then break end
          local rows = initialRows(g, s, links, LIVE_STARTS[start])
          local value = searchRows(g, s, rows, START_PASSES)
          local count, tried, score, routed, keys, work = liveRefine(g, s, fit, budget)
          spent = spent + work
          trials, routings = trials + tried, routings + routed
          if score < bestScore then
            bestScore, bestCost, bestCount, liveRoutes = score, value, count, keys
            for _, object in ipairs(s.objects) do
              bestRows[object] = object.row
            end
          end
        end
        for _, object in ipairs(s.objects) do
          object.row = bestRows[object]
        end
      end
    end
    local rowCount = max(1, bestCount)
    -- A few rows too tall for the screen: close up rows where no column
    -- needs them apart. Every column keeps its order; the channels are
    -- routed afresh, and the close-up is undone if that leaves a contact.
    if rowCount > fitRows and rowCount - fitRows <= 4 then
      local wanted = {}
      for _, object in ipairs(s.objects) do
        wanted[object] = object.row
      end
      local packed = packRows(s.objects, wanted, g.columns)
      local legal = packed < rowCount
      if legal then
        local rowOf = {}
        for _, item in ipairs(s.items) do
          rowOf[item] = item.object.row
        end
        for c = 0, g.columns - 2 do
          if routeChannel(s.channels[c], rowOf, false).illegal > 0 then
            legal = false
            break
          end
        end
      end
      if legal then
        rowCount, liveRoutes = packed, nil
      else
        for _, object in ipairs(s.objects) do
          object.row = wanted[object]
        end
      end
    end
    return { g = g, s = s, folded = folded, stuck = stuck, rowCount = rowCount, bestCost = bestCost,
      trials = trials, routings = routings, liveRoutes = liveRoutes }
  end

  -- The screen does not scroll vertically: while the rows found are more
  -- than fit, fold to a lower target and search again; keep the shortest.
  local best = attempt(fitRows)
  local target = fitRows
  for _ = 1, 2 do
    if best.rowCount <= fitRows or best.stuck then
      break
    end
    -- Lower the target until the folding changes (the fullest column may
    -- already be under the first lower target).
    target = target - (best.rowCount - fitRows)
    local try, stuck
    while target >= 2 do
      try, stuck = attempt(target, true)
      if try or stuck then
        break
      end
      target = target - 1
    end
    if not try then
      break
    end
    if try.rowCount < best.rowCount then
      best = try
    end
    if try.stuck then
      break
    end
  end
  local g, s, folded, rowCount = best.g, best.s, best.folded, best.rowCount
  local bestCost, trials, routings, liveRoutes = best.bestCost, best.trials, best.routings, best.liveRoutes

  -- Route every channel. Routing compares rows only, so it runs on row
  -- indices and the geometry follows.
  local rowOf = {}
  for _, item in ipairs(s.items) do
    rowOf[item] = item.object.row
  end
  local routed = {}
  local totalIllegal = 0
  local widths = {}
  for c = 0, g.columns - 2 do
    local result = routeChannel(s.channels[c], rowOf, false, liveRoutes and liveRoutes[c + 1])
    totalIllegal = totalIllegal + result.illegal
    routed[c] = result
    widths[c] = #result.tracks
  end

  -- Scale. A tree larger than the viewport shrinks uniformly, down to the
  -- smallest scale the card art accepts. Native pipe junctions keep their
  -- size on screen, so the logical track gap grows as the scale falls.
  local columns = g.columns
  local fixed = FIRST_COLUMN_X + columns * buttonW + MARGIN
  -- Painted cards keep their width on screen, so below scale 1 they overhang
  -- the logical card box; the first track must clear that and a pipe turn.
  local cardW = geometry.cardWidth or 160
  local function stubFor(scale)
    return max(STUB, max(0, (cardW / scale - buttonW) / 2) + (JUNCTION_TRIM + 6) / scale)
  end
  local function channelWidth(k, gap, stub)
    if k == 0 then
      return CHANNEL_MIN
    end
    return max(CHANNEL_MIN, 2 * stub + (k - 1) * gap)
  end
  local function contentWidth(gap, stub)
    local need = fixed
    for c = 0, columns - 2 do
      need = need + channelWidth(widths[c], gap, stub)
    end
    return need
  end
  local tightHeight = MARGIN * 2 + (rowCount - 1) * (buttonH + ROW_GAP_MIN) + buttonH
  local function fits(scale)
    return scale * contentWidth(MIN_TRACK_GAP / scale, stubFor(scale)) <= viewportW
      and scale * tightHeight <= viewportH
  end
  local scale, overflow = 1, false
  if not fits(1) then
    if fits(MIN_SCALE) then
      local lo, hi = MIN_SCALE, 1
      for _ = 1, 16 do
        local mid = (lo + hi) / 2
        if fits(mid) then
          lo = mid
        else
          hi = mid
        end
      end
      scale = lo
    else
      scale, overflow = MIN_SCALE, true
    end
  end
  local logicalW, logicalH = viewportW / scale, viewportH / scale
  local minGap, stub = MIN_TRACK_GAP / scale, stubFor(scale)

  -- Vertical geometry: spread the rows over the viewport within limits.
  -- The top and bottom margins shrink before the tree is cut off.
  local vMargin = MARGIN
  if scale * tightHeight > viewportH then
    vMargin = max(MARGIN_TIGHT, floor((logicalH - (tightHeight - 2 * MARGIN)) / 2))
  end
  local available = logicalH - 2 * vMargin - buttonH
  local pitch = rowCount > 1 and available / (rowCount - 1) or 0
  pitch = max(buttonH + ROW_GAP_MIN, min(buttonH + ROW_GAP_MAX, pitch))
  pitch = floor(pitch)
  local function centreY(r)
    return vMargin + r * pitch + floor(buttonH / 2)
  end
  local yOf = {}
  for _, item in ipairs(s.items) do
    yOf[item] = centreY(item.object.row)
  end

  -- Horizontal geometry: the preferred track gap, tightened before the
  -- tree overflows.
  local gap = max(TRACK_GAP, minGap)
  local need = contentWidth(gap, stub)
  if need > logicalW then
    local tracksTotal = 0
    for c = 0, columns - 2 do
      tracksTotal = tracksTotal + max(0, widths[c] - 1)
    end
    if tracksTotal > 0 then
      gap = max(minGap, gap - (need - logicalW) / tracksTotal)
    end
    need = contentWidth(gap, stub)
  end
  local channelW = {}
  local spare = max(0, logicalW - need)
  for c = 0, columns - 2 do
    channelW[c] = channelWidth(widths[c], gap, stub)
  end
  if columns > 1 and spare > 0 then
    -- Share spare width equally, never past the widest useful channel.
    local each = spare / (columns - 1)
    for c = 0, columns - 2 do
      channelW[c] = floor(min(max(CHANNEL_MAX, channelW[c]), channelW[c] + each))
    end
  end
  local columnX = {}
  local x = FIRST_COLUMN_X
  for c = 0, columns - 1 do
    columnX[c] = x
    x = x + buttonW + (channelW[c] or 0)
  end
  local width = x - (channelW[columns - 1] or 0) + MARGIN
  local height = vMargin * 2 + (rowCount - 1) * pitch + buttonH

  -- Track x positions: centred in the channel at the chosen spacing.
  for c = 0, columns - 2 do
    local info = routed[c]
    local k = #info.order
    local xr = columnX[c] + buttonW
    local w = channelW[c]
    local step = k > 1 and min(gap * 1.5, (w - 2 * stub) / (k - 1)) or 0
    local first = xr + (w - (k - 1) * step) / 2
    for i, track in ipairs(info.order) do
      track.x = floor(first + (i - 1) * step + 0.5)
    end
  end

  -- Assemble each prerequisite's route.
  local buttons = {}
  for node = 1, g.n do
    local item = s.cardItem[node]
    buttons[#buttons + 1] = {
      type = g.names[node],
      x = columnX[g.rank[node]],
      y = vMargin + item.object.row * pitch,
    }
  end
  local routes = {}
  for _, e in ipairs(g.edges) do
    local ra, rb = g.rank[e.parent], g.rank[e.child]
    local lane = s.laneOf[e.index]
    local points = { { x = columnX[ra] + buttonW, y = yOf[s.cardItem[e.parent]] } }
    for c = ra, rb - 1 do
      local left = c == ra and s.cardItem[e.parent] or lane.cells[c]
      local right = c + 1 == rb and s.cardItem[e.child] or lane.cells[c + 1]
      local link = nil
      for _, candidate in ipairs(s.channels[c].links) do
        if candidate.left == left and candidate.right == right then
          link = candidate
          break
        end
      end
      if not link.straight then
        points[#points + 1] = { x = link.track.x, y = yOf[left] }
        points[#points + 1] = { x = link.track.x, y = yOf[right] }
      end
      points[#points + 1] = { x = columnX[c + 1], y = yOf[right] }
    end
    routes[#routes + 1] = {
      parent = g.names[e.parent],
      child = g.names[e.child],
      points = simplify(points),
      gaps = {},
    }
  end

  -- Root source spine.
  local roots = {}
  for node = 1, g.n do
    if g.rank[node] == 0 then
      roots[#roots + 1] = node
    end
  end
  table.sort(roots, function(a, b)
    return yOf[s.cardItem[a]] < yOf[s.cardItem[b]]
  end)
  local source = nil
  local sourceRoutes = {}
  if #roots > 0 then
    local middle = roots[floor((#roots + 1) / 2)]
    source = { x = SOURCE_X, y = yOf[s.cardItem[middle]] }
    for _, root in ipairs(roots) do
      local y = yOf[s.cardItem[root]]
      sourceRoutes[#sourceRoutes + 1] = {
        parent = "__PROMOTION_SOURCE__",
        child = g.names[root],
        points = simplify({
          { x = source.x, y = source.y },
          { x = source.x, y = y },
          { x = columnX[0], y = y },
        }),
        gaps = {},
      }
    end
  end

  -- Crossings: the lower-priority promotion path passes under.
  local priorityOf = familyPriority(graph, g, s)
  local routePriority = {}
  for i, e in ipairs(g.edges) do
    routePriority[routes[i]] = priorityOf(e.parent) * 1000 - g.rank[e.parent]
  end
  local crossingPoints = {}
  for c = 0, g.columns - 2 do
    for _, hit in ipairs(routed[c].crossings) do
      crossingPoints[#crossingPoints + 1] = { x = hit.track.x, y = centreY(hit.y) }
    end
  end
  -- Gaps are logical; bring each underpass two screen pixels closer.
  local halfGap = (geometry.underpassHalfGap or 10) - 2 / scale
  local underpasses = {}
  for _, point in ipairs(crossingPoints) do
    local horizontal, vertical = {}, {}
    local hp, vp = -INF, -INF
    for _, route in ipairs(routes) do
      local p = route.points
      for k = 1, #p - 1 do
        local a, b = p[k], p[k + 1]
        if a.y == b.y and a.y == point.y and point.x > min(a.x, b.x) and point.x < max(a.x, b.x) then
          horizontal[#horizontal + 1] = { route = route, segment = k, at = abs(point.x - a.x) }
          hp = max(hp, routePriority[route])
        elseif
          a.x == b.x and a.x == point.x and point.y > min(a.y, b.y) and point.y < max(a.y, b.y)
        then
          vertical[#vertical + 1] = { route = route, segment = k, at = abs(point.y - a.y) }
          vp = max(vp, routePriority[route])
        end
      end
    end
    local under, over = vertical, horizontal
    if hp < vp then
      under, over = horizontal, vertical
    end
    for _, hit in ipairs(under) do
      hit.route.gaps[#hit.route.gaps + 1] =
        { segment = hit.segment, from = hit.at - halfGap, to = hit.at + halfGap }
    end
    if under[1] and over[1] then
      underpasses[#underpasses + 1] = {
        x = point.x,
        y = point.y,
        under = { parent = under[1].route.parent, child = under[1].route.child },
        over = { parent = over[1].route.parent, child = over[1].route.child },
      }
    end
  end

  local layout = {
    buttons = buttons,
    routes = routes,
    sourceRoutes = sourceRoutes,
    source = source,
    width = max(width, logicalW),
    height = max(height, logicalH),
    contentWidth = width,
    contentHeight = height,
    scale = scale,
    overflow = overflow,
    tooTall = scale * height > viewportH + 0.5, -- cut off: the game only scrolls sideways
    crossings = #crossingPoints,
    underpasses = underpasses,
    valid = totalIllegal == 0,
    violations = {},
    method = "channels",
    stats = { rows = rowCount, folded = folded, pitch = pitch, trackGap = gap, estimate = bestCost, trials = trials, routed = routings },
  }
  if totalIllegal > 0 then
    layout.violations[#layout.violations + 1] = "channel routing left "
      .. totalIllegal
      .. " unresolved pipe contacts"
  end
  if clock then
    layout.stats.seconds = clock() - started
  end
  return layout
end
