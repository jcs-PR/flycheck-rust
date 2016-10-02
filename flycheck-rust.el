;;; flycheck-rust.el --- Flycheck: Rust additions and Cargo support  -*- lexical-binding: t; -*-

;; Copyright (C) 2014, 2015  Sebastian Wiesner <swiesner@lunaryorn.com>

;; Author: Sebastian Wiesner <swiesner@lunaryorn.com>
;; URL: https://github.com/flycheck/flycheck-rust
;; Keywords: tools, convenience
;; Version: 0.1-cvs
;; Package-Requires: ((emacs "24.1") (flycheck "0.20") (dash "2.13.0") (seq "2.15"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This Flycheck extension configures Flycheck automatically for the current
;; Cargo project.
;;
;; # Setup
;;
;;     (add-hook 'flycheck-mode-hook #'flycheck-rust-setup)
;;
;; # Usage
;;
;; Just use Flycheck as usual in your Rust/Cargo projects.
;;
;; Note: You must run `cargo build` initially to install all dependencies.  If
;; you add new dependencies to `Cargo.toml` you need to run `cargo build`
;; again. Otherwise you will see spurious errors about missing crates.
;;
;; This extension also provides a convenience function for looking up
;; explanations of the compiler error under point
;; (`flycheck-rust-explain-error') that is not bound by default.

;;; Code:

(require 'dash)
(require 'flycheck)
(require 'seq)
(require 'json)

(defun flycheck-rust-executable-p (rel-name)
  "Whether REL-NAME denotes an executable.

REL-NAME is the file relative to the Cargo.toml file."
  (or (string= "src/main.rs" rel-name)
      (string-prefix-p "src/bin/" rel-name)))

(defun flycheck-rust-test-p (rel-name)
  "Whether REL-NAME denotes a test.

REL-NAME is the file relative to the Cargo.toml file."
  (string-prefix-p "tests/" rel-name))

(defun flycheck-rust-bench-p (rel-name)
  "Whether REL-NAME denotes a bench.

REL-NAME is the file relative to the Cargo.toml file."
  (string-prefix-p "benches/" rel-name))

(defun flycheck-rust-example-p (rel-name)
  "Whether REL-NAME denotes an example.

REL-NAME is the file relative to the Cargo.toml file."
  (string-prefix-p "examples/" rel-name))

(defun flycheck-rust-project-root ()
  "Get the project root for the current buffer.

Return the directory containing the Cargo file, or nil if there
is none."
  (locate-dominating-file (buffer-file-name) "Cargo.toml"))

(defun flycheck-rust-find-crate-root ()
  "Get the crate root (the nearest lib.rs or main.rs)
relative to the current file."
  (-if-let (lib-crate-dir (locate-dominating-file (buffer-file-name) "lib.rs"))
      (expand-file-name "lib.rs" lib-crate-dir)
    (-when-let (exe-crate-dir (locate-dominating-file (buffer-file-name) "main.rs"))
      (expand-file-name "main.rs" exe-crate-dir))))

(defun flycheck-rust-binary-crate-p (project-root)
  "Determine whether PROJECT-ROOT is a binary crate.

PROJECT-ROOT is the path to the root directory of the project.

Return non-nil if PROJECT-ROOT is a binary crate, nil otherwise."
  (let ((root-dir (file-name-directory project-root)))
    (file-exists-p (expand-file-name "src/main.rs" root-dir))))

(defun flycheck-rust-find-target (file-name)
  "Find and return the cargo target associated with the given file.

FILE-NAME is the name of the file that is matched against the
`src_path' value in the list `targets' returned by `cargo
read-manifest'.  If there is no match, the first target is
returned by default.

Return a cons cell (TYPE . NAME), where TYPE is the target
type (lib or bin), and NAME the target name (usually, the crate
name)."
  (let ((json-array-type 'list))
    (-let [(&alist 'targets targets)
           (with-temp-buffer
             (call-process (funcall flycheck-executable-find "cargo") nil t nil "read-manifest")
             (goto-char (point-min))
             (json-read))]
      ;; If there is a target that matches the file-name exactly, pick that
      ;; one.  Otherwise, just pick the first target.
      (-let [(&alist 'kind (kind) 'name name)
             (seq-find (lambda (target)
                         (-let [(&alist 'src_path src_path) target]
                           (string= file-name src_path)))
                       targets (car targets))]
          (cons kind name)))))

;;;###autoload
(defun flycheck-rust-setup ()
  "Setup Rust in Flycheck.

If the current file is part of a Cargo project, configure
Flycheck according to the Cargo project layout."
  (interactive)
  (when (buffer-file-name)
    (-when-let (root (flycheck-rust-project-root))
      (pcase-let ((rel-name (file-relative-name (buffer-file-name) root))
                  (`(,target-type . ,target-name) (flycheck-rust-find-target
                                                     (buffer-file-name))))
        ;; These are valid crate roots as by Cargo's layout
        (if (or (flycheck-rust-executable-p rel-name)
                (flycheck-rust-test-p rel-name)
                (flycheck-rust-bench-p rel-name)
                (flycheck-rust-example-p rel-name)
                (string= "src/lib.rs" rel-name))
            (setq-local flycheck-rust-crate-root rel-name)
          ;; For other files, the library is either the default library or the
          ;; executable
          (setq-local flycheck-rust-crate-root (flycheck-rust-find-crate-root)))
        ;; Check tests in libraries and integration tests
        (setq-local flycheck-rust-check-tests
                    (not (flycheck-rust-executable-p rel-name)))
        ;; Set the crate type
        (setq-local flycheck-rust-crate-type
                    (if (string= target-type "bin")
                        (progn
                          ;; If it's binary target, we need to pass the binary
                          ;; name
                          (setq-local flycheck-rust-binary-name target-name)
                          "bin")
                      "lib"))
        ;; Find build libraries
        (setq-local flycheck-rust-library-path
                    (list (expand-file-name "target/debug" root)
                          (expand-file-name "target/debug/deps" root)))))))

;;;###autoload
(defun flycheck-rust-explain-error (error-code)
  "Explain ERROR-CODE by invoking `rustc --explain'.

ERROR-CODE defaults to the code of the error under point."
  (interactive
   (list (let ((errors-at-point (flycheck-overlay-errors-at (point))))
           (and errors-at-point (flycheck-error-id (car errors-at-point))))))
  (when error-code
    (with-help-window (get-buffer-create "*rustc-explain*")
      (with-current-buffer standard-output
        (call-process "rustc" nil t nil "--explain" error-code)))))

(provide 'flycheck-rust)

;;; flycheck-rust.el ends here
