class Provider
  property! controller : Larimar::Controller

  def on_open(document : Larimar::TextDocument) : Nil
  end

  def on_save(document : Larimar::TextDocument) : Nil
  end

  def on_change(document : Larimar::TextDocument) : Nil
  end

  def on_close(document : Larimar::TextDocument) : Nil
  end
end

module DocumentSymbolProvider
  abstract def provide_document_symbols(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(LSProtocol::SymbolInformation)?
end

module CompletionItemProvider
  abstract def provide_completion_items(
    document : Larimar::TextDocument,
    position : LSProtocol::Position,
    token : CancellationToken?,
  ) : Array(LSProtocol::CompletionItem)?
end

module DefinitionProvider
  abstract def provide_definition(
    document : Larimar::TextDocument,
    position : LSProtocol::Position,
    token : CancellationToken?,
  ) : Array(LSProtocol::Definition)?
end

module FoldingRangeProvider
  abstract def provide_folding_ranges(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(LSProtocol::FoldingRange)?
end

module HoverProvider
  abstract def provide_hover(
    document : Larimar::TextDocument,
    position : LSProtocol::Position,
    token : CancellationToken?,
  ) : LSProtocol::Hover?
end

module InlayHintProvider
  abstract def provide_inlay_hints(
    document : Larimar::TextDocument,
    range : LSProtocol::Range,
    token : CancellationToken?,
  ) : Array(LSProtocol::InlayHint)?
end

module FormattingProvider
  abstract def provide_document_formatting_edits(
    document : Larimar::TextDocument,
    options : LSProtocol::FormattingOptions,
    token : CancellationToken?,
  ) : Array(LSProtocol::TextEdit)?
end

require "./providers/*"
