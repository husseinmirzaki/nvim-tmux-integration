local M = {}

local state = {
    debug = true,
    sessions = {},
}

-- Open a floating scratch window and display `message`.
-- Sets up a minimal floating window and buffer for interaction.
-- 'q' closes the window; '<space>' toggles the session selection on the current line.
function M.create_window_and_show_message(message, opts)
    opts = opts or {}
    local allow_select = opts.allow_select
    if allow_select == nil then allow_select = true end

    -- Get the dimensions of the current window
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.4)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create a new scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)

    -- Set buffer options
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
    vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = buf })

    -- Create a floating window
    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded'
    })

    -- Optional: Set some window options
    vim.api.nvim_set_option_value('number', false, { win = win })
    vim.api.nvim_set_option_value('relativenumber', false, { win = win })

    -- If there are sessions available and no explicit message, render them.
    if (not message or message == "") and #state.sessions > 0 then
        M.refresh_window_content(buf, win)
    else
        -- Insert the message into the buffer (may be empty string)
        vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, vim.split(message or "", "\n"))
    end

    -- Always map 'q' to close the window.
    vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
        noremap = true,
        silent = true,
        nowait = true,
        callback = function()
            vim.api.nvim_win_close(win, true)
        end
    })

    -- Only set up session toggling when allowed.
    if allow_select then
        vim.api.nvim_buf_set_keymap(buf, 'n', '<space>', '', {
            noremap = true,
            silent = true,
            nowait = true,
            callback = function()
                local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
                if state.sessions[cursor_line] then
                    state.sessions[cursor_line].selected = not state.sessions[cursor_line].selected
                    M.refresh_window_content(buf, win)
                end
            end
        })
    end
end

function M.refresh_window_content(buf, win)
    -- Rebuild the display with selection indicators
    -- Shows a marker ([✓] or [ ]) per session, appends a JSON debug line,
    -- then replaces all buffer lines atomically and requests a redraw.
    local lines = {}
    for i, session in ipairs(state.sessions) do
        local marker = session.selected and "[✓] " or "[ ] "
        table.insert(lines, string.format("%sSession ID: %s, Name: %s, Windows: %s, Attached: %s, Neovim: %s",
            marker, session.id, session.name, #session.windows, session.attached, session.has_nvim and "yes" or "no"))
    end
    if M.debug then
        table.insert(lines, "")
        -- Debug output: append JSON of all sessions for quick inspection
        table.insert(lines, vim.fn.json_encode(state.sessions))
    end

    -- Clear buffer and insert updated content
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

    -- Trigger rendering
    vim.cmd('redraw')
end

-- Run a shell command and return its stdout as a string, or nil on failure.
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

-- Query tmux for sessions, populate `state.sessions`, and return a printable listing.
-- Each session entry includes id, name, list of windows, attached flag, and a `selected` boolean.
function M.tmux_session_list()
    local output = M.run_bash_command_and_get_output(
        "tmux list-sessions -F '#{session_id}||__||#{session_name}||__||#{session_windows}||__||#{session_attached}'")
    if output == nil then
        return "No tmux sessions found."
    end
    local split_output = vim.split(output, "\n")
    output = ""
    local new_sessions = {}
    for i, line in ipairs(split_output) do
        if line ~= "" then
            local parts = vim.split(line, "||__||")
            -- preserve previous selection if possible
            local prev_selected = nil
            for _, s in ipairs(state.sessions) do
                if s.id == parts[1] then
                    prev_selected = s.selected
                    break
                end
            end
            local selected = (prev_selected == nil) and true or prev_selected

            local session = {
                id = parts[1],
                name = parts[2],
                windows = {},
                attached = parts[4],
                selected = selected,
                has_nvim = false
            }

            -- find each windows path
            for window_index = 0, tonumber(parts[3]) - 1 do
                local window_output = M.run_bash_command_and_get_output(
                    string.format(
                        "tmux list-windows -t %s -F '#{window_index}||__||#{window_name}||__||#{pane_current_path}' | grep '^%d||__||'",
                        parts[2], window_index))
                if window_output == nil then
                    break
                end
                local window_parts = vim.split(window_output, "||__||")
                local pane_path = window_parts[3]:gsub("\n", "")
                if #window_parts >= 3 then
                    local win_entry = {
                        index = window_parts[1],
                        name = window_parts[2],
                        path = pane_path,
                        has_nvim = false
                    }

                    -- Check panes in the window for running nvim/vim (record pane index)
                    local panes_output = M.run_bash_command_and_get_output(
                        string.format("tmux list-panes -t %s:%s -F '#{pane_index}||__||#{pane_current_command}'",
                            parts[2], window_index))
                    if panes_output then
                        for pane_line in string.gmatch(panes_output, "([^\n]+)") do
                            local pane_parts = vim.split(pane_line, "||__||")
                            local pane_index = pane_parts[1]
                            local pane_cmd = pane_parts[2] or ""
                            if pane_cmd:match("n?vim") then
                                win_entry.has_nvim = true
                                win_entry.nvim_pane = pane_index
                                break
                            end
                        end
                    end

                    if win_entry.has_nvim then
                        session.has_nvim = true
                    end

                    table.insert(session.windows, win_entry)
                end
            end

            table.insert(new_sessions, session)

            output = output .. string.format("%sSession ID: %s, Name: %s, Windows: %s, Attached: %s\n",
                (session.selected and "[✓] " or "[ ] "), parts[1], parts[2], parts[3], parts[4])
        end
    end
    state.sessions = new_sessions
    -- add as json_encoded data at the end
    output = output .. "\n" .. vim.fn.json_encode(state.sessions)
    return output
end

-- Find the session that best matches a given buffer path.
-- The match must start at the beginning of the path; among matches the
-- session with the longest matching window path is returned (best prefix).
M.find_session_by_buffer_path = function(buffer_path)
    local max_path_size = 0
    local max_session = nil
    for _, session in ipairs(state.sessions) do
        for _, window in ipairs(session.windows) do
            if string.find(buffer_path, window.path, 1, true) == 1 then
                if #window.path > max_path_size then
                    max_path_size = #window.path
                    max_session = session
                end
            end
        end
    end
    return max_session
end

-- Collect selected session window paths and invoke Telescope live_grep.
-- When an entry is selected, we use `actions.select_default:enhance` so a
-- `post` hook runs after Telescope's default action (which by default opens
-- the selected result). This allows inspecting which session the selected
-- file belongs to (without preventing Telescope from handling the selection).
M.open_telescope_and_search = function()
    local session_paths = {}
    for _, session in ipairs(state.sessions) do
        if session.selected then
            for _, window in ipairs(session.windows) do
                table.insert(session_paths, window.path)
            end
        end
    end

    if #session_paths == 0 then
        print("No sessions selected for search.")
        return
    end

    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    require('telescope.builtin').live_grep({
        search_dirs = session_paths,
        attach_mappings = function(prompt_bufnr, map)
            local function switch_session()
                local entry = action_state.get_selected_entry()
                local path = entry and (entry.path or entry.filename or entry.value)
                local session = M.find_session_by_buffer_path(path)
                if not session or not session.has_nvim then
                    print("No tmux session found for selected file or is not using nvim")
                    return
                end

                local switch_to = session.windows[1]
                for window_index, window in ipairs(session.windows) do
                    if window.has_nvim then
                        switch_to = window
                        break
                    end
                end
                -- Try switching tmux client to the session id (or name as fallback).
                local switch_cmd = string.format("tmux switch-client -t %s", session.name)
                if state.debug then print("Running: " .. switch_cmd) end
                local switch_out = M.run_bash_command_and_get_output(switch_cmd)
                if state.debug then print("switch-client output: " .. vim.inspect(switch_out)) end

                -- Select the desired window (and pane if detected)
                local select_window_cmd = string.format("tmux select-window -t %s:%s", session.name, switch_to.index)
                if state.debug then print("Running: " .. select_window_cmd) end
                local select_window_out = M.run_bash_command_and_get_output(select_window_cmd)
                if state.debug then print("select-window output: " .. vim.inspect(select_window_out),
                        vim.log.levels.WARN) end

                if switch_to.nvim_pane then
                    local select_pane_cmd = string.format("tmux select-pane -t %s:%s.%s", session.name, switch_to.index,
                        switch_to.nvim_pane)
                    if state.debug then print("Running: " .. select_pane_cmd) end
                    local select_pane_out = M.run_bash_command_and_get_output(select_pane_cmd)
                    if state.debug then print("select-pane output: " .. vim.inspect(select_pane_out),
                            vim.log.levels.WARN) end
                end
                -- Prepare to open the target file in the Neovim instance running in the target tmux pane by sending keystrokes.

                -- Sanitize path: escape single quotes for safe embedding inside a single-quoted shell string, and escape double quotes for use inside the Vim :edit argument.
                local safe_path = path:gsub("'", "'\\''")
                local safe_path_dq = safe_path:gsub('"', '\\"')

                -- Determine target line number (checks `lnum`, `row`, `line` on the entry, then parses ":<num>:" in the value); if present, we prepend a `+<line>` argument to `:edit`.
                local line = nil
                if entry and entry.lnum then
                    line = tonumber(entry.lnum)
                elseif entry and entry.row then
                    line = tonumber(entry.row)
                elseif entry and entry.line then
                    line = tonumber(entry.line)
                else
                    local parsed = tonumber((entry and entry.value or ""):match(":(%d+):"))
                    if parsed then line = parsed end
                end
                local line_arg = ""
                if line and line > 0 then
                    line_arg = "+" .. tostring(line) .. " "
                end

                -- Ensure Neovim is in Normal mode (send Escape) so the following ex command is received correctly.
                local cmd1 = string.format("tmux send-keys -t %s:%s.%s Escape", session.name, switch_to.index, switch_to.nvim_pane)
                if state.debug then print("Running: " .. cmd1) end
                local out1 = M.run_bash_command_and_get_output(cmd1)
                if state.debug then print("send-keys (C-c) output: " .. vim.inspect(out1)) end

                -- Short pause to let tmux/neovim process the Escape
                -- os.execute("sleep 0.05")

                -- Send the literal ':silent! edit {+line} "{path}"' characters via `tmux send-keys -l` (double-quoted path) so the target Neovim opens the file at the given line.
                local cmd2 = string.format("tmux send-keys -t %s:%s.%s -l ':silent! edit %s %s'", session.name, switch_to.index,
                    switch_to.nvim_pane, line_arg, safe_path_dq)
                if state.debug then print("Running: " .. cmd2) end
                local out2 = M.run_bash_command_and_get_output(cmd2)
                if state.debug then print("send-keys (:e) output: " .. vim.inspect(out2)) end

                -- os.execute("sleep 0.05")

                -- press Enter
                local cmd3 = string.format("tmux send-keys -t %s:%s.%s Enter", session.name, switch_to.index,
                    switch_to.nvim_pane)
                if state.debug then print("Running: " .. cmd3) end
                local out3 = M.run_bash_command_and_get_output(cmd3)
                if state.debug then print("send-keys (Enter) output: " .. vim.inspect(out3)) end

                -- Close Telescope
                actions.close(prompt_bufnr)
            end

            map('i', '<CR>', switch_session)
            map('n', '<CR>', switch_session)
            return true
        end,
    })
end

-- Setup plugin user command and convenient keymaps
-- - :SessionManager opens the sessions floating window
-- - :SessionManager search launches a live_grep over selected sessions
function M.setup()
    vim.api.nvim_create_user_command('SessionManager', function(options)
        local in_tmux = vim.env.TMUX or os.getenv("TMUX")
        if not in_tmux then
            M.create_window_and_show_message(
            "SessionManager: Not running inside a tmux session.\nPlease attach to a tmux session and run :SessionManager again.",
                { allow_select = false })
            return
        end
        if #options.args == 0 then
            M.tmux_session_list()
            M.create_window_and_show_message(nil, { allow_select = true })
        elseif options.args == "search" then
            M.open_telescope_and_search()
        end
    end, { nargs = "*" })
    -- global keymaps to open the manager or search selected sessions
    vim.api.nvim_set_keymap('n', '<leader>sm', ':SessionManager<CR>', { noremap = true, silent = true })
    vim.api.nvim_set_keymap('n', '<leader>sf', ':SessionManager search<CR>', { noremap = true, silent = true })
end

return M
