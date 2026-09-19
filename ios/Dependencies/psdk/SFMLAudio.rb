# PSDK requires this file to load the SFMLAudio extension. The classes
# are already in the binary, so the file only has to exist. It also
# carries one compatibility patch.
#
# PSDK's SFML branch calls one FMOD method it never replaced:
#
#   def adjust_volume(channel, volume)
#     return unless channel
#     channel.setVolume(volume / 100.0)
#   end
#
# in scripts/00000 Dependencies/00400 Patch_Ajouts_LiteRGSS/
# 00700 Audio___Fmod.rb, line 688 of the SFML branch. FMOD takes 0 to 1
# and SFML takes 0 to 100, so the name and the range both need the
# change. Every other call in that branch already uses the SFML names.
module SFMLAudio
  module FmodVolume
    def setVolume(volume)
      set_volume(volume * 100)
    end
  end

  Music.include(FmodVolume)
  Sound.include(FmodVolume)
end
