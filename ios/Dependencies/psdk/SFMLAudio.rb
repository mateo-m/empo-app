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
#
# The reference extension has no setVolume either, only set_volume, so that
# line raised NoMethodError on Windows as well. Nobody met it there, because
# a Windows build finds RubyFmod and runs the FMOD branch, where setVolume
# with 0 to 1 is right. PSDK carried the line in releases 26.16 to 26.20 and
# dropped it in 26.21, so a game built from a later release needs no patch.
module SFMLAudio
  module FmodVolume
    def setVolume(volume)
      set_volume(volume * 100)
    end
  end

  Music.include(FmodVolume)
  Sound.include(FmodVolume)
end
