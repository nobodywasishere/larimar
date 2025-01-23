module Crystal
  class Visitor
    property cancellation_token : CancellationToken?
  end

  class ASTNode
    def accept(visitor)
      visitor.cancellation_token.try(&.cancelled!)

      previous_def
    end
  end
end
