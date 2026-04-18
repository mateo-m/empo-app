# Pokemon Essentials input fix
# Adapted from JoiPlay (https://github.com/joiplay/android-mkxp)
#
# Pokemon Essentials games override the Input module with custom
# implementations that use Win32API.GetAsyncKeyState for key reading.
# This bypasses mkxp's native Input system and breaks touch controls.
#
# This script redirects all Input methods back to the j-prefixed native
# C-level methods (jupdate, jpress?, etc.) which can't be overridden by
# Ruby scripts. It runs as a postload (after game scripts define their
# overrides, before Main starts the game loop).

if !$PokemonSystem.nil?
  module Input
    def self.update
      self.jupdate
    end

    def self.press?(button)
      return self.jpress?(button)
    end

    def self.trigger?(button)
      return self.jtrigger?(button)
    end

    def self.repeat?(button)
      return self.jrepeat?(button)
    end

    def self.dir4
      return self.jdir4
    end

    def self.dir8
      return self.jdir8
    end

    def self.pressex?(key)
      return self.jpressex?(key)
    end

    def self.triggerex?(key)
      return self.jtriggerex?(key)
    end

    def self.repeatex?(key)
      return self.jrepeatex?(key)
    end

    def self.repeatcount(key)
      return 0
    end

    def self.updateKeyState(key)
    end
  end
end
