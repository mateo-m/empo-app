# Per-game compatibility code for the PSDK core. psdk_run loads this
# before Game.rb.
#
# It ships inside PsdkCore.framework, so a launcher embeds one artifact
# and carries no PSDK file of its own. Nothing here belongs in the core:
# these are things released games do, not things PSDK does.
$stdout.sync = true
$stderr.sync = true

# A released PSDK game runs `STDERR.reopen(IO::NULL)` when
# Data/Scripts.dat is present. The public GameLoader source guards that
# with `!ARGV.include?('verbose')`, but the bytecode in Edelweiss
# Chronicles has no such guard, so only this stops it. Without it, the
# launcher's log holds no error and no backtrace.
def STDERR.reopen(*)
  self
end

# Edelweiss Chronicles stops unless $0 is 'Game.rb' and $0.__id__ is 24.
# 24 is the first object id a 32-bit Windows Ruby 3.0 hands out, because
# OBJ_ID_INITIAL is sizeof(RVALUE). A 64-bit Ruby gives 40 or more. The
# check is that game's own, not PSDK's. The core sets $0 itself.
#
# `def $0.__id__` raises FrozenError, so the answer comes from String and
# applies to that one instance.
#
# ponytail: one game's check sits in every game's prelude. Split it per
# game when a second game wants a different answer.
class String
  def __id__
    equal?($0) ? 24 : super
  end
end

# A released game leaves through `exit!` in display_game_exception, which
# skips at_exit and prints nothing. Report the caller before the process
# goes, so a crash is not silent in the launcher's log. A clean end stays
# quiet.
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

# PSDK paces the game with Graphics::FPSBalancer. The balancer divides
# the real clock by 1000000 / Graphics.frame_rate, and it runs that many
# game frames. So the frame rate that the balancer reads is the only way
# to make the game go faster. The window keeps its own draw limit, and the
# balancer reads Graphics.frame_rate on each update, so a change applies
# while the game runs.
#
# PSDK defines the reader with attr_accessor, later than this file. This
# module opens Graphics first and waits for that definition, because a
# game loads its scripts from compiled bytecode, and bytecode carries no
# trace instructions, so TracePoint never reports the end of the body.
module Graphics
  class << self
    def singleton_method_added(name)
      super
      return unless name == :frame_rate
      return if @psdk_fast_forward_patch

      @psdk_fast_forward_patch = true
      psdk_base_frame_rate = method(:frame_rate)
      define_singleton_method(:frame_rate) do
        psdk_base_frame_rate.call * LiteRGSS.fast_forward_multiplier
      end
    end
  end
end
