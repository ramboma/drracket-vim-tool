#lang racket/base

;; Parse and output representation of vim commands

(require racket/class
         racket/function
         racket/gui/base
         racket/match)

(provide parse-command
         (struct-out motion-command)
         (struct-out mark-command)
         (struct-out repeat-command)
         (struct-out repeat-motion)
         (struct-out replace-command)
         (struct-out goto-command))

;; A Command is one of
;;   - Symbol
;;   - (repeat-command Repeat Command)
;;   - (motion-command Operator Motion)
;;   - (mark-command Mark-Kind Char)
;;   - (replace-command Char)
;;   - (goto-command (U 'line Integer))
(struct repeat-command (repeat command))
(struct motion-command (operator motion))
(struct mark-command (kind mark))
(struct replace-command (char))
(struct goto-command (line))

;; A Repeat is an integer
;; An Operator (for a motion command) is one of
;;   (or/c 'change
;;         'delete
;;         'yank
;;         'swap-case
;;         'lowercase
;;         'uppercase
;;         'format
;;         'rot13
;;         'shift-right
;;         'shift-left)
;;
;; TODO: Operator leaves out
;;       filtering, folding, and function calls from vim
;;
;; A Motion is one of
;;   - 'word
;;   - 'sentence
;;   - 'paragraph
;;   - 'match
;;   - 'double-quote
;;   - (repeat-motion Repeat Motion)
;;     where Motion is a symbol
(struct repeat-motion (repeat motion))

;; These codes are ignored in the sense that they are skipped over
;; and they don't interrupt a command sequence.
(define ignored-codes
  (list 'shift
        'rshift
        'control
        'rcontrol
        'scroll
        'wheel-up
        'wheel-down
        'wheel-left
        'wheel-right
        'release
        'press))

;; Key-Event% (-> Key-Event%) -> Command
;; Parse a single command
(define (parse-command key *next-key)

  ;; helper that ignores ignored characters
  (define (next-key)
    (let loop ()
      (define key (*next-key))
      (define code (send key get-key-code))
      (if (memq code ignored-codes)
          (loop)
          key)))

  (define code (send key get-key-code))
  (match code
    ;; repeats
    [(? (conjoin char? char-numeric?) digit)
     (parse-repeat code next-key)]

    ;; multi-char/motion commands
    [#\d (parse-delete next-key)]
    [#\y (parse-yank next-key)]
    [#\m (parse-mark next-key 'save-mark)]
    [#\' (parse-mark next-key 'apostrophe)]
    [#\` (parse-mark next-key 'backtick)]
    [#\g (parse-global next-key)]
    [#\r #:when (not (send key get-control-down))
     (parse-replace next-key)]

    ;; insertion
    [#\a 'insert-end]
    [#\A 'insert-end-line]
    [#\i 'insert]
    [#\I 'insert-line]
    [#\O 'insert-previous-line]
    [#\o 'insert-next-line]

    ;; modes
    [#\v 'visual]
    [#\V 'visual-line]
    [#\: 'ex]

    ;; movement
    [(or #\h 'left)  'left]
    [(or #\j 'down)  'down]
    [(or #\k 'up)    'up]
    [(or #\l 'right) 'right]
    [#\f #:when (send key get-control-down)
     'next-page]
    [#\b #:when (send key get-control-down)
     'previous-page]
    [#\w     'next-word]
    [#\b     'previous-word]
    ['prior  'previous-page]
    ['next   'next-page]
    [#\space 'continue]
    [#\0     'start-of-line]
    [#\$     'end-of-line]
    [#\^     'start-of-line-content]
    [#\%     'match]
    [#\G     'end-of-file]

    ;; editing
    [#\J     'join-line]
    [#\x     'delete-at-cursor]

    ;; copy & paste & editing
    [#\D     'delete-rest]
    [#\p     'paste]
    [#\u     'undo]
    [#\r #:when (send key get-control-down)
     'redo]

    ;; search
    [#\/     'search]
    [#\n     'next-search]

    [_ #f]))

(define (parse-repeat digit next-key)
  (define (char-numeric->number x) (string->number (string x)))
  (let loop ([num (char-numeric->number digit)])
    (define event (next-key))
    (match (send event get-key-code)
      [#\G
       (goto-command (if (zero? num) 'last-line num))]
      [(? (conjoin char? char-numeric?) digit)
       (loop (+ (char-numeric->number digit) (* 10 num)))]
      [_
       (repeat-command num (parse-command event next-key))])))

(define (parse-replace next-key)
  (define char (send (next-key) get-key-code))
  (and (char? char)
       (replace-command char)))

(define (parse-delete next-key)
  (define key (next-key))
  (define code (send key get-key-code))
  (match code
    [#\d 'delete-line]
    [c
     (define motion (parse-motion key next-key))
     (and motion (motion-command 'delete motion))]))

(define (parse-yank next-key)
  (define key (next-key))
  (define code (send key get-key-code))
  (match code
    [#\y 'yank-line]
    [c
     (define motion (parse-motion key next-key))
     (and motion (motion-command 'yank motion))]))

(define (parse-global next-key)
  (define key (next-key))
  (define code (send key get-key-code))
  (match code
    [#\g 'start-of-file]
    [_   #f]))

(define (parse-mark next-key kind)
  (define key (next-key))
  (define code (send key get-key-code))
  (and (mark-char? code)
       (match kind
         ['apostrophe (mark-command 'goto-mark-line code)]
         ['backtick   (mark-command 'goto-mark-char code)]
         ['save-mark  (mark-command 'save-mark      code)])))

(define (mark-char? key)
  (and (char? key)
       (char>=? key #\a)
       (char<=? key #\z)))

(define (parse-motion first-key next-key)
  (define code (send first-key get-key-code))
  (match code
    [#\a (match (send (next-key) get-key-code)
           [#\w 'word]
           [#\p 'paragraph]
           [_    #f])]
    [#\%     'match]
    [#\"     'double-quote]
    [#\space 'right]
    [_   #f]))