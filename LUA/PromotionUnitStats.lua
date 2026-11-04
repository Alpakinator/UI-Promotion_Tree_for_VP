-- Promotion-tree unit statistics.
--
-- This module only reads game data and live-unit getters. It never grants a
-- promotion or mutates a unit. PromotionUnitStats.Build returns ordered,
-- presentation-ready sections; callers may render each row's value as Civ V
-- text (including its positive/negative color tags).
PromotionUnitStats = PromotionUnitStats or {}
local Stats = PromotionUnitStats

local PROMOTION_FIELDS = {
  "CombatChange",
  "CombatPercent",
  "AttackMod",
  "DefenseMod",
  "RangedAttackModifier",
  "RangedDefenseMod",
  "MovesChange",
  "RangeChange",
  "VisibilityChange",
  "ReconChange",
  "CityAttack",
  "CityDefense",
  "HillsAttack",
  "HillsDefense",
  "OpenAttack",
  "OpenDefense",
  "OpenRangedAttackMod",
  "OpenFromMod",
  "RoughFromMod",
  "RoughAttack",
  "RoughDefense",
  "RoughRangedAttackMod",
  "AttackFortifiedMod",
  "AttackWoundedMod",
  "AttackFullyHealedMod",
  "AttackAbove50HealthMod",
  "AttackBelowEqual50HealthMod",
  "FlankAttackModifier",
  "FriendlyLandsModifier",
  "FriendlyLandsAttackModifier",
  "OutsideFriendlyLandsModifier",
  "ExtraAttacks",
  "MultiAttackBonus",
  "ExtraWithdrawal",
  "EvasionChange",
  "InterceptChanceChange",
  "NumInterceptionChange",
  "AirInterceptRangeChange",
  "InterceptionCombatModifier",
  "InterceptionDefenseDamageModifier",
  "AirSweepCombatModifier",
  "ExtraFlankPower",
  "FlankSupportModifier",
  "FriendlyHealChange",
  "NeutralHealChange",
  "EnemyHealChange",
  "SameTileHealChange",
  "AdjacentTileHealChange",
  "FlatHealRate",
  "PassiveAoEHeal",
  "HPHealedIfDestroyEnemy",
  "GiveHPHealedIfEnemyKilled",
  "HealOnPillage",
  "PartialHealOnPillage",
  "VisibilityChange",
  "EmbarkExtraVisibility",
  "SeeThrough",
  "ReconChange",
  "MoveDiscountChange",
  "ExtraNavalMovement",
  "FreeAttackMoves",
  "AdjacentMod",
  "NoAdjacentUnitMod",
  "NearbyEnemyCombatMod",
  "NearbyEnemyCombatRange",
  "NearbyCityCombatMod",
  "NearbyFriendlyCityCombatMod",
  "NearbyEnemyCityCombatMod",
  "NearbyImprovementCombatBonus",
  "NearbyImprovementBonusRange",
  "CombatBonusFromNearbyUnitClass",
  "NearbyUnitClassBonusRange",
  "NearbyUnitClassBonus",
  "GreatGeneralCombatModifier",
  "CombatModPerCSAlliance",
  "CombatModPerLevel",
  "BarbarianCombatBonus",
  "VsUnhappyMod",
  "DamageTakenMod",
  "LandAirDefenseBonus",
  "FortifiedModifier",
  "EmbarkDefenseModifier",
  "CapitalDefenseModifier",
  "CapitalDefenseFalloff",
  "CityAttackPlunderModifier",
  "EnemyHealChange",
  "NeutralHealChange",
  "FriendlyHealChange",
  "EnemyDamage",
  "NeutralDamage",
  "EnemyDamageChance",
  "NeutralDamageChance",
  "HealIfDestroyExcludesBarbarians",
  "CanMoveAfterAttacking",
  "IgnoreTerrainCost",
  "HillsDoubleMove",
  "RiverDoubleMove",
  "River",
  "EnemyRoute",
  "RivalTerritory",
  "Amphib",
  "AllowsEmbarkation",
  "EmbarkedAllWater",
  "EmbarkedDeepWater",
  "RangeAttackIgnoreLOS",
  "AirSweepCapable",
  "Recon",
  "CanMoveAllTerrain",
  "IgnoreZOC",
  "AlwaysHeal",
  "HealOutsideFriendly",
  "CannotHeal",
  "OnlyDefensive",
  "NoDefensiveBonus",
  "IgnoreTerrainDamage",
  "IgnoreFeatureDamage",
  "ExtraTerrainDamage",
  "ExtraFeatureDamage",
  "CanMoveImpassable",
  "HeavyCharge",
  "Sapper",
  "Blitz",
  "CaptureDefeatedEnemy",
  "CanClaimGoody",
  "NoCapture",
  "NukeImmune",
  "CannotBeCaptured",
  "StrongerDamaged",
  "FightWellDamaged",
  "RequiresLeadership",
  "MaxHitPointsChange",
  "MaxHitPointsModifier",
  "ExperiencePercent",
  "ExtraXPOnKill",
  "XPFromPillaging",
  "GainsXPFromScouting",
  "GainsXPFromSpotting",
  "GiveExperiencePercent",
  "GreatGeneral",
  "GreatAdmiral",
  "CanCrossIce",
  "CanCrossMountains",
  "CanCrossOceans",
  "HoveringUnit",
  "SimpleHelpText",
}

local promotionRows
local linkedRows
-- Columns differ between DLL versions, and reading a missing one from a
-- GameInfo row logs "Cannot find key". Read only the columns rows have.
local presentFields
local function fieldsOf(row)
  if not presentFields then
    local columns = {}
    local listed = type(row) == "table"
      and pcall(function()
        for key in pairs(row) do
          columns[key] = true
        end
      end)
    if not listed or not columns.Type then
      return PROMOTION_FIELDS
    end
    presentFields = {}
    for i = 1, #PROMOTION_FIELDS do
      if columns[PROMOTION_FIELDS[i]] then
        presentFields[#presentFields + 1] = PROMOTION_FIELDS[i]
      end
    end
  end
  return presentFields
end
local function copyPromotion(row)
  if not row then
    return nil
  end
  local copy = {
    Type = row.Type,
    Description = row.Description,
    Help = row.Help,
    numericFields = {},
    enabledFields = {},
  }
  local fields = fieldsOf(row)
  for i = 1, #fields do
    local field = fields[i]
    local value = row[field]
    copy[field] = value
    local amount = tonumber(value)
    if amount and amount ~= 0 then
      copy.numericFields[field] = amount
    end
    if value == true or amount == 1 or value == "true" then
      copy.enabledFields[field] = true
    end
  end
  return copy
end

local LINKED_TABLES = {
  { name = "UnitPromotions_UnitCombatMods", kind = "combat", typeField = "UnitCombatType" },
  { name = "UnitPromotions_UnitClasses", kind = "class", typeField = "UnitClassType" },
  { name = "UnitPromotions_Domains", kind = "domain", typeField = "DomainType" },
  { name = "UnitPromotions_Terrains", kind = "terrain", typeField = "TerrainType" },
  { name = "UnitPromotions_Features", kind = "feature", typeField = "FeatureType" },
}

local function iterateGameInfo(tableValue)
  if type(tableValue) == "function" then
    return tableValue()
  end
  if type(tableValue) == "table" then
    local mt = getmetatable(tableValue)
    if mt and type(mt.__call) == "function" then
      return tableValue()
    end
  end
  return function()
    return nil
  end
end

local function loadMetadataOnce()
  if promotionRows then
    return
  end
  promotionRows, linkedRows = {}, {}
  local tableValue = GameInfo and GameInfo.UnitPromotions
  if tableValue then
    for row in iterateGameInfo(tableValue) do
      if row and row.Type then
        promotionRows[row.Type] = copyPromotion(row)
      end
    end
  end
  for i = 1, #LINKED_TABLES do
    local spec = LINKED_TABLES[i]
    linkedRows[spec.kind] = {}
    local rows = GameInfo and GameInfo[spec.name]
    if rows then
      for row in iterateGameInfo(rows) do
        if row and row.PromotionType then
          local bucket = linkedRows[spec.kind][row.PromotionType]
          if not bucket then
            bucket = {}
            linkedRows[spec.kind][row.PromotionType] = bucket
          end
          bucket[#bucket + 1] = {
            Type = row[spec.typeField],
            Modifier = row.Modifier or 0,
            Attack = row.Attack or 0,
            Defense = row.Defense or 0,
            DoubleMove = row.DoubleMove,
            Impassable = row.Impassable,
            ExtraMove = row.ExtraMove,
            HalfMove = row.HalfMove,
            IgnoreTerrainCostIn = row.IgnoreTerrainCostIn,
            IgnoreTerrainCostFrom = row.IgnoreTerrainCostFrom,
          }
        end
      end
    end
  end
end

local function lookupPromotion(promotionType)
  loadMetadataOnce()
  local row = promotionRows[promotionType]
  if row then
    return row
  end
  local source = GameInfo and GameInfo.UnitPromotions
  local direct = source and source[promotionType]
  if direct then
    row = copyPromotion(direct)
    if row and row.Type then
      promotionRows[row.Type] = row
    end
  end
  return row
end

local function numberOrZero(value)
  local n = tonumber(value)
  if n then
    return n
  end
  return 0
end

local function unitFieldOrZero(unit, field)
  return unit and numberOrZero(unit[field]) or 0
end

local function sortedPromotionTypes(set)
  local result, seen = {}, {}
  for key, value in pairs(set or {}) do
    local kind = type(key)
    local promotionType
    if kind == "string" and value then
      promotionType = key
    elseif kind == "number" and type(value) == "string" then
      promotionType = value
    elseif kind == "number" and type(value) == "table" then
      promotionType = value.Type
    end
    if promotionType and not seen[promotionType] then
      seen[promotionType] = true
      result[#result + 1] = promotionType
    end
  end
  table.sort(result)
  return result, seen
end

-- Each Build owns its sorted type arrays. Analyze their sparse promotion
-- data once, then reuse the sums across core, conditional and ability rows.
-- Addition for each field retains the original sorted promotion order.
local function summarizePromotions(types)
  if types.totals then
    return types.totals, types.enabled
  end
  local totals, enabled = {}, {}
  for i = 1, #types do
    local row = lookupPromotion(types[i])
    if row then
      for field, amount in pairs(row.numericFields) do
        totals[field] = (totals[field] or 0) + amount
      end
      for field in pairs(row.enabledFields) do
        enabled[field] = true
      end
    end
  end
  types.totals, types.enabled = totals, enabled
  return totals, enabled
end

local function promotionFieldTotal(types, field)
  local totals = summarizePromotions(types)
  return totals[field] or 0
end

local function readLiveNumber(live, method, ...)
  if not live or type(live[method]) ~= "function" then
    return nil
  end
  local ok, value = pcall(live[method], live, ...)
  if ok and tonumber(value) then
    return tonumber(value)
  end
  return nil
end

local function readLiveValue(live, method, ...)
  if not live or type(live[method]) ~= "function" then
    return nil
  end
  local ok, value = pcall(live[method], live, ...)
  if ok then
    return value
  end
  return nil
end

local function readLiveFlag(live, method)
  local value = readLiveValue(live, method)
  return value == true or tonumber(value) == 1
end

local function numberText(value)
  value = tonumber(value) or 0
  local rounded = math.floor(math.abs(value) * 10 + 0.5) / 10
  if math.abs(rounded - math.floor(rounded)) < 0.0001 then
    return tostring(math.floor(rounded))
  end
  return string.format("%.1f", rounded)
end

local function signedColor(value, suffix)
  value = tonumber(value) or 0
  local magnitude = math.floor(math.abs(value) * 10 + 0.5) / 10
  if magnitude == 0 then
    return nil
  end
  local color = value > 0 and "[COLOR_POSITIVE_TEXT]" or "[COLOR_NEGATIVE_TEXT]"
  local sign = value > 0 and "+" or "-"
  return "(" .. color .. sign .. numberText(magnitude) .. (suffix or "") .. "[ENDCOLOR])"
end

local function strengthValue(final, baseline)
  final = tonumber(final) or 0
  baseline = tonumber(baseline) or 0
  local result = numberText(final)
  if baseline ~= 0 then
    local percent = (final / baseline - 1) * 100
    local rounded = math.floor(math.abs(percent) * 10 + 0.5) / 10
    if percent < 0 then
      rounded = -rounded
    end
    local delta = signedColor(rounded, "%")
    if delta then
      result = result .. " " .. delta
    end
  end
  return result
end

local function changedValue(final, baseline, suffix)
  final = tonumber(final) or 0
  baseline = tonumber(baseline) or 0
  local result = numberText(final)
  local delta = signedColor(final - baseline, suffix)
  if delta then
    result = result .. " " .. delta
  end
  return result
end

-- Native text glyphs used by UnitPanel and VP promotion help.
-- Keep icons separate from labels so numeric tests and stat identity stay stable.
local STAT_ICONS = {
  ["Attack strength"] = "[ICON_STRENGTH]",
  ["Defense strength"] = "[ICON_STRENGTH]",
  ["Ranged strength"] = "[ICON_RANGE_STRENGTH]",
  ["Range"] = "[ICON_RANGE_STRENGTH]",
  ["Movement"] = "[ICON_MOVES]",
  ["Sight"] = "[ICON_VISION]",
  ["Sight range"] = "[ICON_VISION]",
  ["Sight range while embarked"] = "[ICON_VISION]",
  ["Recon range"] = "[ICON_VISION]",
  ["Can perform recon"] = "[ICON_VISION]",
  ["Ranged attack into open terrain"] = "[ICON_RANGE_STRENGTH]",
  ["Ranged attack into rough terrain"] = "[ICON_RANGE_STRENGTH]",
  ["Air sweep strength"] = "[ICON_RANGE_STRENGTH]",
  ["Movement when not embarked"] = "[ICON_MOVES]",
  ["Embarked movement"] = "[ICON_MOVES]",
  ["Movement cost reduction"] = "[ICON_MOVES]",
  ["Damage resistance"] = "[ICON_STRENGTH]",
  ["Against barbarians"] = "[ICON_STRENGTH]",
  ["Combat while unhappy"] = "[ICON_STRENGTH]",
  ["When stacked with a Great General"] = "[ICON_STRENGTH]",
  ["Repeated attack bonus"] = "[ICON_STRENGTH]",
  ["Flanking power"] = "[ICON_STRENGTH]",
  ["Flank support"] = "[ICON_STRENGTH]",
  ["Additional attacks per turn"] = "[ICON_STRENGTH]",
  ["Gold from city attacks"] = "[ICON_GOLD]",
  ["Military unit production"] = "[ICON_PRODUCTION]",
}
local function statisticIcon(section, label)
  if section.key == "details" then
    return nil
  end -- Help already contains native icons.
  if STAT_ICONS[label] then
    return STAT_ICONS[label]
  end
  if label:sub(1, 9) == "Movement:" then
    return "[ICON_MOVES]"
  end
  if section.key == "air" then
    return "[ICON_AIRSTRIKE_DEFENSE]"
  end
  if section.key == "mobility" then
    return "[ICON_MOVES]"
  end
  if
    section.key == "attack"
    or section.key == "defense"
    or section.key == "territory"
    or section.key == "conditional"
  then
    return "[ICON_STRENGTH]"
  end
end

local function addRow(section, label, value)
  if value ~= nil and value ~= "" then
    section.rows[#section.rows + 1] =
      { label = label, value = value, icon = statisticIcon(section, label) }
  end
end

-- Suppress zero-valued parameters, including core stats. Unknown previews
-- remain explicit; they must not be mistaken for a known zero.
local function addCoreStat(section, label, amount, formatted, unavailable)
  if unavailable or numberOrZero(amount) ~= 0 then
    addRow(section, label, unavailable and "Unavailable; see promotion details" or formatted)
  end
end

local function nonZero(value)
  return numberOrZero(value) ~= 0
end
local function isDatabaseTrue(value)
  return value == true or tonumber(value) == 1 or value == "true"
end
local function coloredPercentage(value)
  if not nonZero(value) then
    return nil
  end
  return signedColor(numberOrZero(value), "%")
end

local function combinedAttackDefense(attack, defense)
  attack, defense = numberOrZero(attack), numberOrZero(defense)
  if attack == 0 and defense == 0 then
    return nil
  end
  if attack == defense then
    return signedColor(attack, "%") .. " attack and defense"
  end
  local parts = {}
  if attack ~= 0 then
    parts[#parts + 1] = signedColor(attack, "%") .. " attack"
  end
  if defense ~= 0 then
    parts[#parts + 1] = signedColor(defense, "%") .. " defense"
  end
  return table.concat(parts, "; ")
end

local function sumForTypes(types, field)
  return promotionFieldTotal(types, field)
end

local function withHoveredPromotion(types, hoverType, held)
  if not hoverType or held[hoverType] then
    return types
  end
  local result = {}
  for i = 1, #types do
    result[i] = types[i]
  end
  result[#result + 1] = hoverType
  table.sort(result)
  return result
end

local function getInfo(tableName, typeName)
  local tableValue = GameInfo and GameInfo[tableName]
  if not tableValue or not typeName then
    return nil
  end
  local ok, row = pcall(function()
    return tableValue[typeName]
  end)
  if ok and row then
    return row
  end
  return nil
end

local function localizedDescription(tableName, typeName, fallback)
  local row = getInfo(tableName, typeName)
  local description = row and row.Description
  if description and Locale and Locale.ConvertTextKey then
    local ok, value = pcall(Locale.ConvertTextKey, description)
    if ok and value and value ~= "" and value ~= description then
      return value
    end
  end
  return description or fallback or tostring(typeName or "")
end

local function appendTargetSpecificEffects(section, kind, types)
  local byType = {}
  for i = 1, #types do
    local promoType = types[i]
    local rows = linkedRows[kind] and linkedRows[kind][promoType] or nil
    for j = 1, #(rows or {}) do
      local row = rows[j]
      local key = row.Type or "?"
      local value = byType[key]
        or {
          modifier = 0,
          attack = 0,
          defense = 0,
          doubleMove = false,
          impassable = false,
          extraMove = 0,
          halfMove = false,
        }
      value.modifier = value.modifier + numberOrZero(row.Modifier)
      value.attack = value.attack + numberOrZero(row.Attack)
      value.defense = value.defense + numberOrZero(row.Defense)
      value.doubleMove = value.doubleMove or isDatabaseTrue(row.DoubleMove)
      value.impassable = value.impassable or isDatabaseTrue(row.Impassable)
      value.extraMove = value.extraMove + numberOrZero(row.ExtraMove)
      value.halfMove = value.halfMove or isDatabaseTrue(row.HalfMove)
      byType[key] = value
    end
  end
  local ordered = {}
  for key in pairs(byType) do
    ordered[#ordered + 1] = key
  end
  table.sort(ordered)
  for i = 1, #ordered do
    local key = ordered[i]
    local value = byType[key]
    if value.modifier ~= 0 or value.attack ~= 0 or value.defense ~= 0 then
      local detail = combinedAttackDefense(value.attack, value.defense)
      if value.modifier ~= 0 then
        detail = detail and (signedColor(value.modifier, "%") .. " general; " .. detail)
          or signedColor(value.modifier, "%") .. " general"
      end
      local category = kind == "combat" and "UnitCombatInfos"
        or (
          kind == "class" and "UnitClasses"
          or (kind == "domain" and "Domains" or (kind == "terrain" and "Terrains" or "Features"))
        )
      local display = localizedDescription(category, key, key)
      local prefix = kind == "combat" and "Against "
        or (
          kind == "class" and "Against unit class "
          or (
            kind == "domain" and "Against domain "
            or (kind == "terrain" and "On " or "In feature ")
          )
        )
      addRow(section, prefix .. display, detail)
    end
    if kind == "terrain" or kind == "feature" then
      local movement = {}
      if value.doubleMove then
        movement[#movement + 1] = "movement cost halved"
      end
      if value.halfMove then
        movement[#movement + 1] = "movement cost doubled"
      end
      if value.impassable then
        movement[#movement + 1] = "cannot enter"
      end
      if value.extraMove ~= 0 then
        movement[#movement + 1] = "extra move " .. numberText(value.extraMove)
      end
      if #movement > 0 then
        local category = kind == "terrain" and "Terrains" or "Features"
        addRow(
          section,
          "Movement: " .. localizedDescription(category, key, key),
          table.concat(movement, ", ")
        )
      end
    end
  end
end

local ATTACK_CONDITIONS = {
  { "CityAttack", "Against cities" },
  { "HillsAttack", "Against targets on hills" },
  { "OpenAttack", "Against targets in open terrain" },
  { "RoughAttack", "Against targets in rough terrain" },
  { "AttackFortifiedMod", "Against fortified targets" },
  { "AttackWoundedMod", "Against wounded targets" },
  { "AttackFullyHealedMod", "Against fully healed targets" },
  { "AttackAbove50HealthMod", "Against targets above 50% HP" },
  { "AttackBelowEqual50HealthMod", "Against targets at or below 50% HP" },
  { "FriendlyLandsAttackModifier", "Attacking from friendly territory" },
  { "OpenRangedAttackMod", "Ranged attack against open-terrain targets" },
  { "RoughRangedAttackMod", "Ranged attack against rough-terrain targets" },
  { "OpenFromMod", "Ranged attack from open terrain" },
  { "RoughFromMod", "Ranged attack from rough terrain" },
}
local DEFENSE_CONDITIONS = {
  { "CityDefense", "In cities" },
  { "HillsDefense", "On hills" },
  { "OpenDefense", "In open terrain" },
  { "RoughDefense", "In rough terrain" },
  { "RangedDefenseMod", "When defending against ranged attacks" },
  { "FortifiedModifier", "While fortified" },
  { "EmbarkDefenseModifier", "While embarked" },
  { "CapitalDefenseModifier", "Near the capital" },
}

local function abilityText(row)
  if row and row.Help and row.Help ~= "" then
    if Locale and Locale.ConvertTextKey then
      local ok, value = pcall(Locale.ConvertTextKey, row.Help)
      if ok and value and value ~= "" and value ~= row.Help then
        return value
      end
    end
    return row.Help
  end
  return nil
end

local LIVE_CONDITION_GETTERS = {
  CityAttack = "CityAttackModifier",
  CityDefense = "CityDefenseModifier",
  HillsAttack = "HillsAttackModifier",
  HillsDefense = "HillsDefenseModifier",
  OpenAttack = "OpenAttackModifier",
  OpenDefense = "OpenDefenseModifier",
  OpenRangedAttackMod = "OpenRangedAttackModifier",
  RoughAttack = "RoughAttackModifier",
  RoughDefense = "RoughDefenseModifier",
  RoughRangedAttackMod = "RoughRangedAttackModifier",
  AttackFortifiedMod = "AttackFortifiedModifier",
  AttackWoundedMod = "AttackWoundedModifier",
  AttackFullyHealedMod = "AttackFullyHealedModifier",
  AttackAbove50HealthMod = "AttackAbove50Modifier",
  AttackBelowEqual50HealthMod = "AttackBelow50Modifier",
  FlankAttackModifier = "FlankAttackModifier",
  FriendlyLandsModifier = "GetFriendlyLandsModifier",
  FriendlyLandsAttackModifier = "GetFriendlyLandsAttackModifier",
  OutsideFriendlyLandsModifier = "GetOutsideFriendlyLandsModifier",
  RangedDefenseMod = "GetRangedDefenseModifier",
}

local function effectivePromotionField(live, heldTypes, heldMap, hover, field)
  local value
  local method = LIVE_CONDITION_GETTERS[field]
  if method then
    value = readLiveNumber(live, method)
  end
  if value == nil then
    value = promotionFieldTotal(heldTypes, field)
  end
  if hover and not heldMap[hover.Type] then
    value = value + numberOrZero(hover[field])
  end
  return value
end

local function currentPlayerAllyCount(live)
  if not live or not Players then
    return nil
  end
  local owner = readLiveNumber(live, "GetOwner")
  if owner == nil then
    return nil
  end
  local player = Players[owner]
  if not player or type(player.GetNumCSAllies) ~= "function" then
    return nil
  end
  if type(player.IsMinorCiv) == "function" then
    local ok, isMinor = pcall(player.IsMinorCiv, player)
    if ok and isMinor then
      return nil
    end
  end
  local ok, value = pcall(player.GetNumCSAllies, player)
  if ok and tonumber(value) then
    return tonumber(value)
  end
  return nil
end

local ABILITY_GROUPS = {
  healing = {
    title = "Healing",
    fields = {
      FriendlyHealChange = true,
      NeutralHealChange = true,
      EnemyHealChange = true,
      SameTileHealChange = true,
      AdjacentTileHealChange = true,
      FlatHealRate = true,
      PassiveAoEHeal = true,
      HPHealedIfDestroyEnemy = true,
      GiveHPHealedIfEnemyKilled = true,
      PartialHealOnPillage = true,
      HealOnPillage = true,
      AlwaysHeal = true,
      HealOutsideFriendly = true,
      CannotHeal = true,
    },
  },
  mobility = {
    title = "Mobility and vision",
    fields = {
      VisibilityChange = true,
      EmbarkExtraVisibility = true,
      ReconChange = true,
      ExtraNavalMovement = true,
      MoveDiscountChange = true,
      IgnoreTerrainCost = true,
      HillsDoubleMove = true,
      RiverDoubleMove = true,
      River = true,
      Amphib = true,
      CanMoveAfterAttacking = true,
      FreeAttackMoves = true,
      IgnoreZOC = true,
      EnemyRoute = true,
      RivalTerritory = true,
      AllowsEmbarkation = true,
      EmbarkedAllWater = true,
      EmbarkedDeepWater = true,
      CanMoveAllTerrain = true,
      CanCrossIce = true,
      CanCrossMountains = true,
      CanCrossOceans = true,
    },
  },
  air = {
    title = "Interception and air",
    fields = {
      EvasionChange = true,
      InterceptChanceChange = true,
      NumInterceptionChange = true,
      AirInterceptRangeChange = true,
      InterceptionCombatModifier = true,
      InterceptionDefenseDamageModifier = true,
      AirSweepCombatModifier = true,
      AirSweepCapable = true,
    },
  },
  experience = {
    title = "Experience",
    fields = {
      ExtraXPOnKill = true,
      XPFromPillaging = true,
      ExperiencePercent = true,
      GiveExperiencePercent = true,
      GainsXPFromScouting = true,
      GainsXPFromSpotting = true,
    },
  },
}

local function abilitySection(field)
  for key, group in pairs(ABILITY_GROUPS) do
    if group.fields[field] then
      return key, group.title
    end
  end
  return "abilities", "Other abilities"
end

local NUMERIC_ABILITIES = {
  { "VisibilityChange", "Sight range", " tiles" },
  { "EmbarkExtraVisibility", "Sight range while embarked", " tiles" },
  { "ReconChange", "Recon range", " tiles" },
  { "ExtraWithdrawal", "Withdrawal chance", "%" },
  { "EvasionChange", "Evasion chance", "%" },
  { "InterceptChanceChange", "Interception chance", "%" },
  { "NumInterceptionChange", "Interceptions per turn", "" },
  { "AirInterceptRangeChange", "Interception range", " tiles" },
  { "InterceptionCombatModifier", "Interception strength", "%" },
  { "InterceptionDefenseDamageModifier", "Interception damage", "%" },
  { "AirSweepCombatModifier", "Air sweep strength", "%" },
  { "FriendlyHealChange", "Healing in friendly territory", " HP" },
  { "NeutralHealChange", "Healing in neutral territory", " HP" },
  { "EnemyHealChange", "Healing in enemy territory", " HP" },
  { "SameTileHealChange", "Healing to units on this tile", " HP" },
  { "AdjacentTileHealChange", "Healing to adjacent units", " HP" },
  { "FlatHealRate", "Healing per turn", " HP" },
  { "PassiveAoEHeal", "Nearby unit healing", " HP" },
  { "HPHealedIfDestroyEnemy", "Heal after defeating an enemy", " HP" },
  { "GiveHPHealedIfEnemyKilled", "Heal nearby units after a kill", " HP" },
  { "PartialHealOnPillage", "Extra healing from pillaging", " HP" },
  { "ExtraAttacks", "Additional attacks per turn", "" },
  { "MovesChange", "Movement when not embarked", "" },
  { "ExtraNavalMovement", "Embarked movement", "" },
  { "MoveDiscountChange", "Movement cost reduction", " cost points" },
  { "CityAttackPlunderModifier", "Gold from city attacks", "%" },
  { "BarbarianCombatBonus", "Against barbarians", "%" },
  { "VsUnhappyMod", "Combat while unhappy", "%" },
  { "GreatGeneralCombatModifier", "When stacked with a Great General", "%" },
  { "MultiAttackBonus", "Repeated attack bonus", "% per attack" },
  { "ExtraXPOnKill", "Experience on kill", " XP" },
  { "XPFromPillaging", "Experience from pillaging", " XP" },
  { "ExperiencePercent", "Experience gained", "%" },
  { "GiveExperiencePercent", "Experience granted to nearby units", "%" },
  { "MilitaryProductionModifier", "Military unit production", "%" },
  { "ExtraFlankPower", "Flanking power", "%" },
  { "FlankSupportModifier", "Flank support", "%" },
}

local BOOLEAN_ABILITIES = {
  { "IgnoreTerrainCost", "Ignores terrain movement costs" },
  { "HillsDoubleMove", "Double movement on hills" },
  { "RiverDoubleMove", "No river movement penalty" },
  { "River", "No river attack penalty" },
  { "Amphib", "No amphibious attack penalty" },
  { "CanMoveAfterAttacking", "Can move after attacking" },
  { "FreeAttackMoves", "Attacking does not use movement" },
  { "IgnoreZOC", "Ignores zone of control" },
  { "EnemyRoute", "Uses enemy roads" },
  { "RivalTerritory", "Can enter rival territory" },
  { "AllowsEmbarkation", "Can embark" },
  { "EmbarkedAllWater", "Can cross all water while embarked" },
  { "EmbarkedDeepWater", "Can enter deep water" },
  { "RangeAttackIgnoreLOS", "Ranged attacks ignore line of sight" },
  { "AirSweepCapable", "Can sweep air units" },
  { "CanMoveAllTerrain", "Can move through all terrain" },
  { "CanCrossIce", "Can cross ice" },
  { "CanCrossMountains", "Can cross mountains" },
  { "CanCrossOceans", "Can cross oceans" },
  { "StrongerDamaged", "Gains strength when damaged" },
  { "FightWellDamaged", "Fights at full strength while damaged" },
  { "HeavyCharge", "Can use heavy charge" },
  { "Sapper", "Can sap city defenses" },
  { "CaptureDefeatedEnemy", "Can capture defeated units" },
  { "CannotBeCaptured", "Cannot be captured" },
  { "NukeImmune", "Immune to nuclear weapons" },
  { "NoCapture", "Cannot capture units" },
  { "Recon", "Can perform recon" },
  { "Blitz", "Can attack multiple times" },
  { "RangedFlankAttack", "Ranged attacks receive flanking bonuses" },
  { "HealOnPillage", "Fully heals on pillage" },
  { "CannotHeal", "Cannot heal" },
  { "AlwaysHeal", "Can heal every turn" },
  { "HealOutsideFriendly", "Can heal outside friendly territory" },
  { "GainsXPFromScouting", "Gains experience from scouting" },
  { "GainsXPFromSpotting", "Gains experience from spotting" },
  { "CanClaimGoody", "Can claim goody huts" },
}

-- Resolve the fixed field-to-section relationship once, not during hover.
for _, definitions in ipairs({ NUMERIC_ABILITIES, BOOLEAN_ABILITIES }) do
  for _, spec in ipairs(definitions) do
    spec.sectionKey, spec.sectionTitle = abilitySection(spec[1])
  end
end

local function appendAbilityRows(getSection, types)
  local totals, enabled = summarizePromotions(types)
  for i = 1, #NUMERIC_ABILITIES do
    local spec = NUMERIC_ABILITIES[i]
    local value = totals[spec[1]] or 0
    if value ~= 0 then
      local rendered = signedColor(value, spec[3])
      local key, title = spec.sectionKey, spec.sectionTitle
      addRow(getSection(key, title), spec[2], rendered)
    end
  end
  -- DamageTakenMod is added to incoming damage in CvUnit.cpp, so an inverse
  -- modifier is resistance and is shown as a positive benefit.
  local damageTaken = promotionFieldTotal(types, "DamageTakenMod")
  if damageTaken ~= 0 then
    addRow(
      getSection("abilities", "Other abilities"),
      "Damage resistance",
      signedColor(-damageTaken, "%")
    )
  end
  for i = 1, #BOOLEAN_ABILITIES do
    local spec = BOOLEAN_ABILITIES[i]
    if enabled[spec[1]] then
      local key, title = spec.sectionKey, spec.sectionTitle
      addRow(getSection(key, title), spec[2], "Yes")
    end
  end
end

local LIVE_SITUATIONAL_ROWS = {
  { "GetDamageCombatModifier", "Current unit damage", false },
  { "GetStrategicResourceCombatPenalty", "Strategic resource shortage" },
  { "GetUnhappinessCombatPenalty", "If the empire is unhappy" },
  { "GetStrengthThisTurnFromPreviousSamePromotionAttacks", "Repeated attacks this turn" },
  { "GetGiveCombatModToUnit", "Nearby promotion combat aura" },
  { "GetNearbyCityBonusCombatMod", "Nearby city modifier" },
  { "GetNearbyImprovementModifier", "Nearby improvement modifier" },
  { "GetAdjacentModifier", "With an adjacent friendly unit" },
  { "GetNoAdjacentUnitModifier", "With no adjacent friendly unit" },
  { "GetGreatGeneralCombatModifier", "When stacked with a Great General" },
}

local function appendLiveSituational(getSection, live, heldMap, hover)
  if not live then
    return
  end

  for i = 1, #LIVE_SITUATIONAL_ROWS do
    local spec = LIVE_SITUATIONAL_ROWS[i]
    local value
    if spec[3] == false then
      value = readLiveNumber(live, spec[1], false)
    else
      value = readLiveNumber(live, spec[1])
    end
    local unavailable = false
    if hover and not heldMap[hover.Type] then
      if spec[1] == "GetDamageCombatModifier" then
        local damage = readLiveNumber(live, "GetDamage") or 0
        unavailable = damage > 0
          and (isDatabaseTrue(hover.FightWellDamaged) or isDatabaseTrue(hover.StrongerDamaged))
      elseif spec[1] == "GetGiveCombatModToUnit" then
        unavailable = nonZero(hover.GiveCombatMod) or nonZero(hover.GiveDefenseMod)
      elseif spec[1] == "GetNearbyCityBonusCombatMod" then
        unavailable = nonZero(hover.NearbyCityCombatMod)
          or nonZero(hover.NearbyFriendlyCityCombatMod)
          or nonZero(hover.NearbyEnemyCityCombatMod)
      elseif spec[1] == "GetNearbyImprovementModifier" then
        unavailable = nonZero(hover.NearbyImprovementCombatBonus)
      elseif spec[1] == "GetStrengthThisTurnFromPreviousSamePromotionAttacks" then
        unavailable = nonZero(hover.AttackModPerSamePromotionAttack)
      end
      if spec[1] == "GetAdjacentModifier" then
        value = (value or 0) + numberOrZero(hover.AdjacentMod)
      end
      if spec[1] == "GetNoAdjacentUnitModifier" then
        value = (value or 0) + numberOrZero(hover.NoAdjacentUnitMod)
      end
      if spec[1] == "GetGreatGeneralCombatModifier" then
        value = (value or 0) + numberOrZero(hover.GreatGeneralCombatModifier)
      end
    end
    if unavailable or (value and value ~= 0) then
      addRow(
        getSection("conditional", "Conditional effects"),
        spec[2],
        unavailable and "Unavailable; see promotion details" or coloredPercentage(value)
      )
    end
  end
end

local function appendLevelAndAllianceRows(getSection, types, live)
  local perLevel = promotionFieldTotal(types, "CombatModPerLevel")
  local perAlly = promotionFieldTotal(types, "CombatModPerCSAlliance")
  local level = readLiveNumber(live, "GetLevel")
  local allies = currentPlayerAllyCount(live)
  local cap = numberOrZero(GameDefines and GameDefines.BALANCE_MAX_CS_ALLY_STRENGTH)
  if cap <= 0 then
    cap = 5
  end
  local section
  if perLevel ~= 0 then
    section = section or getSection("conditional", "Conditional effects")
    addRow(section, "Combat per additional level", coloredPercentage(perLevel))
    if level and level > 1 then
      addRow(section, "Current level-based combat bonus", coloredPercentage(perLevel * (level - 1)))
    end
  end
  if perAlly > 0 then
    section = section or getSection("conditional", "Conditional effects")
    addRow(section, "Combat per allied city-state", coloredPercentage(perAlly))
    if allies ~= nil then
      local amount = perAlly * math.min(allies, cap)
      addRow(section, "Current city-state alliance combat bonus", coloredPercentage(amount))
    end
  end
end

-- Return the displayed stats for a unit type, optional owned unit, held/plan
-- set, and optional hovered promotion. `heldSet` is a set keyed by promotion
-- Type (or an array of Types). A held/owned promotion is never applied twice.
function Stats.Build(unitDefinition, liveUnit, heldSet, hoveredPromotionType)
  if not unitDefinition then
    return {}
  end
  loadMetadataOnce()
  local heldTypes, heldPromotionSet = sortedPromotionTypes(heldSet)
  local previewTypes = withHoveredPromotion(heldTypes, hoveredPromotionType, heldPromotionSet)
  local hoveredDefinition = hoveredPromotionType
      and not heldPromotionSet[hoveredPromotionType]
      and lookupPromotion(hoveredPromotionType)
    or nil
  local orderedSections = {}
  local sectionByKey = {}
  local function getSection(key, title)
    if sectionByKey[key] then
      return sectionByKey[key]
    end
    local nextSection = { key = key, title = title, rows = {} }
    orderedSections[#orderedSections + 1] = nextSection
    sectionByKey[key] = nextSection
    return nextSection
  end
  local coreSection = getSection("core", "Core statistics")

  local baseCombatStrength = readLiveNumber(liveUnit, "GetBaseCombatStrength")
  if baseCombatStrength == nil then
    baseCombatStrength = unitFieldOrZero(unitDefinition, "Combat")
      + promotionFieldTotal(heldTypes, "CombatChange")
  end
  if hoveredDefinition then
    baseCombatStrength = baseCombatStrength + numberOrZero(hoveredDefinition.CombatChange)
  end

  local baseRangedStrength = readLiveNumber(liveUnit, "GetBaseRangedCombatStrength")
  if baseRangedStrength == nil then
    baseRangedStrength = unitFieldOrZero(unitDefinition, "RangedCombat")
  end

  local combatPercent = readLiveNumber(liveUnit, "GetExtraCombatPercent")
  if combatPercent == nil then
    combatPercent = promotionFieldTotal(heldTypes, "CombatPercent")
  end
  local attackModifier = readLiveNumber(liveUnit, "GetAttackModifier")
  if attackModifier == nil then
    attackModifier = promotionFieldTotal(heldTypes, "AttackMod")
  end
  local defenseModifier = readLiveNumber(liveUnit, "GetDefenseModifier")
  if defenseModifier == nil then
    defenseModifier = promotionFieldTotal(heldTypes, "DefenseMod")
  end
  local rangedAttack = readLiveNumber(liveUnit, "GetRangedAttackModifier")
  if rangedAttack == nil then
    rangedAttack = promotionFieldTotal(heldTypes, "RangedAttackModifier")
  end
  local rangedDefense = readLiveNumber(liveUnit, "GetRangedDefenseModifier")
  if rangedDefense == nil then
    rangedDefense = promotionFieldTotal(heldTypes, "RangedDefenseMod")
  end
  local promotionDefenseModifier = promotionFieldTotal(heldTypes, "DefenseMod")
  local otherDefenseModifier = defenseModifier - promotionDefenseModifier

  if hoveredDefinition then
    -- Level- and alliance-scaled values depend on current context and belong in
    -- the conditional section below. Do not fold them into the context-free
    -- strength row.
    combatPercent = combatPercent + numberOrZero(hoveredDefinition.CombatPercent)
    attackModifier = attackModifier + numberOrZero(hoveredDefinition.AttackMod)
    defenseModifier = defenseModifier + numberOrZero(hoveredDefinition.DefenseMod)
    rangedAttack = rangedAttack + numberOrZero(hoveredDefinition.RangedAttackModifier)
    rangedDefense = rangedDefense + numberOrZero(hoveredDefinition.RangedDefenseMod)
  end

  local unconditionalDefenseModifier = defenseModifier - otherDefenseModifier

  local definitionCombatStrength = unitFieldOrZero(unitDefinition, "Combat")
  local meleeAttackPercent = math.max(-90, combatPercent + attackModifier)
  local meleeDefensePercent = math.max(-90, combatPercent + unconditionalDefenseModifier)
  local meleeAttack = baseCombatStrength * (100 + meleeAttackPercent) / 100
  local meleeDefense = baseCombatStrength * (100 + meleeDefensePercent) / 100
  addCoreStat(
    coreSection,
    "Attack strength",
    meleeAttack,
    strengthValue(meleeAttack, definitionCombatStrength)
  )
  addCoreStat(
    coreSection,
    "Defense strength",
    meleeDefense,
    strengthValue(meleeDefense, definitionCombatStrength)
  )
  local definitionRangedStrength = unitFieldOrZero(unitDefinition, "RangedCombat")
  local rangedPercent = math.max(-90, combatPercent + attackModifier + rangedAttack)
  local rangedStrength = baseRangedStrength * (100 + rangedPercent) / 100
  addCoreStat(
    coreSection,
    "Ranged strength",
    rangedStrength,
    strengthValue(rangedStrength, definitionRangedStrength)
  )

  local baseRange = unitFieldOrZero(unitDefinition, "Range")
  local currentRange = readLiveNumber(liveUnit, "GetRange")
  if currentRange == nil then
    currentRange = baseRange + promotionFieldTotal(heldTypes, "RangeChange")
  end
  local finalRange = currentRange
    + (hoveredDefinition and numberOrZero(hoveredDefinition.RangeChange) or 0)
  addCoreStat(coreSection, "Range", finalRange, changedValue(finalRange, baseRange, ""))

  local baseMoves = unitFieldOrZero(unitDefinition, "Moves")
  local currentMoves
  local scaledMoves = readLiveNumber(liveUnit, "MaxMoves")
  local embarkedState = readLiveValue(liveUnit, "IsEmbarked")
  local embarked = embarkedState == true or tonumber(embarkedState) == 1
  if scaledMoves and scaledMoves > 0 then
    local denominator = numberOrZero(GameDefines and GameDefines.MOVE_DENOMINATOR)
    if denominator <= 0 then
      denominator = 60
    end
    currentMoves = scaledMoves / denominator
  else
    currentMoves = baseMoves + promotionFieldTotal(heldTypes, "MovesChange")
    if embarked then
      local embarkMoves = numberOrZero(GameDefines and GameDefines.EMBARKED_UNIT_MOVEMENT)
      if embarkMoves > 0 then
        currentMoves = embarkMoves + promotionFieldTotal(heldTypes, "ExtraNavalMovement")
      end
    end
  end
  local previewMovementChange = hoveredDefinition and numberOrZero(hoveredDefinition.MovesChange)
    or 0
  local previewEmbarkedMovementChange = hoveredDefinition
      and numberOrZero(hoveredDefinition.ExtraNavalMovement)
    or 0
  local movesWithGroup = readLiveFlag(liveUnit, "IsLinked") or readLiveFlag(liveUnit, "IsGrouped")
  local movementUnavailable = hoveredDefinition
    and movesWithGroup
    and (previewMovementChange ~= 0 or previewEmbarkedMovementChange ~= 0)
  if
    liveUnit
    and embarkedState == nil
    and (previewMovementChange ~= 0 or previewEmbarkedMovementChange ~= 0)
  then
    movementUnavailable = true
  end
  local finalMoves = currentMoves
  if embarked then
    finalMoves = finalMoves + previewEmbarkedMovementChange
  else
    finalMoves = finalMoves + previewMovementChange
  end
  addCoreStat(
    coreSection,
    "Movement",
    finalMoves,
    changedValue(finalMoves, baseMoves, ""),
    movementUnavailable
  )

  local baseSight = unitFieldOrZero(unitDefinition, "BaseSightRange")
  local sight = readLiveNumber(liveUnit, "visibilityRange")
    or readLiveNumber(liveUnit, "VisibilityRange")
  if sight == nil then
    sight = baseSight + promotionFieldTotal(heldTypes, "VisibilityChange")
  end
  local sightUnavailable = false
  if hoveredDefinition then
    local visibility = numberOrZero(hoveredDefinition.VisibilityChange)
    local embarkedVisibility = numberOrZero(hoveredDefinition.EmbarkExtraVisibility)
    if liveUnit and embarkedState == nil and (visibility ~= 0 or embarkedVisibility ~= 0) then
      sightUnavailable = true
    elseif embarked then
      sight = sight + embarkedVisibility
    else
      sight = sight + visibility
    end
  end
  addCoreStat(
    coreSection,
    "Sight",
    sight,
    changedValue(sight, baseSight, " tiles"),
    sightUnavailable
  )

  -- Keep live defense modifiers outside the supplied promotion set visible
  -- without guessing which source supplied them.
  if otherDefenseModifier ~= 0 then
    local conditional = sectionByKey.conditional or getSection("conditional", "Conditional effects")
    addRow(conditional, "Other current defense modifier", coloredPercentage(otherDefenseModifier))
  end

  local attackSection
  for i = 1, #ATTACK_CONDITIONS do
    local spec = ATTACK_CONDITIONS[i]
    local amount =
      effectivePromotionField(liveUnit, heldTypes, heldPromotionSet, hoveredDefinition, spec[1])
    if amount ~= 0 then
      attackSection = attackSection
        or sectionByKey.attack
        or getSection("attack", "Conditional attack effects")
      addRow(attackSection, spec[2], coloredPercentage(amount))
    end
  end
  local defenseSection
  for i = 1, #DEFENSE_CONDITIONS do
    local spec = DEFENSE_CONDITIONS[i]
    local amount =
      effectivePromotionField(liveUnit, heldTypes, heldPromotionSet, hoveredDefinition, spec[1])
    if amount ~= 0 then
      defenseSection = defenseSection or getSection("defense", "Conditional defense effects")
      addRow(defenseSection, spec[2], coloredPercentage(amount))
    end
  end
  local friendly = effectivePromotionField(
    liveUnit,
    heldTypes,
    heldPromotionSet,
    hoveredDefinition,
    "FriendlyLandsModifier"
  )
  local outside = effectivePromotionField(
    liveUnit,
    heldTypes,
    heldPromotionSet,
    hoveredDefinition,
    "OutsideFriendlyLandsModifier"
  )
  local friendlySection
  if friendly ~= 0 or outside ~= 0 then
    friendlySection = getSection("territory", "Territory effects")
    if friendly ~= 0 then
      addRow(friendlySection, "In friendly territory", coloredPercentage(friendly))
    end
    if outside ~= 0 then
      addRow(friendlySection, "Outside friendly territory", coloredPercentage(outside))
    end
  end
  do
    local conditionalSection = sectionByKey.conditional
      or getSection("conditional", "Conditional effects")
    appendTargetSpecificEffects(conditionalSection, "combat", previewTypes)
    appendTargetSpecificEffects(conditionalSection, "class", previewTypes)
    appendTargetSpecificEffects(conditionalSection, "domain", previewTypes)
    appendTargetSpecificEffects(conditionalSection, "terrain", previewTypes)
    appendTargetSpecificEffects(conditionalSection, "feature", previewTypes)
  end

  -- The native flank field is added to the game's per-adjacent-unit flanking
  -- amount; it is not a flat combat modifier. Keep its units explicit.
  local flank = effectivePromotionField(
    liveUnit,
    heldTypes,
    heldPromotionSet,
    hoveredDefinition,
    "FlankAttackModifier"
  )
  local flankBaseValue = GameDefines and tonumber(GameDefines.BONUS_PER_ADJACENT_FRIEND)
  local flankBase = numberOrZero(flankBaseValue)
  if flank ~= 0 or flankBase ~= 0 then
    local conditional = sectionByKey.conditional or getSection("conditional", "Conditional effects")
    if flankBaseValue then
      addRow(conditional, "Per adjacent flanking unit", signedColor(flankBase + flank, "%"))
    else
      addRow(conditional, "Flanking bonus modifier per adjacent unit", signedColor(flank, "%"))
    end
  end

  appendAbilityRows(getSection, previewTypes)
  appendLevelAndAllianceRows(getSection, previewTypes, liveUnit)
  appendLiveSituational(getSection, liveUnit, heldPromotionSet, hoveredDefinition)
  -- Native promotion help is retained for all held/previewed promotions. It
  -- covers secondary effects whose mechanics cannot be reduced to one number.
  local details
  for i = 1, #previewTypes do
    local row = lookupPromotion(previewTypes[i])
    local help = abilityText(row)
    if help then
      details = details or getSection("details", "Promotion details")
      local label = localizedDescription("UnitPromotions", previewTypes[i], previewTypes[i])
      addRow(details, label, help)
    end
  end

  -- Remove empty sections while preserving order. The core section is retained
  -- even for civilians, where its range and movement rows still apply.
  local nonemptySections = {}
  for i = 1, #orderedSections do
    local nextSection = orderedSections[i]
    if #nextSection.rows > 0 or nextSection.key == "core" then
      nonemptySections[#nonemptySections + 1] = nextSection
    end
  end
  return nonemptySections
end

return Stats
