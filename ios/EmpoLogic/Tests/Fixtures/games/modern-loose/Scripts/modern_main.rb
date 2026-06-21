# modern grammar markers (need >= 3 hits for sniffer)
def foo
  bar&.baz
  case x in Integer
    y = 1
  end
  arr.filter_map { |v| v }
end
