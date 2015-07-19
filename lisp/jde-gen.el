;;; jde-gen.el -- Integrated Development Environment for Java.
;; $Id$

;; Author: Paul Kinnucan <paulk@mathworks.com>
;; Maintainer: Paul Landes <landes <at> mailc dt net>
;; Keywords: java, tools

;; Copyright (C) 1997, 1998, 2000, 2001, 2002, 2003, 2004 Paul Kinnucan.
;; Copyright (C) 2009 by Paul Landes

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; Gnu Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.
;;

(require 'tempo)

;; FIXME: (require 'cc-cmds) doesn't work
(declare-function c-indent-line "cc-cmds" (&optional syntax quiet ignore-point-pos))
(declare-function c-indent-exp "cc-cmds" (&optional shutup-p))
(declare-function c-indent-command "cc-cmds" (&optional arg))

;; FIXME: refactor
(declare-function jde-import-find-and-import "jde-import" (class &optional no-errors no-exclude qualifiedp))
(declare-function jde-package-convert-directory-to-package "jde-package" (dir))
(declare-function jde-package-get-package-directory "jde-package" ())
(declare-function jde-wiz-get-name "jde-wiz" (variable))
(declare-function jde-wiz-implement-interface-internal "jde-wiz" (interface-name))
(defvar jde-jdk-registry)
(defvar jde-package-unknown-package-name)

;; Allow tempo to understand ~ as destination of point
;; http://www.emacswiki.org/emacs/TempoMode#toc3
(defvar tempo-initial-pos nil
  "Initial position in template after expansion")

(defadvice tempo-insert( around tempo-insert-pos act )
  "Define initial position."
  (if (eq element '~)
      (setq tempo-initial-pos (point-marker))
    ad-do-it))

(defadvice tempo-insert-template( around tempo-insert-template-pos act )
  "Set initial position when defined using ~."
  (setq tempo-initial-pos nil)
  ad-do-it
  (if tempo-initial-pos
      (progn
        (put template 'no-self-insert t)
        (goto-char tempo-initial-pos))
    (put template 'no-self-insert nil)))



(defgroup jde-gen nil
  "JDE Autocoder"
  :group 'jde
  :prefix "jde-gen-")

(defcustom jde-gen-k&r t
  "*If non-nil, use braces in Original Kernighan & Ritchie Style.
The Creators of C started using brace placement style:

    class Some {

    }

But there is also the alternative line-up style:

    class Some
    {

    }

Setting this variable to t, uses K&R style in skeletons and tempaltes.

Note: According to the Java Code Convention [section 6.4], this value should
      be non-nil."
  :group 'jde-gen
  :type  'boolean)

(defcustom jde-gen-create-javadoc t
  "*If non-nil, generate Javadoc for all jde-gen-* code generation functions."
  :group 'jde-gen
  :type  'boolean)

(defcustom jde-gen-space-after-castings t
  "*If non-nil, add space between a class casting and what comes after it."
  :group 'jde-gen
  :type  'boolean)

; There must be some cleverer way to do this ...
(defun jde-gen-delete-preceding-whitespace ()
  "Delete any syntactical whitespace (including newlines)
before point."
  (while (and (not (bobp))
	      (or (bolp)
		  (re-search-backward "\\s-\\=" nil t)))
    (delete-char -1)))

(defun jde-gen-extract-ids-from-params (params)
  "Given a parameter lsit \"Type1 id1, Type2, id2, ...\" extract the
ids and return as \"id1, id2, ...\"."
  (mapconcat
   (lambda (arg)
     (nth 1 (split-string
	     (jde-replace-in-string
	      (jde-replace-in-string arg "^[ \t\n\f\l]+" "")
	      "[ \t\n\f\l]+$" ""))))
   (split-string params "[,]") ", "))

(defun jde-gen-lookup-named (name)
  "Lookup some saved data under the name NAME.
Returns the data if NAME was found, and nil otherwise."
  (cdr (assq name tempo-named-insertions)))

(defun jde-gen-read-template (strings)
  "Converts an autocode template represented as a list
of strings to a list of Lisp objects as required by
tempo."
  (let ((template-string "")
	(n (length strings))
	(i 0))
    (while (< i n)
      (setq template-string
	    (concat template-string (nth i strings) "\n"))
      (setq i (1+ i)))
    (setq template-string
	  (concat "'(" template-string ")"))
    (eval (car (read-from-string template-string)))))

(defcustom jde-gen-buffer-boilerplate nil
  "*Lines of boilerplate text to put at the head of a buffer template."
  :group 'jde-gen
  :type '(repeat (string :tag "Line")))

(defcustom jde-gen-boilerplate-function 'jde-gen-create-buffer-boilerplate
  "*Specifes buffer boilerplate text function.
This variable specifies a function to create boilerplate text for
insertion at the head of Java source buffers generated by JDE
templates. The specified function should take no arguments and should
return a text string.  The default value is
`jde-gen-create-buffer-boilerplate', which returns the lines of text
specified by `jde-gen-buffer-boilerplate'."
  :group 'jde-gen
  :type 'function)

(defun jde-gen-create-buffer-boilerplate ()
  "This function creates buffer boilerplate from the
variable `jde-gen-buffer-boilerplate'."
  (if jde-gen-buffer-boilerplate
      (let ((bp "")
	    (n (length jde-gen-buffer-boilerplate))
	    (i 0))
	(while (< i n)
	  (setq bp
		(concat bp (elt jde-gen-buffer-boilerplate i) "\n"))
	  (setq i (1+ i)))
	bp)))

(defun jde-gen-get-extend-class ()
  (let ((super-class (read-from-minibuffer "extends: ")))
    (if (not (string= super-class ""))
	(progn
	  (jde-import-find-and-import super-class)
	  (concat "extends " super-class " ")))))

(defcustom jde-gen-final-arguments t
  "Specifies whether to add final modifiers to method arguments.
If this variable is t, `jde-gen-method-signature' automatically
adds final modifiers to each method argument."
  :group 'jde-gen
  :type 'boolean)

(defcustom jde-gen-final-methods t
  "Specifies whether to add final method modifier.
If this variable is t, `jde-gen-method-signature' automatically adds
the final method modifier. This option is ignored within final classes.
Note that anonymous classes are implicitly final."
  :group 'jde-gen
  :type 'boolean)

(defun jde-gen-final-argument-modifier (method-args)
  "Inserts the final modifier depending on `jde-gen-final-arguments'."
  (if jde-gen-final-arguments
      (let ((comma nil)
	    (arg-list (split-string method-args ",")))
	(setq method-args "")
	(mapc
	 (lambda (arg)
	   (if (string-match "\\<final\\>" arg)
	       (setq method-args (concat method-args comma arg))
	     (setq method-args
		   (concat method-args
			   comma
			   (if (string-match "^[ \t]" arg) " ")
			   "final"
			   (if (string-match "^[^ \t]" arg) " ")
			   arg)))
	   (setq comma ","))
	 arg-list)))
  method-args)

(defun jde-gen-final-method-modifier (method-modifiers)
  "Insert final modifier according to `jde-gen-final-methods'."
  (let ((class-info (jde-parse-get-class-modifiers)))
    ;; Anonymous classes are implicitly final. See:
    ;; Java Language specification, section 15.9.5.
    ;; http://java.sun.com/docs/books/jls/second_edition/html/classes.doc.html
    (unless (or (member "final" class-info) ; explicit final modifier?
		(save-excursion
		  (and class-info
		       (goto-char (cdar class-info))
		       (looking-at "new")))) ; anonymous class?
      (if (and jde-gen-final-methods
	       (not (string-match "final" method-modifiers))
	       (not (string-match "private" method-modifiers))
	       (not (string-match "abstract" method-modifiers)))
	  ;; Find correct position according to
	  ;; Java Language specification, section 8.4.3.
	  ;; http://java.sun.com/docs/books/jls/second_edition/html/classes.doc.html
	  (let* ((pos (max (if (string-match "public" method-modifiers) (match-end 0) 0)
			   (if (string-match "protected" method-modifiers) (match-end 0) 0)
			   (if (string-match "static" method-modifiers) (match-end 0) 0)))
		 (left (substring method-modifiers 0 pos))
		 (right (substring method-modifiers pos)))
	    (setq method-modifiers (concat
			     left
			     (if (> (length left) 0) " ")
			     "final"
			     (if (and (= (length left) 0) (> (length right) 0)) " ")
			     right))))))
  method-modifiers)

(defmacro jde-gen-save-excursion (&rest body)
  "Evaluate BODY within a let form.
Protects `tempo-marks', `tempo-named-insertions', `tempo-region-start'
and `tempo-region-stop' against modifications by invoked template.
Those tempo vars will be set to their default values.
This allows to invoke tempo-templates within tempo-templates
without having mutual interference of those templates.
Returns nil."
  `(progn
     (let ((tempo-marks)
	   (tempo-named-insertions)
	   (tempo-region-start (make-marker))
	   (tempo-region-stop (make-marker)))
       (progn ,@body))
     nil))

(defun jde-gen-electric-brace (&optional padding)
  "Insert a brace according to `jde-gen-k&r'.
Optional argument PADDING is inserted before brace
if jde-gen-k&r is enabled."
  (if jde-gen-k&r
      (if padding (insert padding))
    (progn
      (indent-according-to-mode)
      (insert "\n")))
  (insert "{")
  (indent-according-to-mode)
  (insert "\n")
  nil)

(defun jde-gen-indent ()
  "Indent current line if it is not empty.
Removes indentation if the current line contains only whitespaces.
The purpose of this function is to avoid trailing whitespaces
in generated java code. Returns nil."
  (if (save-excursion
	(beginning-of-line)
	(looking-at "\\s-+$"))
      (replace-match ""))
  (if (not (and (bolp) (eolp)))
      (c-indent-line))
  nil) ;; must return nil to prevent template insertion.

(defun jde-gen-blank-lines (n &optional m)
  "Ensure exactly N blank lines.
Leaves point at the beginning of the line following blank lines.
If M is non-nil, (`forward-line' M) will be called after inserting.
If point is at the beginning of a non-blank line, blank lines will appear before that line.
If point is at the end of a non-blank line, blank lines will appear after that line.
If point is in the middle of a non-blank line, this line will be split at point.
Indentation and trailing whitespace of surrounding non-blank lines will stay unchanged.
Returns nil."
  (interactive "*")
  (if (or (bolp) (eolp)
	  (save-excursion
	    (beginning-of-line)
	    (looking-at "\\s-*$")))
      (delete-region
       (+ (point) (skip-chars-backward " \t\n") (skip-chars-forward  " \t"))
       (+ (point) (skip-chars-forward  " \t\n") (skip-chars-backward " \t"))))
  (while (>= n 0)
    (insert "\n")
    (setq n (1- n)))
  (if m
      (forward-line m))
  nil)

; In order to avoid problems with recursive tempo-template invocations
; interface generation has been split in two parts.
; jde-gen-get-interface-implementation prompts for the
; interface and stores point-marker and interface name in buffer local
; variables.  jde-gen-insert-interface-implementation is invoked after
; the template for class or inner class and generates the interface
; implementation.

(defvar jde-gen-interface-to-gen nil
  "Insertion marker and name (MARKER . NAME) of interface
implemented by the most recently generated class template.
Used by `jde-gen-get-interface-implementation' to
store name and location of interface to be inserted
by `jde-gen-insert-interface-implementation'.")

(defun jde-gen-get-interface-implementation (&optional insert-immediately)
  "Prompts the user to enter the name of an interface
implemented by a class being generated by a tempo template.
If the user enters a name, stores the current point as marker in
the buffer and the interface name as a cons (MARKER . NAME)
in the global variable `jde-gen-interface-to-gen'. Otherwise
it sets this variable to nil. If INSERT-IMMEDIATELY is non-nil,
`jde-gen-insert-interface-implementation' will be called immediately
and jde-gen-interface-to-gen will be set to nil."
  (let ((interface (read-from-minibuffer "implements: ")))
    (if (not (string= interface ""))
	(progn
	  (setq jde-gen-interface-to-gen
		(cons (point-marker) interface))
	  (if insert-immediately
	      (progn
		(jde-gen-insert-interface-implementation)
		(setq jde-gen-interface-to-gen nil))))
      (setq jde-gen-interface-to-gen nil)))
  nil) ;; must return nil to prevent template insertion.

(defun jde-gen-insert-interface-implementation ()
  "Generates the interface specified by the cdr of `jde-gen-interface-to-gen'
and inserts it in the current buffer at the location specified
by the car of `jde-gen-interface-to-gen'."
  (if jde-gen-interface-to-gen
      (let ((ins-pos (marker-position (car jde-gen-interface-to-gen)))
	    (interface (cdr jde-gen-interface-to-gen)))
	(save-excursion
	  (goto-char ins-pos)
	  (jde-wiz-implement-interface-internal interface)))))

(defun jde-gen-get-package-statement ()
  (require 'jde-package)
  (let* ((package-dir (jde-package-get-package-directory))
	 (suggested-package-name
	  (if (or
	       (string= package-dir jde-package-unknown-package-name)
	       (string= package-dir ""))
	      nil
	    (jde-package-convert-directory-to-package package-dir)))
	 (package-name
	  (read-from-minibuffer "Package: " suggested-package-name)))
    (if (and
	 package-name
	 (not (string= package-name "")))
	(format "package %s;\n\n" package-name))))


(defcustom jde-gen-method-signature-padding-1 ""
  "String that comes just after the function name and just before
the opening parenthesis of the argument list for a method call or definition.
For example, if set to a single space [\" \"], then a generated method might
look like:

    void setXxxx () {
		^
If not set, the same generated method would look like:

    void setXxxx() {
		^
Note: According to the Java Code Convention [section 6.4], this value should
      be the empty string."
  :group 'jde-gen
  :type 'string)


(defcustom jde-gen-method-signature-padding-2 ""
  "String which comes just after the opening parenthesis and just before
the closing parenthesis of an argument list for a method call or definition.
For example, if set to a single space [\" \"], then a generated method might
look like:

    void setXxxx( boolean newValue ) {
		 ^                ^
If not set, the same generated method would look like:

    void setXxxx(boolean newValue) {
		 ^              ^
Note: According to the Java Code Convention [section 6.4], this value should
      be the empty string."
  :group 'jde-gen
  :type 'string)


(defcustom jde-gen-method-signature-padding-3 " "
  "String which comes just after the closing parenthesis of an
argument list for a method call or definition.  For example, if set to
a single space [\" \"], then a generated method might look like:

    void setXxxx(boolean newValue) {
				  ^
If not set, the same generated method would look like:

    void setXxxx(boolean newValue){
				  ^
Note: According to the Java Code Convention [section 6.4], this value should
      be a single space."
  :group 'jde-gen
  :type 'string)


(defcustom jde-gen-conditional-padding-1 " "
  "The string to be inserted between a conditional keyword (if, while, etc.)
and the opening parenthesis for its conditional expression:

    <keyword><1>(<2><expression><2>)<3>{

also:  <3>else<3>{

where <1> is jde-gen-conditional-padding-1
  and <2> is jde-gen-conditional-padding-2
  and <3> is jde-gen-conditional-padding-3.

For example, if <1> is a space, <2> is nil and <3> is a space, then a while
clause might look like:

    while (true) {

Note: According to the Java Code Convention [section 7.4], this value should
      be a single space."
  :group 'jde-gen
  :type 'string)


(defcustom jde-gen-conditional-padding-2 ""
  "The string to be inserted before and after a conditional expression
between the parentheses.  See `jde-gen-conditional-padding-1' for details.

Note: According to the Java Code Convention [section 7.4], this value should
      be the empty string."
  :group 'jde-gen
  :type 'string)


(defcustom jde-gen-conditional-padding-3 " "
  "The string to be inserted after the closing parenthesis of the
conditional expression and before the opening brace.  See
`jde-gen-conditional-padding-1' for details.

Note: According to the Java Code Convention [section 7.4], this value should
      be a single space."
  :group 'jde-gen
  :type 'string)


(defun jde-gen-method-signature (access type name arglist &optional throwslist)
  "This function generates method signatures with a consistent format.
All jde-gen functions and/or templates should use this function when
creating Java methods and constructors.

The signature is of the format:

  <access> <type> <name><1>(<2><arglist><2>) throws <throwslist><3>

where <1> is the value of jde-gen-method-signature-padding-1
  and <2> is the value of jde-gen-method-signature-padding-2
  and <3> is the value of jde-gen-method-signature-padding-3.

<3> will not be used if `jde-gen-k&r' is nil.

This function takes care of `jde-gen-final-methods' and
`jde-gen-final-arguments'. final modifiers will be added
according to those flags.

If a parameter to this function is empty or nil, then it is omitted,
as well as the corresponding padding, whitespace and/or Java keywords."

  (if (> (length type) 0) ; ordinary method?
      (setq access (jde-gen-final-method-modifier access)))
  (let ((sig
	 (concat
	  (if (> (length access) 0)
	      (concat access " ")
	    ());; if no access (e.g. "public static"), then nothing
	  (if (> (length type) 0)
	      (concat type " ")
	    ());; if no type (e.g. "boolean" or "void"), then nothing
	  name
	  jde-gen-method-signature-padding-1
	  "("
	  (if (> (length arglist) 0)
	      (concat jde-gen-method-signature-padding-2 (jde-gen-final-argument-modifier arglist)
		      jde-gen-method-signature-padding-2 )
	    ())
	  ")"
	  (if (> (length throwslist) 0)
	      (concat " throws " throwslist)
	    ())
	  (if jde-gen-k&r
	      jde-gen-method-signature-padding-3
	    ()))))
    sig))

(defcustom jde-gen-class-create-constructor t
  "*If non-nil, generate constructor for `jde-gen-class-buffer'."
  :group 'jde-gen
  :type  'boolean)

(defcustom jde-gen-class-create-package 'jde-gen-get-package-statement
  "*If non-nil, generate constructor for `jde-gen-class-buffer'."
  :group 'jde-gen
  :type  '(choice
	   (const :tag "Prompt for package" jde-gen-get-package-statement)
	   (const :tag "Package updates automatically" jde-package-update)))

;;(makunbound 'jde-gen-class-buffer-template)
(defcustom jde-gen-class-buffer-template
  (list
   "(funcall jde-gen-boilerplate-function)"
   "(let ((s (funcall jde-gen-class-create-package)))"
   "  (if (or (null s) (not (string-match \"\n\n$\" s)))"
   "      (list 'l s 'n)"
   "    s))"
   "(when jde-gen-create-javadoc"
   "(progn (require 'jde-javadoc) (jde-javadoc-insert-start-block))"
   "'(l \" * Describe class \""
   "    (file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "    \" here.\" 'n"
   "    \" \" (jde-javadoc-insert-empty-line)"
   "    \" \" (jde-javadoc-insert-empty-line)"
   "    \" * Created: \" (current-time-string) 'n"
   "    \" \" (jde-javadoc-insert-empty-line)"
   "    \" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-author-tag))"
   "    \" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-version-tag))"
   "    \" \" (jde-javadoc-insert-end-block)))"
   "\"public class \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\" \" (jde-gen-get-extend-class)"
   "(jde-gen-electric-brace)"
   "'p'n"
   "\"}\">"
   "(if jde-gen-comments (concat \" // \""
   "  (file-name-sans-extension (file-name-nondirectory buffer-file-name))))"
   "'>'n"
   ";; Here comes the stuff that needs a fully generated class."
   ";; We jump back and add those things retrospectively."
   "(progn (tempo-backward-mark)"
   " (jde-gen-save-excursion"
   "  (jde-gen-get-interface-implementation t))"
   " (jde-gen-save-excursion"
   "  (if jde-gen-class-create-constructor"
   "     (jde-wiz-gen-method \"public\" \"\""
   "       (file-name-sans-extension (file-name-nondirectory buffer-file-name)) \"\" \"\" \"\"))))"
   ";; Move to constructor body. Set tempo-marks to nil in order to prevent tempo moving to mark."
   "(progn (re-search-forward \"^[ \\t]*$\") (setq tempo-marks nil) nil)"
   "(when jde-gen-class-create-constructor"
   "  (up-list)"
   "  (forward-char))")
  "*Template for new Java class.
Setting this variable defines a template instantiation
command `jde-gen-class', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (tempo-define-template "java-class-buffer-template"
				 (jde-gen-read-template val)
				 nil
				 "Insert a generic Java class buffer skeleton.")
	  (defalias 'jde-gen-class
	    (list 'lambda (list)
		  (list 'interactive)
		  (list 'tempo-template-java-class-buffer-template)
		  (list 'jde-gen-insert-interface-implementation)))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-class-buffer (file)
  "Create a new Java buffer containing a class of the same name.
This command inserts the class template generated by `jde-gen-class'.
"
  (interactive "F")
  (find-file file)
  (jde-gen-class))

;;(makunbound 'jde-gen-interface-buffer-template)
(defcustom jde-gen-interface-buffer-template
  (list
   "(funcall jde-gen-boilerplate-function)"
   "(jde-gen-get-package-statement)"
   "(progn (require 'jde-javadoc) (jde-javadoc-insert-start-block))"
   "\" * Describe interface \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\" here.\" 'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" * Created: \" (current-time-string) 'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-author-tag))"
   "\" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-version-tag))"
   "\" \" (jde-javadoc-insert-end-block)"
   "\"public interface \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\" \" (jde-gen-get-extend-class)"
   "(jde-gen-electric-brace)"
   "'p'n"
   "\"}\">"
   "(if jde-gen-comments (concat \" // \""
   "  (file-name-sans-extension (file-name-nondirectory buffer-file-name))))"
   "'>'n")
  "*Template for new Java interface.
Setting this variable defines a template instantiation
command `jde-gen-interface', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (tempo-define-template "java-interface-buffer-template"
				 (jde-gen-read-template val)
				 nil
				 "Insert a generic Java interface buffer skeleton.")
	  (defalias 'jde-gen-interface
	    (list 'lambda (list)
		  (list 'interactive)
		  (list 'tempo-template-java-interface-buffer-template)))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-interface-buffer (file)
  "Create a new Java buffer containing an interface of the same name.
This command inserts the interface template generated by `jde-gen-interface'.
It then moves the point to the location of the first method."
  (interactive "F")
  (find-file file)
  (jde-gen-interface))

;;(makunbound 'jde-gen-console-buffer-template)
(defcustom jde-gen-console-buffer-template
  (list
   "(funcall jde-gen-boilerplate-function)"
   "(jde-gen-get-package-statement)"
   "(progn (require 'jde-javadoc) (jde-javadoc-insert-start-block))"
   "\" * Describe class \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\" here.\" 'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" * Created: \" (current-time-string) 'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-author-tag))"
   "\" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-version-tag))"
   "\" \" (jde-javadoc-insert-end-block)"
   "\"public final class \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "(jde-gen-electric-brace \" \")"
   "'p'n"
   "\"}\">"
   "(if jde-gen-comments (concat \" // \""
   "  (file-name-sans-extension (file-name-nondirectory buffer-file-name))))"
   "'>'n"
   ";; Here comes the stuff that needs a fully generated class."
   ";; We jump back and add those things retrospectively."
   "(progn (tempo-backward-mark)"
   " (jde-gen-save-excursion"
   "  (jde-gen-main-method))"
   " (tempo-backward-mark)"
   " (jde-gen-save-excursion"
   "  (jde-wiz-gen-method \"private\" \"\""
   "   (file-name-sans-extension (file-name-nondirectory buffer-file-name)) \"\" \"\" \"\")))"
   ";; Move to constructor body. Set tempo-marks to nil in order to prevent tempo moving to mark."
   "(progn (re-search-forward \"^[ \\t]*$\") (setq tempo-marks nil) nil)")
  "*Template for new Java console app main class buffer.
Setting this variable defines a template instantiation
command `jde-gen-console', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-console
	    (tempo-define-template "java-console-buffer-template"
				   (jde-gen-read-template val)
				   nil
				   "Insert skeleton for a new Java console buffer"))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-console-buffer (file)
  "Create a new Java buffer containing a console class of the same name.
This command inserts the class template generated by `jde-gen-class'.
It then moves the point to the location to the constructor."
  (interactive "F")
  (find-file file)
  (jde-gen-console))

(defun jde-gen-deep-clone-copies ()
  (let* ((class-tag (semantic-current-tag))
	 (class-name (semantic-tag-name class-tag))
	 (members (sort (jde-parse-get-serializable-members class-tag)
			'jde-parse-compare-member-types)))
    (apply #' append '(l)
	      (mapcar #'(lambda (elt)
			  (let ((e (car elt)))
			    (list (format "if (%s != null) ret.%s = %s.clone();" e e e) '> 'n)))
		      members))))

(defcustom jde-gen-deep-clone-catch-exception t
  "*Whether or not to catch CloneNotSupportedException."
  :group 'jde-gen
  :type  'boolean)

;;(makunbound 'jde-gen-deep-clone-template)
(defcustom jde-gen-deep-clone-template
  '(
    "(jde-wiz-generate-interface \"java.lang.Cloneable\")"

    "'&'> (progn (require 'jde-javadoc) nil)"

    ;; create the javadoc (todo: only generate if turned on)
    "(when jde-gen-create-javadoc "
    "'(l (jde-javadoc-insert-start-block)"
    "\"* Create a deep clone of this object.\" '>'n"
    "\"*\" '>'n"
    "\"* @return a deep clone of this object.\" '>'n"
    "'> (jde-javadoc-insert-end-block)))"

    ;; create method declaration
    "(let (jde-gen-final-methods)"
    " (jde-gen-method-signature"
    "   \"public\""
    "   (file-name-sans-extension (file-name-nondirectory buffer-file-name)) "
;    "   \"Object\""
    "   \"clone\""
    "   nil"
    " ))"
    "'>"
    "(jde-gen-electric-brace)"

    ;; return declaration
    "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
    "\" ret = \" "
    " (if jde-gen-deep-clone-catch-exception "
    "    '(l \"null;\") "
    "  '(l \"(\" (file-name-sans-extension"
    "    (file-name-nondirectory buffer-file-name))"
    "    \")super.clone();\")) "
    " '>'n'n "

    ;; must catch CloneNotSupported exception
    "(when jde-gen-deep-clone-catch-exception "
    "(let ((beg (point)))"
    "  (insert \"ret = (\")"
    "  (insert (file-name-sans-extension"
    "    (file-name-nondirectory buffer-file-name)))"
    "  (insert \")\") "
    "  (if jde-gen-space-after-castings (insert \" \"))"
    "  (insert \"super.clone();\")"
    "  (jde-gen-try-catch-wrapper beg (point))"
    ;; at this point we are at the place to add what exception to catch
    "  (insert \"CloneNotSupportedException\")"
    "  nil))"

    "(when jde-gen-deep-clone-catch-exception "
    ;; first go out of the catch exception ()s
    " (goto-char (scan-lists (point) 1 1))"
    ;; now go into the catch {}s definition part
    " (goto-char (scan-lists (point) 1 -1))"
    " (end-of-line)"
    " 'n)"

    "(when jde-gen-deep-clone-catch-exception "
    "'(l \"throw new InternalError(\\\"clone should be supported (forgot?)\\\");\""
    "'(l '>'%)"
    "))"

    "(when jde-gen-deep-clone-catch-exception "
    "'(l (progn (goto-char (scan-lists (point) 1 1)) (end-of-line) '(l n))"
    "''p 'n)"
    ")"

    ;; clone members
    ;; todo: only add those that implement Cloneable
    "(jde-gen-deep-clone-copies) 'n"

    ;; add return statement and finish method
    "\"return ret;\" '>'n"
    "\"}\" '>'n"
    )
  "*Template for creating a deep clone method.
Setting this variable defines a template instantiation
command `jde-gen-deep-clone', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-deep-clone
	    (tempo-define-template
	     "java-deep-clone-method"
	     (jde-gen-read-template val)
	     nil
	     "Create a deep clone method at the current point."))
	  (set-default sym val)))

;; TO DO: Add support for style that puts member declarations at the bottom
;; of a class.
(defun jde-gen-get-next-member-pos (modifiers &optional no-move-to-point)
  "Return the position to add the next member in a class.  Return
the point at end of a group of modifiers at the end of the line in a class
definition, or the top of the class if there are no variables with the
modifiers we supply.  This assumes a style where modifiers always are at the
top of the class like:

public class Person {

  public static final String RACE = \"HUMAN\";

  private String name;
  private int age;
...

MODIFIERS is a set of modifiers to put the point after.
NO-MOVE-POINT if nil move the point, either way, we return the position.
"
  (if (stringp modifiers) (setq modifiers (split-string modifiers ",")))
  (let* ((pair (jde-parse-get-innermost-class-at-point))
	 (class-name (if pair (car pair)))
	 pos)
    (if (null pair) (error "point is not in a class definition"))
    (semantic-fetch-tags)
    (setq pos (jde-parse-get-nth-member class-name modifiers
					nil -1 nil 'subset))

    (if (null pos) (setq pos (jde-parse-get-top-of-class class-name)))
    (if (and pos (not no-move-to-point)) (goto-char pos))
    pos))


(defun jde-gen-insert-at-class-top (&optional class-regexp no-move-point)
  "Position point at top of class, inserting space if needed.

CLASS-REGEXP the symbol used to find the class to find the top of.  See
`jde-parse-get-top-of-class' for more information.

NO-MOVE-POINT if non-nil just the position is returned, otherwise the point is
moved also."
  (if (= (point) (jde-parse-get-top-of-class class-regexp no-move-point))
      (insert "\n"))
  (insert "\n")
  (backward-char 1))

(defun jde-gen-get-set-member-annotations (type name)
  "This is meant to override returning template symbols for private members.
Members include the private encapsulated data of the class.
TYPE is the type of member.
NAME is the member name.
See `jde-gen-get-set-var-template'."
  nil)

;;(makunbound 'jde-gen-get-set-var-template)
(defcustom jde-gen-get-set-var-template
  '(
    ;; position point at top of class, inserting space if needed
    "(jde-gen-insert-at-class-top nil t)"

    ;; remember where we are for later, then go to the end of the private
    ;; declarations first found from the top of the class
    "(progn (tempo-save-named 'mypos (point-marker)) nil)"
    "(progn"
    "  (jde-gen-get-next-member-pos '(\"private\")) nil)"

    ;; add class member
    "(P \"Variable type: \" type t)"
    "(P \"Variable name: \" name t)"
    "'&'>"
    "(when jde-gen-create-javadoc "
    " (progn (require 'jde-javadoc) (jde-javadoc-insert-start-block))"
    " '(l \"* Describe \" (s name) \" here.\" '>'n"
    "'> (jde-javadoc-insert-end-block)))"
    "(jde-gen-get-set-member-annotations"
    "  (tempo-lookup-named 'type)"
    "  (tempo-lookup-named 'name))"
    "'& \"private \" (s type) \" \""
    "(s name) \";\" '>"
    "(progn (goto-char (marker-position (tempo-lookup-named 'mypos))) nil)"

    "(jde-gen-blank-lines 2 -1)"
    ;;we begin by the getter
    "(when jde-gen-create-javadoc "
    "'(l '> (jde-javadoc-insert-start-block)"
    "\"* Get the <code>\" (jde-gen-lookup-and-capitalize 'name) \"</code> value.\" '>'n"
    "'> (jde-javadoc-insert-empty-line)"
    "'>"
    "(let ((type (tempo-lookup-named 'type)))"
    "  (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-return-tag)))"
    "'> (jde-javadoc-insert-end-block)))"

    "(jde-gen-method-signature"
    "  \"public\""
    "  (jde-gen-lookup-named 'type)"
    "  (if (string= \"boolean\" (jde-gen-lookup-named 'type) ) "
    "    (concat \"is\" (jde-gen-lookup-and-capitalize 'name))"
    "   (concat \"get\" (jde-gen-lookup-and-capitalize 'name)))"
    "  nil"
    " )"

    "(jde-gen-electric-brace)"

    "\"return \" (s name) \";\" '>'n \"}\"'>'n"
    ;; leave a blank line with no indentation
    "'n"

    ;;we continue with the setter
    "(when jde-gen-create-javadoc "
    "'(l '> (jde-javadoc-insert-start-block)"
    "\"* Set the <code>\" (jde-gen-lookup-and-capitalize 'name) \"</code> value.\" '>'n"
    "\"*\" '>'n"
    ;; ToDo: use jde-wiz-get-set-variable-prefix
    "\"* @param \" (jde-gen-lookup-named 'name)"
    "\" The new \" (jde-gen-lookup-and-capitalize 'name) \" value.\" '>'n"
    "'> (jde-javadoc-insert-end-block)))"

    ;; name the method
    "(jde-gen-method-signature "
    "  \"public\""
    "  \"void\""
    "  (concat \"set\" (jde-gen-lookup-and-capitalize 'name))"
    "  (concat (jde-gen-lookup-named 'type) \" \" "
    "          (jde-gen-lookup-named 'name))"
    " )"

   "(jde-gen-electric-brace)"

    "'>\"this.\" (s name) \" = \" (jde-gen-lookup-named 'name)"
    "\";\" '>'n \"}\" '>'n"
    "(when (looking-at \"\\\\s-*\\n\\\\s-*$\")"
    "  (forward-line 1) (end-of-line) nil)"
    )
  "*Template for creating a variable at the top of the class and
a get/set method pair for the variable at point.
Setting this variable defines a template instantiation
command `jde-gen-get-set', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-get-set
	    (tempo-define-template
	     "java-get-set-pair"
	     (jde-gen-read-template val)
	     nil
	     "Insert variable at the top of the class and get-set method pair at point."))
	  (set-default sym val)))

(defalias 'jde-gen-property 'jde-gen-get-set)

(defun jde-gen-get-set-methods (duples)
  "Generate variables at the top of the class and get and set methods for
the variables at point.

DUPLES is either a list of list type name pairs or a string.  If it is a
string, the string has the form:

  type1,name1;type2,name2;...;typeN,nameN

where type is the primitive or class name of the getter setter and name is the
name of the property (getter/setter).

If DUPLES is a lisp object it must a list with the form:

  ((\"type1\" \"name1\") (\"type2\" \"name2\") ... )"
  (interactive "sGets/Sets (type1,name1;type2,name2;...): ")
  (if (stringp duples) (setq duples (split-string duples "[ \t]*;[ \t]*")))
  (dolist (elt duples)
    (let ((pair (if (stringp elt) (split-string elt "[ \t]*,[ \t]*") elt)))
      (tempo-save-named 'type (car pair))
      (tempo-save-named 'name (car (cdr pair)))
      (jde-gen-get-set))))

;; (makunbound 'jde-gen-bean-template)
(defcustom jde-gen-bean-template
  '(
    ;; add class shell
    ";; generate class and save point which is in body of the constructor"
    "(jde-gen-class) 'p"

    ;; position point at end of class.
    "(progn (end-of-buffer) (search-backward \"}\") (backward-char 1)) 'n"
    "(jde-gen-blank-lines 2 -1)"

    "(jde-gen-save-excursion"

    ;; import Java, per spec, bean stuff
    " (jde-wiz-generate-interface \"java.io.Serializable\")"
    " (jde-import-insert-import '(\"java.io.Serializable\"))"

    ;; add getters and setters
    " (call-interactively 'jde-gen-get-set-methods))"
    )
  "*Template for creating a Java bean.
Setting this variable defines a template instantiation
command `jde-gen-bean', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-bean
	    (tempo-define-template
	     "java-bean-template"
	     (jde-gen-read-template val)
	     nil
	     "Create a Java bean."))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-bean-buffer (file)
  "Create a new Java buffer containing a Java bean of the same name.
This command inserts the class template generated by `jde-gen-bean'.
It then moves the point to the location of the constructor."
  (interactive "F")
  (find-file file)
  (jde-gen-bean))

;(makunbound 'jde-gen-hibernate-pojo-equals-method-template)
(defcustom jde-gen-hibernate-pojo-equals-method-template
  '("'>"
    "(when jde-gen-create-javadoc"
    "'(l \"/**\" '> 'n"
    "    \" * Check if this object is equal (equivalent) to another object.\" '> 'n"
    "    \" */\" '> 'n"
    "))"
    "(jde-gen-method-signature \"protected\" \"boolean\" \"equalsHelper\" \"Object obj\")"
    "(jde-gen-electric-brace)"
    "(jde-gen-equals-return \"obj\" \"o\" nil \"equalsHelper\") '> 'n"
    "\"}\" '> 'n))"
    )
  "*Template for creating an equals method in a hibernate pojo.
The generated class would extend a persistable pojo used by hibernate.
Setting this variable defines a template instantiation command
`jde-gen-equals-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-hibernate-pojo-equals-method
	    (tempo-define-template
	     "java-hibernate-pojo-equals-method"
	     (jde-gen-read-template val)
	     nil
	     "Create an equals method at the current point."))
	  (set-default sym val)))

;(makunbound 'jde-gen-hibernate-pojo-template)
(defcustom jde-gen-hibernate-pojo-buffer-template
  '("'>"
    "(jde-gen-class)"
    "(flet ((jde-gen-get-set-member-annotations (type name)"
    "         (format \"@Column(name = \\\"%s\\\", nullable = false)\" name)))"
    "   (call-interactively 'jde-gen-get-set-methods)"
    "    nil)"
    "'n"
    "(progn"
    "  (semantic-fetch-tags)"
    "  (jde-gen-hashcode-method)"
    "  'n)"
    "(progn"
    "  (jde-gen-hibernate-pojo-equals-method)"
    "  'n)"
    "(progn"
    "  (jde-gen-tostring-method)"
    "  nil)"
    "(progn"
    "  (jde-parse-get-top-of-class)"
    "  (beginning-of-line)"
    "  nil)"
    "(jde-import-insert-import '(\"javax.persistence.Entity\"))"
    "(jde-import-insert-import '(\"javax.persistence.Table\"))"
    "(jde-import-insert-import '(\"javax.persistence.Column\"))"
    "(progn (jde-import-organize) nil)"
    " '> \"@Entity\" 'n"
    " '> \"@Table(name = \\\"\" "
    "(progn (tempo-save-named 'table-pos (point-marker)) nil)"
    "(downcase (file-name-sans-extension (file-name-nondirectory buffer-file-name)))"
    "\"\\\") \" 'n"
    "(progn (goto-char (marker-position (tempo-lookup-named 'table-pos))) nil)"
    )
  "*Template for creating an equals method.
Setting this variable defines a template instantiation command
`jde-gen-equals-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-hibernate-pojo
	    (tempo-define-template
	     "java-hibernate-pojo-buffer-template"
	     (jde-gen-read-template val)
	     nil
	     "Create an equals method at the current point."))
	  (set-default sym val)))

(defcustom jde-gen-jfc-app-buffer-template
  (list
   "(funcall jde-gen-boilerplate-function)"
   "(jde-gen-get-package-statement)"
   "\"import java.awt.Dimension;\" '>'n"
   "\"import java.awt.Graphics;\" '>'n"
   "\"import java.awt.Graphics2D;\" '>'n"
   "\"import java.awt.Color;\" '>'n"
   "\"import java.awt.geom.Ellipse2D;\" '>'n"
   "\"import java.awt.event.WindowAdapter;\" '>'n"
   "\"import java.awt.event.WindowEvent;\" '>'n"
   "\"import javax.swing.JFrame;\" '>'n"
   "\"import javax.swing.JPanel;\" '>'n"
   "\"import javax.swing.JScrollPane;\" '>'n"
   "\"import javax.swing.JMenuBar;\" '>'n"
   "\"import javax.swing.JMenu;\" '>'n"
   "\"import java.awt.event.ActionEvent;\" '>'n"
   "\"import javax.swing.AbstractAction;\" '>'n '>'n"
   "(progn (require 'jde-javadoc) (jde-javadoc-insert-start-block))"
   "\" * \""
   "(file-name-nondirectory buffer-file-name) '>'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" * Created: \" (current-time-string) '>'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-javadoc-insert 'tempo-template-jde-javadoc-author-tag)"
   "\" \" (jde-javadoc-insert 'tempo-template-jde-javadoc-version-tag)"
   "\" \" (jde-javadoc-insert 'tempo-template-jde-javadoc-end-block \"*/\")"
   "'>'n"
   "\"public class \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\" extends JFrame\""

   "(if jde-gen-k&r "
   "()"
   "'>'n)"
   "\"{\"'>'n"

   "\"class Canvas extends JPanel\""

   "(if jde-gen-k&r "
   "()"
   "'>'n)"
   "\"{\"'>'n"

   "(jde-gen-method-signature"
   "  \"public\""
   "  \"\""
   "  \"Canvas\""
   "  \"\""
   " )"
   "'>"

   "(if jde-gen-k&r "
   " ()"
   " 'n)"
   "\"{\"'>'n"

   "\"setSize(getPreferredSize());\" '>'n"
   "\"Canvas.this.setBackground(Color.white);\" '>'n"
   "\"}\"'>'n '>'n"

   "(jde-gen-method-signature"
   "  \"public\""
   "  \"Dimension\""
   "  \"getPreferredSize\""
   "  \"\""
   " )"
   "'>"

   "(if jde-gen-k&r "
   " ()"
   " 'n)"
   "\"{\"'>'n"

   "\"return new Dimension(600, 600);\" '>'n"
   "\"}\"'>'n '>'n"

   "(jde-gen-method-signature"
   "  \"public\""
   "  \"void\""
   "  \"paintComponent\""
   "  \"Graphics g\""
   " )"
   "'>"

   "(if jde-gen-k&r "
   " ()"
   " 'n)"
   "\"{\"'>'n"

   "\"super.paintComponent(g);\" '>'n"
   "\"Graphics2D g2d = (Graphics2D) g;\" '>'n"
   "\"Ellipse2D circle = new Ellipse2D.Double(0d, 0d, 100d, 100d);\" '>'n"
   "\"g2d.setColor(Color.red);\" '>'n"
   "\"g2d.translate(10, 10);\" '>'n"
   "\"g2d.draw(circle);\" '>'n"
   "\"g2d.fill(circle);\" '>'n"
   "\"}\"'>'n "

   "\"}\"'>'n '>'n"


   ;; Constructor
   "(jde-gen-method-signature"
   "  \"public\""
   "  \"\""
   "  (file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "  \"\""
   " )"
   "'>"

   "(if jde-gen-k&r "
   " ()"
   " 'n)"
   "\"{\"'>'n"


   "\"super(\\\"\" (P \"Enter app title: \") \"\\\");\" '>'n"
   "\"setSize(300, 300);\" '>'n"
   "\"addWindowListener(new WindowAdapter() \""

   "(if jde-gen-k&r "
   "()"
   "'>'n)"
   "\"{\"'>'n"


   "\"public void windowClosing(WindowEvent e) {System.exit(0);}\" '>'n"
   "\"public void windowOpened(WindowEvent e) {}\" '>'n"
   "\"});\"'>'n"


   "\"setJMenuBar(createMenu());\" '>'n"
   "\"getContentPane().add(new JScrollPane(new Canvas()));\" '>'n"
   "\"}\"'>'n"
   "'>'n"

   ;; Main method
   "(jde-gen-method-signature"
   "   \"public static\""
   "   \"void\""
   "   \"main\""
   "   \"String[] args\""
   " )"

   "(if jde-gen-k&r "
   "()"
   "'>'n)"
   "\"{\"'>'n"

   "'>'n"
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\" f = new \""
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "\"();\" '>'n"
   "\"f.show();\" '>'n"
   "\"}\"'>'n '>'n"
   ;; createMenu method
   "\"protected JMenuBar createMenu() \""


   "(if jde-gen-k&r "
   "()"
   "'>'n)"
   "\"{\"'>'n"


   "\"JMenuBar mb = new JMenuBar();\" '>'n"
   "\"JMenu menu = new JMenu(\\\"File\\\");\" '>'n"
   "\"menu.add(new AbstractAction(\\\"Exit\\\") \""

   "(if jde-gen-k&r "
   "()"
   "'>'n)"
   "\"{\"'>'n"


   "(jde-gen-method-signature"
   "  \"public\""
   "  \"void\""
   "  \"actionPerformed\""
   "  \"ActionEvent e\""
   " )"
   "'>"

   "(if jde-gen-k&r "
   " ()"
   " 'n)"
   "\"{\"'>'n"


   "\"System.exit(0);\" '>'n"
   "\"}\" '>'n"
   "\"});\" '>'n"
   "\"mb.add(menu);\" '>'n"
   "\"return mb;\" '>'n"
   "\"}\"'>'n "
   "\"} // \"'>"
   "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
   "'>'n")
  "*Template for JFC (Swing) application buffer.
Setting this variable defines a template instantiation
command `jde-gen-jfc-app', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-jfc-app
	    (tempo-define-template "java-jfc-app-buffer-template"
				   (jde-gen-read-template val)
				   nil
				   "Insert skeleton for a JFC app buffer"))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-jfc-app-buffer (file)
  "Create a new Java buffer containing a JFC application class.
This command inserts the class template generated by `jde-gen-jfc-app'.
It then moves the point to the location to the constructor."
  (interactive "F")
  (find-file file)
  (jde-gen-jfc-app)
  (goto-char (point-min))
  (search-forward "{")
  (backward-char 1)
  (c-indent-exp)
  (tempo-forward-mark))

(defcustom jde-gen-makefile-buffer-template
  (list
    "\"################################################################################\" 'n"
    "\"#\" 'n"
    "\"# Generic Makefile for java\" 'n"
    "\"#\" 'n"
    "\"# Author: \" user-full-name 'n"
    "\"################################################################################\" 'n"
    "\"\" 'n"
    "\"# Common Properties\" 'n"
    "\"SRCDIR = \"  (or (car jde-sourcepath) \"src\") 'n"
    "\"OBJDIR = \"  (if (string= jde-compile-option-directory \"\") \"classes\" jde-compile-option-directory) 'n"
    "\"JAVA_HOME = \" (jde-get-jdk-dir) 'n"
    "\"JAVAC = $\\\(JAVA_HOME\\\)/bin/javac\" 'n"
    "\"JAR = $\\\(JAVA_HOME\\\)/bin/jar\" 'n"
    "\"JVM_OPTION = -g\" (if (not (string= jde-compile-option-encoding \"\")) (concat \" -encoding \" jde-compile-option-encoding)) 'n"
    "\"CLASSPATH = \\\"\" (if (string= (jde-build-classpath jde-global-classpath) \"\") \".\" (jde-build-classpath jde-global-classpath)) \"\\\"\" 'n"
    "\"PKG = \" jde-project-name \".jar\" 'n"
    "\"RES_EXT = properties xml\" 'n"
    "\"\" 'n"
    "\"# Java Compiler Args\" 'n"
    "\"JAVACFLAGS := -bootclasspath $\\\(JAVA_HOME\\\)/jre/lib/rt.jar \\\\\" 'n"
    "\"	-classpath $\\\(CLASSPATH\\\) \\\\\" 'n"
    "\"	-sourcepath $\\\(SRCDIR\\\) \\\\\" 'n"
    "\"	-d $\\\(OBJDIR\\\) \\\\\" 'n"
    "\"	$\\\(JVM_OPTION\\\)\" 'n"
    "\"\" 'n"
    "\"# Sources\" 'n"
    "\"SOURCES = $\\\(shell find $\\\(SRCDIR\\\) \\\\\" 'n"
    "\"	-name *.java \\\\\" 'n"
    "\"	$\\\(foreach x, $\\\(RES_EXT\\\), -o -name \\\"*.$\\\(x\\\)\\\"\\\) \\\\\" 'n"
    "\"\\\)\" 'n"
    "\"# Obj files\" 'n"
    "\"OBJS = $\\\(patsubst $\\\(SRCDIR\\\)/%, $\\\(OBJDIR\\\)/%, $\\\(patsubst %.java, %.class, $\\\(SOURCES\\\)\\\)\\\)\" 'n"
    "\"\" 'n"
    "\".PHONY: all compile jar clean rebuild\" 'n"
    "\"\" 'n"
    "\"# Default target\" 'n"
    "\"all : jar\" 'n"
    "\"\" 'n"
    "\"# Jar\" 'n"
    "\"jar : compile $\\\(PKG\\\)\" 'n"
    "\"$\\\(PKG\\\) : $\\\(OBJS\\\)\" 'n"
    "\"	$\\\(JAR\\\) cf $\\\(PKG\\\) -C $\\\(OBJDIR\\\) .\" 'n"
    "\"\" 'n"
    "\"# Compile\" 'n"
    "\"compile : $\\\(OBJDIR\\\) $\\\(OBJS\\\)\" 'n"
    "\"# Javac\" 'n"
    "\"$\\\(OBJDIR\\\)/%.class : $\\\(SRCDIR\\\)/%.java\" 'n"
    "\"	@echo compile $<\" 'n"
    "\"	@$\\\(JAVAC\\\) $\\\(JAVACFLAGS\\\) $<\" 'n"
    "\"ifneq \\\($\\\(OBJDIR\\\),$\\\(SRCDIR\\\)\\\)\" 'n"
    "\"# Resource file\" 'n"
    "\"$\\\(OBJDIR\\\)/% : $\\\(SRCDIR\\\)/%\" 'n"
    "\"	@mkdir -p $\\\(dir $@\\\)\" 'n"
    "\"	cp $< $@\" 'n"
    "\"endif\" 'n"
    "\"\" 'n"
    "\"\" 'n"
    "\"# Create obj directory\" 'n"
    "\"$\\\(OBJDIR\\\) :\" 'n"
    "\"	mkdir -p $\\\(OBJDIR\\\)\" 'n"
    "\"\" 'n"
    "\"# Clean up\" 'n"
    "\"clean :\" 'n"
    "\"	rm -fr $\\\(PKG\\\) \" 'n"
    "\"ifeq \\\($\\\(OBJDIR\\\),$\\\(SRCDIR\\\)\\\)\" 'n"
    "\"	find $\\\(OBJDIR\\\) -name *.class -exec rm {} \\\\\;\" 'n"
    "\"else\" 'n"
    "\"	rm -fr $\\\(OBJDIR\\\) \" 'n"
    "\"endif\" 'n"
    "\"\" 'n"
    "\"# Rebuild\" 'n"
    "\"rebuild : clean jar\" 'n"
    )
  "*Template for creating a Makefile for jde project.
Setting this variable defines a template instantiation command
`jde-gen-makefile', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-makefile
	    (tempo-define-template
	     "jde-makefile"
	     (jde-gen-read-template val)
	     nil
	     "insert makefile buffer."))
	  (set-default sym val)))

(defun jde-gen-makefile-buffer ()
  "Create a new Makefile buffer.
This command a makefile for jde project using template generated by `jde-gen-makefile'."
  (interactive)
  (let* ((default-directory
	   (file-name-directory
	    (if (string= jde-current-project "")
		(or (jde-find-project-file ".") (expand-file-name "./prj.el"))
	      jde-current-project)))
	 (file (read-file-name "Makefile " default-directory "Makefile")))
    (if (file-directory-p file)
	(setq file (concat file "/Makefile")))
    (when (or (not (file-exists-p file))
	      (yes-or-no-p "Makefile exist, do you want to overwrite it? "))
      (find-file file)
      (makefile-mode)
      (delete-region (point-min) (point-max))
      (jde-gen-makefile))))

(defcustom jde-gen-ant-buildfile-buffer-template
  (list
     "\"<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?>\" 'n"
     "\"<project name=\\\"\" jde-project-name \"\\\" default=\\\"compile\\\" basedir=\\\".\\\">\" 'n"
     "\"\" 'n"
     "\"  <!-- If you want use ecj compiler, uncomment the next line  -->\" 'n"
     "\"  <!--   <property name=\\\"build.compiler\\\" value=\\\"org.eclipse.jdt.core.JDTCompilerAdapter\\\"/> -->\" 'n"
     "\"\" 'n"
     "\"  <!-- set global properties for this build -->\" 'n"
     "\"  <property name=\\\"src\\\"     location=\\\"\" (or (car jde-sourcepath) \"src\") \"\\\"/>\" 'n"
     "\"  <property name=\\\"classes\\\" location=\\\"\" (if (string= jde-compile-option-directory \"\") \"classes\" jde-compile-option-directory) \"\\\"/>\" 'n"
     "\"  <property name=\\\"pkg\\\"     location=\\\"\" jde-project-name \".jar\\\"/>\" 'n"
     "\"  <property name=\\\"docs\\\"    location=\\\"docs\\\"/>\" 'n"
     "\"\" 'n"
     "\"  <property name=\\\"compile.debug\\\"       value=\\\"true\\\"/>\" 'n"
     "\"  <property name=\\\"compile.encoding\\\"    value=\\\"\" (if (not (string= jde-compile-option-encoding \"\")) jde-compile-option-encoding) \"\\\"/>\" 'n"
     "\"  <property name=\\\"compile.deprecation\\\" value=\\\"false\\\"/>\" 'n"
     "\"  <property name=\\\"compile.optimize\\\"    value=\\\"true\\\"/>\" 'n"
     "\"\" 'n"
     "\"  <path id=\\\"compile.classpath\\\">\" 'n"
     "\"    <pathelement path=\\\"\" (if (string= (jde-build-classpath jde-global-classpath) \"\") \".\" (jde-build-classpath jde-global-classpath)) \"\\\"/>\" 'n"
     "\"  </path>\" 'n"
     "\"\" 'n"
     "\"  <target name=\\\"init\\\">\" 'n"
     "\"    <mkdir dir=\\\"${classes}\\\"/>\" 'n"
     "\"    <mkdir dir=\\\"${docs}\\\"/>\" 'n"
     "\"  </target>\" 'n"
     "\"\" 'n"
     "\"  <target name=\\\"compile\\\" depends=\\\"init\\\" description=\\\"Compile the source\\\">\" 'n"
     "\"    <javac srcdir=\\\"${src}\\\"\" 'n"
     "\"           destdir=\\\"${classes}\\\"\" 'n"
     "(if (not (string= jde-compile-option-encoding \"\")) \"           encoding=\\\"${compile.encoding}\\\"\")"
     "(if (not (string= jde-compile-option-encoding \"\")) 'n)"
     "\"           debug=\\\"${compile.debug}\\\"\" 'n"
     "\"           deprecation=\\\"${compile.deprecation}\\\"\" 'n"
     "\"           optimize=\\\"${compile.optimize}\\\">\" 'n"
     "\"      <classpath refid=\\\"compile.classpath\\\"/>\" 'n"
     "\"      <!-- If you want use ecj compiler ant want setting compile options,\" 'n"
     "\"           you can uncomment the following and modify compile options\" 'n"
     "\"      -->\" 'n"
     "\"      <!--       <compilerarg  -->\" 'n"
     "\"      <!--           compiler=\\\"org.eclipse.jdt.core.JDTCompilerAdapter\\\"  -->\" 'n"
     "\"      <!--           line=\\\"-warn:+unused -Xemacs\\\"/> -->\" 'n"
     "\"    </javac>\" 'n"
     "\"  </target>\" 'n"
     "\"\" 'n"
     "\"  <target name=\\\"build\\\" depends=\\\"compile\\\"\" 'n"
     "\"          description=\\\"Generate the distribution\\\">\" 'n"
     "\"    <jar jarfile=\\\"${pkg}\\\" basedir=\\\"${classes}\\\"/>\" 'n"
     "\"  </target>\" 'n"
     "\"\" 'n"
     "\"  <target name=\\\"clean\\\" description=\\\"Clean up\\\" >\" 'n"
     "\"    <delete file=\\\"${build}/${pkg}\\\"/>\" 'n"
     "\"    <delete dir=\\\"${classes}\\\"/>\" 'n"
     "\"  </target>\" 'n"
     "\"\" 'n"
     "\"  <target name=\\\"rebuild\\\" depends=\\\"clean, build\\\" description=\\\"Rebuild\\\">\" 'n"
     "\"  </target>\" 'n"
     "\"\" 'n"
     "\"  <target name=\\\"javadoc\\\" depends=\\\"init\\\" description=\\\"Create java doc\\\">\" 'n"
     "\"    <javadoc destdir=\\\"${docs}\\\">\" 'n"
     "\"      <fileset dir=\\\"${src}\\\">\" 'n"
     "\"        <include name=\\\"**/*.java\\\"/>\" 'n"
     "\"        <!--         <exclude name=\\\"**/*Test*\\\"/> -->\" 'n"
     "\"      </fileset>\" 'n"
     "\"      <classpath refid=\\\"compile.classpath\\\"/>\" 'n"
     "\"    </javadoc>\" 'n"
     "\"  </target>\" 'n"
     "\"\" 'n"
     "\"</project>   \" 'n"
    )
  "*Template for creating a ant buildfile for jde project.
Setting this variable defines a template instantiation command
`jde-gen-ant-buildfile', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-ant-buildfile
	    (tempo-define-template
	     "jde-ant-buildfile"
	     (jde-gen-read-template val)
	     nil
	     "insert ant buildfile buffer."))
	  (set-default sym val)))

(defun jde-gen-ant-buildfile-buffer ()
  "Create a new Makefile buffer.
This command a makefile for jde project using template generated by `jde-gen-ant-buildfile'."
  (interactive)
  (let* ((default-directory
	   (file-name-directory
	    (if (string= jde-current-project "")
		(or (jde-find-project-file ".") (expand-file-name "./prj.el"))
	      jde-current-project)))
	 (jde-ant-buildfile (or (and (boundp 'jde-ant-buildfile) jde-ant-buildfile)
			     "build.xml"))
	 (file (read-file-name
		(concat jde-ant-buildfile " ")
		default-directory
		jde-ant-buildfile)))
    (if (file-directory-p file)
	(setq file (concat file "/" jde-ant-buildfile)))
    (when (or (not (file-exists-p file))
	      (yes-or-no-p "Buildfile exist, do you want to overwrite it? "))
      (find-file file)
      (delete-region (point-min) (point-max))
      (jde-gen-ant-buildfile))))


(defcustom jde-gen-buffer-templates
  (list (cons "Class" 'jde-gen-class)
	(cons "Interface" 'jde-gen-interface)
	(cons "Exception Class" 'jde-gen-exception)
	(cons "Console" 'jde-gen-console)
	(cons "Swing App" 'jde-gen-jfc-app)
	(cons "Unit Test" 'jde-junit-test-class))
  "*Specifies available autocode templates for creating buffers.
The value of this variable is an association list. The car of
each element specifies the template's title. The cdr specifies
a command that inserts the template into a buffer. See the function
`tempo-define-template' for any easy way to create a template
insertion command."
  :group 'jde-gen
  :type '(repeat
	  (cons :tag "Template"
		(string :tag "Title")
		(function :tag "Command")))
  :set '(lambda (sym val)
	  (let ((n (length val))
		(i 0))
	    (setq jde-gen-buffer-template-names (list))
	    (while (< i n)
	      (setq jde-gen-buffer-template-names
		    (append
		     jde-gen-buffer-template-names
		     (list (cons (car (nth i val)) (1+ i)))))
	      (setq i (1+ i))))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-buffer (template file)
  "Create a new Java buffer containing a code template.
This command inserts the specified template at the beginning
of the buffer."
  (interactive
   (list (completing-read "Template: " jde-gen-buffer-template-names)
	 (read-file-name "File: ")))
  (find-file file)
  (funcall (cdr (assoc template jde-gen-buffer-templates)))
  (goto-char (point-min))
  (search-forward "{")
  (backward-char 1)
  (c-indent-exp))


(defun jde-gen-lookup-and-capitalize (val)
  "If the given value (val) is the name of saved data, the data is
stripped of its prefix/suffix (see `jde-wiz-get-name') and it is
capitalized.  Otherwise, the given value is stripped and capitalized."
  (if (jde-gen-lookup-named val)
      (upcase-initials (jde-wiz-get-name (jde-gen-lookup-named val)))
    (upcase-initials (jde-wiz-get-name val))))


(defcustom jde-gen-section-comment-template
  '(
    "(p \"Comment: \" comment-line 'noinsert)"
    "'n"
    "\"// \" (s comment-line) '>'n'n'>"
    )
  "*Template for generating a section comment. Used as an introductory
comment to a source code section by code generating functions."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-section-comment
	    (tempo-define-template
	     "section comment"
	     (jde-gen-read-template val)
	     nil
	     "Insert section comment."))
	  (set-default sym val)))

(defcustom jde-gen-inner-class-template
  '(
    "(end-of-line) '& \"class \" (P \"Class name: \" class) '>"
    "\" \" (jde-gen-get-extend-class)"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " '>'n)"
    "\"{\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  nil"
    "  (jde-gen-lookup-named 'class)"
    "  nil"
    " )"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " '>'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "'>'n"
    "(jde-gen-get-interface-implementation)"
    "'>'n"

    "\"}\" '>'n'>"
    )
  "*Template that creates an empty private class at point."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (tempo-define-template "java-inner-class"
				 (jde-gen-read-template val)
				 nil
				 "Insert inner class.")
	  (defalias 'jde-gen-inner-class-internal
	    (list 'lambda (list)
		  (list 'tempo-template-java-inner-class)
		  (list 'jde-gen-insert-interface-implementation)))
	  (set-default sym val)))

(defun jde-gen-inner-class ()
  (interactive)
  (jde-gen-inner-class-internal)
  (goto-char (scan-lists (point) -1 0))
  (c-indent-exp))

(defcustom jde-gen-action-listener-template
  '(
    "'& (P \"Component name: \")"
    "\".addActionListener(\" jde-gen-method-signature-padding-2 "
    "\"new ActionListener\" jde-gen-method-signature-padding-1 \"()\" '>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " jde-gen-method-signature-padding-3"
    " 'n)"

    "\"{\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"actionPerformed\""
    "  \"ActionEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "\"}\" jde-gen-method-signature-padding-2 \");\"'>'n'>'n'>"
    )
  "*Template for generating an action listener.
Setting this variable defines a template instantiation
command, `jde-gen-action-listener', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-action-listener
	    (tempo-define-template
	     "java-action-listener"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton action listener."))
	  (set-default sym val)))

(defcustom jde-gen-window-listener-template
  '(
    "(end-of-line) '& (P \"Window name: \")"
    "\".addWindowListener(\" jde-gen-method-signature-padding-2 "
    "\"new WindowAdapter\" jde-gen-method-signature-padding-1 \"()\"'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " jde-gen-method-signature-padding-3"
    " 'n)"
    "\"{\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowActivated\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowClosed\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowClosing\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    " \"System.exit(0);\" '>'n \"}\""
    "'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowDeactivated\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowDeiconified\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowIconified\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"windowOpened\""
    "  \"WindowEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "\"}\" jde-gen-method-signature-padding-2 \");\" '>'n'>"
    )
  "*Template for generating a window listener.
Setting this variable defines a template instantiation
command, `jde-gen-window-listener', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-window-listener
	    (tempo-define-template
	     "java-window-listener"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton window listener."))
	  (set-default sym val)))



(defcustom jde-gen-mouse-listener-template
  '(
    "(end-of-line) '& (P \"Component name: \")"
    "\".addMouseListener(\" jde-gen-method-signature-padding-2 "
    "\"new MouseAdapter\" jde-gen-method-signature-padding-1 \"()\" '>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " jde-gen-method-signature-padding-3"
    " 'n)"
    "\"{\"'>'n "

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mouseClicked\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mouseEntered\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mouseExited\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mousePressed\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mouseReleased\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "\"}\" jde-gen-method-signature-padding-2 \");\"'>'n'>"
    )
  "*Template for generating a mouse listener.
Setting this variable defines a template instantiation
command, `jde-gen-mouse-listener', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-mouse-listener
	    (tempo-define-template
	     "java-mouse-listener"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton mouse listener."))
	  (set-default sym val)))

(defcustom jde-gen-mouse-motion-listener-template
  '(
    "(end-of-line) '& (P \"Component name: \")"
    "\".addMouseMotionListener(\" jde-gen-method-signature-padding-2 "
    "\"new MouseMotionAdapter\" jde-gen-method-signature-padding-1 \"()\" '>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " jde-gen-method-signature-padding-3"
    " 'n)"
    "\"{\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mouseDragged\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"mouseMoved\""
    "  \"MouseEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "\"}\" jde-gen-method-signature-padding-2 \");\"'>'n'>"
    )
  "*Template for generating a mouse listener.
Setting this variable defines a template instantiation
command, `jde-gen-mouse-motion-listener', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-mouse-motion-listener
	    (tempo-define-template
	     "java-mouse-motion-listener"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton mouse motion listener."))
	  (set-default sym val)))

(defcustom jde-gen-change-listener-template
  '(
    "'& (P \"Component name: \")"
    "\".addChangeListener(\" jde-gen-method-signature-padding-2 "
    "\"new ChangeListener\" jde-gen-method-signature-padding-1 \"()\" '>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " jde-gen-method-signature-padding-3"
    " 'n)"

    "\"{\"'>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"stateChanged\""
    "  \"ChangeEvent e\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n"

    "\"}\" jde-gen-method-signature-padding-2 \");\"'>'n'>'n'>"
    )
  "*Template for generating a change listener.
Setting this variable defines a template instantiation
command, `jde-gen-change-listener', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-change-listener
	    (tempo-define-template
	     "java-change-listener"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton change listener."))
	  (set-default sym val)))

(defcustom jde-gen-main-method-template
  '(
    "(jde-gen-save-excursion"
    " (jde-wiz-gen-method"
    "   \"public static\""
    "   \"void\""
    "   \"main\""
    "   \"String[] args\""
    "   \"\" \"\"))"
    ";; don't move point"
    "(setq tempo-marks nil)"
    )
  "Template for generating the main method.
Setting this variable defines a template instantiation
command, `jde-gen-main-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-main-method
	    (tempo-define-template
	     "main-method"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton main method."))
	  (set-default sym val)))


(defcustom  jde-gen-println
  '(
    "(beginning-of-line)"
    "\"System.out.println(\" ~ \");\" '>'n'>"
    )
  "*Template for generating a System.out.println statement."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-println
	    (tempo-define-template
	     "println"
	     (jde-gen-read-template val)
	     nil
	     "Insert println statement."))
	  (set-default sym val)))

(defcustom  jde-gen-beep
  '(
    "(end-of-line) '&"
    "\"Toolkit.getDefaultToolkit().beep();\"'>'n'>"
    )
  "*Template for generating a Toolkit.getDefaultToolkit().beep() statement."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-beep
	    (tempo-define-template
	     "beep statement"
	     (jde-gen-read-template val)
	     nil
	     "Insert beep statement."))
	  (set-default sym val)))

(defcustom  jde-gen-property-change-support
  '(
    "(end-of-line) '&"

    "\"protected PropertyChangeSupport pcs =  new PropertyChangeSupport(this);\" '>'n '>'n"


    "\"/**\" '>'n"
    "\"* Adds a PropertyChangeListener to the listener list.\" '>'n"
    "\"* The listener is registered for all properties.\" '>'n"
    "\"*\" '>'n"
    "\"* @param listener The PropertyChangeListener to be added\" '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"addPropertyChangeListener\""
    "  \"PropertyChangeListener listener\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "\"pcs.addPropertyChangeListener(listener);\" '>'n \"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Removes a PropertyChangeListener from the listener list.\" '>'n"
    "\"* This removes a PropertyChangeListener that was registered\" '>'n"
    "\"* for all properties.\" '>'n"
    "\"*\" '>'n "
    "\"* @param listener The PropertyChangeListener to be removed\" '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"removePropertyChangeListener\""
    "  \"PropertyChangeListener listener\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'>\"pcs.removePropertyChangeListener(listener);\" '>'n \"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Adds a PropertyChangeListener for a specific property.\" '>'n"
    "\"* The listener will be invoked only when a call on firePropertyChange\" '>'n"
    "\"* names that specific property.\" '>'n"
    "\"*\" '>'n"
    "\"* @param propertyName The name of the property to listen on\" '>'n"
    "\"* @param listener The PropertyChangeListener to be added\" '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"addPropertyChangeListener\""
    "  \"String propertyName, PropertyChangeListener listener\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"pcs.addPropertyChangeListener(propertyName, listener);\" '>'n"
    "\"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Removes a PropertyChangeListener for a specific property.\" '>'n"
    "\"*\" '>'n"
    "\"* @param propertyName The name of the property that was listened on\" '>'n"
    "\"* @param listener The PropertyChangeListener to be removed\"'>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"removePropertyChangeListener\""
    "  \"String propertyName, PropertyChangeListener listener\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"pcs.removePropertyChangeListener(propertyName, listener);\" '>'n"
    "\"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Reports a bound property update to any registered listeners. \" '>'n"
    "\"* No event is fired if old and new are equal and non-null.\" '>'n"
    "\"*\" '>'n"
    "\"* @param propertyName The programmatic name of the property\" '>'n"
    "\"*                     that was changed\" '>'n"
    "\"* @param oldValue The old value of the property\" '>'n"
    "\"* @param newValue The new value of the property.\" '>'n \"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"firePropertyChange\""
    "  \"String propertyName, Object oldValue, Object newValue\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"pcs.firePropertyChange(propertyName, oldValue, newValue);\" '>'n"
    "\"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Reports a bound property update to any registered listeners. \" '>'n"
    "\"* No event is fired if old and new are equal and non-null.\" '>'n"
    "\"* This is merely a convenience wrapper around the more general\" '>'n"
    "\"* firePropertyChange method that takes Object values.\" '>'n"
    "\"* No event is fired if old and new are equal and non-null.\" '>'n"
    "\"*\" '>'n"
    "\"* @param propertyName The programmatic name of the property\" '>'n"
    "\"*                     that was changed\" '>'n"
    "\"* @param oldValue The old value of the property\" '>'n"
    "\"* @param newValue The new value of the property.\" '>'n \"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"firePropertyChange\""
    "  \"String propertyName, int oldValue, int newValue\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"pcs.firePropertyChange(propertyName, oldValue, newValue);\" '>'n"
    "\"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Reports a bound property update to any registered listeners. \" '>'n"
    "\"* No event is fired if old and new are equal and non-null.\" '>'n"
    "\"* This is merely a convenience wrapper around the more general\" '>'n"
    "\"* firePropertyChange method that takes Object values.\" '>'n"
    "\"* No event is fired if old and new are equal and non-null.\" '>'n"
    "\"*\" '>'n"
    "\"* @param propertyName The programmatic name of the property\" '>'n"
    "\"*                     that was changed\" '>'n"
    "\"* @param oldValue The old value of the property\" '>'n"
    "\"* @param newValue The new value of the property.\" '>'n \"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"firePropertyChange\""
    "  \"String propertyName, boolean oldValue, boolean newValue\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"pcs.firePropertyChange(propertyName, oldValue, newValue);\" '>'n"
    "\"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Fires an existing PropertyChangeEvent to any registered listeners.\" '>'n"
    "\"* No event is fired if the given event's old and new values are\"'>'n"
    "\"* equal and non-null. \" '>'n"
    "\"*\" '>'n"
    "\"* @param evt The PropertyChangeEvent object.\" '>'n\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"firePropertyChange\""
    "  \"PropertyChangeEvent evt\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"pcs.firePropertyChange(evt);\" '>'n \"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* Checks if there are any listeners for a specific property.\" '>'n"
    "\"*\" '>'n"
    "\"* @param evt The PropertyChangeEvent object.\" '>'n"
    "\"* @return <code>true</code>if there are one or more listeners\"'>'n"
    "\"*             for the given property\" '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"boolean\""
    "  \"hasListeners\""
    "  \"String propertyName\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "'> \"return pcs.hasListeners(propertyName);\" '>'n \"}\" '>'n '>'n'>"
    )
  "*Template for adding property change support to a class."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-property-change-support
	    (tempo-define-template
	     "property change support template"
	     (jde-gen-read-template val)
	     nil
	     "Insert property change support template."))
	  (set-default sym val)))

(defcustom  jde-gen-listener-registry
  '(
    "(p \"Listener class (fully qualified): \" listenerFQN 'noinsert)"
    "(tempo-save-named 'listener-class "
    " (jde-replace-in-string (tempo-lookup-named 'listenerFQN)"
    "                    \"[^\\\\.]+\\\\.\" \"\"))"
    "(tempo-save-named 'listener-vector "
    " (concat (jde-wiz-downcase-initials (tempo-lookup-named 'listener-class))"
    "         \"s\"))"

    "(end-of-line) '&"
    "\"protected Vector \" (s listener-vector) \" = new Vector();\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* The method <CODE>add\" (s listener-class)"
    "\"</CODE> allows to \" '>'n"
    "\"* add a new <CODE>\" (s listener-class) \"</CODE>\" '>'n"
    "\"* that will be notified of incoming events.\" '>'n"
    "\"*\" '>'n"
    "\"* @see \" (s listenerFQN) '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  (concat \"add\" (tempo-lookup-named 'listener-class))"
    "  (concat (tempo-lookup-named 'listener-class) \" l\")"
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "(s listener-vector) \".addElement(l);\" '> 'n"

    "\"}\" '>'n '>'n"

    "\"/**\" '>'n"
    "\"* The method <CODE>remove\" (s listener-class)"
    "\"</CODE> allows to \" '>'n"
    "\"* remove a <CODE>\" (s listener-class) \"</CODE> that was\" '>'n"
    "\"* previously registered to be notified of incoming events.\" '>'n"
    "\"*\" '>'n"
    "\"* @see \" (s listenerFQN) '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  (concat \"remove\" (tempo-lookup-named 'listener-class))"
    "  (concat (tempo-lookup-named 'listener-class) \" l\")"
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    "(s listener-vector) \".removeElement(l);\" '> 'n"

    "\"}\" '>'n '>'n"
    )
  "*Template for adding a registry for a class of listeners."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-listener-registry
	    (tempo-define-template
	     "listener registry template"
	     (jde-gen-read-template val)
	     nil
	     "Insert listener registry template."))
	  (set-default sym val)))

(defcustom  jde-gen-event-source-fire-method-template
  '(
    "(p \"Listener class (fully qualified): \" listenerFQN 'noinsert)"
    "(p \"Listener method name: \" method-name 'noinsert)"
    "(p \"Method name: \" return-type 'noinsert)"
    "(p \"Method name: \" params 'noinsert)"
    "(tempo-save-named 'listener-class "
    " (jde-replace-in-string (tempo-lookup-named 'listenerFQN)"
    "                    \"[^\\\\.]+\\\\.\" \"\"))"
    "(tempo-save-named 'listener-vector "
    " (concat (jde-wiz-downcase-initials (tempo-lookup-named 'listener-class))"
    "         \"s\"))"
    "(tempo-save-named 'fire-method "
    " (concat \"fire\" (upcase-initials (tempo-lookup-named 'method-name))))"
    "(tempo-save-named 'param-ids "
    " (jde-gen-extract-ids-from-params (tempo-lookup-named 'params)))"

    "(end-of-line) '&"
    "\"/**\" '>'n"
    "\"* The method <CODE>\" (s fire-method)"
    "\"</CODE> is used \" '>'n"
    "\"* to call the <CODE>\" (s method-name) \"</CODE> method of\" '>'n"
    "\"* every previously registered <CODE>\" (s listener-class) \"</CODE>.\" '>'n"
    "\"*\" '>'n"
    "\"* @see \" (s listenerFQN) '>'n"
    "\"*/\" '>'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  (tempo-lookup-named 'return-type)"
    "  (tempo-lookup-named 'fire-method)"
    "  (tempo-lookup-named 'params)"
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"

    " \"for(int i = 0; i < \" (s listener-vector) \".size(); i++)\" '>"
    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"((\" (s listener-class) \")\" (s listener-vector)"
    "\".elementAt (i)).\" (s method-name) \" (\" (s param-ids) \");\" '> 'n"
    "\"}\" '>'n"

    "\"}\" '>'n '>'n"
    )
  "*Template for adding a registry for a class of listeners."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-event-source-fire-method
	    (tempo-define-template
	     "event source fire method template"
	     (jde-gen-read-template val)
	     nil
	     "Insert event source fire method template."))
	  (set-default sym val)))

;; (makunbound 'jde-gen-enity-bean-template)
(defcustom jde-gen-entity-bean-template
  '(
    "(jde-import-insert-imports-into-buffer "
    "  (list \"javax.ejb.*\""
    "        \"java.rmi.RemoteException\"))"
    "'>"

    "(jde-gen-method-signature"
    "   \"public\""
    "  \"void\""
    "  \"ejbActivate\""
    "  nil"
    "  \"RemoteException\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "'>"
    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbPassivate\""
    "  nil"
    "  \"RemoteException\""
    " )"

    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "'>"
    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbLoad\""
    "  nil"
    "  \"RemoteException\""
    " )"

    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "'>"
    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbStore\""
    "  nil"
    "  \"RemoteException\""
    " )"

    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "'>"
    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbRemove\""
    "  nil"
    "  \"RemoteException\""
    " )"

    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "'>"
    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"setEntityContext\""
    "  \"EntityContext ctx\""
    "  \"RemoteException\""
    " )"

    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "'>"
    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"unsetEntityContext\""
    "  nil"
    "  \"RemoteException\""
    " )"

    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n '>"
    )
  "*Template that creates an empty implementation of an EJB Entity Bean."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-entity-bean
	    (tempo-define-template
	     "ejb-entity-bean"
	     (jde-gen-read-template val)
	     nil
	     "Adds an implementation of the EJB Entity Bean interface to the
class in the current buffer at the current point in the buffer. Before invoking
this command,  position point at the point in the buffer where you want the first
Entity Bean method to appear. Use `jde-ejb-entity-bean-buffer' to create a complete
skeleton entity bean implementation from scratch."))
	  (set-default sym val)))


;; (makunbound 'jde-gen-session-bean-template)
(defcustom jde-gen-session-bean-template
  '(
    "(jde-import-insert-imports-into-buffer "
    "  (list \"javax.ejb.*\""
    "        \"java.rmi.RemoteException\"))"
    "'>"

    "(jde-wiz-update-implements-clause \"SessionBean\")"
    "'>"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbActivate\""
    "  nil"
    "  \"RemoteException\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbPassivate\""
    "  nil"
    "  \"RemoteException\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"ejbRemove\""
    "  nil"
    "  \"RemoteException\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"setSessionContext\""
    "  \"SessionContext ctx\""
    "  \"RemoteException\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"

    "(jde-gen-method-signature"
    "  \"public\""
    "  \"void\""
    "  \"unsetSessionContext\""
    "  nil"
    "  \"RemoteException\""
    " )"
    "'>"

    ;;we open the bracket according to k&r style or not
    "(if jde-gen-k&r "
    " ()"
    " 'n)"
    "\"{\"'>'n"
    "\"}\"'>'n 'n"
    "'>"
    )
  "*Template that creates an empty implementation of an EJB Session Bean."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-session-bean
	    (tempo-define-template
	     "ejb-session-bean"
	     (jde-gen-read-template val)
	     nil
	     "Adds an implementation of the EJB Session Bean interface to the
class in the current buffer at the current point in the buffer. Before invoking
this command,  position point at the point in the buffer where you want the first
Session Bean method to appear. Use `jde-ejb-session-bean-buffer' to create a complete
skeleton session bean implementation from scratch."))
	  (set-default sym val)))



;; (makunbound 'jde-gen-method-javadoc-comment)
(defcustom jde-gen-method-javadoc-comment "template"
  "Specifies the type of javadoc comment generated by
the `jde-gen-method-template'. The choices are

   * Template

     Uses `jde-javadoc-autodoc-at-line' function to generate
     the documentation.

   * Inherit

     Generates a javadoc comment containing only the
     javadoc (@inheritDoc) tag. This tag causes javadoc
     to copy the javadoc comment from the abstract
     method that the generated method implements but
     only if the javadoc for the abstract method is
     also being generated.

   * None

     Specifies that the method template not generate
     a javadoc comment. In this case, javadoc copies
     the comment from the abstract method if its doc
     is also being generated in the same run."
  :group 'jde-gen
  :type '(choice
	  (const :tag "Template" "template")
	  (const :tag "Inherit Tag" "inherit")
	  (const :tag "None" "none")))


;; (makunbound 'jde-gen-method-template)
(defcustom jde-gen-method-template
  '(
    "(p \"Method modifiers: \" modifiers 'noinsert)"
    "(p \"Method return type: \" return-type 'noinsert)"
    "(p \"Method name: \" name 'noinsert)"
    "(p \"Method parameters: \" parameters 'noinsert)"
    "(p \"Method exceptions: \" exceptions 'noinsert)"
    "(p \"Method body: \" default-body 'noinsert)"
    "(jde-gen-delete-preceding-whitespace) 'n 'n 'p"

    ;; Insert inherit javadoc comment if specified.
    "(if (string= jde-gen-method-javadoc-comment \"inherit\")"
    "'(l \"/*\" 'n>"
    "\"* (@inheritDoc)\" 'n>"
    "\"*/\" 'n>"
    "))"

    ;; Insert method signature.
    "(jde-gen-method-signature"
    "  (tempo-lookup-named 'modifiers)"
    "  (tempo-lookup-named 'return-type)"
    "  (tempo-lookup-named 'name)"
    "  (tempo-lookup-named 'parameters)"
    "  (tempo-lookup-named 'exceptions)"
    " )"
    "'>"

    "(jde-gen-electric-brace)"
    "(s default-body) (jde-gen-indent) 'p'n"
    "\"}\"'>'n"
    "(if (string= jde-gen-method-javadoc-comment \"template\")"
    " (progn (tempo-backward-mark) (tempo-backward-mark) (beginning-of-line)"
    "   (jde-gen-save-excursion (jde-javadoc-autodoc-at-line))"
    "   (tempo-forward-mark) nil)"
    "  (progn (tempo-backward-mark) nil))"
    "(setq tempo-marks nil) ;; prevent tempo from moving point"
    )
  "*Template for generating a skeleton method. The
`jde-gen-method-javadoc-comment' variable controls whether this
template generates a javadoc comment for the method, and, if so, what
kind of comment. Setting this variable defines a template
instantiation command, `jde-gen-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-method
	    (tempo-define-template
	     "method"
	     (jde-gen-read-template val)
	     nil
	     "Insert skeleton method."))
	  (set-default sym val)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;_* equals method generator
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defcustom jde-gen-equals-trailing-and-operators nil
  "Specifies whether the '&&' operators in a generated equals
method are added at the end of the line or at the beginning.  If
this variable is t, the operator will be added at the end of the
line, else on the next line before the comparison.  With
`jde-gen-equals-trailing-and-operators' set to nil:

    return (a == o.a)
	&& (b == o.b)
	&& (s == null ? o.s == null : s.equals(o.s));

Or, with `jde-gen-equals-trailing-and-operators' set to t:

    return (a == o.a) &&
	(b == o.b) &&
	(s == null ? o.s == null : s.equals(o.s));
"
  :group 'jde-gen
  :type 'boolean)

;;;###autoload
(defcustom jde-gen-equals-parens-around-expression nil
  "Specifies whether the generated equals expression should be
surrounded by parentheses.
With `jde-gen-equals-trailing-and-operators' set to nil:

    return ((a == o.a)
	    && (b == o.b)
	    && (s == null ? o.s == null : s.equals(o.s)));

Or, with `jde-gen-equals-trailing-and-operators' set to t:

    return ((a == o.a) &&
	    (b == o.b) &&
	    (s == null ? o.s == null : s.equals(o.s)));
"
  :group 'jde-gen
  :type 'boolean)

;;;###autoload
(defcustom jde-gen-equals-method-template
  '("'>"
   "(when jde-gen-create-javadoc"
    "'(l \"/**\" '> 'n"
    "    \" * Check if this object is equal (equivalent) to another object.\" '> 'n"
    "    \" */\" '> 'n"
    "))"
    "(jde-gen-method-signature \"public\" \"boolean\" \"equals\" \"Object obj\")"
    "(jde-gen-electric-brace)"
    "\"if (obj == this) return true;\" '> 'n"
    "\"if ((obj == null) || !getClass().equals(obj.getClass())) return false;\" '> 'n"
    "'> 'n"
    "(jde-gen-equals-return \"obj\" \"o\") '> 'n"
    "\"}\" '> 'n))"
    )
  "*Template for creating an equals method.
Setting this variable defines a template instantiation command
`jde-gen-equals-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-equals-method
	    (tempo-define-template
	     "java-equals-method"
	     (jde-gen-read-template val)
	     nil
	     "Create an equals method at the current point."))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-equals-return (&optional parm-name var-name class super-method)
  "Generate a body of an appropriate override for the
java.lang.Object#equals(Object) function. This function gets the
list of member variables from`jde-parse-get-serializable-members'.

The first optional parameter `parm-name' is the parameter name of
the Object argument of the equals function.  Default is \"obj\".

The second optional parameter `var-name' denotes the variable
name used to cast the \"obj\" argument to. The default is \"o\".

The third optional parameter `class' can be a semantic tag, which
is then used instead of the result of `semantic-current-tag'.

Example:
    class Bean {
	int a;
	long b;
	String s;
    }

Result:
    Bean o = (Bean) obj;

    return (a == o.a)
	&& (b == o.b)
	&& (s == null ? o.s == null : s.equals(o.s));

Or, with `jde-gen-equals-trailing-and-operators' set to t:
    Bean o = (Bean) obj;

    return (a == o.a) &&
	(b == o.b) &&
	(s == null ? o.s == null : s.equals(o.s));
"
  (interactive)
  (let* ((parm (or parm-name "obj"))
	 (var (or var-name "o"))
	 (class-tag (or class (semantic-current-tag)))
	 (class-name (semantic-tag-name class-tag))
	 (members (sort (jde-parse-get-serializable-members class-tag)
			'jde-parse-compare-member-types))
	 (super (car (semantic-tag-type-superclasses class-tag)))
	 (extends (and super (not (string= "Object" super)))))
    (setq super-method (or super-method "equals"))
    (list 'l '>
	  class-name " " var " = (" class-name ") " parm ";" '>'n '>'n
	  "return "
	  (if jde-gen-equals-parens-around-expression "(")
	  (if extends (list 'l (format "super.%s(" super-method) var ")")) '>
	  (cons 'l (mapcar
	      (lambda (tag)
		(let ((name (semantic-tag-name tag))
		      (type (semantic-tag-type tag)))
		  (list 'l (if extends (jde-gen-equals-add-and-operator)
			     (setq extends t) nil)
			(cond
			 ;; primitive arrays
			 ((and (string-match "\\`\\(byte\\|char\\|short\\|int\\|long\\|float\\|double\\|boolean\\)" type)
			     (or (string-match "\\[.*\\]" name) (string-match "\\[.*\\]" type)))
			  (let ((array (replace-regexp-in-string "\\[.*\\]" "" name)))
			    (concat "java.util.Arrays.equals(" array ", " var "." array ")")))

			 ;; object arrays
			 ((or (string-match "\\[.*\\]" name) (string-match "\\[.*\\]" type))
			  (let ((array (replace-regexp-in-string "\\[.*\\]" "" name)))
			    (concat "java.util.Arrays.deepEquals(" array ", " var "." array ")")))

			 ;; primitives
			 ((or (semantic-tag-of-type-p tag "byte")
			      (semantic-tag-of-type-p tag "char")
			      (semantic-tag-of-type-p tag "short")
			      (semantic-tag-of-type-p tag "int")
			      (semantic-tag-of-type-p tag "long")
			      (semantic-tag-of-type-p tag "boolean"))
			  (concat "(" name " == " var "." name ")"))

			 ;; floating point; use epsilon?
			 ((or (semantic-tag-of-type-p tag "float")
			      (semantic-tag-of-type-p tag "double"))
			  (concat "(" name " == " var "." name ")"))

			 ;; object references
			 (t (concat "(" name " == null ? " var "." name " == null : "
				    name ".equals(" var "." name "))" )))
			'>))) members))
	  (if jde-gen-equals-parens-around-expression ")") ";")))

(defun jde-gen-equals-add-and-operator ()
  (if jde-gen-equals-trailing-and-operators
      (list 'l " &&" '> 'n '>)
    (list 'l '> 'n '> "&& ")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;_* hashCode method generator
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defcustom jde-gen-hashcode-method-template
  '("'>"
    "(when jde-gen-create-javadoc"
    "'(l "
    "\"/**\" '> 'n"
    "\" * Calculate the hash code for this object.\" '> 'n"
    "\" * \" '> 'n"
    "\" * <p>The rules laid out in J. Blosh's Effective Java are used\" '> 'n"
    "\" * for the hash code calculation.</p>\" '> 'n"
    "\" * \" '> 'n"
    "\" * @return the hash code.\" '> 'n"
    "\" * \" '> 'n"
    "\" * @see java.lang.Object#hashCode\" '> 'n"
    "\" */\" '> 'n))"
    "(jde-gen-method-signature \"public\"\ \"int\" \"hashCode\" nil)"
    "(jde-gen-electric-brace)"
    "(jde-gen-hashcode-body) '> 'n"
    "\"}\" '> 'n '>" )
  "*Template for creating a hashCode method.
Setting this variable defines a template instantiation command
`jde-gen-hashcode-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-hashcode-method
	    (tempo-define-template
	     "java-hashcode-method"
	     (jde-gen-read-template val)
	     nil
	     "Create a hashCode method at the current point."))
	  (set-default sym val)))

(defvar jde-gen-hashcode-primes
  '(11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97)
    "a list of all two digit prime numbers")

(defvar jde-gen-hashcode-current-prime 0
  "a prime number")

(defun jde-gen-hashcode-next-prime ()
  "Get the next prime number"
  (let ((last jde-gen-hashcode-current-prime))
    (setq jde-gen-hashcode-current-prime (% (+ 1 last)
					    (length jde-gen-hashcode-primes)))
    (int-to-string (nth last jde-gen-hashcode-primes))))

;;;###autoload
(defun jde-gen-hashcode-body (&optional var-name class)
  "Generate a body of a hashCode function.
This function gets the list of member variables of the current
class from `jde-parse-get-serializable-members'.

The first optional parameter `var-name' denotes the variable name used
to calculate the hash code, the default is \"code\".

The second optional parameter `class' can be a semantic tag, which is
then used instead of the result of `semantic-current-tag'.
"
  (interactive)
  (let* ((var (or var-name "code"))
	 (class-tag (or class (semantic-current-tag)))
	 (members (sort (jde-parse-get-serializable-members class-tag)
			'jde-parse-compare-member-types))
	 (super (car (semantic-tag-type-superclasses class-tag)))
	 (extends (and super (not (string= "Object" super)))))
    (list 'l "int " var " = "
	  (if extends "super.hashCode()" (jde-gen-hashcode-next-prime)) ";"
	  '> 'n '> 'n
	  (cons
	   'l
	   (mapcar
	    (lambda (tag)
	      (let ((name (semantic-tag-name tag))
		    (type (semantic-tag-type tag)))
		(list 'l var " = " var " * 37 + "
		      (cond
		       ;; arrays must be first

		       ;; primitive arrays
		       ((and (string-match "\\`\\(byte\\|char\\|short\\|int\\|long\\|float\\|double\\|boolean\\)" type)
			     (or (string-match "\\[.*\\]" name) (string-match "\\[.*\\]" type)))
			(let ((array (replace-regexp-in-string "\\[.*\\]" "" name)))
			  (concat "java.util.Arrays.hashCode(" array ")")))
		       ;; object arrays
		       ((or (string-match "\\[.*\\]" name) (string-match "\\[\\]" type))
			(let ((array (replace-regexp-in-string "\\[.*\\]" "" name)))
			  (concat "java.util.Arrays.deepHashCode(" array ")")))

		       ;; smaller types
		       ((or (semantic-tag-of-type-p tag "byte")
			    (semantic-tag-of-type-p tag "char")
			    (semantic-tag-of-type-p tag "short"))
			(concat "(int) " name))
		       ;; integers
		       ((semantic-tag-of-type-p tag "int") name)
		       ((semantic-tag-of-type-p tag "long")
			(concat "(int) (" name " ^ (" name " >> 32))" ))
		       ;; booleans
		       ((semantic-tag-of-type-p tag "boolean")
			(concat "(" name " ? 1 : 0)"))

		       ;; floating point
		       ((semantic-tag-of-type-p tag "float")
			(concat "Float.floatToIntBits(" name ")" ))
		       ((semantic-tag-of-type-p tag "double")
			(concat "(int) (Double.doubleToLongBits(" name ") ^ (Double.doubleToLongBits(" name ") >> 32))" ))


		       ;; object references
		       (t
			(concat "(" name " == null ? " (jde-gen-hashcode-next-prime)
				" : " name ".hashCode())"))) ";"
		      '> 'n))) members))
	  '> 'n
	  "return " var ";")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;_* toString method generator
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defcustom jde-gen-tostring-method-template
  '("'>"
    "(when jde-gen-create-javadoc"
    "'(l "
    "\"/**\" '> 'n"
    "\" * Get a string representation of this object.\" '> 'n"
    "\" * \" '> 'n"
    "\" * @return a string representation of this object.\" '> 'n"
    "\" * \" '> 'n"
    "\" * @see java.lang.Object#toString\" '> 'n"
    "\" */\" '> 'n))"
    "(jde-gen-method-signature \"public\" \"String\" \"toString\" \"\")"
    "(jde-gen-electric-brace)"
    "(jde-gen-tostring-return) '> 'n"
    "\"}\" '>"
    )
  "*Template for creating an toString method.
Setting this variable defines a template instantiation
command `jde-gen-tostring-method', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-tostring-method
	    (tempo-define-template
	     "java-tostring-method"
	     (jde-gen-read-template val)
	     nil
	     "Create an toString method at the current point."))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-tostring-return (&optional class)
  "Generate a body of an appropriate override for the
java.lang.Object#toString function. This gets the member variables
of the current class from semantic via `semantic-current-tag'."
  (interactive)
  (let* ((class-tag (or class (semantic-current-tag)))
	 (class-name (semantic-tag-name class-tag))
	 (members (jde-parse-get-member-variables class-tag))
	 (super (car (semantic-tag-type-superclasses class-tag)))
	 (extends (and super (not (string= "Object" super))))
	 (first t)
	 (str-bld-type (if (< 1.4 (string-to-number (caar jde-jdk-registry)))
			   "StringBuilder"
			 "StringBuffer")))
    (list 'l '>
	  (format "return new %s(" str-bld-type)
	  (cons 'l (mapcar
		    (lambda (tag)
		      (let ((name (semantic-tag-name tag)))
			(prog1
			    (list 'l (concat (if (not first) ".append(")
					     "\""
					     (if (not first) ", "))
				  name "=\" + " name ")"
				  '> 'n)
			  (setq first nil))))
		    members))
	  ".toString();")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;_* Generate all object methods
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun jde-gen-object-methods ()
  "Generates an equals(), a hashCode() and a toString method."
  (interactive)
  (jde-gen-equals-method)
  (newline-and-indent)
  (jde-gen-hashcode-method)
  (newline-and-indent)
  (jde-gen-tostring-method))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;_* Exception class wizard
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defcustom jde-gen-exception-buffer-template
  (list
   "(open-line 1) (funcall jde-gen-boilerplate-function)"
   "(jde-gen-get-package-statement)"
   "(progn (require 'jde-javadoc) (jde-javadoc-insert-start-block))"
   "\" * Exception <code>\" (jde-parse-get-buffer-unqualified-class) \"</code>.\" '> 'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" * Created: \" (current-time-string) '> 'n"
   "\" \" (jde-javadoc-insert-empty-line)"
   "\" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-author-tag))"
   "\" \" (jde-gen-save-excursion (jde-javadoc-insert 'tempo-template-jde-javadoc-version-tag))"
   "\" \" (jde-javadoc-insert-end-block)"
   "\"public class \""
   "(jde-parse-get-buffer-unqualified-class)" "\" \" (jde-gen-get-extend-class)"
   "(jde-gen-electric-brace)"
   "'p'n"

   ;; Default constructor
   "'> (jde-javadoc-insert-start-block)"
    "\"* Constructs a new <code>\" (jde-parse-get-buffer-unqualified-class) \"</code> with\" '>'n"
    "\"* <code>null</code> as its detail message.\" '>'n"
    "'> (jde-javadoc-insert-end-block)"
    "(jde-gen-method-signature \"public\" nil (jde-parse-get-buffer-unqualified-class) nil)"
    "(jde-gen-electric-brace)"
    "\"}\"'>'n"
    ;; leave a blank line with no indentation
    "'n"

   ;; Constructor with message
   "'> (jde-javadoc-insert-start-block)"
    "\"* Constructs a new <code>\" (jde-parse-get-buffer-unqualified-class) \"</code> with\" '>'n"
    "\"* the specified detail message.\" '>'n"
    "'> (jde-javadoc-insert-empty-line)"
    "\"* @param message the detail message string.\" '> 'n"
    "'> (jde-javadoc-insert-end-block)"
    "(jde-gen-method-signature \"public\" nil (jde-parse-get-buffer-unqualified-class) \"String message\")"
    "(jde-gen-electric-brace)"
    "\"super(message);\" '> 'n"
    "\"}\" '> 'n"
    ;; leave a blank line with no indentation
    "'n"

   ;; Constructor with a cause
   "'> (jde-javadoc-insert-start-block)"
    "\"* Constructs a new <code>\" (jde-parse-get-buffer-unqualified-class) \"</code> with\" '>'n"
    "\"* the specified cause and a detail message of\" '> 'n"
    "\"* <code>(cause == null ? null : cause.toString())</code>\" '> 'n"
    "\"* (which typically contains the class and detail message of cause).\" '> 'n"
    "'> (jde-javadoc-insert-empty-line)"
    "\"* @param cause the causing throwable. A null value is permitted\" '> 'n"
    "\"*     and indicates that the cause is nonexistent or unknown.\" '> 'n"
    "'> (jde-javadoc-insert-end-block)"
    "(jde-gen-method-signature \"public\" nil (jde-parse-get-buffer-unqualified-class) \"Throwable cause\")"
    "(jde-gen-electric-brace)"
    "\"super(cause == null ? (String) null : cause.toString());\" '> 'n"
    "\"initCause(cause);\" '> 'n"
    "\"}\" '> 'n"
    ;; leave a blank line with no indentation
    "'n"

    ;; Constructor with a message and a cause
   "'> (jde-javadoc-insert-start-block)"
    "\"* Constructs a new <code>\" (jde-parse-get-buffer-unqualified-class) \"</code> with\" '>'n"
    "\"* the specified cause and message.\" '> 'n"
    "'> (jde-javadoc-insert-empty-line)"
    "\"* @param message the detail message string.\" '> 'n"
    "\"* @param cause the causing throwable. A null value is permitted\" '> 'n"
    "\"*     and indicates that the cause is nonexistent or unknown.\" '> 'n"
    "'> (jde-javadoc-insert-end-block)"
    "(jde-gen-method-signature \"public\" nil (jde-parse-get-buffer-unqualified-class) \"String message,Throwable cause\")"
    "(jde-gen-electric-brace)"
    "\"super(message);\" '> 'n"
    "\"initCause(cause);\" '> 'n"
    "\"}\" '> 'n"
    ;; leave a blank line with no indentation

    "\"}\" '>" "(if jde-gen-comments (concat \" // \" (jde-parse-get-buffer-unqualified-class)))"
   "'>'n")
  "*Template for a new exception class.
Setting this variable defines a template instantiation
command `jde-gen-exception', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (tempo-define-template "java-exception-buffer-template"
				 (jde-gen-read-template val)
				 nil
				 "Insert a generic Java exception buffer skeleton.")
	  (defalias 'jde-gen-exception
	    (list 'lambda (list)
		  (list 'interactive)
		  (list 'tempo-template-java-exception-buffer-template)))
	  (set-default sym val)))

;;;###autoload
(defun jde-gen-exception-buffer (file)
  "Create a new Java buffer containing an exception class of the same name.
This command inserts the template generated by `jde-gen-exception'.
It then moves the point to the location of the first method."
  (interactive "F")
  (find-file file)
  (jde-gen-exception))


(defcustom jde-gen-code-templates
  (list (cons "Get Set Pair" 'jde-gen-get-set)
	(cons "main method" 'jde-gen-main-method)
	(cons "toString Method (Apache)" 'jde-gen-tostring-method)
	(cons "Equals Method" 'jde-gen-equals-method)
	(cons "Hash Code Method" 'jde-gen-hashcode-method)
	(cons "Deep clone" 'jde-gen-deep-clone)
	(cons "Action Listener" 'jde-gen-action-listener)
	(cons "Change Listener" 'jde-gen-change-listener)
	(cons "Window Listener" 'jde-gen-window-listener)
	(cons "Mouse Listener" 'jde-gen-mouse-listener)
	(cons "Mouse Motion Listener" 'jde-gen-mouse-motion-listener)
	(cons "Inner Class" 'jde-gen-inner-class)
	(cons "println" 'jde-gen-println)
	(cons "beep" 'jde-gen-beep)
	(cons "property change support" 'jde-gen-property-change-support)
	(cons "EJB Entity Bean" 'jde-gen-entity-bean)
	(cons "EJB Session Bean" 'jde-gen-session-bean)
	)
  "*Specifies available autocode templates.
The value of this variable is an association list. The car of
each element specifies a template name. The cdr specifies
a command that inserts the template into a buffer. See the function
`tempo-define-template' for any easy way to create a template
insertion command."
  :group 'jde-gen
  :type '(repeat
	  (cons :tag "Template"
		(string :tag "Name")
		(function :tag "Command")))
  :set '(lambda (sym val)
	  (let ((n (length val))
		(i 0))
	    (setq jde-gen-template-names (list))
	    (while (< i n)
	      (setq jde-gen-template-names
		    (append
		     jde-gen-template-names
		     (list (cons (car (nth i val)) (1+ i)))))
	      (setq i (1+ i))))
	  (set-default sym val)))

(defun jde-gen-code (name)
  "Insert the code template specified by NAME at point.
The template must be one of those specified by the
variable `jde-gen-code-templates'."
  (interactive
   (list
    (completing-read "Template name: " jde-gen-template-names)))
  (funcall (cdr (assoc name jde-gen-code-templates))))



;;; Control Flow Templates
;;; Contributed by Eric D. Friedman <friedman@lmi.net>

(defvar jde-gen-abbrev-templates nil
  "List of abbreviation templates defined by
`jde-gen-define-abbrev-template'.")

(defun jde-gen-define-abbrev-template (abbrev template)
  "Defines a TEMPLATE that replaces ABBREV when you type ABBREV
in a JDE source buffer. TEMPLATE is a list of tempo template
elements. See `tempo-define-template' for information on
template elements. The resulting template is added to the
list bound to `jde-gen-abbrev-templates'. "
  (let ((template-name (concat "jde-gen-" abbrev)))
    (defalias (intern template-name)
      (tempo-define-template
       template-name
       template
       abbrev
       (format "JDE template for %s control flow abbreviation." abbrev)
       'jde-gen-abbrev-templates))))

(defcustom jde-gen-cflow-enable t
  "Enables abbreviations for Java control flow constructs."
  :group 'jde-gen
  :type 'boolean)


(defcustom jde-gen-comments nil
  "*If no-nil, use comments, else do not use comments.
with comments:

      try {

      } catch (Exception e) {

      } // end of try-catch


witout comments:

      try {

      } catch (Exception e) {

      }

Setting this variable to t, uses comments in skeletons and templates."
  :group 'jde-gen
  :type 'boolean)

;; (makunbound 'jde-gen-cflow-if)
(defcustom jde-gen-cflow-if
  '(
    "'> \"if\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"if-clause: \" clause)"
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    "'(l \" // end of if (\" (s clause) \")\"))"
    "'>'n"
    )
  "Skeleton if statement. To insert the if statement at point, type if
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode'"
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "if"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-else
  '(
    "'> \"else\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of else\"))"
    "'>'n"
    )
  "Skeleton else statement. To insert the statement at point, type else
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "else"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-if-else
  '(
    "'> \"if\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"if-clause: \" clause)"
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\" '>"
    "(if jde-gen-comments "
    " '(l \" // end of if (\" (s clause) \")\" '>'n)"
    " (if jde-gen-k&r "
    "  jde-gen-conditional-padding-3 "
    "  'n))"
    "'> \"else\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of if (\" (s clause) \") else\"))"
    "'>'n"
    )
  "Skeleton if-else statement. To insert the statement at point, type ife
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "ife"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-else-if
  '(
    "'> \"else if\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"else-if-clause: \" clause) "
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of else if (\" (s clause) \")\"))"
    "'>'n"
    )
  "Skeleton else-if statement. To insert the statement at point, type eif
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "eif"
	   (jde-gen-read-template val))
	  (set-default sym val)))

;; (makunbound 'jde-gen-cflow-while)
(defcustom jde-gen-cflow-while
  '(
    "'> \"while\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"while-clause: \" clause) "
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of while (\" (s clause) \")\"))"
    "'>'n"
    )
  "Skeleton while statement. To insert the statement at point, type while
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "while"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-for
  '(
    "'> \"for\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"for-clause: \" clause) "
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of for (\" (s clause) \")\"))"
    "'>'n"
    )
  "Skeleton for statement. To insert the statement at point, type for
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "for"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-for-i
  '(
    "'> \"for\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 \"int \" (p \"variable: \" var) "
    "\" = 0; \" (s var) \" < \" (p \"upper bound: \" upper-bound) \"; \" (s var) \"++\""
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of for (int \" (s var) \" = 0; \""
    "(s var) \" < \" (s upper-bound) \"; \" (s var) \"++)\"))"
    "'>'n"
    )
  "Skeleton for i statement. To insert the statement at point, type fori
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information.

Note: `tempo-interactive' must be set to a non-nil value to be prompted
      for variable name and upper-bounds information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "fori"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-for-iter
  '(
    "'> \"for\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 \"Iterator \" (p \"variable: \" var) "
    "\" = \" (p \"collection: \" coll) \".iterator(); \""
    "(s var) \".hasNext();\""
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r"
    "(s var) \".next();\" '>'n'>"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of for (Iterator \" (s var) \" = \" (s coll)"
    " \".iterator(); \" (s var) \".hasNext();)\"))"
    "'>'n"
    )
  "Skeleton for iterator statement. To insert the statement at point,
type foriter and then space.  Note that abbrev mode must be
enabled. See `jde-enable-abbrev-mode' for more information.

Note: `tempo-interactive' must be set to a non-nil value to be prompted
      for variable name and collection name information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "foriter"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-switch
  '(
    "'> \"switch\" jde-gen-conditional-padding-1 "
    " \"(\" jde-gen-conditional-padding-2 (p \"switch-condition: \" clause) "
    "       jde-gen-conditional-padding-2 \")\""
    "'>"
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "\"case \" (p \"first value: \" first-value) \":\"'>'n"
    "'p'n"            ;; point will end up here
    "\"break;\"'>'n"
    "\"default:\"'>'n'>"
    "\"break;\"'>'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of switch (\" (s clause) \")\"))"
    "'>'n"
    )
  "Skeleton switch statement. To insert the statement at point, type switch
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "switch"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-case
  '(
    "\"case \" (p \"value: \" value) \":\"'>'n"
    "'p'n"           ;; point will end up here
    "\"break;\"'>"
    )
  "Skeleton case statement. To insert the statement at point, type case
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "case"
	   (jde-gen-read-template val))
	  (set-default sym val)))

;; (makunbound 'jde-gen-cflow-try-catch)
(defcustom jde-gen-cflow-try-catch
  '(
    "'> \"try \""
    "(jde-gen-electric-brace)"
    "'r'n"
    "\"}\" '>"

    ;; "(if jde-gen-k&r "
    ;; "  jde-gen-conditional-padding-3 "
    ;; " 'n)"

    "(if jde-gen-comments "
    " '(l \" // end of try\" '>'n)"
    " (if jde-gen-k&r "
    "  jde-gen-conditional-padding-3 "
    "  'n))"

    "\"catch\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"catch what: \" clause) \" e\""
    "      jde-gen-conditional-padding-2 \")\" '>"
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'p'n"
    "\"}\""
    " (if jde-gen-comments "
    "	'(l \" // end of try-catch\"))"
    "'>'n"
    )
  "Skeleton try-catch statement. To insert the statement at point, type try
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "try"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-catch
  '(
    "'> \"catch\" jde-gen-conditional-padding-1  "
    "\"(\" jde-gen-conditional-padding-2 (p \"catch what: \" clause) \" e\""
    "      jde-gen-conditional-padding-2 \")\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of catch\"))"
    "'>'n"
    )
  "Skeleton catch statement. To insert the statement at point, type catch
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "catch"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-try-finally
  '(
    "'> \"try \""
    "(jde-gen-electric-brace)"
    "'r'n"
    "\"}\" '>"
    "(if jde-gen-k&r "
    "  jde-gen-conditional-padding-3 "
    " 'n)"
    "\"catch\" jde-gen-conditional-padding-1 "
    "\"(\" jde-gen-conditional-padding-2 (p \"catch what: \" clause) \" e\""
    "      jde-gen-conditional-padding-2 \")\" '>"
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\" '> "
    "(if jde-gen-k&r "
    "  jde-gen-conditional-padding-3 "
    " 'n)"
    "\"finally\" '>"
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of try-finally\"))"
    "'>'n"
    )
  "Skeleton try-catch-finally statement. To insert the statement at point, type
tryf and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "tryf"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-cflow-finally
  '(
    "'> \"finally\""
    "(jde-gen-electric-brace jde-gen-conditional-padding-3)"
    "'r'n"
    "\"}\""
    "(if jde-gen-comments "
    " '(l \" // end of finally\"))"
    "'>'n"
    )
  "Skeleton finally statement. To insert the statement at point, type finally
and then space. Note that abbrev mode must be enabled. See
`jde-enable-abbrev-mode' for more information."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (jde-gen-define-abbrev-template
	   "finally"
	   (jde-gen-read-template val))
	  (set-default sym val)))

(defcustom jde-gen-log-member-template
  '(
    "(jde-gen-insert-at-class-top)"
    "'& '>"
    "\"private static final Log log = LogFactory.getLog(\""
    "(file-name-sans-extension (file-name-nondirectory buffer-file-name))"
    "\".class);\""
    "(jde-gen-save-excursion"
    " (jde-import-insert-import '(\"org.apache.commons.logging.Log\"))"
    " (jde-import-insert-import '(\"org.apache.commons.logging.LogFactory\")))"
    )
  "*Template for creating an a commons log instance member.
Setting this variable defines a template instantiation
command `jde-gen-log-member', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-log-member
	    (tempo-define-template
	     "java-log-member"
	     (jde-gen-read-template val)
	     nil
	     "Create a log member at the current point."))
	  (set-default sym val)))

(defcustom jde-gen-log-statement-template
  '(
    "(let ((choices '(trace debug info warn error)))"
    "  (tempo-save-named 'level"
    "    (read-completing-choice \"Level\" choices t t nil nil \"debug\" nil t t)))"
    "'& '>"
    "\"if (log.is\""
    "(capitalize (tempo-lookup-named 'level))"
    "\"Enabled())\""
   "(if jde-gen-k&r "
   "\" \""
   "'> 'n)"
   "\"{\"'>'n'>"
   " \"log.\" (tempo-lookup-named 'level) \"(String.format(\\\"\" "
   "'p"
   " \"\\\"));\" "
   "'n \"}\" '>"
   "(tempo-forward-mark)"
    )
  "*Template for creating an a commons log statement.
Setting this variable defines a template instantiation
command `jde-gen-log-statement', as a side-effect."
  :group 'jde-gen
  :type '(repeat string)
  :set '(lambda (sym val)
	  (defalias 'jde-gen-log-statement
	    (tempo-define-template
	     "java-log-statement"
	     (jde-gen-read-template val)
	     nil
	     "Create an log statement method at the current point."))
	  (set-default sym val)))

(defun jde-gen-abbrev-hook ()
  "Abbreviation hook. Inserts an abbreviation template.
Abbreviation name is deleted from buffer before the template is inserted.
This function does nothing, if point is in a comment or string.
Returns t, if the template has been inserted, otherwise nil."
  (unless (jde-parse-comment-or-quoted-p)
    (let* ((abbrev-start
	    (or abbrev-start-location
		(save-excursion (re-search-backward "\\<.*\\="))))
	   (abbrev
	    (buffer-substring-no-properties abbrev-start (point)))
	   (template (assoc-string abbrev jde-gen-abbrev-templates t)))
      (if template
	  (progn
	    (delete-char (- (length abbrev)))
	    ;; Following let avoids infinite expansion.
	    ;; Infinite expansions could be caused by
	    ;; (newline) in templates.
	    ;; e.g. "else" (newline)
	    (let (local-abbrev-table)
	      (funcall (cdr template)))
	    t) ; don't insert self-inserting input character that triggered the expansion.
	(error "Template for abbreviation %s not found!" abbrev)))))

;; The following enables the hook to control the treatment of the
;; self-inserting input character that triggered the expansion.
(put 'jde-gen-abbrev-hook 'no-self-insert t)

(defun jde-gen-load-abbrev-templates ()
  "Defines jde-mode abbrevs for the control flow templates."
  (loop for template in jde-gen-abbrev-templates do
	(let ((abbrev (car template)))
	  (define-abbrev
	    local-abbrev-table
	    abbrev
	    (if (featurep 'xemacs) abbrev t) ;; Hack (see note below)
	    'jde-gen-abbrev-hook
	    0))))

;; Note: the previous function uses the following hack to address the
;; problem of preventing expansion of control flow abbreviations in
;; comments and strings. The hack defines the abbreviation such that
;; abbrev-mode doesn't replace the abbreviation.
;; If the abbreviation is not in a string or comment, the hook
;; then erases the abbreviation and replaces it with the corresponding
;; control flow expansion. If the abbreviation is in a string or
;; comment, the hook does nothing, simply leaving the abbreviation
;; as the user typed it.

(defun jde-gen-test-cflow-templates ()
   (interactive)
   (set-buffer (get-buffer-create "*jde-cflow-test*"))
   (jde-mode)
   (erase-buffer)
   (insert "public class Test {\n\n}")
   (backward-char 2)
   (loop for flags in '((t . t) (t . nil) (nil . t) (nil . nil)) do
	 (let ((jde-gen-k&r (car flags))
	       (jde-gen-comments (cdr flags)))
	   (insert (format "/**** jde-gen-comments: %S jde-gen-k&r: %S ****/\n\n"
			   jde-gen-comments jde-gen-k&r))
	   (loop for abbrev in
		 '(("if"      (clause . "true"))
		   ("else")
		   ("ife"     (clause . "true"))
		   ("eif"     (clause . "true"))
		   ("while"   (clause . "true"))
		   ("for"     (clause . "int i = 0; i < 10; i++"))
		   ("fori"    (var . "i") (upper-bound . "10"))
		   ("foriter" (var . "iter") (coll . "list"))
		   ("switch"  (clause . "digit") (first-value . "1"))
		   ("case"    (value . "2"))
		   ("try"     (clause . "Exception"))
		   ("catch"   (clause . "Exception"))
		   ("tryf"    (clause . "Exception"))
		   ("finally"))
		 do
		 (let (insertations
		       (abbrev-start-location (point)))
		   (insert (car abbrev))
		   (while (setq abbrev (cdr abbrev))
		     (setq insertations (car abbrev))
		     (tempo-save-named (car insertations) (cdr insertations)))
		   (jde-gen-abbrev-hook)
		   (goto-char (- (point-max) 2))
		   (insert "\n"))))))



(defun jde-gen-try-catch-wrapper (beg end)
  "Wrap the region from BEG to END into a try/catch block.
BEG and END are modified so the region only contains complete lines."
  (interactive "r")
  (jde-gen-generic-wrapper beg end "try" "catch"))

(defun jde-gen-try-finally-wrapper (beg end)
  "Wrap the region from BEG to END into a try/finally block.
BEG and END are modified so the region only contains complete lines."
  (interactive "r")
  (jde-gen-generic-wrapper beg end "try" "finally"))

(defun jde-gen-if-wrapper (beg end)
  "Wraps the region from beg to end into an if block."
  (interactive "r")
  (jde-gen-generic-wrapper beg end "if"))

(defun jde-gen-if-else-wrapper (beg end)
  "Wraps the region from beg to end into an if block."
  (interactive "r")
  (jde-gen-generic-wrapper beg end "if" "else"))

;;This code is a modified version of the method qflib-make-try-wrapper
(defun jde-gen-generic-wrapper (beg end expr1 &optional expr2)
  "Wrap the region from BEG to END into a EXPR1 and EXPR2 block. if EXPR2 is
nil it is omitted. BEG and END are modified so the region only contains
complete lines."
  (let ((to (make-marker))
	indent-region-function)
    (set-marker to
		(save-excursion
		  (goto-char end)
		  (if (and (bolp)
			   (not (= beg end)))
		      (point)
		    (end-of-line)
		    (1+ (point)))))
    (goto-char beg)
    (beginning-of-line)
    (insert expr1)
    (if (string= expr1 "if")
	(insert (concat jde-gen-conditional-padding-1
			"(" jde-gen-conditional-padding-2 ")")))
    (if jde-gen-k&r
	(insert " ")
      (insert "\n"))
    (insert "{\n")
    (if jde-gen-k&r
	(forward-char -1)
      (forward-char -4))
    (indent-for-tab-command)
    (indent-region (point) to nil)
    (goto-char to)
    (insert "}")
    (if expr2
	(progn
	  (if jde-gen-k&r
	      (insert jde-gen-conditional-padding-3)
	    (insert "\n"))
	  (if (string= expr2 "catch")
	      (insert (concat expr2 jde-gen-conditional-padding-1
			      "(" jde-gen-conditional-padding-2 " e"
			      jde-gen-conditional-padding-2 ")"))
	    (insert expr2))
	  (if jde-gen-k&r
	      (insert jde-gen-conditional-padding-3)
	    (insert "\n"))
	  (insert "{\n}")
	  (if jde-gen-comments
	      (insert " // end of " expr1
		      (if expr2
			  (concat "-" expr2))))))
    (insert "\n")
    (indent-region (marker-position to) (point) nil)
    (goto-char to)
    (if (string= expr1 "if")
	(search-backward (concat "(" jde-gen-conditional-padding-2 ")")))
    (if (string= expr2 "catch")
	(search-forward "("))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                           ;;
;;  Electric Return Mode                                                     ;;
;;                                                                           ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom jde-electric-return-p nil
  "Specifies whether the JDEE's electric return mode is
enabled for this session or project. This mode causes the JDEE to
match an open brace at the end of a line with a closing
brace. You can use `jde-toggle-electric-return' at any
time to enable or disable eelctric return mode."
  :group 'jde-gen
  :type 'boolean
  :set '(lambda (sym val)
	  (if (featurep 'jde)
	    (let ((curr-project
		   (with-current-buffer jde-current-buffer
		     jde-current-project)))
	      (mapc
	       (lambda (buf)
		 (with-current-buffer buf
		   (let ((key (car (read-from-string "[return]"))))
		       (if val
			   (define-key (current-local-map) key 'jde-electric-return)
			 (local-unset-key key)))))
	       (jde-get-project-source-buffers))))
	  (setq jde-electric-return-mode val)
	  (set-default sym val)))

(defcustom jde-newline-function  'newline-and-indent
  "Indent command that `jde-electric-return' calls.  Functions
that may be useful include newline, newline-and-indent,
align-newline-and-indent, or your own custom function."
  :group 'jde-gen
  :type 'function)

(defun jde-gen-embrace()
  "Match an open brace at the end of a line
with a closing brace (if required), put point on a
empty line between the braces, and indent the new lines.

So if before
you had:

   pubic void function () {
			   ^
You now have:

   pubic void function () {

   } ^

Point must be at the end of the line, or at a } character
followed by the end of the line.

If it thinks a matching close brace already exists a new one is not inserted.
Before:
   pubic void function () {
   }                       ^
After:
   pubic void function () {

   } ^"
  (interactive)
  (if (or (eq (point) (point-min))
	  (save-excursion
	    (backward-char)
	    (not (looking-at "{}?$"))))
      (newline-and-indent)
    ;; else
    (progn
      (newline-and-indent)
      (newline-and-indent)
      (when (not (looking-at "}"))
	(insert "}")
	(c-indent-command))
      (forward-line -1)
      (c-indent-command))))

(defun jde-electric-return ()
"Invokes `jde-gen-embrace' to close an open brace at the end of a line."
  (interactive)
  (if  ;; the current line ends at an open brace.
       (and
	(save-excursion
	  (re-search-backward "{\\s-*" (line-beginning-position) t))
	(looking-at "}?\\s-*$"))
      (jde-gen-embrace)
    (call-interactively jde-newline-function)))

(defvar jde-electric-return-mode nil
  "Nonnil indicates that electric return mode is on.")

(defun jde-electric-return-mode ()
  "Toggles the JDEE's electric return mode. In electric
return mode, pressing the Enter key causes the JDEE to
close open braces at the end of a line. This command enables
eletric return mode by binding `jde-electric-return' to the
Return key on your keyboard. It disables electric return mode
by rebinding the Return key to its original binding."
  (interactive)
  (when (boundp 'jde-mode-map)
    (let ((key (car (read-from-string "[return]"))))
	   (if jde-electric-return-mode
	       (local-unset-key key)
	     (define-key (current-local-map) key 'jde-electric-return))))
  (setq jde-electric-return-mode (not jde-electric-return-mode))
  (if jde-electric-return-mode
      (message "electric return mode on")
    (message "electric return mode off")))

(provide 'jde-gen)

;; End of jde-gen.el
