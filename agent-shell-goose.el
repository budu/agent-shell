;;; agent-shell-goose.el --- Goose agent configurations -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Alvaro Ramirez

;; Author: Alvaro Ramirez https://xenodium.com
;; URL: https://github.com/xenodium/agent-shell

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This file includes Goose-specific configurations.
;;

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'shell-maker)
(require 'acp)

(declare-function agent-shell--indent-string "agent-shell")
(declare-function agent-shell-make-agent-config "agent-shell")
(declare-function agent-shell--make-acp-client "agent-shell")
(declare-function agent-shell-start "agent-shell")

(cl-defun agent-shell-make-goose-authentication (&key openai-api-key none)
  "Create Goose authentication configuration.

OPENAI-API-KEY is the OpenAI API key string or function that returns it.
NONE when non-nil disables API key authentication.

Only one of OPENAI-API-KEY or NONE should be provided, never both."
  (when (and openai-api-key none)
    (error "Cannot specify both :openai-api-key and :none - choose one"))
  (unless (or openai-api-key none)
    (error "Must specify either :openai-api-key or :none"))
  (cond
   (openai-api-key `((:openai-api-key . ,openai-api-key)))
   (none `((:none . t)))))

(defcustom agent-shell-goose-authentication nil
  "Configuration for Goose authentication.
For API key (string):

  (setq agent-shell-goose-authentication
        (agent-shell-make-goose-authentication :openai-api-key \"your-key\"))

For API key (function):

  (setq agent-shell-goose-authentication
        (agent-shell-make-goose-authentication :openai-api-key (lambda () ...)))

For no authentication (when using alternative authentication methods):

  (setq agent-shell-goose-authentication
        (agent-shell-make-goose-authentication :none t))"
  :type 'alist
  :group 'agent-shell)

(defcustom agent-shell-goose-command
  '("goose" "acp")
  "Command and parameters for the Goose client.

The first element is the command name, and the rest are command parameters."
  :type '(repeat string)
  :group 'agent-shell)

(defcustom agent-shell-goose-environment
  nil
  "Environment variables for the Goose client.

This should be a list of environment variables to be used when
starting the Goose client process.

Example usage to set custom environment variables:

  (setq agent-shell-goose-environment
        (`agent-shell-make-environment-variables'
         \"MY_VAR\" \"some-value\"
         \"MY_OTHER_VAR\" \"another-value\"))"
  :type '(repeat string)
  :group 'agent-shell)

(defun agent-shell-goose-make-agent-config ()
  "Create a Goose agent configuration.

Returns an agent configuration alist using `agent-shell-make-agent-config'."
  (agent-shell-make-agent-config
   :mode-line-name "Goose"
   :buffer-name "Goose"
   :shell-prompt "Goose> "
   :shell-prompt-regexp "Goose> "
   :welcome-function #'agent-shell-goose--welcome-message
   :icon-name "goose.png"
   :client-maker (lambda (buffer)
                   (agent-shell-goose-make-client :buffer buffer))
   :install-instructions "See https://block.github.io/goose/docs/getting-started/installation."))

(defun agent-shell-goose-start-agent ()
  "Start an interactive Goose agent shell."
  (interactive)
  (agent-shell-start
   :config (agent-shell-goose-make-agent-config)))

(cl-defun agent-shell-goose-make-client (&key buffer)
  "Create a Goose client using configured authentication with BUFFER as context.

Uses `agent-shell-goose-authentication' for authentication configuration."
  (unless buffer
    (error "Missing required argument: :buffer"))
  (let ((api-key (agent-shell-goose-key)))
    (agent-shell--make-acp-client :command (car agent-shell-goose-command)
                                  :command-params (cdr agent-shell-goose-command)
                                  :environment-variables (append (cond ((map-elt agent-shell-goose-authentication :none)
                                                                        nil)
                                                                       (api-key
                                                                        (list (format "OPENAI_API_KEY=%s" api-key)))
                                                                       (t
                                                                        (error "Missing Goose authentication (see agent-shell-goose-authentication)")))
                                                                 agent-shell-goose-environment)
                                  :context-buffer buffer)))

(defun agent-shell-goose-key ()
  "Get the Goose OpenAI API key."
  (cond ((stringp (map-elt agent-shell-goose-authentication :openai-api-key))
         (map-elt agent-shell-goose-authentication :openai-api-key))
        ((functionp (map-elt agent-shell-goose-authentication :openai-api-key))
         (condition-case _err
             (funcall (map-elt agent-shell-goose-authentication :openai-api-key))
           (error
            (error "OpenAI API key not found.  Check out `agent-shell-goose-authentication'"))))
        (t
         nil)))

(defun agent-shell-goose--welcome-message (config)
  "Return Goose welcome message using `shell-maker' CONFIG."
  (let ((art (agent-shell--indent-string 4 (agent-shell-goose--ascii-art)))
        (message (string-trim-left (shell-maker-welcome-message config) "\n")))
    (concat "\n\n"
            art
            "\n\n"
            message)))

(defun agent-shell-goose--ascii-art ()
  "Goose ASCII art."
  (let* ((is-dark (eq (frame-parameter nil 'background-mode) 'dark))
         (text (string-trim "
╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮
│ ╭───╯ │ ╭─╮ │ │ ╭─╮ │ │ ╭───╯ │ ╭───╯
│ │     │ │ │ │ │ │ │ │ │ ╰───╮ │ ╰───╮
│ │ ╭─╮ │ │ │ │ │ │ │ │ ╰───╮ │ │ ╭───╯
│ ╰─╯ │ │ ╰─╯ │ │ ╰─╯ │ ╭───╯ │ │ ╰───╮
╰───╮ │ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯
    ╰─╯" "\n")))
    (propertize text 'font-lock-face (if is-dark
                                         '(:foreground "#a0a0a0")
                                       '(:foreground "#505050")))))

(provide 'agent-shell-goose)

;;; agent-shell-goose.el ends here
