# ios_compat.rb
# mkxp-ios engine compatibility layer
# Auto-loaded before game scripts to ensure compatibility

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
