-- luacheck config. Run it through `python3 scripts/checks.py` (the pre-commit hook does):
-- that adds the mod's own cross-file globals (top-level definitions in LUA/ and UI/, which
-- share one environment through include()) and fails only on warnings a change adds.
-- Plain `luacheck LUA UI` reports those globals as undefined.

std = "lua51+civ" -- Civ V runs Lua 5.1
max_line_length = false
unused_args = false -- engine callbacks have fixed signatures
ignore = {
  "6..", -- whitespace and indentation
}

-- The engine's Lua environment, from Vox Populi's .luacheckrc (stds.CIV,
-- sourced there from CvGameCoreDLL, Civ5XP and LuaCATS).
stds.civ = {
  read_globals = {
    "Game", "Map", "Players", "Teams",
    "ContextPtr", "Controls", "Events", "LuaEvents",
    "ContentManager", "DB", "GameDefines", "GameInfo",
    "Locale", "Matchmaking", "Modding", "Network",
    "OptionsManager", "Path", "Steam", "UI",
    "ExposedMembers", "ExposedTypes",
    "GameCore", "GameEventFactory", "GameEvents",
    "LuaEventFactory", "PreGame",
    "UIManager", "TTManager",
    "Fractal", "GameInfoActions", "GameInfoTypes",
    "AccomplishmentTypes", "ActionSubTypes", "ActivityTypes",
    "AdvisorTypes", "AggressivePostureTypes",
    "BeliefTypes", "ButtonPopupTypes",
    "ChatTargetTypes", "CityAIFocusTypes", "CityUpdateTypes",
    "CivApproachTypes", "CivOpinionTypes", "CombatPredictionTypes",
    "CommandTypes", "ContractTypes", "ControlTypes", "CoopWarStates",
    "CorporationTypes", "DiploUIStateTypes", "DirectionTypes",
    "DisputeLevelTypes", "DomainTypes", "EndTurnBlockingTypes",
    "FaithPurchaseTypes", "FeatureTypes", "FlowDirectionTypes",
    "FogOfWarModeTypes", "FromUIDiploEventTypes",
    "GameMessageTypes", "GameOptionTypes", "GameStates",
    "GameplayGameStateTypes", "GenericWorldAnchorTypes",
    "InfluenceLevelTrend", "InfluenceLevelTypes",
    "InstantYieldType", "InterfaceDirtyBits", "InterfaceModeTypes",
    "LeaderheadAnimationTypes", "MajorCivApproachTypes",
    "MinorCivPersonalityTypes", "MinorCivQuestTypes",
    "MinorCivTraitTypes", "MissionTypes", "NotificationTypes",
    "OrderTypes", "PeaceTreatyTypes", "PlotTypes",
    "PolicyBranchTypes", "PublicOpinionTypes", "ReligionTypes",
    "ResolutionDecisionTypes", "ResourceUsageTypes",
    "RoutePlanTypes",
    "StrengthTypes", "TaskTypes", "TerraformingEventTypes",
    "TerrainTypes", "ThreatTypes", "TradeConnectionTypes",
    "TradeableItems", "YieldTypes",
    "ButtonStates", "ContentType", "EndGameTypes",
    "GameStateTypes", "GameTypes", "GameViewTypes",
    "InfoCornerID", "KeyEvents", "Keys",
    "Mouse", "MouseEvents", "MultiplayerLobbyMode",
    "NetErrors", "NetKicked",
    "PopupPriorities", "PopupPriority",
    "SlotClaim", "SlotStatus",
    "SystemUpdateUIType", "YieldDisplayTypes",
    "GridToWorld", "HexToWorld", "HexVertexToWorld",
    "ToGridFromHex", "ToHexFromGrid",
    "InStrategicView", "IsGameCoreBusy",
    "TruncateString", "LookUpControl", "IsNull",
    "IncludeFileList", "RefreshIncludeFileList",
    "Profiler", "Automation", "FLua",
    math = { fields = { "clamp" } },
    table = { fields = { "fill", "count" } },
    "GenerationalInstanceManager",
    "Vector2", "Vector3", "Vector4", "Color",
    "VecAdd", "VecSub", "VecSubtract",
    -- base game IconSupport.lua (include("IconSupport"))
    "IconHookup", "CivIconHookup", "SimpleCivIconHookup",
  },
  globals = {
    "include", "InstanceManager", "MapModData",
  },
}
