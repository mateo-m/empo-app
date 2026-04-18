# ios_compat.rb
# Engine-level iOS compatibility layer.
# Auto-loaded before game scripts to ensure compatibility.
# Game-specific patches live in separate files (e.g. pokemon_compat.rb).

# --- Process spawning neutralization ---
# fork()/exec() are forbidden on iOS and cause immediate SIGKILL.
# Neutralize all process-spawning methods at the engine level.
module Kernel
  # Process-spawning methods are no-ops on iOS: fork/exec would be
  # killed by the sandbox and system("game.exe") only makes sense on
  # Windows. Return nil so games keep running; real exec() would
  # terminate the process but that's the entire iOS app here, so a
  # silent no-op is the safer default.
  def system(*args) nil end
  def exec(*args)   nil end
  def fork(*args)   nil end
  def spawn(*args)  nil end
  module_function :system, :exec, :fork, :spawn
end

# --- Windows environment variable stubs ---
# Many RGSS games use ENV["TEMP"] / ENV["APPDATA"] for file operations.
_tmp = "/tmp"
begin
  _tmp = Dir.tmpdir
rescue
end
ENV["TEMP"] ||= _tmp
ENV["TMP"]  ||= _tmp
ENV["APPDATA"] ||= _tmp

# --- MKXP module shim ---
# Some game preload scripts expect the MKXP module from Ancurio's
# original mkxp. mkxp-z uses "System" module instead.
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

# --- Win32 library null-stub via const_missing ---
# Win32-only library scripts (RGSS Linker, FMODEX, network loaders, etc.)
# reference constants that never get defined on iOS because DLL loading is a
# no-op (see win32_wrap.rb). Instead of adding per-library stubs, hook
# Module#const_missing so any undefined constant - top-level OR nested
# inside a partially-defined module like Berka::NetErrorErr - resolves to
# a safe stub rather than raising NameError.
#
# Two kinds of stubs are returned:
#
# 1. Constants whose name ends in Error, Err, Exception, or Failure become
#    real StandardError subclasses. This matters because games commonly
#    write `raise Berka::NetErrorErr, "msg"`; the raised exception must
#    inherit from Exception or Ruby rejects it, and if it is NullStub the
#    alert ends up showing "IOS::NullStub" as the error message.
#
# 2. Everything else becomes IOS::NullStub, which silently absorbs any
#    method call and any nested constant lookup. This covers library
#    namespaces like FmodEx, FmodEx::System, etc.
module IOS
  class NullStub
    def self.method_missing(name, *args, &block)
      self
    end

    def self.respond_to_missing?(name, include_private = false)
      true
    end

    def self.const_missing(name)
      ::Module.instance_method(:const_missing).bind(self).call(name)
    end

    def self.new(*args, &block)
      allocate
    end

    # to_s intentionally returns an empty string so that any residual
    # `"prefix: #{stub}"` formatting in game code produces clean output
    # instead of leaking the internal "IOS::NullStub" name into alerts.
    def self.to_s;    ""; end
    def self.inspect; "#<IOS::NullStub>"; end

    def method_missing(name, *args, &block)
      nil
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  # Holds the auto-generated exception-like stub classes so
  # `rescue Berka::NetErrorErr` remains stable across lookups.
  ErrorStubs = {}

  ERROR_SUFFIX_RE = /(?:Error|Err|Exception|Failure)\z/
end

class Module
  def const_missing(name)
    if name.to_s =~ ::IOS::ERROR_SUFFIX_RE
      key = [self, name]
      ::IOS::ErrorStubs[key] ||= begin
        klass = Class.new(StandardError)
        const_set(name, klass)
        klass
      end
    else
      ::IOS::NullStub
    end
  end
end

# --- Dir.chdir nil-safety ---
# Some games pass nil to Dir.chdir, which crashes Ruby.
class << Dir
  unless method_defined?(:_mkxp_orig_chdir)
    alias_method :_mkxp_orig_chdir, :chdir
  end
  def chdir(dir = nil, &block)
    return _mkxp_orig_chdir(&block) if dir.nil?
    _mkxp_orig_chdir(dir, &block)
  end
end
