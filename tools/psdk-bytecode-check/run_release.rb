$stdout.sync = true
$stderr.sync = true
OUT = ENV.fetch('SNAP_DIR')
SNAP_EVERY = ENV.fetch('SNAP_EVERY', '5').to_f
RUN_FOR = ENV.fetch('RUN_FOR', '60').to_f
PRESS_FROM = ENV.fetch('PRESS_FROM', '1e9').to_f
PRESS_KEYS = ENV.fetch('PRESS_KEYS', 'A').split(',').map(&:to_sym)

module SnapFrames
  def update(*)
    r = super
    @snap_start ||= Time.now
    @snap_frames = @snap_frames.to_i + 1
    t = Time.now - @snap_start
    if t >= (@snap_next ||= SNAP_EVERY)
      @snap_next += SNAP_EVERY
      snap_to_bitmap.to_png_file(File.join(OUT, format('t%03d.png', t)))
      puts format('SNAP t=%.1f frames=%d scene=%s', t, @snap_frames, $scene.class)
    end
    exit!(0) if t > RUN_FOR
    r
  end

  def snap_elapsed = @snap_start ? Time.now - @snap_start : 0
end

# Answers true for one frame in each 1.5 s window.
module PressKeys
  def trigger?(key)
    t = Graphics.snap_elapsed
    slot = (t / 1.5).floor
    if PRESS_KEYS.include?(key) && t > PRESS_FROM && slot != @press_slot
      @press_slot = slot
      return true
    end
    super
  end
end

Thread.new do
  sleep 0.05 until defined?(Graphics) && Graphics.respond_to?(:update) && Graphics.respond_to?(:snap_to_bitmap)
  Graphics.singleton_class.prepend(SnapFrames)
  sleep 0.05 until defined?(Input) && Input.respond_to?(:trigger?)
  Input.singleton_class.prepend(PressKeys)
  puts 'hooks installed'
end

# Edelweiss exits unless $0 is 'Game.rb' and $0.__id__ is 24, the first id of 32-bit Windows Ruby 3.0.
$0 = 'Game.rb'
class String
  def __id__ = equal?($0) ? 24 : super
end
load 'Game.rb'
