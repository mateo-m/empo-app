$LOAD_PATH.unshift('lib/ruby/3.0.0/i386-mingw32') if RUBY_PLATFORM.include?('mingw')
require 'zlib'
out = ARGV[0]
scripts = Marshal.load(Zlib::Inflate.inflate(File.binread('Data/Scripts.dat')))
all = [RubyVM::InstructionSequence.load_from_binary(File.binread('Game.yarb')).disasm]
scripts.each { |b| all << RubyVM::InstructionSequence.load_from_binary(b).disasm }
File.binwrite(out, Marshal.dump(all))
puts "#{RUBY_DESCRIPTION}: #{all.size} listings"
