# Neovim plugin for Amazon Q Developer

This plugin integrates Amazon Q Developer with Neovim, providing Chat functionality, Inline Code Suggestions, and other Amazon Q capabilities. After installation, [authenticate](#authentication-to-amazon-q-developer) through IAM Identity Center or AWS Builder ID. You can use Amazon Q for free without an AWS account by authenticating with Builder ID.

## Requirements

- NodeJS >=18
- Neovim >=0.10.4

## Quick Start

1. Install the plugin using your preferred method (see [Installation Options](#installation-options))
2. Configure the plugin in your Neovim config:
   ```lua
   require('amazonq').setup({
     ssoStartUrl = 'https://view.awsapps.com/start', -- Authenticate with Amazon Q Free Tier
   })
   ```
3. Run `:AmazonQ` from any file to start using the plugin

## Installation Options

### Minimal Manual Installation

To install and use the plugin, you only need to clone this repo and add in to Neovim runtimepath location:

```lua
-- Add the plugin to Neovim's runtimepath
vim.cmd[[set runtimepath+=/path/to/amazonq.nvim]]

-- Configure the plugin
require('amazonq').setup({
  ssoStartUrl = 'https://view.awsapps.com/start', -- Authenticate with Amazon Q Free Tier
})
```
- See [Configuration](#configuration) to configure other settings.
    - By default the plugin will look for `node` on your $PATH. To set an explicit location, set `cmd`.
3. Run `:AmazonQ` from any file.
4. *Optional:* Code completions are provided by the "textDocument/completion" LSP method, which "just works" with most autocompletion plugins.
    - Note: completion is limited to supported filetypes.
    - See [Inline Code Suggestions](#inline-code-suggestions).

### Using vim-plug

```lua
local Plug = vim.fn['plug#']
vim.call('plug#begin')
Plug 'git@github.com:awslabs/amazonq.nvim.git'
vim.call('plug#end')

require('amazonq').setup({
  ssoStartUrl = 'https://view.awsapps.com/start', -- Authenticate with Amazon Q Free Tier
})
```

### Using lazy.nvim

See [install instructions](https://lazy.folke.io/installation)

```lua
-- plugins.lua
return {
  {
    name = 'amazonq',
    url = 'https://github.com/awslabs/amazonq.nvim.git',
    opts = {
      ssoStartUrl = 'https://view.awsapps.com/start',  -- Authenticate with Amazon Q Free Tier
    },
  },
}
```

## Authentication to Amazon Q Developer

You can authenticate using one of two methods:

* **Amazon Q Free Tier**: Use AWS Builder ID with the URL `https://view.awsapps.com/start`
* **Amazon Q Developer Pro**: Use the start URL provided by your administrator

Configure authentication by setting the `ssoStartUrl` value in your setup:

```lua
require('amazonq').setup({
  ssoStartUrl = 'https://view.awsapps.com/start', -- For Free Tier with AWS Builder ID
  -- OR
  -- ssoStartUrl = 'your-organization-sso-url', -- For Pro subscription
})
```

## Usage

The plugin provides a single global `:AmazonQ` command and `zq` mapping:

| Command/Mapping | Description |
|----------------|-------------|
| `:AmazonQ` | Open Amazon Q chat window |
| `zq` | Select text, then type `zq` to append it to the chat context. Equivalent to: select text, type `:AmazonQ`, then run the command. |
| `:AmazonQ refactor` | Select code, then run this to get refactoring suggestions |
| `:.AmazonQ fix` | Fix only the current line (the standard "." range means "current line") |
| `:%AmazonQ optimize` | Optimize the entire contents of the current file |
| `:AmazonQ explain` | Explain the current file |

For complete documentation, see [:help amazonq-usage](https://github.com/awslabs/amazonq.nvim/blob/main/doc/amazonq.txt) and [:help amazonq-chat](https://github.com/awslabs/amazonq.nvim/blob/main/doc/amazonq.txt).

## Configuration

Below are the available configuration options with their default values. Only `ssoStartUrl` is required. See [:help amazonq-config](https://github.com/awslabs/amazonq.nvim/blob/main/doc/amazonq.txt#L197)
for details.

```lua
require('amazonq').setup({
  -- REQUIRED: SSO portal URL for authentication
  ssoStartUrl = 'https://view.awsapps.com/start',
  -- OR
  -- ssoStartUrl = 'your-organization-sso-url', -- For Pro subscription

  -- Command to start Amazon Q Language Server
  -- Defaults to the language server bundled with this plugin
  cmd = { 'node', 'language-server/build/aws-lsp-codewhisperer-token-binary.js', '--stdio' },
  
  -- Filetypes where the Q will be activated
  -- See: https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/q-language-ide-support.html
  -- `amazonq` is required for Q Chat feature.
  filetypes = {
      'amazonq', 'bash', 'java', 'python', 'typescript', 'javascript', 'csharp', 
      'ruby', 'kotlin', 'sh', 'sql', 'c', 'cpp', 'go', 'rust', 'lua',
  },

  -- Enable/disable inline code suggestions
  inline_suggest = true,

  -- Configure the chat panel position and appearance
  on_chat_open = function()
    vim.cmd[[
      vertical topleft split
      set wrap breakindent nonumber norelativenumber nolist
    ]]
  end,

  -- Enable debug mode for development
  debug = false,
})
```

## Inline Code Suggestions

Amazon Q provides AI-powered [code suggestions](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/inline-suggestions.html) as you type. These are implemented through the LSP `textDocument/completion` method and work with most Neovim completion plugins (nvim-cmp, blink, mini.completion, etc.).

To use inline suggestions:

1. Authenticate with `:AmazonQ login`
2. Start typing in a supported filetype
3. Trigger completion using your completion plugin's keybinding

Inline suggestions are enabled by default. To disable them:

```lua
require('amazonq').setup({
  -- Other settings...
  inline_suggest = false,
})
```

For plugin-specific configuration, see [:help amazonq-config-completion](https://github.com/awslabs/amazonq.nvim/blob/main/doc/amazonq.txt#L175).

## Troubleshooting

### Checking Language Server Status

To verify the language server is running:

```vim
:checkhealth vim.lsp
```

This shows if the server is attached to the current file and displays the path to the log file (e.g. `/local/home/$user/.local/state/nvim/lsp.log`).

### Enabling Debug Logs

To see detailed communication between the plugin and Language Server:

```lua
vim.lsp.set_log_level('debug')
```

### Common Issues

- If the plugin isn't working, ensure NodeJS >=18 is installed and in your PATH
- For authentication issues, verify your `ssoStartUrl` is correct
- For filetype-specific problems, check that the filetype is in your `filetypes` configuration

## Development

To develop this plugin, you probably want to add it to the Nvim `'runtimepath'` so that you can test your changes easily. In that case, *remove* it from your plugin manager config.

1. Clone amazonq.nvim package locally:
   ```
   git clone git@github.com:awslabs/amazonq.nvim.git
   ```

2. *Remove* amazonq.nvim from your plugin manager config, if necessary.

3. Add the amazonq.nvim package to the Nvim `'runtimepath'`. This tells Nvim to look for plugins at that path.
   ```lua
   vim.cmd[[set runtimepath+=/path/to/amazonq.nvim]]
   ```

4. You can now use the `amazonq` plugin located in the amazonq.nvim package path. You can make edits, restart Nvim to test them, open Pull Requests, etc.
   ```lua
   require('amazonq').setup({
     ssoStartUrl = 'https://view.awsapps.com/start',
     debug = true, -- Enable debug mode during development
   })
   ```

See [develop.md](./doc/develop.md) for more implementation details of plugin and language server.

### Debugging

- To debug the LSP server, see https://github.com/aws/language-servers/blob/main/CONTRIBUTING.md#with-other-clients

### Logging

- To enable logging, pass `debug=true` to `require('amazonq').setup{}`.
- Logs are written to `vim.fs.joinpath(vim.fn.stdpath('log'), 'amazonq.log')`
- Nvim also produces its own `vim.lsp` logs by default.
    - Enable DEBUG log-level for Nvim lsp (hint: put this in a workspace-local `.nvim.lua` file and enable the `:help 'exrc'` option):
      ```
      vim.lsp.set_log_level('debug')
      ```
    - File: `:lua =vim.lsp.log.get_filename()`
    - Logs produced by Amazon Q Language server will appear there as `"window/logMessage"` messages:
      ```
      "window/logMessage", … "Runtime: Initializing runtime without encryption", type = 3 } }
      "window/logMessage", … "Runtime: Registering IAM credentials update handler", type = 3 } }
      "window/logMessage", … "Runtime: Registering bearer credentials update handler", type = 3 } }
      ...
      "window/logMessage", … "Q Chat server has been initialized", type = 3 } }
      "window/logMessage", … "SSO Auth capability has been initialised", type = 3 } }
      "window/logMessage", … "Auth Device command called", type = 3 } }
      "window/logMessage", … 'Resolved SSO token {"accessToken":"…","expiresAt":"2025-01-21T21:44:20.631Z",…}',…} }
      "window/logMessage", … "Received chat prompt", type = 3 } }
      "window/logMessage", … "Request for conversation id: New conversation", type = 3 } }
      ```

### Code Formatting and Linting

Code is formatted using [stylua](https://github.com/JohnnyMorganz/StyLua) and linted using [selene](https://github.com/Kampfkarren/selene).
Currently it's not automated, you must run it manually:

1. Install the required tools:
    - stylua:
      - macOS: `brew install stylua`
      - win/linux: https://github.com/JohnnyMorganz/StyLua/releases
    - selene:
      - macOS: `brew install selene`
      - win/linux: https://github.com/Kampfkarren/selene/releases
2. Run (from the top level directory):
    - To check files both selene and stylua in check mode:
      ```sh
      make lint
      ```

    - To format files with stylua:
      ```sh
      make format
      ```

### Implementation

- Inline suggestions are provided by creating a in-process LSP shim client is named `amazonq-completion`.
    - This is a temporary measure until Q LSP provides this out of the box.
    - Vim has a [known limitation](https://github.com/neovim/neovim/issues/7769) where it replaces newlines `\n` in multiline completions with NUL bytes, which it renders as `^@`.
      amazonq.nvim works around this by replacing the NUL bytes in a `CompleteDone` event-handler. 

## Experimental Status and Contributions

The Neovim plugin for Amazon Q Developer is in experimental state. 
We welcome contributions and feedback! See [Contributing Guide](CONTRIBUTING.md) for details on contributing feedback, feature requests, and bug reports.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.
