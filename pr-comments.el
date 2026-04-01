;;; pr-comments.el --- Browse unresolved GitHub PR review threads via xref -*- lexical-binding: t -*-

;; Author: Roman Kashitsyn <roman.kashitsyn@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, vc

;;; Commentary:
;; Lists all unresolved GitHub PR review threads in the standard *pr-comments* buffer.
;; Threads with replies appear with a [replied] indicator.
;; Requires the `gh' CLI to be authenticated.
;;
;; Usage: M-x pr-comments

;;; Code:

(require 'xref)
(require 'cl-lib)
(require 'json)
(require 'wid-edit)

;;;; Customization

(defgroup pr-comments nil
  "Browse unresolved GitHub PR review threads via xref."
  :group 'tools
  :prefix "pr-comments-")

(defcustom pr-comments-gh-executable "gh"
  "Path to the gh CLI executable."
  :type 'string
  :group 'pr-comments)

;;;; Internal state

(defvar pr-comments--thread-cache (make-hash-table :test 'equal)
  "Hash table mapping \"ABSFILE:LINE\" to thread alists.
Populated by `pr-comments--build-xref-items' and cleared on each
`pr-comments' invocation.")

(defvar pr-comments--current-pr nil
  "Plist (:owner OWNER :repo REPO :number NUMBER) for the current PR.")

(defvar pr-comments--last-git-root nil
  "Git root used by the most recent `pr-comments' invocation.
Used by `pr-comments-refresh' to re-run from the xref buffer.")

;;;; GraphQL query

(defconst pr-comments--graphql-query
  "query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){\
repository(owner:$owner,name:$repo){\
pullRequest(number:$pr){\
reviewThreads(first:100,after:$cursor){\
pageInfo{hasNextPage endCursor}\
nodes{\
isResolved path line originalLine \
comments(first:100){\
nodes{author{login}body url}\
}\
}\
}\
}\
}\
}"
  "GraphQL query to fetch PR review threads.")

;;;; Phase 1 — Core infrastructure

(defun pr-comments--git-root ()
  "Return the absolute path to the git root directory.
Signal `user-error' if not inside a git repository."
  (let ((root (or (and (fboundp 'vc-root-dir) (vc-root-dir))
                  (locate-dominating-file
                   (or (buffer-file-name) default-directory)
                   ".git"))))
    (unless root
      (user-error "pr-comments: Not inside a git repository"))
    (file-name-as-directory (expand-file-name root))))

(defun pr-comments--run-gh (git-root &rest args)
  "Run `pr-comments-gh-executable' with ARGS in GIT-ROOT.
Return stdout as a string on success.
Signal `user-error' with stderr content on non-zero exit."
  (let ((stdout-buf  (generate-new-buffer " *pr-comments-stdout*"))
        (stderr-file (make-temp-file "pr-comments-stderr")))
    (unwind-protect
        (let* ((default-directory git-root)
               (exit-code (apply #'call-process
                                 pr-comments-gh-executable
                                 nil
                                 (list stdout-buf stderr-file)
                                 nil
                                 args)))
          (if (zerop exit-code)
              (with-current-buffer stdout-buf (buffer-string))
            (let ((err (with-temp-buffer
                         (insert-file-contents stderr-file)
                         (buffer-string))))
              (user-error "pr-comments: gh error: %s"
                          (string-trim err)))))
      (kill-buffer stdout-buf)
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

;;;; Phase 2 — PR detection

(defun pr-comments--detect-pr (git-root)
  "Detect the PR for the current branch in GIT-ROOT.
Return a plist (:owner OWNER :repo REPO :number NUMBER).
Signal `user-error' if no PR exists for the current branch."
  (let* ((json-str (pr-comments--run-gh git-root "pr" "view" "--json" "url,number"))
         (data (with-temp-buffer
                 (insert json-str)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
         (number (alist-get 'number data))
         (url    (alist-get 'url data)))
    (unless (and number url)
      (user-error "pr-comments: Could not parse PR info from gh output"))
    (unless (string-match
             "https://github\\.com/\\([^/]+\\)/\\([^/]+\\)/pull/"
             url)
      (user-error "pr-comments: Unexpected PR URL format: %s" url))
    (list :owner  (match-string 1 url)
          :repo   (match-string 2 url)
          :number number)))

;;;; Phase 3 — GitHub GraphQL API

(defun pr-comments--fetch-threads-page (git-root owner repo pr-number cursor)
  "Fetch one page of review threads for PR-NUMBER in OWNER/REPO.
CURSOR is the pagination cursor string, or nil for the first page.
Return the reviewThreads alist from the response."
  (let* ((args (list "api" "graphql"
                     "-f" (format "owner=%s" owner)
                     "-f" (format "repo=%s" repo)
                     "-F" (format "pr=%d" pr-number)
                     "-f" (format "query=%s" pr-comments--graphql-query)))
         (args (if cursor
                   (append args (list "-f" (format "cursor=%s" cursor)))
                 args))
         (json-str (apply #'pr-comments--run-gh git-root args))
         (data (with-temp-buffer
                 (insert json-str)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil))))
    (alist-get 'reviewThreads
               (alist-get 'pullRequest
                          (alist-get 'repository
                                     (alist-get 'data data))))))

(defun pr-comments--fetch-all-threads (git-root owner repo pr-number)
  "Fetch all review thread nodes for PR-NUMBER in OWNER/REPO.
Handles pagination automatically. Return a flat list of thread alists."
  (let ((cursor nil)
        (all-nodes '())
        (has-next t))
    (while has-next
      (let* ((threads  (pr-comments--fetch-threads-page
                        git-root owner repo pr-number cursor))
             (page-info (alist-get 'pageInfo threads))
             (nodes     (alist-get 'nodes threads)))
        (setq all-nodes (append all-nodes nodes))
        (setq has-next (alist-get 'hasNextPage page-info))
        (setq cursor   (alist-get 'endCursor page-info))))
    all-nodes))

;;;; Phase 4 — Data transformation

(defun pr-comments--thread-line (thread)
  "Return the line number for THREAD, preferring `line' over `originalLine'."
  (or (alist-get 'line thread)
      (alist-get 'originalLine thread)))

(defun pr-comments--answered-p (thread)
  "Return t if THREAD has more than one comment (i.e. someone replied)."
  (> (length (alist-get 'nodes (alist-get 'comments thread))) 1))

(defun pr-comments--format-summary (thread)
  "Format a one-line summary string for THREAD."
  (let* ((comments    (alist-get 'nodes (alist-get 'comments thread)))
         (first       (car comments))
         (author      (or (alist-get 'login (alist-get 'author first))
                          "unknown"))
         (raw-body    (or (alist-get 'body first) ""))
         (body        (replace-regexp-in-string "[\n\r]+" " " raw-body))
         (body        (if (> (length body) 80)
                          (concat (substring body 0 80) "...")
                        body))
         (prefix      (if (pr-comments--answered-p thread) "[replied] " "")))
    (format "%s%s: %s" prefix author body)))

(defun pr-comments--thread-to-xref (thread git-root)
  "Convert THREAD to an xref item rooted at GIT-ROOT.
Return nil if the thread has no usable line number."
  (let ((line (pr-comments--thread-line thread)))
    (when line
      (let* ((rel-path (alist-get 'path thread))
             (abs-file (expand-file-name rel-path git-root))
             (summary  (pr-comments--format-summary thread)))
        (xref-make summary (xref-make-file-location abs-file line 0))))))

(defun pr-comments--build-xref-items (threads git-root)
  "Build a sorted list of xref items from THREADS.
Also populate `pr-comments--thread-cache' keyed by \"ABSFILE:LINE\".
Skips resolved threads and threads without a usable line number."
  (clrhash pr-comments--thread-cache)
  (let* ((unresolved (cl-remove-if (lambda (th) (alist-get 'isResolved th))
                                   threads))
         (items-and-threads
          (delq nil
                (mapcar (lambda (th)
                          (let ((item (pr-comments--thread-to-xref th git-root)))
                            (when item
                              (let* ((loc  (xref-item-location item))
                                     (file (xref-file-location-file loc))
                                     (line (xref-file-location-line loc))
                                     (key  (format "%s:%d" file line)))
                                (puthash key th pr-comments--thread-cache))
                              item)))
                        unresolved))))
    (sort items-and-threads
          (lambda (a b)
            (let* ((la (xref-item-location a))
                   (lb (xref-item-location b))
                   (fa (xref-file-location-file la))
                   (fb (xref-file-location-file lb)))
              (if (string= fa fb)
                  (< (xref-file-location-line la)
                     (xref-file-location-line lb))
                (string< fa fb)))))))

;;;; Full comment body feature

(defun pr-comments--insert-body (thread pr-info)
  "Insert THREAD content with clickable links into the current buffer.
PR-INFO is a plist (:owner OWNER :repo REPO :number NUMBER)."
  (let* ((comments  (alist-get 'nodes (alist-get 'comments thread)))
         (path      (alist-get 'path thread))
         (line      (pr-comments--thread-line thread))
         (owner     (plist-get pr-info :owner))
         (repo      (plist-get pr-info :repo))
         (number    (plist-get pr-info :number))
         (separator (make-string 60 ?─)))
    (insert (format "%s\n" separator))
    (insert (format "File: %s  Line: %s\n" path (or line "?")))
    (insert (format "PR:   %s/%s#%s\n" owner repo number))
    (insert (format "%s\n\n" separator))
    (dolist (comment comments)
      (let* ((author (or (alist-get 'login (alist-get 'author comment))
                         "unknown"))
             (body   (or (alist-get 'body comment) ""))
             (url    (alist-get 'url comment))
             (indented (replace-regexp-in-string
                        "^" "  "
                        (with-temp-buffer
                          (insert body)
                          (let ((fill-column 72))
                            (fill-region (point-min) (point-max)))
                          (buffer-string)))))
        (insert (format "%s:\n%s\n" author indented))
        (when url
          (insert "  ")
          (widget-create 'link
                         :notify (lambda (&rest _) (browse-url url))
                         :help-echo url
                         "View on GitHub")
          (insert "\n"))
        (insert "\n")))
    (insert (format "%s\nPress q to close\n" separator))))

(defun pr-comments--thread-for-key (file line)
  "Return the cached thread for FILE at LINE, or nil."
  (gethash (format "%s:%d" file line) pr-comments--thread-cache))

(defun pr-comments--thread-at-point ()
  "Return the thread alist for the current navigation position, or nil.
Tries the xref buffer item first (works when *pr-comments* is focused), then
falls back to the current buffer's file and line (works after next-error
navigates to a source file)."
  (or
   ;; Case 1: point is on an xref item in the *pr-comments* buffer
   (when-let* ((xref-buf (get-buffer "*pr-comments*"))
               (item     (with-current-buffer xref-buf
                           (ignore-errors (xref--item-at-point))))
               (loc      (xref-item-location item)))
     (pr-comments--thread-for-key (xref-file-location-file loc)
                                  (xref-file-location-line loc)))
   ;; Case 2: current buffer is the source file (e.g. after next-error)
   (when-let* ((file (buffer-file-name))
               (line (line-number-at-pos nil t)))
     (pr-comments--thread-for-key file line))))

(defun pr-comments--display-thread (thread)
  "Render THREAD into the `*PR Comment*' buffer and ensure it is visible."
  (let ((buf (get-buffer-create "*PR Comment*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (remove-overlays)
        (pr-comments--insert-body thread pr-comments--current-pr))
      (widget-setup)
      (setq buffer-read-only t)
      (goto-char (point-min))
      (local-set-key (kbd "q") #'quit-window))
    (display-buffer buf
                    '(display-buffer-in-side-window
                      (side . bottom)
                      (window-height . 0.35)))))

(defun pr-comments--show-body-at-point ()
  "Show the full comment thread for the xref item at point.
Displays a `*PR Comment*' buffer in a side window."
  (interactive)
  (if-let ((thread (pr-comments--thread-at-point)))
      (pr-comments--display-thread thread)
    (message "pr-comments: No comment data at point")))

(defun pr-comments--auto-update-comment ()
  "Update `*PR Comment*' buffer when it is visible and point is on an xref item.
Intended as a buffer-local entry in `post-command-hook' for `*pr-comments*'."
  (when (get-buffer-window "*PR Comment*")
    (when-let ((thread (pr-comments--thread-at-point)))
      (pr-comments--display-thread thread))))

;;;; Phase 5 — Entry point

(defun pr-comments--fetch-and-display (git-root)
  "Fetch PR review threads for GIT-ROOT and display them in the *pr-comments* buffer."
  (message "pr-comments: Detecting PR...")
  (let* ((pr-info (pr-comments--detect-pr git-root))
         (owner   (plist-get pr-info :owner))
         (repo    (plist-get pr-info :repo))
         (number  (plist-get pr-info :number)))
    (setq pr-comments--current-pr  pr-info
          pr-comments--last-git-root git-root)
    (message "pr-comments: Fetching threads for %s/%s#%s..." owner repo number)
    (let* ((threads (pr-comments--fetch-all-threads git-root owner repo number))
           (items   (pr-comments--build-xref-items threads git-root))
           (n       (length items))
           (replied (cl-count-if
                     (lambda (item)
                       (let* ((loc (xref-item-location item))
                              (key (format "%s:%d"
                                           (xref-file-location-file loc)
                                           (xref-file-location-line loc))))
                         (when-let ((th (gethash key pr-comments--thread-cache)))
                           (pr-comments--answered-p th))))
                     items)))
      (if (zerop n)
          (message "pr-comments: No unresolved review threads.")
        (message "pr-comments: Found %d unresolved thread(s) (%d replied)."
                 n replied)
        (let ((xref-buffer-name "*pr-comments*"))
          (xref-show-xrefs (lambda () items) nil))
        (run-at-time 0 nil
                     (lambda ()
                       (add-hook 'next-error-hook #'pr-comments--auto-update-comment)
                       (when-let ((buf (get-buffer "*pr-comments*")))
                         (with-current-buffer buf
                           (local-set-key (kbd "g")   #'pr-comments-refresh)
                           (local-set-key (kbd "SPC") #'pr-comments--show-body-at-point)
                           (add-hook 'post-command-hook
                                     #'pr-comments--auto-update-comment
                                     nil t)
                           (add-hook 'kill-buffer-hook
                                     (lambda ()
                                       (remove-hook 'next-error-hook
                                                    #'pr-comments--auto-update-comment))
                                     nil t)))))))))

(defun pr-comments-refresh ()
  "Re-fetch PR review threads and refresh the *pr-comments* buffer."
  (interactive)
  (unless pr-comments--last-git-root
    (user-error "pr-comments: No previous run to refresh"))
  (pr-comments--fetch-and-display pr-comments--last-git-root))

;;;###autoload
(defun pr-comments ()
  "List unresolved GitHub PR review threads in the *pr-comments* buffer.
Threads with replies are shown with a [replied] prefix.
Press RET or click to jump to the file and line of a comment.
Press g to refresh.
Press SPC to view the full comment thread in a side window."
  (interactive)
  (pr-comments--fetch-and-display (pr-comments--git-root)))

(provide 'pr-comments)
;;; pr-comments.el ends here
