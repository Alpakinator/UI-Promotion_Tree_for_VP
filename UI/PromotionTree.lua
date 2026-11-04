-- Expanded edition: Alpakinator, vibe-coded with GPT-6.1 Sol.

print("This is the 'UI - Promotion Tree' mod script.")

include("IconSupport")
include("InstanceManager")

bDebug = false
ClassMode = false

include("DebugPrint")
include("ControlUtils")
include("ButtonManager")
include("PipeManager")
include("PromotionUtils")
include("PromotionClassCatalog")
include("PromotionTreeStoredRows")
include("PromotionTreeLayout")
include("PromotionReviewedLayouts")
include("PromotionPresentation")
include("PromotionHover")
include("SidebarCard")
include("PromotionClassPlanner")
include("PromotionExtraPromotions")
include("PromotionUnitStats")
include("PromotionStatsPanel")

-- PANEL provides a fallback when screen dimensions are unavailable. PIPE is
-- retained for manager initialization; routes use measured native atlas pieces.
local config = {
  normal = { NAME = "Normal", PANEL = 900, PIPE = 8, BUTTON = "ButtonInstance" },
  small = { NAME = "Small", PANEL = 768, PIPE = 8, BUTTON = "ButtonInstanceSmall" },
}
local panelHeight = nil
local sidebarCenterY = nil

local sidebarLeftMargin = 20
local panelTopMargin = 20
local sidebarWidth = 250

local classCardWidth = 246
local classCardHeight = 64
local selectedClassIndex = 0

local unitCardWidth = 246
local unitCardHeight = 128
local unitPortraitSize = 128

local promotionCardWidth = nil
local promotionCardHeight = nil

local selectedUnitID = nil
local isTreeVisible = false
local plansByClassKey = {}
local activeClassPlan, activeClassKey, plannedPromotionStates = nil, nil, nil
local otherPromotionManager = nil
local inspectedUnit = nil
local heldPromotions = nil
local statsPanel = nil
local UpdateUnitStats

local hoverGraph, cardsByPromotionType, relatedPromotionsByType, hoveredPromotionType =
  nil, {}, {}, nil

local function ResetPromotionHover(graph)
  hoverGraph, cardsByPromotionType, relatedPromotionsByType, hoveredPromotionType =
    graph, {}, {}, nil
end

local function HighlightPromotionRelations(promotionType)
  if not hoverGraph then
    return
  end
  local related = nil
  if promotionType then
    related = relatedPromotionsByType[promotionType]
    if not related then
      related = PromotionHoverRelated(hoverGraph, promotionType)
      relatedPromotionsByType[promotionType] = related
    end
  end
  for name, button in pairs(cardsByPromotionType) do
    ButtonManagerSetHighlight(button, related and related[name] or false, name == promotionType)
  end
  local focusedEdges = nil
  if promotionType then
    focusedEdges = {}
    local node = hoverGraph.nodes[promotionType]
    if node then
      for _, parent in ipairs(node.parents or {}) do
        focusedEdges[parent .. "\001" .. promotionType] = true
      end
      for _, child in ipairs(node.children or {}) do
        focusedEdges[promotionType .. "\001" .. child] = true
      end
    end
  end
  PipeManagerHighlightEdges(focusedEdges)
  hoveredPromotionType = promotionType
  if UpdateUnitStats then
    UpdateUnitStats(promotionType)
  end
end

local function UpdateExperienceControls(liveUnit)
  local label = Controls.PromotionExperienceLabel
  local boxHeight = liveUnit and unitCardHeight or classCardHeight
  -- Align XP with each name area and its native frame's top edge.
  local frameTop = liveUnit and 16 or 5
  -- Bottom-anchor the text three pixels above the visible frame.
  Controls.PromotionExperienceBox:SetSizeVal(liveUnit and 112 or 150, 28)
  Controls.PromotionExperienceBox:SetOffsetVal(
    sidebarLeftMargin + (liveUnit and 132 or 62),
    sidebarCenterY - boxHeight / 2 + frameTop - 3 - 28
  )
  if liveUnit then
    local xp = liveUnit.GetExperience and liveUnit:GetExperience() or 0
    local nextXP = liveUnit.ExperienceNeeded and liveUnit:ExperienceNeeded()
    label:SetText(nextXP and ("XP: " .. xp .. " / " .. nextXP) or ("XP: " .. xp))
    Controls.ResetClassPlanButton:SetHide(true)
  else
    local xp = PromotionClassPlanner.ExperienceForPlan(activeClassPlan)
    label:SetText("XP needed: " .. xp)
    -- Keep Reset beside Close. Below the enlarged class card it collides
    -- with the sidebar legend on short screens.
    Controls.ResetClassPlanButton:SetOffsetVal(sidebarLeftMargin + 110, 100)
    Controls.ResetClassPlanButton:SetHide(false)
  end
  label:SetHide(false)
end

local function DrawExtraPromotionPanel(liveUnit, graph)
  if otherPromotionManager then
    otherPromotionManager:ResetInstances()
  end
  Controls.ExtraPromotionsPanel:SetHide(true)
  Controls.Legend:SetHide(false)
  if not liveUnit then
    return
  end
  local entries = PromotionExtraPromotions(liveUnit, graph)
  if #entries == 0 then
    return
  end

  local top = sidebarCenterY + unitCardHeight / 2 + 20
  local legendTop = Controls.ScrollPanel:GetSizeY() - 68 - 150
  local available = legendTop - top - 12
  if available < 96 then
    -- On a short screen the list takes the legend's sidebar slot. The tree
    -- viewport and promotion coordinates remain exactly the same.
    Controls.Legend:SetHide(true)
    available = Controls.ScrollPanel:GetSizeY() - top - 20
  end
  local height = math.max(72, math.min(240, available))
  Controls.ExtraPromotionsPanel:SetOffsetVal(sidebarLeftMargin, top)
  Controls.ExtraPromotionsPanel:SetSizeVal(230, height)
  -- The slider sits outside the ScrollPanel's right edge. Reserve its width
  -- inside the 230px frame while keeping the 198px promotion cards intact.
  Controls.ExtraPromotionsScroll:SetSizeVal(198, height - 39)
  Controls.ExtraPromotionsScrollBar:SetSizeY(math.max(24, height - 75))
  if not otherPromotionManager then
    otherPromotionManager =
      InstanceManager:new("ExtraPromotionInstance", "Button", Controls.ExtraPromotionsStack)
  end
  for _, entry in ipairs(entries) do
    local item = otherPromotionManager:GetInstance()
    item.Name:SetText(entry.Name)
    item.Name:SetTruncateWidth(143)
    item.Button:SetToolTipString(entry.Tooltip)
    item.PortraitFrame:SetHide(
      IconHookup(entry.PortraitIndex, 45, entry.IconAtlas, item.Portrait) ~= true
    )
  end
  Controls.ExtraPromotionsStack:CalculateSize()
  Controls.ExtraPromotionsStack:ReprocessAnchoring()
  Controls.ExtraPromotionsScroll:CalculateInternalSize()
  Controls.ExtraPromotionsPanel:SetHide(false)
end

local usesLargeCards = false

function PlaceDropDown()
  DrawPromotionDropDown(sidebarLeftMargin, sidebarCenterY - (classCardHeight / 2))

  AdjustClassGroupWidth(sidebarWidth)

  OnSelectCombatClass(selectedClassIndex)
end

function PlaceUnit(liveUnit)
  local unitCardX = sidebarLeftMargin
  local unitCardY = sidebarCenterY - (unitCardHeight / 2)
  DrawUnitBox(unitCardX, unitCardY, liveUnit)

  AdjustClassGroupWidth(sidebarWidth)

  local combatClass = nil
  local unitType = GameInfo.Units[liveUnit:GetUnitType()]

  if unitType.PromotionClass then
    combatClass = unitType.PromotionClass
  elseif liveUnit:GetUnitCombatType() >= 0 then
    combatClass = GameInfo.UnitCombatInfos[liveUnit:GetUnitCombatType()].Type
  else
    print(
      string.format(
        "Unit %i (%s) isn't eligible for any promotions",
        liveUnit:GetID(),
        unitType.Type
      )
    )
  end

  PlacePromotions(liveUnit, combatClass, unitCardX + unitCardWidth, sidebarCenterY)
end

-- The toolbar stays at native size. Only the complete promotion diagram is
-- fitted to its default viewport, using at most 150% proportional logical area.
-- Measure the actual viewport, never the enlarged content box. The archived
-- 900/768 PANEL constants are fallbacks, not a license to allocate more space.
local lastViewportReport = nil
function ResolvePromotionViewport()
  local originX = sidebarLeftMargin + sidebarWidth
  local originY = panelTopMargin + 20
  local panelW = Controls.ScrollPanel:GetSizeX()
  local panelH = Controls.ScrollPanel:GetSizeY()
  local ok, screenW, screenH = pcall(function()
    return UIManager:GetScreenSizeVal()
  end)
  if ok and type(screenW) == "number" and screenW > 0 then
    panelW = math.min(panelW, screenW)
  end
  if ok and type(screenH) == "number" and screenH > 0 then
    panelH = math.min(panelH, screenH)
  end
  return {
    x = originX,
    y = originY,
    width = math.max(1, panelW - originX - 20),
    height = math.max(1, panelH - originY - 2 * panelTopMargin),
    panelW = panelW,
    panelH = panelH,
  }
end

function PlacePromotions(liveUnit, classKey, sourceX, sourceY)
  local perfClock = os and os.clock
  local perfStart = perfClock and perfClock()
  local currentConfig = usesLargeCards and config.normal or config.small
  if panelHeight ~= ResolvePanelHeight(currentConfig) then
    Resize(currentConfig)
  end
  ResetPromotionHover(nil)
  ButtonManagerReset()
  PipeManagerReset()
  Controls.LayoutStatus:SetHide(true)
  local graphStart = perfClock and perfClock()
  local graph = BuildPromotionGraph(classKey, liveUnit)
  inspectedUnit = liveUnit
  heldPromotions = nil
  if liveUnit then
    activeClassPlan, activeClassKey, plannedPromotionStates = nil, nil, nil
  else
    activeClassKey = classKey
    if not plansByClassKey[classKey] then
      plansByClassKey[classKey] = PromotionClassPlanner.New(graph)
    end
    activeClassPlan = plansByClassKey[classKey]
    plannedPromotionStates = PromotionClassPlanner.States(activeClassPlan)
  end
  UpdateExperienceControls(liveUnit)
  DrawExtraPromotionPanel(liveUnit, graph)
  if UpdateUnitStats then
    UpdateUnitStats(nil)
  end
  local graphSeconds = perfClock and perfClock() - graphStart
  local layoutSeconds, drawSeconds, cacheHit = nil, nil, nil
  local layoutMethod, canvasWidth = "none", 0
  local viewport = ResolvePromotionViewport()
  local originX, originY = viewport.x, viewport.y
  local viewportW, viewportH = viewport.width, viewport.height
  local report = string.format(
    "panel %dx%d; promotion viewport %dx%d at %d,%d",
    viewport.panelW,
    viewport.panelH,
    viewportW,
    viewportH,
    originX,
    originY
  )
  if report ~= lastViewportReport then
    print("Promotion Tree measured viewport: " .. report)
    lastViewportReport = report
  end
  local function unavailable(message)
    Controls.LayoutStatus:SetText(message)
    Controls.LayoutStatus:SetHide(false)
    for _, detail in ipairs(graph.diagnostics or {}) do
      print("Promotion Tree: " .. detail)
    end
  end
  if graph.invalid then
    unavailable("This promotion tree contains inconsistent prerequisite data.")
  elseif #graph.order == 0 then
    unavailable("No promotions are available for this unit class.")
  else
    local layoutStart = perfClock and perfClock()
    local function solve()
      return PromotionLayoutCached(graph, {
        buttonW = promotionCardWidth,
        buttonH = promotionCardHeight,
        viewportW = viewportW,
        viewportH = viewportH,
        padding = 24,
        pipeHalfWidth = 4,
        underpassHalfGap = 10,
      })
    end
    local layout
    layout, cacheHit = solve()
    if usesLargeCards and (layout.overflow or not layout.valid or #layout.buttons == 0) then
      -- Normal cards do not fit even at the smallest scale; Small cards may.
      Resize(config.small)
      Controls.ResizeButton:SetCheck(true)
      viewport = ResolvePromotionViewport()
      originX, originY = viewport.x, viewport.y
      viewportW, viewportH = viewport.width, viewport.height
      layout, cacheHit = solve()
      print("Promotion Tree: selected Small cards to fit the tree")
    end
    if perfClock then
      layoutSeconds = perfClock() - layoutStart
    end
    for _, detail in ipairs(layout.violations or {}) do
      print("Promotion Tree layout: " .. tostring(detail))
    end
    if layout.overflow then
      print("Promotion Tree: the tree is larger than the panel even at the smallest scale")
    end
    if #layout.buttons == 0 then
      unavailable("This promotion tree could not be arranged.")
    else
      local drawStart = perfClock and perfClock()
      local drawn, reason =
        DrawTreeLayout(layout, liveUnit, classKey, originX, originY, viewportH, graph)
      if perfClock then
        drawSeconds = perfClock() - drawStart
      end
      if not drawn then
        unavailable("This promotion tree could not be drawn within the display limits.")
        print("Promotion Tree renderer: " .. tostring(reason))
      end
      layoutMethod = (layout.method or "?") .. (layout.stats and layout.stats.stored and " stored" or "")
      canvasWidth = (layout.contentWidth or 0) * (layout.scale or 1)
    end
  end
  -- Trees are fitted into the viewport by scale; one still wider at the
  -- smallest scale widens the canvas, and the panel scrolls.
  AdjustClassGroupWidth(sidebarWidth)
  AdjustBaseGroupWidth(math.max(viewportW, canvasWidth) + 20)
  Controls.GroupsStack:CalculateSize()
  Controls.GroupsStack:ReprocessAnchoring()
  Controls.ScrollPanel:CalculateInternalSize()
  if perfClock then
    print(
      string.format(
        "Promotion Tree CPU: graph=%.3fs layout=%.3fs draw=%.3fs total=%.3fs cache=%s method=%s",
        graphSeconds or 0,
        layoutSeconds or 0,
        drawSeconds or 0,
        perfClock() - perfStart,
        cacheHit and "hit" or "miss",
        layoutMethod
      )
    )
  end
end

function DrawTreeLayout(layout, liveUnit, classKey, originX, originY, viewportH, graph)
  local scale = layout.scale or 1
  ButtonManagerSetScale(scale)
  local routes, paintReason = layout.paintedRoutes, nil
  if not routes then
    routes, _, paintReason = PromotionPaintedRoutes(
      layout,
      promotionCardWidth,
      promotionCardHeight,
      ButtonManagerGetCardWidth()
    )
  end
  if not routes then
    return false, paintReason
  end
  originY = originY
    + PromotionTreeVerticalOffset(
      layout,
      viewportH,
      promotionCardWidth,
      promotionCardHeight,
      ButtonManagerGetCardWidth(),
      routes,
      sidebarCenterY - originY
    )
  local painted = {}
  for i = 1, #routes do
    painted[i] = routes[i]
  end
  local boxWidth = liveUnit and unitCardWidth or classCardWidth
  local boxHeight = liveUnit and unitCardHeight or classCardHeight
  local bridge = PromotionUnitSourceBridge(
    layout,
    originX,
    originY,
    sidebarLeftMargin + boxWidth + 2,
    sidebarCenterY,
    boxHeight
  )
  if bridge then
    painted[#painted + 1] = bridge
  end
  local pipeOptions = {
    scale = scale,
    offsetX = originX,
    offsetY = originY,
    nativeArt = scale < 0.999,
  }
  local ok, reason = PipeManagerDrawNetwork(painted, pipeOptions)
  if not ok and bridge then
    -- A short sidebar dogleg cannot fit full native junction tiles. Preserve
    -- its exact centre attachment using straight native runs in that case.
    print("Promotion Tree box stem: " .. tostring(reason))
    ok, reason = PipeManagerDrawNetwork(routes, pipeOptions)
    if ok then
      for i = 1, #bridge.points - 1 do
        ok, reason = PipeManagerDrawPath({ bridge.points[i], bridge.points[i + 1] }, pipeOptions)
        if not ok then
          break
        end
      end
    end
  end
  if not ok then
    PipeManagerReset()
    return false, reason
  end
  ResetPromotionHover(graph)
  for _, button in ipairs(layout.buttons) do
    DrawPromotionButton(
      originX + button.x * scale,
      originY + button.y * scale,
      liveUnit,
      button.type,
      classKey,
      graph.nodes[button.type]
    )
  end
  return true
end

function AdjustPanelHeight(panelHeight)
  local outerPanelHeight = panelHeight + 2 * panelTopMargin
  -- The scrolling surface and its glass backing cover the entire panel.
  -- The promotion viewport still keeps its existing lower padding above it.
  local scrollHeight = outerPanelHeight
  local groupHeight = outerPanelHeight
  local dividerHeight = scrollHeight - panelTopMargin
  local blockHeight = scrollHeight

  SetHeight(Controls.TreePanel, outerPanelHeight)
  SetHeight(Controls.ScrollPanel, scrollHeight)

  SetHeight(Controls.ClassGroup, groupHeight)
  SetHeight(Controls.ClassDivider, dividerHeight)

  SetHeight(Controls.BaseGroup, groupHeight)
  SetHeight(Controls.BaseDivider, dividerHeight)
  SetHeight(Controls.BaseBlock, blockHeight)

  Controls.DropDownBox:SetOffset({
    x = sidebarLeftMargin,
    y = (sidebarCenterY - classCardHeight / 2),
  })
  Controls.UnitBox:SetOffset({ x = sidebarLeftMargin, y = (sidebarCenterY - unitCardHeight / 2) })

  Controls.ScrollPanel:CalculateInternalSize()
  Controls.ScrollBar:SetSizeX(Controls.ScrollPanel:GetSizeX() - sidebarLeftMargin - 15)
end

function AdjustClassGroupWidth(width)
  SetWidth(Controls.ClassGroup, width)
  SetWidth(Controls.ClassBar, width)
end

function AdjustBaseGroupWidth(width)
  SetWidth(Controls.BaseGroup, width)
  SetWidth(Controls.BaseBlock, width)
  SetWidth(Controls.BaseBar, width)
end

function DrawPromotionDropDown(x, y)
  dprint("Place dropdown menu at (%i, %i)", x, y)

  Controls.ClassLabel:SetText(Locale.ConvertTextKey("TXT_KEY_PROMO_GROUP_CLASS"))

  Controls.DropDownBox:SetHide(false)
  Controls.UnitStatsPanel:SetHide(true)
  Controls.UnitBox:SetHide(true)

  PopulateClassDropDown()

  Controls.Legend:SetHide(true)
end

function DrawUnitBox(x, y, liveUnit)
  dprint("Place unit box for %s at (%i, %i)", liveUnit:GetName(), x, y)

  Controls.ClassLabel:SetText(Locale.ConvertTextKey("TXT_KEY_PROMO_GROUP_UNIT"))

  Controls.UnitBox:SetHide(false)
  Controls.DropDownBox:SetHide(true)

  Controls.UnitName:SetText(SidebarCardWrapName(liveUnit:GetName(), 24, 112))
  Controls.UnitName:SetTruncateWidth(112)

  local unit = GameInfo.Units[liveUnit:GetUnitType()]
  Controls.UnitPortraitFrame:SetHide(
    IconHookup(unit.PortraitIndex, unitPortraitSize, unit.IconAtlas, Controls.UnitPortrait) ~= true
  )

  Controls.UnitBox:SetToolTipString("")

  Controls.Legend:SetHide(false)
  OffsetAgain(Controls.Legend)
end

function DrawPromotionButton(x, y, liveUnit, promotionType, classKey, node)
  dprint("Place %s at (%i, %i)", promotionType, x, y)
  local promotion = GameInfo.UnitPromotions[promotionType]

  local promotionName = Locale.ConvertTextKey(promotion.Description)
  local displayName = ButtonManagerDisplayName(promotionName)
  local tooltip = promotionName .. "[NEWLINE]" .. Locale.ConvertTextKey(promotion.Help)
  if node and node.requiredPrereq then
    local required = GameInfo.UnitPromotions[node.requiredPrereq]
    if required then
      tooltip = tooltip
        .. "[NEWLINE][NEWLINE]"
        .. Locale.ConvertTextKey(
          "TXT_KEY_PROMO_REQUIRED_PROMOTION",
          Locale.ConvertTextKey(required.Description)
        )
    end
  end

  local button = ButtonManagerGetButton(
    x,
    y,
    tooltip,
    promotion.IconAtlas,
    promotion.PortraitIndex,
    promotion.TechPrereq
  )

  local state
  if liveUnit then
    if HasPromotion(liveUnit, promotion.ID) then
      state = "selected"
    elseif CanAcquirePromotion(liveUnit, promotion.ID) then
      state = "available"
    else
      state = "locked"
    end
  else
    state = plannedPromotionStates and plannedPromotionStates[promotionType] or "locked"
  end

  if state == "selected" then
    button.EarntName:SetText(displayName)
    button.EarntGlowName:SetText(displayName)
    button.Earnt:SetHide(false)
    button.Available:SetHide(true)
    button.Unavailable:SetHide(true)
    ButtonManagerSetHighlightState(button, "selected")
  elseif state == "available" then
    button.AvailableName:SetText(displayName)
    button.AvailableGlowName:SetText(displayName)
    button.Available:SetHide(false)
    button.Earnt:SetHide(true)
    button.Unavailable:SetHide(true)
    ButtonManagerSetHighlightState(button, "available")
  else
    button.UnavailableName:SetText(displayName)
    button.UnavailableGlowName:SetText(displayName)
    button.Unavailable:SetHide(false)
    button.Earnt:SetHide(true)
    button.Available:SetHide(true)
    ButtonManagerSetHighlightState(button, "locked")
  end
  if liveUnit and state == "available" then
    button.Button:SetVoid1(promotion.ID)
    button.Button:RegisterCallback(Mouse.eLClick, OnSelectPromotion)
  elseif not liveUnit and state ~= "locked" then
    button.Button:RegisterCallback(Mouse.eLClick, function()
      if activeClassPlan and activeClassKey == classKey then
        local changed = PromotionClassPlanner.Toggle(activeClassPlan, promotionType)
        if changed then
          PlacePromotions(nil, classKey, sidebarLeftMargin + classCardWidth, sidebarCenterY)
        end
      end
    end)
  end
  cardsByPromotionType[promotionType] = button
  button.Button:RegisterCallback(Mouse.eMouseEnter, function()
    HighlightPromotionRelations(promotionType)
  end)
  button.Button:RegisterCallback(Mouse.eMouseExit, function()
    if hoveredPromotionType == promotionType then
      HighlightPromotionRelations(nil)
    end
  end)
end

g_ClassList = nil

local function SetSelectedClassName(className)
  local button = Controls.ClassDropDown:GetButton()
  -- The native PullDown sizes and places its own closed-button text without
  -- honoring our child GridButton's narrow text anchors. Draw the name in a
  -- separate right-aligned label whose left edge clears the circular flag.
  button:SetText("")
  button:SetToolTipString(className)
  local wrapped = SidebarCardWrapName(SidebarClassDisplayName(className), 20, 150)
  local lines = {}
  for line in (wrapped .. "[NEWLINE]"):gmatch("(.-)%[NEWLINE%]") do
    lines[#lines + 1] = line
  end
  if #lines > 2 then
    wrapped = lines[1] .. "[NEWLINE]" .. lines[2] .. "…"
  end
  Controls.ClassSelectedName:SetText(wrapped)
  Controls.ClassSelectedName:SetTruncateWidth(150)
  Controls.ClassSelectedName:SetToolTipString(className)
end

function PopulateClassDropDown()
  if g_ClassList == nil then
    PopulateClassList()

    for classIndex = 1, #g_ClassList, 1 do
      local controlTable = {}
      Controls.ClassDropDown:BuildEntry("InstanceOne", controlTable)

      local name = g_ClassList[classIndex].Name
      local wrapped = SidebarCardWrapName(SidebarClassDisplayName(name), 18, 148)
      controlTable.Button:SetVoid1(classIndex)
      local _, lineBreaks = wrapped:gsub("%[NEWLINE%]", "")
      controlTable.Button:SetSizeVal(196, math.max(40, (lineBreaks + 1) * 20 + 6))
      controlTable.Button:SetText("")
      controlTable.Button:SetToolTipString(name)
      controlTable.Name:SetText(wrapped)
      controlTable.Name:SetTruncateWidth(148)
      local unit = GameInfo.Units[g_ClassList[classIndex].UnitType]
      local flag = SidebarClassFlag(unit)
      controlTable.Flag:SetHide(flag == nil)
      if flag then
        controlTable.Flag:SetTexture(flag.texture)
        controlTable.Flag:SetTextureOffsetVal(flag.x, flag.y)
        controlTable.Flag:SetTextureSizeVal(32, 32)
        controlTable.Flag:SetSizeVal(32, 32)
        controlTable.Flag:NormalizeTexture()
      end
    end

    local initial = g_ClassList[selectedClassIndex] and g_ClassList[selectedClassIndex].Name or ""
    SetSelectedClassName(initial)

    Controls.ClassDropDown:CalculateInternals()
    Controls.ClassDropDown:RegisterSelectionCallback(OnSelectCombatClass)
  end
end

function PopulateClassList()
  g_ClassList = PromotionClassCatalog.List()
  selectedClassIndex = math.max(1, math.min(selectedClassIndex, #g_ClassList))
end

UpdateUnitStats = function(hover)
  local definition = inspectedUnit and GameInfo.Units[inspectedUnit:GetUnitType()]
  if not definition or not PromotionUnitStats then
    Controls.UnitStatsPanel:SetHide(true)
    return
  end
  if not heldPromotions then
    heldPromotions = {}
    for promotion in GameInfo.UnitPromotions() do
      if HasPromotion(inspectedUnit, promotion.ID) then
        heldPromotions[promotion.Type] = true
      end
    end
  end
  local xpTop = sidebarCenterY - unitCardHeight / 2 + 16 - 3 - 28
  local height = math.max(40, xpTop - 146 - 6)
  -- Recover half of each 20px sidebar margin for the information panel.
  -- Keep the tree boundary at its existing x coordinate.
  local margin = sidebarLeftMargin / 2
  local panelWidth = sidebarLeftMargin + sidebarWidth - 2 * margin
  Controls.UnitStatsPanel:SetOffsetVal(margin, 146)
  Controls.UnitStatsPanel:SetSizeVal(panelWidth, height)
  Controls.UnitStatsPanel:SetHide(false)
  Controls.UnitStatsScroll:SetSizeVal(panelWidth - 26, height - 10)
  Controls.UnitStatsScrollBar:SetSizeY(math.max(12, height - 46))
  if not statsPanel then
    statsPanel = PromotionStatsPanel.New(Controls)
  end
  statsPanel:Render(PromotionUnitStats.Build(definition, inspectedUnit, heldPromotions, hover))
end

function ShowHideHandler(isHidden, isInitializing)
  if not isHidden and not isInitializing then
    if selectedUnitID == nil then
      PlaceDropDown()
    else
      PlaceUnit(Players[Game.GetActivePlayer()]:GetUnitByID(selectedUnitID))
    end
  end

  isTreeVisible = (isHidden == false)
end
ContextPtr:SetShowHideHandler(ShowHideHandler)

function OnDisplay(unitID)
  if statsPanel then
    statsPanel:Reset()
  end
  Controls.SwitchModeButton:SetHide(false)
  selectedUnitID = unitID
  dprint("OnDisplay(%i)", selectedUnitID or 0)
  if not isTreeVisible then
    -- Every opening starts with Small cards; D switches to Normal until the
    -- panel closes. Switching mode while open keeps the chosen size.
    if usesLargeCards then
      Resize(config.small)
    end
    Controls.ResizeButton:SetCheck(true)
  end

  UIManager:QueuePopup(ContextPtr, PopupPriority.BarbarianCamp)
end
LuaEvents.PromotionTreeDisplay.Add(OnDisplay)

function OnResize(isChecked)
  dprint("OnResize(%s)", (isChecked and "true" or "false"))

  if isChecked then
    Small()
  else
    Normal()
  end
end
Controls.ResizeButton:RegisterCheckHandler(OnResize)

function OnClose()
  Hide()
  UIManager:DequeuePopup(ContextPtr)
end
Controls.CloseButton:RegisterCallback(Mouse.eLClick, OnClose)
Events.GameplaySetActivePlayer.Add(OnClose)

function OnSwitchMode()
  if ClassMode then
    local selectedUnit = UI.GetHeadSelectedUnit()
    if selectedUnit then
      LuaEvents.PromotionTreeDisplay(selectedUnit:GetID())
      ClassMode = false
    end
  else
    LuaEvents.PromotionTreeDisplay()
    ClassMode = true
  end
end
Controls.SwitchModeButton:RegisterCallback(Mouse.eLClick, OnSwitchMode)

function InputHandler(uiMsg, wParam, lParam)
  if uiMsg == KeyEvents.KeyDown then
    if wParam == Keys.VK_ESCAPE or wParam == Keys.VK_RETURN then
      OnClose()
      return true
    elseif wParam == Keys.S then
      OnSwitchMode()
      return true
    elseif wParam == Keys.D then
      Controls.ResizeButton:SetCheck(usesLargeCards == true)
      if usesLargeCards then
        Small()
      else
        Normal()
      end
      return true
    end
  end
  return false
end
ContextPtr:SetInputHandler(InputHandler)

function OnSelectCombatClass(classIndex)
  if classIndex == nil or classIndex < 1 or classIndex > #g_ClassList then
    classIndex = selectedClassIndex or 1
  end

  selectedClassIndex = classIndex

  if #g_ClassList == 0 then
    SetSelectedClassName("")
    Controls.ClassUnitRange:SetText("")
    Controls.ClassPortraitFrame:SetHide(true)
    ButtonManagerReset()
    PipeManagerReset()
    Controls.PromotionExperienceLabel:SetHide(true)
    return
  end
  local className = g_ClassList[classIndex].Name
  SetSelectedClassName(className)
  local unitRange = g_ClassList[classIndex].UnitRange or ""
  Controls.ClassUnitRange:SetText(SidebarCardWrapName(unitRange, 16, 238))
  Controls.ClassUnitRange:SetToolTipString(unitRange)

  local unit = GameInfo.Units[g_ClassList[classIndex].UnitType]
  local flag = SidebarClassFlag(unit)
  Controls.ClassPortraitFrame:SetHide(false)
  Controls.ClassPortrait:SetHide(flag == nil)
  if flag then
    Controls.ClassPortrait:SetTexture(flag.texture)
    Controls.ClassPortrait:SetTextureOffsetVal(flag.x, flag.y)
    -- Crop exactly one native atlas cell, independently of its display size.
    Controls.ClassPortrait:SetTextureSizeVal(flag.size, flag.size)
    Controls.ClassPortrait:SetSizeVal(32, 32)
    Controls.ClassPortrait:NormalizeTexture()
  else
    print("Promotion Tree: no valid unit flag atlas for " .. tostring(unit and unit.Type))
  end

  PlacePromotions(
    nil,
    g_ClassList[classIndex].Key,
    sidebarLeftMargin + classCardWidth,
    sidebarCenterY
  )
end

function OnSelectPromotion(promotionID)
  local liveUnit = UI.GetHeadSelectedUnit()
  if
    not liveUnit
    or liveUnit:GetID() ~= selectedUnitID
    or not CanAcquirePromotion(liveUnit, promotionID)
  then
    return
  end
  Events.AudioPlay2DSound("AS2D_INTERFACE_UNIT_PROMOTION")
  Game.HandleAction(GetActionForPromotion(promotionID))
end

function OnResetClassPlan()
  if not activeClassPlan or not activeClassKey then
    return
  end
  PromotionClassPlanner.Reset(activeClassPlan)
  PlacePromotions(nil, activeClassKey, sidebarLeftMargin + classCardWidth, sidebarCenterY)
end
Controls.ResetClassPlanButton:RegisterCallback(Mouse.eLClick, OnResetClassPlan)

function OnUnitInfoDirty()
  if isTreeVisible then
    local liveUnit = UI.GetHeadSelectedUnit()

    if liveUnit and liveUnit:GetID() == selectedUnitID then
      PlaceUnit(liveUnit)
    end
  end
end
Events.SerialEventUnitInfoDirty.Add(OnUnitInfoDirty)

function Hide()
  dprint("Hide()")

  ContextPtr:SetHide(true)
end

function Show()
  dprint("Show()")

  ContextPtr:SetHide(false)
end

function Small()
  dprint("Small()")

  Resize(config.small)
  Show()
end

function Normal()
  dprint("Normal()")

  Resize(config.normal)
  Show()
end

-- Keep viewport sizing separate from logical tree layout. The solver receives
-- the measured viewport through ResolvePromotionViewport, in both card modes.
function ResolvePanelHeight(config)
  local screenSizeAvailable, _, screenHeight = pcall(function()
    return UIManager:GetScreenSizeVal()
  end)

  if not screenSizeAvailable or type(screenHeight) ~= "number" or screenHeight <= 0 then
    return config.PANEL
  end

  -- Keep the outer panel inside the actual viewport at every resolution. At
  -- the shortest supported heights, trim the letterbox margins to 16px so the
  -- small layout retains enough room for ten 54px promotion rows.
  panelTopMargin = (screenHeight <= 608) and 16 or 20
  return math.max(1, screenHeight - 2 * panelTopMargin)
end

function Resize(config)
  dprint("Resize to %s", config.NAME)

  local requestedPanelHeight = ResolvePanelHeight(config)

  -- Reinitializing either manager without releasing its current instances leaves
  -- old controls attached to ScrollPanel. Normal and Small can resolve to the
  -- same screen height, so reset on every switch, not only when the panel height
  -- changes.
  ButtonManagerReset()
  PipeManagerReset()

  usesLargeCards = (config.NAME == "Normal")

  panelHeight = requestedPanelHeight
  sidebarCenterY = panelTopMargin + (panelHeight / 2)
  AdjustPanelHeight(panelHeight)

  promotionCardWidth, promotionCardHeight =
    ButtonManagerInit(config.BUTTON, "Button", Controls.ScrollPanel)

  PipeManagerInit(config.PIPE, "PipeInstance", "PipeIcon", Controls.ScrollPanel)
end

function Debug()
  bDebug = true
end

function NoDebug()
  bDebug = false
end

function Init()
  dprint("Init()")

  Resize(config.small)
  Controls.ResizeButton:SetCheck(true)
  Hide()
end

Init()

function ShowOnDemand()
  local selectedUnit = UI.GetHeadSelectedUnit()
  if selectedUnit then
    LuaEvents.PromotionTreeDisplay(selectedUnit:GetID())
    ClassMode = false
    Controls.SwitchModeButton:SetHide(false)
  else
    LuaEvents.PromotionTreeDisplay()
    ClassMode = true
    Controls.SwitchModeButton:SetHide(true)
  end
end

function OnAdditionalInformationDropdownGatherEntries(additionalEntries)
  table.insert(
    additionalEntries,
    { text = Locale.ConvertTextKey("TXT_KEY_PROMO_DIPLO_CORNER_HOOK"), call = ShowOnDemand }
  )
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(
  OnAdditionalInformationDropdownGatherEntries
)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()
