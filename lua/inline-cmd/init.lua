local ns = vim.api.nvim_create_namespace("inline-cmd")
local enabled = true

---@type Config
local config = require("inline-cmd.defaults")

---@alias ParserLanguage string
---@class Comment
---@field content string
---@field startRow integer
---@field startColumn integer
---@field endRow integer
---@field endColumn integer

---@alias SingleLangComments Comment[]
---@alias FileComments table<ParserLanguage, SingleLangComments>

local M = {}

local runningJobs = {}

---@param parserName string
---@return SingleLangComments
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

	local commentsPerLanguage = {}
	for _, lang in ipairs(langs) do
		commentsPerLanguage[lang] = getLangComments(lang)
	end

	return commentsPerLanguage
end

---@param comment Comment
local function inlineComment(comment)
	local cmd = comment.content:match(config.runPattern)
	if not cmd or cmd == "" then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()

	-- make sure we have a table for this buffer
	runningJobs[bufnr] = runningJobs[bufnr] or {}

	local jobId = vim.fn.jobstart(cmd, {
		shell = true,
		cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"),
		stdout_buffered = false,
		on_stdout = function(_, data, _)
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
			vim.schedule(function()
				if not data then return end

				local output = {}
				for _, line in ipairs(data) do
					if line ~= "" then
						table.insert(output, line)
					end
				end

				if #output == 0 then return end

				local virt_lines = {}
				for _, line in ipairs(output) do
					table.insert(virt_lines, { { line, "Comment" } })
				end

				vim.api.nvim_buf_set_extmark(bufnr, ns, comment.endRow, 0, {
					virt_lines = virt_lines,
					virt_lines_above = false,
				})
			end)
		end,
		on_stderr = function(_, data, _)
			vim.schedule(function()
				if not data then return end
				local errors = vim.tbl_filter(function(l) return l ~= "" end, data)
				if #errors > 0 then
					vim.notify("Error: " .. table.concat(errors, "\n"), vim.log.levels.ERROR)
				end
			end)
		end,
	})

	runningJobs[bufnr][jobId] = true
end

---@param lang ParserLanguage
---@param comments SingleLangComments
local function inlineLangComments(lang, comments)
	for _, comment in ipairs(comments) do
		inlineComment(comment)
	end
end

local function run()
	local bufnr = vim.api.nvim_get_current_buf()

	-- kill all running jobs for this buffer
	if runningJobs[bufnr] then
		for job_id, _ in pairs(runningJobs[bufnr]) do
			if vim.fn.jobwait({job_id}, 0)[1] == -1 then
				vim.fn.jobstop(job_id)
			end
			runningJobs[bufnr][job_id] = nil
		end
	end

	local fileComments = getFileComments()
	for lang, comments in pairs(fileComments) do
		inlineLangComments(lang, comments)
	end
end

local function runDispatch()
	if enabled then
		vim.schedule(run)
	end
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts)

	vim.api.nvim_create_autocmd("WinEnter", {
		callback = runDispatch
	})

	vim.api.nvim_create_autocmd("BufWrite", {
		callback = runDispatch
	})

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
