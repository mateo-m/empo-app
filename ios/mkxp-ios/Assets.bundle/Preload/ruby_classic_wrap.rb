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
    def encode(*_args)
      self
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

# Encoding class doesn't exist in 1.8 either, so games referencing
# Encoding::UTF_8 etc. blow up. Route them through the NullStub from
# ios_compat.rb by NOT defining Encoding here: Object.const_missing
# will return IOS::NullStub, whose #to_s is "". But games often pass
# the result as an argument to the no-op force_encoding above, so a
# stub is not strictly required for correctness.
