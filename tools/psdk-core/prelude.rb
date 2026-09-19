# End-to-end harness for the PSDK core. psdk_run loads this before
# Game.rb.
#
# It only watches. It reports input, audio and errors, and it never
# wraps Graphics.update. PSDK replaces that method from FPSBalancer
# while the game boots, and a wrapper that lands on the wrong side of
# that replacement makes the two call each other until the stack runs
# out. The driving script takes its pictures with `simctl io screenshot`
# instead, which also proves the frame reached the display.
$stdout.sync = true
$stderr.sync = true

# A released PSDK game runs `STDERR.reopen(IO::NULL)` when
# Data/Scripts.dat is present. The public GameLoader source guards that
# with `!ARGV.include?('verbose')`, but the bytecode in Edelweiss
# Chronicles has no such guard, so only this stops it. Without it, every
# error message and every backtrace goes to /dev/null.
def STDERR.reopen(*)
  self
end

# Report what LiteRGSS hands PSDK for an injected key, and what PSDK
# makes of it. The first number is the SFML key code and the second is
# the scancode. PSDK versions read different ones, and input.yml is
# written in whichever space that version uses, so seeing both is the
# only way to know a key arrived in a form the game can match.
Thread.new do
  sleep 0.05 until defined?(::Input) && ::Input.respond_to?(:press?)
  class << ::Input
    alias_method :psdk_probe_on_key_down, :on_key_down
    def on_key_down(*args)
      psdk_probe_on_key_down(*args)
      vkey, = ::Input::Keys.find { |_, v| args.any? { |a| v.include?(a) } }
      state = ::Input.instance_variable_get(:@current_state) || {}
      $stderr.puts "PSDK-KEY args=#{args.inspect} vkey=#{vkey.inspect} down=#{state[vkey]}"
      $stderr.flush
    end
  end
  $stderr.puts 'PSDK-HOOK Input'
end

# Report whether sound really plays. Without a capture device the
# playing offset is the only signal: it advances only while the driver
# pulls samples from the file. This reads the SFMLAudio objects through
# ObjectSpace, because every PSDK version keeps them somewhere else.
Thread.new do
  sleep 0.05 until defined?(::SFMLAudio)
  $stderr.puts 'PSDK-AUDIO SFMLAudio is loaded'
  loop do
    sleep 5
    report = []
    ObjectSpace.each_object(::SFMLAudio::Music) do |m|
      report << format('music@%.2fs', m.get_playing_offset) if m.playing?
    end
    ObjectSpace.each_object(::SFMLAudio::Sound) do |o|
      report << format('sound@%.2fs', o.get_playing_offset) if o.playing?
    end
    $stderr.puts "PSDK-AUDIO #{report.empty? ? 'nothing plays' : report.join(' ')}"
    $stderr.flush
  end
end

# Yuki::EXC catches every error in the game loop and shows a window that
# waits for a key. Nothing prints, and by the time the process leaves, $!
# is whatever killed the window, not the first error. Report the error as
# EXC receives it, then leave, so a run does not sit in that window until
# the test times out.
Thread.new do
  sleep 0.05 until defined?(::Yuki) && defined?(::Yuki::EXC) && ::Yuki::EXC.respond_to?(:run)
  class << ::Yuki::EXC
    def run(error, *)
      $stderr.puts "PSDK-EXC #{error.class}: #{error.message}"
      $stderr.puts Array(error.backtrace).join("\n")
      $stderr.flush
      exit!(0)
    end
  end
  $stderr.puts 'PSDK-HOOK EXC'
end

# Edelweiss Chronicles stops unless $0 is 'Game.rb' and $0.__id__ is 24.
# 24 is the first object id a 32-bit Windows Ruby 3.0 hands out, because
# OBJ_ID_INITIAL is sizeof(RVALUE). A 64-bit Ruby gives 40 or more. The
# check is the game's own, not PSDK's, so it stays here and not in the
# core. The core sets $0 itself.
#
# `def $0.__id__` raises FrozenError, so the answer comes from String
# and applies to that one instance.
class String
  def __id__
    equal?($0) ? 24 : super
  end
end

# A released game leaves through `exit!` in display_game_exception,
# which skips at_exit and prints nothing. Report the caller before the
# process goes, so a crash is not silent. A clean end stays quiet.
module Kernel
  alias psdk_orig_exit_bang exit!
  def exit!(status = false)
    unless status == 0 || status == true
      $stderr.puts "PSDK-EXIT #{status.inspect}"
      $stderr.puts caller.join("\n")
      $stderr.flush
    end
    psdk_orig_exit_bang(status)
  end
end

at_exit do
  next if $!.nil? || $!.is_a?(SystemExit)

  $stderr.puts "PSDK-ERROR #{$!.inspect}"
  $stderr.puts Array($!.backtrace).join("\n")
  $stderr.flush
end
