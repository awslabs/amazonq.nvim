local log = require('amazonq.log')

local M = {}

M.productName = 'Amazon Q'
M.moduleName = 'amazonq'

local popup_win

--- @param kind string
local function ensuredir(kind)
  local dir = vim.fs.joinpath(vim.fn.stdpath(kind), M.moduleName)
  if not vim.uv.fs_stat(dir) then
    vim.fn.mkdir(dir, 'p')
  end
  return dir
end

--- Gets a "…/amazonq/" directory for storing (non-cache) data.
--- Creates the dir if it doesn't exist.
function M.datadir()
  return ensuredir('data')
end

--- Gets a "…/amazonq/" directory for storing cache data.
--- Creates the dir if it doesn't exist.
function M.cachedir()
  return ensuredir('cache')
end

--- Shows a user-facing message, prefixed with the plugin name.
---
--- @param msg any
--- @param level? vim.log.levels Message severity level
function M.msg(msg, level)
  -- If `msg` is an object, do a shallow-copy to avoid printing metatable info.
  if type(msg) == 'table' then
    local copy = {}
    for k, v in pairs(msg) do
      copy[k] = v
    end
    msg = vim.inspect(copy)
  elseif type(msg) ~= 'string' then
    msg = vim.inspect(msg)
  end
  -- Timed-out waiting for browser login flow to complete
  vim.notify(('Amazon Q: %s'):format(msg), level)
  log.log(msg, level)
end

--- Shows (and focuses) `text` in a centered, floating window with a max width of 100 chars.
--- User can dismiss the window by switching to another window or mouse-clicking anywhere outside of it.
---
--- @param text string
--- @param max_width? integer
--- @param max_height? integer
--- @return number # window-id
function M.show_popup(text, max_width, max_height)
  M.dismiss_popup() -- Only show one "dialog" at any given time.
  assert(text)

  max_width = max_width and max_width or 100
  max_height = max_height and max_height or 10
  local offset_x = math.max(0, math.floor((vim.o.columns - max_width) / 2))
  local offset_y = math.max(0, math.floor((vim.o.lines - max_height) / 2))
  local _, win = vim.lsp.util.open_floating_preview({ text }, 'markdown', {
    border = 'rounded',
    focus = true,
    focusable = true,
    max_height = max_height,
    max_width = max_width,
    offset_x = offset_x,
    offset_y = offset_y,
    relative = 'editor',
    title = M.productName,
  })
  vim.api.nvim_set_current_win(win)
  popup_win = win
  return win
end

--- Dismisses the current dialog, if any.
function M.dismiss_popup()
  if not popup_win or not vim.api.nvim_win_is_valid(popup_win) then
    popup_win = nil
    return
  end
  vim.api.nvim_win_close(popup_win, false)
  popup_win = nil
end

local html_entities = {
  ['&amp;'] = '&',
  ['&lt;'] = '<',
  ['&gt;'] = '>',
  ['&quot;'] = '"',
  ['&#39;'] = "'",
  ['&nbsp;'] = ' ',
  ['&apos;'] = "'",
  -- Add more entities as needed
}

-- Basic ASCII character conversion table for HTML numeric entities.
local char_table = {}
for i = 32, 126 do
  char_table[i] = string.char(i)
end

--- Decode HTML entities (both named and numeric).
---
--- Examples:
--- - `"&gt;"` => `">"`
--- - `"&#42;"` => `"*"`
---
--- @param s string HTML content
--- @return string
function M.decode_html_entities(s)
  assert(s)

  local ok, decoded = pcall(function()
    -- Named entities.
    s = s:gsub('&[%w#]+;', html_entities)

    -- Decimal numeric entities.
    s = s:gsub('&#(%d+);', function(n)
      local num = tonumber(n)
      return char_table[num] or ('&#' .. n .. ';')
    end)

    -- Hex numeric entities.
    s = s:gsub('&#[Xx](%x+);', function(n)
      local num = tonumber(n, 16)
      return char_table[num] or ('&#x' .. n .. ';')
    end)

    return s
  end)

  if not ok then
    log.log('decode_html_entities() failed', vim.log.levels.ERROR)
    return s
  end

  return decoded
end

--- For `:AmazonQ <tab>` completion. See `:help :command-complete`.
---
--- @param arg string Current (partial) argument being completed.
--- @param line string Current command-line up to cursor.
--- @param pos number Cursor position in the command-line.
--- @return string[] # List of completion candidates
function M.cmd_complete(arg, line, pos)
  local subcmds = {
    'clear',
    'help',
    'login',
    'logout',
    'explain',
    'refactor',
    'optimize',
    'toggle',
    'fix',
  }

  local completions = {}
  for _, cmd in ipairs(subcmds) do
    if cmd:sub(1, #arg) == arg then
      table.insert(completions, cmd)
    end
  end

  return completions
end

--- Sets the indent of non-empty lines in `lines`.
---
--- @param indent_width integer Number of spaces for indentation.
--- @param lines string[] Lines to indent.
--- @return string[] normalized Indented lines.
--- @overload fun(indent_width: integer, lines: string): string
function M.indent(indent_width, lines)
  if vim.fn.has('nvim-0.11') == 1 then
    local lines_ = type(lines) == 'string' and lines or table.concat(lines, '\n')
    local indented = vim.text.indent(indent_width, lines_)
    return type(lines) == 'string' and indented or vim.split(indented, '\n')
  end
  --- TODO(jmkeyes): drop the rest of this code, when we bump to Nvim 0.11+.

  local indented = {}
  local min_indent = math.huge
  local empty_pattern = '^%s*$'
  local indent_pattern = '^(%s*)'
  local lines_ = type(lines) == 'string' and vim.split(lines, '\n') or lines

  -- Calculate minimum indentation across all non-empty lines.
  for _, line in ipairs(lines_) do
    -- Skip empty or whitespace-only lines
    if not line:match(empty_pattern) then
      local indent = select(2, line:find(indent_pattern))
      min_indent = math.min(min_indent, indent or 0)
    end
  end
  min_indent = (min_indent == math.huge) and 0 or min_indent

  -- Process lines with normalized indentation.
  local indent_spaces = string.rep(' ', indent_width)
  for _, line in ipairs(lines_) do
    if not line:match(empty_pattern) then
      -- Remove existing indentation and add configured number of spaces
      table.insert(indented, indent_spaces .. line:sub(min_indent + 1))
    else
      table.insert(indented, '')
    end
  end

  return type(lines) == 'string' and table.concat(indented, '\n') or indented
end

return M
