class Sample
  BIG = 12345678901234567890123
  MID = 3_000_000_000
  NEG = -5
  NEGBIG = -(2**40)
  F = 3.14159
  R = (1..10)
  RX = /ab+c/i
  C = 2i
  Q = 3r
  def opt(a, b = 2, c = -7, *rest, k:, j: 5, z: NEG, **kw, &blk)
    [a, b, c, rest, k, j, z, kw]
  end
  def loop_sum(n)
    s = 0
    i = 0
    while i < n
      s += i
      i += 1
    end
    s
  end
  def safe
    yield
  rescue ZeroDivisionError => e
    "rescued #{e.class}"
  ensure
    @done = true
  end
  def strs = ["é".encoding.name, :sym, "x".frozen?, %w[a b], { a: 1, 'b' => 2.5 }]
  def cs(x)
    case x
    when 1, 2 then :low
    when 1000000000000 then :huge
    when "s" then :str
    else :other
    end
  end
end
s = Sample.new
p s.opt(1, k: 3)
p s.opt(1, 9, 8, 7, k: 3, j: 4, q: 1)
p s.loop_sum(1000)
p s.safe { 1 / 0 }
p s.strs
p [s.cs(2), s.cs(1000000000000), s.cs("s"), s.cs(nil)]
p [Sample::BIG, Sample::MID, Sample::NEG, Sample::NEGBIG, Sample::F, Sample::R, Sample::RX, Sample::C, Sample::Q]
p [true, false, nil, 1.5e300, -0.25, 2**62, -(2**31), 2**31 - 1, 2**30, -(2**30) - 1]
