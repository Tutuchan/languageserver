# languageserver: An implementation of the Language Server Protocol for R

[![CRAN\_Status\_Badge](http://www.r-pkg.org/badges/version/languageserver)](https://cran.r-project.org/package=languageserver)
[![](http://cranlogs.r-pkg.org/badges/grand-total/languageserver)](https://cran.r-project.org/package=languageserver)

`languageserver` is an implement of the Microsoft's [Language Server Protocol](https://microsoft.github.io/language-server-protocol) for the language of R.

It is released on CRAN and can be easily installed by
```
install.packages("languageserver")
```

The development version of `languageserver` could be installed by running the following in R
```
source("https://install-github.me/REditorSupport/languageserver")
```

## Language Clients

These editors are supported by installing the corresponding package.

- VSCode: [vscode-r-lsp](https://github.com/REditorSupport/vscode-r-lsp)

- Atom: [atom-ide-r](https://github.com/REditorSupport/atom-ide-r)

- Sublime Text: [R-IDE](https://github.com/REditorSupport/sublime-ide-r)

- Vim/NeoVim: [LanguageClient-neovim](https://github.com/autozimu/LanguageClient-neovim) with settings
```vim
let g:LanguageClient_serverCommands = {
    \ 'r': ['R', '--slave', '-e', 'languageserver::run()'],
    \ }
```

- EMacs: [lsp-mode](https://github.com/emacs-lsp/lsp-mode) with settings
```elisp
(lsp-define-stdio-client lsp-R "R"
                         (lambda () default-directory)
			 '("R" "--slave" "-e" "languageserver::run()"))
(add-hook 'R-mode-hook #'lsp-R-enable)
```

## Services Implemented

`languageserver` is still under active development, the following services have been implemented:

- [x] textDocumentSync (diagnostics)
- [x] hoverProvider
- [x] completionProvider
- [x] signatureHelpProvider
- [x] definitionProvider
- [ ] referencesProvider
- [ ] documentHighlightProvider
- [ ] documentSymbolProvider
- [ ] workspaceSymbolProvider
- [ ] codeActionProvider
- [ ] codeLensProvider
- [x] documentFormattingProvider
- [x] documentRangeFormattingProvider
- [ ] documentOnTypeFormattingProvider
- [ ] renameProvider
- [ ] documentLinkProvider
- [ ] executeCommandProvider


## Diagnostics settings

User can specify the default linters in `.Rprofile`. For example,

```r
setHook(
    packageEvent("languageserver", "onLoad"),
    function(...) {
        options(languageserver.default_linters = lintr::with_defaults(
            line_length_linter = lintr::line_length_linter(100),
            object_usage_linter = NULL,
            object_length_linter = NULL,
            object_name_linter = NULL,
            commented_code_linter = NULL
        ))
    }
)
```
Please note that this setting is ignored if a `.lintr` file is found.

## Development

To add a new functionality:
+ update `capabilities.R` with the new capability options if needed and uncomment the line in ServerCapabilities,
+ update the associated function in `handlers-langfeatures.R`,
+ create or update the underlying code,
+ reinstall the package with `devtools::install()`, run the server in debug mode in a separate terminal window,
+ reload the VSCode window (`Cmd+Shift+P` on Mac OS) and check the messages in the server + the behaviour in VSCode.
