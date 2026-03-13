local isSilent = true
--@debug@
isSilent = false
--@end-debug@

local L = LibStub("AceLocale-3.0"):NewLocale("MagicProfiler", "enUS", true, isSilent)

-- Options: General
L["Magic Profiler"] = true
L["Magic Profiler is an LDB data source that displays addon CPU and memory usage. It requires an LDB display addon such as Button Bin, ChocolateBar, or Titan Panel."] = true
L["LDB update interval"] = true
L["How often to update the LDB button text with the current CPU load, in seconds. This runs continuously in the background."] = true
L["Top window interval"] = true
L["How often to refresh the Top window while it is open, in seconds."] = true
L["Tooltip entries"] = true
L["Maximum number of addons to show in the LDB tooltip."] = true
L["Enable load snapshot"] = true
L["Capture on-load CPU usage for all addons. When disabled, snapshot buttons are hidden and no load data is collected."] = true

-- Options: Profiles
L["Profiles"] = true

-- LDB hints
L["Left-click: Open Top window"] = true
L["Right-click: Options"] = true