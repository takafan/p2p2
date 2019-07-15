
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "p2p2/version"

Gem::Specification.new do |spec|
  spec.name          = "p2p2"
  spec.version       = P2p2::VERSION
  spec.authors       = ["takafan"]
  spec.email         = ["qqtakafan@gmail.com"]

  spec.summary       = %q{p2p}
  spec.description   = %q{内网里的任意应用，访问另一个内网里的应用服务端。}
  spec.homepage      = "https://github.com/takafan/p2p2"
  spec.license       = "MIT"

  spec.files         = %w[
p2p2.gemspec
lib/p2p2.rb
lib/p2p2/head.rb
lib/p2p2/hex.rb
lib/p2p2/p1.rb
lib/p2p2/p2.rb
lib/p2p2/p2pd.rb
lib/p2p2/version.rb
  ]

  spec.require_paths = ["lib"]
end
