;; Symbol kinds
;; array
;; boolean
;; class
;; constant
;; constructor
;; enum
;; enummember
;; event
;; field
;; file
;; function
;; interface
;; key
;; method
;; module
;; namespace
;; null
;; number
;; object
;; operator
;; package
;; property
;; string
;; struct
;; typeparameter
;; variable

(class_def
    "class" @context
    name: (_) @name) @item.class

(struct_def
    "struct" @context
    name: (_) @name) @item.struct

(method_def
    "def" @context
    ((_) @name
    "." @name)?
    name: (_) @name) @item.method

(fun_def
    "fun" @context
    name: (_) @name) @item.method

(macro_def
    "macro" @context
    name: (_) @name) @item.method

(module_def
    "module" @context
    name: (_) @name) @item.namespace

(enum_def
    "enum" @context
    name: (_) @name) @item.enum

;; TODO: enum members

(annotation_def
    "annotation" @context
    name: (_) @name) @item

(lib_def
	"lib" @context
    name: (_) @name) @item.namespace

(type_def
	"type" @context
	(constant) @name) @item.interface

(c_struct_def
	"struct" @context
    name: (_) @name) @item.struct

(union_def
	"union" @context
    name: (_) @name) @item.struct

(alias
    "alias" @context
    name: (_) @name) @item.interface

(const_assign
    lhs: (_) @name
    rhs: (_) @context) @item.constant

(type_declaration
    var: [(instance_var) (class_var)] @name
    type: (_) @context) @item.property

;; (call
;;     method: (_) @context
;;     arguments: (_) @name
;;     (#match? @context "(class_)?(getter|setter|property)[?!]?")) @item

;; (call
;;     method: (_) @context
;;     arguments: (argument_list
;;         (constant) @name)
;;     (#match? @context "record")) @item
