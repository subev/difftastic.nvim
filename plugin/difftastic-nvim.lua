if vim.g.loaded_difftastic_nvim then
    return
end
vim.g.loaded_difftastic_nvim = true

-- Generate helptags if needed
local source = debug.getinfo(1, "S").source:sub(2)
local doc_dir = vim.fn.fnamemodify(source, ":h:h") .. "/doc"
if vim.fn.isdirectory(doc_dir) == 1 then
    vim.cmd.helptags(doc_dir)
end

vim.api.nvim_create_user_command("Difft", function(opts)
    local revset = opts.args:gsub("^['\"](.+)['\"]$", "%1")
    require("difftastic-nvim").open(revset)
end, {
    nargs = 1,
    desc = "Open difftastic diff view",
})

vim.api.nvim_create_user_command("DifftClose", function()
    require("difftastic-nvim").close()
end, {
    desc = "Close difftastic diff view",
})

vim.api.nvim_create_user_command("DifftUpdate", function()
    require("difftastic-nvim").update()
end, {
    desc = "Update difftastic-nvim binary to latest release",
})
