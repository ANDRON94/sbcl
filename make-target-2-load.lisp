;;; Do warm init without compiling files.

;;; Get back to a reasonable state where all of the compiler works,
;;; as does SB-VM:HEXDUMP and MAP-ALLOCATED-OBJECTS, etc.
;;; before trying to define any more functions.
(defvar *compile-files-p* nil)
(load (merge-pathnames "src/cold/warm.lisp" *load-pathname*))

;;; Remove symbols from CL:*FEATURES* that should not be exposed to users.
(export 'sb-impl::+internal-features+ 'sb-impl)
(let* ((non-target-features
        '(;; :SB-AFTER-XC-CORE is essentially an option flag to make-host-2
          :SB-AFTER-XC-CORE
          ;; CONS-PROFILING sets the initial compiler policy which persists
          ;; into the default baseline policy. It has no relevance post-build
          ;; in as much as policy can be changed later arbitrarily.
          :CONS-PROFILING
          ;; Uses of OS-PROVIDES-DLOPEN and -DLADDR are confined to src/code/foreign.lisp
          :OS-PROVIDES-DLOPEN :OS-PROVIDES-DLADDR
          ;; more-or-less confined to serve-event, except for a test which now
          ;; detects whether COMPUTE-POLLFDS is defined and therefore testable.
          :OS-PROVIDES-POLL
          ;; The final batch of symbols is strictly for C. The prefix of
          ;; "LISP_FEATURE_" on the corresponding #define is unfortunate.
          :GCC-TLS
          :RESTORE-FS-SEGMENT-REGISTER-FROM-TLS ; only for 'src/runtime/thread.h'
          :OS-PROVIDES-BLKSIZE-T ; only for 'src/runtime/wrap.h'
          :OS-PROVIDES-PUTWC)) ; only for 'src/runtime/backtrace.c'
       (public-features
        (cons
         sb-impl::!sbcl-architecture
         '(:COMMON-LISP :SBCL :ANSI-CL :IEEE-FLOATING-POINT
           :64-BIT ; choice of word size. 32-bit if absent
           :BIG-ENDIAN :LITTLE-ENDIAN ; endianness: pick one and only one
           :BSD :UNIX :LINUX :WIN32 :DARWIN :SUNOS :ANDROID ; OS: pick one or more
           :FREEBSD :GNU-KFREEBSD :OPENBSD :NETBSD :DRAGONFLY :HAIKU :HPUX
           :MACH-O :ELF ; obj file format: pick zero or one
           ;; I would argue that this should not be exposed,
           ;; but I would also anticipate blowblack from removing it.
           :CHENEYGC :GENCGC ; GC: pick one and only one
           ;; This really should not exist. For any one architecture, if it supports
           ;; :linkage-table (which almost all do), then it should support dynamic-core,
           ;; and we should build with both, which is to say that dynamic-core is not
           ;; an additional yes/no choice.
           :SB-DYNAMIC-CORE
           ;; Can't use s-l-a-d :compression safely without it
           :SB-CORE-COMPRESSION
           ;; Features that are also in *FEATURES-POTENTIALLY-AFFECTING-FASL-FORMAT*
           ;; and would probably mess up something if made non-public,
           ;; though I don't think they should all be public.
           :MSAN
           :SB-SAFEPOINT :SB-SAFEPOINT-STRICTLY
           :SB-THREAD :SB-UNICODE
           ;; Things which (I think) at least one person has requested be kept around
           :SB-LDB
           ;; Features which are public and "potentially affect" fasl format,
           ;; though in practice they don't because every build has them.
           ;; And/or at least one person has requested be kept around.
           :SB-PACKAGE-LOCKS
           ;; unsure, I think this is for end-user consumption,
           ;; though every release of SBCL since eons ago has had local nicknames.
           :PACKAGE-LOCAL-NICKNAMES
           ;; Developer mode features. A release build will never have them,
           ;; hence it makes no difference whether they're public or not.
           :SB-FLUID :SB-DEVEL)))
       (removable-features
        (append non-target-features public-features)))
  (defconstant sb-impl:+internal-features+
    (remove-if (lambda (x) (member x removable-features)) *features*))
  (setq *features* (remove-if-not (lambda (x) (member x public-features))
                                  *features*)))

;;; There's a fair amount of machinery which is needed only at cold
;;; init time, and should be discarded before freezing the final
;;; system. We discard it by uninterning the associated symbols.
;;; Rather than using a special table of symbols to be uninterned,
;;; which might be tedious to maintain, instead we use a hack:
;;; anything whose name matches a magic character pattern is
;;; uninterned.
;;; Additionally, you can specify an arbitrary way to destroy
;;; random bootstrap stuff on per-package basis.
(defun !unintern-init-only-stuff (&aux result)
  (dolist (package (list-all-packages))
    (sb-int:awhen (find-symbol "!REMOVE-BOOTSTRAP-SYMBOLS" package)
      (funcall sb-int:it)))
  (dolist (list sb-int:*!removable-symbols*)
    (let ((package (find-package (car list))))
      (dolist (symbol (cdr list))
        (fmakunbound symbol)
        (unintern symbol package))))
  sb-kernel::
  (flet ((uninternable-p (symbol)
           (let ((name (symbol-name symbol)))
             (or (and (>= (length name) 1) (char= (char name 0) #\!))
                 (and (>= (length name) 2) (string= name "*!" :end1 2))
                 (memq symbol
                       '(sb-c::sb-pcl sb-c::sb-impl sb-c::sb-kernel
                         sb-c::sb-c sb-c::sb-int))))))
    ;; A structure constructor name, in particular !MAKE-SAETP,
    ;; can't be uninterned if referenced by a defstruct-description.
    ;; So loop over all structure classoids and clobber any
    ;; symbol that should be uninternable.
    (maphash (lambda (classoid layout)
               (when (structure-classoid-p classoid)
                 (let ((dd (layout-info layout)))
                   (setf (dd-constructors dd)
                         (delete-if (lambda (x)
                                      (and (consp x) (uninternable-p (car x))))
                                    (dd-constructors dd))))))
             (classoid-subclasses (find-classoid t)))
    ;; Todo: perform one pass, then a full GC, then a final pass to confirm
    ;; it worked. It should be an error if any uninternable symbols remain,
    ;; but at present there are about 13 other "!" symbols with referrers.
    (with-package-iterator (iter (list-all-packages) :internal :external)
      (loop (multiple-value-bind (winp symbol accessibility package) (iter)
              (declare (ignore accessibility))
              (unless winp
                (return))
              (when (uninternable-p symbol)
                ;; Uninternable symbols which are referenced by other stuff
                ;; can't disappear from the image, but we don't need to preserve
                ;; their functions, so FMAKUNBOUND them. This doesn't have
                ;; the intended effect if the function shares a code-component
                ;; with non-cold-init lambdas. Though the cold-init function is
                ;; never called post-build, it is not discarded. Also, I suspect
                ;; that the following loop should print nothing, but it does:
#|
                (sb-vm:map-allocated-objects
                  (lambda (obj type size)
                    (declare (ignore size))
                    (when (= type sb-vm:code-header-widetag)
                      (let ((name (sb-c::debug-info-name
                                   (sb-kernel:%code-debug-info obj))))
                        (when (and (stringp name) (search "COLD-INIT-FORMS" name))
                          (print obj)))))
                  :dynamic)
|#
                (fmakunbound symbol)
                (unintern symbol package))))))
  (sb-int:dohash ((k v) sb-c::*backend-parsed-vops*)
    (declare (ignore k))
    (setf (sb-c::vop-parse-body v) nil))
  result)

;;; Check for potentially bad format-control strings
(defun !scan-format-control-strings ()
  (labels ((possibly-ungood-package-reference (string)
             ;; We want to see nothing SB-package-like at all
             (or (search "sb-" string :test #'char-equal)
                 ;; catch mistakes due to imitating the way things used to be
                 (search "sb!" string :test #'char-equal)))
           (possibly-format-control (string)
             (when (find #\~ string)
               ;; very likely to be a format control if it parses OK.
               ;; Possibly not, but false positives are acceptable.
               (some (lambda (x)
                       (and (typep x 'sb-format::format-directive)
                            (eql (sb-format::directive-character x) #\/)
                            (possibly-ungood-package-reference
                             (subseq string
                                     (sb-format::directive-start x)
                                     (sb-format::directive-end x)))))
                     (ignore-errors
                      (sb-format::%tokenize-control-string
                       string 0 (length string) nil))))))
    (let (wps)
      (sb-vm:map-allocated-objects
       (lambda (obj type size)
         (declare(ignore type size))
         (when (and (stringp obj) (possibly-format-control obj))
           (push (make-weak-pointer obj) wps)))
       :all)
      (when wps
        (dolist (wp wps)
          (format t "Found string ~S~%" (weak-pointer-value wp)))
        (warn "Potential problem with format-control strings.
Please check that all strings which were not recognizable to the compiler
(as the first argument to WARN, etc.) are wrapped in SB-FORMAT:TOKENS"))
      wps)))

(progn
  ;; See the giant comment at the bottom of this file
  ;; concerning the need for this GC.
  (gc :full t)
  (!scan-format-control-strings))

;;; Either set some more package docstrings, or remove any and all docstrings
;;; that snuck in (as can happen with any file compiled in warm load)
;;; depending on presence of the :sb-doc internal feature.
(if (member :sb-doc sb-impl:+internal-features+)
  (setf (documentation (find-package "COMMON-LISP") t)
        "public: home of symbols defined by the ANSI language specification"
        (documentation (find-package "COMMON-LISP-USER") t)
        "public: the default package for user code and data"
        (documentation (find-package "KEYWORD") t)
        "public: home of keywords")
  (let ((count 0))
    (macrolet ((clear-it (place)
                 `(when ,place
                    ,(if (typep place '(cons (eql sb-int:info)))
                         `(sb-int:clear-info ,@(cdr place))
                         `(setf ,place nil))
                    (incf count))))
      ;; 1. Functions, macros, special operators
      (sb-vm:map-allocated-objects
       (lambda (obj type size)
         (declare (ignore size))
         (case type
          (#.sb-vm:code-header-widetag
           (dotimes (i (sb-kernel:code-n-entries obj))
             (let ((f (sb-kernel:%code-entry-point obj i)))
               (clear-it (sb-kernel:%simple-fun-doc f)))))
          (#.sb-vm:instance-widetag
           (when (typep obj 'class)
             (when (slot-boundp obj 'sb-pcl::%documentation)
               (clear-it (slot-value obj 'sb-pcl::%documentation)))))
          (#.sb-vm:funcallable-instance-widetag
           (when (typep obj 'standard-generic-function)
             (when (slot-boundp obj 'sb-pcl::%documentation)
               (clear-it (slot-value obj 'sb-pcl::%documentation)))))))
       :all)
      ;; 2. Variables, types, and anything else
      (do-all-symbols (s)
        (dolist (category '(:variable :type :typed-structure :setf))
          (clear-it (sb-int:info category :documentation s)))
        (clear-it (sb-int:info :random-documentation :stuff s))))
    (when (plusp count)
      (format t "~&Removed ~D doc string~:P" count)))
)

(progn
  ;; Remove source forms of compiled-to-memory lambda expressions.
  ;; The disassembler is the major culprit for retention of these,
  ;; but there are others and I don't feel like figuring out where from.
  ;; Globally declaiming EVAL-STORE-SOURCE-FORM 0 would work too,
  ;; but isn't it nice to know that the logic for storing the forms
  ;; actually works? (Yes)
  (sb-vm:map-allocated-objects
   (lambda (obj type size)
     (declare (ignore size))
     (case type
      (#.sb-vm:instance-widetag
       (when (typep obj 'sb-c::core-debug-source)
         (setf (sb-c::core-debug-source-form obj) nil)))
      (#.sb-vm:code-header-widetag
       (dotimes (i (sb-kernel:code-n-entries obj))
         (let ((fun (sb-kernel:%code-entry-point obj i)))
           (when (sb-kernel:%simple-fun-lexpr fun)
             (setf (sb-impl::%simple-fun-source fun)
                   (sb-impl::%simple-fun-doc fun))))))))
   :all)

  ;; Disable the format-control optimizer for ERROR and WARN
  ;; while preserving the argument-checking logic. Technically the optimizer is
  ;; probably ok to leave in, but the spec is ambiguous as to whether
  ;; implicit compile-time transformations on format strings is permitted.
  ;; http://www.lispworks.com/documentation/HyperSpec/Issues/iss170_w.htm
  ;; seems to imply that it is, but I would imagine that users don't expect it.
  (setq sb-c::*optimize-format-strings* nil)

  ;; Fix unknown types in globaldb
  (let ((l nil))
    (do-all-symbols (s)
      (flet ((fixup (kind)
               (multiple-value-bind (type present)
                   (sb-int:info kind :type s)
                 (when (and present
                            (sb-kernel:ctype-p type)
                            (sb-kernel:contains-unknown-type-p type))
                   (setf (sb-int:info kind :type s)
                         (sb-kernel:specifier-type (sb-kernel:type-specifier type)))
                   (push s l)))))
        (fixup :function)
        (fixup :variable)))
    (unless (sb-impl::!c-runtime-noinform-p)
      (let ((*print-pretty* nil)
            (*print-length* nil))
        (format t "~&; Fixed types: ~S~%" (sort l #'string<)))))

  ;; Unintern no-longer-needed stuff before the possible PURIFY in
  ;; SAVE-LISP-AND-DIE.
  #-(or sb-fluid sb-devel) (!unintern-init-only-stuff)

  ;; Mark interned immobile symbols so that COMPILE-FILE knows
  ;; which symbols will always be physically in immobile space.
  ;; Due to the possibility of interning a symbol that was allocated in dynamic
  ;; space, it's not the case that all interned symbols are immobile.
  ;; And we can't promise anything across reload, which makes it impossible
  ;; for x86-64 codegen to know which symbols are immediate constants.
  ;; Except that symbols which existed at SBCL build time must be.
  (do-all-symbols (symbol)
    (when (sb-kernel:immobile-space-obj-p symbol)
      (sb-kernel:set-header-data
           symbol (logior (sb-kernel:get-header-data symbol)
                          (ash 1 sb-vm::+initial-core-symbol-bit+)))))

  ;; A symbol whose INFO slot underwent any kind of manipulation
  ;; such that it now has neither properties nor globaldb info,
  ;; can have the slot set back to NIL if it wasn't already.
  (do-all-symbols (symbol)
    (when (and (sb-kernel:symbol-info symbol)
               (null (sb-kernel:symbol-info-vector symbol))
               (null (symbol-plist symbol)))
      (setf (sb-kernel:symbol-info symbol) nil)))
)

(sb-ext:gc :full t)

;;; resetting compilation policy to neutral values in preparation for
;;; SAVE-LISP-AND-DIE as final SBCL core (not in warm.lisp because
;;; SB-C::*POLICY* has file scope)
(setq sb-c::*policy* (copy-structure sb-c::**baseline-policy**))

;;; Adjust READTABLE-BASE-CHAR-PREFERENCE back to the advertised default.
(dolist (rt (list sb-impl::*standard-readtable* *debug-readtable*))
  (setf (readtable-base-char-preference rt) :symbols))
;;; Change the internal constructor's default too.
(let ((dsd sb-kernel::(find 'sb-impl::%readtable-string-preference
                            (dd-slots (find-defstruct-description 'readtable))
                            :key #'dsd-name)))
  (funcall #'(setf slot-value) 'character dsd 'sb-kernel::default))

;;; The system is complete now, all standard functions are
;;; defined.
;;; The call to CTYPE-OF-CACHE-CLEAR is probably redundant.
;;; SAVE-LISP-AND-DIE calls DEINIT which calls DROP-ALL-HASH-CACHES.
(sb-kernel::ctype-of-cache-clear)

;;; In case there is xref data for internals, repack it here to
;;; achieve a more compact encoding.
;;;
;;; However, repacking changes
;;; SB-C::**MOST-COMMON-XREF-NAMES-BY-{INDEX,NAME}** thereby changing
;;; the interpretation of xref data written into and loaded from
;;; fasls. Since fasls should be compatible between images originating
;;; from the same SBCL build, REPACK-XREF is of no use after the
;;; target image has been built.
(when (member :sb-xref-for-internals sb-impl:+internal-features+)
  (sb-c::repack-xref :verbose 1))
(fmakunbound 'sb-c::repack-xref)

(progn
  (load (merge-pathnames "src/code/shaketree" *load-pathname*))
  (sb-impl::shake-packages
   ;; Development mode: retain all symbols with any system-related properties
   #+sb-devel
   (lambda (symbol accessibility)
     (declare (ignore accessibility))
     (or (sb-kernel:symbol-info symbol)
         (and (boundp symbol) (not (keywordp symbol)))))
   ;; Release mode: retain all symbols satisfying this intricate test
   #-sb-devel
   (lambda (symbol accessibility)
     (case (symbol-package symbol)
      (#.(find-package "SB-VM")
       (or (eq accessibility :external)
           ;; overapproximate what we need for contribs and tests
           (member symbol '(sb-vm::map-referencing-objects
                            sb-vm::map-stack-references
                            sb-vm::thread-profile-data-slot
                            sb-vm::thread-alloc-region-slot
                            sb-vm::primitive-object-size
                            ;; need this for defining a vop which
                            ;; tests the x86-64 allocation profiler
                            sb-vm::pseudo-atomic
                            ;; Naughty outside-world code uses these.
                            #+x86-64 sb-vm::reg-in-size
                            sb-vm::thread-control-stack-start-slot))
           (search "-OFFSET" (string symbol))
           (search "-TN" (string symbol))))
      ((#.(find-package "SB-C")
        #.(find-package "SB-ASSEM")
        #.(find-package "SB-DISASSEM")
        #.(find-package "SB-IMPL")
        #.(find-package "SB-PRETTY")
        #.(find-package "SB-KERNEL"))
       ;; Assume all and only external symbols must be retained
       (eq accessibility :external))
      (#.(find-package "SB-FASL")
       ;; Retain +BACKEND-FASL-FILE-IMPLEMENTATION+ and +FASL-FILE-VERSION+
       ;; (and anything else otherwise reachable)
       (and (eq accessibility :external)
            (constantp symbol)))
      (#.(find-package "SB-BIGNUM")
       ;; There are 2 important external symbols for sb-gmp.
       ;; Other externals can disappear.
       (member symbol '(sb-bignum:%allocate-bignum
                        sb-bignum:make-small-bignum)))
      (t
       ;; By default, retain any symbol with any attachments
       (or (sb-kernel:symbol-info symbol)
           (and (boundp symbol) (not (keywordp symbol)))))))
   :verbose nil :print nil)
  (unintern 'sb-impl::shake-packages 'sb-impl))

;;; Use historical (stupid) behavior for storing pathname namestrings
;;; in fasls.
(setq sb-c::*name-context-file-path-selector* 'truename)

;;; Lock internal packages
(dolist (p (list-all-packages))
  (unless (member p (mapcar #'find-package '("KEYWORD" "CL-USER")))
    (sb-ext:lock-package p)))

;;; Clean up stray symbols from the CL-USER package.
(with-package-iterator (iter "CL-USER" :internal :external)
  (loop (multiple-value-bind (winp symbol) (iter)
          (if winp (unintern symbol "CL-USER") (return)))))

(setq sb-c:*compile-to-memory-space* :auto)
(when (find-package "SB-INTERPRETER") (setq sb-ext:*evaluator-mode* :interpret))
;; folding doesn't actually do anything unless the backend supports it,
;; but the interface exists no matter what.
(sb-ext:fold-identical-code :aggressive t :preserve-docstrings t)

;; See comments in 'readtable.lisp'
(setf (readtable-base-char-preference *readtable*) :symbols)

#+sb-devel
(sb-impl::%enter-new-nicknames (find-package :cl) '("SB-XC" "CL"))
"done with warm.lisp, about to SAVE-LISP-AND-DIE"

#|
This is the actual "name" of a toplevel code component that gets dumped to fasl
when compiling src/pcl/boot. Not only does it contain a format control string in
its raw representation, this is a complete and utter waste of time to dump.
We really ought to try a LOT harder not to produce such garbage metadata:

* (progn (terpri)
   (write (sb-c::compiled-debug-fun-toplevel-name
           (elt (sb-c::compiled-debug-info-fun-map *cdi*) 0))
          :level nil :length nil))

(SB-C::TOP-LEVEL-FORM
 (LABELS ((WARN-PARSE (SPECIALIZER &OPTIONAL CONDITION)
            (STYLE-WARN "~@<Cannot parse specializer ~S in ~S~@[: ~A~].~@:>"
                        SPECIALIZER # CONDITION))
          (WARN-FIND (CONDITION NAME PROTO-GENERIC-FUNCTION PROTO-METHOD)
            (WARN CONDITION :FORMAT-CONTROL
                  #<(SIMPLE-BASE-STRING
                     228) ~@<Cannot find type for specializer ~
                  ~/sb-ext:print-symbol-with-prefix/ when executing ~S ~
                  for a ~/sb-impl:print-type-specifier/ of a ~
                  ~/sb-imp... {1003A2BC8F}>
                  :FORMAT-ARGUMENTS #))
          (CLASS-NAME-TYPE-SPECIFIER
              (NAME PROTO-GENERIC-FUNCTION PROTO-METHOD &OPTIONAL #)
            (LET #
              #)))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/SYMBOL
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (LET (#)
       (WHEN SPECIALIZER #)))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/T
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (LET (#)
       (WHEN SPECIALIZER #)))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/CLASS-EQ-SPECIALIZER
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (SPECIALIZER-TYPE-SPECIFIER PROTO-GENERIC-FUNCTION PROTO-METHOD
      (SPECIALIZER-CLASS SPECIALIZER)))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/EQL-SPECIALIZER
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (DECLARE (IGNORE PROTO-GENERIC-FUNCTION PROTO-METHOD))
     `(EQL SB-IMPL::COMMA))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/STRUCTURE-CLASS
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (DECLARE (IGNORE PROTO-GENERIC-FUNCTION PROTO-METHOD))
     (CLASS-NAME SPECIALIZER))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/SYSTEM-CLASS
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (DECLARE (IGNORE PROTO-GENERIC-FUNCTION PROTO-METHOD))
     (CLASS-NAME SPECIALIZER))
   (DEFUN REAL-SPECIALIZER-TYPE-SPECIFIER/CLASS
          (PROTO-GENERIC-FUNCTION PROTO-METHOD SPECIALIZER)
     (LET (#)
       (WHEN # #)))))
|#
