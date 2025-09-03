# Implementation details

## Q Language Server APIs

Amazon Q language server is developed in [AWS Language Server](https://github.com/aws/language-servers/tree/main/server/aws-lsp-codewhisperer) project and is built with [Language Server Runtimes](https://github.com/aws/language-server-runtimes/tree/main/runtimes) framework.

### Q Chat API

Amazon Q Chat language server implement LSP extension protocol for Chat: https://github.com/aws/language-server-runtimes/blob/main/runtimes/README.md#chat.

## Context collection in Q Chat window

Implementation of client side context collection for Chat replicates version of Amazon Q for VSCode. Q Language server attaches relevant files opened in IDE and registered in Language Server to requests to Q Chat backend. These 2 PR have some details:
https://github.com/aws/language-servers/pull/231
https://github.com/aws/language-servers/pull/463
