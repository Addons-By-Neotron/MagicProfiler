local mod = LibStub("AceAddon-3.0"):NewAddon("MagicProfiler", "AceTimer-3.0", "AceEvent-3.0")
local LDB = LibStub("LibDataBroker-1.1")
local QTIP = LibStub("LibQTip-1.0")

----------------------------------------------------------------
-- State
----------------------------------------------------------------

local addonNames = {}    -- cached addon names (don't change at runtime)
local memUsage = {}      -- KB per addon index
local memPrev = {}       -- KB per addon index from previous refresh
local memDelta = {}      -- KB change since last refresh
local cpuCurrent = {}    -- RecentAverageTime ms per addon index (cached for sort)
local cpuSession = {}    -- SessionAverageTime ms per addon index (cached for sort)
local numAddons = 0
local profilerAvailable = false

-- Throttled memory updates
local MEM_UPDATE_INTERVAL = 10

local lastMemUpdate = 0

-- Timing
local LDB_SAMPLE_INTERVAL = 3

local sampleInterval = 3
local sampleTimer = nil

-- Tooltip state
local TOOLTIP_INTERVAL = 5
local TOP_N = 20

local tooltip
local tooltipAnchor = nil
local tooltipTimer = nil

-- Tooltip sorting helper
local sortedAddons = {}

-- Top window state
local TOP_ROW_HEIGHT = 18
local TOP_FRAME_WIDTH = 650
local TOP_MIN_ROWS = 5
local TOP_MAX_ROWS = 50
local TOP_VISIBLE_ROWS_DEFAULT = 25

local topFrame
local topRows = {}
local topSortColumn = "cpuCurrent"
local topSortReversed = false
local topTimer = nil
local topVisibleRows = TOP_VISIBLE_ROWS_DEFAULT
local topSortedAddons = {}

-- Top window column layout
local TOP_COLUMNS = {
   { key = "name",       label = "Addon",         width = 220, justify = "LEFT"  },
   { key = "cpuCurrent", label = "CPU (current)",  width = 100, justify = "RIGHT" },
   { key = "cpuSession", label = "CPU (session)",  width = 100, justify = "RIGHT" },
   { key = "memory",     label = "Memory",         width = 90,  justify = "RIGHT" },
   { key = "memDelta",   label = "Mem Delta",      width = 90,  justify = "RIGHT" },
}
local HEADER_Y = -55
local DATA_Y = HEADER_Y - 22
local headerButtons = {}
local ARROW_ACTIVE = 1.0
local ARROW_INACTIVE = 0.35

-- Interval control
local INTERVALS = { 1, 3, 5, 10 }
local intervalButtons = {}

-- Forward declarations
local ShowTopWindow, UpdateTopWindow

----------------------------------------------------------------
-- Profiler helpers
----------------------------------------------------------------

local function GetAppTime(metric)
   return C_AddOnProfiler.GetApplicationMetric(metric) or 1
end

local function GetOverallPct(metric)
   local app = GetAppTime(metric)
   local overall = C_AddOnProfiler.GetOverallMetric(metric) or 0
   return overall / app * 100
end

local function GetAddonPct(name, metric)
   local app = GetAppTime(metric)
   local val = C_AddOnProfiler.GetAddOnMetric(name, metric) or 0
   return val / app * 100
end

local function FormatPct(pct)
   if pct >= 10 then
      return format("%.0f%%", pct)
   elseif pct >= 1 then
      return format("%.1f%%", pct)
   elseif pct >= 0.01 then
      return format("%.2f%%", pct)
   else
      return "0%"
   end
end

----------------------------------------------------------------
-- Data sampling
----------------------------------------------------------------

local function RefreshMemory()
   UpdateAddOnMemoryUsage()
   for i = 1, numAddons do
      memPrev[i] = memUsage[i] or 0
      memUsage[i] = GetAddOnMemoryUsage(i)
      memDelta[i] = memUsage[i] - memPrev[i]
   end
   lastMemUpdate = GetTime()
end

local function RefreshCPUMetrics()
   if not profilerAvailable then return end
   local currentMetric = Enum.AddOnProfilerMetric.RecentAverageTime
   local sessionMetric = Enum.AddOnProfilerMetric.SessionAverageTime
   for i = 1, numAddons do
      local name = addonNames[i]
      cpuCurrent[i] = C_AddOnProfiler.GetAddOnMetric(name, currentMetric) or 0
      cpuSession[i] = C_AddOnProfiler.GetAddOnMetric(name, sessionMetric) or 0
   end
end

local function UpdateSample()
   local newCount = C_AddOns.GetNumAddOns()
   if newCount ~= numAddons then
      numAddons = newCount
      for i = 1, numAddons do
         addonNames[i] = C_AddOns.GetAddOnInfo(i)
      end
   end
   profilerAvailable = C_AddOnProfiler and C_AddOnProfiler.IsEnabled()
end

local function RestartSampleTimer(interval)
   if sampleTimer then
      mod:CancelTimer(sampleTimer)
   end
   sampleTimer = mod:ScheduleRepeatingTimer(UpdateSample, interval)
end

function mod:OnInitialize()
   MagicProfilerDB = MagicProfilerDB or {}
   if MagicProfilerDB.sampleInterval then
      sampleInterval = MagicProfilerDB.sampleInterval
   end
end

function mod:OnEnable()
   UpdateSample()
   RestartSampleTimer(LDB_SAMPLE_INTERVAL)
end

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function FormatMemory(kb)
   if kb >= 1024 then
      return format("%.1f MB", kb / 1024)
   else
      return format("%d KB", kb)
   end
end

local function CPUColor(pct)
   if pct < 1 then
      return 0.2, 1, 0.2
   elseif pct < 5 then
      return 1, 1, 0.2
   else
      return 1, 0.2, 0.2
   end
end

local function c(text, r, g, b)
   return format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

----------------------------------------------------------------
-- Top window sort functions
----------------------------------------------------------------

local sortFuncs = {
   name = function(a, b)
      return (addonNames[a] or "") < (addonNames[b] or "")
   end,
   cpuCurrent = function(a, b)
      return (cpuCurrent[a] or 0) > (cpuCurrent[b] or 0)
   end,
   cpuSession = function(a, b)
      return (cpuSession[a] or 0) > (cpuSession[b] or 0)
   end,
   memory = function(a, b)
      return (memUsage[a] or 0) > (memUsage[b] or 0)
   end,
   memDelta = function(a, b)
      return (memDelta[a] or 0) > (memDelta[b] or 0)
   end,
}

----------------------------------------------------------------
-- Top window UI
----------------------------------------------------------------

local function CreateTopControls()
   local f = topFrame

   f.totalMem = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
   f.totalMem:SetPoint("TOPRIGHT", -10, -35)
   f.totalMem:SetText("")

   f.totalCPU = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
   f.totalCPU:SetPoint("RIGHT", f.totalMem, "LEFT", -15, 0)
   f.totalCPU:SetText("Total: 0%")

   local prevBtn
   for idx, interval in ipairs(INTERVALS) do
      local btn = CreateFrame("Button", nil, f, "BackdropTemplate")
      btn:SetSize(32, 20)
      if prevBtn then
         btn:SetPoint("LEFT", prevBtn, "RIGHT", 2, 0)
      else
         btn:SetPoint("TOPLEFT", 10, -32)
      end
      btn:SetBackdrop({
         bgFile = "Interface/Tooltips/UI-Tooltip-Background",
         edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
         tile = true, tileSize = 8, edgeSize = 8,
         insets = { left = 2, right = 2, top = 2, bottom = 2 },
      })

      btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      btn.text:SetPoint("CENTER")
      btn.text:SetText(interval .. "s")

      btn.interval = interval
      btn:SetScript("OnClick", function(self)
         sampleInterval = self.interval
         MagicProfilerDB.sampleInterval = sampleInterval
         RestartSampleTimer(sampleInterval)
         if topTimer then
            mod:CancelTimer(topTimer)
         end
         topTimer = mod:ScheduleRepeatingTimer(UpdateTopWindow, sampleInterval)
         for _, b in ipairs(intervalButtons) do
            if b.interval == sampleInterval then
               b:SetBackdropColor(0.2, 0.4, 0.8, 0.8)
            else
               b:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            end
         end
      end)

      if interval == sampleInterval then
         btn:SetBackdropColor(0.2, 0.4, 0.8, 0.8)
      else
         btn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
      end

      intervalButtons[idx] = btn
      prevBtn = btn
   end

   -- Refresh Memory button
   local memBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
   memBtn:SetSize(80, 20)
   memBtn:SetPoint("LEFT", prevBtn, "RIGHT", 10, 0)
   memBtn:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
   })
   memBtn:SetBackdropColor(0.15, 0.3, 0.15, 0.8)

   memBtn.text = memBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   memBtn.text:SetPoint("CENTER")
   memBtn.text:SetText("Refresh Mem")

   memBtn:SetScript("OnClick", function()
      RefreshMemory()
      UpdateTopWindow()
   end)
   memBtn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Refresh Memory Usage")
      GameTooltip:AddLine("Memory is not updated automatically for performance reasons.", 1, 1, 1, true)
      GameTooltip:Show()
   end)
   memBtn:SetScript("OnLeave", function()
      GameTooltip:Hide()
   end)
end

local function UpdateHeaderArrows()
   for _, b in ipairs(headerButtons) do
      if b.columnKey == topSortColumn then
         b.arrowUp:SetAlpha(topSortReversed and ARROW_ACTIVE or ARROW_INACTIVE)
         b.arrowDown:SetAlpha(topSortReversed and ARROW_INACTIVE or ARROW_ACTIVE)
      else
         b.arrowUp:SetAlpha(0)
         b.arrowDown:SetAlpha(0)
      end
   end
end

local function CreateTopHeaders()
   local xOffset = 10
   for i, col in ipairs(TOP_COLUMNS) do
      local btn = CreateFrame("Button", nil, topFrame)
      btn:SetSize(col.width, 20)
      btn:SetPoint("TOPLEFT", xOffset, HEADER_Y)

      btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      btn.text:SetText(col.label)
      btn.text:SetTextColor(1, 0.82, 0)

      btn.arrowUp = btn:CreateTexture(nil, "OVERLAY")
      btn.arrowUp:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
      btn.arrowUp:SetSize(10, 10)

      btn.arrowDown = btn:CreateTexture(nil, "OVERLAY")
      btn.arrowDown:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
      btn.arrowDown:SetSize(10, 10)

      if col.justify == "RIGHT" then
         btn.text:SetPoint("RIGHT")
         btn.arrowUp:SetPoint("RIGHT", btn.text, "LEFT", -2, 4)
         btn.arrowDown:SetPoint("RIGHT", btn.text, "LEFT", -2, -6)
      else
         btn.text:SetPoint("LEFT")
         btn.arrowUp:SetPoint("LEFT", btn.text, "RIGHT", 4, 4)
         btn.arrowDown:SetPoint("LEFT", btn.text, "RIGHT", 4, -6)
      end

      btn:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")

      btn.columnKey = col.key
      btn:SetScript("OnClick", function(self)
         if topSortColumn == self.columnKey then
            topSortReversed = not topSortReversed
         else
            topSortColumn = self.columnKey
            topSortReversed = false
         end
         UpdateHeaderArrows()
         UpdateTopWindow()
      end)

      headerButtons[i] = btn
      xOffset = xOffset + col.width
   end

   UpdateHeaderArrows()

   local sep = topFrame:CreateTexture(nil, "ARTWORK")
   sep:SetHeight(1)
   sep:SetPoint("TOPLEFT", 8, HEADER_Y - 20)
   sep:SetPoint("TOPRIGHT", -8, HEADER_Y - 20)
   sep:SetColorTexture(0.6, 0.6, 0.6, 0.5)
end

local function CreateTopScrollArea()
   local scrollFrame = CreateFrame("ScrollFrame", "MagicProfilerScrollFrame", topFrame, "FauxScrollFrameTemplate")
   scrollFrame:SetPoint("TOPLEFT", 6, DATA_Y)
   scrollFrame:SetPoint("BOTTOMRIGHT", -28, 30)
   topFrame.scrollFrame = scrollFrame

   scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
      FauxScrollFrame_OnVerticalScroll(self, offset, TOP_ROW_HEIGHT, function() UpdateTopWindow() end)
   end)

   for i = 1, topVisibleRows do
      local row = CreateFrame("Frame", nil, topFrame)
      row:SetSize(TOP_FRAME_WIDTH - 36, TOP_ROW_HEIGHT)
      row:SetPoint("TOPLEFT", 10, DATA_Y - (i - 1) * TOP_ROW_HEIGHT)

      row.bg = row:CreateTexture(nil, "BACKGROUND")
      row.bg:SetAllPoints()
      if i % 2 == 0 then
         row.bg:SetColorTexture(1, 1, 1, 0.03)
      else
         row.bg:SetColorTexture(0, 0, 0, 0)
      end

      local xOffset = 0
      row.cols = {}
      for j, col in ipairs(TOP_COLUMNS) do
         local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
         fs:SetWidth(col.width)
         fs:SetJustifyH(col.justify)
         fs:SetPoint("LEFT", xOffset, 0)
         row.cols[j] = fs
         xOffset = xOffset + col.width
      end

      topRows[i] = row
   end
end

local function CreateTopStatusBar()
   topFrame.statusBar = topFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   topFrame.statusBar:SetPoint("BOTTOMLEFT", 10, 10)
   topFrame.statusBar:SetTextColor(0.6, 0.6, 0.6)
end

UpdateTopWindow = function()
   if not topFrame or not topFrame:IsShown() then return end

   -- Refresh cached CPU metrics
   RefreshCPUMetrics()

   -- Build list of loaded addons only
   wipe(topSortedAddons)
   for i = 1, numAddons do
      if C_AddOns.IsAddOnLoaded(i) then
         topSortedAddons[#topSortedAddons + 1] = i
      end
   end

   -- Sort
   local cmp = sortFuncs[topSortColumn] or sortFuncs.cpuCurrent
   if topSortReversed then
      sort(topSortedAddons, function(a, b) return cmp(b, a) end)
   else
      sort(topSortedAddons, cmp)
   end

   -- Update scroll
   local totalAddons = #topSortedAddons
   FauxScrollFrame_Update(topFrame.scrollFrame, totalAddons, topVisibleRows, TOP_ROW_HEIGHT)
   local offset = FauxScrollFrame_GetOffset(topFrame.scrollFrame)

   local appCurrent = GetAppTime(Enum.AddOnProfilerMetric.RecentAverageTime)
   local appSession = GetAppTime(Enum.AddOnProfilerMetric.SessionAverageTime)

   -- Render visible rows
   for i = 1, topVisibleRows do
      local row = topRows[i]
      local idx = offset + i
      if idx <= totalAddons then
         local addonIdx = topSortedAddons[idx]
         local name = addonNames[addonIdx] or ""
         local curPct = (cpuCurrent[addonIdx] or 0) / appCurrent * 100
         local sesPct = (cpuSession[addonIdx] or 0) / appSession * 100
         local mem = memUsage[addonIdx] or 0
         local r, g, b = CPUColor(curPct)

         row.cols[1]:SetText(name)
         row.cols[1]:SetTextColor(r, g, b)
         row.cols[2]:SetText(FormatPct(curPct))
         row.cols[2]:SetTextColor(r, g, b)
         row.cols[3]:SetText(FormatPct(sesPct))
         row.cols[3]:SetTextColor(r, g, b)
         row.cols[4]:SetText(FormatMemory(mem))
         row.cols[4]:SetTextColor(1, 1, 1)

         local delta = memDelta[addonIdx] or 0
         if delta > 0 then
            row.cols[5]:SetText("+" .. FormatMemory(delta))
            row.cols[5]:SetTextColor(1, 0.4, 0.4)
         elseif delta < 0 then
            row.cols[5]:SetText("-" .. FormatMemory(-delta))
            row.cols[5]:SetTextColor(0.4, 1, 0.4)
         else
            row.cols[5]:SetText("0 KB")
            row.cols[5]:SetTextColor(0.5, 0.5, 0.5)
         end
         row:Show()
      else
         row:Hide()
      end
   end

   -- Update total CPU, total memory, and status
   local totalPct = GetOverallPct(Enum.AddOnProfilerMetric.RecentAverageTime)
   topFrame.totalCPU:SetText(format("CPU: %s", FormatPct(totalPct)))

   local totalKB = 0
   for _, addonIdx in ipairs(topSortedAddons) do
      totalKB = totalKB + (memUsage[addonIdx] or 0)
   end
   topFrame.totalMem:SetText(format("Mem: %s", FormatMemory(totalKB)))

   topFrame.statusBar:SetText(format("%d / %d addons loaded", #topSortedAddons, numAddons))
end

local function CreateTopFrame()
   local f = CreateFrame("Frame", "MagicProfilerTopFrame", UIParent, "BackdropTemplate")
   local db = MagicProfilerDB
   local savedW = db.width or TOP_FRAME_WIDTH
   local savedH = db.height or (70 + topVisibleRows * TOP_ROW_HEIGHT + 30)
   local available = savedH - 70 - 30
   topVisibleRows = max(TOP_MIN_ROWS, floor(available / TOP_ROW_HEIGHT))
   f:SetSize(savedW, savedH)
   if db.point then
      f:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
   else
      f:SetPoint("CENTER")
   end
   f:SetMovable(true)
   f:SetResizable(true)
   f:SetResizeBounds(
      TOP_FRAME_WIDTH, 70 + TOP_MIN_ROWS * TOP_ROW_HEIGHT + 30,
      TOP_FRAME_WIDTH, 70 + TOP_MAX_ROWS * TOP_ROW_HEIGHT + 30
   )
   f:EnableMouse(true)
   f:SetClampedToScreen(true)
   local function SaveFrameLayout()
      local db = MagicProfilerDB
      local point, _, relPoint, x, y = f:GetPoint()
      db.point = point
      db.relPoint = relPoint
      db.x = x
      db.y = y
      db.width = f:GetWidth()
      db.height = f:GetHeight()
   end

   f:RegisterForDrag("LeftButton")
   f:SetScript("OnDragStart", f.StartMoving)
   f:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      SaveFrameLayout()
   end)
   f:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
   })
   f:SetBackdropColor(0, 0, 0, 0.9)
   f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
   f:SetFrameStrata("MEDIUM")

   f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
   f.title:SetPoint("TOPLEFT", 10, -8)
   f.title:SetText("Magic Profiler")

   f.closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
   f.closeBtn:SetPoint("TOPRIGHT", -2, -2)

   f:SetScript("OnShow", function()
      if (GetTime() - lastMemUpdate) >= MEM_UPDATE_INTERVAL then
         RefreshMemory()
      end
      UpdateTopWindow()
      topTimer = mod:ScheduleRepeatingTimer(UpdateTopWindow, sampleInterval)
   end)
   f:SetScript("OnHide", function()
      if topTimer then
         mod:CancelTimer(topTimer)
         topTimer = nil
      end
      sampleInterval = LDB_SAMPLE_INTERVAL
      RestartSampleTimer(LDB_SAMPLE_INTERVAL)
   end)

   -- Resize grip (bottom-right corner, height only)
   local grip = CreateFrame("Button", nil, f)
   grip:SetSize(16, 16)
   grip:SetPoint("BOTTOMRIGHT", -4, 4)
   grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
   grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
   grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
   grip:SetScript("OnMouseDown", function()
      f:StartSizing("BOTTOMRIGHT")
   end)
   grip:SetScript("OnMouseUp", function()
      f:StopMovingOrSizing()
      SaveFrameLayout()
   end)

   f:SetScript("OnSizeChanged", function(self, w, h)
      -- Recalculate visible rows based on new height
      local available = h - 70 - 30  -- header area and status bar
      topVisibleRows = max(TOP_MIN_ROWS, floor(available / TOP_ROW_HEIGHT))

      -- Create new rows if needed
      for i = #topRows + 1, topVisibleRows do
         local row = CreateFrame("Frame", nil, self)
         row:SetSize(TOP_FRAME_WIDTH - 36, TOP_ROW_HEIGHT)
         row:SetPoint("TOPLEFT", 10, DATA_Y - (i - 1) * TOP_ROW_HEIGHT)

         row.bg = row:CreateTexture(nil, "BACKGROUND")
         row.bg:SetAllPoints()
         if i % 2 == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.03)
         else
            row.bg:SetColorTexture(0, 0, 0, 0)
         end

         local xOffset = 0
         row.cols = {}
         for j, col in ipairs(TOP_COLUMNS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.justify)
            fs:SetPoint("LEFT", xOffset, 0)
            row.cols[j] = fs
            xOffset = xOffset + col.width
         end

         topRows[i] = row
      end

      -- Hide extra rows
      for i = topVisibleRows + 1, #topRows do
         topRows[i]:Hide()
      end

      UpdateTopWindow()
   end)

   tinsert(UISpecialFrames, "MagicProfilerTopFrame")

   topFrame = f
   return f
end

local function DismissTooltip()
   if tooltipTimer then
      mod:CancelTimer(tooltipTimer)
      tooltipTimer = nil
   end
   if tooltip then
      QTIP:Release(tooltip)
      tooltip = nil
   end
   tooltipAnchor = nil
end

ShowTopWindow = function()
   if not topFrame then
      DismissTooltip()
      CreateTopFrame()
      CreateTopControls()
      CreateTopHeaders()
      CreateTopScrollArea()
      CreateTopStatusBar()
      UpdateTopWindow()
   elseif topFrame:IsShown() then
      topFrame:Hide()
   else
      DismissTooltip()
      topFrame:Show()
   end
end

----------------------------------------------------------------
-- LDB Tooltip
----------------------------------------------------------------

local function SortByMemory(a, b)
   return (memUsage[a] or 0) > (memUsage[b] or 0)
end

local function SortByCPUCurrent(a, b)
   return (cpuCurrent[a] or 0) > (cpuCurrent[b] or 0)
end

local function FillTooltip()
   tooltip:Clear()

   local y

   if not profilerAvailable then
      -- Memory-only mode: 2 columns, sorted by memory
      tooltip:SetColumnLayout(2, "LEFT", "RIGHT")

      y = tooltip:AddHeader()
      tooltip:SetCell(y, 1, "|cffffffffAddon CPU Usage|r", "LEFT", 2)

      tooltip:AddLine(" ")
      y = tooltip:AddLine()
      tooltip:SetCell(y, 1, "|cffff9933Addon profiler is not available.|r", "LEFT", 2)
      tooltip:AddLine(" ")

      wipe(sortedAddons)
      for i = 1, numAddons do
         if (memUsage[i] or 0) > 0 then
            sortedAddons[#sortedAddons + 1] = i
         end
      end
      sort(sortedAddons, SortByMemory)

      tooltip:AddSeparator(1)
      y = tooltip:AddLine()
      tooltip:SetCell(y, 1, "|cff999999Addon|r", "LEFT")
      tooltip:SetCell(y, 2, "|cff999999Memory|r", "RIGHT")
      tooltip:AddSeparator(1)

      local count = min(#sortedAddons, TOP_N)
      for j = 1, count do
         local i = sortedAddons[j]
         local name = addonNames[i] or ""
         local mem = memUsage[i] or 0

         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, format("|cffffffff%s|r", name), "LEFT")
         tooltip:SetCell(y, 2, format("|cffffffff%s|r", FormatMemory(mem)), "RIGHT")
      end

      if #sortedAddons > TOP_N then
         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, format("|cff808080... and %d more|r", #sortedAddons - TOP_N), "LEFT", 2)
      end
   else
      -- CPU + Memory mode: 3 columns, sorted by CPU
      tooltip:SetColumnLayout(3, "LEFT", "RIGHT", "RIGHT")

      y = tooltip:AddHeader()
      tooltip:SetCell(y, 1, "|cffffffffAddon CPU Usage|r", "LEFT", 3)

      local totalPct = GetOverallPct(Enum.AddOnProfilerMetric.RecentAverageTime)

      tooltip:AddLine(" ")
      y = tooltip:AddLine()
      tooltip:SetCell(y, 1, "|cffffff00Total CPU:|r", "LEFT")
      tooltip:SetCell(y, 3, format("|cffffffff%s|r", FormatPct(totalPct)), "RIGHT")
      tooltip:AddLine(" ")

      RefreshCPUMetrics()
      local appTime = GetAppTime(Enum.AddOnProfilerMetric.RecentAverageTime)

      wipe(sortedAddons)
      for i = 1, numAddons do
         if (cpuCurrent[i] or 0) > 0 then
            sortedAddons[#sortedAddons + 1] = i
         end
      end
      sort(sortedAddons, SortByCPUCurrent)

      tooltip:AddSeparator(1)
      y = tooltip:AddLine()
      tooltip:SetCell(y, 1, "|cff999999Addon|r", "LEFT")
      tooltip:SetCell(y, 2, "|cff999999CPU|r", "RIGHT")
      tooltip:SetCell(y, 3, "|cff999999Memory|r", "RIGHT")
      tooltip:AddSeparator(1)

      local count = min(#sortedAddons, TOP_N)
      for j = 1, count do
         local i = sortedAddons[j]
         local name = addonNames[i] or ""
         local pct = (cpuCurrent[i] or 0) / appTime * 100
         local mem = memUsage[i] or 0
         local r, g, b = CPUColor(pct)

         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, c(name, r, g, b), "LEFT")
         tooltip:SetCell(y, 2, c(FormatPct(pct), r, g, b), "RIGHT")
         tooltip:SetCell(y, 3, format("|cffffffff%s|r", FormatMemory(mem)), "RIGHT")
      end

      if #sortedAddons > TOP_N then
         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, format("|cff808080... and %d more|r", #sortedAddons - TOP_N), "LEFT", 3)
      end
   end

   tooltip:AddLine(" ")
   tooltip:AddSeparator(1)
   y = tooltip:AddLine()
   local cols = profilerAvailable and 3 or 2
   tooltip:SetCell(y, 1, "|cffeda55fClick:|r |cffffff00Open Top window|r", "LEFT", cols)
end

local function RefreshTooltip()
   if tooltip and tooltip:IsShown() then
      FillTooltip()
      tooltip:Show()
   else
      if tooltipTimer then
         mod:CancelTimer(tooltipTimer)
         tooltipTimer = nil
      end
      if tooltip then
         QTIP:Release(tooltip)
         tooltip = nil
      end
      tooltipAnchor = nil
   end
end

----------------------------------------------------------------
-- LDB data object
----------------------------------------------------------------

local dataObj = LDB:NewDataObject("Magic Profiler", {
   type = "data source",
   icon = "Interface\\Icons\\INV_Gizmo_02",
   label = "CPU",
   text = "...",

   OnClick = function(frame, button)
      if button == "LeftButton" then
         ShowTopWindow()
      end
   end,

   OnEnter = function(frame)
      if topFrame and topFrame:IsShown() then return end
      if tooltip then
         QTIP:Release(tooltip)
      end
      if (GetTime() - lastMemUpdate) >= MEM_UPDATE_INTERVAL then
         RefreshMemory()
      end
      tooltip = QTIP:Acquire("MagicProfilerTooltip")
      tooltipAnchor = frame

      FillTooltip()

      tooltip:SetAutoHideDelay(0.25, frame)
      tooltip:SmartAnchorTo(frame)
      tooltip:Show()

      if tooltipTimer then
         mod:CancelTimer(tooltipTimer)
      end
      tooltipTimer = mod:ScheduleRepeatingTimer(RefreshTooltip, TOOLTIP_INTERVAL)
   end,

   OnLeave = function(frame)
   end,
})

----------------------------------------------------------------
-- LDB text updater
----------------------------------------------------------------

local function UpdateText()
   if not profilerAvailable then
      dataObj.label = "Profiler N/A"
      dataObj.text = ""
   else
      dataObj.label = "CPU"
      local pct = GetOverallPct(Enum.AddOnProfilerMetric.RecentAverageTime)
      dataObj.text = FormatPct(pct)
   end
end

local origUpdateSample = UpdateSample
UpdateSample = function()
   origUpdateSample()
   UpdateText()
end
