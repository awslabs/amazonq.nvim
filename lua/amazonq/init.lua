local M = {}

local log = require('amazonq.log')
local lsp = require('amazonq.lsp')
local sso = require('amazonq.sso')
local chat = require('amazonq.chat')
local completion = require('amazonq.completion')
local util = require('amazonq.util')

--- Gets the path to the `aws-lsp-codewhisperer-token-binary.js` javascript blob.
local function path_to_langserver()
  local this_file = debug.getinfo(1).source:match('@?(.*/)')
  local this_dir = vim.fn.fnamemodify(this_file, ':p:h')
  local f = vim.fn.simplify(this_dir .. '../../../language-server/build/aws-lsp-codewhisperer-token-binary.js')
  return f
end

--- @param scope 'global' | 'local' | 'prompt'
function M.ctxfile(scope)
  return chat.ctxfile(scope)
end

function M.setup(opts)
  local cmd = opts.cmd and opts.cmd or {
    'node',
    path_to_langserver(),
    '--stdio',
  }
  assert(type(cmd) == 'table', 'opts.cmd must be a list')
  assert(vim.fn.executable(cmd[1]) == 1, ('not executable or not found: "%s"'):format(cmd[1]))
  if cmd[1] and cmd[1]:find('node') then
    local node_v_out = vim.trim(vim.system({ cmd[1], '--version' }):wait().stdout):sub(-20)
    local node_v = assert(vim.version.parse(node_v_out), ('invalid node --version: "%s"'):format(node_v_out))
    local node_v_expected = '18.0.0'
    assert(
      vim.version.ge(node_v, node_v_expected),
      ('node version must be >= %s, got: %s'):format(node_v_expected, node_v_out)
    )
  end
  assert(vim.fn.filereadable(cmd[2]) == 1, ('invalid path: "%s"'):format(cmd[2]))

  log.init({ enable = opts.debug })
  sso.setup(opts.ssoStartUrl)

  chat.on_chat_open = opts.on_chat_open or chat.on_chat_open

  lsp.setup({
    debug = opts.debug,
    inline_suggest = opts.inline_suggest,
    cmd = cmd,
    root_dir = opts.root_dir,
    filetypes = opts.filetypes,
    on_init = sso.on_lsp_init,
  })

  if opts.inline_suggest ~= false then
    completion.setup()
  end

  -- Define the :AmazonQ command.
  --  - without args: focus the chat window.
  --  - "toggle": show/hide the chat window.
  vim.api.nvim_create_user_command('AmazonQ', function(ev)
    log.log((':AmazonQ fargs=%s'):format(vim.inspect(ev)), vim.log.levels.DEBUG)

    -- TODO(jmkeyes): 'status'
    -- TODO(jmkeyes): 'restart'
    if #ev.fargs == 0 then
      if ev.line1 == 0 or ev.range == 0 then
        -- Special case: ":0AmazonQ" only focuses the chat window without sending text.
        chat.open_chat()
      else
        chat.on_cmd('', ev, { ctx_only = true })
      end
    elseif ev.fargs[1] == 'help' then
      chat.open_chat()
      chat.help()
    elseif ev.fargs[1] == 'clear' then
      chat.open_chat()
      chat.clear()
    elseif ev.fargs[1] == 'login' then
      if chat.lsp_client then
        sso.on_lsp_init(chat.lsp_client)
      else
        lsp.start()
      end
    elseif ev.fargs[1] == 'logout' then
      sso.logout()
    elseif ev.fargs[1] == 'toggle' then
      chat.toggle()
    elseif ev.fargs[1] == 'explain' then
      chat.on_cmd('explain', ev)
    elseif ev.fargs[1] == 'refactor' then
      chat.on_cmd('refactor', ev)
    elseif ev.fargs[1] == 'fix' then
      chat.on_cmd('fix', ev)
    elseif ev.fargs[1] == 'optimize' then
      chat.on_cmd('optimize', ev)
    end
  end, {
    nargs = '*',
    range = 0, -- Allow ":0AmazonQ" special case.
    complete = util.cmd_complete, -- For `:AmazonQ <tab>` completion.
  })

  -- Handle deprecated :AmazonQxx commands.
  -- TODO(jmkeyes): remove this after some "bake time".
  vim.api.nvim_create_autocmd('CmdUndefined', {
    group = lsp.augroup,
    callback = function(ev)
      -- Map of old commands to their new equivalents.
      local old_new = {
        AmazonQChat = 'toggle',
        AmazonQAuth = 'login',
        AmazonQHelp = 'help',
        AmazonQClear = 'clear',
        AmazonQExplain = 'explain',
        AmazonQRefactor = 'refactor',
        AmazonQFix = 'fix',
        AmazonQOptimize = 'optimize',
      }

      local subcmd = old_new[ev.match]
      util.msg(('removed, use ":AmazonQ %s" instead.'):format(subcmd), vim.log.levels.ERROR)
    end,
  })

  vim.cmd [[xnoremap zq :AmazonQ<CR>]]
  vim.keymap.set('n', 'zq', function()
    vim.cmd((':%sAmazonQ'):format(vim.v.count))
  end)

  vim.api.nvim_create_autocmd('LspAttach', {
    group = lsp.augroup,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)

      if client and client.name == 'amazonq' then
        chat.lsp_client = client

        if opts.inline_suggest ~= false and not vim.b.amazonq then
          completion.start(lsp.config)
        end
      end
    end,
  })
end

return M
