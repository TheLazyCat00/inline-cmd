local enabled = true
local namespaces = {}

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

local runningJobs = {}

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
---@return Comment[]
local function getLangComments(parserName)
	local bufnr = 0
	local start_line = 0
	local end_line = -1

	local _, parser = pcall(vim.treesitter.get_parser, bufnr, parserName)
	if parser == nil then
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

	for id, node, _ in query:iter_captures(root, bufnr, start_line, end_line) do
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

---@return FileComments
local function getFileComments()
	if not isTextBuffer() then
		return {}
	end

	local ftLang = vim.treesitter.language.get_lang(vim.bo.ft)
	local langs = config.langRemapOverride[ftLang] or { ftLang }

	---@type CommentAndLanguage[]
	local commentsAndLanguage = {}
	for _, lang in ipairs(langs) do
		for _, comment in ipairs(getLangComments(lang)) do
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

---@param comment Comment
---@param lang string
---@param index integer
local function inlineComment(comment, lang, index)
	local cmd = comment.content:match(config.runPattern)
	if not cmd or cmd == "" then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()

	-- make sure we have a table for this buffer
	runningJobs[bufnr] = runningJobs[bufnr] or {}

	local outputs = { stdout = {}, stderr = {} }
	local function updateVirtText()
		local nsName = "" .. lang .. index .. ""
		local nsId = namespaces[nsName] or vim.api.nvim_create_namespace(nsName)
		namespaces[nsName] = nsId

		vim.schedule(function()
			vim.api.nvim_buf_clear_namespace(bufnr, nsId, 0, -1)
			local virtLines = {}

			for _, line in ipairs(outputs.stdout) do
				table.insert(virtLines, { { line, config.hl.output } })
			end

			for _, line in ipairs(outputs.stderr) do
				table.insert(virtLines, { { line, config.hl.error } })
			end

			local totalLines = vim.api.nvim_buf_line_count(bufnr)
			local startRow = comment.endRow + 1
			local endRow = startRow

			while endRow <= totalLines do
				local line = vim.api.nvim_buf_get_lines(bufnr, endRow, endRow + 1, false)[1]

				if line ~= "" then
					break
				end

				endRow = endRow + 1
			end

			if endRow > startRow then
				vim.api.nvim_buf_set_lines(bufnr, startRow, endRow, false, {})  -- Remove +1
			end

			local emptyLines = {}
			for _ = 1, #virtLines + config.paddingAtEnd do
				table.insert(emptyLines, "")
			end
			vim.api.nvim_buf_set_lines(bufnr, startRow, startRow, false, emptyLines)

			for index, line in ipairs(virtLines) do
				if index > totalLines then return end
				local currentRow = comment.endRow + index
				vim.api.nvim_buf_set_extmark(bufnr, nsId, currentRow, 0, {
					virt_text = line,
					virt_text_pos = "eol",
					virt_text_repeat_linebreak = true
				})
			end

			config.onInline()
		end)
	end

	local jobId = vim.fn.jobstart(cmd, {
		shell = true,
		cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"),
		stdout_buffered = false,
		on_stdout = function(_, data, _)
			if not data then return end

			local output = {}
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(output, line)
				end
			end

			if #output == 0 then return end
			outputs.stdout = output

			updateVirtText()
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
			outputs.stderr = output

			updateVirtText()
		end,
	})

	runningJobs[bufnr][jobId] = true
end

local function run()
	local bufnr = vim.api.nvim_get_current_buf()

	-- kill all running jobs for this buffer
	if runningJobs[bufnr] then
		for jobId, _ in pairs(runningJobs[bufnr]) do
			if vim.fn.jobwait({jobId}, 0)[1] == -1 then
				vim.fn.jobstop(jobId)
			end
			runningJobs[bufnr][jobId] = nil
		end
	end

	local fileComments = getFileComments()
	table.sort(fileComments, function(a, b)
		return a.comment.endRow > b.comment.endRow
	end)

	for index, commentAndLang in ipairs(fileComments) do
		inlineComment(commentAndLang.comment, commentAndLang.language, index)
	end
end

local function runDispatch()
	if enabled then
		vim.schedule(run)
	end
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts)

	for _, event in ipairs(config.events) do
		vim.api.nvim_create_autocmd(event, {
			callback = runDispatch
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
end

return M
