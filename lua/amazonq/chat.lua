local api = vim.api
local util = require('amazonq.util')
local lsp = require('amazonq.lsp')
local log = require('amazonq.log')
local sso = require('amazonq.sso')

---@class amazonq.cmdargs
---@field bufnr integer Buffer number
---@field pos1 integer[] Start position `[line,col]` tuple
---@field pos2 integer[] End position `[line,col]` tuple

local M = {
  ---@type vim.lsp.Client
  lsp_client = nil,
  on_chat_open = function()
    vim.cmd [[
      vertical topleft split
      set wrap breakindent nonumber norelativenumber nolist
    ]]
  end,
}

local augroup = api.nvim_create_augroup('amazonq.chat', { clear = true })
local ns_id = api.nvim_create_namespace('amazonq.chat2')
---@type integer? Chat buffer id.
local chatbuf
local chat_tabid = 'amazonq_vim'
---@type { retries: number, id?: integer, input?: string, cmdargs?: amazonq.cmdargs }
--- Current (pending) request info. Used to:
--- - cancel the request if user hits ctrl-c in the chat prompt.
--- - retry the request after refreshing login/auth.
local cur_request = {
  retries = 0,
}
local last_changetick = math.huge
local prompthint = '(Type `cc` to view/edit the current prompt.)'
local prompttext = '*User*:'
local ctxmsg = 'Updated prompt (type `cc` to view/edit, or `<Enter>` to send):'

local function check_lsp_client()
  if not M.lsp_client then
    util.msg('Client not started, running ":AmazonQ login" now.', vim.log.levels.WARN)
    vim.cmd [[AmazonQ login]]

    return false
  end

  return true
end

local function trunc_list(l, n)
  if #l <= n then
    return vim.deepcopy(l)
  end
  local l2 = vim.list_slice(l, 1, n)
  table.insert(l2, '    ...')
  return l2
end

---@param name string
local function set_bufname(name)
  -- TODO: increment a number and add it to the name until we find a name that isn't taken.
  pcall(api.nvim_buf_set_name, chatbuf, name)
end

--- Checks that a window buffer is usable as a "Selected file", specifically:
--- - it is a valid win-id.
--- - it is NOT a current or former AmazonQ Chat buffer.
local function is_valid_ctxwin(winnr)
  if not (winnr and api.nvim_win_is_valid(winnr)) then
    return false
  end
  local buf = api.nvim_win_get_buf(winnr)
  return '' == vim.fn.getbufvar(buf, 'amazonq') and not vim.fn.bufname(buf):match('%[Amazon Q%]')
end

---@return integer? # Chat window id.
local function chatwin()
  if not check_lsp_client() then
    return
  end
  local wins = chatbuf and vim.fn.win_findbuf(chatbuf) or {}
  return wins[1]
end

--- Gets the location of the specified chat context file.
---
--- @param scope 'global' | 'local' | 'prompt'
local function ctxfile(scope)
  if scope == 'global' then
    return vim.fs.joinpath(util.datadir(), 'chat-context.md')
  elseif scope == 'prompt' then
    return vim.fs.joinpath(util.datadir(), 'chat-prompt.md')
  elseif scope == 'local' then
    -- TODO: need to think about this
    error('not implemented yet')
  else
    error()
  end
end

--- Appends text to the specified chat context file.
---
--- @param scope 'global' | 'local' | 'prompt'
--- @param text string
local function add_ctx(scope, text)
  local f = assert(io.open(ctxfile(scope), 'a+'))
  -- Is this helpful or does it just eat up context window?
  -- f:write('The following code is context for questions that I will ask below.\n\n')
  f:write(text)
  f:close()
  -- If user is currently viewing the context file, reload it.
  local buf = vim.fn.bufnr(ctxfile(scope))
  if buf > 0 then
    vim.cmd.checktime(buf)
  end
end

--- Reads the content of the specified chat context file.
---
--- @param scope 'global' | 'local' | 'prompt'
local function get_ctx(scope)
  local f = io.open(ctxfile(scope), 'r')
  if not f then
    return ''
  end
  local text = f:read('*a')
  f:close()
  return text
end

--- Clears the specified chat context file.
---
--- @param scope 'global' | 'local' | 'prompt'
local function clear_ctx(scope)
  local f = assert(io.open(ctxfile(scope), 'w+'))
  f:close()
  add_ctx(scope, '') -- Tickle :checktime.
end

--- Opens the chat context file and presents it to the user.
---
--- @param scope 'global' | 'local' | 'prompt'
local function edit_ctxfile(scope)
  vim.cmd.split(ctxfile(scope))
end

--- Finds the (0-indexed) line just before the last "User:" line.
---
--- @return integer
local function find_info_line()
  local last_line = vim.fn.line('$')
  for i = last_line, 1, -1 do
    local line = vim.fn.getline(i)
    if line:match('^' .. vim.pesc(prompttext) .. '$') then
      return i - 2
    end
  end
  return 0
end

--- Shows a "Selected file: …" info overlay.
local function update_info_overlay()
  assert(chatbuf)
  local win = chatwin()
  if not win then
    return
  end
  local line = find_info_line()
  api.nvim_buf_clear_namespace(chatbuf, ns_id, 0, -1)
  local wininfo = assert(vim.fn.getwininfo(win)[1], ('invalid win: %s'):format(win))
  local viewport_width = wininfo.width - wininfo.textoff

  -- Get the current "selected file".
  local ctx, _ = M.get_context()
  local selectedfile = ctx.position_params
      and vim.fn.fnamemodify(vim.uri_to_fname(ctx.position_params.textDocument.uri), ':.')
    or '(none)'
  local text = ('Selected: %s'):format(selectedfile)

  -- Calculate padding to right-align the text.
  local padding = string.rep(' ', viewport_width - #text)

  -- Set the extmark with virtual text
  api.nvim_buf_set_extmark(chatbuf, ns_id, line, 0, {
    virt_text = { { padding .. text, 'Comment' } },
    virt_text_pos = 'overlay',
    priority = 100,
  })
end

local function show_chat_win(buf)
  -- Setup a split window.
  M.on_chat_open()

  -- Focus the chat buffer in the split window.
  buf = buf or api.nvim_create_buf(true, true)
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)

  return { buf = buf, win = win }
end

local function on_prompt_cancel()
  if not check_lsp_client() then
    return
  end

  if cur_request.id then
    if vim.fn.has('nvim-0.11') == 1 then
      M.lsp_client:cancel_request(cur_request.id)
    else
      -- Deprecated signature for Nvim 0.10 and older.
      -- TODO(jmkeyes): remove this after our minimum supported Nvim is 0.11+.
      ---@diagnostic disable-next-line:param-type-mismatch,missing-parameter
      M.lsp_client.cancel_request(cur_request.id)
    end

    util.msg(('canceled request id: %s'):format(cur_request.id), vim.log.levels.INFO)
  end
end

--- Shows the chat buffer+window, and initializes it if necessary.
---
--- @return integer # buf id
function M.open_chat()
  local chatbuf_valid = chatbuf and api.nvim_buf_is_valid(chatbuf)
  -- Don't open new chat if it already exists
  if chatbuf_valid then
    if not chatwin() then
      show_chat_win(chatbuf)
    else
      -- Focus on the existing chat window
      api.nvim_set_current_win(assert(chatwin()))
    end

    assert(chatbuf)
    vim.cmd [[normal! G$]] -- Place cursor at end of prompt.

    -- User or a plugin may have deleted/unloaded the buffer.
    -- Then we need to reinitialize it.
    local is_initialized = not not (vim.b.amazonq and vim.fn.line('$') > 1)
    if is_initialized then
      return chatbuf
    end
  end

  -- Setup Chat window
  chatbuf = chatbuf_valid and chatbuf or (show_chat_win()).buf

  vim.fn.prompt_setcallback(chatbuf, M.send_prompt)
  vim.fn.prompt_setinterrupt(chatbuf, on_prompt_cancel)

  set_bufname('[Amazon Q]')
  vim.b.amazonq = {}
  vim.bo[chatbuf].buftype = 'prompt'
  vim.bo[chatbuf].bufhidden = 'hide'
  -- TODO(jmkeyes): set b:amazonq so users can set custom options in the chat buffer.
  vim.bo[chatbuf].filetype = 'markdown'
  vim.bo[chatbuf].syntax = 'markdown'
  vim.bo[chatbuf].textwidth = 0

  -- buffer-local mappings
  vim.keymap.set('n', '<c-c>', on_prompt_cancel, { buffer = chatbuf })
  vim.keymap.set('n', 'cC', function()
    edit_ctxfile('global')
  end, { buffer = chatbuf })
  vim.keymap.set('n', 'cc', function()
    edit_ctxfile('prompt')
  end, { buffer = chatbuf })
  -- HACK: avoid default `prompt-buffer` CTRL-w behavior. https://github.com/nvim-telescope/telescope.nvim/pull/1650
  vim.keymap.set('i', '<c-w>', '<c-s-w>', { buffer = chatbuf })

  api.nvim_create_autocmd('WinEnter', {
    group = augroup,
    buffer = chatbuf,
    callback = function()
      update_info_overlay()
    end,
  })

  api.nvim_create_autocmd('InsertLeave', {
    group = augroup,
    buffer = chatbuf,
    callback = function(ev)
      -- Prompt buffer is eager to set 'modified', but it's not useful here.
      -- TODO(jmkeyes): optionally auto-save the chat session to `stdpath('log')`.
      vim.bo[ev.buf].modified = false
    end,
  })

  -- Handle "p" (put) in the chat buffer.
  -- TODO(jmkeyes): remove this after upstream issue is fixed: https://github.com/neovim/neovim/issues/32661
  api.nvim_create_autocmd({ 'TextChanged' }, {
    group = augroup,
    buffer = chatbuf,
    callback = function(ev)
      local changed = api.nvim_buf_get_changedtick(ev.buf) > last_changetick
      if not changed then
        return
      end
      -- Handle multiline string paste (via "p", cmd+v, etc).
      local startpos = vim.fn.getpos("'[")
      local startline = startpos[2] - 1 -- API line is 0-indexed end-inclusive.
      local startcol = startpos[3] - 1 -- API col is 0-indexed end-exclusive.
      local endpos = vim.fn.getpos("']")
      local endline = endpos[2] - 1
      local endcol = endpos[3] - 1
      local lastlinecol = #vim.fn.getline('$') == 0 and 0 or #vim.fn.getline('$') - 1
      -- XXX: fixup if col is at the (newline). 😱 getregionpos() would greatly help, but requires Nvim 0.11+.
      if #vim.fn.getline(startline + 1) > 0 and #vim.fn.getline(startline + 1) == startcol + 1 then
        startline = startline + 1
        startcol = 0
      end
      local ok, lines = pcall(api.nvim_buf_get_text, chatbuf, startline, startcol, endline, endcol + 1, {})
      if not ok then
        log.log(
          ('TextChanged: nvim_buf_get_text failed startpos=%s,%s endpos=%s,%s'):format(
            startline,
            startcol,
            endline,
            endcol + 1
          )
        )
        return
      end
      local trimmed = vim.trim(table.concat(lines, '\n'))
      log.log(
        ('TextChanged start=%s,%s end=%s,%s lastlinecol=%s'):format(startline, startcol, endline, endcol, lastlinecol)
      )

      -- Single-line input: update the current prompt input.
      if not vim.trim(table.concat(lines, '\n')):find('\n') then
        if startline == endline and (startcol > 0 or endcol < lastlinecol) then
          vim.bo[ev.buf].modified = false
          -- Inline (charwise) put, don't need to do anything.
          log.log('TextChanged charwise, skipped')
          return
        end

        -- Get previous input (if any) so we can preserve it.
        local previnput = ''
        if #lines > 1 or (startcol == 0 and endcol == lastlinecol and endcol > 0) then
          -- Whole line was added (linewise "put"), so the previous line is the pending prompt (if any).
          -- Assumes that previous prompt is 1 line (because buftype=prompt doesn't support multiline input).
          previnput = vim.trim(api.nvim_buf_get_lines(chatbuf, startline - 1, startline, false)[1] or '')
          previnput = previnput == prompttext and '' or previnput
          log.log(('previnput=%s'):format(previnput))
        end

        -- Append to previous input (if any).
        trimmed = (#previnput > 0 and previnput .. ' ' or '') .. trimmed
        log.log(('TextChanged: oneline trimmed=%s'):format(vim.inspect(trimmed)))
        -- Delete the pending prompt AND the inserted region, before putting the combined result.
        local ok2, msg =
          pcall(api.nvim_buf_set_text, chatbuf, startline - (#previnput > 0 and 1 or 0), startcol, endline, endcol, {})
        if not ok2 then
          log.log(('TextChanged: nvim_buf_set_text failed endcol=%s msg=%s'):format(endcol, vim.inspect(msg)))
        end

        -- Feed single-line paste (ignore trailing newlines) into the prompt, as normal.
        vim.fn.feedkeys(vim.keycode('A<c-u><c-u>') .. trimmed, 'ixn')
      else
        -- Multiline input: add it to the context file, instead of inserting into the prompt.
        log.log(('TextChanged: multiline lines=%s'):format(vim.inspect(lines)))

        -- Delete the inserted region.
        api.nvim_buf_set_text(chatbuf, startline, startcol, endline, endcol, {})

        lines = util.indent(4, lines)
        table.insert(lines, 1, 'Context:')
        table.insert(lines, 2, '')
        table.insert(lines, '')
        add_ctx('prompt', table.concat(lines, '\n'))
        table.insert(lines, 1, ctxmsg)
        M.append(trunc_list(lines, 8))
      end

      vim.cmd('normal! G$')
      vim.bo[ev.buf].modified = false
    end,
  })

  M.init_prompt()

  return chatbuf
end

--- Toggle the chat window
function M.toggle()
  if chatwin() then
    api.nvim_win_hide(assert(chatwin()))
  else
    M.open_chat()
  end
end

--- Set initial prompt
function M.init_prompt()
  assert(chatbuf)
  local msg = {
    "Hi, I'm Amazon Q. Ask me anything.",
    '- For simple (single-line) prompts, insert directly in this buffer.',
    '- For multiline prompts, type `cc` in this buffer, or `zq` on selected text.',
    '- Type `cC` to edit the global context (inserted before every prompt).',
    '- Hit `<Enter>` to send the current prompt.',
    '- See `:help amazonq` for documentation.',
  }
  local globalctx = get_ctx('global')
  if '' ~= vim.trim(globalctx) then
    table.insert(msg, '')
    table.insert(msg, ('Using global context: %s'):format(vim.fn.fnamemodify(ctxfile('global'), ':~')))
  end
  table.insert(msg, '')
  table.insert(msg, prompttext)
  M.append(msg)
  vim.fn.prompt_setprompt(chatbuf, '')
  vim.bo[chatbuf].modified = false
  api.nvim_input('i<Esc>')

  update_info_overlay()
end

--- Appends `input` to the current context, and sends the combined prompt to Amazon Q LSP.
---
--- Clears the prompt file (`clear_ctx('prompt')`) on successful response.
---
--- @param input string Chat input, or prompt text from a command/event/etc.
--- @param cmdargs? amazonq.cmdargs Args sent by a command, mapping, etc.
function M.send_prompt(input, cmdargs)
  if not check_lsp_client() then
    return
  end
  if cur_request.id then
    util.msg('cancel (CTRL-C) the current request before starting a new one')
    return
  end
  log.log(('send_prompt(): input=%s'):format(vim.inspect(input)))

  M.show_progress()

  -- Prepend the global context + current prompt-file to the prompt input.
  local globalctx = ('# General context/instructions (apply to your ANSWER but NOT to my questions/instructions):\n\n%s\n\n# END General context/instructions. My questions/instructions are BELOW:'):format(
    get_ctx('global')
  )
  local prompt = ('%s\n\n%s\n\n%s'):format(globalctx, vim.trim(get_ctx('prompt')), vim.trim(input))

  local ctx, _ = M.get_context(cmdargs)
  local params = {
    prompt = {
      tabId = chat_tabid,
      prompt = prompt,
    },
  }
  params = vim.tbl_deep_extend('force', params, ctx.position_params or {})
  params = vim.tbl_deep_extend('force', params, ctx.range_params or {})

  cur_request.input = input
  cur_request.cmdargs = cmdargs
  -- Server implementation: https://github.com/aws/language-servers/blob/7ce6b947b96954f8c552e5053ebc437502f66cd3/server/aws-lsp-codewhisperer/src/language-server/chat/chatController.ts#L72
  cur_request.id = lsp.lsp_request(M.lsp_client, 'aws/chat/sendChatPrompt', params, M.on_chat_response)
end

-- /help Quick Action
function M.help()
  if not check_lsp_client() then
    return
  end

  M.append({ 'What can Amazon Q help me with?' })

  M.show_progress()

  -- Server implementation: https://github.com/aws/language-servers/blob/7ce6b947b96954f8c552e5053ebc437502f66cd3/server/aws-lsp-codewhisperer/src/language-server/chat/chatController.ts#L333
  lsp.lsp_request(M.lsp_client, 'aws/chat/sendChatQuickAction', {
    tabId = chat_tabid,
    quickAction = '/help',
  }, M.on_chat_response)
end

--- /clear Quick Action
---
--- TODO(jmkeyes): send `aws/chat/endChat`? https://github.com/aws/language-server-runtimes/blob/main/runtimes/README.md#chat
function M.clear()
  if not check_lsp_client() then
    return
  end

  assert(chatbuf)
  last_changetick = math.huge -- Disable TextChanged handler.
  -- Clear chat buffer
  api.nvim_buf_set_lines(chatbuf, 0, -1, false, {})

  M.init_prompt()
  clear_ctx('prompt')

  -- Server implementation: https://github.com/aws/language-servers/blob/7ce6b947b96954f8c552e5053ebc437502f66cd3/server/aws-lsp-codewhisperer/src/language-server/chat/chatController.ts#L333
  lsp.lsp_request(M.lsp_client, 'aws/chat/sendChatQuickAction', {
    tabId = chat_tabid,
    quickAction = '/clear',
  }, function(_, _)
    util.msg('chat cleared')
  end)

  vim.schedule(function()
    -- Enable TextChanged handler.
    last_changetick = api.nvim_buf_get_changedtick(chatbuf)
  end)
end

--- Gets text from the current buffer and builds a Q prompt.
---
--- @param verb string "Explain", "Fix", etc. (special case: "Context")
--- @param line1 integer Mark-indexed line 1.
--- @param line2 integer Mark-indexed line 2.
--- @param notext boolean Don't include the text content.
--- @return string[]
local function make_prompt(verb, line1, line2, notext)
  local hasverb = verb ~= 'Context'
  --- Whole buffer or range/selection?
  local all = notext or (line1 == 1 and line2 == vim.fn.line('$'))
  local l1 = line1
  local l2 = line2
  local lines = not all and (l1 == l2 and ('line %d, '):format(l1) or ('lines %d-%d, '):format(l1, l2)) or nil
  local range = hasverb and (all and 'this codefile ' or 'the selected codeblock ') or ''
  local fname = vim.fn.fnamemodify(vim.fn.bufname(''), ':p:t')
  fname = fname == '' and 'untitled' or fname

  local prompt = {
    ('%s %s(%sfile `%s`)'):format(verb, range, lines or '', fname),
  }

  -- Trim trailing blank lines.
  local buflines = table.concat(vim.fn.getline(line1, line2) --[[@as string[] ]], '\n'):gsub('%s+$', '') .. '\n'
  local indented = vim.split(util.indent(4, buflines), '\n')

  local codeblock = vim
    .iter(notext and {} or {
      '',
      indented,
      '',
    })
    :flatten()
    :totable()

  vim.list_extend(prompt, codeblock)

  return prompt
end

--- Performs `:AmazonQ [cmd]`.
---
--- @param cmdname string
--- @param ev vim.api.keyset.create_user_command.command_args
--- @param opts? {
---   ctx_only?: boolean, -- Append to context only, don't send prompt.
--- }
function M.on_cmd(cmdname, ev, opts)
  assert(ev.line1 > 0)
  opts = opts or {}
  cmdname = '' ~= vim.trim(cmdname or '') and cmdname or 'Context'

  -- Construct command prompt
  -- https://github.com/aws/aws-toolkit-vscode/blob/06e72ca61785858291606c259a145cb6ddddfb50/packages/core/src/codewhispererChat/controllers/chat/prompts/promptsGenerator.ts#L11
  local buf = api.nvim_get_current_buf()
  local prompt = make_prompt(cmdname, ev.line1, ev.line2, ev.range == 0)

  local endcol = #vim.fn.getbufline(buf, ev.line2)[1] - 1
  local args = {
    bufnr = buf,
    -- Position is "mark-indexed". See:
    --  - :help api-indexing
    --  - :help vim.lsp.util.make_given_range_params
    pos1 = { ev.line1, 0 },
    pos2 = { ev.line2, endcol },
  }

  -- Highlight the range in the source buffer.
  if vim.fn.has('nvim-0.11') == 1 then
    vim.hl.range(buf, ns_id, 'Visual', { ev.line1 - 1, 0 }, { ev.line2 - 1, endcol }, { timeout = 800 })
  end

  local chatbuf_ = M.open_chat()
  last_changetick = math.huge -- Disable TextChanged handler.
  api.nvim_buf_set_lines(chatbuf_, -1, -1, false, {})
  -- Note: M.append() will reenable the TextChanged handler.

  local text = table.concat(prompt, '\n')
  if opts.ctx_only == true then
    add_ctx('prompt', text)
  else
    M.send_prompt(text, args)
  end

  -- This is "cosmetic" (UI-only), for user visibility.
  M.append({ cmdname == 'Context' and ctxmsg or '' })
  M.append(trunc_list(prompt, 10))
end

--- Gets context from:
---   - the chat prompt
---   - the buffer in the next window
---
--- @param cmdargs? amazonq.cmdargs Args sent by a command, mapping, etc.
---
--- @return table # context object
--- @return integer? # window-id used to build the context
function M.get_context(cmdargs)
  -- Use context from previous window, or current window if it's not the chat window.
  local ctxwin = is_valid_ctxwin(vim.fn.win_getid()) and vim.fn.win_getid() or vim.fn.win_getid(vim.fn.winnr('#'))
  if not is_valid_ctxwin(ctxwin) then -- Edge case: get any window that isn't the AmazonQ window.
    ---@type integer[]
    local wins = vim.tbl_filter(is_valid_ctxwin, api.nvim_list_wins())
    ctxwin = wins[1]
  end

  local context = {}
  local pos_encoding = (M.lsp_client or { offset_encoding = 'utf-16' }).offset_encoding
  local range_params = cmdargs and lsp.get_lsp_pos(pos_encoding, cmdargs.pos1, cmdargs.pos2, cmdargs.bufnr) or nil

  context.range_params = range_params
      -- Pass given range/selection as context.
      and range_params
    -- Pass full file as context.
    or nil

  if is_valid_ctxwin(ctxwin) then
    local position_params = vim.lsp.util.make_position_params(ctxwin, pos_encoding)
    if position_params.textDocument.uri ~= 'file://' then
      context.position_params = position_params
    end
  end

  return context, ctxwin
end

--- Handles server response to chat input or quick-action requests.
---
--- Clears the context file (`clear_ctx()`) on successful response.
---
--- @param err? lsp.ResponseError
--- @param response? any
--- @param ctx lsp.HandlerContext
function M.on_chat_response(err, response, ctx)
  local err_msg
  local request_id = cur_request.id
  cur_request.id = nil
  M.clear_progress()

  if err then
    local o = {
      request_method = ctx.method,
      request_id = request_id,
      -- Remove metamethods (avoids noise in logs).
      error = setmetatable(vim.deepcopy(err), nil),
    }
    log.log(o, vim.log.levels.ERROR)
    --- User canceled the request.
    local req_canceled = (err.message == 'aborted' or err.message == 'Request aborted')
    err_msg = req_canceled and 'Request canceled.'
      or lsp.fmt_msg(err, 'If this continues to happen, try `:AmazonQ clear`.')
  end

  local reconnect_msg = 'Connection expired. Trying to reconnect...'
  local chat_response = response == nil and err_msg
    or (
      response.body == ''
        and ((response.followUp.options[1].type == 're-auth' or response.followUp.options[1].type == 'full-auth') and reconnect_msg or '')
      or util.decode_html_entities(response.body)
    )

  if chat_response == reconnect_msg and cur_request.retries < 1 then
    cur_request.retries = cur_request.retries + 1
    log.log('login expired; attempting to refresh auth and retry prompt...')
    sso.login(function()
      M.send_prompt(cur_request.input, cur_request.cmdargs)
    end)
    return
  end
  cur_request.retries = 0

  local lines_to_add = {
    '*Amazon Q*:',
    '',
  }
  vim.list_extend(lines_to_add, vim.split(vim.trim(chat_response), '\n'))
  vim.list_extend(lines_to_add, {
    '',
    '---',
    '',
    prompthint,
    '',
    prompttext,
  })

  M.append(lines_to_add)

  if chat_response == reconnect_msg then
    log.log('login expired; no more retries')
    vim.cmd [[AmazonQ login]]
  elseif not err then -- Got a successful response.
    clear_ctx('prompt')
  end

  update_info_overlay()
end

function M.show_progress()
  assert(chatbuf)
  -- TODO: animation in statusbar/winbar?
  M.append({ 'Generating (CTRL-C to cancel)...' })
end

function M.clear_progress()
  assert(chatbuf)
  api.nvim_buf_call(chatbuf, function()
    vim.cmd [[silent keeppatterns g/\VGenerating (CTRL-C to cancel).../d _]]
  end)
end

--- @param lines string[]
function M.append(lines)
  lines = vim.list_extend(vim.deepcopy(lines), { '' })
  last_changetick = math.huge -- Disable TextChanged handler.
  assert(chatbuf)
  api.nvim_buf_set_lines(chatbuf, -2, -1, false, lines)

  -- Scroll to the end of the window
  if chatwin() then
    api.nvim_win_call(assert(chatwin()), function()
      vim.cmd('normal! G')
    end)
  end

  vim.bo[chatbuf].modified = false
  vim.schedule(function()
    -- Enable TextChanged handler.
    last_changetick = api.nvim_buf_get_changedtick(chatbuf)
  end)
end

local paste_lines = { '' }
vim.paste = (function(overridden)
  return function(lines, phase)
    if not vim.b.amazonq then
      return overridden(lines, phase)
    elseif phase == -1 or phase == 1 then
      paste_lines = { '' } -- See ":help channel-lines".
    end

    -- Collect all lines. See ":help channel-lines".
    paste_lines[#paste_lines] = paste_lines[#paste_lines] .. (lines[1] or '')
    table.remove(lines, 1)
    vim.list_extend(paste_lines, lines)

    if phase == -1 or phase == 3 then
      local joined = vim.trim(table.concat(paste_lines, '\n'))
      if not joined:find('\n') then
        -- Single-line paste: enter the prompt, then handle as normal.
        vim.fn.feedkeys('a', 'ixn')
        overridden({ joined }, -1)
        vim.bo.modified = false
        return true
      end

      -- When the paste stream ends, add multi-line text to the prompt context, instead of inserting into the prompt.
      paste_lines = util.indent(4, paste_lines)
      table.insert(paste_lines, 1, 'Context:')
      table.insert(paste_lines, 2, '')
      table.insert(paste_lines, '')
      add_ctx('prompt', table.concat(paste_lines, '\n'))
      table.insert(paste_lines, 1, ctxmsg)
      M.append(trunc_list(paste_lines, 8))
      return true
    end
  end
end)(vim.paste)

return M
