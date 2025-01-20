;; @class
;; @comment
;; @decorator
;; @enum
;; @enummember
;; @event
;; @function
;; @interface
;; @keyword
;; @label
;; @macro
;; @method
;; @modifier
;; @namespace
;; @number
;; @operator
;; @parameter
;; @property
;; @regexp
;; @string
;; @struct
;; @type
;; @typeparameter
;; @variable

[
  "alias"
  "annotation"
  "begin"
  "break"
  "case"
  "class"
  "def"
  "do"
  "else"
  "elsif"
  "end"
  "ensure"
  "enum"
  "extend"
  "for"
  "fun"
  "if"
  "in"
  "include"
  "lib"
  "macro"
  "module"
  "next"
  "of"
  "require"
  "rescue"
  "return"
  "select"
  "struct"
  "then"
  "type"
  "union"
  "unless"
  "until"
  "verbatim"
  "when"
  "while"
  "yield"
] @keyword

(conditional
  [
    "?"
    ":"
  ] @operator)

[
  (private)
  (protected)
  "abstract"
] @keyword

(pseudo_constant) @type

; literals
(string) @string

(symbol) @enummember

(regex
  "/" @operator) @regexp

(heredoc_content) @string

[
  (heredoc_start)
  (heredoc_end)
] @label

(string_escape_sequence) @string

[
  (integer)
  (float)
] @number

[
  (true)
  (false)
  (nil)
  (self)
] @type

(comment) @comment

; Operators and punctuation
[
  "="
  "=>"
  "->"
] @operator

(operator) @operator

[
  ","
  ";"
  "."
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @operator

(index_call
  method: (operator) @operator
  [
    "]"
    "]?"
  ] @operator)

[
  "{%"
  "%}"
  "{{"
  "}}"
] @macro

(interpolation
  "#{" @operator
  "}" @operator)

; Types
[
  (constant)
  (generic_instance_type)
  (generic_type)
] @type

(nilable_constant
  "?" @type)

(nilable_type
  "?" @type)

(annotation
  (constant) @decorator)

(method_def
  name: [
    (identifier)
    (constant)
  ] @function)

(macro_def
  name: [
    (identifier)
    (constant)
  ] @function)

(macro_var) @variable

[
  (class_var)
  (instance_var)
] @property

(underscore) @type

(pointer_type
  "*" @operator)

; function calls
(call
  method: (_) @function)

(implicit_object_call
  method: (_) @function)

;; (call
;;     method: (_) @keyword
;;     arguments: (argument_list
;;       [
;;         (type_declaration
;;           var: (_) @function)
;;         (assign
;;           lhs: (_) @function)
;;         (_) @function
;;       ])
;;     (#match? @keyword "(class_)?(getter|setter|property)[?!]?"))

;; (call
;;     method: (_) @keyword
;;     (#match? @keyword "record"))

(identifier) @variable

(param) @parameter
