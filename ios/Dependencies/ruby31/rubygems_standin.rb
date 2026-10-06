# Minimal rubygems.rb stand-in shipped as part of the bundled stdlib
# (see the ruby-stdlib target in common.make).
#
# Ruby is built with --disable-rubygems: there is no gem
# installation, activation, or load-path magic on iOS, and wiring
# the full rubygems machinery into a statically-linked VM buys
# nothing. But game scripts routinely `require 'rubygems'` for one
# thing only: Gem::Version comparisons in their update checkers.
# Serve exactly that surface from the real rubygems sources
# (rubygems/version.rb + its deprecate dependency).
module Gem
  class LoadError < ::LoadError; end
end

require 'rubygems/version'
