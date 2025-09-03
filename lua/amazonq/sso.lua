-- TODO: Check authentication status at startup

local util = require('amazonq.util')
local lsp = require('amazonq.lsp')

local M = {}
--- @type vim.lsp.Client LSP client instance
M.client = nil
--- @type string SSO start URL from plugin configuration
M.sso_start_url = nil

-- Handler for 'aws/credentials/token/update' response
function M.on_update_credentials(_, _, _)
  util.dismiss_popup()
  util.msg('updated SSO token', vim.log.levels.INFO)
end

-- Handler for 'aws/credentials/getConnectionMetadata' request
function M.on_get_connection_metadata()
  return {
    sso = {
      startUrl = M.sso_start_url,
    },
  }
end

--- Performs login, and calls `on_login` when a response is received.
---
--- @param on_login? fun(err, result)
function M.login(on_login)
  -- Server docs: https://github.com/aws/language-server-runtimes/blob/main/runtimes/README.md#lsp
  lsp.lsp_request(M.client, 'workspace/executeCommand', {
    command = 'ssoAuth/authDevice/getToken',
    arguments = {
      startUrl = M.sso_start_url or nil,
    },
  }, function(err, result)
    if err then
      util.msg(err, vim.log.levels.ERROR)
    end

    if result then
      M.bearer_token = result.token
      M.update_token(result.token)
    end

    if on_login then
      on_login(err, result)
    end
  end)
end

function M.update_token(token)
  -- Send encrypted token to server. https://github.com/aws/language-server-runtimes/blob/main/runtimes/README.md#auth
  lsp.lsp_request(M.client, 'aws/credentials/token/update', {
    data = {
      token = token,
    },
    encrypted = false,
  }, function()
    M.on_update_credentials()
  end)
end

function M.logout()
  lsp.lsp_request(M.client, 'aws/credentials/token/delete', {}, function()
    M.on_update_credentials()
  end)
end

--- Performs login/auth after LSP client is initialized.
---
--- @param lsp_client vim.lsp.Client
function M.on_lsp_init(lsp_client)
  M.client = lsp_client

  -- Register handlers for custom LSP methods and notifications
  M.client.handlers['aws/credentials/token/update'] = M.on_update_credentials
  M.client.handlers['aws/credentials/getConnectionMetadata'] = M.on_get_connection_metadata

  -- Try to Authenticate automatically when LSP client is first initialized
  M.login()
end

-- Setup function to initialize the SSO module
--- @param sso_start_url_config string
function M.setup(sso_start_url_config)
  M.sso_start_url = sso_start_url_config
  lsp.sso_login = M.login
end

return M
