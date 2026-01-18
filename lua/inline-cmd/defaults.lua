---@class HighlightGroups
---@field output string
---@field error string

---@class Config
---@field events string[]
---@field runPattern string
---@field langRemapOverride table<string, string[]>
---@field hl HighlightGroups
---@field onInline fun()
---@field paddingAtEnd integer
return {
	events = { "WinEnter", "BufWrite" },
	runPattern = '%$Inline"%[(.-)%]"',
	langRemapOverride = require("inline-cmd.lang-remap"),
	hl = {
		output = "Comment",
		error = "ErrorMsg"
	},
	onInline = function ()
		vim.cmd("noautocmd write")
	end,
	paddingAtEnd = 1
}
