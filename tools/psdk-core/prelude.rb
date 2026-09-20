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

# psdk_run takes one prelude, and the test host gives it this file. The
# core gives it runtime_prelude.rb, which holds the per-game fixes and
# the fast forward patch. Load that file first, so a test run has what
# the app runs.
load File.join(__dir__, 'Frameworks/PsdkCore.framework/runtime_prelude.rb')

# A released PSDK game runs `STDERR.reopen(IO::NULL)` when
# Data/Scripts.dat is present. The public GameLoader source guards that
# with `!ARGV.include?('verbose')`, but the bytecode in Edelweiss
# Chronicles has no such guard, so only this stops it. Without it, every
# error message and every backtrace goes to /dev/null.
def STDERR.reopen(*)
  self
end

# Report what LiteRGSS hands PSDK for an injected key, and which
# virtual keys PSDK then holds down. Input.press? is the answer the game
# itself reads, so it is the only proof a key arrived in a form the game
# matches. A guess from the numbers alone is wrong: a PSDK version reads
# the key code and another reads the scancode.
#
# Input::Keys goes out once as well. It says which number each virtual
# key answers to in this game, which is what a launcher needs to pick a
# button.
Thread.new do
  sleep 0.05 until defined?(::Input) && ::Input.respond_to?(:press?)
  $stderr.puts "PSDK-MAP #{::Input::Keys.inspect}"

  class << ::Input
    alias_method :psdk_probe_on_key_down, :on_key_down
    def on_key_down(*args)
      psdk_probe_on_key_down(*args)
      down = ::Input::Keys.keys.select { |k| ::Input.press?(k) }
      $stderr.puts "PSDK-KEY args=#{args.inspect} down=#{down.inspect}"
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

# Count the game frames that FPSBalancer runs, and report the rate.
# Graphics.frame_count counts drawn frames, so only this number shows a
# fast run. The balancer runs its block frame_to_execute times for each
# drawn frame.
$psdk_logic_frames = 0
Thread.new do
  sleep 0.05 until defined?(::Graphics::FPSBalancer)
  ::Graphics::FPSBalancer.prepend(Module.new do
    def run(&block)
      super { $psdk_logic_frames += 1; block.call }
    end
  end)
end

# Report how many updates the game gets each second. Reading Graphics from
# another thread is safe. The prelude must not wrap Graphics.update, for
# the reason at the top of this file.
Thread.new do
  sleep 0.05 until defined?(::Graphics) && ::Graphics.respond_to?(:frame_count)
  last_count = nil
  last_logic = 0
  last_time = nil
  loop do
    sleep 5
    count = ::Graphics.frame_count
    now = Time.now
    if last_count
      rate = (count - last_count) / (now - last_time)
      logic = ($psdk_logic_frames - last_logic) / (now - last_time)
      $stderr.puts format('PSDK-RATE frames=%d per_second=%.1f logic_per_second=%.1f',
                          count, rate, logic)
      $stderr.flush
    end
    last_count = count
    last_logic = $psdk_logic_frames
    last_time = now
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

# Change the window scale the way the in-game options menu does, at the
# second PSDK_SCALE names, as `<second>:<scale>`. PSDK's Options scene
# writes Graphics.screen_scale, which rebuilds the window settings and
# reloads them. Driving the setter is the same call with no menu to
# walk through.
if (plan = ENV['PSDK_SCALE']) && !plan.empty?
  second, scale = plan.split(':')
  Thread.new do
    sleep 0.05 until defined?(::Graphics) && ::Graphics.respond_to?(:screen_scale=)
    sleep second.to_f
    $stderr.puts "PSDK-SCALE setting #{scale}"
    $stderr.flush
    ::Graphics.screen_scale = scale.to_f
  end
end
