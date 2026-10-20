Pod::Spec.new do |s|
  s.name             = 'tts_pcm'
  s.version          = '0.0.1'
  s.summary          = 'Speech synthesis to PCM with the OS voices.'
  s.description      = <<-DESC
Synthesizes text with AVSpeechSynthesizer and hands the PCM to Dart instead of
playing it. The caller owns the speaker.
                       DESC
  s.homepage         = 'https://github.com/kiarina/labs'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'kiarina' => 'kiarinadawa@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'tts_pcm/Sources/tts_pcm/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
