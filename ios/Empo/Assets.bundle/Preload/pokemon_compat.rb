# pokemon_compat.rb
# Compatibility patches for Pokemon Essentials / Pokemon fangames.
# Separated from ios_compat.rb to keep engine-generic code clean.

# --- Uranium hard-reset prevention ---
# Pokemon Uranium checks $game_exists on startup and calls
# system('Uranium') + exit to relaunch itself. On iOS, system() is
# neutralized (see ios_compat.rb), but we also clear the flag so the
# hard-reset code path is never reached.
$game_exists = nil

# --- Disposed RGSS object safety patches ---
# Pokemon Essentials scripts (e.g. Mouse Input, pokemonLoadPanel)
# access properties on disposed Sprites/Windows/Viewports between
# frames. Some custom classes report disposed?=false but their
# internal native C++ object is already freed, raising RGSSError.
#
# We wrap property accessors to return safe defaults instead of
# crashing. These patches must re-apply every session because
# mriBindingInit() re-registers native methods, overwriting our
# wrappers.
_disposed_safe_zero = [:x, :y, :z, :ox, :oy, :width, :height,
                        :opacity, :back_opacity, :contents_opacity]
_disposed_safe_false = [:visible]

[Sprite, Window, Viewport, Plane, Tilemap].each do |klass|
  _disposed_safe_zero.each do |meth|
    next unless klass.method_defined?(meth)
    orig = :"_mkxp_orig_#{meth}"
    # Always re-alias: mriBindingInit re-registers native methods each
    # session, overwriting our wrapper. We must re-alias and re-wrap.
    klass.send(:alias_method, orig, meth)
    klass.send(:define_method, meth) do
      return 0 if disposed?
      begin
        send(orig)
      rescue RGSSError
        0
      end
    end
  end

  _disposed_safe_false.each do |meth|
    next unless klass.method_defined?(meth)
    orig = :"_mkxp_orig_#{meth}"
    klass.send(:alias_method, orig, meth)
    klass.send(:define_method, meth) do
      return false if disposed?
      begin
        send(orig)
      rescue RGSSError
        false
      end
    end
  end
end

# --- Null mouse shim ---
# Pokemon Essentials games set $mouse = Game_Mouse.new. Between
# sessions, constant cleanup removes Game_Mouse but $mouse still
# holds an orphaned instance. Setting $mouse = nil doesn't work
# because defined?($mouse) still returns "global-variable" in
# Ruby 1.8.
#
# MkxpNullMouse absorbs any method call, returning false/0/nil.
# The C++ cleanup code (binding-mri.cpp) pre-creates an instance
# and assigns it to $mouse before constant removal.
class MkxpNullMouse
  def method_missing(*) false end
  def respond_to_missing?(*) true end
  def x; 0 end
  def y; 0 end
end
