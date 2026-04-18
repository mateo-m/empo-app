# ruby_classic_wrap.rb
# Minimal compatibility layer for Ruby 1.8 on mkxp-z.
#
# iOS ships Ruby 1.8 (see ios/mkxp-ios/project.yml -lruby18-static).
# Ruby 1.8 has no concept of string encoding, so methods that games
# written for Ruby 1.9+ expect (force_encoding, encode, encoding, ...)
# raise NoMethodError. Stub them as no-ops so scripts that sprinkle
# `.force_encoding("UTF-8")` on strings don't crash.

class String
  unless method_defined?(:force_encoding)
    def force_encoding(*_args)
      self
    end
  end

  unless method_defined?(:encode)
    # Real String#encode returns a NEW string (unlike #force_encoding
    # which mutates in place and returns self). Returning `self` would
    # alias the receiver into whatever the caller does next, so game
    # code that does `s = x.encode("UTF-8"); s.gsub!(...)` would end
    # up mutating `x`. Return a dup to preserve copy-on-encode.
    def encode(*_args)
      dup
    end
  end

  unless method_defined?(:encoding)
    def encoding
      "ASCII-8BIT"
    end
  end

  unless method_defined?(:valid_encoding?)
    def valid_encoding?
      true
    end
  end

  unless method_defined?(:b)
    def b
      dup
    end
  end
end

# The Encoding class doesn't exist in Ruby 1.8 either. Games that
# reference Encoding::UTF_8 or similar still error out with NameError.
# The String#force_encoding stub above tolerates any argument type, so
# a dedicated Encoding stub is not required in the common case.
