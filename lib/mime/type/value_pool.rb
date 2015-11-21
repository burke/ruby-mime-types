MIME::Type::ValuePool = Hash.new { |h, k| #:nodoc:
  begin
    k = k.dup
  rescue TypeError
    k
  else
    k.freeze
  end

  h[k] = k
}
