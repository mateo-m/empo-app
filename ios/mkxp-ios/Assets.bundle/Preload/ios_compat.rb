# ios_compat.rb
# mkxp-ios engine compatibility layer
# Auto-loaded before game scripts to ensure compatibility

# Neutralize system()/exec()/fork() — these call fork+exec which is
# forbidden on iOS and causes an immediate crash (SIGKILL).
# Games like Pokemon Uranium use "system('Uranium')" in their Hard Reset
# script to relaunch themselves; on iOS we handle restarts via the
# session loop, not by spawning a new process.
module Kernel
  def system(*args) nil end
  def exec(*args) raise SystemExit end
  def fork(*args) nil end
  def spawn(*args) nil end
  module_function :system, :exec, :fork, :spawn
end

# Clear session-specific globals that games set and check across
# restarts. Without this, the game thinks it's a "restart" and tries
# to call system() to relaunch itself.
$game_exists = nil

# Set Windows environment variables that games expect
# Many RGSS games use ENV["TEMP"] for temporary file operations
_tmp = "/tmp"
begin
  _tmp = Dir.tmpdir
rescue
end
ENV["TEMP"] ||= _tmp
ENV["TMP"]  ||= _tmp
# Some games check APPDATA for save file locations
ENV["APPDATA"] ||= _tmp

# Provide the MKXP module that some game preload scripts expect
# (from Ancurio's original mkxp). mkxp-z uses "System" module instead.
module MKXP
  def self.zinflate(string)
    Zlib::Inflate.inflate(string)
  end

  def self.zdeflate(string, level = Zlib::DEFAULT_COMPRESSION)
    Zlib::Deflate.deflate(string, level)
  end

  def self.data_directory(*args)
    System.data_directory(*args) if defined?(System)
  end

  def self.puts(*args)
    if defined?(System)
      System.puts(*args)
    else
      Kernel.puts(*args)
    end
  end
end

# Patch Dir.chdir to handle nil gracefully (games may pass nil paths)
class << Dir
  unless method_defined?(:_mkxp_orig_chdir)
    alias_method :_mkxp_orig_chdir, :chdir
  end
  def chdir(dir = nil, &block)
    return _mkxp_orig_chdir(&block) if dir.nil?
    _mkxp_orig_chdir(dir, &block)
  end
end

# Patch RGSS objects so accessing properties on disposed objects returns
# safe defaults instead of raising RGSSError. Many Pokemon Essentials
# scripts (e.g. Mouse Input) call width/height/x/y on windows that may
# have been disposed between frames. We rescue RGSSError because some
# custom classes (e.g. pokemonLoadPanel) report disposed?=false but
# their internal native object is already freed.
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

# Null mouse shim — absorbs any method call and returns false/0/nil.
# Used to replace stale $mouse globals between game sessions. When
# Game A defines Game_Mouse and sets $mouse, then Game B runs without
# its own mouse class, $mouse would still hold Game A's instance whose
# class has been removed. This shim prevents NoMethodError crashes
# while being falsy-safe (games guard with "if $mouse" or
# "defined?($mouse) && $mouse.leftClick?").
class MkxpNullMouse
  def method_missing(*) false end
  def respond_to_missing?(*) true end
  def x; 0 end
  def y; 0 end
end
