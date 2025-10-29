;;; agent-shell-tests.el --- Tests for agent-shell -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-shell)

;;; Code:

(ert-deftest agent-shell-make-environment-variables-test ()
  "Test `agent-shell-make-environment-variables' function."
  ;; Test basic key-value pairs
  (should (equal (agent-shell-make-environment-variables
                  "PATH" "/usr/bin"
                  "HOME" "/home/user")
                 '("PATH=/usr/bin"
                   "HOME=/home/user")))

  ;; Test empty input
  (should (equal (agent-shell-make-environment-variables) '()))

  ;; Test single pair
  (should (equal (agent-shell-make-environment-variables "FOO" "bar")
                 '("FOO=bar")))

  ;; Test with keywords (should be filtered out)
  (should (equal (agent-shell-make-environment-variables
                  "VAR1" "value1"
                  :inherit-env nil
                  "VAR2" "value2")
                 '("VAR1=value1"
                   "VAR2=value2")))

  ;; Test error on incomplete pairs
  (should-error (agent-shell-make-environment-variables "PATH")
                :type 'error)

  ;; Test :inherit-env t
  (let ((process-environment '("EXISTING_VAR=existing_value"
                               "MY_OTHER_VAR=another_value")))
    (should (equal (agent-shell-make-environment-variables
                    "NEW_VAR" "new_value"
                    :inherit-env t)
                   '("NEW_VAR=new_value"
                     "EXISTING_VAR=existing_value"
                     "MY_OTHER_VAR=another_value"))))

  ;; Test :load-env with single file
  (let ((env-file (let ((file (make-temp-file "test-env" nil ".env")))
                    (with-temp-file file
                      (insert "TEST_VAR=test_value\n")
                      (insert "# This is a comment\n")
                      (insert "ANOTHER_TEST=another_value\n")
                      (insert "\n")  ; empty line
                      (insert "THIRD_VAR=third_value\n"))
                    file)))
    (unwind-protect
        (should (equal (agent-shell-make-environment-variables
                        "MANUAL_VAR" "manual_value"
                        :load-env env-file)
                       '("MANUAL_VAR=manual_value"
                         "TEST_VAR=test_value"
                         "ANOTHER_TEST=another_value"
                         "THIRD_VAR=third_value")))
      (delete-file env-file)))

  ;; Test :load-env with multiple files
  (let ((env-file1 (let ((file (make-temp-file "test-env1" nil ".env")))
                     (with-temp-file file
                       (insert "FILE1_VAR=file1_value\n")
                       (insert "SHARED_VAR=from_file1\n"))
                     file))
        (env-file2 (let ((file (make-temp-file "test-env2" nil ".env")))
                     (with-temp-file file
                       (insert "FILE2_VAR=file2_value\n")
                       (insert "SHARED_VAR=from_file2\n"))
                     file)))
    (unwind-protect
        (should (equal (agent-shell-make-environment-variables
                        :load-env (list env-file1 env-file2))
                       '("FILE1_VAR=file1_value"
                         "SHARED_VAR=from_file1"
                         "FILE2_VAR=file2_value"
                         "SHARED_VAR=from_file2")))
      (delete-file env-file1)
      (delete-file env-file2)))

  ;; Test :load-env with non-existent file (should error)
  (should-error (agent-shell-make-environment-variables
                 "TEST_VAR" "test_value"
                 :load-env "/non/existent/file")
                :type 'error)

  ;; Test :load-env combined with :inherit-env
  (let ((env-file (let ((file (make-temp-file "test-env" nil ".env")))
                    (with-temp-file file
                      (insert "ENV_FILE_VAR=env_file_value\n"))
                    file))
        (process-environment '("EXISTING_VAR=existing_value")))
    (unwind-protect
        (should (equal (agent-shell-make-environment-variables
                        "MANUAL_VAR" "manual_value"
                        :load-env env-file
                        :inherit-env t)
                       '("MANUAL_VAR=manual_value"
                         "ENV_FILE_VAR=env_file_value"
                         "EXISTING_VAR=existing_value")))
      (delete-file env-file))))

(ert-deftest agent-shell--resolve-devcontainer-path-test ()
  "Test `agent-shell--resolve-devcontainer-path' function."
  ;; Mock agent-shell--get-devcontainer-workspace-path
  (cl-letf (((symbol-function 'agent-shell--get-devcontainer-workspace-path)
             (lambda (_) "/workspace")))

    ;; Need to run in an existing directory (requirement of `file-in-directory-p')
    (let ((default-directory "/tmp"))
      ;; With text file capabilities enabled
      (let ((agent-shell-text-file-capabilities t))

        ;; Resolves container paths to local filesystem paths
        (should (equal (agent-shell--resolve-devcontainer-path "/workspace/d/f.el") "/tmp/d/f.el"))
        (should (equal (agent-shell--resolve-devcontainer-path "/workspace/f.el") "/tmp/f.el"))
        (should (equal (agent-shell--resolve-devcontainer-path "/workspace") "/tmp"))

        ;; Prevents attempts to leave local working directory
        (should-error (agent-shell--resolve-devcontainer-path "/workspace/..") :type 'error)

        ;; Resolves local filesystem paths to container paths
        (should (equal (agent-shell--resolve-devcontainer-path "/tmp/d/f.el") "/workspace/d/f.el"))
        (should (equal (agent-shell--resolve-devcontainer-path "/tmp/f.el") "/workspace/f.el"))
        (should (equal (agent-shell--resolve-devcontainer-path "/tmp") "/workspace"))

        ;; Does not resolve unexpected paths
        (should-error (agent-shell--resolve-devcontainer-path "/unexpected") :type 'error))

      ;; With text file capabilities disabled (ie. never resolve to local filesystem)
      (let ((agent-shell-text-file-capabilities nil))

        ;; Does not resolve container paths to local filesystem paths
        (should-error (agent-shell--resolve-devcontainer-path "/workspace/d/f.el") :type 'error)
        (should-error (agent-shell--resolve-devcontainer-path "/workspace/f.el.") :type 'error)
        (should-error (agent-shell--resolve-devcontainer-path "/workspace") :type 'error)
        (should-error (agent-shell--resolve-devcontainer-path "/workspace/..") :type 'error)

        ;; Resolves local filesystem paths to container paths
        (should (equal (agent-shell--resolve-devcontainer-path "/tmp/d/f.el") "/workspace/d/f.el"))
        (should (equal (agent-shell--resolve-devcontainer-path "/tmp/f.el") "/workspace/f.el"))
        (should (equal (agent-shell--resolve-devcontainer-path "/tmp") "/workspace"))

        ;; Does not resolve unexpected paths
        (should-error (agent-shell--resolve-devcontainer-path "/unexpected") :type 'error)))))

(ert-deftest agent-shell--shorten-paths-test ()
  "Test `agent-shell--shorten-paths' function."
  ;; Mock agent-shell-cwd to return a predictable value
  (cl-letf (((symbol-function 'agent-shell-cwd)
             (lambda () "/path/to/agent-shell/")))

    ;; Test shortening full paths to project-relative format
    (should (equal (agent-shell--shorten-paths
                    "/path/to/agent-shell/README.org")
                   "README.org"))

    ;; Test with subdirectories
    (should (equal (agent-shell--shorten-paths
                    "/path/to/agent-shell/tests/agent-shell-tests.el")
                   "tests/agent-shell-tests.el"))

    ;; Test mixed text with project path
    (should (equal (agent-shell--shorten-paths
                    "Read /path/to/agent-shell/agent-shell.el (4 - 6)")
                   "Read agent-shell.el (4 - 6)"))

    ;; Test text that doesn't contain project path (should remain unchanged)
    (should (equal (agent-shell--shorten-paths
                    "Some random text without paths")
                   "Some random text without paths"))

    ;; Test text with different paths (should remain unchanged)
    (should (equal (agent-shell--shorten-paths
                    "/some/other/path/file.txt")
                   "/some/other/path/file.txt"))

    ;; Test nil input
    (should (equal (agent-shell--shorten-paths nil) nil))

    ;; Test empty string
    (should (equal (agent-shell--shorten-paths "") ""))))

(ert-deftest agent-shell--format-plan-test ()
  "Test `agent-shell--format-plan' function."
  ;; Test homogeneous statuses
  (should (equal (agent-shell--format-plan [((content . "Update state initialization")
                                             (status . "pending"))
                                            ((content . "Update session initialization")
                                             (status . "pending"))])
                 (substring-no-properties
                  " pending  Update state initialization
 pending  Update session initialization")))

  ;; Test mixed statuses
  (should (equal (substring-no-properties
                  (agent-shell--format-plan [((content . "First task")
                                              (status . "pending"))
                                             ((content . "Second task")
                                              (status . "in_progress"))
                                             ((content . "Third task")
                                              (status . "completed"))]))
                 " pending     First task
 in progress  Second task
 completed   Third task"))

  ;; Test empty entries
  (should (equal (agent-shell--format-plan []) "")))

(ert-deftest agent-shell--parse-file-mentions-test ()
  "Test agent-shell--parse-file-mentions function."
  ;; Simple @ mention
  (let ((mentions (agent-shell--parse-file-mentions "@file.txt")))
    (should (= (length mentions) 1))
    (should (equal (map-elt (car mentions) :path) "file.txt")))

  ;; @ mention with quotes
  (let ((mentions (agent-shell--parse-file-mentions "Compare @\"file with spaces.txt\" to @other.txt")))
    (should (= (length mentions) 2))
    (should (equal (map-elt (car mentions) :path) "file with spaces.txt"))
    (should (equal (map-elt (cadr mentions) :path) "other.txt")))

  ;; @ mention at start of line
  (let ((mentions (agent-shell--parse-file-mentions "@README.md is the main file")))
    (should (= (length mentions) 1))
    (should (equal (map-elt (car mentions) :path) "README.md")))

  ;; Multiple @ mentions
  (let ((mentions (agent-shell--parse-file-mentions "Compare @file1.txt with @file2.txt")))
    (should (= (length mentions) 2))
    (should (equal (map-elt (car mentions) :path) "file1.txt"))
    (should (equal (map-elt (cadr mentions) :path) "file2.txt")))

  ;; No @ mentions
  (let ((mentions (agent-shell--parse-file-mentions "No mentions here")))
    (should (= (length mentions) 0))))

(ert-deftest agent-shell--build-content-blocks-test ()
  "Test agent-shell--build-content-blocks function."
  (let* ((temp-file (make-temp-file "agent-shell-test" nil ".txt"))
         (file-content "Test file content")
         (default-directory (file-name-directory temp-file))
         (file-name (file-name-nondirectory temp-file))
         (file-path (expand-file-name temp-file))
         (file-uri (concat "file://" file-path)))

    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert file-content))

          ;; Mock agent-shell-cwd
          (cl-letf (((symbol-function 'agent-shell-cwd)
                     (lambda () default-directory)))

            ;; Test with embedded context support and small file
            (let ((agent-shell--state (list
                                       (cons :agent-supports-embedded-context t))))
              (let ((blocks (agent-shell--build-content-blocks (format "Analyze @%s" file-name))))
                (should (equal blocks
                               `(((type . "text")
                                  (text . "Analyze"))
                                 ((type . "resource")
                                  (resource . ((uri . ,file-uri)
                                               (text . ,file-content)
                                               (mimeType . "text/plain")))))))))

            ;; Test without embedded context support
            (let ((agent-shell--state (list
                                       (cons :agent-supports-embedded-context nil))))
              (let ((blocks (agent-shell--build-content-blocks (format "Analyze @%s" file-name))))
                (should (equal blocks
                               `(((type . "text")
                                  (text . "Analyze"))
                                 ((type . "resource_link")
                                  (uri . ,file-uri)
                                  (name . ,file-name)
                                  (mimeType . "text/plain")
                                  (size . ,(file-attribute-size (file-attributes temp-file)))))))))

            ;; Test fallback by setting a very small file size limit
            (let ((agent-shell--state (list
                                       (cons :agent-supports-embedded-context t)))
                  (agent-shell-embed-file-size-limit 5))
              (let ((blocks (agent-shell--build-content-blocks (format "Analyze @%s" file-name))))
                (should (equal blocks
                               `(((type . "text")
                                  (text . "Analyze"))
                                 ((type . "resource_link")
                                  (uri . ,file-uri)
                                  (name . ,file-name)
                                  (mimeType . "text/plain")
                                  (size . ,(file-attribute-size (file-attributes temp-file)))))))))

            ;; Test with no mentions
            (let ((agent-shell--state (list
                                       (cons :agent-supports-embedded-context t))))
              (let ((blocks (agent-shell--build-content-blocks "No mentions here")))
                (should (equal blocks
                               '(((type . "text")
                                  (text . "No mentions here")))))))))

      (delete-file temp-file))))

(ert-deftest agent-shell--collect-attached-files-test ()
  "Test agent-shell--collect-attached-files function."
  ;; Test with empty list
  (should (equal (agent-shell--collect-attached-files '()) '()))

  ;; Test with resource block
  (let ((blocks '(((type . "resource")
                   (resource . ((uri . "file:///path/to/file.txt")
                                (text . "content"))))
                  ((type . "text")
                   (text . "some text")))))
    (let ((uris (agent-shell--collect-attached-files blocks)))
      (should (= (length uris) 1))
      (should (equal (car uris) "file:///path/to/file.txt"))))

  ;; Test with resource_link block
  (let ((blocks '(((type . "resource_link")
                   (uri . "file:///path/to/file.txt")
                   (name . "file.txt"))
                  ((type . "text")
                   (text . "some text")))))
    (let ((uris (agent-shell--collect-attached-files blocks)))
      (should (= (length uris) 1))
      (should (equal (car uris) "file:///path/to/file.txt"))))

  ;; Test with multiple files
  (let ((blocks '(((type . "resource_link")
                   (uri . "file:///path/to/file1.txt"))
                  ((type . "text")
                   (text . " "))
                  ((type . "resource_link")
                   (uri . "file:///path/to/file2.txt")))))
    (let ((uris (agent-shell--collect-attached-files blocks)))
      (should (= (length uris) 2)))))

(ert-deftest agent-shell--send-command-integration-test ()
  "Integration test: verify agent-shell--send-command calls ACP correctly."
  (let ((sent-request nil)
        (agent-shell--state (list
                            (cons :client 'test-client)
                            (cons :session (list (cons :id "test-session")))
                            (cons :agent-supports-embedded-context t)
                            (cons :buffer (current-buffer)))))

    ;; Mock acp-send-request to capture what gets sent
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest args)
                 (setq sent-request args))))

      ;; Send a simple command
      (agent-shell--send-command
       :prompt "Hello agent"
       :shell nil)

      ;; Verify request was sent
      (should sent-request)

      ;; Verify basic request structure
      (let* ((request (plist-get sent-request :request))
             (params (map-elt request :params))
             (prompt (map-elt params 'prompt)))
        (should prompt)
        (should (equal prompt '[((type . "text") (text . "Hello agent"))]))))))

(ert-deftest agent-shell--send-command-error-fallback-test ()
  "Test agent-shell--send-command falls back to plain text on build-content-blocks error."
  (let ((sent-request nil)
        (agent-shell--state (list
                             (cons :client 'test-client)
                             (cons :session (list (cons :id "test-session")))
                             (cons :agent-supports-embedded-context t)
                             (cons :buffer (current-buffer)))))

    ;; Mock build-content-blocks to throw an error
    (cl-letf (((symbol-function 'agent-shell--build-content-blocks)
               (lambda (_prompt)
                 (error "Simulated error in build-content-blocks")))
              ((symbol-function 'acp-send-request)
               (lambda (&rest args)
                 (setq sent-request args))))

      ;; First, verify that build-content-blocks actually throws an error
      (should-error (agent-shell--build-content-blocks "Test prompt")
                    :type 'error)

      ;; Now verify send-command handles the error gracefully
      (agent-shell--send-command
       :prompt "Test prompt with @file.txt"
       :shell nil)

      ;; Verify request was sent (fallback succeeded)
      (should sent-request)

      ;; Verify it fell back to plain text
      (let* ((request (plist-get sent-request :request))
             (params (map-elt request :params))
             (prompt (map-elt params 'prompt)))
        ;; Should still have a prompt
        (should prompt)
        ;; Should be a single text block with the original prompt
        (should (equal prompt '[((type . "text") (text . "Test prompt with @file.txt"))]))))))

(ert-deftest agent-shell--format-diff-as-text-test ()
  "Test `agent-shell--format-diff-as-text' function."
  ;; Test nil input
  (should (equal (agent-shell--format-diff-as-text nil) nil))

  ;; Test basic diff formatting
  (let* ((old-text "line 1\nline 2\nline 3\n")
         (new-text "line 1\nline 2 modified\nline 3\n")
         (diff-info `((:old . ,old-text)
                      (:new . ,new-text)
                      (:file . "test.txt")))
         (result (agent-shell--format-diff-as-text diff-info)))

    ;; Should return a string
    (should (stringp result))

    ;; Should NOT contain file header lines with timestamps (they should be stripped)
    (should-not (string-match-p "^---" result))
    (should-not (string-match-p "^\\+\\+\\+" result))

    ;; Should contain unified diff hunk headers
    (should (string-match-p "^@@" result))

    ;; Should contain the actual changes
    (should (string-match-p "^-line 2" result))
    (should (string-match-p "^\\+line 2 modified" result))

    ;; Should have syntax highlighting (text properties)
    (let ((has-diff-face nil))
      (dotimes (i (length result))
        (when (get-text-property i 'font-lock-face result)
          (setq has-diff-face t)))
      (should has-diff-face))))

(ert-deftest agent-shell--format-agent-capabilities-test ()
  "Test `agent-shell--format-agent-capabilities' function."
  ;; Test with multiple capabilities (includes comma)
  (let ((capabilities '((promptCapabilities (image . t) (audio . :false) (embeddedContext . t))
                        (mcpCapabilities (http . t) (sse . t)))))
    (should (equal (substring-no-properties
                    (agent-shell--format-agent-capabilities capabilities))
                   (string-trim"
prompt  image and embedded context
mcp     http and sse"))))

  ;; Test with single capability per category (no comma)
  (let ((capabilities '((promptCapabilities (image . t))
                        (mcpCapabilities (http . t)))))
    (should (equal (substring-no-properties
                    (agent-shell--format-agent-capabilities capabilities))
                   (string-trim "
prompt  image
mcp     http"))))

  ;; Test with top-level boolean capability (loadSession)
  (let ((capabilities '((loadSession . t)
                        (promptCapabilities (image . t) (embeddedContext . t)))))
    (should (equal (substring-no-properties
                    (agent-shell--format-agent-capabilities capabilities))
                   (string-trim "
load session
prompt        image and embedded context"))))

  ;; Test with all capabilities disabled (should return empty string)
  (let ((capabilities '((promptCapabilities (image . :false) (audio . :false)))))
    (should (equal (agent-shell--format-agent-capabilities capabilities) ""))))

(provide 'agent-shell-tests)
;;; agent-shell-tests.el ends here
