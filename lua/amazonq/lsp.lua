local M = {}
local util = require('amazonq.util')
local log = require('amazonq.log')

M.augroup = vim.api.nvim_create_augroup('amazonq.lsp', { clear = true })

-- XXX: Injected by sso.lua to avoid circular dependency.
M.sso_login = nil

--- Default LSP config, used for the `vim.lsp.start()` call.
M.config --[[@type vim.lsp.ClientConfig]] = {
  name = 'amazonq',
  cmd = {},
  -- UTF-16 https://github.com/aws/language-servers/issues/732
  offset_encoding = (vim.fn.has('nvim-0.11') == 1 and 'utf-16' or nil),
  ---@type table<string, lsp.Handler>
  handlers = {
    -- Handle telemetry requests from the server
    ['telemetry/event'] = function(_, _result, _ctx)
      -- TODO: send telemetry to Telemetry collection endpoint
    end,

    -- Handle log events - one particular important log message is for handling authentication errors
    ['window/logMessage'] = function(_, result, _ctx)
      if
        result
        and result.message
        and (
          string.find(result.message, 'Authorization failed, bearer token is not set')
          or string.find(result.message, 'The bearer token included in the request is invalid.')
        )
      then
        -- Try auto-login, to avoid noisy "Connection expired" message.
        -- May improve after: https://github.com/aws/language-servers/issues/801
        M.sso_login(function(err, _result)
          if err then
            util.msg('Connection expired or invalid. Run ":AmazonQ login".', vim.log.levels.WARN)
          end
        end)
      end
    end,
    -- Handle window events - this is used to display the authentication url and code to the user
    ['window/showMessage'] = function(_, result, _ctx)
      if result and result.message then
        util.show_popup(M.fmt_msg(result))
      end
    end,
  },
  -- Add any additional LSP server configuration options here
  init_options = {
    aws = {
      clientInfo = {
        name = 'Neovim',
        version = tostring(vim.version()),
        extension = {
          name = 'amazonq',
          version = '0.1.0',
        },
      },
    },
  },
}

--- Gets a presentable, markdown-formatted message from a LSP result.
---
--- @param o any LSP result object
--- @param hint? string Optional hint placed after the main text, before the data details.
function M.fmt_msg(o, hint)
  o = vim.deepcopy(o)
  local msg = vim.trim(o.message or '')
  o.message = nil
  hint = hint and '\n\n' .. hint or ''
  local data = #vim.tbl_keys(o) == 0 and '' or '\n\n' .. util.indent(4, vim.inspect(o))
  -- Include the other fields (`code`, `data`) as a codeblock.
  msg = ('%s%s%s'):format(msg, hint, data)
  return msg
end

--- Wraps the Nvim lsp client to deal with deprecation of non-"self" functions:
--- https://github.com/neovim/neovim/commit/454ae672aad172a299dcff7c33c5e61a3b631c90
---
--- Also logs to our logfile.
---
--- @param client vim.lsp.Client
--- @param method string LSP method name.
--- @param params? table LSP request params.
--- @param handler? lsp.Handler Response |lsp-handler| for this method.
--- @param bufnr? integer (default: 0) Buffer handle, or 0 for current.
--- @return integer? # request id
---
--- @see vim.lsp.Client.request()
function M.lsp_request(client, method, params, handler, bufnr)
  local ok = false
  local request_id ---@type integer?

  if vim.fn.has('nvim-0.11') == 1 then
    ok, request_id = client:request(method, params, handler, bufnr)
  --- @return boolean status indicates whether the request was successful.
  ---     If it is `false`, then it will always be `false` (the client has shutdown).
  --- @return integer? request_id Can be used with |Client:cancel_request()|.
  ---                             `nil` is request failed.
  else
    -- Deprecated signature for Nvim 0.10 and older.
    -- TODO(jmkeyes): remove this after our minimum supported Nvim is 0.11+.
    ---@diagnostic disable-next-line:param-type-mismatch
    ok, request_id = client.request(method, params, handler, bufnr)
  end

  log.log({
    method = method,
    request_id = request_id,
    status = ok,
    params = params,
    bufnr = bufnr,
  })

  return request_id
end

-- Define the LSP server setup function
function M.setup(opts)
  assert(opts.cmd, 'opts.cmd is required')
  assert(not opts.filetypes or type(opts.filetypes) == 'table')
  assert(opts.on_init)
  opts.root_dir = opts.root_dir or vim.uv.cwd()
  opts.filetypes = opts.filetypes
    or {
      'amazonq',
      'bash',
      'c',
      'cpp',
      'csharp',
      'go',
      'java',
      'javascript',
      'kotlin',
      'lua',
      'python',
      'ruby',
      'rust',
      'sh',
      'shell',
      'sql',
      'typescript',
    }

  M.config.debug = opts.debug
  M.config.cmd = opts.cmd
  M.config.root_dir = opts.root_dir
  M.config.filetypes = opts.filetypes

  --- Starts the LSP client, or reuses existing if there is one already.
  --- @param on_init? fun(...)
  function M.start(on_init)
    M.config.on_init = function(...)
      opts.on_init(...)
      if on_init then
        on_init(...)
      end
    end
    vim.lsp.start(M.config)
  end

  vim.api.nvim_create_autocmd({ 'FileType' }, {
    group = M.augroup,
    pattern = opts.filetypes,
    callback = function(ev)
      if type(vim.fn.getbufvar(ev.buf, 'amazonq')) == 'table' then
        return -- Don't attach to our own chat buffer.
      end
      M.start()
    end,
  })
end

--- Translates a vim mark-like position (see `:help api-indexing`) to LSP position.
---
--- @param pos_encoding 'utf-8'|'utf-16'|'utf-32' Position encoding
--- @param pos1 integer[]
--- @param pos2 integer[]
--- @param bufnr? integer
function M.get_lsp_pos(pos_encoding, pos1, pos2, bufnr)
  assert(type(pos1) == 'table')
  assert(type(pos2) == 'table')
  local params = vim.lsp.util.make_given_range_params(pos1, pos2, bufnr, pos_encoding)
  local range = params.range

  -- Accept the range only if it is more than a single character, and the
  -- textDocument definition is valid.
  if
    (
      range.start.line < range['end'].line
      or (range.start.line == range['end'].line and range.start.character < range['end'].character - 1)
    ) and (params.textDocument.uri ~= 'file://')
  then
    return params
  end

  return nil
end

return M
