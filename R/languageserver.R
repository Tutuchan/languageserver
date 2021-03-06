#' @useDynLib languageserver
#' @importFrom R6 R6Class
#' @details
#' An implementation of the Language Server Protocol for R
"_PACKAGE"


LanguageServer <- R6::R6Class("LanguageServer",
    public = list(
        tcp = FALSE,
        inputcon = NULL,
        outputcon = NULL,
        exit_flag = NULL,
        request_handlers = NULL,
        notification_handlers = NULL,
        documents = new.env(),
        workspace = NULL,

        run_lintr = TRUE,

        processId = NULL,
        rootUri = NULL,
        rootPath = NULL,
        initializationOptions = NULL,
        ClientCapabilities = NULL,

        sync_in = NULL,
        sync_out = NULL,
        reply_queue = NULL,

        initialize = function(host, port) {
            if (is.null(port)) {
                logger$info("connection type: stdio")
                outputcon <- stdout()
                inputcon <- file("stdin")
                # note: windows doesn't non-blocking read stdin
                open(inputcon, blocking = FALSE)
            } else {
                self$tcp <- TRUE
                logger$info("connection type: tcp at ", port)
                inputcon <- socketConnection(host = host, port = port, open = "r+")
                logger$info("connected")
                outputcon <- inputcon
            }

            self$inputcon <- inputcon
            self$outputcon <- outputcon
            self$register_handlers()

            self$workspace <- Workspace$new()
            self$sync_in <- collections::OrderedDictL$new()
            self$sync_out <- collections::OrderedDictL$new()
            self$reply_queue <- collections::QueueL$new()

            self$process_sync_in <- leisurize(
                function() process_sync_in(self), 0.3)
            self$process_sync_out <- (function() process_sync_out(self))
        },

        finalize = function() {
            close(self$inputcon)
        },

        deliver = function(message) {
            if (!is.null(message)) {
                cat(message$format(), file = self$outputcon)
                logger$info("deliver: ", class(message))
                method <- message$method
                if (!is.null(method)) {
                    logger$info("method: ", method)
                }
            }
        },

        handle_raw = function(data) {
            payload <- tryCatch(
                jsonlite::fromJSON(data, simplifyVector = FALSE),
                error = function(e) e)
            if (inherits(payload, "error")) {
                logger$error("error handling json: ", payload)
                return(NULL)
            }
            pl_names <- names(payload)
            logger$info("received payload.")
            if ("id" %in% pl_names && "method" %in% pl_names) {
                self$handle_request(payload)
            } else if ("method" %in% pl_names) {
                self$handle_notification(payload)
            } else {
                logger$error("not request or notification")
            }
        },

        handle_request = function(request) {
            id <- request$id
            method <- request$method
            params <- request$params
            if (method %in% names(self$request_handlers)) {
                logger$info("handling request: ", method)
                tryCatch({
                    dispatch <- self$request_handlers[[method]]
                    dispatch(self, id, params)
                },
                error = function(e) {
                    logger$error("internal error: ", e)
                    self$deliver(ResponseErrorMessage$new(id, "InternalError", to_string(e)))
                })
            } else {
                logger$error("unknown request: ", method)
                self$deliver(ResponseErrorMessage$new(
                    id, "MethodNotFound", paste0("unknown request ", method)))
            }
        },

        handle_notification = function(notification) {
            method <- notification$method
            params <- notification$params
            if (method %in% names(self$notification_handlers)) {
                logger$info("handling notification: ", method)
                tryCatch({
                    dispatch <- self$notification_handlers[[method]]
                    dispatch(self, params)
                },
                error = function(e) {
                    logger$error("internal error: ", e)
                })
            } else {
                logger$error("unknown notification: ", method)
            }
        },

        process_events = function() {
            self$process_sync_in()
            self$process_sync_out()
            self$process_reply_queue()
        },

        text_sync = function(uri, document = NULL, run_lintr = TRUE, parse = TRUE) {
            if (self$sync_in$has(uri)) {
                # make sure we do not accidentially override list call with `parse = FALSE`
                item <- self$sync_in$pop(uri)
                parse <- parse || item$parse
                run_lintr <- run_lintr || item$run_lintr
            }
            self$sync_in$set(
                uri, list(document = document, run_lintr = run_lintr, parse = parse))
        },

        process_sync_in = NULL,

        process_sync_out = NULL,

        process_reply_queue = function() {
            while (self$reply_queue$size() > 0) {
                reply <- self$reply_queue$pop()
                self$deliver(reply)
            }
        },

        check_connection = function() {
            if (!isOpen(self$inputcon)) {
                self$exit_flag <- TRUE
            }

            if (.Platform$OS.type == "unix" && getppid() == 1) {
                # exit if the current process becomes orphan
                self$exit_flag <- TRUE
            }
        },

        read_line = function() {
            if (self$tcp) {
                readLines(self$inputcon, n = 1)
            } else {
                .Call("stdin_read_line", PACKAGE = "languageserver")
            }
        },

        read_char = function(n) {
            if (self$tcp) {
                readChar(self$inputcon, n)
            } else {
                .Call("stdin_read_char", PACKAGE = "languageserver", n)
            }
        },

        read_header = function() {
            if (self$tcp && !socketSelect(list(self$inputcon), timeout = 0)) return(NULL)
            header <- self$read_line()
            if (length(header) == 0 || nchar(header) == 0) return(NULL)

            logger$info("received: ", header)
            matches <- stringr::str_match(header, "Content-Length: ([0-9]+)")
            if (is.na(matches[2]))
                stop("Unexpected input: ", header)
            as.integer(matches[2])
        },

        read_content = function(nbytes) {
            empty_line <- self$read_line()
            while (length(empty_line) == 0) {
                empty_line <- self$read_line()
                Sys.sleep(0.01)
            }
            if (nchar(empty_line) > 0)
                stop("Unexpected non-empty line")
            data <- ""
            while (nbytes > 0) {
                newdata <- self$read_char(nbytes)
                if (length(newdata) > 0) {
                    nbytes <- nbytes - nchar(newdata, type = "bytes")
                    data <- paste0(data, newdata)
                }
                Sys.sleep(0.01)
            }
            data
        },

        eventloop = function() {
            while (TRUE) {
                ret <- try({
                    self$check_connection()

                    if (isTRUE(self$exit_flag)) {
                        logger$info("exiting")
                        break
                    }

                    self$process_events()

                    nbytes <- self$read_header()
                    if (is.null(nbytes)) {
                        Sys.sleep(0.1)
                        next
                    }
                    data <- self$read_content(nbytes)
                    self$handle_raw(data)
                }, silent = TRUE)
                if (inherits(ret, "try-error")) {
                    logger$error(ret)
                    logger$error(as.list(traceback()))
                    logger$error("exiting")
                    break
                }
            }
        },

        run = function() {
            self$eventloop()
        }
    )
)

LanguageServer$set("public", "register_handlers", function() {
    self$request_handlers <- list(
        initialize = on_initialize,
        shutdown = on_shutdown,
        `textDocument/completion` =  text_document_completion,
        `textDocument/hover` = text_document_hover,
        `textDocument/signatureHelp` = text_document_signature_help,
        `textDocument/formatting` = text_document_formatting,
        `textDocument/rangeFormatting` = text_document_range_formatting
    )

    self$notification_handlers <- list(
        initialized = on_initialized,
        exit = on_exit,
        `textDocument/didOpen` = text_document_did_open,
        `textDocument/didChange` = text_document_did_change,
        `textDocument/didSave` = text_document_did_save,
        `textDocument/didClose` = text_document_did_close,
        `workspace/didChangeConfiguration` = workspace_did_change_configuration
    )
})


#' Run the R language server
#' @param debug set \code{TRUE} to show debug information in stderr;
#'              or it could be a character string specifying the log file
#' @param host the hostname used to create the tcp server, not used when \code{port} is \code{NULL}
#' @param port the port used to create the tcp server. If \code{NULL}, use stdio instead.
#' @examples
#' \dontrun{
#' # to use stdio
#' languageserver::run()
#'
#' # to use tcp server
#' languageserver::run(port = 8888)
#' }
#' @export
run <- function(debug = FALSE, host = "localhost", port = NULL) {
    tools::Rd2txt_options(underline_titles = FALSE)
    tools::Rd2txt_options(itemBullet = "* ")
    logger$debug_mode(debug)
    langserver <- LanguageServer$new(host, port)
    langserver$run()
}
