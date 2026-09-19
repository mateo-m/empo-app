require 'zlib'
win = Marshal.load(Zlib::Inflate.inflate(File.binread(ARGV[0])))
nat = Marshal.load(Zlib::Inflate.inflate(File.binread(ARGV[1])))
raise "count #{win.size} vs #{nat.size}" unless win.size == nat.size
same = diff = fail = 0
win.each_with_index do |bin, i|
  begin
    a = RubyVM::InstructionSequence.load_from_binary(bin).disasm
    b = RubyVM::InstructionSequence.load_from_binary(nat[i]).disasm
    a == b ? same += 1 : (diff += 1; warn "DIFF ##{i}" if diff < 4)
  rescue Exception => e
    fail += 1; warn "FAIL ##{i} #{e.class}: #{e.message[0,120]}" if fail < 6
  end
end
puts "scripts=#{win.size} same=#{same} diff=#{diff} fail=#{fail}"
g = RubyVM::InstructionSequence.load_from_binary(File.binread(ARGV[2]))
puts "Game.yarb loads: #{g.disasm.lines.size} lines of instructions"
