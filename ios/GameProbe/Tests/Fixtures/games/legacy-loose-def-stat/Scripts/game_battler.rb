# RGSS2 names the defense stat "def". Each of these lines matched the
# endless-def token before the sniffer required the name on the same
# line, and three matches tagged Visions & Voices as modern Ruby.
class Game_Battler
  def def
    n = [[base_def + @def_plus, 1].max, 999].min
    return n
  end
end

class Window_Status
  def draw_parameters(x, y)
    parameter_name = Vocab::def
    parameter_value = actor.def
    value = @actor.def
    new_value = @new_def
  end
end
