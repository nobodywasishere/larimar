# A cancellation source creates and controls a `CancellationToken`.
class CancellationTokenSource
  @channel : Channel(Nil)

  getter token : CancellationToken

  def initialize
    @channel = Channel(Nil).new
    @token = CancellationToken.new(@channel)
  end

  # Cancels the associated token, non-blocking
  def cancel : Nil
    @channel.close
  end
end

# A cancellation token is passed to an asynchronous or long running operation to request cancellation,
# like cancelling a request for completion items because the user continued to type.
#
# To get an instance of a `CancellationToken` use a `CancellationTokenSource`.
class CancellationToken
  # :nodoc:
  def initialize(@channel : Channel(Nil))
  end

  # Checks if the token is cancelled, non-blocking
  def cancelled? : Bool
    @channel.closed?
  end

  def cancelled! : Nil
    raise CancellationException
  end
end

class CancellationException < Exception
end
