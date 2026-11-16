-- Headless smoke tests with a fake backend.
-- Run: nvim --headless --clean -u NONE -l tests/run.lua   (from the repo root)

vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "
vim.o.columns, vim.o.lines = 80, 24

local seen = {}
local ie = require("kip")
ie.setup({
  flash_ms = 0,
  backend = function(req, on_done)
    seen[#seen + 1] = req
    local instr = req.user:match("Instruction: (.*)$")
    local out
    if instr == "upper" then
      out = vim.fn.toupper(req.selection)
    elseif instr == "fenced" then
      out = "```lua\n" .. req.selection:upper() .. "\n```\n"
    else
      out = instr
    end
    vim.defer_fn(function()
      on_done(out)
    end, 20)
    return function() end
  end,
})

local failed = 0
local function keys(s, mode)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), mode or "mxt", false)
end
local function wait(cond, what)
  if not vim.wait(2000, cond, 10) then
    error("timeout waiting for " .. what .. "; buffer: " .. vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
  end
end
local function print(msg)
  io.stdout:write(msg .. "\n")
end
local function in_prompt()
  return vim.bo.filetype == "kip_prompt"
end
local function buf_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- keys: operator+motion; instruction: typed into the prompt (nil = no prompt expected)
local function case(name, lines, cursor, op_keys, instruction, expected)
  local ok, err = pcall(function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, cursor)
    local buf = vim.api.nvim_get_current_buf()
    local n = #seen
    keys(op_keys)
    if instruction then
      wait(in_prompt, "prompt window")
      keys("i" .. instruction .. "<CR>")
    end
    wait(function()
      return #seen > n and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected)
    end, "result; got " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
    assert(vim.api.nvim_get_current_buf() == buf, "focus did not return to the buffer")
    assert(vim.fn.mode() == "n", "not back in normal mode: " .. vim.fn.mode())
  end)
  if ok then
    print("ok   " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

case("inner word", { "hello world foo" }, { 1, 7 }, " kiw", "upper", { "hello WORLD foo" })
case("inside parens", { "call(a, b) + x" }, { 1, 6 }, " ki(", "upper", { "call(A, B) + x" })
case("a paragraph", { "one", "two", "", "three" }, { 1, 0 }, " kip", "upper", { "ONE", "TWO", "", "three" })
case("motion with count", { "a b c d e" }, { 1, 0 }, " k3w", "upper", { "A B C d e" })
case("to end of line", { "keep this change that" }, { 1, 10 }, " k$", "upper", { "keep this CHANGE THAT" })
case("current line", { "  x = 1", "  y = 2" }, { 2, 3 }, " kk", "upper", { "  x = 1", "  Y = 2" })
case("line with count", { "a", "b", "c" }, { 1, 0 }, "2 kk", "upper", { "A", "B", "c" })
case("visual charwise", { "hello world" }, { 1, 0 }, "ve k", "upper", { "HELLO world" })
case("visual linewise", { "a", "b", "c" }, { 2, 0 }, "Vj k", "upper", { "a", "B", "C" })
case("visual multi-line charwise", { "abc def", "ghi jkl" }, { 1, 4 }, "vj k", "upper", { "abc DEF", "GHI Jkl" })
case("multibyte", { "привет мир!" }, { 1, 13 }, " kiw", "upper", { "привет МИР!" })
case("code fences stripped", { "foo bar" }, { 1, 0 }, " kiw", "fenced", { "FOO bar" })
case("search motion", { "aa bb cc dd" }, { 1, 3 }, " k/dd<CR>", "upper", { "aa BB CC dd" })

-- multi-line reply really splits into lines
do
  local ok, err = pcall(function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x", "TODO", "y" })
    ie.config.backend = function(_, on_done)
      on_done("l1\nl2\n")
      return function() end
    end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    keys(" kk")
    wait(in_prompt, "prompt")
    keys("igo<CR>")
    wait(function()
      return vim.deep_equal(buf_lines(), { "x", "l1", "l2", "y" })
    end, "multi-line; got " .. vim.inspect(buf_lines()))
    -- one undo step restores the original
    keys("u")
    assert(vim.deep_equal(buf_lines(), { "x", "TODO", "y" }), "undo: " .. vim.inspect(buf_lines()))
  end)
  print((ok and "ok   " or "FAIL ") .. "multi-line reply + single undo" .. (ok and "" or (": " .. err)))
  failed = failed + (ok and 0 or 1)
end

-- dot-repeat reuses the last instruction without prompting
do
  local ok, err = pcall(function()
    ie.config.backend = function(req, on_done)
      on_done(req.selection:upper())
      return function() end
    end
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one two three" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    keys(" kiw")
    wait(in_prompt, "prompt")
    keys("iupper<CR>")
    wait(function()
      return buf_lines()[1] == "ONE two three"
    end, "first edit")
    keys("ww.")
    wait(function()
      return buf_lines()[1] == "ONE two THREE"
    end, "dot repeat")
    assert(not in_prompt(), "dot-repeat opened a prompt")
    -- linewise + count
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "d", "e" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    keys("2 kk")
    wait(in_prompt, "prompt")
    keys("iupper<CR>")
    wait(function()
      return buf_lines()[2] == "B"
    end, "line edit")
    keys("3G.")
    wait(function()
      return vim.deep_equal(buf_lines(), { "A", "B", "C", "D", "e" })
    end, "linewise dot repeat")
    -- visual
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdef", "abcdef" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    keys("vl k")
    wait(in_prompt, "prompt")
    keys("iupper<CR>")
    wait(function()
      return buf_lines()[1] == "ABcdef"
    end, "visual edit")
    keys("j0ll.")
    wait(function()
      return buf_lines()[2] == "abCDef"
    end, "visual dot repeat")
  end)
  print((ok and "ok   " or "FAIL ") .. "dot-repeat" .. (ok and "" or (": " .. err)))
  failed = failed + (ok and 0 or 1)
end

-- cancelling the prompt leaves text and extmarks untouched
do
  local ok, err = pcall(function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "stay" })
    keys(" kiw")
    wait(in_prompt, "prompt")
    keys("<Esc>")
    wait(function()
      return not in_prompt()
    end, "prompt close")
    assert(buf_lines()[1] == "stay")
    local ns = vim.api.nvim_get_namespaces()["kip"]
    assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0, "extmarks left behind")
  end)
  print((ok and "ok   " or "FAIL ") .. "cancel prompt" .. (ok and "" or (": " .. err)))
  failed = failed + (ok and 0 or 1)
end

-- edits made while the request is running do not misplace the result; <C-c> cancels
do
  local ok, err = pcall(function()
    local finish
    ie.config.backend = function(req, on_done)
      finish = function()
        on_done(req.selection:upper())
      end
      return function() end
    end
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "target", "z" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    keys(" kiw")
    wait(in_prompt, "prompt")
    keys("iupper<CR>")
    wait(function()
      return finish ~= nil
    end, "request start")
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new first", "new second" })
    finish()
    wait(function()
      return vim.deep_equal(buf_lines(), { "new first", "new second", "a", "TARGET", "z" })
    end, "tracked edit; got " .. vim.inspect(buf_lines()))

    finish = nil
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    keys(" kiw")
    wait(in_prompt, "prompt")
    keys("iupper<CR>")
    wait(function()
      return finish ~= nil
    end, "request start")
    keys("<C-c>")
    finish()
    vim.wait(100)
    assert(buf_lines()[3] == "a", "cancelled edit was applied")
    local ns = vim.api.nvim_get_namespaces()["kip"]
    assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0, "extmarks left behind")
  end)
  print((ok and "ok   " or "FAIL ") .. "concurrent buffer edits + cancel" .. (ok and "" or (": " .. err)))
  failed = failed + (ok and 0 or 1)
end

-- :Kip with a range and inline instruction
do
  local ok, err = pcall(function()
    ie.config.backend = function(req, on_done)
      on_done(req.selection:upper())
      return function() end
    end
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c" })
    vim.cmd("2,3Kip upper")
    wait(function()
      return vim.deep_equal(buf_lines(), { "a", "B", "C" })
    end, ":Kip")
  end)
  print((ok and "ok   " or "FAIL ") .. ":Kip range" .. (ok and "" or (": " .. err)))
  failed = failed + (ok and 0 or 1)
end

if failed > 0 then
  print(failed .. " test(s) failed")
  os.exit(1)
end
print("all tests passed")
