;;; projection-multi-cmake.el --- Projection integration for `compile-multi' and the CMake project type. -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Mohsin Kaleem

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library exposes a target generation function for `compile-multi' which
;; sources the list of available targets from a CMake projects build config.
;;
;; This functionality is supported by parsing the set of available targets
;; from the output of the help target (this assumes the project has already
;; passed the configure stage). If invoked prior to this target resolution
;; will return no targets.

;;; Code:

(require 'projection-utils)
(require 'projection-core-log)
(require 'projection-utils-cmake)
(require 'projection-multi)
(require 'projection-types)

(defgroup projection-multi-cmake nil
  "Helpers for `compile-multi' and CMake projects."
  :group 'projection-multi)

(defcustom projection-multi-cmake-cache-targets 'auto
  "When true cache the CMake targets of each project."
  :type '(choice
          (const auto :tag "Cache targets and invalidate cache automatically")
          (boolean :tag "Always/Never cache targets"))
  :group 'projection-multi-cmake)

(defcustom projection-multi-cmake-exclude-targets
  (rx bol
      (or
       ;; Exclude all the builtin targets generated by CTest when you include(CTest).
       ;; See https://gitlab.kitware.com/cmake/cmake/-/issues/21730.
       "Continuous"
       "ContinuousBuild"
       "ContinuousConfigure"
       "ContinuousCoverage"
       "ContinuousMemCheck"
       "ContinuousStart"
       "ContinuousSubmit"
       "ContinuousTest"
       "ContinuousUpdate"
       "Experimental"
       "ExperimentalBuild"
       "ExperimentalConfigure"
       "ExperimentalCoverage"
       "ExperimentalMemCheck"
       "ExperimentalStart"
       "ExperimentalSubmit"
       "ExperimentalTest"
       "ExperimentalUpdate"
       "Nightly"
       "NightlyBuild"
       "NightlyConfigure"
       "NightlyCoverage"
       "NightlyMemCheck"
       "NightlyMemoryCheck"
       "NightlyStart"
       "NightlySubmit"
       "NightlyTest"
       "NightlyUpdate")
      eol)
  "Regular expression matching CMake targets to exclude from selection.
Configure any targets you never want to be presented with (such as CDash helper
targets) with this option."
  :type '(optional string)
  :group 'projection-multi-cmake)



;;; Command target backend

(defconst projection-multi-cmake--help-regex
  (rx
   bol
   (or
    (and
     (group-n 1 (minimal-match (one-or-more any)))
     ": " (one-or-more any))
    (and
     (one-or-more ".") " "
     (group-n 1 (minimal-match (one-or-more any)))
     (optional " (the default if no target is provided)")))
   eol)
  "Regexp to match targets from the CMake help output.")

(defun projection-multi-cmake--targets-from-command ()
  "Determine list of available CMake targets respecting project cache."
  (projection--cache-get-with-predicate
   (projection--current-project 'no-error)
   'projection-multi-cmake-targets
   (cond
    ((eq projection-multi-cmake-cache-targets 'auto)
     (projection--cmake-configure-modtime-p))
    (t projection-multi-cmake-cache-targets))
   #'projection-multi-cmake--targets-from-command2))

(projection--declare-cache-var
  'projection-multi-cmake-targets
  :title "Multi CMake command targets"
  :category "CMake"
  :description "Yarn script targets associated with this project"
  :hide t)

(defun projection-multi-cmake--targets-from-command2 ()
  "Determine list of available CMake targets from the help target."
  (projection--log :debug "Resolving available CMake targets")

  (projection--with-shell-command-buffer (projection--cmake-command nil "help")
    (let (res)
      (save-match-data
        (while (re-search-forward projection-multi-cmake--help-regex nil 'noerror)
          (let ((target (match-string 1)))
            (push target res))))
      (nreverse res))))



;;; Code model target backend

(defconst projection-multi-cmake--code-model-meta-targets
  ;; CMake targets [[https://github.com/kitware/CMake/blob/master/Source/cmGlobalGenerator.cxx#L3145][defined]] by CMake itself instead of the generator.
  '("all" "install" "clean"))

(defun projection-multi-cmake--targets-from-code-model ()
  "Determine list of available CMake targets from the code-model."
  ;; KLUDGE: The code-model contains targets for all build-type configurations.
  ;; For a single build-type generator like Ninja this is fine. For multi type
  ;; configs like Ninja Multi-Config projection won't know which configuration
  ;; contains the active targets for now we just return the set union of all
  ;; targets even if some may not be runnable for the current project config.
  (when-let ((code-model (projection-cmake--file-api-code-model)))
    (cl-assert (string-equal (alist-get 'kind code-model) "codemodel"))

    (append
     (thread-last
       code-model
       (alist-get 'configurations)
       (mapcar (apply-partially #'alist-get 'targets))
       (apply #'append)
       (mapcar (apply-partially #'alist-get 'name))
       (append (list (make-hash-table :test 'equal)))
       (cl-reduce (lambda (hash-table target)
                    (puthash target t hash-table)
                    hash-table))
       (hash-table-keys))
     projection-multi-cmake--code-model-meta-targets)))



(defun projection-multi-cmake--dynamic-triggers (project-type)
  "`compile-multi' target generator using dynamic CMake target backend.
Candidates will be prefixed with PROJECT-TYPE."
  (cl-loop
   for target in
   (pcase projection-cmake-target-backend
     ('help-target (projection-multi-cmake--targets-from-command))
     ('code-model (projection-multi-cmake--targets-from-code-model))
     (_ (user-error "Invalid CMake target backend: %s"
                    projection-cmake-target-backend)))
   unless (string-match-p projection-multi-cmake-exclude-targets target)
     collect `(,(concat project-type ":" target)
               :command
               ,(projection--cmake-command 'build target)
               :annotation
               ,(projection--cmake-annotation 'build target))))

(defun projection-multi-cmake--workflow-preset-triggers (project-type)
  "`compile-multi' target generator using CMake workflow presets.
Candidates will be prefixed with PROJECT-TYPE."
  (cl-loop
   for (preset) in (projection-cmake--list-presets-for-build-type 'workflow)
   collect `(,(concat project-type ":workflow:" preset)
             :command
             ,(projection--cmake-workflow-command preset)
             :annotation
             ,(projection--cmake-workflow-annotation preset))))

;;;###autoload
(defun projection-multi-cmake-targets (&optional project-type)
  "`compile-multi' target generator function for CMake projects.
When set the generated targets will be prefixed with PROJECT-TYPE."
  (setq project-type (or project-type "cmake"))

  (let ((projection-cmake-preset 'silent))
    (append
     (projection-multi-cmake--dynamic-triggers project-type)
     (projection-multi-cmake--workflow-preset-triggers project-type))))

;;;###autoload
(defun projection-multi-compile-cmake ()
  "`compile-multi' wrapper for only CMake targets."
  (interactive)
  (projection-multi-compile--run
   (projection--current-project 'no-error)
   `((t ,#'projection-multi-cmake-targets))))

;;;###autoload
(with-eval-after-load 'projection-types
  (oset projection-project-type-cmake compile-multi-targets
        (seq-uniq
         (append
          (oref projection-project-type-cmake compile-multi-targets)
          (list #'projection-multi-cmake-targets)))))

(provide 'projection-multi-cmake)
;;; projection-multi-cmake.el ends here
