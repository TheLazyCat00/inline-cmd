---@class Config
---@field events string[]
---@field runPattern string
---@field langRemapOverride table<string, string[]>

return {
	events = { "WinEnter", "BufWrite" },
	runPattern = "%$Inline%[(.-)%]",
	langRemapOverride = require("inline-cmd.lang-remap")
}
