--- File history viewer for difftastic.nvim.
--- Shows commits that affected a specific file with difftastic diffs.
local M = {}

local binary = require("difftastic-nvim.binary")
local diff = require("difftastic-nvim.diff")
local history_tree = require("difftastic-nvim.history_tree")

--- Current history state
M.state = {
    file_path = nil,
    commits = {},
    current_commit_idx = 1,
    tree_win = nil,
    tree_buf = nil,
    left_win = nil,
    left_buf = nil,
    right_win = nil,
    right_buf = nil,
    tabpage = nil,
}

--- Reset state to initial values.
local function reset_state()
    M.state = {
        file_path = nil,
        commits = {},
        current_commit_idx = 1,
        tree_win = nil,
        tree_buf = nil,
        left_win = nil,
        left_buf = nil,
        right_win = nil,
        right_buf = nil,
        tabpage = nil,
    }
end

--- Fetch diff data for a specific commit and file.
--- @param commit table Commit object with hash
--- @param file_path string File path
--- @return table|nil File diff data
local function fetch_commit_diff(commit, file_path)
    local result = binary.get().run_diff_commit_file(commit.hash, file_path)
    if result and result.files and #result.files > 0 then
        return result.files[1]
    end
    return nil
end

--- Set up keymaps for history diff buffers.
--- @param buf number Buffer handle
local function setup_diff_keymaps(buf)
    local difft = require("difftastic-nvim")
    local keys = difft.config.keymaps

    if keys.next_file then
        vim.keymap.set("n", keys.next_file, M.next_commit, { buffer = buf })
    end
    if keys.prev_file then
        vim.keymap.set("n", keys.prev_file, M.prev_commit, { buffer = buf })
    end
    if keys.next_hunk then
        vim.keymap.set("n", keys.next_hunk, M.next_hunk, { buffer = buf })
    end
    if keys.prev_hunk then
        vim.keymap.set("n", keys.prev_hunk, M.prev_hunk, { buffer = buf })
    end
    if keys.close then
        vim.keymap.set("n", keys.close, M.close, { buffer = buf })
    end
    if keys.focus_tree then
        vim.keymap.set("n", keys.focus_tree, function()
            if M.state.tree_win and vim.api.nvim_win_is_valid(M.state.tree_win) then
                vim.api.nvim_set_current_win(M.state.tree_win)
            end
        end, { buffer = buf })
    end
end

--- Set up keymaps for history tree buffer.
local function setup_tree_keymaps()
    local difft = require("difftastic-nvim")
    local keys = difft.config.keymaps
    local buf = M.state.tree_buf

    if keys.focus_diff then
        vim.keymap.set("n", keys.focus_diff, function()
            if M.state.right_win and vim.api.nvim_win_is_valid(M.state.right_win) then
                vim.api.nvim_set_current_win(M.state.right_win)
            end
        end, { buffer = buf })
    end
    if keys.next_file then
        vim.keymap.set("n", keys.next_file, M.next_commit, { buffer = buf })
    end
    if keys.prev_file then
        vim.keymap.set("n", keys.prev_file, M.prev_commit, { buffer = buf })
    end
end

--- Open file history view.
--- @param file_path string Path to the file
function M.open(file_path)
    -- Normalize the file path
    file_path = vim.fn.fnamemodify(file_path, ":.")

    -- If already open in a tab, switch to it
    if M.state.tabpage and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
        vim.api.nvim_set_current_tabpage(M.state.tabpage)
        -- If same file, just return; otherwise close and reopen
        if M.state.file_path == file_path then
            return
        end
        M.close()
    end

    -- Fetch file history
    local result = binary.get().get_file_history(file_path)
    if not result or not result.commits or #result.commits == 0 then
        vim.notify("No history found for " .. file_path, vim.log.levels.INFO)
        return
    end

    -- Store state
    M.state.file_path = file_path
    M.state.commits = result.commits
    M.state.current_commit_idx = 1

    -- Create a new tab for history
    vim.cmd("tabnew")
    M.state.tabpage = vim.api.nvim_get_current_tabpage()

    -- Open tree sidebar
    history_tree.open(M.state)

    -- Open diff panes (reuses the window created by tabnew)
    diff.open(M.state)

    -- Set up keymaps for diff buffers
    for _, buf in ipairs({ M.state.left_buf, M.state.right_buf }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            setup_diff_keymaps(buf)
        end
    end

    -- Set up keymaps for tree buffer
    setup_tree_keymaps()

    -- Show first commit
    local first_idx = history_tree.first_commit()
    if first_idx then
        M.show_commit(first_idx)
    end

    -- Focus the right (new) pane
    if M.state.right_win and vim.api.nvim_win_is_valid(M.state.right_win) then
        vim.api.nvim_set_current_win(M.state.right_win)
    end
end

--- Close the file history view.
function M.close()
    -- Close the tab if it exists and is valid
    if M.state.tabpage and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
        -- Get all tabs to check if this is the only one
        local tabs = vim.api.nvim_list_tabpages()

        if #tabs > 1 then
            -- Switch to another tab first, then close this one
            local current_tab = vim.api.nvim_get_current_tabpage()
            if current_tab == M.state.tabpage then
                -- Find another tab to switch to
                for _, tab in ipairs(tabs) do
                    if tab ~= M.state.tabpage then
                        vim.api.nvim_set_current_tabpage(tab)
                        break
                    end
                end
            end

            -- Close all windows in the history tab
            local wins = vim.api.nvim_tabpage_list_wins(M.state.tabpage)
            for _, win in ipairs(wins) do
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_close(win, true)
                end
            end
        else
            -- Only one tab - close windows and create new buffer
            local wins = { M.state.tree_win, M.state.left_win, M.state.right_win }
            for _, win in ipairs(wins) do
                if win and vim.api.nvim_win_is_valid(win) then
                    if #vim.api.nvim_list_wins() > 1 then
                        vim.api.nvim_win_close(win, true)
                    else
                        vim.api.nvim_set_current_win(win)
                        vim.cmd("enew")
                    end
                end
            end
        end
    end

    -- Explicitly delete buffers to avoid name conflicts on reopen
    for _, buf in ipairs({ M.state.tree_buf, M.state.left_buf, M.state.right_buf }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    reset_state()
end

--- Show diff for a specific commit.
--- @param idx number Commit index (1-based)
function M.show_commit(idx)
    if idx < 1 or idx > #M.state.commits then
        return
    end

    M.state.current_commit_idx = idx
    local commit = M.state.commits[idx]

    -- Fetch and render the diff for this commit
    local file_data = fetch_commit_diff(commit, M.state.file_path)

    if file_data then
        diff.render(M.state, file_data)
    else
        -- Handle case where diff couldn't be fetched (e.g., initial commit)
        -- Show empty diff with message
        vim.bo[M.state.left_buf].modifiable = true
        vim.bo[M.state.right_buf].modifiable = true
        vim.api.nvim_buf_set_lines(M.state.left_buf, 0, -1, false, { "-- No previous version (initial commit) --" })
        vim.api.nvim_buf_set_lines(M.state.right_buf, 0, -1, false, { "-- Initial version --" })
        vim.bo[M.state.left_buf].modifiable = false
        vim.bo[M.state.right_buf].modifiable = false
    end

    history_tree.highlight_current(M.state)
end

--- Navigate to the next commit.
function M.next_commit()
    local next_idx = history_tree.next_commit(M.state.current_commit_idx)
    if next_idx then
        M.show_commit(next_idx)
    end
end

--- Navigate to the previous commit.
function M.prev_commit()
    local prev_idx = history_tree.prev_commit(M.state.current_commit_idx)
    if prev_idx then
        M.show_commit(prev_idx)
    end
end

--- Navigate to the next hunk within the current diff.
function M.next_hunk()
    diff.next_hunk(M.state)
end

--- Navigate to the previous hunk within the current diff.
function M.prev_hunk()
    diff.prev_hunk(M.state)
end

return M
