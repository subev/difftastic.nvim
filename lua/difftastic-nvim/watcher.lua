--- File watcher for automatic diff refresh.
--- Monitors .git/index for changes and triggers refresh with debouncing.
local M = {}

--- @type uv_fs_poll_t|nil
M.fs_poll = nil

--- @type uv_timer_t|nil
M.debounce_timer = nil

--- @type function|nil
M.callback = nil

--- Default debounce delay in milliseconds
M.DEBOUNCE_MS = 100

--- Default poll interval in milliseconds
M.POLL_INTERVAL_MS = 1000

--- Find the .git directory for the current working directory.
--- @return string|nil git_dir Path to .git directory or nil if not in a git repo
function M.find_git_dir()
    local handle = io.popen("git rev-parse --git-dir 2>/dev/null")
    if not handle then
        return nil
    end

    local result = handle:read("*l")
    handle:close()

    if result and result ~= "" then
        -- Make absolute if relative
        if not result:match("^/") then
            local cwd = vim.fn.getcwd()
            result = cwd .. "/" .. result
        end
        return result
    end
    return nil
end

--- Trigger the callback with debouncing.
--- Resets the timer on each call, only fires after DEBOUNCE_MS of inactivity.
local function debounced_trigger()
    if not M.callback then
        return
    end

    -- Create timer if needed
    if not M.debounce_timer then
        M.debounce_timer = vim.loop.new_timer()
    end

    -- Reset timer
    M.debounce_timer:stop()
    M.debounce_timer:start(
        M.DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
            if M.callback then
                M.callback()
            end
        end)
    )
end

--- Start watching .git/index for changes.
--- @param callback function Called when index changes (debounced)
--- @param poll_interval number|nil Poll interval in ms (default 1000)
function M.start(callback, poll_interval)
    -- Stop any existing watcher
    M.stop()

    local git_dir = M.find_git_dir()
    if not git_dir then
        return false
    end

    local index_path = git_dir .. "/index"

    -- Check if index file exists
    local stat = vim.loop.fs_stat(index_path)
    if not stat then
        return false
    end

    M.callback = callback
    M.fs_poll = vim.loop.new_fs_poll()

    local interval = poll_interval or M.POLL_INTERVAL_MS

    M.fs_poll:start(
        index_path,
        interval,
        vim.schedule_wrap(function(err)
            if not err then
                debounced_trigger()
            end
        end)
    )

    return true
end

--- Stop watching and clean up resources.
function M.stop()
    if M.fs_poll then
        M.fs_poll:stop()
        if not M.fs_poll:is_closing() then
            M.fs_poll:close()
        end
        M.fs_poll = nil
    end

    if M.debounce_timer then
        M.debounce_timer:stop()
        if not M.debounce_timer:is_closing() then
            M.debounce_timer:close()
        end
        M.debounce_timer = nil
    end

    M.callback = nil
end

--- Check if watcher is currently active.
--- @return boolean
function M.is_watching()
    return M.fs_poll ~= nil
end

return M
