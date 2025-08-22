# Amazon Q Developer Language Server

Currently Language Server is compiled from https://github.com/aws/language-servers/tree/main/app/aws-lsp-codewhisperer-runtimes package with slightly modified server implementation. Language Server used with this plugin is available at `./build/aws-lsp-codewhisperer-token-binary.js` file.

Build configuration used to produce this Amazon Q Language Server version is stored [neovim_q](https://github.com/aws/language-servers/blob/neovim_q/app/aws-lsp-codewhisperer-runtimes/src/token-standalone.ts) branch of AWS Language Servers project.

Current Language Server version commit: `9f1fb4caba792185bf5773d87b209750587f1b52`

## How to build Language Server

1. Clone `neovim_q` branch from [AWS Language Servers](https://github.com/aws/language-servers/):

```
git clone https://github.com/aws/language-servers/ && cd language-servers && git checkout neovim_q
```

2. Compile repository

```
npm install && npm run package
```

3. To use compiled server, set `cmd` configuration with path to locally compiled file at `language-servers/app/aws-lsp-codewhisperer-runtimes/build/aws-lsp-codewhisperer-token-binary.js`. See [:help amazonq-config](https://github.com/awslabs/amazonq.nvim/blob/main/doc/amazonq.txt#L207) for details.
