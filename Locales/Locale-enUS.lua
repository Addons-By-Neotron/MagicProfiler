local isSilent = true
--@debug@
isSilent = false
--@end-debug@

local L = LibStub("AceLocale-3.0"):NewLocale("MagicProfiler", "enUS", true, isSilent)

-- Options: General
L["Magic Profiler"] = true
L["Magic Profiler is an LDB data source that displays addon CPU and memory usage. It requires an LDB display addon such as Button Bin, ChocolateBar, or Titan Panel."] = true
L["Sample interval"] = true
L["How often to sample and update profiler data, in seconds."] = true
L["Tooltip entries"] = true
L["Maximum number of addons to show in the LDB tooltip."] = true

-- Options: Profiles
L["Profiles"] = true

-- LDB hints
L["Left-click: Open Top window"] = true
L["Right-click: Options"] = true