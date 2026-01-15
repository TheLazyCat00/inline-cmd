---@class Config
---@field runPattern string
---@field langRemapOverride table<string, string[]>

return {
	runPattern = "%$Inline%[(.-)%]",
	langRemapOverride = require("inline-cmd.lang-remap")
}
