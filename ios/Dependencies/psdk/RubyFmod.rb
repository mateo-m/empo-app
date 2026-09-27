# PSDK games from December 2019 to about March 2021 play sound only through
# FMOD, a closed-source Windows library. Their GameLoader requires RubyFmod,
# and without FMOD their Audio module plays nothing. This file gives them the
# FMOD calls that module makes, on top of SFMLAudio.
#
# A channel is one SFMLAudio::Music. FMOD counts time in DSP clock ticks at
# the mixer rate, and the game builds fades and the BGM pause under an ME
# from that clock, so the clock here is the monotonic time at RATE ticks a
# second. Audio.update calls System.update once a frame, and that applies
# the fades and the delays.
module FMOD
  class Error < StandardError
    attr_reader :hr

    def initialize(message = 'FMOD error', hr = 0)
      super(message)
      @hr = hr
    end
  end

  module INIT
    NORMAL = 0
  end

  module MODE
    LOOP_OFF = 0x1
    LOOP_NORMAL = 0x2
    FMOD_2D = 0x8
    CREATESTREAM = 0x80
    OPENMEMORY = 0x800
  end

  module TIMEUNIT
    MS = 0x1
    PCM = 0x2
  end

  # The game sends the byte count and a MIDI sound bank here. SFML reads
  # neither.
  class SoundExInfo
    def initialize(*); end
  end

  module System
    RATE = 48_000
    @channels = []
    @lock = Mutex.new
    @origin = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class << self
      def init(*); end

      def close
        channels.each(&:stop)
      end

      def update
        channels.each(&:psdk_update)
        @lock.synchronize { @channels.reject!(&:psdk_done?) }
      end

      def channels
        @lock.synchronize { @channels.dup }
      end

      def dsp_clock
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @origin) * RATE).to_i
      end

      def getSoftwareFormat
        [RATE, 0, 0]
      end

      def createSound(data_or_filename, mode, _info = nil)
        data = mode & MODE::OPENMEMORY == 0 ? File.binread(data_or_filename) : data_or_filename
        Sound.new(data, mode)
      rescue SystemCallError => e
        raise Error.new(e.message, 23)
      end
      alias createStream createSound

      def playSound(sound, paused)
        channel = Channel.new(sound, paused)
        @lock.synchronize { @channels << channel }
        channel
      end
    end
  end

  class Sound
    attr_reader :data, :mode, :rate, :loop_points

    def initialize(data, mode)
      probe = SFMLAudio::Music.new
      raise Error.new('SFML cannot read this audio file', 25) unless probe.open_from_memory(data)

      @data = data
      @mode = mode
      @rate = probe.get_sample_rate
      @duration = probe.get_duration
    end

    def getLength(unit)
      unit == TIMEUNIT::PCM ? (@duration * @rate).to_i : (@duration * 1000).to_i
    end

    # The game reads the LOOPSTART and LOOPLENGTH sample counts from Ogg
    # comments (NAME=value) or from ID3 TXXX frames (NAME\0value). It asks
    # for the TXXX frames only when the plain names fail, so the plain names
    # find both forms.
    def getTag(name, _index)
      value = @data[/#{name}[=\0](\d+)/n, 1] if name.start_with?('LOOP')
      raise Error.new("No #{name} tag", 34) unless value

      [0, 0, value]
    end

    def setLoopPoints(start, _start_unit, stop, _stop_unit)
      @loop_points = [start, stop]
    end

    # FMOD stops every channel of a sound when the sound is released, and
    # Audio.se_stop relies on it.
    def release
      System.channels.each { |channel| channel.stop if channel.sound.equal?(self) }
    end
  end

  class Channel
    attr_reader :sound

    def initialize(sound, paused)
      @sound = sound
      @music = SFMLAudio::Music.new
      @music.open_from_memory(sound.data)
      @music.set_loop(sound.mode & MODE::LOOP_NORMAL != 0)
      if (points = sound.loop_points)
        start, stop = points
        @music.set_loop_points(start.fdiv(sound.rate), (stop - start).fdiv(sound.rate))
      end
      @volume = 1.0
      @fade_points = []
      @delay_start = 0
      @delay_end = 0
      @paused = paused
      psdk_update
    end

    def setVolume(volume)
      @volume = volume
      psdk_update
    end

    def setPitch(pitch)
      @music.set_pitch(pitch)
    end

    def setPaused(paused)
      @paused = paused
      psdk_update
    end

    def setVolumeRamp(*); end

    def getDSPClock
      clock = System.dsp_clock
      [clock, clock]
    end

    # FMOD holds the channel silent before the start clock and after the
    # end clock. An end clock of 0 means no end.
    def setDelay(start_clock, end_clock, _stop_channels)
      @delay_start = start_clock
      @delay_end = end_clock
      psdk_update
    end

    def addFadePoint(clock, volume)
      @fade_points << [clock, volume]
      @fade_points.sort_by!(&:first)
    end

    def getPosition(unit)
      offset = @music.get_playing_offset
      unit == TIMEUNIT::PCM ? (offset * @sound.rate).to_i : (offset * 1000).to_i
    end

    def setPosition(position, unit)
      @music.set_playing_offset(unit == TIMEUNIT::PCM ? position.fdiv(@sound.rate) : position / 1000.0)
    end

    # FMOD says a paused channel is still playing.
    def isPlaying
      !@done
    end

    def stop
      @music.stop
      @done = true
    end

    def psdk_done?
      @done
    end

    def psdk_update
      return if @done

      clock = System.dsp_clock
      @music.set_volume(@volume * fade_volume(clock) * 100)
      audible = !@paused && clock >= @delay_start && (@delay_end == 0 || clock < @delay_end)
      if !audible
        @music.pause if @music.playing?
      elsif @started && @music.stopped?
        @done = true
      elsif !@music.playing?
        @music.play
        @started = true
      end
    end

    private

    def fade_volume(clock)
      return 1.0 if @fade_points.empty?

      after = @fade_points.index { |point_clock, _| point_clock > clock }
      return @fade_points.last.last unless after
      return @fade_points.first.last if after == 0

      (from_clock, from), (to_clock, to) = @fade_points[after - 1], @fade_points[after]
      from + (to - from) * (clock - from_clock).fdiv(to_clock - from_clock)
    end
  end
end
