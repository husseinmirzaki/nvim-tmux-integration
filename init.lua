local M = {}

local state = {
	debug = true,
	sessions = {},
	marks = {},
}

-- 1. UTILS
function M.run_bash_command_and_get_output(cmd)
	local handle = io.popen(cmd)
	if handle then
		local result = handle:read("*a")
		handle:close()
		return result
	else
		return nil
	end
end

-- 2. MARKING LOGIC
function M.mark_current_position()
	local path = vim.fn.expand("%:p")
	if path == "" or vim.bo.buftype ~= "" then
		print("Cannot mark this buffer")
		return
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local name = vim.fn.expand("%:t")

	table.insert(state.marks, {
		path = path,
		line = line,
		name = name,
	})
	print(string.format("📌 Marked: %s at line %d", name, line))
end

-- 3. JUMPING LOGIC
function M.perform_jump(path, line)
	-- Refresh session state before jumping to ensure tmux IDs are current
	M.tmux_session_list()
	local session = M.find_session_by_buffer_path(path)

	if not session or not session.has_nvim then
		print("No active tmux/nvim session found for this path.")
		return
	end

	local target_win = nil
	for _, win in ipairs(session.windows) do
		if win.has_nvim then
			target_win = win
			break
		end
	end

	if not target_win then
		return
	end

	os.execute(string.format("tmux switch-client -t %s", session.name))
	os.execute(string.format("tmux select-window -t %s:%s", session.name, target_win.index))
	os.execute(string.format("tmux select-pane -t %s:%s.%s", session.name, target_win.index, target_win.nvim_pane))

	local safe_path = path:gsub("'", "'\\''"):gsub('"', '\\"')
	local keys = string.format("Escape ':silent! edit +%d %s' Enter", line, safe_path)
	os.execute(
		string.format("tmux send-keys -t %s:%s.%s %s", session.name, target_win.index, target_win.nvim_pane, keys)
	)
end

-- 4. THE TWO DISTINCT WINDOWS

-- WINDOW A: MARKS MANAGER
function M.open_marks_window()
	local width, height = math.floor(vim.o.columns * 0.5), math.floor(vim.o.lines * 0.4)
	local row, col = math.floor((vim.o.lines - height) / 2), math.floor((vim.o.columns - width) / 2)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Saved Marks ",
	})

	local function render()
		local lines = {
			"  Enter: Jump | d: Delete | q: Close",
			"──────────────────────────────────────",
		}
		if #state.marks == 0 then
			table.insert(lines, "   (No marks saved)")
		else
			for i, mark in ipairs(state.marks) do
				table.insert(lines, string.format(" [%d] %s (Line: %d)", i, mark.name, mark.line))
			end
		end
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	end

	render()

	-- Mappings for Marks
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })
	vim.keymap.set("n", "d", function()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		local idx = line - 2 -- account for headers
		if state.marks[idx] then
			table.remove(state.marks, idx)
			render()
		end
	end, { buffer = buf })
	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		local idx = line - 2
		if state.marks[idx] then
			local mark = state.marks[idx]
			vim.api.nvim_win_close(win, true)
			M.perform_jump(mark.path, mark.line)
		end
	end, { buffer = buf })
end

-- WINDOW B: SESSION MANAGER (Original functionality)
function M.open_sessions_window()
	M.tmux_session_list()
	local width, height = math.floor(vim.o.columns * 0.7), math.floor(vim.o.lines * 0.4)
	local row, col = math.floor((vim.o.lines - height) / 2), math.floor((vim.o.columns - width) / 2)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Tmux Sessions ",
	})

	local function render()
		local lines = {
			"  Space: Toggle for Search | q: Close",
			"──────────────────────────────────────",
		}
		for _, session in ipairs(state.sessions) do
			local marker = session.selected and "[✓] " or "[ ] "
			table.insert(lines, string.format(" %s%s (Windows: %s)", marker, session.name, #session.windows))
		end
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	end

	render()

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })
	vim.keymap.set("n", "<space>", function()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		local idx = line - 2
		if state.sessions[idx] then
			state.sessions[idx].selected = not state.sessions[idx].selected
			render()
		end
	end, { buffer = buf })
end

-- 5. TMUX DATA FETCHING
function M.tmux_session_list()
	local output = M.run_bash_command_and_get_output(
		"tmux list-sessions -F '#{session_id}||__||#{session_name}||__||#{session_windows}||__||#{session_attached}'"
	)
	if not output then
		return
	end

	local split_output = vim.split(output, "\n")
	local new_sessions = {}

	for _, line in ipairs(split_output) do
		if line ~= "" then
			local parts = vim.split(line, "||__||")
			local prev_selected = nil
			for _, s in ipairs(state.sessions) do
				if s.id == parts[1] then
					prev_selected = s.selected
					break
				end
			end

			local session = {
				id = parts[1],
				name = parts[2],
				windows = {},
				attached = parts[4],
				selected = (prev_selected == nil) and true or prev_selected,
				has_nvim = false,
			}

			local win_count = tonumber(parts[3]) or 0
			for i = 0, win_count - 1 do
				local win_out = M.run_bash_command_and_get_output(
					string.format(
						"tmux list-windows -t %s -F '#{window_index}||__||#{window_name}||__||#{pane_current_path}' | grep '^%d||__||'",
						parts[2],
						i
					)
				)
				if win_out then
					local w_parts = vim.split(win_out, "||__||")
					local win_entry = { index = w_parts[1], path = (w_parts[3] or ""):gsub("\n", ""), has_nvim = false }
					local p_out = M.run_bash_command_and_get_output(
						string.format(
							"tmux list-panes -t %s:%s -F '#{pane_index}||__||#{pane_current_command}'",
							parts[2],
							i
						)
					)
					if p_out then
						for p_line in string.gmatch(p_out, "([^\n]+)") do
							local p_parts = vim.split(p_line, "||__||")
							if (p_parts[2] or ""):match("n?vim") then
								win_entry.has_nvim = true
								win_entry.nvim_pane = p_parts[1]
								session.has_nvim = true
								break
							end
						end
					end
					table.insert(session.windows, win_entry)
				end
			end
			table.insert(new_sessions, session)
		end
	end
	state.sessions = new_sessions
end

M.find_session_by_buffer_path = function(buffer_path)
	local max_path_size, max_session = 0, nil
	for _, session in ipairs(state.sessions) do
		for _, window in ipairs(session.windows) do
			if string.find(buffer_path, window.path, 1, true) == 1 then
				if #window.path > max_path_size then
					max_path_size, max_session = #window.path, session
				end
			end
		end
	end
	return max_session
end

-- 6. TELESCOPE SEARCH
M.open_telescope_and_search = function()
	local paths = {}
	for _, s in ipairs(state.sessions) do
		if s.selected then
			for _, w in ipairs(s.windows) do
				table.insert(paths, w.path)
			end
		end
	end
	if #paths == 0 then
		return
	end
	require("telescope.builtin").live_grep({
		search_dirs = paths,
		attach_mappings = function(prompt_bufnr, map)
			local function jump()
				local entry = require("telescope.actions.state").get_selected_entry()
				require("telescope.actions").close(prompt_bufnr)
				M.perform_jump(entry.path or entry.filename, entry.lnum or 1)
			end
			map("i", "<CR>", jump)
			map("n", "<CR>", jump)
			return true
		end,
	})
end

-- 7. SETUP
function M.setup()
	vim.api.nvim_create_user_command("SessionManager", function(opts)
		if opts.args == "search" then
			M.open_telescope_and_search()
		elseif opts.args == "mark" then
			M.mark_current_position()
		else
			M.open_sessions_window()
		end
	end, { nargs = "*" })

	vim.api.nvim_create_user_command("MarksManager", function()
		M.open_marks_window()
	end, {})

	-- Keymaps
	vim.keymap.set("n", "<leader>sm", ":SessionManager<CR>", { desc = "Tmux Sessions" })
	vim.keymap.set("n", "<leader>sf", ":SessionManager search<CR>", { desc = "Search Selected Sessions" })
	vim.keymap.set("n", "<leader>sa", ":SessionManager mark<CR>", { desc = "Mark Current File/Line" })
	vim.keymap.set("n", "<leader>sl", ":MarksManager<CR>", { desc = "List Marks" }) -- SL for "Session List" or "Saved List"
end

return M
