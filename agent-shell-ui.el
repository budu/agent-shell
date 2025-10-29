;;; agent-shell-ui.el --- Interactive shell UI elements -*- lexical-binding: t; -*-

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
;; A library for creating interactive shell UI elements.
;;
;; Note: This package is in very early stages and likely has
;; rough edges.
;;
;; Report issues at https://github.com/xenodium/agent-shell/issues
;;
;; ✨ Please support this work https://github.com/sponsors/xenodium ✨

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'cursor-sensor)
(require 'subr-x)
(require 'text-property-search)

(defvar-local agent-shell-ui--content-store nil
  "A hash table used to save sui content like body.
This avoids duplicating body content in text properties which is more costly.")

(cl-defun agent-shell-ui-make-dialog-block-model (&key (namespace-id "global") (block-id "1") label-left label-right body)
  "Create a dialog block model alist.
NAMESPACE-ID, BLOCK-ID, LABEL-LEFT, LABEL-RIGHT, and BODY are the keys."
  (list (cons :namespace-id namespace-id)
        (cons :block-id block-id)
        (cons :label-left (agent-shell-ui--string-or-nil label-left))
        (cons :label-right (agent-shell-ui--string-or-nil label-right))
        (cons :body (agent-shell-ui--string-or-nil body))))

(cl-defun agent-shell-ui-update-dialog-block (model &key append create-new on-post-process navigation expanded)
  "Update or add a dialog block using MODEL.

When APPEND is non-nil, append to body instead of replacing.
When CREATE-NEW is non-nil, create new block.
When ON-POST-PROCESS is non-nil, call this function after updating.
When NAVIGATION is `never', block won't be TAB navigatable.
When NAVIGATION is `auto', block is navigatable if non-empty body.
When NAVIGATION is `always', block is always TAB navigatable.
When EXPANDED is non-nil, body will be expanded by default.

For existing blocks, the current expansion state is preserved unless overridden."
  (save-mark-and-excursion
    (let* ((inhibit-read-only t)
           (namespace-id (map-elt model :namespace-id))
           (qualified-id (format "%s-%s" namespace-id (map-elt model :block-id)))
           (new-label-left (map-elt model :label-left))
           (new-label-right (map-elt model :label-right))
           (new-body (map-elt model :body))
           (block-start nil)
           (padding-start nil)
           (padding-end nil)
           (match (save-mark-and-excursion
                    (goto-char (point-max))
                    (text-property-search-backward
                     'agent-shell-ui-state nil
                     (lambda (_ state)
                       (equal (map-elt state :qualified-id) qualified-id))
                     t))))
      (when (or new-label-left new-label-right new-body)
        (when match
          (goto-char (prop-match-beginning match)))
        (if (and match (not create-new))
            ;; Found existing block - delete and regenerate
            (let* ((existing-model (agent-shell-ui--read-dialog-block-at-point))
                   (state (get-text-property (point) 'agent-shell-ui-state))
                   (existing-body (map-elt existing-model :body))
                   (block-end (prop-match-end match))
                   (final-body (if new-body
                                   (if (and append existing-body)
                                       (concat existing-body new-body)
                                     new-body)
                                 existing-body))
                   (final-model (list (cons :namespace-id namespace-id)
                                      (cons :block-id (map-elt model :block-id))
                                      (cons :label-left (or new-label-left
                                                            (map-elt existing-model :label-left)))
                                      (cons :label-right (or new-label-right
                                                             (map-elt existing-model :label-right)))
                                      (cons :body final-body))))
              (setq block-start (prop-match-beginning match))

              ;; Safely replace existing block using narrow-to-region
              (save-excursion
                (goto-char block-start)
                (skip-chars-backward "\n")
                (setq padding-start (point)))

              ;; Replace block
              (delete-region block-start block-end)
              (goto-char block-start)
              (agent-shell-ui--insert-dialog-block final-model qualified-id
                                        (not (map-elt state :collapsed))
                                        navigation)
              (setq padding-end (point)))

          ;; Not found or create-new - insert new block
          (goto-char (point-max))
          (setq padding-start (point))
          (insert (agent-shell-ui--required-newlines 2))
          (setq block-start (point))
          (agent-shell-ui--insert-dialog-block model qualified-id expanded navigation)
          (insert "\n\n")
          (setq padding-end (point))))
      (when on-post-process
        (funcall on-post-process))
      (when-let ((block-range (agent-shell-ui--block-range :position block-start)))
        (list (cons :block block-range)
              (cons :body (agent-shell-ui--nearest-range-matching-property
                           :property 'agent-shell-ui-section :value 'body
                           :from (map-elt block-range :start)
                           :to (map-elt block-range :end)))
              (cons :label-left (agent-shell-ui--nearest-range-matching-property
                                 :property 'agent-shell-ui-section :value 'label-left
                                 :from (map-elt block-range :start)
                                 :to (map-elt block-range :end)))
              (cons :label-right (agent-shell-ui--nearest-range-matching-property
                                  :property 'agent-shell-ui-section :value 'label-right
                                  :from (map-elt block-range :start)
                                  :to (map-elt block-range :end)))
              (cons :padding (when (and padding-start padding-end)
                               (list (cons :start padding-start)
                                     (cons :end padding-end)))))))))


(defun agent-shell-ui--read-dialog-block-at (position qualified-id)
  "Read dialog block at POSITION with QUALIFIED-ID."
  (when-let ((dialog (list (cons :block-id qualified-id)))
             (state (get-text-property position 'agent-shell-ui-state))
             (range (agent-shell-ui--block-range :position position)))
    ;; TODO: Get rid of merging block namespace and id.
    ;; Extract namespace-id from qualified-id if it contains a dash
    (when (string-match "^\\(.+\\)-\\(.+\\)$" qualified-id)
      (setf (map-elt dialog :namespace-id) (match-string 1 qualified-id))
      (setf (map-elt dialog :block-id) (match-string 2 qualified-id)))
    (save-mark-and-excursion
      (save-restriction
        (narrow-to-region (map-elt range :start)
                          (map-elt range :end))
        (goto-char (map-elt range :start))
        (setf (map-elt dialog :collapsed) (map-elt state :collapsed))
        (when-let ((label-left (agent-shell-ui--nearest-range-matching-property
                                :property 'agent-shell-ui-section :value 'label-left)))
          (setf (map-elt dialog :label-left) (buffer-substring (map-elt label-left :start)
                                                               (map-elt label-left :end))))
        (when-let ((label-right (agent-shell-ui--nearest-range-matching-property
                                 :property 'agent-shell-ui-section :value 'label-right)))
          (setf (map-elt dialog :label-right) (buffer-substring (map-elt label-right :start)
                                                                (map-elt label-right :end))))
        (when agent-shell-ui--content-store
          (when-let ((body (gethash (concat qualified-id "-body") agent-shell-ui--content-store)))
            (setf (map-elt dialog :body) body)))))
    dialog))

(cl-defun agent-shell-ui-delete-dialog-block (&key namespace-id block-id)
  "Delete dialog block with NAMESPACE-ID and BLOCK-ID."
  (save-mark-and-excursion
    (let* ((inhibit-read-only t)
           (qualified-id (format "%s-%s" namespace-id block-id))
           (match (save-mark-and-excursion
                    (goto-char (point-max))
                    (text-property-search-backward
                     'agent-shell-ui-state nil
                     (lambda (_ state)
                       (equal (map-elt state :qualified-id) qualified-id))
                     t))))
      (when match
        (let ((block-start (prop-match-beginning match))
              (block-end (prop-match-end match)))
          (when agent-shell-ui--content-store
            (remhash qualified-id agent-shell-ui--content-store))
          ;; Remove vertical space that's part of the block.
          (goto-char block-end)
          (skip-chars-forward " \t\n")
          (setq block-end (point))
          (delete-region block-start block-end))))))

(defun agent-shell-ui--read-dialog-block-at-point ()
  "Read dialog block at point, returning model or nil if none found."
  (when-let ((state (get-text-property (point) 'agent-shell-ui-state))
             (range (agent-shell-ui--block-range :position (point))))
    (agent-shell-ui--read-dialog-block-at (map-elt range :start)
                               (map-elt state :qualified-id))))

(cl-defun agent-shell-ui--block-range (&key position)
  "Get block range at POSITION if found.  Nil otherwise.

In the form:

  ((start . 1)
   (end . 3))."
  (when-let ((qualified-id (map-elt (get-text-property (or position (point)) 'agent-shell-ui-state) :qualified-id)))
    (agent-shell-ui--nearest-range-matching-property
     :property 'agent-shell-ui-state
     :value qualified-id
     :predicate (lambda (qualified-id property)
                  (equal (map-elt property :qualified-id) qualified-id)))))

(cl-defun agent-shell-ui--nearest-range-matching-property (&key property value (predicate t) from to)
  "Return nearest range where PREDICATE is non-nil for PROPERTY and VALUE."
  (save-mark-and-excursion
    (save-restriction
      (when (and from to)
        (narrow-to-region from to))
      (let ((backward-match (or (text-property-search-backward property value predicate)
                                (progn
                                  (unless (eobp)
                                    (forward-char 1))
                                  (text-property-search-backward property value predicate))))
            (forward-match (text-property-search-forward property value predicate)))
        (when (or backward-match forward-match)
          `((:start . ,(if backward-match
                           (prop-match-beginning backward-match)
                         (prop-match-beginning forward-match)))
            (:end . ,(if forward-match
                         (prop-match-end forward-match)
                       (prop-match-end backward-match)))))))))

(defun agent-shell-ui--insert-dialog-block (model qualified-id &optional expanded navigation)
  "Insert dialog block from MODEL with QUALIFIED-ID text properties.
EXPANDED determines initial state (default nil for collapsed).
NAVIGATION controls navigability:

 `never' (not navigatable)
 `auto' (navigatable if body and indicator present)
 `always' (always navigatable)."
  (let ((block-start (point))
        (label-left (map-elt model :label-left))
        (label-right (map-elt model :label-right))
        (body (map-elt model :body))
        (need-space nil)
        (indicator-start)
        (indicator-end)
        (label-left-start)
        (label-left-end)
        (label-right-start)
        (label-right-end)
        (body-start)
        (body-end)
        (collapsable))

    ;; Insert collapse indicator if body exists
    (when-let ((has-labels (or label-left label-right)))
      (if body
          (progn
            (setq collapsable has-labels)
            (setq indicator-start (point))
            (insert (agent-shell-ui-add-action-to-text
                     (if expanded "▼ " "▶ ")
                     (lambda ()
                       (interactive)
                       (agent-shell-ui-toggle-dialog-block-at-point))
                     (lambda ()
                       (message "Press RET to toggle"))))
            (setq indicator-end (point))
            (add-text-properties indicator-start indicator-end
                                 `(agent-shell-ui-section indicator
                                               keymap ,(agent-shell-ui-make-action-keymap
                                                        (lambda ()
                                                          (interactive)
                                                          (agent-shell-ui-toggle-dialog-block-at-point)))
                                               read-only t
                                               front-sticky (read-only))))
        (setq collapsable nil)
        (setq indicator-start (point))
        ;; Reserving the space for expand indicators enables
        ;; aligning columns but also avoids text jumping when
        ;; body arrives later on.
        ;;
        ;; For example:
        ;;
        ;; "   [ completed ] [ read ] Read agent-shell/README.org"
        ;;
        ;; vs
        ;;
        ;; "▼  [ completed ] [ read ] Read agent-shell/README.org"
        (insert "  ") ;; "▶ "
        (setq indicator-end (point))))

    (when label-left
      (setq label-left-start (point))
      (insert (agent-shell-ui-add-action-to-text
               label-left
               (lambda ()
                 (interactive)
                 (agent-shell-ui-toggle-dialog-block-at-point))
               (lambda ()
                 (message "Press RET to toggle"))))
      (setq label-left-end (point))
      (add-text-properties label-left-start label-left-end
                           `(agent-shell-ui-section label-left
                                         help-echo ,qualified-id
                                         read-only t
                                         front-sticky (read-only)))
      (setq need-space t))

    (when label-right
      (when need-space
        (insert " "))
      (setq label-right-start (point))
      (insert (agent-shell-ui-add-action-to-text
               label-right
               (lambda ()
                 (interactive)
                 (agent-shell-ui-toggle-dialog-block-at-point))
               (lambda ()
                 (message "Press RET to toggle"))))
      (setq label-right-end (point))
      (add-text-properties label-right-start label-right-end
                           `(agent-shell-ui-section label-right
                                         help-echo ,qualified-id
                                         read-only t
                                         front-sticky (read-only))))

    (when body
      (when (or label-left label-right)
        (insert "\n\n"))
      ;; Never leave more than two trailing newlines.
      (when (string-suffix-p "\n\n" body)
        (setq body (concat (string-trim-right body) "\n\n")))
      (setq body-start (point))
      (let ((clean-body (string-remove-prefix "  " body)))
        (insert (agent-shell-ui--indent-text clean-body "  ")))
      (setq body-end (point))
      (add-text-properties body-start body-end
                           `(agent-shell-ui-section body
                                         help-echo ,qualified-id
                                         read-only t
                                         front-sticky (read-only))))
    (when-let ((is-collapsable collapsable)
               (body-overlay (make-overlay (or label-right-end
                                               label-left-end) body-end)))
      (overlay-put body-overlay 'evaporate t)
      (overlay-put body-overlay 'agent-shell-ui-section 'body)
      (overlay-put body-overlay 'invisible (not expanded)))
    ;; Hide trailing whitespace (don't delete) in body.
    (when body
      (save-mark-and-excursion
        (goto-char body-end)
        (when (re-search-backward "[^ \t\n]" body-start t)
          (forward-char 1)
          (when (< (point) body-end)
            (let ((ws-overlay (make-overlay (point) body-end)))
              (overlay-put ws-overlay 'invisible t)
              (overlay-put ws-overlay 'evaporate t)
              (overlay-put ws-overlay 'agent-shell-ui-section 'trailing-whitespace))))))
    (when body
      (unless agent-shell-ui--content-store
        (setq agent-shell-ui--content-store (make-hash-table :test 'equal)))
      (puthash (concat qualified-id "-body") body agent-shell-ui--content-store))
    (put-text-property
     block-start (or body-end label-right-end label-left-end)
     'agent-shell-ui-state (list
                 ;; Note: Avoid storing chunky data in
                 ;; agent-shell-ui-state as it will impact performance.
                 ;; Use agent-shell-ui--content-store for these instances.
                 ;; For example, dialog body.
                 (cons :qualified-id qualified-id)
                 (cons :collapsed (not expanded))
                 (cons :navigatable (cond
                                     ((eq navigation 'never) nil)
                                     ((eq navigation 'always) t)
                                     ((eq navigation 'auto)
                                      (and body indicator-start))
                                     (t
                                      ;; Default to auto
                                      (and body indicator-start))))))
    (put-text-property block-start (or body-end label-right-end label-left-end) 'read-only t)
    (put-text-property block-start (or body-end label-right-end label-left-end) 'front-sticky '(read-only))))

(defun agent-shell-ui--required-newlines (desired)
  "Return string of newlines needed to reach DESIRED before POSITION."
  (let ((context (save-mark-and-excursion
                   (let ((end (point)))
                     (forward-line (- (+ 1 desired)))
                     (buffer-substring (point) end)))))
    (with-temp-buffer
      (insert context)
      ;; When counting visible newlines before point,
      ;; we may encounter invisible text, which may
      ;; look like newlines but gives false negatives.
      ;; In those cases, delete any 'invisible text
      ;; and try counting.
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (while (not (bobp))
          (let* ((end (point))
                 (start (previous-single-property-change end 'invisible nil (point-min))))
            (if (get-text-property (1- end) 'invisible)
                (delete-region start end))
            (goto-char start))))
      (goto-char (point-max))
      (let ((pos (point)))
        (skip-chars-backward "\n")
        (make-string (max 0 (- desired (- pos (point)))) ?\n)))))

(defun agent-shell-ui-toggle-dialog-block-at-point ()
  "Toggle visibility of dialog block body at point."
  (interactive)
  (save-mark-and-excursion
    (when-let* ((inhibit-read-only t)
                (buffer-undo-list t)
                (state (get-text-property (point) 'agent-shell-ui-state))
                (block (agent-shell-ui--block-range :position (point)))
                (body (agent-shell-ui--nearest-range-matching-property
                       :property 'agent-shell-ui-section :value 'body
                       :from (map-elt block :start)
                       :to (map-elt block :end)))
                (indicator (agent-shell-ui--nearest-range-matching-property
                            :property 'agent-shell-ui-section :value 'indicator
                            :from (map-elt block :start)
                            :to (map-elt block :end)))
                (body-overlay (seq-first (overlays-in (map-elt body :start)
                                                      (map-elt body :end))))
                (overlay-found (equal (overlay-get body-overlay 'agent-shell-ui-section) 'body)))
      (when (equal (overlay-get body-overlay 'agent-shell-ui-section) 'body)
        (let ((indicator-properties (text-properties-at (map-elt indicator :start))))
          (overlay-put body-overlay 'invisible (not (map-elt state :collapsed)))
          (delete-region (map-elt indicator :start)
                         (map-elt indicator :end))
          (goto-char (map-elt indicator :start))
          (insert (if (map-elt state :collapsed)
                      "▼ "
                    "▶ "))
          (add-text-properties (map-elt indicator :start)
                               (map-elt indicator :end)
                               indicator-properties)
          (map-put! state :collapsed (not (map-elt state :collapsed))))
        (put-text-property (map-elt block :start)
                           (map-elt block :end) 'agent-shell-ui-state state)))))

(defun agent-shell-ui-collapse-dialog-block-by-id (namespace-id block-id)
  "Collapse dialog block with NAMESPACE-ID and BLOCK-ID."
  (save-mark-and-excursion
    (let ((qualified-id (format "%s-%s" namespace-id block-id)))
      (goto-char (point-max))
      (when (text-property-search-backward
             'agent-shell-ui-state qualified-id
             (lambda (_ state)
               (equal (map-elt state :qualified-id) qualified-id))
             t)
        (agent-shell-ui-toggle-dialog-block-at-point)))))

(defun agent-shell-ui--string-or-nil (str)
  "Return STR if it is not nil and not empty, otherwise nil."
  (and str (not (string-empty-p str)) str))

(defun agent-shell-ui--indent-text (text &optional indent-string)
  "Indent TEXT by adding INDENT-STRING to the beginning of each non-empty line.
INDENT-STRING defaults to two spaces."
  (when text
    (let ((indent (or indent-string "  ")))
      (mapconcat (lambda (line)
                   (if (string-empty-p line)
                       line
                     (concat indent line)))
                 (split-string text "\n")
                 "\n"))))

(defun agent-shell-ui-forward-block ()
  "Jump to the next block."
  (interactive)
  (when-let* ((start-point (point))
              (found (save-mark-and-excursion
                       ;; In navigatable block already
                       ;; move past it.
                       (when-let ((state (get-text-property (point) 'agent-shell-ui-state))
                                  (block (agent-shell-ui--block-range :position (point))))
                         (goto-char (map-elt block :end)))
                       (when-let ((next (text-property-search-forward
                                         'agent-shell-ui-state nil
                                         (lambda (_old-val new-val)
                                           (and new-val (map-elt new-val :navigatable)))
                                         t)))
                         (prop-match-beginning next)))))
    (when found
      (deactivate-mark)
      (goto-char found)
      found)))

(defun agent-shell-ui-backward-block ()
  "Jump to the previous block."
  (interactive)
  (when-let* ((start-point (point))
              (found (save-mark-and-excursion
                       ;; In navigatable block already
                       ;; move to beginning.
                       (when-let ((state (get-text-property (point) 'agent-shell-ui-state))
                                  (block (agent-shell-ui--block-range :position (point))))
                         (goto-char (map-elt block :start)))
                       (when-let ((prev (text-property-search-backward
                                         'agent-shell-ui-state nil
                                         (lambda (_old-val new-val)
                                           (and new-val (map-elt new-val :navigatable)))
                                         t)))
                         (prop-match-beginning prev)))))
    (when found
      (deactivate-mark)
      (goto-char found)
      found)))

(defun agent-shell-ui-make-action-keymap (action)
  "Create keymap with ACTION."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] action)
    (define-key map (kbd "RET") action)
    (define-key map [remap self-insert-command] 'ignore)
    map))

(defun agent-shell-ui-add-action-to-text (text action &optional on-entered face)
  "Add ACTION lambda to propertized TEXT and return modified text.
ON-ENTERED is a function to call when the cursor enters the text.
FACE when non-nil applies the specified face to the text."
  (add-text-properties 0 (length text)
                       `(keymap ,(agent-shell-ui-make-action-keymap action))
                       text)
  (when on-entered
    (add-text-properties 0 (length text)
                         (list 'cursor-sensor-functions
                               (list (lambda (_window _old-pos sensor-action)
                                       (when (eq sensor-action 'entered)
                                         (funcall on-entered)))))
                         text))
  (when face
    (add-text-properties 0 (length text)
                         `(font-lock-face ,face)
                         text)
    (add-text-properties 0 (length text)
                         `(face ,face)
                         text))
  text)

(defvar agent-shell-ui-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `agent-shell-ui-mode'.")

;;;###autoload
(define-minor-mode agent-shell-ui-mode
  "Minor mode for SUI block navigation."
  :lighter " SUI"
  :keymap agent-shell-ui-mode-map
  (if agent-shell-ui-mode
      (cursor-sensor-mode 1)
    (cursor-sensor-mode -1)))

(provide 'agent-shell-ui)

;;; agent-shell-ui.el ends here
