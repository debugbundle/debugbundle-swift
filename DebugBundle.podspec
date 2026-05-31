Pod::Spec.new do |s|
  s.name         = "DebugBundle"
  s.version      = "1.0.0"
  s.summary      = "Native DebugBundle SDK for iOS apps."
  s.description  = "Core DebugBundle client, queueing, transport, redaction, capture policy, and probes for iOS apps."
  s.license      = { :type => "AGPL-3.0-only" }
  s.author       = { "DebugBundle" => "support@debugbundle.com" }
  s.homepage     = "https://github.com/debugbundle/debugbundle-swift"
  s.source       = { :git => "https://github.com/debugbundle/debugbundle-swift.git", :tag => "v#{s.version}" }
  s.platforms    = { :ios => "15.0" }
  s.swift_version = "5.10"
  s.source_files = "Sources/DebugBundle/**/*.swift"
end
