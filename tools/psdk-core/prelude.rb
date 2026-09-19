# End-to-end harness for the PSDK core. psdk_run loads this before
# Game.rb.
#
# It writes a PNG every SNAP_EVERY seconds, prints the current scene,
# and leaves after RUN_FOR seconds. A released game never returns from
# its own loop, so a run without a time limit never ends.
$stdout.sync = true
$stderr.sync = true

SNAP_DIR = ENV.fetch('PSDK_SNAP_DIR', File.join(Dir.pwd, '..', 'snaps'))
SNAP_EVERY = ENV.fetch('PSDK_SNAP_EVERY', '5').to_f
RUN_FOR = ENV.fetch('PSDK_RUN_FOR', '90').to_f

Dir.mkdir(SNAP_DIR) unless Dir.exist?(SNAP_DIR)

module SnapFrames
  def update(*)
    result = super
    @snap_start ||= Time.now
    @snap_frames = @snap_frames.to_i + 1
    elapsed = Time.now - @snap_start
    if elapsed >= (@snap_next ||= SNAP_EVERY)
      @snap_next += SNAP_EVERY
      snap_to_bitmap.to_png_file(File.join(SNAP_DIR, format('t%03d.png', elapsed)))
      puts format('PSDK-SNAP t=%.1f frames=%d scene=%s', elapsed, @snap_frames, $scene.class)
    end
    if elapsed > RUN_FOR
      puts format('PSDK-DONE t=%.1f frames=%d scene=%s', elapsed, @snap_frames, $scene.class)
      exit!(0)
    end
    result
  end
end

Thread.new do
  sleep 0.05 until defined?(Graphics) && Graphics.respond_to?(:snap_to_bitmap)
  Graphics.singleton_class.prepend(SnapFrames)
  puts 'PSDK-HOOK Graphics'
end

# Edelweiss Chronicles stops unless $0 is 'Game.rb' and $0.__id__ is 24.
# 24 is the first object id a 32-bit Windows Ruby 3.0 hands out, because
# OBJ_ID_INITIAL is sizeof(RVALUE). A 64-bit Ruby gives 40 or more. The
# check is the game's own, not PSDK's, so it stays here and not in the
# core.
#
# `def $0.__id__` raises FrozenError, so the answer comes from String
# and applies to that one instance.
$0 = 'Game.rb'
class String
  def __id__
    equal?($0) ? 24 : super
  end
end
