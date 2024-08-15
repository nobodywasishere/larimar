class Larimar::Parser
  module AST
    abstract class Node
      include JSON::Serializable

      property parent : Node?

      macro inherited
        getter node : String = {{ @type.name.stringify.split("::").last }}
      end
    end

    class Nop < Node
      def initialize(@parent = nil)
      end
    end

    class Expressions < Node
      getter children : Array(Node)

      def initialize(@children, @parent = nil)
      end
    end

    class Parenthesis < Node
      getter lparen_token : Token
      getter expressions : Node
      getter rparen_token : Token

      def initialize(@lparen_token, @expressions, @rparen_token)
      end
    end

    class Begin < Node
      getter begin_token : Token
      getter children : Array(Node)?
      getter end_token : Token

      def initialize(@begin_token, @children, @end_token, @parent = nil)
      end
    end

    class NilLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class BoolLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class NumberLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class CharLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class StringLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class SymbolLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class ArrayLiteral < Node
      getter left_bracket : Token
      getter elements : Array(Tuple(Node, Token))?
      getter last_element : Node?
      getter right_bracket : Token?
      getter of_token : Token?
      getter type_name : Node?

      def initialize(
        @left_bracket, @elements, @last_element, @right_bracket,
        @of_token, @type_name, @parent = nil
      )
      end
    end

    class RangeLiteral < Node
      getter from : Node
      getter dots : Token
      getter to : Node

      def initialize(@from, @dots, @to, @parent = nil)
      end
    end

    class RegexLiteral < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class SpecialVar < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class Var < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class InstanceVar < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class ClassVar < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class TypeDeclaration < Node
      getter name : Node
      getter colon_token : Token
      getter type_name : Node
      getter equals_token : Token?
      getter value : Node?

      def initialize(@name, @colon_token, @type_name, @equals_token, @value)
      end
    end

    class Path < Node
      getter start_colon : Token?
      getter names : Array(Token)

      def initialize(@start_colon, @names, @parent = nil)
      end
    end

    class ClassDef < Node
      getter abstract_keyword : Token?
      getter class_keyword : Token
      getter name : Node
      getter super_arrow : Token?
      getter super_name : Node?
      getter body : Node
      getter end_token : Token

      def initialize(
        @abstract_keyword, @class_keyword, @name, @super_arrow, @super_name,
        @body, @end_token, @parent = nil
      )
      end
    end

    class ModuleDef < Node
      getter module_keyword : Token
      getter name : Node
      getter body : Node
      getter end_token : Token

      def initialize(@module_keyword, @name, @body, @end_token)
      end
    end

    class Self < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class Or < Node
      getter left : Node
      getter operator : Token
      getter right : Node

      def initialize(@left, @operator, @right, @parent = nil)
      end
    end

    class And < Node
      getter left : Node
      getter operator : Token
      getter right : Node

      def initialize(@left, @operator, @right, @parent = nil)
      end
    end

    class Call < Node
      getter obj : Node
      getter dot : Token?
      getter name : Token
      getter lparen : Token?
      getter args : Array(Node)
      getter rparen : Token?

      def initialize(@obj, @dot, @name, @lparen, @args, @rparen, @parent = nil)
      end

      def self.new(obj : Node, name : Token, arg : Node, parent : Node? = nil)
        new(obj, nil, name, nil, [arg] of Node, nil, parent: parent)
      end

      def self.new(obj : Node, name : Token, parent : Node? = nil)
        new(obj, nil, name, nil, [] of Node, nil, parent: parent)
      end
    end

    class Not < Node
      getter mark : Token
      getter expression : Node

      def initialize(@expression, @mark, @parent = nil)
      end
    end

    class Ternary < Node
      getter condition : Node
      getter question : Token
      getter true_case : Node
      getter colon : Token
      getter false_case : Node

      def initialize(@condition, @question, @true_case, @colon, @false_case)
      end
    end

    class Yield < Node
      getter with_token : Token?
      getter scope : Node?
      getter yield_token : Token
      getter lparen : Token?
      getter args : Array(Node)
      getter rparen : Token?

      def initialize(@with_token, @scope, @yield_token, @lparen, @args, @rparen)
      end
    end

    class Error < Node
      getter token : Token

      def initialize(@token, @parent = nil)
      end
    end

    class Def < Node
      getter abstract_token : Token?
      getter def_token : Token
      getter receiver : Node?
      getter receiver_dot : Token?
      getter name : Token?
      getter equals : Token?
      getter args : Array(Node)?
      getter return_colon : Token?
      getter return_type : Node?
      getter body : Node?
      getter end_token : Token?

      def initialize(
        @abstract_token, @def_token, @receiver, @receiver_dot,
        @name, @equals, @args, @return_colon, @return_type,
        @body, @end_token
      )
      end
    end

    class Union < Node
      getter types : Array(Tuple(Node, Token))
      getter last_type : Node

      def initialize(@types, @last_type)
      end
    end

    class Require < Node
      getter require_token : Token
      getter require_str : Token

      def initialize(@require_token, @require_str)
      end
    end

    class AnnotationDef < Node
      getter annotation_token : Token
      getter name : Node
      getter annotation_end : Token

      def initialize(@annotation_token, @name, @annotation_end)
      end
    end

    class Annotation < Node
      getter at_lsquare_token : Token
      getter name : Node
      getter rsquare_token : Token

      def initialize(@at_lsquare_token, @name, @rsquare_token)
      end
    end

    class Alias < Node
      getter alias_token : Token
      getter name : Node
      getter equals_token : Token
      getter value : Node

      def initialize(@alias_token, @name, @equals_token, @value)
      end
    end

    class Case < Node
      getter case_token : Token
      getter condition : Node?
      getter when_expressions : Array(Node)?
      getter else_node : Else?
      getter end_token : Token

      def initialize(@case_token, @condition, @when_expressions, @else_node, @end_token)
      end
    end

    class Select < Node
      getter select_token : Token
      getter when_expressions : Array(Node)?
      getter else_node : Else?
      getter end_token : Token

      def initialize(@select_token, @when_expressions, @else_node, @end_token)
      end
    end

    class When < Node
      getter when_token : Token
      getter when_conditions : Array(Tuple(Node, Token))
      getter last_condition : Node
      getter then_token : Token?
      getter expressions : Node

      def initialize(@when_token, @when_conditions, @last_condition, @then_token, @expressions)
      end
    end

    class Else < Node
      getter else_token : Token
      getter expressions : Node

      def initialize(@else_token, @expressions)
      end
    end
  end
end
