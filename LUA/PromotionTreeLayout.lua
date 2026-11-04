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
-- Rows and channel routings for the graphs of the current game data are
-- optimised offline by slow exact refinement (devtools) and stored in
-- PromotionTreeStoredRows; a matching graph only replays and checks them.
-- Any other graph gets the fast estimate search here.
--
-- A tree larger than the viewport is shrunk uniformly (layout.scale) down
-- to the smallest scale the card art accepts; beyond that layout.overflow is
-- set. The result uses the established layout table: buttons, routes,
-- sourceRoutes, source, width, height and scale. Nothing here depends on
-- Civ V.

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local INF = math.huge

local SOURCE_X = 24 -- the root source spine
local FIRST_COLUMN_X = 92
local MARGIN = 28 -- right and vertical canvas margin
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
local SEARCH_PASSES = 6
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
  -- The graph's identity for stored row orders: promotions, prerequisites
  -- and rank chains, hashed.
  local parts = {}
  for i = 1, n do
    parts[#parts + 1] = names[i]
  end
  for _, e in ipairs(edges) do
    parts[#parts + 1] = e.parent .. ">" .. e.child
  end
  for _, chain in ipairs(chains) do
    parts[#parts + 1] = table.concat(chain, "-")
  end
  local text = table.concat(parts, ",")
  local hash = 5381
  for i = 1, #text do
    hash = (hash * 33 + text:byte(i)) % 4294967296
  end
  return {
    signature = string.format("%08x-%d-%d", hash, n, #edges),
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

local function initialRows(g, s, links, seed)
  -- Barycentric sweeps on real positions, re-packed into rows each time.
  local wanted = {}
  for _, object in ipairs(s.objects) do
    local first = object.cells[object.lo]
    local key = first.card and g.names[first.card] or ("~" .. object.index)
    wanted[object] = object.index
    object.key = key
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

local function searchRows(g, s, rows)
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
  for pass = 1, SEARCH_PASSES do
    local improved = false
    for _, object in ipairs(s.objects) do
      if #object.channelList > 0 then
        local from = object.row
        local bestDelta, bestRow, bestFresh = -0.5, nil, nil
        local bestSwap, bestRows = nil, nil
        local limit = rowsUsed -- one fresh row below the current ones
        for r = 0, limit do
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
local MODE_LETTER = { trunk = "t", collector = "c", own = "o" }
local LETTER_MODE = { t = "trunk", c = "collector", o = "own" }

local function routeChannel(channel, yOf, quick, stored)
  local links = channel.links
  local leftList, rightList = channelItems(channel, yOf)
  local function evaluate(thorough)
    local tracks = buildTracks(links, leftList, rightList)
    contactCosts(tracks, leftList, rightList)
    local order, pos, cost = orderTracks(tracks, leftList, rightList, thorough)
    return cost + #tracks * TRACK_COST, tracks, order, pos
  end
  -- A stored routing, "modes:order": one letter per link, then the track
  -- ids west to east. Nil unless it fits these links and is legal.
  local function replay()
    local modeText, orderText = stored:match("^(%a*):([%d,]*)$")
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
  if stored then
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
  local letters, ids = {}, {}
  for i, link in ipairs(links) do
    letters[i] = MODE_LETTER[link.mode] or "t"
  end
  for i, track in ipairs(order) do
    ids[i] = track.id
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
    stored = table.concat(letters) .. ":" .. table.concat(ids, ","),
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

--------------------------------------------------------------------------
-- Stored row orders
--------------------------------------------------------------------------

-- An object's name in stored row orders: its first card, or for a long pipe
-- lane its prerequisite and target column.
local function objectKey(g, object)
  local first = object.cells[object.lo]
  if first.card then
    return g.names[first.card]
  end
  return "~" .. g.names[first.lane.parent] .. ">" .. (first.lane.hi + 1)
end

-- Rows optimised offline (devtools) for this exact graph, if any. Returns
-- the number of rows, or nil when nothing usable is stored.
local function applyStoredRows(g, s)
  local entry = PromotionTreeStoredRows and PromotionTreeStoredRows[g.signature]
  local stored = entry and entry.rows
  if not stored then
    return nil
  end
  local taken, count = {}, 0
  for _, object in ipairs(s.objects) do
    local r = stored[objectKey(g, object)]
    if not r then
      return nil
    end
    for c = object.lo, object.hi do
      local cell = c * 4096 + r
      if taken[cell] then
        return nil
      end
      taken[cell] = true
    end
    count = max(count, r + 1)
  end
  for _, object in ipairs(s.objects) do
    object.row = stored[objectKey(g, object)]
  end
  return count, entry.routes
end

-- The rows of a finished layout, for storing.
local function rowsByKey(g, s)
  local rows = {}
  for _, object in ipairs(s.objects) do
    rows[objectKey(g, object)] = object.row
  end
  return rows
end

function PromotionTreeLayoutSolve(graph, geometry)
  local clock = os and os.clock
  local started = clock and clock()
  local buttonW, buttonH = geometry.buttonW, geometry.buttonH
  assert(buttonW and buttonH, "buttonW and buttonH required")
  local viewportW = geometry.viewportW or 1630
  local viewportH = geometry.viewportH or 1000
  local g = prepareGraph(graph)
  local s = buildObjects(g)

  -- Rows: stored for this graph, or searched.
  local storedCount, storedRoutes = applyStoredRows(g, s)
  local bestCost, bestCount = 0, storedCount
  local trials, routings = 0, 0
  if not storedCount then
    local links = neighbourObjects(g, s)
    -- Two starting orders; keep the better estimate.
    local bestRows
    bestCost = INF
    for seed = 1, 2 do
      local rows = initialRows(g, s, links, seed)
      local value, count = searchRows(g, s, rows)
      if value < bestCost then
        bestCost, bestCount = value, count
        bestRows = {}
        for _, object in ipairs(s.objects) do
          bestRows[object] = object.row
        end
      end
    end
    for _, object in ipairs(s.objects) do
      object.row = bestRows[object]
    end
    if (geometry.refinePasses or 0) > 0 then
      bestCount, trials, _, routings = refineRows(g, s, geometry.refinePasses)
    end
  end
  local rowCount = max(1, bestCount)

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
    local result = routeChannel(s.channels[c], rowOf, false, storedRoutes and storedRoutes[c + 1])
    totalIllegal = totalIllegal + result.illegal
    routed[c] = result
    widths[c] = #result.tracks
  end
  local routeKeys = {}
  for c = 0, g.columns - 2 do
    routeKeys[c + 1] = routed[c].stored
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
  local available = logicalH - 2 * MARGIN - buttonH
  local pitch = rowCount > 1 and available / (rowCount - 1) or 0
  pitch = max(buttonH + ROW_GAP_MIN, min(buttonH + ROW_GAP_MAX, pitch))
  pitch = floor(pitch)
  local function centreY(r)
    return MARGIN + r * pitch + floor(buttonH / 2)
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
  local height = MARGIN * 2 + (rowCount - 1) * pitch + buttonH

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
      y = MARGIN + item.object.row * pitch,
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
    crossings = #crossingPoints,
    underpasses = underpasses,
    valid = totalIllegal == 0,
    violations = {},
    method = "channels",
    stats = { rows = rowCount, pitch = pitch, trackGap = gap, estimate = bestCost, trials = trials, routed = routings, stored = storedCount ~= nil },
    signature = g.signature,
    rowsByKey = rowsByKey(g, s),
    routeKeys = routeKeys,
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
