---@class CmdOutput
---@field stdout string[]
---@field stderr string[]
---@field finished boolean

---@class CmdInfo
---@field namespace integer?
---@field cmd string
---@field output CmdOutput?

---@type table<integer, table<integer, CmdInfo>>
local cmds = {}
local enabled = true

---@type table<integer, table<integer, integer>>
local runningJobs = {}

---@type Config
local config = require("inline-cmd.defaults")

---@class CommentAndLanguage
---@field comment Comment
---@field language ParserLanguage

---@alias ParserLanguage string
---@class Comment
---@field content string
---@field startRow integer
---@field startColumn integer
---@field endRow integer
---@field endColumn integer

---@alias FileComments CommentAndLanguage[]

local M = {}

local function debug(msg)
	vim.notify(vim.inspect(msg), vim.log.levels.INFO)
end

---@param tbl table
---@return integer
local function size(tbl)
	local count = 0
	for _ in pairs(tbl) do
		count = count + 1
	end

	return count
end

---@param parserName string
---@param bufnr integer
---@return Comment[]
local function getLangComments(parserName, bufnr)
	local startLine = 0
	local endLine = -1

	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, parserName)
	if not ok or parser == nil then
		return {}
	end

	local tree = parser:parse()[1]
	local root = tree:root()

	local _, query = pcall(vim.treesitter.query.get, parserName, "highlights")
	if query == nil then
		return {}
	end

	local comments = {}
	local seen = {}

	for id, node, _ in query:iter_captures(root, bufnr, startLine, endLine) do
		local captureName = query.captures[id]

		if captureName:match("^comment") then
			local parent = node:parent()
			if parent and parent:type():match("comment") then
				goto continue
			end

			local sr, sc, er, ec = node:range()
			local key = string.format("%d:%d:%d:%d", sr, sc, er, ec)
			if not seen[key] then
				seen[key] = true

				local comment = {
					content = vim.treesitter.get_node_text(node, bufnr),
					startRow = sr,
					startColumn = sc,
					endRow = er,
					endColumn = ec,
				}

				table.insert(comments, comment)
			end
		end

		::continue::
	end

	return comments
end

---@return boolean
local function isTextBuffer()
	return vim.bo.buftype == ""
end

---@param bufnr integer
---@return FileComments
local function getFileComments(bufnr)
	if not isTextBuffer() then
		return {}
	end

	local ftLang = vim.treesitter.language.get_lang(vim.bo.ft)
	local langs = config.langRemapOverride[ftLang] or { ftLang }

	---@type CommentAndLanguage[]
	local commentsAndLanguage = {}
	for _, lang in ipairs(langs) do
		for _, comment in ipairs(getLangComments(lang, bufnr)) do
			---@type CommentAndLanguage
			local commentAndLanguage = {
				comment = comment,
				language = lang,
			}
			table.insert(commentsAndLanguage, commentAndLanguage)
		end
	end

	return commentsAndLanguage
end

---@param cmdIndex integer
---@param row integer
---@param bufnr integer
---@param onModifyBuffer fun()
local function updateVirtText(cmdIndex, row, bufnr, onModifyBuffer)
	local bufferCmds = cmds[bufnr]
	local currentCmd = bufferCmds[cmdIndex]

	local nsId = currentCmd.namespace or vim.api.nvim_create_namespace(bufnr .. "|" .. cmdIndex)
	currentCmd.namespace = nsId

	vim.schedule(function()
		vim.api.nvim_buf_clear_namespace(bufnr, nsId, 0, -1)
		local virtLines = {}

		for _, line in ipairs(currentCmd.output.stdout) do
			table.insert(virtLines, { { line, config.hl.output } })
		end

		for _, line in ipairs(currentCmd.output.stderr) do
			table.insert(virtLines, { { line, config.hl.error } })
		end

		local totalLines = vim.api.nvim_buf_line_count(bufnr)
		local startRow = row + 1
		local endRow = startRow

		while endRow <= totalLines do
			local line = vim.api.nvim_buf_get_lines(bufnr, endRow, endRow + 1, false)[1]

			if line ~= "" then
				break
			end

			endRow = endRow + 1
		end


		local function applyVirtualLines()
			local newTotalLines = vim.api.nvim_buf_line_count(bufnr)
			for index, line in ipairs(virtLines) do
				local currentRow = row + index
				if currentRow > newTotalLines then return end
				vim.api.nvim_buf_set_extmark(bufnr, nsId, currentRow, 0, {
					virt_text = line,
					virt_text_pos = "eol",
					virt_text_repeat_linebreak = true
				})
			end
		end

		local mode = vim.api.nvim_get_mode().mode
		local inInsert = mode:sub(1, 1) == "i"
		if inInsert then
			applyVirtualLines()
		end

		local newCmdEnding = #virtLines + row + config.paddingAtEnd + 1
		if endRow < newCmdEnding then
			local amountNewLines = newCmdEnding - endRow
			local emptyLines = {}
			for _ = 1, amountNewLines do
				table.insert(emptyLines, "")
			end
			vim.api.nvim_buf_set_lines(bufnr, endRow, endRow, false, emptyLines)
			onModifyBuffer()
		elseif endRow > newCmdEnding then
			vim.api.nvim_buf_set_lines(bufnr, newCmdEnding, endRow, false, {})
			onModifyBuffer()
		end

		applyVirtualLines()
	end)
end

---@param comment Comment
---@param lang string
---@param index integer
---@param forceUpdate boolean
---@param bufnr integer
local function inlineComment(comment, lang, index, forceUpdate, bufnr)
	local reuseOldOutput = not forceUpdate

	local cmd = comment.content:match(config.runPattern)
	if not cmd or cmd == "" then
		return
	end

	-- make sure we have a table for this buffer
	runningJobs[bufnr] = runningJobs[bufnr] or {}
	local bufferCmds = cmds[bufnr] or {}
	cmds[bufnr] = bufferCmds

	---@type CmdInfo
	local currentCmd = bufferCmds[index]

	if reuseOldOutput and currentCmd  then
		if currentCmd.cmd == cmd and currentCmd.output.finished then
			updateVirtText(index, comment.endRow, bufnr, config.onModifyBuffer)
			return
		else
			local jobId = runningJobs[bufnr][index]
			if vim.fn.jobwait({jobId}, 0)[1] == -1 then
				vim.fn.jobstop(jobId)
			end
		end
	end

	currentCmd = {
		namespace = nil,
		cmd = cmd,
		output = {stdout = {}, stderr = {}, finished = false }
	}
	bufferCmds[index] = currentCmd

	local modifiedBuffer = false

	local jobId = vim.fn.jobstart(cmd, {
		shell = true,
		cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"),
		stdout_buffered = false,
		on_exit = function ()
			currentCmd.output.finished = true
			if modifiedBuffer then
				config.onModifyBuffer()
			end
		end,
		on_stdout = function(_, data, _)
			if not data then return end

			local output = {}
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(output, line)
				end
			end

			if #output == 0 then return end
			currentCmd.output.stdout = output

			updateVirtText(index, comment.endRow, bufnr, function ()
				modifiedBuffer = true
			end)
		end,
		on_stderr = function(_, data, _)
			if not data then return end

			local output = {}
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(output, line)
				end
			end

			if #output == 0 then return end
			currentCmd.output.stderr = output

			updateVirtText(index, comment.endRow, bufnr, function ()
				modifiedBuffer = true
			end)
		end,
	})

	runningJobs[bufnr][index] = jobId
end

---@param forceUpdate boolean
local function run(forceUpdate)
	local bufnr = vim.api.nvim_get_current_buf()

	local fileComments = getFileComments(bufnr)
	table.sort(fileComments, function(a, b)
		return a.comment.endRow > b.comment.endRow
	end)

	for index, commentAndLang in ipairs(fileComments) do
		index = #fileComments + 1 - index
		inlineComment(commentAndLang.comment, commentAndLang.language, index, forceUpdate, bufnr)
	end

	local bufferCmds = cmds[bufnr] or {}
	for index, cmd in ipairs(bufferCmds) do
		if index > #fileComments then
			vim.api.nvim_buf_clear_namespace(bufnr, cmd.namespace, 0, -1)
			cmds[bufnr][index] = nil
		end
	end
end

---@param forceUpdate boolean
local function runDispatch(forceUpdate)
	if enabled then
		vim.schedule(function ()
			run(forceUpdate)
		end)
	end
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts)

	for _, event in ipairs(config.events) do
		vim.api.nvim_create_autocmd(event, {
			callback = function ()
				runDispatch(false)
			end
		})
	end

	vim.api.nvim_create_user_command("InlineCmdEnable",
		function ()
			enabled = true
			vim.notify("inline-cmd enabled", vim.log.levels.INFO)
		end
		, {})

	vim.api.nvim_create_user_command("InlineCmdDisable",
		function ()
			enabled = false
			vim.notify("inline-cmd disabled", vim.log.levels.INFO)
		end
		, {})

	vim.api.nvim_create_user_command("InlineCmdUpdate",
		function ()
			runDispatch(true)
		end
		, {})
end

return M
