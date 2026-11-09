-- Discover membership from the active database. The presentation taxonomy
-- names native combat roles; it never lists individual unit types.
PromotionClassCatalog = {}
local Catalog = PromotionClassCatalog
local discoveredProfiles, profilesByKey
local function isDatabaseTrue(value)
  return value == true or value == 1
end
local function translate(key)
  return key and Locale.ConvertTextKey(key) or ""
end
function Catalog.Name(key)
  local words = {}
  for word in translate(key):gmatch("%S+") do
    local lower = word:lower()
    if lower ~= "unit" and lower ~= "units" then
      words[#words + 1] = word
    end
  end
  return table.concat(words, " ")
end
function Catalog.Get(key)
  return profilesByKey and profilesByKey[key]
end

-- Unit-type capabilities, with the bonuses granted on creation. These tests
-- mirror CvUnit::canAcquirePromotion / isPromotionValid without consulting XP,
-- present technology, damage, movement spent, or current prerequisite readiness.
-- Such temporary state must not remove future branches from a promotion tree.
function Catalog.Capabilities(unit, freePromotions, promotions)
  local capabilities = {
    mounted = isDatabaseTrue(unit.IsMounted),
    range = unit.Range or 0,
    intercept = unit.AirInterceptRange or 0,
    moves = unit.Moves or 0,
    sweep = false,
    hover = false,
    evasion = 0,
    interceptChance = 0,
  }
  for key in pairs(freePromotions or {}) do
    local promotion = promotions and promotions[key]
    if promotion then
      capabilities.range = capabilities.range + (promotion.RangeChange or 0)
      capabilities.intercept = capabilities.intercept + (promotion.AirInterceptRangeChange or 0)
      capabilities.evasion = capabilities.evasion + (promotion.EvasionChange or 0)
      capabilities.interceptChance = capabilities.interceptChance
        + (promotion.InterceptChanceChange or 0)
      capabilities.sweep = capabilities.sweep or isDatabaseTrue(promotion.AirSweepCapable)
      capabilities.hover = capabilities.hover or isDatabaseTrue(promotion.HoveringUnit)
    end
  end
  return capabilities
end
function Catalog.Allows(row, capabilities)
  if isDatabaseTrue(row.MountedOnly) and not capabilities.mounted then
    return false
  end
  if (row.MinimumRangeRequired or 0) > capabilities.range then
    return false
  end
  if (row.MaximumRangeRequired or 0) > 0 and capabilities.range > row.MaximumRangeRequired then
    return false
  end
  if
    capabilities.intercept <= 0
    and (
      (row.InterceptChanceChange or 0) ~= 0
      or (row.InterceptionCombatModifier or 0) ~= 0
      or (row.NumInterceptionChange or 0) ~= 0
    )
  then
    return false
  end
  if isDatabaseTrue(row.Blitz) and capabilities.moves == 1 then
    return false
  end
  if (row.AirSweepCombatModifier or 0) ~= 0 and not capabilities.sweep then
    return false
  end
  if isDatabaseTrue(row.AllowsEmbarkation) and capabilities.hover then
    return false
  end
  if isDatabaseTrue(row.EmbarkedDeepWater) and not capabilities.hover then
    return false
  end
  local maxEvasion = tonumber(GameDefines and GameDefines.MAX_EVASION_PROBABILITY) or 90
  local maxIntercept = tonumber(GameDefines and GameDefines.MAX_INTERCEPTION_PROBABILITY) or 100
  if (row.EvasionChange or 0) > 0 and capabilities.evasion + row.EvasionChange > maxEvasion then
    return false
  end
  if
    (row.InterceptChanceChange or 0) > 0
    and capabilities.interceptChance + row.InterceptChanceChange > maxIntercept
  then
    return false
  end
  return true
end

function Catalog.ForUnit(unit, liveUnit)
  if not unit then
    return nil
  end
  local freePromotions = {}
  for row in DB.Query("SELECT PromotionType FROM Unit_FreePromotions WHERE UnitType = ?", unit.Type) do
    freePromotions[row.PromotionType] = true
  end
  local capabilities = Catalog.Capabilities(unit, freePromotions, GameInfo.UnitPromotions)
  if liveUnit then
    if liveUnit.IsMounted then
      capabilities.mounted = liveUnit:IsMounted()
    end
    if liveUnit.GetRange then
      capabilities.range = liveUnit:GetRange()
    end
    if liveUnit.GetAirInterceptRange then
      capabilities.intercept = liveUnit:GetAirInterceptRange()
    end
    if liveUnit.IsAirSweepCapable then
      capabilities.sweep = liveUnit:IsAirSweepCapable()
    end
    if liveUnit.IsHoveringUnit then
      capabilities.hover = liveUnit:IsHoveringUnit()
    end
  end
  return {
    CombatClass = unit.PromotionClass or unit.CombatClass,
    UnitType = unit.Type,
    Free = freePromotions,
    Capabilities = capabilities,
  }
end

local function promotionMembershipSignature(graph)
  local parts = { table.concat(graph.order, ";") }
  local external = {}
  for key in pairs(graph.externalSources) do
    external[#external + 1] = key
  end
  table.sort(external)
  parts[#parts + 1] = table.concat(external, ";")
  return table.concat(parts, "|")
end

-- Presentation-only vocabulary approved for the dropdown. Unknown combat
-- classes retain their translated game name and follow known families.
local COMBAT_ROLE_LABELS = {
  UNITCOMBAT_RECON = { 1, "RECON" },
  UNITCOMBAT_MELEE = { 2, "MELEE" },
  UNITCOMBAT_GUN = { 2, "GUNPOWDER" },
  UNITCOMBAT_ARCHER = { 3, "RANGED" },
  UNITCOMBAT_HELICOPTER = { 3, "HELICOPTER" },
  UNITCOMBAT_MOUNTED = { 4, "MOUNTED_MELEE" },
  UNITCOMBAT_ARMOR = { 5, "ARMOR" },
  UNITCOMBAT_SIEGE = { 6, "SIEGE" },
  UNITCOMBAT_NAVALMELEE = { 7, "NAVAL_MELEE" },
  UNITCOMBAT_NAVALRANGED = { 8, "NAVAL_RANGED" },
  UNITCOMBAT_CARRIER = { 9, "CARRIER" },
  UNITCOMBAT_SUBMARINE = { 10, "SUBMARINE" },
  UNITCOMBAT_FIGHTER = { 11, "FIGHTER" },
  UNITCOMBAT_BOMBER = { 12, "BOMBER" },
  UNITCOMBAT_MISSIONARY = { 13, "MISSIONARY" },
  UNITCOMBAT_DIPLOMACY = { 14, "DIPLOMACY" },
}
local function roleLabel(role)
  return translate("TXT_KEY_PROMOTREE_CLASS_" .. role)
end
local function assignProfileName(profile, data)
  local role = COMBAT_ROLE_LABELS[profile.CombatClass]
  profile.FamilyOrder = role and role[1] or 1000
  profile.FamilyKey = role and tostring(role[1]) or profile.CombatClass
  local label = role and role[2]
  if profile.CombatClass == "UNITCOMBAT_ARCHER" then
    if profile.Free.PROMOTION_HOVERING_UNIT or profile.Capabilities.hover then
      label = "HELICOPTER"
    elseif profile.Capabilities.mounted then
      label = "MOUNTED_RANGED"
    end
  elseif profile.CombatClass == "UNITCOMBAT_GUN" and profile.Capabilities.intercept > 0 then
    label = "ANTI_AIR"
  elseif profile.CombatClass == "UNITCOMBAT_NAVALMELEE" and profile.Capabilities.intercept > 0 then
    label = "NAVAL_MODERN"
  end
  profile.Name = label and roleLabel(label)
    or Catalog.Name(data.classes[profile.CombatClass].Description)
end
-- Entries that share a base name are told apart by data, not by a list of
-- known units. The entry with the most regular (buildable, non-gift) unit
-- types is the main one and keeps the plain name; every other entry is named
-- after the first word of its earliest unit in the tech tree ("Ranged —
-- Drone"). Colliding first words use the full unit name instead. `used`
-- holds every label already taken, so a variant never repeats another name.
local function nameVariants(peers, used)
  local function before(a, b)
    if a.RegularUnits ~= b.RegularUnits then
      return a.RegularUnits > b.RegularUnits
    end
    for i = 1, #a.EarliestOrder do
      if a.EarliestOrder[i] ~= b.EarliestOrder[i] then
        return a.EarliestOrder[i] < b.EarliestOrder[i]
      end
    end
    return a.Key < b.Key
  end
  local main = peers[1]
  for i = 2, #peers do
    if before(peers[i], main) then
      main = peers[i]
    end
  end
  local base, variants, wordOf, wordCount = main.Name, {}, {}, {}
  for _, profile in ipairs(peers) do
    if profile ~= main then
      local word = profile.EarliestUnitName:match("%S+") or profile.EarliestUnitName
      variants[#variants + 1] = profile
      wordOf[profile] = word
      wordCount[word] = (wordCount[word] or 0) + 1
    end
  end
  for _, profile in ipairs(variants) do
    local label = base .. " — " .. wordOf[profile]
    if wordCount[wordOf[profile]] > 1 or used[label] then
      label = base .. " — " .. profile.EarliestUnitName
    end
    local unique, copy = label, 2
    while used[unique] do
      unique, copy = label .. " " .. copy, copy + 1
    end
    profile.Name = unique
    used[unique] = true
  end
end

-- Graph eligibility depends on class, capabilities and starting grants, not
-- unit identity. Equal profiles within one immutable database snapshot share
-- extraction work. Different graph-relevant grants still receive distinct graphs;
-- flavor-only grants are ignored after their capability effects are computed.
local function graphEligibilityKey(profile, prerequisiteSources)
  local parts = {}
  for _, set in ipairs({ profile.Capabilities, profile.Free }) do
    local keys = {}
    for key in pairs(set) do
      if set ~= profile.Free or prerequisiteSources[key] then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local value = tostring(set[key])
      parts[#parts + 1] = #key .. ":" .. key .. #value .. ":" .. value
    end
    parts[#parts + 1] = ";"
  end
  return table.concat(parts)
end

-- Pure data seam used by the runtime reader and catalogue regression tests.
function Catalog.Build(data)
  local profilesBySignature, profiles, eligibilityGraphsByClass, prerequisiteSourcesByClass =
    {}, {}, {}, {}
  for class, rows in pairs(data.rows) do
    local graphSourceTypes = {}
    for _, row in ipairs(rows) do
      graphSourceTypes[row.Type] = true
      if row.PromotionPrereq then
        graphSourceTypes[row.PromotionPrereq] = true
      end
      for i = 1, 9 do
        local prerequisite = row["PromotionPrereqOr" .. i]
        if prerequisite then
          graphSourceTypes[prerequisite] = true
        end
      end
    end
    prerequisiteSourcesByClass[class] = graphSourceTypes
  end
  local defaults = {}
  for _, row in ipairs(data.unitClasses) do
    if row.DefaultUnit then
      defaults[row.DefaultUnit] = true
    end
  end
  local units, unitsByType = {}, {}
  for _, unit in ipairs(data.units) do
    units[#units + 1] = unit
    unitsByType[unit.Type] = unit
  end
  local function unitUnlockOrder(unit)
    local tech = data.technologies and data.technologies[unit.PrereqTech]
    local era = tech and data.eras and data.eras[tech.Era]
    return era and era.ID or -1, tech and tech.GridX or -1, tech and tech.Cost or 0
  end
  local function representativePreference(unit)
    -- Class defaults can also be gifts or rewards unavailable for production.
    if
      isDatabaseTrue(unit.MinorCivGift)
      or (unit.Cost or 0) < 0
      or (unit.PolicyType and unit.PolicyType ~= "")
    then
      return 2
    end
    return defaults[unit.Type] and 0 or 1
  end
  table.sort(units, function(a, b)
    local firstPreference, secondPreference =
      representativePreference(a), representativePreference(b)
    if firstPreference ~= secondPreference then
      return firstPreference < secondPreference
    end
    local firstEra, firstTechColumn, firstTechCost = unitUnlockOrder(a)
    local secondEra, secondTechColumn, secondTechCost = unitUnlockOrder(b)
    if firstEra ~= secondEra then
      return firstEra < secondEra
    end
    if firstTechColumn ~= secondTechColumn then
      return firstTechColumn < secondTechColumn
    end
    if firstTechCost ~= secondTechCost then
      return firstTechCost < secondTechCost
    end
    if not not defaults[a.Type] ~= not not defaults[b.Type] then
      return defaults[a.Type] == true
    end
    local firstUnitCost, secondUnitCost = a.Cost or -1, b.Cost or -1
    if firstUnitCost < 0 then
      firstUnitCost = math.huge
    end
    if secondUnitCost < 0 then
      secondUnitCost = math.huge
    end
    if firstUnitCost ~= secondUnitCost then
      return firstUnitCost < secondUnitCost
    end
    return a.Type < b.Type
  end)
  for _, unit in ipairs(units) do
    local combatClass = unit.PromotionClass or unit.CombatClass
    if combatClass and unit.CombatClass and data.classes[combatClass] then
      local freePromotions = data.free[unit.Type] or {}
      local profile = {
        CombatClass = combatClass,
        UnitType = unit.Type,
        UnitTypes = { unit.Type },
        Free = freePromotions,
        Capabilities = Catalog.Capabilities(unit, freePromotions, data.promotions),
        Rows = data.rows[combatClass] or {},
      }
      local graphsByEligibility = eligibilityGraphsByClass[combatClass]
      if not graphsByEligibility then
        graphsByEligibility = {}
        eligibilityGraphsByClass[combatClass] = graphsByEligibility
      end
      local key = graphEligibilityKey(profile, prerequisiteSourcesByClass[combatClass] or {})
      local graph = graphsByEligibility[key]
      if not graph then
        graph = BuildPromotionGraph(combatClass, nil, profile)
        graphsByEligibility[key] = graph
      end
      if #graph.order > 0 then
        local signature = combatClass .. "|" .. promotionMembershipSignature(graph)
        local matchingProfile = profilesBySignature[signature]
        if matchingProfile then
          matchingProfile.UnitTypes[#matchingProfile.UnitTypes + 1] = unit.Type
          -- Icon preference must not change the family's earliest unlock.
          local candidate = { unitUnlockOrder(unit) }
          for i = 1, 3 do
            if candidate[i] ~= matchingProfile.Timeline[i] then
              if candidate[i] < matchingProfile.Timeline[i] then
                matchingProfile.Timeline = candidate
              end
              break
            end
          end
          -- The shared class planner starts with only grants common to the
          -- whole group; unique free ranks remain visible in particular-unit mode.
          for key in pairs(matchingProfile.Free) do
            if not freePromotions[key] then
              matchingProfile.Free[key] = nil
            end
          end
        else
          profile.Free = {}
          for key in pairs(freePromotions) do
            profile.Free[key] = true
          end
          profile.Allowed = {}
          for _, key in ipairs(graph.order) do
            profile.Allowed[key] = true
          end
          profile.Key = combatClass .. "|" .. unit.Type
          profile.Timeline = { unitUnlockOrder(unit) }
          profile.Name = Catalog.Name(data.classes[combatClass].Description)
          profile.Graph = graph
          profilesBySignature[signature] = profile
          profiles[#profiles + 1] = profile
        end
      end
    end
  end
  local profilesByName = {}
  for _, profile in ipairs(profiles) do
    -- Membership was appended in representative preference / unlock order.
    -- Describe standard units when present; special-only groups retain their
    -- own endpoints. This is a span of members, not a claimed upgrade chain.
    local first = unitsByType[profile.UnitType]
    local last = first
    for _, key in ipairs(profile.UnitTypes) do
      local unit = unitsByType[key]
      if representativePreference(unit) == representativePreference(first) then
        last = unit
      end
    end
    profile.FirstUnitType, profile.LastUnitType = first.Type, last.Type
    local firstName, lastName = translate(first.Description), translate(last.Description)
    profile.UnitRange = firstName == lastName and firstName or firstName .. " - " .. lastName
    -- A variant is named after the unit a player meets first in the tech
    -- tree. Gifts, policy and unbuildable units count only if nothing else does.
    local earliest, earliestOrder, regularUnits = nil, nil, 0
    for _, key in ipairs(profile.UnitTypes) do
      local unit = unitsByType[key]
      local special = representativePreference(unit) == 2
      if not special then
        regularUnits = regularUnits + 1
      end
      local order = { special and 1 or 0, unitUnlockOrder(unit) }
      local earlier = not earliestOrder
      if not earlier then
        for i = 1, 4 do
          if order[i] ~= earliestOrder[i] then
            earlier = order[i] < earliestOrder[i]
            break
          end
        end
      end
      if earlier then
        earliest, earliestOrder = unit, order
      end
    end
    profile.EarliestUnitName = Catalog.Name(earliest.Description)
    profile.EarliestOrder, profile.RegularUnits = earliestOrder, regularUnits
    profile.Graph = BuildPromotionGraph(profile.CombatClass, nil, profile)
    assignProfileName(profile, data)
    profilesByName[profile.Name] = profilesByName[profile.Name] or {}
    table.insert(profilesByName[profile.Name], profile)
  end
  local names, used = {}, {}
  for name in pairs(profilesByName) do
    names[#names + 1] = name
    used[name] = true
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if #profilesByName[name] > 1 then
      nameVariants(profilesByName[name], used)
    end
  end
  table.sort(profiles, function(a, b)
    if a.FamilyOrder ~= b.FamilyOrder then
      return a.FamilyOrder < b.FamilyOrder
    end
    if a.FamilyKey ~= b.FamilyKey then
      return a.FamilyKey < b.FamilyKey
    end
    for i = 1, 3 do
      if a.Timeline[i] ~= b.Timeline[i] then
        return a.Timeline[i] < b.Timeline[i]
      end
    end
    if a.Name ~= b.Name then
      return a.Name < b.Name
    end
    return a.Key < b.Key
  end)
  -- Within each family, walk the most similar obtainable promotion sets.
  -- Begin with its earliest unlock; the chronological sort above breaks ties.
  -- Jaccard similarity treats missing and additional branches symmetrically.
  local orderedProfiles = {}
  while #profiles > 0 do
    local current = table.remove(profiles, 1)
    orderedProfiles[#orderedProfiles + 1] = current
    while true do
      local closestIndex, closestSimilarity = nil, -1
      for i, candidate in ipairs(profiles) do
        if candidate.FamilyKey == current.FamilyKey then
          local intersection, union = 0, #current.Graph.order
          for _, key in ipairs(candidate.Graph.order) do
            if current.Graph.nodes[key] then
              intersection = intersection + 1
            else
              union = union + 1
            end
          end
          local score = union == 0 and 1 or intersection / union
          if score > closestSimilarity then
            closestIndex, closestSimilarity = i, score
          end
        end
      end
      if not closestIndex then
        break
      end
      current = table.remove(profiles, closestIndex)
      orderedProfiles[#orderedProfiles + 1] = current
    end
  end
  return orderedProfiles
end

function Catalog.List()
  if discoveredProfiles then
    return discoveredProfiles
  end
  local data = {
    units = {},
    unitClasses = {},
    classes = {},
    free = {},
    promotions = {},
    rows = {},
    technologies = {},
    eras = {},
  }
  for row in DB.Query("SELECT * FROM Technologies") do
    data.technologies[row.Type] = row
  end
  for row in DB.Query("SELECT * FROM Eras") do
    data.eras[row.Type] = row
  end
  for row in DB.Query("SELECT * FROM UnitCombatInfos ORDER BY ID") do
    data.classes[row.Type] = row
  end
  for row in DB.Query("SELECT * FROM Units ORDER BY Type") do
    data.units[#data.units + 1] = row
  end
  for row in DB.Query("SELECT * FROM UnitClasses") do
    data.unitClasses[#data.unitClasses + 1] = row
  end
  for row in DB.Query("SELECT * FROM UnitPromotions") do
    data.promotions[row.Type] = row
  end
  for row in DB.Query("SELECT UnitType, PromotionType FROM Unit_FreePromotions") do
    data.free[row.UnitType] = data.free[row.UnitType] or {}
    data.free[row.UnitType][row.PromotionType] = true
  end
  for class in pairs(data.classes) do
    data.rows[class] = PromotionGraphFetchRows(class)
  end
  discoveredProfiles = Catalog.Build(data)
  profilesByKey = {}
  for _, profile in ipairs(discoveredProfiles) do
    profilesByKey[profile.Key] = profile
  end
  return discoveredProfiles
end
