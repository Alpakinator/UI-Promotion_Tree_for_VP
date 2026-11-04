--
-- Promotion Utility functions
--

--
-- Unit promotion functions
--

function HasPromotion(liveUnit, promotionID)
  return (liveUnit and liveUnit:IsHasPromotion(promotionID))
end

function CanAcquirePromotion(liveUnit, promotionID)
  if liveUnit and liveUnit:CanAcquirePromotion(promotionID) then
    local actionID = GetActionForPromotion(promotionID)
    return (actionID and Game.CanHandleAction(actionID))
  end

  return false
end

--
-- Action promotion functions
--

function GetActionForPromotion(promotionID)
  local promotion = GameInfo.UnitPromotions[promotionID]

  for actionID, action in pairs(GameInfoActions) do
    if
      action.SubType == ActionSubTypes.ACTIONSUBTYPE_PROMOTION and action.Type == promotion.Type
    then
      return actionID
    end
  end

  return nil
end

--
-- Ranked promotions
--
-- This only decides how the unit tool tip groups promotions.  It used to gate
-- the tree traversal as well, which is what hid Logistics from the naval
-- ranged tree: its only two in-class parents (Broadside and Indomitable) are
-- unranked, so the walk dead-ended at both.  The graph below uses the prereq
-- columns directly and does not consult this at all.
--
local sMatchRank = "_[0-9IV]+$"

--
-- Families are read off the name the player sees, not the type.  Vox Populi
-- does not always keep the two in step: PROMOTION_SORTIE is shown as "Ace Pilot
-- IV" and is the fourth rank of PROMOTION_INTERCEPTION_1..3, but nothing in its
-- type says so, and the fighter tree hung it a row below the other three -- the
-- exact thing the row rule exists to stop.
--
-- The display name is used only when it ends in a rank; otherwise this falls
-- back to the type, so a language that does not number ranks the same way
-- behaves as it did before rather than losing families altogether.  Across the
-- whole of Vox Populi this changes one chain and nothing else.
--
local sMatchRankName = "[ _][0-9IVX]+$"

function IsRankedPromotion(promotionType)
  if
    promotionType == "PROMOTION_MEDIC"
    or promotionType == "PROMOTION_CHARGE"
    or promotionType == "PROMOTION_ANTI_AIR"
    or promotionType == "PROMOTION_SPLASH"
    or promotionType == "PROMOTION_NAVIGATOR"
  then
    return true
  end

  return (promotionType:match(sMatchRank) ~= nil)
end

function GetPromotionBase(promotionType, promotionName)
  if promotionName and promotionName:match(sMatchRankName) then
    local sRank = promotionName:match(sMatchRankName)
    return "name:" .. promotionName:sub(1, promotionName:len() - sRank:len())
  end

  local sRank = promotionType:match(sMatchRank) or ""
  return promotionType:sub(1, promotionType:len() - sRank:len())
end

--
-- The rank GetPromotionBase stripped, as a number.  Arabic and Roman suffixes
-- both occur, sometimes for different chains sharing a prefix -- INTERCEPTION_1
-- (fighters) and INTERCEPTION_I (gunpowder, naval melee, carriers) are not the
-- same line.  A promotion with no suffix is rank 1, which is what puts MEDIC
-- and MEDIC_II in one chain.
--
local ROMAN_DIGITS = { I = 1, V = 5, X = 10 }

function GetPromotionRank(promotionType, promotionName)
  local sSuffix = promotionName and promotionName:match("[ _]([0-9IVX]+)$")
    or promotionType:match("_([0-9IV]+)$")
  if not sSuffix then
    return 1
  end
  if sSuffix:match("^%d+$") then
    return tonumber(sSuffix)
  end

  local iTotal, iPrev = 0, 0
  for i = sSuffix:len(), 1, -1 do
    local iValue = ROMAN_DIGITS[sSuffix:sub(i, i)] or 0
    if iValue < iPrev then
      iTotal = iTotal - iValue
    else
      iTotal = iTotal + iValue
      iPrev = iValue
    end
  end
  return iTotal
end

--
-- Promotion graph
--

local PREREQ_COLUMNS = {
  "PromotionPrereqOr1",
  "PromotionPrereqOr2",
  "PromotionPrereqOr3",
  "PromotionPrereqOr4",
  "PromotionPrereqOr5",
  "PromotionPrereqOr6",
  "PromotionPrereqOr7",
  "PromotionPrereqOr8",
  "PromotionPrereqOr9",
}

--
-- Database boundary for selectable class members. The offline harness replaces
-- this and the free-promotion fetch below; the graph rules run unchanged.
--
function PromotionGraphFetchRows(membershipClass)
  local rows = {}

  local sQuery = "SELECT p.* FROM UnitPromotions p "
    .. "JOIN UnitPromotions_UnitCombats c ON c.PromotionType = p.Type "
    .. "WHERE c.UnitCombatType = ? AND IFNULL(p.CannotBeChosen, 0) = 0 ORDER BY p.Type"
  for row in DB.Query(sQuery, membershipClass) do
    -- Civ V database rows are read-only proxies, not ordinary Lua tables.
    -- Copy only the graph's fields before adding presentation metadata.
    local entry = {
      Type = row.Type,
      ID = row.ID,
      PromotionPrereq = row.PromotionPrereq,
      Name = row.Description and Locale and Locale.ConvertTextKey(row.Description) or nil,
    }
    for _, field in ipairs({
      "MountedOnly",
      "MinimumRangeRequired",
      "MaximumRangeRequired",
      "InterceptChanceChange",
      "InterceptionCombatModifier",
      "NumInterceptionChange",
      "Blitz",
      "AirSweepCombatModifier",
      "AllowsEmbarkation",
      "EmbarkedDeepWater",
      "EvasionChange",
    }) do
      entry[field] = row[field]
    end
    for _, field in ipairs(PREREQ_COLUMNS) do
      entry[field] = row[field]
    end
    rows[#rows + 1] = entry
  end

  return rows
end

-- The class view uses a discovered profile; the unit view inspects its type. Unit mode checks actual ownership before using any free promotion:
-- a promotion listed for the type may have been lost after an upgrade. The
-- harness replaces this seam.
function PromotionGraphFetchFreePromotions(classKey, liveUnit)
  local unitType
  if liveUnit then
    if liveUnit.GetUnitType and GameInfo and GameInfo.Units then
      local unit = GameInfo.Units[liveUnit:GetUnitType()]
      unitType = unit and unit.Type
    end
  elseif PromotionClassCatalog then
    local profile = PromotionClassCatalog.Get(classKey)
    unitType = profile and profile.UnitType
  end

  local free = {}
  if unitType then
    for row in
      DB.Query("SELECT PromotionType FROM Unit_FreePromotions WHERE UnitType = ?", unitType)
    do
      free[row.PromotionType] = true
    end
  end
  return free
end

--
-- Builds the promotion graph for a combat class.
--
-- Returns the structure TreeLayoutSolve expects: every node sorted, parents
-- and children sorted, roots sorted.  Sorting is not cosmetic -- DB.Query row
-- order is not contractually stable, and the layout has to be reproducible
-- between openings.
--
-- pUnit is optional.  External free or held promotions can be entry conditions
-- without becoming visible nodes.  Current promotion readiness must only
-- affect button state, never the future graph's topology.
--
function BuildPromotionGraph(classKey, liveUnit, profile)
  if not profile and PromotionClassCatalog then
    profile = PromotionClassCatalog.Get(classKey)
    if liveUnit and liveUnit.GetUnitType and GameInfo and GameInfo.Units then
      profile = PromotionClassCatalog.ForUnit(GameInfo.Units[liveUnit:GetUnitType()], liveUnit)
    end
  end
  local membershipClass = profile and profile.CombatClass or classKey
  local rows = profile and profile.Rows or PromotionGraphFetchRows(membershipClass)

  local member = {}
  local order = {}
  local nameOf = {}
  local diagnostics = {}
  local hasDataError = false
  for i = 1, #rows do
    local row = rows[i]
    local allowed = not profile
      or (profile.Allowed and profile.Allowed[row.Type])
      or (
        profile
        and not profile.Allowed
        and (profile.Free[row.Type] or PromotionClassCatalog.Allows(row, profile.Capabilities))
      )
    if allowed then
      if member[row.Type] then
        table.insert(diagnostics, "duplicate promotion member " .. row.Type)
        hasDataError = true
      else
        member[row.Type] = row
        nameOf[row.Type] = row.Name
        table.insert(order, row.Type)
      end
    end
  end
  table.sort(order)

  -- Keep mandatory AND and alternative OR prerequisites distinct.  The layout
  -- still receives their in-class union in parents/children; node metadata lets
  -- the UI explain their different acquisition meanings.
  local parents, children, requiredOf, alternativesOf = {}, {}, {}, {}
  for i = 1, #order do
    parents[order[i]] = {}
    children[order[i]] = {}
  end

  local function checkPrereq(promotionType, childType)
    if GameInfo and GameInfo.UnitPromotions and GameInfo.UnitPromotions[promotionType] == nil then
      table.insert(diagnostics, "unknown prerequisite " .. promotionType .. " for " .. childType)
      hasDataError = true
    end
  end

  for i = 1, #order do
    local promotionType = order[i]
    local row = member[promotionType]
    local seenEdge, seenOr = {}, {}
    if not row.PromotionPrereqOr1 then
      for j = 2, #PREREQ_COLUMNS do
        if row[PREREQ_COLUMNS[j]] then
          table.insert(diagnostics, "OR prerequisites begin after Or1 for " .. promotionType)
          hasDataError = true
          break
        end
      end
    end
    local requiredType = row.PromotionPrereq
    if requiredType then
      checkPrereq(requiredType, promotionType)
      requiredOf[promotionType] = requiredType
      if member[requiredType] then
        seenEdge[requiredType] = true
        table.insert(parents[promotionType], requiredType)
        table.insert(children[requiredType], promotionType)
      end
    end
    alternativesOf[promotionType] = {}
    for j = 1, #PREREQ_COLUMNS do
      local prerequisiteType = row[PREREQ_COLUMNS[j]]
      if prerequisiteType then
        checkPrereq(prerequisiteType, promotionType)
        if not seenOr[prerequisiteType] then
          table.insert(alternativesOf[promotionType], prerequisiteType)
        end
        if member[prerequisiteType] and not seenEdge[prerequisiteType] then
          table.insert(parents[promotionType], prerequisiteType)
          table.insert(children[prerequisiteType], promotionType)
        end
        seenEdge[prerequisiteType] = true
        seenOr[prerequisiteType] = true
      end
    end
  end

  -- Diagnose malformed cycles rather than letting assignColumns silently make
  -- a backwards edge.  A future caller can refuse to draw an invalid graph.
  local visit, path, inPath = {}, {}, {}
  local hasCycle = false
  local function inspect(promotionType)
    visit[promotionType] = 1
    table.insert(path, promotionType)
    inPath[promotionType] = #path
    for i = 1, #children[promotionType] do
      local childType = children[promotionType][i]
      if visit[childType] == nil then
        inspect(childType)
      elseif visit[childType] == 1 then
        local cycle = {}
        for j = inPath[childType], #path do
          table.insert(cycle, path[j])
        end
        table.insert(cycle, childType)
        table.insert(diagnostics, "prerequisite cycle " .. table.concat(cycle, " -> "))
        hasCycle = true
      end
    end
    inPath[promotionType] = nil
    table.remove(path)
    visit[promotionType] = 2
  end
  for i = 1, #order do
    if visit[order[i]] == nil then
      inspect(order[i])
    end
  end

  local free = profile and profile.Free
    or PromotionGraphFetchFreePromotions(classKey, liveUnit)
    or {}
  local held, sourceStatus = {}, {}
  local function hasSource(promotionType)
    if sourceStatus[promotionType] ~= nil then
      return sourceStatus[promotionType]
    end
    local satisfied
    if not liveUnit then
      satisfied = free[promotionType] == true
    else
      if held[promotionType] == nil then
        local promotion = GameInfo
          and GameInfo.UnitPromotions
          and GameInfo.UnitPromotions[promotionType]
        held[promotionType] = (promotion and HasPromotion(liveUnit, promotion.ID)) and true or false
      end
      satisfied = held[promotionType]
    end
    sourceStatus[promotionType] = satisfied
    return satisfied
  end

  -- The UI planner needs to distinguish an out-of-class prerequisite that is
  -- already held from one that is merely named in an OR list. Evaluate every
  -- referenced name even if the reachability pass can short-circuit early.
  for i = 1, #order do
    local promotionType = order[i]
    if requiredOf[promotionType] then
      hasSource(requiredOf[promotionType])
    end
    for j = 1, #alternativesOf[promotionType] do
      hasSource(alternativesOf[promotionType][j])
    end
  end

  -- Acquisition is AND(required, OR(alternatives)), with empty clauses true.
  -- Iterate to a fixed point so source promotions and ordinary class roots can
  -- open every future branch without consulting Game.CanHandleAction.
  local reachable = {}
  local changed = true
  while changed do
    changed = false
    for i = 1, #order do
      local promotionType = order[i]
      if not reachable[promotionType] then
        local requiredType = requiredOf[promotionType]
        local requiredOk = not requiredType
          or hasSource(requiredType)
          or (member[requiredType] and reachable[requiredType])
        local alternatives = alternativesOf[promotionType]
        local alternativeOk = (#alternatives == 0)
        for j = 1, #alternatives do
          local prerequisiteType = alternatives[j]
          if
            hasSource(prerequisiteType)
            or (member[prerequisiteType] and reachable[prerequisiteType])
          then
            alternativeOk = true
            break
          end
        end
        if hasSource(promotionType) or (requiredOk and alternativeOk) then
          reachable[promotionType] = true
          changed = true
        end
      end
    end
  end

  local externalSources = {}
  for promotionType, satisfied in pairs(sourceStatus) do
    if satisfied and not member[promotionType] then
      externalSources[promotionType] = true
    end
  end

  local graph = {
    order = {},
    nodes = {},
    roots = {},
    diagnostics = diagnostics,
    externalSources = externalSources,
    grantedPromotions = {},
    invalid = hasCycle or hasDataError,
  }
  for i = 1, #order do
    local promotionType = order[i]
    if reachable[promotionType] then
      if free[promotionType] then
        graph.grantedPromotions[promotionType] = true
      end
      local keptParents, keptChildren, keptOrParents = {}, {}, {}
      for j = 1, #parents[promotionType] do
        if reachable[parents[promotionType][j]] then
          table.insert(keptParents, parents[promotionType][j])
        end
      end
      for j = 1, #children[promotionType] do
        if reachable[children[promotionType][j]] then
          table.insert(keptChildren, children[promotionType][j])
        end
      end
      table.sort(keptParents)
      table.sort(keptChildren)
      for j = 1, #alternativesOf[promotionType] do
        local prerequisiteType = alternativesOf[promotionType][j]
        if member[prerequisiteType] and reachable[prerequisiteType] then
          table.insert(keptOrParents, prerequisiteType)
        end
      end
      table.sort(keptOrParents)

      if #keptParents == 0 then
        table.insert(graph.roots, promotionType)
      end

      table.insert(graph.order, promotionType)
      -- `family` groups the ranks of one promotion (Shock I/II/III).  The
      -- layout treats it as an opaque token and only uses it to prefer keeping
      -- a chain on one row, which is what makes the tree read as lines.
      graph.nodes[promotionType] = {
        parents = keptParents,
        children = keptChildren,
        requiredPrereq = requiredOf[promotionType],
        orPrereqs = alternativesOf[promotionType],
        requiredParent = (
          requiredOf[promotionType]
          and member[requiredOf[promotionType]]
          and reachable[requiredOf[promotionType]]
        )
            and requiredOf[promotionType]
          or nil,
        orParents = keptOrParents,
        name = nameOf[promotionType],
        family = GetPromotionBase(promotionType, nameOf[promotionType]),
        -- Database order: base promotions come before unique-unit additions.
        id = tonumber(member[promotionType].ID),
      }
    end
  end

  graph.chains = BuildRankChains(graph)

  return graph
end

--
-- Rank chains
--
-- A shared base name is a hypothesis, not a chain.  VP files three unrelated
-- promotions under MARCH (March, Skirmisher March, Air Repair) and two under
-- SENTRY, and in both cases the later rank does not require the earlier one --
-- so grouping on the name alone would invent a chain that the game does not
-- have, and the layout would then try to keep it on one row.
--
-- A run is a chain only where consecutive ranks are actually parent and child
-- in this class's graph.  Anything else splits.  Returned in rank order, which
-- is the order the layout has to keep them monotone in.
--
function BuildRankChains(graph)
  local families = {}
  for i = 1, #graph.order do
    local promotionType = graph.order[i]
    local sBase = graph.nodes[promotionType].family
    families[sBase] = families[sBase] or {}
    table.insert(families[sBase], promotionType)
  end

  local bases = {}
  for sBase in pairs(families) do
    table.insert(bases, sBase)
  end
  table.sort(bases)

  local chains = {}
  for i = 1, #bases do
    local list = families[bases[i]]
    table.sort(list, function(a, b)
      local iA = GetPromotionRank(a, graph.nodes[a].name)
      local iB = GetPromotionRank(b, graph.nodes[b].name)
      if iA ~= iB then
        return iA < iB
      end
      return a < b
    end)

    local run = { list[1] }
    for j = 2, #list do
      local bLinked = false
      local parents = graph.nodes[list[j]].parents
      for k = 1, #parents do
        if parents[k] == list[j - 1] then
          bLinked = true
        end
      end

      if bLinked then
        table.insert(run, list[j])
      else
        if #run > 1 then
          table.insert(chains, run)
        end
        run = { list[j] }
      end
    end
    if #run > 1 then
      table.insert(chains, run)
    end
  end

  return chains
end
