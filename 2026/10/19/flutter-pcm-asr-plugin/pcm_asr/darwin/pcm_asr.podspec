Pod::Spec.new do |s|
  s.name             = 'pcm_asr'
  s.version          = '0.0.1'
  s.summary          = 'Final transcription of finalized PCM segments with the OS speech engine.'
  s.description      = <<-DESC
The caller owns the microphone; this plugin only turns one finished PCM
segment into final text with Apple's SpeechAnalyzer.
                       DESC
  s.homepage         = 'https://github.com/kiarina/labs'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'kiarina' => 'kiarinadawa@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'pcm_asr/Sources/pcm_asr/**/*.swift'
  s.resource_bundles = { 'pcm_asr_privacy' => ['pcm_asr/Sources/pcm_asr/PrivacyInfo.xcprivacy'] }
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
