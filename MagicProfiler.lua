local L = LibStub("AceLocale-3.0"):GetLocale("MagicProfiler")
local LDB = LibStub("LibDataBroker-1.1")
local QTIP = LibStub("LibQTip-1.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfig-3.0")

local mod = LibStub("AceAddon-3.0"):NewAddon("MagicProfiler", "AceConsole-3.0", "AceTimer-3.0", "AceEvent-3.0", "LibMagicUtil-1.0")
LibStub("LibLogger-1.0"):Embed(mod)

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

local defaults = {
   profile = {
      ldbInterval = 3,
      sampleInterval = 3,
      topN = 20,
      enableSnapshot = true,
   },
   char = {
      reloadInitiatedAt = nil,
      width = nil,
      height = nil,
      point = nil,
      relPoint = nil,
      x = nil,
      y = nil,
   },
}

-- Throttled memory updates
local MEM_UPDATE_INTERVAL = 10

local lastMemUpdate = 0

-- Timing
local sampleInterval = 3
local sampleTimer = nil

-- Tooltip state
local TOOLTIP_INTERVAL = 5

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

-- Snapshot state
local cpuEarly = {}          -- ms per addon index, 1s capture
local cpuEarlyAppTime = 0    -- app RecentAverageTime at 1s capture; 0 = profiler unavailable
local cpuLate = {}           -- ms per addon index, 5s capture
local cpuLateAppTime = 0     -- app RecentAverageTime at 5s capture; 0 = profiler unavailable
local memSnapshot = {}       -- KB per addon index, 5s capture
local snapshotTimeStr = nil  -- display string set when 5s fires, e.g. "14:32:15"
local reloadSeconds = nil    -- integer seconds of reload duration; nil if not a timed reload
local snapshotMode = false   -- true = Top window shows frozen snapshot view
local snapshotSortColumn = "cpuEarly"
local snapshotSortReversed = false

-- Top window column layout
local TOP_COLUMNS = {
   { key = "name",       label = "Addon",         width = 220, justify = "LEFT"  },
   { key = "cpuCurrent", label = "CPU (current)",  width = 100, justify = "RIGHT" },
   { key = "cpuSession", label = "CPU (session)",  width = 100, justify = "RIGHT" },
   { key = "memory",     label = "Memory",         width = 90,  justify = "RIGHT" },
   { key = "memDelta",   label = "Mem Delta",      width = 90,  justify = "RIGHT" },
}

local SNAPSHOT_COLUMNS = {
   { key = "name",        label = "Addon",        width = 220, justify = "LEFT"  },
   { key = "cpuEarly",    label = "CPU (1s)",      width = 100, justify = "RIGHT" },
   { key = "cpuLate",     label = "CPU (5s)",      width = 100, justify = "RIGHT" },
   { key = "memSnapshot", label = "Memory",        width = 90,  justify = "RIGHT" },
}
-- Total data width: 510px — fits within existing 650px frame without resizing

local HEADER_Y = -55
local DATA_Y = HEADER_Y - 22
local headerButtons = {}
local snapshotHeaderButtons = {}
local ARROW_ACTIVE = 1.0
local ARROW_INACTIVE = 0.35

-- Interval control
local INTERVALS = { 1, 3, 5, 10 }
local intervalButtons = {}

-- Forward declarations
local ShowTopWindow, UpdateTopWindow, UpdateHeaderArrows

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

local function TakeEarlySnapshot()
   if not (C_AddOnProfiler and C_AddOnProfiler.IsEnabled()) then return end
   local metric = Enum.AddOnProfilerMetric.RecentAverageTime
   cpuEarlyAppTime = C_AddOnProfiler.GetApplicationMetric(metric) or 0
   if cpuEarlyAppTime == 0 then return end
   for i = 1, numAddons do
      cpuEarly[i] = C_AddOnProfiler.GetAddOnMetric(addonNames[i], metric) or 0
   end
end

local function TakeLateSnapshot()
   -- CPU capture (skipped if profiler unavailable)
   if C_AddOnProfiler and C_AddOnProfiler.IsEnabled() then
      local metric = Enum.AddOnProfilerMetric.RecentAverageTime
      cpuLateAppTime = C_AddOnProfiler.GetApplicationMetric(metric) or 0
      if cpuLateAppTime > 0 then
         for i = 1, numAddons do
            cpuLate[i] = C_AddOnProfiler.GetAddOnMetric(addonNames[i], metric) or 0
         end
      end
   end

   -- Memory capture (always runs)
   UpdateAddOnMemoryUsage()
   for i = 1, numAddons do
      memSnapshot[i] = GetAddOnMemoryUsage(i)
   end

   snapshotTimeStr = date("%H:%M:%S")

   -- Enable the [Snap] toggle button now that data is ready
   if topFrame and topFrame.snapToggleBtn then
      topFrame.snapToggleBtn:Enable()
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

----------------------------------------------------------------
-- Options helpers
----------------------------------------------------------------

local options = {}

local function BuildOptions()
   options.general = {
      type = "group",
      name = L["Magic Profiler"],
      args = {
         desc = {
            type = "description",
            name = L["Magic Profiler is an LDB data source that displays addon CPU and memory usage. It requires an LDB display addon such as Button Bin, ChocolateBar, or Titan Panel."],
            order = 0,
            fontSize = "medium",
         },
         ldbInterval = {
            type = "range",
            name = L["LDB update interval"],
            desc = L["How often to update the LDB button text with the current CPU load, in seconds. This runs continuously in the background."],
            min = 1, max = 10, step = 1,
            width = "full",
            order = 1,
            get = function() return mod.db.profile.ldbInterval end,
            set = function(_, val)
               mod.db.profile.ldbInterval = val
               if not topFrame or not topFrame:IsShown() then
                  RestartSampleTimer(val)
               end
            end,
         },
         sampleInterval = {
            type = "range",
            name = L["Top window interval"],
            desc = L["How often to refresh the Top window while it is open, in seconds."],
            min = 1, max = 10, step = 1,
            width = "full",
            order = 2,
            get = function() return mod.db.profile.sampleInterval end,
            set = function(_, val)
               mod.db.profile.sampleInterval = val
               sampleInterval = val
               if topFrame and topFrame:IsShown() then
                  RestartSampleTimer(val)
               end
               for _, b in ipairs(intervalButtons) do
                  if b.interval == val then
                     b:SetBackdropColor(0.2, 0.4, 0.8, 0.8)
                  else
                     b:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
                  end
               end
            end,
         },
         topN = {
            type = "range",
            name = L["Tooltip entries"],
            desc = L["Maximum number of addons to show in the LDB tooltip."],
            min = 5, max = 50, step = 5,
            width = "full",
            order = 3,
            get = function() return mod.db.profile.topN end,
            set = function(_, val)
               mod.db.profile.topN = val
            end,
         },
         enableSnapshot = {
            type = "toggle",
            name = L["Enable load snapshot"],
            desc = L["Capture on-load CPU usage for all addons. When disabled, snapshot buttons are hidden and no load data is collected."],
            width = "full",
            order = 4,
            get = function() return mod.db.profile.enableSnapshot end,
            set = function(_, val)
               mod.db.profile.enableSnapshot = val
               if not val and snapshotMode then
                  EnterLiveMode()
               end
               if topFrame then
                  UpdateTopWindow()
               end
            end,
         },
         cmdHeader = {
            type = "header",
            name = L["Commands"],
            order = 10,
         },
         cmdDesc = {
            type = "description",
            name = L["/profiler toggle  — show/hide the Top window"] .. "\n"
                .. L["/profiler config  — open settings"] .. "\n"
                .. L["/profiler snapshot  — reload and capture on-load CPU usage"],
            order = 11,
            fontSize = "medium",
         },
      },
   }
   options.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(mod.db)
end

function mod:OptReg(optname, tbl, dispname)
   if dispname then
      optname = "Magic Profiler" .. optname
      AceConfigRegistry:RegisterOptionsTable(optname, tbl)
      return AceConfigDialog:AddToBlizOptions(optname, dispname, "Magic Profiler")
   else
      AceConfigRegistry:RegisterOptionsTable(optname, tbl)
      return AceConfigDialog:AddToBlizOptions(optname, "Magic Profiler")
   end
end

function mod:OnInitialize()
   self.db = LibStub("AceDB-3.0"):New("MagicProfilerDB", defaults, "Default")
   sampleInterval = self.db.profile.sampleInterval
   -- Compute reload duration if this load was triggered by "Create Snapshot"
   if self.db.char.reloadInitiatedAt then
      local delta = GetServerTime() - self.db.char.reloadInitiatedAt
      if delta >= 0 and delta < 300 then
         reloadSeconds = delta
      end
      self.db.char.reloadInitiatedAt = nil
   end
   BuildOptions()
   self.optionsMain = self:OptReg("Magic Profiler", options.general)
   self.optionsEnd = self:OptReg(": Profiles", options.profiles, L["Profiles"])
end

function mod:OnEnable()
   UpdateSample()
   if mod.db.profile.enableSnapshot then
      mod:ScheduleTimer(TakeEarlySnapshot, 1)
      mod:ScheduleTimer(TakeLateSnapshot, 5)
   end
   mod:RegisterChatCommand("profiler", function(input)
      local cmd = strtrim(input or ""):lower()
      if cmd == "toggle" then
         ShowTopWindow()
      elseif cmd == "config" then
         mod:InterfaceOptionsFrame_OpenToCategory(mod.optionsEnd)
         mod:InterfaceOptionsFrame_OpenToCategory(mod.optionsMain)
      elseif cmd == "snapshot" then
         if not mod.db.profile.enableSnapshot then
            mod:info(L["Load snapshot is disabled. Enable it in options first."])
            return
         end
         mod.db.char.reloadInitiatedAt = GetServerTime()
         ReloadUI()
      else
         mod:info(L["Available commands:"])
         mod:info(L["/profiler toggle  — show/hide the Top window"])
         mod:info(L["/profiler config  — open settings"])
         mod:info(L["/profiler snapshot  — reload and capture on-load CPU usage"])
      end
   end)

   RestartSampleTimer(mod.db.profile.ldbInterval)
   if reloadSeconds and mod.db.profile.enableSnapshot then
      mod:ScheduleTimer(function()
         ShowTopWindow()
         snapshotMode = true
         snapshotSortColumn = "cpuEarly"
         snapshotSortReversed = false
         if topFrame and topFrame.snapToggleBtn then
            topFrame.snapToggleBtn:SetBackdropColor(0.2, 0.4, 0.8, 0.8)
            topFrame.snapToggleBtn.text:SetText("Live")
         end
         UpdateHeaderArrows()
         UpdateTopWindow()
      end, 5.1)
   end
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

local snapshotSortFuncs = {
   name = function(a, b)
      return (addonNames[a] or "") < (addonNames[b] or "")
   end,
   cpuEarly = function(a, b)
      return (cpuEarly[a] or 0) > (cpuEarly[b] or 0)
   end,
   cpuLate = function(a, b)
      return (cpuLate[a] or 0) > (cpuLate[b] or 0)
   end,
   memSnapshot = function(a, b)
      return (memSnapshot[a] or 0) > (memSnapshot[b] or 0)
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
         mod.db.profile.sampleInterval = sampleInterval
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

   f.memBtn = memBtn

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

   -- [Snap] toggle button
   local snapBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
   snapBtn:SetSize(70, 20)
   snapBtn:SetPoint("LEFT", memBtn, "RIGHT", 10, 0)
   snapBtn:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
   })
   snapBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)

   snapBtn.text = snapBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   snapBtn.text:SetPoint("CENTER")
   snapBtn.text:SetText("On-Load")

   snapBtn:SetScript("OnClick", function()
      snapshotMode = not snapshotMode
      if snapshotMode then
         snapshotSortColumn = "cpuEarly"
         snapshotSortReversed = false
         snapBtn:SetBackdropColor(0.2, 0.4, 0.8, 0.8)
         snapBtn.text:SetText("Live")
         -- pause live timer while viewing frozen snapshot
         if topTimer then
            mod:CancelTimer(topTimer)
            topTimer = nil
         end
      else
         snapBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
         snapBtn.text:SetText("On-Load")
         -- restart live update timer
         if topTimer then mod:CancelTimer(topTimer) end
         topTimer = mod:ScheduleRepeatingTimer(UpdateTopWindow, sampleInterval)
      end
      UpdateHeaderArrows()
      UpdateTopWindow()
   end)
   snapBtn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Load Snapshot View")
      GameTooltip:AddLine("Toggle between live data and the frozen load snapshot.", 1, 1, 1, true)
      GameTooltip:Show()
   end)
   snapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

   snapBtn:Disable()   -- enabled by TakeLateSnapshot once data is ready
   f.snapToggleBtn = snapBtn

   -- Create Snapshot button (triggers reload)
   local createSnapBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
   createSnapBtn:SetSize(110, 20)
   createSnapBtn:SetPoint("LEFT", snapBtn, "RIGHT", 4, 0)
   createSnapBtn:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
   })
   createSnapBtn:SetBackdropColor(0.4, 0.25, 0.05, 0.9)

   createSnapBtn.text = createSnapBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   createSnapBtn.text:SetPoint("CENTER")
   createSnapBtn.text:SetText("Create Snapshot")

   createSnapBtn:SetScript("OnClick", function()
      mod.db.char.reloadInitiatedAt = GetServerTime()
      ReloadUI()
   end)
   createSnapBtn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Create Load Snapshot")
      GameTooltip:AddLine("Reload the UI and capture load-time CPU usage for all addons.", 1, 1, 1, true)
      GameTooltip:Show()
   end)
   createSnapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
   f.createSnapBtn = createSnapBtn
end

UpdateHeaderArrows = function()
   local buttons = snapshotMode and snapshotHeaderButtons or headerButtons
   local col     = snapshotMode and snapshotSortColumn or topSortColumn
   local rev     = snapshotMode and snapshotSortReversed or topSortReversed
   for _, b in ipairs(buttons) do
      if b.columnKey == col then
         b.arrowUp:SetAlpha(rev and ARROW_ACTIVE or ARROW_INACTIVE)
         b.arrowDown:SetAlpha(rev and ARROW_INACTIVE or ARROW_ACTIVE)
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

local function CreateSnapshotHeaders()
   -- Note: the horizontal separator below the headers is created by CreateTopHeaders
   -- and is frame-level (always visible). It is intentionally shared with snapshot mode.
   local xOffset = 10
   for i, col in ipairs(SNAPSHOT_COLUMNS) do
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
         if snapshotSortColumn == self.columnKey then
            snapshotSortReversed = not snapshotSortReversed
         else
            snapshotSortColumn = self.columnKey
            snapshotSortReversed = false
         end
         UpdateHeaderArrows()
         UpdateTopWindow()
      end)

      btn:Hide()  -- hidden until snapshot mode is entered
      snapshotHeaderButtons[i] = btn
      xOffset = xOffset + col.width
   end
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

   if snapshotMode then
      -- ── Snapshot mode ──────────────────────────────────────────

      -- Show/hide widget sets
      topFrame.snapshotInfoBar:Show()
      topFrame.totalCPU:Hide()
      topFrame.totalMem:Hide()
      topFrame.memBtn:Hide()
      for _, b in ipairs(intervalButtons) do b:Hide() end
      for _, b in ipairs(headerButtons) do b:Hide() end
      for _, b in ipairs(snapshotHeaderButtons) do b:Show() end

      -- Build info bar text
      if snapshotTimeStr then
         if reloadSeconds then
            topFrame.snapshotInfoBar:SetText(format("Snapshot — %s  |  Reload: ~%ds", snapshotTimeStr, reloadSeconds))
         else
            topFrame.snapshotInfoBar:SetText(format("Snapshot — %s", snapshotTimeStr))
         end
      else
         topFrame.snapshotInfoBar:SetText("Snapshot not ready yet")
      end

      -- Build index list: any addon with non-zero snapshot data
      wipe(topSortedAddons)
      for i = 1, numAddons do
         if (cpuEarly[i] or 0) > 0 or (cpuLate[i] or 0) > 0 or (memSnapshot[i] or 0) > 0 then
            topSortedAddons[#topSortedAddons + 1] = i
         end
      end

      -- Sort with reversal
      local cmp = snapshotSortFuncs[snapshotSortColumn] or snapshotSortFuncs.cpuEarly
      if snapshotSortReversed then
         sort(topSortedAddons, function(a, b) return cmp(b, a) end)
      else
         sort(topSortedAddons, cmp)
      end

      -- Update scroll
      local totalAddons = #topSortedAddons
      FauxScrollFrame_Update(topFrame.scrollFrame, totalAddons, topVisibleRows, TOP_ROW_HEIGHT)
      local offset = FauxScrollFrame_GetOffset(topFrame.scrollFrame)

      -- Render rows
      for i = 1, topVisibleRows do
         local row = topRows[i]
         local idx = offset + i
         if idx <= totalAddons then
            local addonIdx = topSortedAddons[idx]
            local name = addonNames[addonIdx] or ""

            -- CPU early
            local earlyPct = 0
            local earlyStr = "--"
            if cpuEarlyAppTime > 0 then
               earlyPct = (cpuEarly[addonIdx] or 0) / cpuEarlyAppTime * 100
               earlyStr = FormatPct(earlyPct)
            end

            -- CPU late
            local latePct = 0
            local lateStr = "--"
            if cpuLateAppTime > 0 then
               latePct = (cpuLate[addonIdx] or 0) / cpuLateAppTime * 100
               lateStr = FormatPct(latePct)
            end

            local mem = memSnapshot[addonIdx] or 0
            local r, g, b = CPUColor(earlyPct)

            row.cols[1]:SetText(name)
            row.cols[1]:SetTextColor(r, g, b)
            row.cols[2]:SetText(earlyStr)
            row.cols[2]:SetTextColor(r, g, b)
            row.cols[3]:SetText(lateStr)
            row.cols[3]:SetTextColor(CPUColor(latePct))
            row.cols[4]:SetText(FormatMemory(mem))
            row.cols[4]:SetTextColor(1, 1, 1)
            row.cols[5]:SetText("")   -- always clear; do NOT Hide() this FontString
            row:Show()
         else
            row:Hide()
         end
      end

      topFrame.statusBar:SetText(format("%d addons in snapshot", #topSortedAddons))

   else
      -- ── Live mode ──────────────────────────────────────────────

      -- Show/hide widget sets
      topFrame.snapshotInfoBar:Hide()
      topFrame.totalCPU:Show()
      topFrame.totalMem:Show()
      topFrame.memBtn:Show()
      for _, b in ipairs(intervalButtons) do b:Show() end
      for _, b in ipairs(headerButtons) do b:Show() end
      for _, b in ipairs(snapshotHeaderButtons) do b:Hide() end

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

   -- Hide snapshot buttons when feature is disabled
   if not mod.db.profile.enableSnapshot then
      topFrame.snapToggleBtn:Hide()
      topFrame.createSnapBtn:Hide()
   end
end

local function CreateTopFrame()
   local f = CreateFrame("Frame", "MagicProfilerTopFrame", UIParent, "BackdropTemplate")
   local db = mod.db.char
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
      local db = mod.db.char
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

   f.snapshotInfoBar = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   f.snapshotInfoBar:SetPoint("TOPRIGHT", -10, -35)
   f.snapshotInfoBar:SetTextColor(0.8, 0.8, 0.5)
   f.snapshotInfoBar:Hide()

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
      sampleInterval = mod.db.profile.sampleInterval
      RestartSampleTimer(mod.db.profile.ldbInterval)
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

local function EnterLiveMode()
   snapshotMode = false
   if topTimer then mod:CancelTimer(topTimer) end
   topTimer = mod:ScheduleRepeatingTimer(UpdateTopWindow, sampleInterval)
   if topFrame and topFrame.snapToggleBtn then
      topFrame.snapToggleBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
      topFrame.snapToggleBtn.text:SetText("On-Load")
   end
end

ShowTopWindow = function()
   if not topFrame then
      DismissTooltip()
      CreateTopFrame()
      CreateTopControls()
      CreateTopHeaders()
      CreateSnapshotHeaders()
      CreateTopScrollArea()
      CreateTopStatusBar()
      EnterLiveMode()
      UpdateHeaderArrows()
      UpdateTopWindow()
      -- Enable [Snap] now if TakeLateSnapshot already fired before the window was opened
      if snapshotTimeStr and topFrame.snapToggleBtn then
         topFrame.snapToggleBtn:Enable()
      end
   elseif topFrame:IsShown() then
      topFrame:Hide()
   else
      DismissTooltip()
      EnterLiveMode()
      UpdateHeaderArrows()
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

      local topN = mod.db.profile.topN
      local count = min(#sortedAddons, topN)
      for j = 1, count do
         local i = sortedAddons[j]
         local name = addonNames[i] or ""
         local mem = memUsage[i] or 0

         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, format("|cffffffff%s|r", name), "LEFT")
         tooltip:SetCell(y, 2, format("|cffffffff%s|r", FormatMemory(mem)), "RIGHT")
      end

      if #sortedAddons > topN then
         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, format("|cff808080... and %d more|r", #sortedAddons - topN), "LEFT", 2)
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

      local topN = mod.db.profile.topN
      local count = min(#sortedAddons, topN)
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

      if #sortedAddons > topN then
         y = tooltip:AddLine()
         tooltip:SetCell(y, 1, format("|cff808080... and %d more|r", #sortedAddons - topN), "LEFT", 3)
      end
   end

   tooltip:AddLine(" ")
   tooltip:AddSeparator(1)
   local cols = profilerAvailable and 3 or 2
   y = tooltip:AddLine()
   tooltip:SetCell(y, 1, "|cffeda55f" .. L["Left-click: Open Top window"] .. "|r", "LEFT", cols)
   y = tooltip:AddLine()
   tooltip:SetCell(y, 1, "|cffeda55f" .. L["Right-click: Options"] .. "|r", "LEFT", cols)
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
      elseif button == "RightButton" then
         mod:InterfaceOptionsFrame_OpenToCategory(mod.optionsEnd)
         mod:InterfaceOptionsFrame_OpenToCategory(mod.optionsMain)
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
